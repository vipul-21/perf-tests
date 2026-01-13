#!/bin/bash
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CLUSTER_SCRIPT="${SCRIPT_DIR}/byocni-cluster.sh"
PODSTART_DIR="$(cd "${SCRIPT_DIR}/../perf-tests/clusterloader2" && pwd)"
PODSTART_SCRIPT="${PODSTART_DIR}/run-podstartup.sh"

if [ ! -x "${CLUSTER_SCRIPT}" ]; then
    echo "Error: Missing or non-executable cluster script at ${CLUSTER_SCRIPT}" >&2
    exit 1
fi

if [ ! -f "${PODSTART_SCRIPT}" ]; then
    echo "Error: Missing pod startup script at ${PODSTART_SCRIPT}" >&2
    exit 1
fi

RUNS=1
LIFECYCLE="recreate"
CLUSTER_NAME="byocni-cluster"
REGION="westus3"
POOL_COUNT=""
NODES_PER_POOL=""
SCENARIO="default"
DEPLOYMENT_SIZE=100
SLO_PATTERN=""
PROM_PATTERN=""
RESULT_PREFIX=""
ENABLE_MESH=false
ENABLE_MONITORING=false
PODS_PER_NODE=""
NAMESPACE_COUNT=""
LOAD_THROUGHPUT=""
DELETE_THROUGHPUT=""

print_usage() {
    cat <<EOF
Usage: $(basename "$0") [options]

Options:
  --runs <N>             Number of test iterations (default: 1)
  --recreate            Recreate cluster before each run (default behavior)
  --reuse               Reuse cluster across runs; create only if missing
  --delete-only         Delete cluster and exit
  --cluster-name <NAME> Override cluster name (default: byocni-cluster)
    --region <REGION>     Override Azure region (default: westus3)
    --mesh                Enable mesh mode in byocni-cluster.sh
    --no-mesh             Explicitly disable mesh (default)
  --pools <N>           Worker pool count passed to byocni-cluster.sh
  --nodes-per-pool <N>  Workers per pool passed to byocni-cluster.sh
  --scenario <NAME>     run-podstartup scenario (default: default)
    --deployment-size <N> Deployment size for run-podstartup (default: 100)
        --pods-per-node <N>   Override pods per node for podstartup (optional)
        --namespaces <N>      Override namespace count for podstartup (optional)
        --load-throughput <N> Override load throughput (pods/sec) (optional)
        --delete-throughput <N> Override delete throughput (pods/sec); defaults to load rate
  --slo-pattern <PAT>   Optional grep pattern to mark SLO nodes
  --prom-pattern <PAT>  Optional grep pattern to mark Prometheus nodes
  --results-prefix <P>  Custom results folder prefix (default auto-generated)
    --enable-monitoring   Forward monitoring flag to byocni-cluster.sh
  -h, --help            Show this help and exit
EOF
}

require_value() {
    local flag="$1"
    local value="$2"
    if [ -z "$value" ]; then
        echo "Error: ${flag} expects a value" >&2
        exit 1
    fi
}

while [[ $# -gt 0 ]]; do
    case "$1" in
        --runs)
            require_value "$1" "${2-}"
            RUNS="$2"; shift 2 ;;
        --recreate)
            LIFECYCLE="recreate"; shift ;;
        --reuse)
            LIFECYCLE="reuse"; shift ;;
        --delete-only)
            LIFECYCLE="delete-only"; shift ;;
        --cluster-name)
            require_value "$1" "${2-}"
            CLUSTER_NAME="$2"; shift 2 ;;
        --region)
            require_value "$1" "${2-}"
            REGION="$2"; shift 2 ;;
        --mesh)
            ENABLE_MESH=true; shift ;;
        --no-mesh)
            ENABLE_MESH=false; shift ;;
        --pools)
            require_value "$1" "${2-}"
            POOL_COUNT="$2"; shift 2 ;;
        --nodes-per-pool)
            require_value "$1" "${2-}"
            NODES_PER_POOL="$2"; shift 2 ;;
        --scenario)
            require_value "$1" "${2-}"
            SCENARIO="$2"; shift 2 ;;
        --deployment-size)
            require_value "$1" "${2-}"
            DEPLOYMENT_SIZE="$2"; shift 2 ;;
        --pods-per-node)
            require_value "$1" "${2-}"
            PODS_PER_NODE="$2"; shift 2 ;;
        --namespaces)
            require_value "$1" "${2-}"
            NAMESPACE_COUNT="$2"; shift 2 ;;
        --load-throughput)
            require_value "$1" "${2-}"
            LOAD_THROUGHPUT="$2"; shift 2 ;;
        --delete-throughput)
            require_value "$1" "${2-}"
            DELETE_THROUGHPUT="$2"; shift 2 ;;
        --slo-pattern)
            require_value "$1" "${2-}"
            SLO_PATTERN="$2"; shift 2 ;;
        --prom-pattern)
            require_value "$1" "${2-}"
            PROM_PATTERN="$2"; shift 2 ;;
        --results-prefix)
            require_value "$1" "${2-}"
            RESULT_PREFIX="$2"; shift 2 ;;
        --enable-monitoring)
            ENABLE_MONITORING=true; shift ;;
        -h|--help)
            print_usage; exit 0 ;;
        *)
            echo "Unknown option: $1" >&2
            print_usage
            exit 1 ;;
    esac
done

if ! [[ "${RUNS}" =~ ^[0-9]+$ ]] || [ "${RUNS}" -lt 1 ]; then
    echo "Error: --runs must be a positive integer" >&2
    exit 1
fi

if [ -n "${POOL_COUNT}" ] && ! [[ "${POOL_COUNT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --pools expects an integer" >&2
    exit 1
fi

if [ -n "${NODES_PER_POOL}" ] && ! [[ "${NODES_PER_POOL}" =~ ^[0-9]+$ ]]; then
    echo "Error: --nodes-per-pool expects an integer" >&2
    exit 1
fi

if [ -n "${PODS_PER_NODE}" ] && ! [[ "${PODS_PER_NODE}" =~ ^[0-9]+$ ]]; then
    echo "Error: --pods-per-node expects an integer" >&2
    exit 1
fi

if [ -n "${NAMESPACE_COUNT}" ] && ! [[ "${NAMESPACE_COUNT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --namespaces expects an integer" >&2
    exit 1
fi

if [ -n "${LOAD_THROUGHPUT}" ] && ! [[ "${LOAD_THROUGHPUT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --load-throughput expects an integer" >&2
    exit 1
fi

if [ -n "${DELETE_THROUGHPUT}" ] && ! [[ "${DELETE_THROUGHPUT}" =~ ^[0-9]+$ ]]; then
    echo "Error: --delete-throughput expects an integer" >&2
    exit 1
fi

if ! command -v az >/dev/null 2>&1; then
    echo "Error: Azure CLI (az) is required" >&2
    exit 1
fi

if ! command -v kubectl >/dev/null 2>&1; then
    echo "Error: kubectl is required" >&2
    exit 1
fi

RESOURCE_GROUP="${CLUSTER_NAME}-rg"
SESSION_TAG="$(date +%Y%m%dT%H%M%S)"
if [ -z "${RESULT_PREFIX}" ]; then
    RESULT_PREFIX="${CLUSTER_NAME}-runs-${SESSION_TAG}"
fi

KUBECONFIG_PATH="$(mktemp -t "${CLUSTER_NAME}-kubeconfig.XXXXXX")"
trap 'rm -f "${KUBECONFIG_PATH}"' EXIT

LOG_PREFIX="[multi-run]"

log() {
    echo "[$(date +%Y-%m-%dT%H:%M:%S%z)] ${LOG_PREFIX} $*" >&2
}

log "Using temporary kubeconfig at ${KUBECONFIG_PATH}"
log "Starting run-byocni-podstartup-multi with configuration: runs=${RUNS}, lifecycle=${LIFECYCLE}, cluster=${CLUSTER_NAME}, region=${REGION}, mesh=${ENABLE_MESH}, pools=${POOL_COUNT:-default}, nodes-per-pool=${NODES_PER_POOL:-default}, scenario=${SCENARIO}, deployment-size=${DEPLOYMENT_SIZE}, pods-per-node=${PODS_PER_NODE:-default}, namespaces=${NAMESPACE_COUNT:-default}, load-throughput=${LOAD_THROUGHPUT:-100}, delete-throughput=${DELETE_THROUGHPUT:-${LOAD_THROUGHPUT:-100}}, results=${RESULT_PREFIX}"

cluster_exists() {
    if az aks show --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" >/dev/null 2>&1; then
        return 0
    fi
    return 1
}

resource_group_exists() {
    [[ "$(az group exists --name "${RESOURCE_GROUP}" --output tsv)" == "true" ]]
}

wait_for_cluster_deletion() {
    local interval=15
    local max_wait=$((60 * 20)) # 20 minutes upper bound
    local waited=0

    while [ "${waited}" -lt "${max_wait}" ]; do
        if ! cluster_exists && ! resource_group_exists; then
            log "Cluster ${CLUSTER_NAME} and resource group ${RESOURCE_GROUP} fully deleted."
            return 0
        fi

        log "Deletion still in progress (waited ${waited}s)..."
        sleep "${interval}"
        waited=$((waited + interval))
    done

    log "Deletion exceeded ${max_wait}s; sleeping additional 300s as safeguard."
    sleep 300
    return 0
}

delete_cluster() {
    if resource_group_exists; then
        log "Deleting resource group ${RESOURCE_GROUP}..."
        az group delete --name "${RESOURCE_GROUP}" --yes --no-wait
        wait_for_cluster_deletion
        log "Deletion command issued for ${RESOURCE_GROUP}."
    else
        log "Resource group ${RESOURCE_GROUP} not found; skipping delete."
    fi
}

create_cluster() {
    log "Creating cluster ${CLUSTER_NAME} in ${REGION}..."
    local args=(--name "${CLUSTER_NAME}" --region "${REGION}")
    if [ -n "${POOL_COUNT}" ]; then
        args+=(--pools "${POOL_COUNT}")
    fi
    if [ -n "${NODES_PER_POOL}" ]; then
        args+=(--nodes-per-pool "${NODES_PER_POOL}")
    fi
    if [ "${ENABLE_MESH}" = true ]; then
        args+=(--mesh)
    fi
    if [ "${ENABLE_MONITORING}" = true ]; then
        args+=(--enable-monitoring)
    fi
    args+=(--kubeconfig "${KUBECONFIG_PATH}")
    local full_cmd=("${CLUSTER_SCRIPT}" "${args[@]}")
    log "Executing: ${full_cmd[*]}"
    "${full_cmd[@]}"
    log "Cluster creation command completed for ${CLUSTER_NAME}."
}

ensure_cluster() {
    if cluster_exists; then
        log "Cluster ${CLUSTER_NAME} already exists; reusing."
    else
        log "Cluster ${CLUSTER_NAME} not found; creating."
        create_cluster
    fi
}

refresh_credentials() {
    log "Fetching kubeconfig for ${CLUSTER_NAME}..."
    az aks get-credentials --resource-group "${RESOURCE_GROUP}" --name "${CLUSTER_NAME}" --overwrite-existing --file "${KUBECONFIG_PATH}"
}

wait_for_nodes() {
    local attempts=60
    local delay=15
    for ((i=1; i<=attempts; i++)); do
        if ! nodes_output=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes --no-headers 2>/dev/null); then
            log "kubectl get nodes failed, retrying (${i}/${attempts})..."
            sleep "${delay}"
            continue
        fi

        local total_nodes ready_nodes
        total_nodes=$(echo "${nodes_output}" | awk 'NF' | wc -l | tr -d ' ')
        ready_nodes=$(echo "${nodes_output}" | awk '$2 ~ /Ready/ {count++} END {print count+0}')

        if [ "${total_nodes}" -gt 0 ]; then
            log "Node readiness ${ready_nodes}/${total_nodes}."
            if [ "${ready_nodes}" -eq "${total_nodes}" ]; then
                echo "${ready_nodes}"
                return 0
            fi
        else
            log "No Kubernetes nodes reported yet (${i}/${attempts})."
        fi

        sleep "${delay}"
    done

    echo "Timed out waiting for all Kubernetes nodes to become Ready" >&2
    return 1
}

wait_for_cilium() {
    log "Waiting for Cilium daemonset to become Ready..."
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system rollout status daemonset/cilium --timeout=25m
    log "Waiting for Cilium operator deployment to become Ready..."
    kubectl --kubeconfig "${KUBECONFIG_PATH}" -n kube-system rollout status deployment/cilium-operator --timeout=10m
    log "Cilium control plane components are Ready."
}

count_ready_slo_nodes() {
    if ! nodes_output=$(kubectl --kubeconfig "${KUBECONFIG_PATH}" get nodes -l slo=true --no-headers 2>/dev/null); then
        log "kubectl get nodes (slo=true) failed; defaulting slo node count to 0."
        echo 0
        return 0
    fi

    local ready_nodes
    ready_nodes=$(echo "${nodes_output}" | awk '$2 ~ /Ready/ {count++} END {print count+0}')
    echo "${ready_nodes}"
}

run_podstartup() {
    local run_id="$1"
    local node_count="$2"
    local folder="${RESULT_PREFIX}/run-${run_id}"
    log "Starting pod startup test run ${run_id} with ${node_count} nodes..."
    pushd "${PODSTART_DIR}" >/dev/null
    local args=("${folder}" "${KUBECONFIG_PATH}" "${RESOURCE_GROUP}" "${node_count}" "${DEPLOYMENT_SIZE}" "${SCENARIO}")
    if [ -n "${SLO_PATTERN}" ]; then
        args+=("${SLO_PATTERN}")
        if [ -n "${PROM_PATTERN}" ]; then
            args+=("${PROM_PATTERN}")
        fi
    elif [ -n "${PROM_PATTERN}" ]; then
        args+=("" "${PROM_PATTERN}")
    fi
    local env_overrides=()
    if [ -n "${PODS_PER_NODE}" ]; then
        env_overrides+=("CL2_PODS_PER_NODE=${PODS_PER_NODE}")
    fi
    if [ -n "${NAMESPACE_COUNT}" ]; then
        env_overrides+=("CL2_NAMESPACES=${NAMESPACE_COUNT}")
    fi
    if [ -n "${LOAD_THROUGHPUT}" ]; then
        env_overrides+=("CL2_LOAD_TEST_THROUGHPUT=${LOAD_THROUGHPUT}")
    fi
    if [ -n "${DELETE_THROUGHPUT}" ]; then
        env_overrides+=("CL2_DELETE_TEST_THROUGHPUT=${DELETE_THROUGHPUT}")
    fi

    local full_cmd
    if [ "${#env_overrides[@]}" -gt 0 ]; then
        full_cmd=(env "${env_overrides[@]}" "${PODSTART_SCRIPT}" "${args[@]}")
    else
        full_cmd=("${PODSTART_SCRIPT}" "${args[@]}")
    fi
    log "Executing: ${full_cmd[*]}"
    "${full_cmd[@]}"
    popd >/dev/null
    log "Completed pod startup test run ${run_id}."
}

case "${LIFECYCLE}" in
    recreate|reuse|delete-only) ;;
    *)
        echo "Error: Invalid lifecycle option ${LIFECYCLE}" >&2
        exit 1 ;;
 esac

if [ "${LIFECYCLE}" = "delete-only" ]; then
    delete_cluster
    exit 0
fi

run_counter=1
while [ "${run_counter}" -le "${RUNS}" ]; do
    log "=== Run ${run_counter}/${RUNS} ==="
    if [ "${LIFECYCLE}" = "recreate" ]; then
        delete_cluster || true
        create_cluster
    else
        ensure_cluster
    fi

    refresh_credentials
    wait_for_cilium
    node_total="$(wait_for_nodes)"
    slo_ready_total="$(count_ready_slo_nodes)"
    if [ "${slo_ready_total}" -eq 0 ]; then
        log "No Ready nodes labeled slo=true detected; defaulting to total node count ${node_total}."
        slo_ready_total="${node_total}"
    else
        log "Detected ${slo_ready_total} Ready nodes labeled slo=true (total cluster nodes: ${node_total})."
    fi

    log "Launching run-podstartup.sh with slo_ready_nodes=${slo_ready_total}."
    run_podstartup "${run_counter}" "${slo_ready_total}"

    run_counter=$((run_counter + 1))
    if [ "${LIFECYCLE}" = "recreate" ] && [ "${run_counter}" -le "${RUNS}" ]; then
        log "Preparing for next run by removing cluster..."
        delete_cluster || true
    fi

done

if [ "${LIFECYCLE}" = "recreate" ]; then
    log "Final cleanup: deleting cluster after last run."
    delete_cluster || true
fi

log "All runs completed successfully. Results stored under prefix ${RESULT_PREFIX}."
