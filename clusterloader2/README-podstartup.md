# Pod Startup Performance Test - Usage Guide

## Quick Start

```bash
cd /home/singhvipul/ws/shreya/perf-tests/clusterloader2

# Basic test run
./run-podstartup.sh \
  test-cluster \
  ~/.kube/config \
  my-resource-group \
  3 \
  100 \
  default \
  "aks-nodepool1" \
  "aks-nodepool2"
```

## Script Parameters

```bash
./run-podstartup.sh <RESULTSFOLDER> <KUBECONFIG> <RG> <NODES> <DEPLOYMENT_SIZE> <SCENARIO> <SLO_NODES> <PROMETHEUS_NODES>
```

| Parameter | Description | Example |
|-----------|-------------|---------|
| **RESULTSFOLDER** | Name for the test results folder | `test-cluster` |
| **KUBECONFIG** | Path to kubeconfig file | `~/.kube/config` |
| **RG** | Resource group name (for reporting) | `my-rg` |
| **NODES** | Number of nodes in cluster | `3` |
| **DEPLOYMENT_SIZE** | Pods per deployment (used to calculate deployments per namespace) | `100` |
| **SCENARIO** | Test scenario: `default` or `ces` | `default` |
| **SLO_NODES** | Grep pattern for SLO workload nodes | `aks-nodepool1` or `vmss1` |
| **PROMETHEUS_NODES** | Grep pattern for Prometheus nodes | `aks-nodepool2` or `vmss2` |

### Understanding DEPLOYMENT_SIZE

The `DEPLOYMENT_SIZE` parameter controls how pods are distributed across deployments:

**Calculation:**
```
Total Pods = NODES × CL2_PODS_PER_NODE
Pods per Namespace = Total Pods ÷ 100 namespaces
Deployments per Namespace = Pods per Namespace ÷ DEPLOYMENT_SIZE
Pods per Deployment = DEPLOYMENT_SIZE
```

### Comparing Default vs CES
```bash
# Run default scenario
./run-podstartup.sh comparison ~/.kube/config test-rg 3 100 default "vmss1" "vmss2"

# Run CES scenario
./run-podstartup.sh comparison ~/.kube/config test-rg 3 100 ces "vmss1" "vmss2"

# Compare in perfdash
cd ../perfdash && make run-local
```