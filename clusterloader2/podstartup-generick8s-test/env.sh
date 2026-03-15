#!/bin/bash
# Pod Startup Analysis - Generic Kubernetes Environment Configuration
# Source this file before running clusterloader2:
#   source podstartup-generick8s-test/env.sh
#   ./podstartup-generick8s-test/run.sh
# Or manually run the go command after sourcing.

# =============================================================================
# CLUSTER CONFIGURATION - MODIFY THESE FOR YOUR CLUSTER
# =============================================================================

# Number of worker nodes in your cluster (REQUIRED - adjust to match your cluster)
# 500-node scale target (25k pods with 50 pods per node)
export CL2_NODES="${CL2_NODES:-500}"

# Path to your kubeconfig file (can be overridden via run.sh -k flag)
export KUBECONFIG="${KUBECONFIG:-$HOME/.kube/config}"

# =============================================================================
# POD DISTRIBUTION
# =============================================================================

# Number of pods to schedule per node
# Scale targets: 10 nodes=50, 100 nodes=50, 500 nodes=50, 1000 nodes=40
export CL2_PODS_PER_NODE="${CL2_PODS_PER_NODE:-50}"

# Number of pod replicas per deployment
# Lower value = more deployments with fewer replicas each
# Examples:
#   500-node:  10 pods/deployment × 50 namespaces × 50 deployments/namespace = 25,000 pods
#   1000-node: 10 pods/deployment × 100 namespaces × 40 deployments/namespace = 40,000 pods
export CL2_DEPLOYMENT_SIZE="${CL2_DEPLOYMENT_SIZE:-10}"

# Number of namespaces to create (overridden via CL2_NAMESPACES in config.yaml)
export CL2_NAMESPACES="${CL2_NAMESPACES:-50}"

# Number of deployments per namespace
# Examples: 10 nodes=1, 100 nodes=5, 500 nodes=10, 1000 nodes=40
export CL2_DEPLOYMENTS_PER_NS="${CL2_DEPLOYMENTS_PER_NS:-10}"

# =============================================================================
# THROUGHPUT SETTINGS
# =============================================================================

# Pods created per second (scale down for smaller clusters)
# Recommended: 10 nodes=20, 100 nodes=50, 500 nodes=100, 1000 nodes=100
export CL2_LOAD_TEST_THROUGHPUT="${CL2_LOAD_TEST_THROUGHPUT:-50}"

# Pods deleted per second (defaults to creation rate)
export CL2_DELETE_TEST_THROUGHPUT="${CL2_DELETE_TEST_THROUGHPUT:-$CL2_LOAD_TEST_THROUGHPUT}"

# =============================================================================
# POD RESOURCE REQUESTS
# =============================================================================

# CPU request in millicores per pod
# Formula: (NODE_CPU_CORES × 0.87 × 1000) ÷ CL2_PODS_PER_NODE
# Examples for PODS_PER_NODE=50:
#   4-core node:  (4 × 0.87 × 1000) ÷ 50 = 69m
#   8-core node:  (8 × 0.87 × 1000) ÷ 50 = 139m
#   16-core node: (16 × 0.87 × 1000) ÷ 50 = 278m
# Examples for PODS_PER_NODE=100:
#   4-core node:  34m
#   8-core node:  69m
export CL2_LATENCY_POD_CPU="${CL2_LATENCY_POD_CPU:-69}"

# Memory request in MB per pod
export CL2_LATENCY_POD_MEMORY="${CL2_LATENCY_POD_MEMORY:-50}"

# =============================================================================
# TIMEOUTS AND THRESHOLDS
# =============================================================================

# Maximum time to wait for pod operations (increase for larger clusters)
# Recommended: 10 nodes=10m, 100 nodes=20m, 500 nodes=30m, 1000 nodes=40m
export CL2_OPERATION_TIMEOUT="${CL2_OPERATION_TIMEOUT:-30m}"

# Pod startup latency SLO threshold (triggers violation if exceeded)
# Recommended: 10 nodes=30s, 100 nodes=60s, 500 nodes=120s, 1000 nodes=3m
export CL2_POD_STARTUP_LATENCY_THRESHOLD="${CL2_POD_STARTUP_LATENCY_THRESHOLD:-120s}"

# Number of create/delete cycles to run
export CL2_REPEATS="${CL2_REPEATS:-5}"

# Disable in-cluster network latency probes (ping client/server)
export CL2_ENABLE_IN_CLUSTER_NETWORK_LATENCY=false

# =============================================================================
# PROMETHEUS CONFIGURATION (Fixed for dedicated 8-core/32GB monitoring node)
# =============================================================================

# Prometheus resources are optimized for a dedicated monitoring node with:
#   CPU: 8 cores, Memory: 32GB, Pods: 10
# These settings work for 10, 100, and 1000 node tests.
#
# The Prometheus pod will schedule on nodes labeled: prometheus=true
# Ensure your monitoring node is labeled: kubectl label node <node> prometheus=true

# Resource scaling - tuned for 32GB node to handle up to 1000 nodes
# Memory: ~28GB allocated (SCALE * (1 + Nodes/1000) Gi)
# CPU: ~6 cores allocated (200 + SCALE * 500 * Nodes/1000 millicores)
export CL2_PROMETHEUS_MEMORY_LIMIT_FACTOR=14
export CL2_PROMETHEUS_MEMORY_SCALE_FACTOR=14
export CL2_PROMETHEUS_CPU_SCALE_FACTOR=12

# Master scraping settings (kubeadm control plane typically exposes apiserver on 6443,
# and scheduler/controller-manager are bound to 127.0.0.1, so scrape apiserver only).
# NOTE: These variables are consumed directly by the Prometheus manifests (no CL2_ prefix).
export PROMETHEUS_APISERVER_SCRAPE_PORT=6443
export PROMETHEUS_SCRAPE_APISERVER_ONLY=true
export PROMETHEUS_SCRAPE_MASTER_KUBELETS=true
export PROMETHEUS_SCRAPE_KUBE_PROXY=false
export PROMETHEUS_SCRAPE_KUBE_DNS=false
export PROMETHEUS_SCRAPE_COREDNS=false

# Disable Prometheus PVC (uses emptyDir instead)
# Enable only if you have a working storage class (e.g., on GKE/AKS/EKS)
export CL2_PROMETHEUS_PVC_ENABLED=false

# Keep Prometheus running after test (useful for debugging/analysis)
# Set to true to tear down Prometheus after test completes
export CL2_TEAR_DOWN_PROMETHEUS=false

# =============================================================================
# CILIUM METRICS (Disabled by default - enable when needed for Cilium analysis)
# =============================================================================

# Set to true to collect Cilium-specific metrics (CES delay, endpoint propagation, etc.)
export CL2_CILIUM_METRICS_ENABLED="${CL2_CILIUM_METRICS_ENABLED:-true}"
export CL2_PROMETHEUS_SCRAPE_CILIUM_OPERATOR="${CL2_PROMETHEUS_SCRAPE_CILIUM_OPERATOR:-true}"
export CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT="${CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT:-true}"
export CL2_PROMETHEUS_SCRAPE_CLUSTERMESH_APISERVER="${CL2_PROMETHEUS_SCRAPE_CLUSTERMESH_APISERVER:-false}"

# =============================================================================
# KUBELET METRICS (Disabled - enable if kubelet SLI metrics needed)
# =============================================================================

export CL2_KUBELET_METRICS_ENABLED=true
export PROMETHEUS_SCRAPE_KUBELETS=true

# =============================================================================
# CLEANUP SETTINGS
# =============================================================================

export DELETE_AUTOMANAGED_NAMESPACES="${DELETE_AUTOMANAGED_NAMESPACES:-true}"

# =============================================================================
# CLUSTERLOADER2 COMMAND OPTIONS
# =============================================================================

# Provider: use 'local' for generic k8s, 'skeleton' for minimal
export CL2_PROVIDER="${CL2_PROVIDER:-local}"

# Report directory (auto-generated with timestamp)
export CL2_REPORT_DIR="${CL2_REPORT_DIR:-results/generic-k8s-test/$(date +%Y%m%dT%H%M)}"

# Verbosity level (0-4, higher = more verbose)
export CL2_VERBOSITY="${CL2_VERBOSITY:-2}"

# =============================================================================
# HELPER FUNCTIONS
# =============================================================================

# Print current configuration
cl2_show_config() {
    echo "=============================================="
    echo "Pod Startup Analysis - Current Configuration"
    echo "=============================================="
    echo ""
    echo "Cluster:"
    echo "  KUBECONFIG:                    $KUBECONFIG"
    echo "  CL2_NODES:                     $CL2_NODES"
    echo "  CL2_PROVIDER:                  $CL2_PROVIDER"
    echo ""
    echo "Pod Distribution:"
    echo "  CL2_PODS_PER_NODE:             $CL2_PODS_PER_NODE"
    echo "  CL2_DEPLOYMENT_SIZE:           $CL2_DEPLOYMENT_SIZE"
    echo "  Total Pods:                    $((CL2_NODES * CL2_PODS_PER_NODE))"
    echo ""
    echo "Throughput:"
    echo "  CL2_LOAD_TEST_THROUGHPUT:      $CL2_LOAD_TEST_THROUGHPUT pods/sec"
    echo "  CL2_DELETE_TEST_THROUGHPUT:    $CL2_DELETE_TEST_THROUGHPUT pods/sec"
    echo "  Estimated Saturation Time:     $((CL2_NODES * CL2_PODS_PER_NODE / CL2_LOAD_TEST_THROUGHPUT))s"
    echo ""
    echo "Resources:"
    echo "  CL2_LATENCY_POD_CPU:           ${CL2_LATENCY_POD_CPU}m"
    echo "  CL2_LATENCY_POD_MEMORY:        ${CL2_LATENCY_POD_MEMORY}M"
    echo ""
    echo "Timeouts:"
    echo "  CL2_OPERATION_TIMEOUT:         $CL2_OPERATION_TIMEOUT"
    echo "  CL2_POD_STARTUP_LATENCY_THRESHOLD: $CL2_POD_STARTUP_LATENCY_THRESHOLD"
    echo "  CL2_REPEATS:                   $CL2_REPEATS"
    echo ""
    echo "Metrics:"
    echo "  CL2_CILIUM_METRICS_ENABLED:    $CL2_CILIUM_METRICS_ENABLED"
    echo "  CL2_KUBELET_METRICS_ENABLED:   $CL2_KUBELET_METRICS_ENABLED"
    echo ""
    echo "Output:"
    echo "  CL2_REPORT_DIR:                $CL2_REPORT_DIR"
    echo "=============================================="
}

# Label all worker nodes for SLO workloads
cl2_label_nodes() {
    echo "Labeling all nodes with slo=true..."
    kubectl get nodes --no-headers -o custom-columns=":metadata.name" | \
        xargs -I {} kubectl label node {} slo=true --overwrite
    echo "Adding slo=true:NoSchedule taint..."
    kubectl get nodes --no-headers -o custom-columns=":metadata.name" | \
        xargs -I {} kubectl taint node {} slo=true:NoSchedule --overwrite 2>/dev/null || true
    echo "Done. Current node labels:"
    kubectl get nodes -L slo
}

# Remove SLO labels and taints
cl2_unlabel_nodes() {
    echo "Removing slo labels and taints from all nodes..."
    kubectl get nodes --no-headers -o custom-columns=":metadata.name" | \
        xargs -I {} kubectl label node {} slo- --overwrite 2>/dev/null || true
    kubectl get nodes --no-headers -o custom-columns=":metadata.name" | \
        xargs -I {} kubectl taint node {} slo=true:NoSchedule- 2>/dev/null || true
    echo "Done."
}

# Print the clusterloader2 command
cl2_print_command() {
    echo ""
    echo "Run this command from the clusterloader2 directory:"
    echo ""
    echo "go run cmd/clusterloader.go \\"
    echo "  --kubeconfig $KUBECONFIG \\"
    echo "  --report-dir \"$CL2_REPORT_DIR\" \\"
    echo "  --testconfig podstartupanalysis/config.yaml \\"
    echo "  --provider $CL2_PROVIDER \\"
    echo "  --prometheus-scrape-kubelets=false \\"
    echo "  --prometheus-scrape-master-kubelets=true \\" 
    echo "  --prometheus-ready-timeout=15m \\"
    echo "  --enable-prometheus-server=true \\"
    echo "  --v=$CL2_VERBOSITY \\"
    echo "  --experimental-prometheus-snapshot-to-report-dir=true \\"
    echo "  --tear-down-prometheus-server=$CL2_TEAR_DOWN_PROMETHEUS"
    echo ""
}

# =============================================================================
# AUTO-DISPLAY CONFIG ON SOURCE
# =============================================================================

echo ""
echo "✅ Environment loaded for Pod Startup Analysis test"
echo ""
echo "Quick commands:"
echo "  cl2_show_config    - Show current configuration"
echo "  cl2_label_nodes    - Label nodes with slo=true (required before test)"
echo "  cl2_unlabel_nodes  - Remove slo labels after testing"
echo "  cl2_print_command  - Print the clusterloader2 command to run"
echo ""
echo "To modify settings, export variables BEFORE sourcing, e.g.:"
echo "  export CL2_NODES=100 && source podstartup-generick8s-test/env.sh"
echo ""
