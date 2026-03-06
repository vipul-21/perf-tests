#!/bin/bash
# Pod Startup Analysis - Run Script for Generic Kubernetes
# Usage: ./podstartup-generick8s-test/run.sh [OPTIONS] [TEST_NAME]
#
# Options:
#   -k, --kubeconfig PATH     Path to kubeconfig file
#   -n, --nodes NUM           Number of nodes in cluster
#   -p, --pods-per-node NUM   Pods per node (default: 50, use 40 for 1000-node)
#   -d, --deployment-size NUM Pods per deployment (default: 10)
#   -N, --namespaces NUM      Number of namespaces (default: 50)
#   -D, --deployments-per-ns  Deployments per namespace (default: 10)
#   -h, --help                Show this help message
#
# Scale Presets (based on perf-scale-plan.txt):
#   10 nodes:   -n 10 -p 50 -N 10 -D 1
#   100 nodes:  -n 100 -p 50 -N 20 -D 5
#   500 nodes:  -n 500 -p 50 -N 50 -D 10
#   1000 nodes: -n 1000 -p 40 -N 100 -D 40
#
# Examples:
#   ./run.sh my-test
#   ./run.sh -n 1000 -p 40 -N 100 -D 40 1000-node-test

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CL2_DIR="$(dirname "$SCRIPT_DIR")"

# Parse command line arguments
while [[ $# -gt 0 ]]; do
    case $1 in
        -k|--kubeconfig)
            export KUBECONFIG="$2"
            shift 2
            ;;
        -n|--nodes)
            export CL2_NODES="$2"
            shift 2
            ;;
        -p|--pods-per-node)
            export CL2_PODS_PER_NODE="$2"
            shift 2
            ;;
        -d|--deployment-size)
            export CL2_DEPLOYMENT_SIZE="$2"
            shift 2
            ;;
        -N|--namespaces)
            export CL2_NAMESPACES="$2"
            shift 2
            ;;
        -D|--deployments-per-ns)
            export CL2_DEPLOYMENTS_PER_NS="$2"
            shift 2
            ;;
        -h|--help)
            echo "Usage: $0 [OPTIONS] [TEST_NAME]"
            echo ""
            echo "Options:"
            echo "  -k, --kubeconfig PATH     Path to kubeconfig file"
            echo "  -n, --nodes NUM           Number of nodes in cluster"
            echo "  -p, --pods-per-node NUM   Pods per node (default: 50, use 40 for 1000-node)"
            echo "  -d, --deployment-size NUM Pods per deployment (default: 10)"
            echo "  -N, --namespaces NUM      Number of namespaces (default: 50)"
            echo "  -D, --deployments-per-ns  Deployments per namespace (default: 10)"
            echo "  -h, --help                Show this help message"
            echo ""
            echo "Scale Presets (total pods = nodes × pods-per-node):"
            echo "  10 nodes (500 pods):     -n 10 -p 50 -N 10 -D 1"
            echo "  100 nodes (5000 pods):   -n 100 -p 50 -N 20 -D 5"
            echo "  500 nodes (25000 pods):  -n 500 -p 50 -N 50 -D 10"
            echo "  1000 nodes (40000 pods): -n 1000 -p 40 -N 100 -D 40"
            echo ""
            echo "Examples:"
            echo "  $0 my-test"
            echo "  $0 -n 1000 -p 40 -N 100 -D 40 1000-node-test"
            exit 0
            ;;
        -*)
            echo "Unknown option: $1"
            exit 1
            ;;
        *)
            TEST_NAME="$1"
            shift
            ;;
    esac
done

# Source environment (after parsing args so overrides take effect)
echo "Sourcing environment from $SCRIPT_DIR/env.sh..."
source "$SCRIPT_DIR/env.sh"

# Test name for results folder (default if not set via args)
TEST_NAME="${TEST_NAME:-generic-k8s-test}"

# Update report directory with test name
export CL2_REPORT_DIR="results/${TEST_NAME}/$(date +%Y%m%dT%H%M)"

echo ""
echo "=============================================="
echo "Pod Startup Analysis - Generic Kubernetes"
echo "=============================================="
echo ""

# Show configuration
cl2_show_config

echo ""
echo "Press Enter to continue or Ctrl+C to abort..."
read -r

# Auto-detect prom node name if not set
if [[ -z "${CL2_PROM_NODE_NAME:-}" ]]; then
  CL2_PROM_NODE_NAME=$(kubectl --kubeconfig "$KUBECONFIG" get nodes -l prometheus=true --no-headers -o custom-columns=':metadata.name' 2>/dev/null | head -1)
  if [[ -n "$CL2_PROM_NODE_NAME" ]]; then
    echo "Auto-detected prom node: $CL2_PROM_NODE_NAME"
  else
    echo "WARNING: No prom node found (no node with label prometheus=true)"
  fi
fi
export CL2_PROM_NODE_NAME="${CL2_PROM_NODE_NAME:-}"

# Create report directory
mkdir -p "$CL2_REPORT_DIR"

echo ""
echo "Starting ClusterLoader2..."
echo "Report directory: $CL2_REPORT_DIR"
echo ""

cd "$CL2_DIR"

# Deploy prom-node cAdvisor ServiceMonitor in background once monitoring namespace is ready
if [[ -n "${CL2_PROM_NODE_NAME:-}" ]]; then
  (
    echo "Waiting for monitoring namespace to be ready..."
    for i in $(seq 1 120); do
      if kubectl --kubeconfig "$KUBECONFIG" get namespace monitoring &>/dev/null; then
        sleep 10  # wait for Prometheus Operator to be ready
        kubectl --kubeconfig "$KUBECONFIG" apply -f - <<EOSM
apiVersion: monitoring.coreos.com/v1
kind: ServiceMonitor
metadata:
  name: kubelet-prom
  namespace: monitoring
  labels:
    k8s-app: kubelet-prom
spec:
  endpoints:
  - port: https-metrics
    scheme: https
    path: /metrics/cadvisor
    interval: 30s
    honorLabels: true
    tlsConfig:
      insecureSkipVerify: true
    bearerTokenFile: /var/run/secrets/kubernetes.io/serviceaccount/token
    relabelings:
      - sourceLabels: [__meta_kubernetes_endpoint_address_target_name]
        regex: '${CL2_PROM_NODE_NAME}'
        action: keep
    metricRelabelings:
      - sourceLabels: [__name__]
        regex: container_cpu_usage_seconds_total|container_memory_working_set_bytes|container_memory_usage_bytes
        action: keep
      - sourceLabels: [container]
        regex: cilium-operator|kvstoremesh|clustermesh-apiserver|apiserver|etcd
        action: keep
  selector:
    matchLabels:
      k8s-app: kubelet
  namespaceSelector:
    matchNames:
    - kube-system
EOSM
        echo "kubelet-prom ServiceMonitor deployed for node: ${CL2_PROM_NODE_NAME}"
        break
      fi
      sleep 5
    done
  ) &
  PROM_SM_PID=$!
fi

go run cmd/clusterloader.go \
    --kubeconfig "$KUBECONFIG" \
    --report-dir "$CL2_REPORT_DIR" \
    --testconfig podstartupanalysis/config.yaml \
    --provider "$CL2_PROVIDER" \
    --prometheus-scrape-kubelets=true \
    --prometheus-scrape-master-kubelets=true \
    --prometheus-ready-timeout=15m \
    --enable-prometheus-server=true \
    --v="$CL2_VERBOSITY" \
    --experimental-prometheus-snapshot-to-report-dir=true \
    --tear-down-prometheus-server="$CL2_TEAR_DOWN_PROMETHEUS" \
    2>&1 | tee "$CL2_REPORT_DIR/cl2-output.txt"

echo ""
echo "=============================================="
echo "Test Complete!"
echo "=============================================="
echo "Results saved to: $CL2_REPORT_DIR"
echo ""
echo "Files generated:"
ls -la "$CL2_REPORT_DIR"/*.json 2>/dev/null || echo "  (no JSON files yet)"
echo ""
