#!/bin/bash
# dns_perf_4scenario.sh — 4-Scenario DNS Performance Comparison
#
# Compares DNS throughput/latency across two BYO CNI clusters:
#   1. BYO CNI + Cilium v1.18 + SDP  (v1.18 manifests, standalone DNS proxy)
#   2. BYO CNI + Cilium v1.19 + SDP  (v1.19 manifests, standalone DNS proxy)
#   3. BYO CNI + Cilium v1.19 no-SDP (in-agent DNS proxy only, no SDP)
#   4. BYO CNI + Cilium v1.19 no-proxy (no DNS proxy — raw DNS baseline)
#
# Cluster layout:
#   Cluster 1 (v1.18): runs scenario 1
#   Cluster 2 (v1.19): runs scenarios 2, 3, 4 (full teardown/redeploy between)
#
# IMPORTANT: This script uses isolated kubeconfig files and will NOT
#            modify your default ~/.kube/config context.
#
# Usage:
#   ./dns_perf_4scenario.sh [--scenario <1|2|3|4|all>] [--smoke] [--skip-infra]
#
# Prerequisites:
#   - az cli logged in
#   - kubectl, envsubst
#   - python3 (for perf-tests runner)
#   - go (for jsonify)
#   - cilium-private repo with upstream/camrynl/v1.19-manifests fetched
#   - perf-tests repo cloned

set -euo pipefail

###############################################################################
# Configuration — override via environment variables
###############################################################################

RESOURCE_GROUP="${RESOURCE_GROUP:-dns-perf-4scenario-rg}"
LOCATION="${LOCATION:-westus2}"
K8S_VERSION="${K8S_VERSION:-1.35.0}"
NODE_COUNT="${NODE_COUNT:-3}"
NODE_VM_SIZE="${NODE_VM_SIZE:-Standard_D4s_v3}"
POD_CIDR="${POD_CIDR:-10.244.0.0/16}"

# Cluster names — two BYO CNI clusters
V18_CLUSTER="${V18_CLUSTER:-dns-perf-byo-v18}"
V19_CLUSTER="${V19_CLUSTER:-dns-perf-byo-v19}"

# Images — override via env or source .build-tags/*.env from build_images.sh
CILIUM_IMAGE_REGISTRY="${CILIUM_IMAGE_REGISTRY:-acnpublic.azurecr.io}"
# v1.18 images (built from dev/v1.18, pushed to acnpublic.azurecr.io/cilium/)
CILIUM_V18_TAG="${CILIUM_V18_TAG:-amd64-dns-perf-v1.18}"
SDP_V18_TAG="${SDP_V18_TAG:-amd64-dns-perf-v1.18}"
# v1.19 images (built from dev/v1.19, pushed to acnpublic.azurecr.io/cilium/)
CILIUM_V19_TAG="${CILIUM_V19_TAG:-amd64-dns-perf-v1.19}"
SDP_V19_TAG="${SDP_V19_TAG:-amd64-dns-perf-v1.19}"

# Repo paths
CILIUM_REPO_ROOT="${CILIUM_REPO_ROOT:-$(cd "$(dirname "$0")/../../cilium-private" 2>/dev/null && pwd || echo "/home/singhvipul/ws/cilium-private")}"
PERF_TESTS_ROOT="${PERF_TESTS_ROOT:-$(cd "$(dirname "$0")/.." 2>/dev/null && pwd || echo "/home/singhvipul/ws/perf-tests")}"

# Work directory (results, kubeconfigs, generated manifests)
WORK_DIR="${WORK_DIR:-$PERF_TESTS_ROOT/dns/dns-perf-4scenario-workdir}"

# Isolated kubeconfig files — never touches ~/.kube/config
V18_KUBECONFIG="$WORK_DIR/kubeconfig-v18"
V19_KUBECONFIG="$WORK_DIR/kubeconfig-v19"

# Git branch with v1.19 manifests
MANIFEST_BRANCH="${MANIFEST_BRANCH:-upstream/camrynl/v1.19-manifests}"

# Test settings
NUM_RUNS="${NUM_RUNS:-5}"
BETWEEN_RUN_WAIT="${BETWEEN_RUN_WAIT:-120}"

# Scenario labels for results
declare -A SCENARIO_NAMES=(
    [1]="v18-cilium-sdp"
    [2]="v19-cilium-sdp"
    [3]="v19-cilium-inagent-proxy"
    [4]="v19-cilium-no-proxy"
)

###############################################################################
# CLI argument parsing
###############################################################################

TARGET_SCENARIO="all"
SMOKE_MODE=false
SKIP_INFRA=false

while [[ $# -gt 0 ]]; do
    case $1 in
        --scenario|-s) TARGET_SCENARIO="$2"; shift 2 ;;
        --smoke)       SMOKE_MODE=true; shift ;;
        --skip-infra)  SKIP_INFRA=true; shift ;;
        --runs)        NUM_RUNS="$2"; shift 2 ;;
        --help|-h)
            echo "Usage: $0 [--scenario <1|2|3|4|all>] [--smoke] [--skip-infra] [--runs N]"
            echo ""
            echo "  --scenario   Run specific scenario (1-4) or 'all' (default: all)"
            echo "  --smoke      Use 30s runs instead of 600s for quick validation"
            echo "  --skip-infra Skip cluster creation (clusters must already exist)"
            echo "  --runs N     Number of test runs per scenario (default: 5)"
            exit 0
            ;;
        *) echo "Unknown option: $1"; exit 1 ;;
    esac
done

if $SMOKE_MODE; then
    RUN_LENGTH=30
else
    RUN_LENGTH=600
fi

###############################################################################
# Logging
###############################################################################

LOG_FILE="$WORK_DIR/dns-perf-4scenario.log"

log() {
    local msg="[$(date '+%Y-%m-%d %H:%M:%S')] $1"
    echo "$msg" | tee -a "$LOG_FILE"
}

log_error() {
    log "ERROR: $1" >&2
}

###############################################################################
# Helpers — all kubectl/helm calls use isolated kubeconfig
###############################################################################

# kubectl wrapper that uses the right kubeconfig
kctl() {
    local kubeconfig="$1"; shift
    KUBECONFIG="$kubeconfig" kubectl "$@"
}

# helm wrapper
hctl() {
    local kubeconfig="$1"; shift
    KUBECONFIG="$kubeconfig" helm "$@"
}

###############################################################################
# Setup
###############################################################################

setup_workdir() {
    mkdir -p "$WORK_DIR"/{manifests,results,params}
    log "Work directory: $WORK_DIR"
}

create_stress_params() {
    cat > "$WORK_DIR/params/stress-test.yaml" << EOF
# DNS stress test — no QPS limit, find the ceiling
run_length_seconds: [$RUN_LENGTH]
max_qps: [null]
query_file: ["all-queries.txt"]
EOF
    log "Created stress test params (run_length=${RUN_LENGTH}s, max_qps=unlimited)"
}

extract_v19_manifests() {
    log "Extracting v1.19 manifests from $MANIFEST_BRANCH"
    local dest="$WORK_DIR/manifests/v1.19"
    rm -rf "$dest"
    mkdir -p "$dest"

    cd "$CILIUM_REPO_ROOT"

    # Extract full v1.19 manifest tree
    git archive "$MANIFEST_BRANCH" -- "test/manifests/v1.19/" | \
        tar -x --strip-components=2 -C "$dest"

    # Verify key files exist
    local required_files=(
        "$dest/v1.19/config/cilium-config-standalone-dns-proxy.yaml"
        "$dest/v1.19/config/cilium-config.yaml"
        "$dest/v1.19/config/standalone-dns-proxy.yaml"
        "$dest/v1.19/standalone-dns-proxy/templates/daemonset.yaml"
        "$dest/v1.19/cilium-agent/templates/daemonset.yaml"
        "$dest/v1.19/cilium-agent/files/clusterrole.yaml"
        "$dest/v1.19/cilium-operator/templates/deployment.yaml"
    )
    for f in "${required_files[@]}"; do
        if [[ ! -f "$f" ]]; then
            log_error "Missing required manifest: $f"
            exit 1
        fi
    done
    log "v1.19 manifests extracted to $dest"
}

copy_v18_manifests() {
    log "Copying v1.18 manifests from $CILIUM_REPO_ROOT (main branch)"
    local dest="$WORK_DIR/manifests/v1.18"
    rm -rf "$dest"
    mkdir -p "$dest"

    cp -r "$CILIUM_REPO_ROOT/test/manifests/v1.18" "$dest/"

    local required_files=(
        "$dest/v1.18/config/cilium-config-standalone-dns-proxy.yaml"
        "$dest/v1.18/config/standalone-dns-proxy.yaml"
        "$dest/v1.18/standalone-dns-proxy/templates/daemonset.yaml"
        "$dest/v1.18/cilium-agent/templates/daemonset.yaml"
        "$dest/v1.18/cilium-agent/files/clusterrole.yaml"
        "$dest/v1.18/cilium-operator/templates/deployment.yaml"
    )
    for f in "${required_files[@]}"; do
        if [[ ! -f "$f" ]]; then
            log_error "Missing required v1.18 manifest: $f"
            exit 1
        fi
    done
    log "v1.18 manifests copied to $dest"
}

generate_scenario_configs() {
    local v19_dir="$WORK_DIR/manifests/v1.19/v1.19"

    # Scenario 3: in-agent proxy only (no SDP)
    # Start from the SDP config (which has enable-l7-proxy: "true") but disable SDP
    local s3_config="$WORK_DIR/manifests/scenario3-cilium-config.yaml"
    sed \
        -e 's/enable-standalone-dns-proxy: "true"/enable-standalone-dns-proxy: "false"/' \
        "$v19_dir/config/cilium-config-standalone-dns-proxy.yaml" > "$s3_config"
    log "Generated scenario 3 config (l7-proxy=true, SDP=false)"

    # Scenario 4: no proxy at all (raw DNS baseline)
    local s4_config="$WORK_DIR/manifests/scenario4-cilium-config.yaml"
    sed \
        -e 's/enable-l7-proxy: "true"/enable-l7-proxy: "false"/' \
        -e 's/enable-standalone-dns-proxy: "true"/enable-standalone-dns-proxy: "false"/' \
        "$v19_dir/config/cilium-config-standalone-dns-proxy.yaml" > "$s4_config"
    log "Generated scenario 4 config (l7-proxy=false, SDP=false)"
}

create_cnp_yaml() {
    cat > "$WORK_DIR/manifests/kube-dns-cnp.yaml" << 'EOF'
apiVersion: "cilium.io/v2"
kind: CiliumNetworkPolicy
metadata:
  name: "dns-perf-fqdn-policy"
spec:
  endpointSelector:
    matchLabels:
      app: dns-perf-client
  egress:
    - toEndpoints:
        - matchLabels:
            "k8s:io.kubernetes.pod.namespace": kube-system
            "k8s:k8s-app": kube-dns
      toPorts:
        - ports:
           - port: "53"
             protocol: ANY
          rules:
            dns:
              - matchPattern: "*"
    - toFQDNs:
       - matchPattern: "*"
EOF
    log "Created CiliumNetworkPolicy YAML"
}

###############################################################################
# Infrastructure — cluster creation (isolated kubeconfigs)
###############################################################################

create_resource_group() {
    log "Creating resource group $RESOURCE_GROUP in $LOCATION"
    az group create -n "$RESOURCE_GROUP" -l "$LOCATION" --output none
}

create_v18_cluster() {
    if $SKIP_INFRA; then
        log "Skipping v1.18 cluster creation (--skip-infra)"
        if [[ ! -f "$V18_KUBECONFIG" ]]; then
            log "Fetching credentials for existing v1.18 cluster"
            az aks get-credentials \
                -n "$V18_CLUSTER" -g "$RESOURCE_GROUP" \
                --file "$V18_KUBECONFIG" --overwrite-existing
        fi
        return 0
    fi

    log "Creating AKS Azure CNI overlay cluster for v1.18: $V18_CLUSTER"
    az aks create \
        -n "$V18_CLUSTER" \
        -g "$RESOURCE_GROUP" \
        -l "$LOCATION" \
        --network-plugin azure \
        --network-plugin-mode overlay \
        --kubernetes-version "$K8S_VERSION" \
        --node-count "$NODE_COUNT" \
        --node-vm-size "$NODE_VM_SIZE" \
        --pod-cidr "$POD_CIDR" \
        --generate-ssh-keys \
        --output none

    az aks get-credentials \
        -n "$V18_CLUSTER" -g "$RESOURCE_GROUP" \
        --file "$V18_KUBECONFIG" --overwrite-existing

    log "v1.18 cluster ready. Kubeconfig: $V18_KUBECONFIG"
}

create_v19_cluster() {
    if $SKIP_INFRA; then
        log "Skipping v1.19 cluster creation (--skip-infra)"
        if [[ ! -f "$V19_KUBECONFIG" ]]; then
            log "Fetching credentials for existing v1.19 cluster"
            az aks get-credentials \
                -n "$V19_CLUSTER" -g "$RESOURCE_GROUP" \
                --file "$V19_KUBECONFIG" --overwrite-existing
        fi
        return 0
    fi

    log "Creating AKS Azure CNI overlay cluster for v1.19: $V19_CLUSTER"
    az aks create \
        -n "$V19_CLUSTER" \
        -g "$RESOURCE_GROUP" \
        -l "$LOCATION" \
        --network-plugin azure \
        --network-plugin-mode overlay \
        --kubernetes-version "$K8S_VERSION" \
        --node-count "$NODE_COUNT" \
        --node-vm-size "$NODE_VM_SIZE" \
        --pod-cidr "$POD_CIDR" \
        --generate-ssh-keys \
        --output none

    az aks get-credentials \
        -n "$V19_CLUSTER" -g "$RESOURCE_GROUP" \
        --file "$V19_KUBECONFIG" --overwrite-existing

    log "v1.19 cluster ready. Kubeconfig: $V19_KUBECONFIG"
}

###############################################################################
# Deployment helpers (all use isolated kubeconfigs)
###############################################################################

wait_for_cilium_ready() {
    local kc="$1"
    local timeout="${2:-300}"
    log "Waiting for Cilium pods to be ready (timeout: ${timeout}s)"

    local deadline=$((SECONDS + timeout))
    while [[ $SECONDS -lt $deadline ]]; do
        local ready
        ready=$(kctl "$kc" get pods -n kube-system -l k8s-app=cilium \
            --no-headers -o custom-columns=':status.conditions[?(@.type=="Ready")].status' \
            2>/dev/null | grep -c "True" || true)
        local total
        total=$(kctl "$kc" get pods -n kube-system -l k8s-app=cilium \
            --no-headers 2>/dev/null | wc -l || echo 0)

        if [[ "$total" -gt 0 && "$ready" -eq "$total" ]]; then
            log "Cilium ready: $ready/$total pods"
            return 0
        fi
        log "Cilium pods: $ready/$total ready, waiting..."
        sleep 10
    done
    log_error "Cilium did not become ready within ${timeout}s"
    kctl "$kc" get pods -n kube-system -l k8s-app=cilium -o wide
    return 1
}

wait_for_sdp_ready() {
    local kc="$1"
    local timeout="${2:-180}"
    log "Waiting for SDP (acns-security-agent) pods to be ready (timeout: ${timeout}s)"

    local deadline=$((SECONDS + timeout))
    while [[ $SECONDS -lt $deadline ]]; do
        local ready
        ready=$(kctl "$kc" get pods -n kube-system -l k8s-app=acns-security-agent \
            --no-headers -o custom-columns=':status.conditions[?(@.type=="Ready")].status' \
            2>/dev/null | grep -c "True" || true)
        local total
        total=$(kctl "$kc" get pods -n kube-system -l k8s-app=acns-security-agent \
            --no-headers 2>/dev/null | wc -l || echo 0)

        if [[ "$total" -gt 0 && "$ready" -eq "$total" ]]; then
            log "SDP ready: $ready/$total pods"
            return 0
        fi
        log "SDP pods: $ready/$total ready, waiting..."
        sleep 10
    done
    log_error "SDP did not become ready within ${timeout}s"
    return 1
}

deploy_cilium_rbac() {
    local kc="$1"
    local version="$2"  # "v1.18" or "v1.19"
    local manifest_dir="$WORK_DIR/manifests/$version/$version"

    log "Applying Cilium RBAC and operator files ($version)"
    kctl "$kc" apply -f "$manifest_dir/cilium-agent/files/"
    kctl "$kc" apply -f "$manifest_dir/cilium-operator/files/"
}

deploy_cilium_agent() {
    local kc="$1"
    local version="$2"
    local image_tag="$3"
    local manifest_dir="$WORK_DIR/manifests/$version/$version"

    log "Deploying Cilium agent DaemonSet ($version, tag=$image_tag)"
    CILIUM_VERSION_TAG="$image_tag" CILIUM_IMAGE_REGISTRY="$CILIUM_IMAGE_REGISTRY" \
        envsubst '${CILIUM_VERSION_TAG} ${CILIUM_IMAGE_REGISTRY}' \
        < "$manifest_dir/cilium-agent/templates/daemonset.yaml" | \
        kctl "$kc" apply -f -
}

deploy_cilium_operator() {
    local kc="$1"
    local version="$2"
    local image_tag="$3"
    local manifest_dir="$WORK_DIR/manifests/$version/$version"

    log "Deploying Cilium operator ($version, tag=$image_tag)"
    CILIUM_VERSION_TAG="$image_tag" CILIUM_IMAGE_REGISTRY="$CILIUM_IMAGE_REGISTRY" \
        envsubst '${CILIUM_VERSION_TAG} ${CILIUM_IMAGE_REGISTRY}' \
        < "$manifest_dir/cilium-operator/templates/deployment.yaml" | \
        kctl "$kc" apply -f -
}

###############################################################################
# Scenario deployments
###############################################################################

# Scenario 1: BYO CNI + Cilium v1.18 + SDP
deploy_scenario1() {
    local kc="$V18_KUBECONFIG"
    local manifest_dir="$WORK_DIR/manifests/v1.18/v1.18"

    log "=== Deploying Scenario 1: BYO + Cilium v1.18 + SDP ==="

    # On BYO CNI clusters, nodes are NotReady until the CNI is installed.
    # Deploy Cilium first (has NotReady tolerations), then SDP after nodes are Ready.

    # 1. Apply SDP ConfigMap (Cilium config references it, must exist first)
    log "Applying SDP ConfigMap (fqdn-policy-config) — v1.18"
    kctl "$kc" apply -f "$manifest_dir/config/standalone-dns-proxy.yaml"

    # 2. Apply Cilium config with SDP enabled
    log "Applying Cilium config (SDP variant) — v1.18"
    kctl "$kc" apply -f "$manifest_dir/config/cilium-config-standalone-dns-proxy.yaml"

    # 3. Deploy Cilium RBAC, agent, operator (agent tolerates NotReady)
    deploy_cilium_rbac "$kc" "v1.18"
    deploy_cilium_agent "$kc" "v1.18" "$CILIUM_V18_TAG"
    deploy_cilium_operator "$kc" "v1.18" "$CILIUM_V18_TAG"
    wait_for_cilium_ready "$kc"

    # 4. Now nodes are Ready — deploy SDP DaemonSet
    log "Deploying SDP DaemonSet (acns-security-agent) — v1.18"
    SDP_VERSION_TAG="$SDP_V18_TAG" CILIUM_IMAGE_REGISTRY="$CILIUM_IMAGE_REGISTRY" \
        envsubst '${SDP_VERSION_TAG} ${CILIUM_IMAGE_REGISTRY}' \
        < "$manifest_dir/standalone-dns-proxy/templates/daemonset.yaml" | \
        kctl "$kc" apply -f -

    wait_for_sdp_ready "$kc"

    log "=== Scenario 1 deployment complete ==="
}

# Scenario 2: BYO CNI + Cilium v1.19 + SDP
deploy_scenario2() {
    local kc="$V19_KUBECONFIG"
    local manifest_dir="$WORK_DIR/manifests/v1.19/v1.19"

    log "=== Deploying Scenario 2: BYO + Cilium v1.19 + SDP ==="

    # 1. Apply SDP ConfigMap (Cilium config references it, must exist first)
    log "Applying SDP ConfigMap (fqdn-policy-config) — v1.19"
    kctl "$kc" apply -f "$manifest_dir/config/standalone-dns-proxy.yaml"

    # 2. Apply Cilium config with SDP enabled
    log "Applying Cilium config (SDP variant) — v1.19"
    kctl "$kc" apply -f "$manifest_dir/config/cilium-config-standalone-dns-proxy.yaml"

    # 3. Deploy Cilium RBAC, agent, operator (agent tolerates NotReady)
    deploy_cilium_rbac "$kc" "v1.19"
    deploy_cilium_agent "$kc" "v1.19" "$CILIUM_V19_TAG"
    deploy_cilium_operator "$kc" "v1.19" "$CILIUM_V19_TAG"
    wait_for_cilium_ready "$kc"

    # 4. Now nodes are Ready — deploy SDP DaemonSet
    log "Deploying SDP DaemonSet (acns-security-agent) — v1.19"
    SDP_VERSION_TAG="$SDP_V19_TAG" CILIUM_IMAGE_REGISTRY="$CILIUM_IMAGE_REGISTRY" \
        envsubst '${SDP_VERSION_TAG} ${CILIUM_IMAGE_REGISTRY}' \
        < "$manifest_dir/standalone-dns-proxy/templates/daemonset.yaml" | \
        kctl "$kc" apply -f -

    wait_for_sdp_ready "$kc"

    log "=== Scenario 2 deployment complete ==="
}

# Scenario 3: BYO CNI + Cilium v1.19 (in-agent proxy only, no SDP)
deploy_scenario3() {
    local kc="$V19_KUBECONFIG"

    log "=== Deploying Scenario 3: BYO + Cilium v1.19 (in-agent proxy only) ==="

    # Apply Cilium config: l7-proxy=true, SDP=false
    log "Applying Cilium config (l7-proxy enabled, SDP disabled)"
    kctl "$kc" apply -f "$WORK_DIR/manifests/scenario3-cilium-config.yaml"

    # Deploy RBAC, agent, operator (no SDP)
    deploy_cilium_rbac "$kc" "v1.19"
    deploy_cilium_agent "$kc" "v1.19" "$CILIUM_V19_TAG"
    deploy_cilium_operator "$kc" "v1.19" "$CILIUM_V19_TAG"
    wait_for_cilium_ready "$kc"

    log "=== Scenario 3 deployment complete ==="
}

# Scenario 4: BYO CNI + Cilium v1.19 (no DNS proxy — raw baseline)
deploy_scenario4() {
    local kc="$V19_KUBECONFIG"

    log "=== Deploying Scenario 4: BYO + Cilium v1.19 (no DNS proxy) ==="

    # Apply Cilium config: l7-proxy=false, SDP=false
    log "Applying Cilium config (no proxy)"
    kctl "$kc" apply -f "$WORK_DIR/manifests/scenario4-cilium-config.yaml"

    # Deploy RBAC, agent, operator (no SDP, no proxy)
    deploy_cilium_rbac "$kc" "v1.19"
    deploy_cilium_agent "$kc" "v1.19" "$CILIUM_V19_TAG"
    deploy_cilium_operator "$kc" "v1.19" "$CILIUM_V19_TAG"
    wait_for_cilium_ready "$kc"

    log "=== Scenario 4 deployment complete ==="
}

###############################################################################
# Teardown
###############################################################################

teardown_cilium() {
    local kc="$1"
    local version="${2:-v1.19}"
    log "Tearing down Cilium and SDP from cluster ($version)"
    local manifest_dir="$WORK_DIR/manifests/$version/$version"

    # Delete SDP
    kctl "$kc" delete ds acns-security-agent -n kube-system --ignore-not-found=true 2>/dev/null || true
    kctl "$kc" delete cm fqdn-policy-config -n kube-system --ignore-not-found=true 2>/dev/null || true

    # Delete Cilium agent and operator
    kctl "$kc" delete ds cilium -n kube-system --ignore-not-found=true 2>/dev/null || true
    kctl "$kc" delete deploy cilium-operator -n kube-system --ignore-not-found=true 2>/dev/null || true
    kctl "$kc" delete cm cilium-config -n kube-system --ignore-not-found=true 2>/dev/null || true

    # Delete RBAC
    if [[ -d "$manifest_dir/cilium-agent/files" ]]; then
        kctl "$kc" delete -f "$manifest_dir/cilium-agent/files/" --ignore-not-found=true 2>/dev/null || true
    fi
    if [[ -d "$manifest_dir/cilium-operator/files" ]]; then
        kctl "$kc" delete -f "$manifest_dir/cilium-operator/files/" --ignore-not-found=true 2>/dev/null || true
    fi

    # Delete CNP
    kctl "$kc" delete cnp dns-perf-fqdn-policy --ignore-not-found=true 2>/dev/null || true

    # Clean up perf client
    kctl "$kc" delete deploy dns-perf-client --ignore-not-found=true 2>/dev/null || true

    # Wait for pods to terminate
    log "Waiting for Cilium/SDP pods to terminate..."
    local timeout=120
    local deadline=$((SECONDS + timeout))
    while [[ $SECONDS -lt $deadline ]]; do
        local remaining
        remaining=$(kctl "$kc" get pods -n kube-system \
            -l 'k8s-app in (cilium, acns-security-agent)' \
            --no-headers 2>/dev/null | wc -l || echo 0)
        if [[ "$remaining" -eq 0 ]]; then
            break
        fi
        log "  $remaining pods still terminating..."
        sleep 5
    done

    log "Teardown complete"
}

###############################################################################
# Preflight validation
###############################################################################

preflight_check() {
    local kc="$1"
    local scenario="$2"

    log "Running preflight checks for scenario $scenario"

    # Check nodes ready
    local ready_nodes
    ready_nodes=$(kctl "$kc" get nodes --no-headers | grep -c " Ready" || true)
    log "  Nodes ready: $ready_nodes"
    if [[ "$ready_nodes" -lt 1 ]]; then
        log_error "No ready nodes!"
        return 1
    fi

    # Check CoreDNS running
    local coredns_pods
    coredns_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=kube-dns --no-headers 2>/dev/null | grep -c "Running" || true)
    log "  CoreDNS pods running: $coredns_pods"

    # Scenario-specific checks
    case "$scenario" in
        1)
            # v1.18 + SDP — check both cilium and SDP
            local cilium_pods sdp_pods
            cilium_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "Running" || true)
            sdp_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=acns-security-agent --no-headers 2>/dev/null | grep -c "Running" || true)
            log "  Cilium pods (v1.18): $cilium_pods, SDP pods: $sdp_pods"
            if [[ "$sdp_pods" -lt 1 ]]; then
                log_error "SDP not running for scenario 1!"
                return 1
            fi
            ;;
        2)
            # v1.19 + SDP — check both cilium and SDP
            local cilium_pods sdp_pods
            cilium_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "Running" || true)
            sdp_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=acns-security-agent --no-headers 2>/dev/null | grep -c "Running" || true)
            log "  Cilium pods (v1.19): $cilium_pods, SDP pods: $sdp_pods"
            if [[ "$sdp_pods" -lt 1 ]]; then
                log_error "SDP not running for scenario 2!"
                return 1
            fi
            ;;
        3)
            # BYO + in-agent proxy only
            local cilium_pods
            cilium_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "Running" || true)
            log "  Cilium pods: $cilium_pods (in-agent proxy mode)"
            # Verify SDP is NOT running
            local sdp_pods
            sdp_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=acns-security-agent --no-headers 2>/dev/null | wc -l || echo 0)
            if [[ "$sdp_pods" -gt 0 ]]; then
                log_error "SDP should NOT be running for scenario 3!"
                return 1
            fi
            ;;
        4)
            # BYO + no proxy
            local cilium_pods
            cilium_pods=$(kctl "$kc" get pods -n kube-system -l k8s-app=cilium --no-headers 2>/dev/null | grep -c "Running" || true)
            log "  Cilium pods: $cilium_pods (no-proxy mode)"
            ;;
    esac

    # DNS smoke test: resolve kubernetes.default
    log "  DNS smoke test..."
    if kctl "$kc" run dns-smoke-test --rm -i --restart=Never \
        --image=busybox:1.36 --timeout=30s -- \
        nslookup kubernetes.default.svc.cluster.local 2>/dev/null | grep -q "Address"; then
        log "  DNS smoke test: PASSED"
    else
        log "  DNS smoke test: FAILED (may be expected for scenario 4)"
    fi

    # For scenarios 1-3: verify FQDN policy can be enforced
    if [[ "$scenario" -le 3 ]]; then
        log "  Verifying FQDN policy enforcement..."
        # Just check the CNP status
        if kctl "$kc" get cnp dns-perf-fqdn-policy 2>/dev/null | grep -q "dns-perf-fqdn-policy"; then
            log "  FQDN policy: applied"
        else
            log "  FQDN policy: not yet applied (will apply before test)"
        fi
    fi

    log "Preflight checks passed for scenario $scenario"
    return 0
}

###############################################################################
# Record metadata for each run
###############################################################################

record_metadata() {
    local kc="$1"
    local scenario_num="$2"
    local scenario_name="$3"
    local output_dir="$4"

    local metadata_file="$output_dir/scenario_metadata.json"

    local cilium_ver
    local sdp_ver
    case "$scenario_num" in
        1) cilium_ver="$CILIUM_V18_TAG"; sdp_ver="$SDP_V18_TAG" ;;
        *) cilium_ver="$CILIUM_V19_TAG"; sdp_ver="$SDP_V19_TAG" ;;
    esac

    local k8s_ver
    k8s_ver=$(kctl "$kc" version --short 2>/dev/null | grep Server | awk '{print $NF}' || echo "unknown")

    local node_count
    node_count=$(kctl "$kc" get nodes --no-headers 2>/dev/null | wc -l || echo "unknown")

    local coredns_replicas
    coredns_replicas=$(kctl "$kc" get deploy -n kube-system -l k8s-app=kube-dns --no-headers \
        -o custom-columns=':status.readyReplicas' 2>/dev/null | head -1 || echo "unknown")

    local cilium_config_dump=""
    if kctl "$kc" get cm cilium-config -n kube-system 2>/dev/null >/dev/null; then
        cilium_config_dump=$(kctl "$kc" get cm cilium-config -n kube-system -o json 2>/dev/null | \
            python3 -c "import sys,json; d=json.load(sys.stdin)['data']; print(json.dumps({k:d[k] for k in sorted(d.keys()) if 'dns' in k.lower() or 'proxy' in k.lower() or 'fqdn' in k.lower() or 'standalone' in k.lower() or 'l7' in k.lower()}, indent=2))" 2>/dev/null || echo "{}")
    fi

    cat > "$metadata_file" << EOF
{
    "scenario_number": $scenario_num,
    "scenario_name": "$scenario_name",
    "cluster_type": "byo-cni",
    "cilium_version": "$cilium_ver",
    "sdp_version": "$sdp_ver",
    "kubernetes_version": "$k8s_ver",
    "node_count": "$node_count",
    "node_vm_size": "$NODE_VM_SIZE",
    "coredns_replicas": "$coredns_replicas",
    "cilium_image": "$CILIUM_IMAGE_REGISTRY/cilium:$cilium_ver",
    "sdp_image": "$CILIUM_IMAGE_REGISTRY/cilium/dns-proxy:$sdp_ver",
    "run_length_seconds": $RUN_LENGTH,
    "max_qps": null,
    "num_runs": $NUM_RUNS,
    "timestamp": "$(date -Iseconds)",
    "dns_proxy_config": $cilium_config_dump
}
EOF
    log "Recorded metadata to $metadata_file"
}

###############################################################################
# DNS Performance Test Runner
###############################################################################

run_perf_test() {
    local kc="$1"
    local scenario_num="$2"
    local scenario_name="$3"

    log "=== Running DNS perf test: Scenario $scenario_num ($scenario_name) ==="
    log "  Runs: $NUM_RUNS, Duration: ${RUN_LENGTH}s each, QPS: unlimited"

    local result_dir="$WORK_DIR/results/$scenario_name"
    mkdir -p "$result_dir"

    # Record metadata
    record_metadata "$kc" "$scenario_num" "$scenario_name" "$result_dir"

    # Apply CNP for scenarios 1-3
    if [[ "$scenario_num" -le 3 ]]; then
        log "Applying CiliumNetworkPolicy"
        kctl "$kc" apply -f "$WORK_DIR/manifests/kube-dns-cnp.yaml"
        sleep 5
    else
        log "Skipping CNP for scenario 4 (no proxy — raw baseline)"
    fi

    # Run tests
    local dns_dir="$PERF_TESTS_ROOT/dns"
    local params_file="$WORK_DIR/params/stress-test.yaml"

    for ((run=1; run<=NUM_RUNS; run++)); do
        log "--- Run $run/$NUM_RUNS for scenario $scenario_name ---"

        local run_dir="$result_dir/run_$run"
        mkdir -p "$run_dir"

        cd "$dns_dir"

        # Run the perf test using the existing framework with isolated kubeconfig
        if KUBECONFIG="$kc" python3 py/run_perf.py \
            --params "$params_file" \
            --use-cluster-dns \
            --out-dir "$run_dir" \
            > "$run_dir/test_output.log" 2>&1; then
            log "  Run $run PASSED"
        else
            log_error "  Run $run FAILED — check $run_dir/test_output.log"
            tail -20 "$run_dir/test_output.log" | while IFS= read -r line; do
                log "    $line"
            done
        fi

        # Convert results to JSON with jsonify
        if [[ -d "$dns_dir/jsonify" ]]; then
            cd "$dns_dir/jsonify"

            local json_out="$run_dir/json"
            mkdir -p "$json_out"

            if go run main.go \
                --benchmarkDirPath="$run_dir/latest" \
                --jsonDirPath="$json_out" \
                --benchmarkName="dns" \
                > "$run_dir/jsonify_output.log" 2>&1; then
                log "  Jsonify: OK"
            else
                log "  Jsonify: FAILED (non-critical)"
            fi
        fi

        # Copy results to perfdash-compatible structure
        local build_dir="$PERF_TESTS_ROOT/dns/json-metrics-structured/$scenario_name"
        local build_num
        build_num=$(find_next_build_number "$build_dir")
        mkdir -p "$build_dir/$build_num/artifacts"

        cp -r "$run_dir/json/"* "$build_dir/$build_num/artifacts/" 2>/dev/null || true
        cp "$result_dir/scenario_metadata.json" "$build_dir/$build_num/artifacts/" 2>/dev/null || true

        cat > "$build_dir/$build_num/build_info.json" << EOF
{
    "build_number": $build_num,
    "scenario": "$scenario_name",
    "run": $run,
    "created_at": "$(date -Iseconds)",
    "run_length_seconds": $RUN_LENGTH
}
EOF

        # Wait between runs (except last)
        if [[ $run -lt $NUM_RUNS ]]; then
            log "  Waiting ${BETWEEN_RUN_WAIT}s before next run..."
            sleep "$BETWEEN_RUN_WAIT"
        fi
    done

    # Clean up perf client pods
    kctl "$kc" delete deploy dns-perf-client --ignore-not-found=true 2>/dev/null || true

    log "=== Scenario $scenario_num ($scenario_name) complete: $NUM_RUNS runs ==="
}

find_next_build_number() {
    local dir="$1"
    local max=0
    if [[ -d "$dir" ]]; then
        for d in "$dir"/*/; do
            local num
            num=$(basename "$d" 2>/dev/null)
            if [[ "$num" =~ ^[0-9]+$ ]] && [[ "$num" -gt "$max" ]]; then
                max=$num
            fi
        done
    fi
    echo $((max + 1))
}

###############################################################################
# Comparison report
###############################################################################

generate_comparison() {
    log "=== Generating comparison report ==="

    local report="$WORK_DIR/results/comparison_report.txt"

    cat > "$report" << 'HEADER'
╔══════════════════════════════════════════════════════════════╗
║            DNS Performance — 4-Scenario Comparison          ║
╚══════════════════════════════════════════════════════════════╝

HEADER

    for scenario_num in 1 2 3 4; do
        local scenario_name="${SCENARIO_NAMES[$scenario_num]}"
        local result_dir="$WORK_DIR/results/$scenario_name"

        if [[ ! -d "$result_dir" ]]; then
            echo "Scenario $scenario_num ($scenario_name): NO RESULTS" >> "$report"
            echo "" >> "$report"
            continue
        fi

        echo "━━━ Scenario $scenario_num: $scenario_name ━━━" >> "$report"

        # Extract metadata
        if [[ -f "$result_dir/scenario_metadata.json" ]]; then
            python3 -c "
import json, sys
with open('$result_dir/scenario_metadata.json') as f:
    m = json.load(f)
print(f\"  Cluster: {m.get('cluster_type', 'unknown')}\")
print(f\"  K8s: {m.get('kubernetes_version', 'unknown')}\")
print(f\"  Nodes: {m.get('node_count', 'unknown')} x {m.get('node_vm_size', 'unknown')}\")
print(f\"  CoreDNS replicas: {m.get('coredns_replicas', 'unknown')}\")
print(f\"  Run duration: {m.get('run_length_seconds', 'unknown')}s\")
" >> "$report" 2>/dev/null || true
        fi

        # Summarize results per run
        echo "  Results:" >> "$report"
        for run_dir in "$result_dir"/run_*/; do
            local run_num
            run_num=$(basename "$run_dir" | sed 's/run_//')

            # Try to extract QPS and latency from raw output
            local latest_dir="$run_dir/latest"
            if [[ -d "$latest_dir" ]]; then
                for result_file in "$latest_dir"/*.out; do
                    if [[ -f "$result_file" ]]; then
                        python3 -c "
import yaml, sys
with open('$result_file') as f:
    data = yaml.safe_load(f)
if data and 'data' in data and data['data'].get('ok'):
    d = data['data']
    qps = d.get('qps_average', 'N/A')
    lat_avg = d.get('latency_average', 'N/A')
    lat_p99 = d.get('latency_99th', 'N/A')
    queries = d.get('queries_sent', 'N/A')
    completed = d.get('queries_completed', 'N/A')
    print(f'    Run {\"$run_num\"}: QPS={qps}, Lat_avg={lat_avg}, Lat_p99={lat_p99}, Sent={queries}, Done={completed}')
else:
    print(f'    Run {\"$run_num\"}: PARSE ERROR or FAILED')
" >> "$report" 2>/dev/null || echo "    Run $run_num: no parseable output" >> "$report"
                    fi
                done
            else
                echo "    Run $run_num: no results" >> "$report"
            fi
        done
        echo "" >> "$report"
    done

    echo "Report saved: $report"
    cat "$report"
    log "Comparison report generated: $report"
}

###############################################################################
# Main orchestration
###############################################################################

should_run_scenario() {
    local num="$1"
    [[ "$TARGET_SCENARIO" == "all" || "$TARGET_SCENARIO" == "$num" ]]
}

main() {
    mkdir -p "$WORK_DIR"
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  DNS Performance Test — 4-Scenario Comparison           ║"
    log "║  Cluster 1: BYO CNI + Cilium v1.18                     ║"
    log "║  Cluster 2: BYO CNI + Cilium v1.19                     ║"
    log "╠══════════════════════════════════════════════════════════╣"
    log "║  Target: ${TARGET_SCENARIO}  Smoke: ${SMOKE_MODE}  Runs: ${NUM_RUNS}  Duration: ${RUN_LENGTH}s ║"
    log "╚══════════════════════════════════════════════════════════╝"
    log ""
    log "KUBECONFIG SAFETY: Using isolated kubeconfig files"
    log "  v1.18 cluster: $V18_KUBECONFIG"
    log "  v1.19 cluster: $V19_KUBECONFIG"
    log "  Default ~/.kube/config will NOT be modified"
    log ""

    # Setup
    setup_workdir
    create_stress_params
    copy_v18_manifests
    extract_v19_manifests
    generate_scenario_configs
    create_cnp_yaml

    # Create infrastructure
    create_resource_group

    if should_run_scenario 1; then
        create_v18_cluster
    fi
    if should_run_scenario 2 || should_run_scenario 3 || should_run_scenario 4; then
        create_v19_cluster
    fi

    # === Scenario 1: BYO + Cilium v1.18 + SDP ===
    if should_run_scenario 1; then
        log ""
        log "████████████████████████████████████████████████████"
        log "█  SCENARIO 1: BYO CNI + Cilium v1.18 + SDP      █"
        log "████████████████████████████████████████████████████"
        teardown_cilium "$V18_KUBECONFIG" "v1.18"
        deploy_scenario1
        preflight_check "$V18_KUBECONFIG" 1
        run_perf_test "$V18_KUBECONFIG" 1 "${SCENARIO_NAMES[1]}"
    fi

    # === Scenario 2: BYO + Cilium v1.19 + SDP ===
    if should_run_scenario 2; then
        log ""
        log "████████████████████████████████████████████████████"
        log "█  SCENARIO 2: BYO CNI + Cilium v1.19 + SDP      █"
        log "████████████████████████████████████████████████████"
        teardown_cilium "$V19_KUBECONFIG" "v1.19"
        deploy_scenario2
        preflight_check "$V19_KUBECONFIG" 2
        run_perf_test "$V19_KUBECONFIG" 2 "${SCENARIO_NAMES[2]}"
    fi

    # === Scenario 3: BYO + Cilium v1.19 (in-agent proxy only) ===
    if should_run_scenario 3; then
        log ""
        log "████████████████████████████████████████████████████"
        log "█  SCENARIO 3: BYO CNI + Cilium v1.19 (in-agent) █"
        log "████████████████████████████████████████████████████"
        teardown_cilium "$V19_KUBECONFIG" "v1.19"
        deploy_scenario3
        preflight_check "$V19_KUBECONFIG" 3
        run_perf_test "$V19_KUBECONFIG" 3 "${SCENARIO_NAMES[3]}"
    fi

    # === Scenario 4: BYO + Cilium v1.19 (no proxy — baseline) ===
    if should_run_scenario 4; then
        log ""
        log "████████████████████████████████████████████████████"
        log "█  SCENARIO 4: BYO CNI + Cilium v1.19 (no proxy) █"
        log "████████████████████████████████████████████████████"
        teardown_cilium "$V19_KUBECONFIG" "v1.19"
        deploy_scenario4
        preflight_check "$V19_KUBECONFIG" 4
        run_perf_test "$V19_KUBECONFIG" 4 "${SCENARIO_NAMES[4]}"
    fi

    # Final teardown
    if should_run_scenario 1; then
        teardown_cilium "$V18_KUBECONFIG" "v1.18"
    fi
    if should_run_scenario 2 || should_run_scenario 3 || should_run_scenario 4; then
        teardown_cilium "$V19_KUBECONFIG" "v1.19"
    fi

    # Generate comparison
    generate_comparison

    log ""
    log "╔══════════════════════════════════════════════════════════╗"
    log "║  All scenarios complete!                                ║"
    log "║  Results: $WORK_DIR/results/                            "
    log "║  Report:  $WORK_DIR/results/comparison_report.txt       "
    log "╚══════════════════════════════════════════════════════════╝"
}

main "$@"
