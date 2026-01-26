#!/bin/bash
set -eu

# Directory Navigation (Moved to top for variable resolution)
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"

# Defaults
CLUSTER_NAME="byocni-cluster"
REGION="canadacentral"
ENABLE_MESH=false
ENABLE_MONITORING=false
ENABLE_KVSTORE=false
ETCD_ENDPOINT=""
ETCD_CERTS_DIR=""
CLUSTER_ID=1
POOL_COUNT=1
NODES_PER_POOL=2
WORKER_VM_SIZE="Standard_D4s_v4"
PROMETHEUS_NODEPOOL_NAME="prometheus"
PROMETHEUS_NODE_COUNT=1
PROMETHEUS_VM_SIZE="Standard_D64s_v3"
MESH_MONITOR_WORKSPACE_ID="/subscriptions/9b8218f9-902a-4d20-a65c-e98acec5362f/resourceGroups/ccp-perf-rg/providers/Microsoft.Monitor/accounts/ccp-perf-amw-1"
NOMESH_MONITOR_WORKSPACE_ID="/subscriptions/9b8218f9-902a-4d20-a65c-e98acec5362f/resourceGroups/ccp-perf-rg/providers/Microsoft.Monitor/accounts/ccp-perf-amw-2"
MONITOR_WORKSPACE_ID="${MONITOR_WORKSPACE_ID:-}"
KUBECONFIG_CLI=""

# Use absolute path for chart directory
CILIUM_CHART_DIR="${CILIUM_CHART_DIR:-$SCRIPT_DIR/../../cilium/install/kubernetes/cilium}"
: "${CILIUM_IMAGE_REPO:=acnpublic.azurecr.io/cilium/cilium}" >/dev/null
: "${CILIUM_IMAGE_TAG:=ces-node-6}" >/dev/null
: "${CLUSTERMESH_IMAGE_REPO:=acnpublic.azurecr.io/cilium/clustermesh-apiserver}" >/dev/null
: "${CLUSTERMESH_IMAGE_TAG:=test2}" >/dev/null


# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -m|--mesh) ENABLE_MESH=true ;;
        -n|--name) CLUSTER_NAME="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        --id) CLUSTER_ID="$2"; shift ;;
        --pools) POOL_COUNT="$2"; shift ;;
        --nodes-per-pool) NODES_PER_POOL="$2"; shift ;;
        -k|--kubeconfig) KUBECONFIG_CLI="$2"; shift ;;
        --enable-monitoring) ENABLE_MONITORING=true ;;
        --enable-kvstore) ENABLE_KVSTORE=true ;;
        --etcd-endpoint) ETCD_ENDPOINT="$2"; shift ;;
        --etcd-certs-dir) ETCD_CERTS_DIR="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Export monitoring flag for downstream scripts
export ENABLE_MONITORING

# Default monitoring workspace selection depends on mesh enablement when caller
# does not explicitly provide MONITOR_WORKSPACE_ID.
if [ "$ENABLE_MONITORING" = true ] && [ -z "${MONITOR_WORKSPACE_ID}" ]; then
    if [ "$ENABLE_MESH" = true ]; then
        MONITOR_WORKSPACE_ID="$MESH_MONITOR_WORKSPACE_ID"
    else
        MONITOR_WORKSPACE_ID="$NOMESH_MONITOR_WORKSPACE_ID"
    fi
fi

if ! [[ "$POOL_COUNT" =~ ^[0-9]+$ ]] || [ "$POOL_COUNT" -lt 1 ]; then
    echo "Error: --pools must be a positive integer."
    exit 1
fi

if ! [[ "$NODES_PER_POOL" =~ ^[0-9]+$ ]] || [ "$NODES_PER_POOL" -lt 1 ]; then
    echo "Error: --nodes-per-pool must be a positive integer."
    exit 1
fi

# Export Variables for Makefile
export CLUSTER="${CLUSTER_NAME}"
export GROUP="${CLUSTER_NAME}-rg"
export REGION="${REGION}"

# Ensure a dedicated kubeconfig path aligned with caller expectations
if [ -n "${KUBECONFIG_CLI}" ]; then
    KUBECONFIG="${KUBECONFIG_CLI}"
elif [ -n "${KUBECONFIG:-}" ]; then
    KUBECONFIG="${KUBECONFIG}"
else
    KUBECONFIG="$(mktemp -t "${CLUSTER}-kubeconfig.XXXXXX")"
fi
mkdir -p "$(dirname "${KUBECONFIG}")"
touch "${KUBECONFIG}"
export KUBECONFIG
echo "Using kubeconfig at ${KUBECONFIG}"

# Get and Export Subscription ID
echo "Getting current subscription..."
SUB_ID=$(az account show --query id -o tsv)
if [ -z "$SUB_ID" ]; then
    echo "Error: Could not determine Azure Subscription ID. Please run 'az login'."
    exit 1
fi
export AZURE_SUBSCRIPTION="${SUB_ID}"
export SUB="${SUB_ID}"

MAKEFILE_DIR="$SCRIPT_DIR/../../cilium-private/clustermesh"

echo "Deploying cluster ${CLUSTER} in ${REGION}..."
echo "Resource Group: ${GROUP}"

# Ensure kube-proxy.json exists
if [ ! -f "$MAKEFILE_DIR/kube-proxy.json" ]; then
    echo "{}" > "$MAKEFILE_DIR/kube-proxy.json"
fi

# add 2 nodepools for AKS cluster

# Ensure chart directory exists (required for both deployments)
if [ ! -d "$CILIUM_CHART_DIR" ] || [ ! -f "$CILIUM_CHART_DIR/Chart.yaml" ]; then
    echo "Error: Cilium chart not found at $CILIUM_CHART_DIR. Set CILIUM_CHART_DIR to a valid chart path." >&2
    exit 1
fi
echo "Using Cilium chart from $CILIUM_CHART_DIR"

# Check if cluster exists to avoid unnecessary waits/upgrades
if az aks show --resource-group "$GROUP" --name "$CLUSTER" &>/dev/null; then
    echo "Cluster $CLUSTER already exists. Skipping creation/upgrade step."
else
    # Run Make
    pushd "$MAKEFILE_DIR" > /dev/null

    # Use local az CLI to avoid Docker volume mount issues with kube-proxy.json
    echo "Running make with local az CLI..."
    if [ "$ENABLE_MESH" = true ]; then
        make overlay-byocni-nokubeproxy-up-mesh AZCLI=az K8S_VER=1.33
    else
        make overlay-byocni-nokubeproxy-up AZCLI=az K8S_VER=1.33
    fi

    popd > /dev/null
fi

# Deploy or discover etcd VM if kvstore mode is enabled
if [ "$ENABLE_KVSTORE" = true ]; then
    # If no etcd endpoint provided, deploy etcd VM or discover existing one
    if [ -z "$ETCD_ENDPOINT" ]; then
        echo "No etcd endpoint provided. Checking for existing etcd VM or deploying new one..."
        
        # Try to find existing etcd VM in the same resource group
        ETCD_VM_NAME="etcd-server"
        ETCD_NIC_NAME="${ETCD_VM_NAME}-nic"
        
        if az vm show -g "$GROUP" -n "$ETCD_VM_NAME" &>/dev/null; then
            echo "Found existing etcd VM: $ETCD_VM_NAME in resource group $GROUP"
            
            # Get the private IP from the existing VM
            ETCD_PRIVATE_IP=$(az network nic show \
                --resource-group "$GROUP" \
                --name "$ETCD_NIC_NAME" \
                --query 'ipConfigurations[0].privateIPAddress' -o tsv)
            
            if [ -z "$ETCD_PRIVATE_IP" ]; then
                echo "Error: Could not retrieve private IP from etcd VM" >&2
                exit 1
            fi
            
            ETCD_ENDPOINT="https://${ETCD_PRIVATE_IP}:2379"
            echo "Using existing etcd at: $ETCD_ENDPOINT"
            
            # Download certificates if not already present
            if [ -z "$ETCD_CERTS_DIR" ]; then
                ETCD_CERTS_DIR="${SCRIPT_DIR}/etcd-certs-${ETCD_VM_NAME}"
            fi
            
            if [ ! -d "$ETCD_CERTS_DIR" ] || [ ! -f "$ETCD_CERTS_DIR/ca.crt" ]; then
                echo "Downloading etcd certificates from existing VM..."
                mkdir -p "$ETCD_CERTS_DIR"
                
                ETCD_PUBLIC_IP=$(az vm show -d -g "$GROUP" -n "$ETCD_VM_NAME" --query publicIps -o tsv)
                if [ -z "$ETCD_PUBLIC_IP" ]; then
                    echo "Error: Could not retrieve public IP from etcd VM for certificate download" >&2
                    exit 1
                fi
                
                ssh -o StrictHostKeyChecking=no "azureuser@${ETCD_PUBLIC_IP}" "sudo cat /etc/etcd/pki/ca.crt" > "${ETCD_CERTS_DIR}/ca.crt"
                ssh -o StrictHostKeyChecking=no "azureuser@${ETCD_PUBLIC_IP}" "sudo cat /etc/etcd/pki/client.crt" > "${ETCD_CERTS_DIR}/client.crt"
                ssh -o StrictHostKeyChecking=no "azureuser@${ETCD_PUBLIC_IP}" "sudo cat /etc/etcd/pki/client.key" > "${ETCD_CERTS_DIR}/client.key"
                
                echo "Certificates downloaded to: $ETCD_CERTS_DIR"
            fi
        else
            echo "No existing etcd VM found. Deploying new etcd server..."
            
            # Determine VNet name from cluster
            # The VNet is created by the Makefile with pattern: ${CLUSTER}-vnet
            VNET_NAME="${CLUSTER}-vnet"
            
            # Call kvstore-cluster.sh to deploy etcd in the same VNet
            KVSTORE_SCRIPT="${SCRIPT_DIR}/kvstore-cluster.sh"
            if [ ! -f "$KVSTORE_SCRIPT" ]; then
                echo "Error: kvstore-cluster.sh not found at $KVSTORE_SCRIPT" >&2
                exit 1
            fi
            
            echo "Deploying etcd VM using kvstore-cluster.sh..."
            "$KVSTORE_SCRIPT" \
                --name "$ETCD_VM_NAME" \
                --resource-group "$GROUP" \
                --region "$REGION" \
                --vnet-name "$VNET_NAME" \
                --subnet-name "etcd-subnet" \
                --subnet-prefix "10.254.0.0/24"
            
            # Get the IP from the newly created VM
            ETCD_PRIVATE_IP=$(az network nic show \
                --resource-group "$GROUP" \
                --name "$ETCD_NIC_NAME" \
                --query 'ipConfigurations[0].privateIPAddress' -o tsv)
            
            if [ -z "$ETCD_PRIVATE_IP" ]; then
                echo "Error: Could not retrieve private IP from newly created etcd VM" >&2
                exit 1
            fi
            
            ETCD_ENDPOINT="https://${ETCD_PRIVATE_IP}:2379"
            
            # Set default certs directory if not provided
            if [ -z "$ETCD_CERTS_DIR" ]; then
                ETCD_CERTS_DIR="${SCRIPT_DIR}/etcd-certs-${ETCD_VM_NAME}"
            fi
            
            echo "etcd deployed successfully at: $ETCD_ENDPOINT"
        fi
    fi
    
    # Validate etcd endpoint is set
    if [ -z "$ETCD_ENDPOINT" ]; then
        echo "Error: Failed to determine etcd endpoint" >&2
        exit 1
    fi
    
    # Validate certificates directory
    if [ -z "$ETCD_CERTS_DIR" ]; then
        echo "Error: --etcd-certs-dir is required when --enable-kvstore is set" >&2
        echo "Example: --etcd-certs-dir ./etcd-certs-etcd-server" >&2
        exit 1
    fi
    if [ ! -d "$ETCD_CERTS_DIR" ]; then
        echo "Error: etcd certificates directory not found: $ETCD_CERTS_DIR" >&2
        exit 1
    fi
    if [ ! -f "$ETCD_CERTS_DIR/ca.crt" ] || [ ! -f "$ETCD_CERTS_DIR/client.crt" ] || [ ! -f "$ETCD_CERTS_DIR/client.key" ]; then
        echo "Error: Missing etcd certificates in $ETCD_CERTS_DIR" >&2
        echo "Required files: ca.crt, client.crt, client.key" >&2
        exit 1
    fi
    
    echo "Using external etcd at: $ETCD_ENDPOINT"
    echo "Using certificates from: $ETCD_CERTS_DIR"
fi

# Get Credentials
echo "Getting credentials into ${KUBECONFIG}..."
for attempt in {1..3}; do
    if az aks get-credentials -n "$CLUSTER" -g "$GROUP" --overwrite-existing --file "$KUBECONFIG"; then
        break
    fi
    if [ "$attempt" -lt 3 ]; then
        echo "az aks get-credentials attempt ${attempt} failed; retrying in 60s..."
        sleep 60
    else
        echo "Error: az aks get-credentials failed after 3 attempts." >&2
        exit 1
    fi
done

# Note: If etcd VM is deployed automatically, it will be created in the same VNet as AKS
# If you provide --etcd-endpoint manually, ensure the etcd VM is accessible from the cluster
if [ "$ENABLE_KVSTORE" = true ]; then
    ETCD_IP=$(echo "$ETCD_ENDPOINT" | sed -E 's|https?://([^:]+):.*|\1|')
    echo "etcd endpoint configured: $ETCD_ENDPOINT (IP: $ETCD_IP)"
fi

# Prepare Cilium Install Flags
CILIUM_FLAGS=(
    --namespace kube-system
    --set image.repository="${CILIUM_IMAGE_REPO}"
    --set image.tag="${CILIUM_IMAGE_TAG}"
    --set image.useDigest=false
    --set azure.resourceGroup="${GROUP}"
    --set aksbyocni.enabled=false
    --set nodeinit.enabled=false
    --set hubble.enabled=false
    --set envoy.enabled=false
    --set cluster.id="${CLUSTER_ID}"
    --set cluster.name="${CLUSTER}"
    --set prometheus.enabled=true
    --set operator.prometheus.enabled=true
    --set endpointRoutes.enabled=true
    --set ciliumEndpointSlice.enabled=true
    --set enable-ipv4=true
    --set kubeProxyReplacement=true
    --set kubeProxyReplacementHealthzBindAddr='0.0.0.0:10256'
    --set extraArgs="{--install-iptables-rules=true}"
    --set endpointHealthChecking.enabled=false
    --set cni.exclusive=false
    --set bpf.enableTCX=false
    --set bpf.hostLegacyRouting=true
    --set l7Proxy=true
    --set sessionAffinity=true
    --set ipam.operator.clusterPoolIPv4PodCIDRList=172.16.0.0/12
    --set ipam.operator.clusterPoolIPv4MaskSize=25
    --set operator.unmanagedPodWatcher.intervalSeconds=15s
    --set enableIPv4Masquerade=true
    --set bpf.mapDynamicSizeRatio=0.01
)

# Add kvstore configuration if enabled
if [ "$ENABLE_KVSTORE" = true ]; then
    echo "Configuring Cilium with external etcd kvstore..."
    
    # Create etcd secrets before installing Cilium
    if ! kubectl --kubeconfig "${KUBECONFIG}" -n kube-system get secret cilium-etcd-secrets >/dev/null 2>&1; then
        echo "Creating Kubernetes secret for etcd certificates..."
        kubectl --kubeconfig "${KUBECONFIG}" create secret generic cilium-etcd-secrets \
            --from-file=etcd-client-ca.crt="${ETCD_CERTS_DIR}/ca.crt" \
            --from-file=etcd-client.key="${ETCD_CERTS_DIR}/client.key" \
            --from-file=etcd-client.crt="${ETCD_CERTS_DIR}/client.crt" \
            -n kube-system
    else
        echo "etcd certificates secret already exists; skipping creation."
    fi
    
    # Add kvstore flags to Cilium configuration
    # In kvstore mode, identities are stored in etcd, not as CRDs
    CILIUM_FLAGS+=(
        --set etcd.enabled=true
        --set etcd.ssl=true
        --set "etcd.endpoints[0]=${ETCD_ENDPOINT}"
        --set identityAllocationMode=kvstore
    )
fi

if kubectl --kubeconfig "${KUBECONFIG}" -n kube-system get daemonset cilium >/dev/null 2>&1; then
    echo "Cilium daemonset already exists; skipping install."
else
    echo "Installing Cilium..."
    cilium install --chart-directory "${CILIUM_CHART_DIR}" "${CILIUM_FLAGS[@]}"
fi

if [ "$ENABLE_MONITORING" = true ]; then
    if [ -z "${MONITOR_WORKSPACE_ID:-}" ]; then
        echo "Error: MONITOR_WORKSPACE_ID must be set when enabling monitoring." >&2
        exit 1
    fi

    current_monitor_enabled=$(az aks show \
        --resource-group "$GROUP" \
        --name "$CLUSTER" \
        --query 'azureMonitorProfile.metrics.enabled' \
        -o tsv 2>/dev/null || echo "")

    if [ "${current_monitor_enabled,,}" = "true" ]; then
        echo "Azure Monitor metrics already enabled for $CLUSTER; skipping aks update."
    else
        echo "Enabling Azure Monitor metrics for $CLUSTER..."
        az aks update \
            --resource-group "$GROUP" \
            --name "$CLUSTER" \
            --enable-azure-monitor-metrics \
            --azure-monitor-workspace-resource-id "$MONITOR_WORKSPACE_ID"
    fi

    echo "Applying minimal AMA metrics scrape settings..."
    kubectl --context "${CLUSTER}" apply -f - <<'EOF'
apiVersion: v1
kind: ConfigMap
metadata:
  name: ama-metrics-settings-configmap
  namespace: kube-system
data:
    default-scrape-settings-enabled: |
        # Disable all default scrapers except apiserver
        kubelet = false
        cadvisor = false
        nodeexporter = false
        kube-state-metrics = false
        coredns = false
        kubeproxy = false
        apiserver = true
        controlplane-apiserver = false
    default-targets-metrics-keep-list: |
        apiserver = "process_cpu_seconds_total|process_resident_memory_bytes|apiserver_request_duration_seconds_bucket|apiserver_request_total|apiserver_cache_list_returned_objects_total|apiserver_cache_list_fetched_objects_total"
    default-targets-scrape-interval-settings: |
        apiserver = "30s"
    pod-annotation-based-scraping: |
        # Disable all pod annotation scraping
        podannotationnamespaceregex = "^$"
EOF

    echo "Waiting for PodMonitor CRD to become available..."
    for attempt in {1..30}; do
        if kubectl --context "${CLUSTER}" get crd podmonitors.azmonitoring.coreos.com >/dev/null 2>&1; then
            break
        fi
        echo "PodMonitor CRD not ready yet (attempt ${attempt}/30); retrying in 10s..."
        sleep 10
    done

    if ! kubectl --context "${CLUSTER}" get crd podmonitors.azmonitoring.coreos.com >/dev/null 2>&1; then
        echo "PodMonitor CRD unavailable; skipping PodMonitor configuration to keep monitoring idempotent." >&2
    else
        echo "Reconciling PodMonitor for Cilium agents..."
        kubectl --context "${CLUSTER}" apply -f - <<EOF
apiVersion: azmonitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cilium-agent
  namespace: kube-system
  labels:
    prometheus.azure.com/cluster: "${CLUSTER}"
spec:
  sampleLimit: 500
  namespaceSelector:
    matchNames:
      - kube-system
  selector:
    matchLabels:
      k8s-app: cilium
  podMetricsEndpoints:
    - port: prometheus
      interval: 30s
      path: /metrics
      honorLabels: true
      metricRelabelings:
        - sourceLabels: [__name__]
          action: keep
          regex: "^(cilium_process_.*|cilium_endpoint_regeneration_time_stats_seconds_.*|cilium_agent_api_process_time_seconds_.*|cilium_k8s_client_api_calls_total|cilium_endpoint_state)$"
  podTargetLabels:
    - k8s-app

EOF

                if [ "$ENABLE_MESH" = true ]; then
                        echo "Reconciling PodMonitor for clustermesh apiserver..."
                        cat <<'EOF' | kubectl --context "${CLUSTER}" apply -f -
apiVersion: azmonitoring.coreos.com/v1
kind: PodMonitor
metadata:
  name: cilium-clustermesh-apiserver
  namespace: kube-system
  labels:
    k8s-app: clustermesh-apiserver-pods
spec:
  sampleLimit: 500
  selector:
    matchLabels:
      k8s-app: clustermesh-apiserver
  namespaceSelector:
    matchNames:
      - kube-system
  podMetricsEndpoints:
    - port: apiserv-metrics
      interval: 30s
      path: /metrics
      honorLabels: true
  podTargetLabels:
    - k8s-app
EOF
                fi
    fi
fi

if [ "$ENABLE_MESH" = true ]; then
    echo "Configuring clustermesh prerequisites..."
    if ! kubectl --context "${CLUSTER}" -n kube-system get configmap clustermesh-remote-users &>/dev/null; then
        kubectl --context "${CLUSTER}" -n kube-system create configmap clustermesh-remote-users \
            --from-literal=.keep=""
    fi
    
    kubectl --context "${CLUSTER}" -n kube-system label configmap clustermesh-remote-users \
        app.kubernetes.io/managed-by=Helm \
        app.kubernetes.io/part-of=cilium \
        --overwrite
    
    kubectl --context "${CLUSTER}" -n kube-system annotate configmap clustermesh-remote-users \
        meta.helm.sh/release-name=cilium \
        meta.helm.sh/release-namespace=kube-system \
        --overwrite

    echo "Enabling clustermesh control plane..."
    cilium clustermesh enable --context "${CLUSTER}" --enable-kvstoremesh --service-type NodePort
    echo "Waiting for clustermesh-apiserver to be ready..."
    kubectl --context "${CLUSTER}" -n kube-system rollout status deployment/clustermesh-apiserver --timeout=600s

    echo "Updating clustermesh-apiserver image..."
    kubectl --context "${CLUSTER}" set image deployment/clustermesh-apiserver \
        -n kube-system \
        apiserver="${CLUSTERMESH_IMAGE_REPO}:${CLUSTERMESH_IMAGE_TAG}"
    
    kubectl --context "${CLUSTER}" rollout restart deployment/clustermesh-apiserver -n kube-system
    
    echo "Waiting for clustermesh-apiserver rollout..."
    kubectl --context "${CLUSTER}" -n kube-system rollout status deployment/clustermesh-apiserver --timeout=600s

    echo "Discovering service endpoint..."
    CLUSTERMESH_SVC_IP=$(kubectl --context "${CLUSTER}" -n kube-system \
        get svc clustermesh-apiserver -o jsonpath='{.spec.clusterIP}')

    echo "Regenerating etcd certificates..."
    # Create temporary directory for certificate generation
    TEMP_CERT_DIR=$(mktemp -d)
    
    # Get CA certificate and key
    kubectl --context "${CLUSTER}" -n kube-system get secret cilium-ca \
        -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TEMP_CERT_DIR}/ca.crt"
    kubectl --context "${CLUSTER}" -n kube-system get secret cilium-ca \
        -o jsonpath='{.data.ca\.key}' | base64 -d > "${TEMP_CERT_DIR}/ca.key"
    
    # Create OpenSSL config with cluster IP and pod IP
    cat > "${TEMP_CERT_DIR}/openssl.cnf" <<EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = clustermesh-apiserver.kube-system.svc.cluster.local

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = clustermesh-apiserver.kube-system.svc.cluster.local
DNS.2 = clustermesh-apiserver.kube-system.svc
DNS.3 = clustermesh-apiserver.kube-system
DNS.4 = clustermesh-apiserver
DNS.5 = localhost
DNS.6 = *.mesh.cilium.io
IP.1 = 127.0.0.1
IP.2 = ::1
IP.3 = ${CLUSTERMESH_SVC_IP}
EOF
    
    # Generate new server key and certificate
    openssl genrsa -out "${TEMP_CERT_DIR}/tls.key" 2048
    openssl req -new -key "${TEMP_CERT_DIR}/tls.key" \
        -out "${TEMP_CERT_DIR}/tls.csr" -config "${TEMP_CERT_DIR}/openssl.cnf"
    openssl x509 -req -in "${TEMP_CERT_DIR}/tls.csr" \
        -CA "${TEMP_CERT_DIR}/ca.crt" \
        -CAkey "${TEMP_CERT_DIR}/ca.key" \
        -CAcreateserial \
        -out "${TEMP_CERT_DIR}/tls.crt" \
        -days 3650 \
        -extensions v3_req \
        -extfile "${TEMP_CERT_DIR}/openssl.cnf"
    
    # Delete existing secret and recreate
    kubectl --context "${CLUSTER}" -n kube-system delete secret clustermesh-apiserver-server-cert --ignore-not-found=true
    
    # Update the secret
    kubectl --context "${CLUSTER}" -n kube-system create secret generic clustermesh-apiserver-server-cert \
        --from-file=tls.crt="${TEMP_CERT_DIR}/tls.crt" \
        --from-file=tls.key="${TEMP_CERT_DIR}/tls.key" \
        --from-file=ca.crt="${TEMP_CERT_DIR}/ca.crt"
    
    kubectl --context "${CLUSTER}" -n kube-system rollout restart deployment/clustermesh-apiserver
    kubectl --context "${CLUSTER}" -n kube-system rollout status deployment/clustermesh-apiserver --timeout=600s
    rm -rf "${TEMP_CERT_DIR}"

    echo "Extracting admin certificates..."
    LOCAL_CA_CRT=$(kubectl --context "${CLUSTER}" -n kube-system get secret cilium-ca -o jsonpath='{.data.ca\.crt}')
    LOCAL_CLIENT_KEY=$(kubectl --context "${CLUSTER}" -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\.key}')
    LOCAL_CLIENT_CRT=$(kubectl --context "${CLUSTER}" -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\.crt}')
    
    kubectl --context "${CLUSTER}" -n kube-system create secret generic clustermesh-apiserver-local-cert \
        --from-literal=tls.key="$(echo ${LOCAL_CLIENT_KEY} | base64 -d)" \
        --from-literal=tls.crt="$(echo ${LOCAL_CLIENT_CRT} | base64 -d)" \
        --from-literal=ca.crt="$(echo ${LOCAL_CA_CRT} | base64 -d)" \
        --dry-run=client -o yaml | kubectl --context "${CLUSTER}" apply -f -

    echo "Enabling centralized control plane (Upgrade)..."
    cilium upgrade --context "${CLUSTER}" \
        --namespace kube-system \
        --chart-directory "${CILIUM_CHART_DIR}" \
        --reuse-values \
        --set azure.resourceGroup="${GROUP}" \
        --set clustermesh.config.enabled=true \
        --set clustermesh.config.localCluster.ips[0]="${CLUSTERMESH_SVC_IP}" \
        --set clustermesh.config.localCluster.tls.caCert="${LOCAL_CA_CRT}" \
        --set clustermesh.config.localCluster.tls.key="${LOCAL_CLIENT_KEY}" \
        --set clustermesh.config.localCluster.tls.cert="${LOCAL_CLIENT_CRT}" \
        --set clustermesh.readCiliumEndpointSlicesFromEtcd=true

    echo "Restarting Cilium agents..."
    kubectl --context "${CLUSTER}" -n kube-system rollout restart daemonset/cilium
    kubectl --context "${CLUSTER}" -n kube-system rollout status daemonset/cilium --timeout=15m

    echo "Converting clustermesh to hostNetwork deployment..."
    SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
    "${SCRIPT_DIR}/setup-clustermesh.sh" \
        --cluster "${CLUSTER}" \
        --clustermesh-image "${CLUSTERMESH_IMAGE_REPO}" \
        --clustermesh-tag "${CLUSTERMESH_IMAGE_TAG}" \
        --cilium-image "${CILIUM_IMAGE_REPO}" \
        --cilium-tag "${CILIUM_IMAGE_TAG}"
    
fi

echo "Reconciling worker node pools ($POOL_COUNT requested)..."
for (( pool_index=1; pool_index<=POOL_COUNT; pool_index++ )); do
    pool_name="userpool${pool_index}"
    echo "Ensuring worker node pool $pool_name..."
    if az aks nodepool show --resource-group "$GROUP" --cluster-name "$CLUSTER" --name "$pool_name" &>/dev/null; then
        echo "Updating labels and taints on $pool_name..."
        az aks nodepool update \
            --resource-group "$GROUP" \
            --cluster-name "$CLUSTER" \
            --name "$pool_name" \
            --labels slo=true \
            --node-taints slo=true:NoSchedule

        current_count=$(az aks nodepool show --resource-group "$GROUP" --cluster-name "$CLUSTER" --name "$pool_name" --query count -o tsv)
        if [ "$current_count" != "$NODES_PER_POOL" ]; then
            echo "Scaling $pool_name from $current_count to $NODES_PER_POOL nodes..."
            az aks nodepool scale \
                --resource-group "$GROUP" \
                --cluster-name "$CLUSTER" \
                --name "$pool_name" \
                --node-count "$NODES_PER_POOL"
        fi
    else
        echo "Creating worker node pool $pool_name..."
        az aks nodepool add \
            --resource-group "$GROUP" \
            --cluster-name "$CLUSTER" \
            --name "$pool_name" \
            --node-count "$NODES_PER_POOL" \
            --node-vm-size "$WORKER_VM_SIZE" \
            --labels slo=true \
            --node-taints slo=true:NoSchedule \
            --mode User
    fi
done

echo "Ensuring Prometheus node pool ($PROMETHEUS_NODEPOOL_NAME)..."
prom_pool_exists=false
if az aks nodepool show --resource-group "$GROUP" --cluster-name "$CLUSTER" --name "$PROMETHEUS_NODEPOOL_NAME" &>/dev/null; then
    prom_pool_exists=true
fi

if [ "$prom_pool_exists" = true ]; then
    echo "Updating label on Prometheus pool..."
    az aks nodepool update --resource-group "$GROUP" --cluster-name "$CLUSTER" --name "$PROMETHEUS_NODEPOOL_NAME" --labels prometheus=true

    current_prom_count=$(az aks nodepool show --resource-group "$GROUP" --cluster-name "$CLUSTER" --name "$PROMETHEUS_NODEPOOL_NAME" --query count -o tsv)
    if [ "$current_prom_count" != "$PROMETHEUS_NODE_COUNT" ]; then
        echo "Scaling Prometheus pool from $current_prom_count to $PROMETHEUS_NODE_COUNT nodes..."
        az aks nodepool scale --resource-group "$GROUP" --cluster-name "$CLUSTER" --name "$PROMETHEUS_NODEPOOL_NAME" --node-count "$PROMETHEUS_NODE_COUNT"
    fi
else
    echo "Creating Prometheus node pool..."
    az aks nodepool add --resource-group "$GROUP" --cluster-name "$CLUSTER" --name "$PROMETHEUS_NODEPOOL_NAME" --node-count "$PROMETHEUS_NODE_COUNT" --node-vm-size "$PROMETHEUS_VM_SIZE" --labels prometheus=true --mode User
fi

echo "Cluster deployment and Cilium installation complete."
kubectl rollout restart daemonset cilium -n kube-system
cilium status --context "${CLUSTER}" --wait
sleep 1m
