# Load Test Guide — Pod Startup Latency Analysis with ClusterLoader2

This guide explains how to run pod startup latency load tests using ClusterLoader2 (CL2) from the `perf-tests` repo (branch: `ccp-mesh`). The test creates and deletes deployments in cycles while Prometheus captures kubelet, Cilium, and API server metrics.

---

## Table of Contents

1. [Overview](#1-overview)
2. [Prerequisites](#2-prerequisites)
3. [Quick Start](#3-quick-start)
4. [Scale Presets](#4-scale-presets)
5. [Parameter Reference](#5-parameter-reference)
6. [How Parameters Affect the Test](#6-how-parameters-affect-the-test)
7. [Test Execution Flow](#7-test-execution-flow)
8. [Prometheus & Metrics Collection](#8-prometheus--metrics-collection)
9. [Running Tests on Different Clusters](#9-running-tests-on-different-clusters)
10. [Test Results & Output](#10-test-results--output)
11. [Monitoring During Tests](#11-monitoring-during-tests)
12. [Advanced Configuration](#12-advanced-configuration)
13. [Troubleshooting](#13-troubleshooting)

---

## 1. Overview

### What the Test Does

The load test runs **N repeated cycles** of:

```
┌─────────────────────────────────────────────────────────────────┐
│  Repeat 1..N (default: 5 cycles)                                │
│                                                                 │
│  1. CREATE deployments across all namespaces                    │
│     └─ RandomizedSaturationTimeLimited (target: X pods/sec)     │
│  2. WAIT for all pods to reach Running state                    │
│  3. SLEEP 10 minutes (metrics settle)                           │
│  4. DELETE all deployments (scale to 0 replicas)                │
│  5. WAIT for deletion to complete                               │
│  6. SLEEP 20 minutes (inter-iteration cooldown)                 │
│                                                                 │
└─────────────────────────────────────────────────────────────────┘
```

Each cycle creates the same set of pods, so you get **multiple data points** for pod startup latency under identical conditions.

### What It Measures

- **Pod startup latency** — Time from pod creation to all containers running (via `kubelet_pod_start_sli_duration_seconds`)
- **Pod sandbox creation** — Time to create pause container + CNI network setup (`kubelet_run_podsandbox_duration_seconds`)
- **Runtime operations** — Container create/start/stop durations (`kubelet_runtime_operations_duration_seconds`)
- **Cilium endpoint regeneration** — BPF program compilation and endpoint setup (`cilium_endpoint_regeneration_time_stats_seconds`)
- **API server load** — CPU, memory, request latency during pod churn
- **Cilium agent/operator resource usage** — CPU and memory under load

### Repository Setup

```bash
git clone https://github.com/kubernetes/perf-tests.git
cd perf-tests
git checkout ccp-mesh
```

---

## 2. Prerequisites

| Requirement | Details |
|-------------|---------|
| Go | 1.21+ (CL2 is built from source via `go run`) |
| kubectl | Configured with kubeconfig for target cluster |
| Cluster nodes | Labeled with `slo=true` and tainted `slo=true:NoSchedule` |
| Prometheus node | Labeled with `prometheus=true` (no taint, so Prometheus pod can schedule) |
| Worker node CPU | Must be sufficient for pod CPU requests (see [Parameter Reference](#5-parameter-reference)) |

### Node Setup

Worker nodes must have the `slo=true` label and taint. The test deployments tolerate this taint, ensuring only test pods land on worker nodes:

```bash
# Already done by worker-bootstrap.sh in acn-perf-tests clusters
# For manual setup:
kubectl label node <node> slo=true
kubectl taint node <node> slo=true:NoSchedule
```

The Prometheus node must have `prometheus=true` label (automatically detected by `run.sh`):

```bash
kubectl label node <node> prometheus=true
```

---

## 3. Quick Start

### One-Command Run

```bash
cd perf-tests/clusterloader2

# 1000-node mesh cluster test
./podstartup-generick8s-test/run.sh \
  -k /path/to/ind-mesh.conf \
  -n 1000 -p 40 -N 100 -D 40 \
  mesh-1000node-test
```

### Step-by-Step

```bash
cd perf-tests/clusterloader2

# 1. Source environment (sets defaults + helper functions)
source podstartup-generick8s-test/env.sh

# 2. Override parameters for your cluster
export KUBECONFIG=/path/to/ind-mesh.conf
export CL2_NODES=1000
export CL2_PODS_PER_NODE=40

# 3. Review configuration
cl2_show_config

# 4. Run the test
./podstartup-generick8s-test/run.sh mesh-1000node-test
```

---

## 4. Scale Presets

Pre-validated parameter combinations for different cluster sizes:

| Cluster Size | Nodes | Pods/Node | Total Pods | Namespaces | Deploy/NS | Throughput | CPU Request | Command |
|-------------|-------|-----------|------------|------------|-----------|------------|-------------|---------|
| **Small** | 10 | 50 | 500 | 10 | 1 | 20 | 69m | `-n 10 -p 50 -N 10 -D 1` |
| **Medium** | 100 | 50 | 5,000 | 20 | 5 | 50 | 69m | `-n 100 -p 50 -N 20 -D 5` |
| **Large** | 500 | 50 | 25,000 | 50 | 10 | 100 | 69m | `-n 500 -p 50 -N 50 -D 10` |
| **XL** | 1000 | 40 | 40,000 | 100 | 40 | 100 | 69m | `-n 1000 -p 40 -N 100 -D 40` |

### Full Command Examples

```bash
# 10-node test (quick validation)
./podstartup-generick8s-test/run.sh -k ~/ind-mesh.conf \
  -n 10 -p 50 -N 10 -D 1 mesh-10node-test

# 100-node test
./podstartup-generick8s-test/run.sh -k ~/ind-mesh.conf \
  -n 100 -p 50 -N 20 -D 5 mesh-100node-test

# 1000-node test
./podstartup-generick8s-test/run.sh -k ~/ind-mesh.conf \
  -n 1000 -p 40 -N 100 -D 40 mesh-1000node-test
```

---

## 5. Parameter Reference

### Pod Distribution Parameters

| Parameter | Flag | Default | Description |
|-----------|------|---------|-------------|
| `CL2_NODES` | `-n` | 500 | Number of worker nodes expected in the cluster |
| `CL2_PODS_PER_NODE` | `-p` | 50 | Target pods per node |
| `CL2_DEPLOYMENT_SIZE` | `-d` | 10 | Replicas per deployment (pod count per deployment) |
| `CL2_NAMESPACES` | `-N` | 50 | Number of namespaces to spread deployments across |
| `CL2_DEPLOYMENTS_PER_NS` | `-D` | 10 | Number of deployments created in each namespace |

**Derived values** (computed by CL2):

```
Total Pods      = CL2_NODES × CL2_PODS_PER_NODE
Pods/Namespace  = Total Pods ÷ CL2_NAMESPACES
Deploys/NS      = Pods/Namespace ÷ CL2_DEPLOYMENT_SIZE
Saturation Time = Total Pods ÷ CL2_LOAD_TEST_THROUGHPUT (seconds)
```

### Throughput Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CL2_LOAD_TEST_THROUGHPUT` | 50 | Target pod creation rate (pods/sec) |
| `CL2_DELETE_TEST_THROUGHPUT` | same as load | Target pod deletion rate (pods/sec) |

### Pod Resource Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CL2_LATENCY_POD_CPU` | 69 | CPU request per pod in millicores |
| `CL2_LATENCY_POD_MEMORY` | 50 | Memory request per pod in MB |

**CPU Request Formula:**

```
CL2_LATENCY_POD_CPU = (Node CPU Cores × 0.87 × 1000) ÷ CL2_PODS_PER_NODE
```

Examples for `CL2_PODS_PER_NODE=50`:
- 4-core node (D4s_v4): `(4 × 0.87 × 1000) ÷ 50 = 69m`
- 8-core node (D8s_v4): `(8 × 0.87 × 1000) ÷ 50 = 139m`
- 16-core node: `(16 × 0.87 × 1000) ÷ 50 = 278m`

The 0.87 factor accounts for kubelet, system daemons, and Cilium agent CPU reservations (~13% overhead).

### Timeout & Iteration Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CL2_OPERATION_TIMEOUT` | 30m | Max wait for pods to reach Running/Deleted |
| `CL2_POD_STARTUP_LATENCY_THRESHOLD` | 120s | SLO threshold — test logs violation if exceeded |
| `CL2_REPEATS` | 5 | Number of create/delete cycles |

### Metrics Collection Flags

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CL2_CILIUM_METRICS_ENABLED` | true | Scrape Cilium agent and operator metrics |
| `CL2_KUBELET_METRICS_ENABLED` | true | Scrape kubelet pod startup metrics |
| `CL2_PROMETHEUS_SCRAPE_CILIUM_OPERATOR` | true | Deploy PodMonitor for cilium-operator |
| `CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT` | true | Deploy PodMonitor for cilium-agent |
| `CL2_PROMETHEUS_SCRAPE_CLUSTERMESH_APISERVER` | false | Deploy PodMonitor for clustermesh (mesh mode) |

### Prometheus Resource Parameters

| Parameter | Default | Description |
|-----------|---------|-------------|
| `CL2_PROMETHEUS_MEMORY_LIMIT_FACTOR` | 14 | Memory scaling factor |
| `CL2_PROMETHEUS_MEMORY_SCALE_FACTOR` | 14 | Memory base allocation |
| `CL2_PROMETHEUS_CPU_SCALE_FACTOR` | 12 | CPU scaling factor |
| `CL2_PROMETHEUS_PVC_ENABLED` | false | Use PVC (false = emptyDir) |
| `CL2_TEAR_DOWN_PROMETHEUS` | false | Delete Prometheus after test (false = keep for debugging) |

---

## 6. How Parameters Affect the Test

### Understanding the Math

The test creates a **fixed total number of pods** distributed across namespaces and deployments:

```
Example: 1000-node cluster with -n 1000 -p 40 -N 100 -D 40

Total Pods       = 1000 × 40 = 40,000
Pods/Namespace   = 40,000 ÷ 100 = 400
Deploys/NS       = 400 ÷ 10 (deployment_size) = 40
Saturation Time  = 40,000 ÷ 100 (throughput) = 400 seconds ≈ 6.7 minutes
```

### Per-Iteration Timing

Each iteration takes approximately:

```
Create phase:    Saturation Time + time for all pods to reach Running
Wait:            until WaitForControlledPodsRunning completes
Sleep:           10 minutes (metrics stabilization)
Delete phase:    Deletion Time + time for all pods to terminate
Wait:            until all pods deleted
Sleep:           20 minutes (inter-iteration cooldown)
─────────────────────────────────────────────────────
Typical total:   ~45-60 minutes per iteration
```

For 5 iterations: **~4-5 hours total test time**.

### Tuning for Cluster Size

| Parameter | Why to Tune | Impact |
|-----------|-------------|--------|
| `CL2_PODS_PER_NODE` | Reduce from 50 → 40 for large clusters | Prevents node CPU saturation; reduces total pods |
| `CL2_NAMESPACES` | More namespaces = better API server distribution | Too few = hot namespaces; too many = overhead |
| `CL2_LOAD_TEST_THROUGHPUT` | Higher = faster test, more API server pressure | Don't exceed what kubelet can handle (~100 pods/s at 1000 nodes) |
| `CL2_LATENCY_POD_CPU` | Must match node CPU / pods-per-node | Too high = pods pending; too low = unrealistic |
| `CL2_OPERATION_TIMEOUT` | Increase for larger clusters | Pods take longer to schedule at scale |
| `CL2_REPEATS` | More cycles = more data points | Each cycle adds ~45-60 min |

### Common Mistakes

| Mistake | Symptom | Fix |
|---------|---------|-----|
| CPU request too high | Pods stuck in `Pending` | Recalculate: `(cores × 0.87 × 1000) ÷ pods_per_node` |
| Throughput too high | API server overloaded, pods timing out | Reduce to 50-100 pods/sec |
| Timeout too short | Test fails with "operation timed out" | Increase `CL2_OPERATION_TIMEOUT` |
| Nodes not labeled | Pods unschedulable | Ensure all workers have `slo=true` label + taint |
| Wrong node count | Uneven pod distribution | `CL2_NODES` must match actual schedulable node count |

---

## 7. Test Execution Flow

### What `run.sh` Does

```
1. Parse CLI arguments (-k, -n, -p, -N, -D, test name)
2. Source env.sh (sets defaults, helper functions)
3. Display configuration → wait for Enter to confirm
4. Auto-detect Prometheus node (label: prometheus=true)
5. Create results directory: results/<test-name>/<timestamp>/
6. Launch background task: deploy kubelet-prom ServiceMonitor
   └─ Waits for monitoring namespace → kubectl apply ServiceMonitor
7. Run CL2: go run cmd/clusterloader.go
   ├─ CL2 creates monitoring namespace
   ├─ CL2 deploys Prometheus Operator + Prometheus
   ├─ CL2 deploys ServiceMonitors (kubelet, master, cilium)
   ├─ CL2 runs config.yaml test steps (create/delete cycles)
   └─ CL2 snapshots Prometheus data to report directory
8. Display results summary
```

### What CL2's `config.yaml` Does

```yaml
# Per iteration:
1. Create deployments (RandomizedSaturationTimeLimited)
   - Spread across N namespaces × D deployments/namespace
   - Each deployment = CL2_DEPLOYMENT_SIZE replicas
   - Created at CL2_LOAD_TEST_THROUGHPUT pods/sec
2. WaitForControlledPodsRunning (all pods Running)
3. Sleep 10 minutes
4. Delete deployments (set replicas to 0)
5. WaitForControlledPodsRunning (all pods gone)
6. Sleep 20 minutes
```

### Deployment Template

Each deployment creates pods with:
- **Image**: `mcr.microsoft.com/oss/kubernetes/pause:3.6` (minimal container)
- **Node selector**: `slo: "true"` (only lands on labeled workers)
- **Tolerations**: `slo=true:NoSchedule`, `node.kubernetes.io/not-ready` (15 min grace)
- **Resources**: `cpu: <CL2_LATENCY_POD_CPU>m`, `memory: <CL2_LATENCY_POD_MEMORY>M`

---

## 8. Prometheus & Metrics Collection

### Auto-Deployed Components

CL2 automatically deploys into the `monitoring` namespace:

| Component | Purpose |
|-----------|---------|
| Prometheus Operator | Manages Prometheus + ServiceMonitor/PodMonitor CRDs |
| Prometheus StatefulSet | Scrapes and stores all metrics |
| ServiceMonitor: `kubelet` | Kubelet metrics (pod startup, runtime ops) + cAdvisor |
| ServiceMonitor: `master` | API server metrics |
| PodMonitor: `cilium-agent-pods` | Cilium agent metrics (endpoint regen, BPF compilation) |
| PodMonitor: `cilium-operator-pods` | Cilium operator metrics (CES queueing) |
| ServiceMonitor: `kubelet-prom` | cAdvisor from Prometheus node (clustermesh resource usage) |

### Kubelet Metrics Scraped (10% hashmod sampling)

The kubelet ServiceMonitor uses hashmod-based sampling to scrape ~10% of nodes:

| Metric | What It Measures |
|--------|-----------------|
| `kubelet_pod_worker_duration_seconds` | Kubelet sync loop per pod |
| `kubelet_pod_start_sli_duration_seconds` | Pod spec received → containers running (SLI) |
| `kubelet_runtime_operations_duration_seconds` | Runtime ops: run_podsandbox, start_container, etc. |
| `kubelet_run_podsandbox_duration_seconds` | Sandbox creation (pause container + CNI) |

### Cilium Metrics Scraped (10% hashmod sampling)

| Metric | What It Measures |
|--------|-----------------|
| `cilium_endpoint_regeneration_time_stats_seconds` | Endpoint regen by scope (total, bpfCompilation) |
| `cilium_agent_api_process_time_seconds` | Cilium API processing (PUT /v1/endpoint) |
| `cilium_endpoint_count` | Endpoints per agent |
| `cilium_identity` | Unique identities |
| `cilium_bpf_map_pressure` | BPF map utilization |

### Prom Node cAdvisor (kubelet-prom ServiceMonitor)

Deployed by `run.sh` in the background. Scrapes cAdvisor metrics from the Prometheus node only, filtered to:

- **Containers**: `cilium-operator`, `kvstoremesh`, `clustermesh-apiserver`, `apiserver`, `etcd`
- **Metrics**: `container_cpu_usage_seconds_total`, `container_memory_working_set_bytes`

---

## 9. Running Tests on Different Clusters

### Mesh Cluster (with Cilium ClusterMesh)

```bash
./podstartup-generick8s-test/run.sh \
  -k /path/to/acn-perf-tests/hyperscale/terraform/ind-mesh.conf \
  -n 1000 -p 40 -N 100 -D 40 \
  mesh-1000node-test
```

All Cilium metrics are enabled by default (`CL2_CILIUM_METRICS_ENABLED=true`).

### NoMesh Cluster (Cilium without ClusterMesh)

```bash
./podstartup-generick8s-test/run.sh \
  -k /path/to/acn-perf-tests/hyperscale/terraform/ind-nomesh.conf \
  -n 1000 -p 40 -N 100 -D 40 \
  nomesh-1000node-test
```

Same parameters as mesh — Cilium metrics still apply.

### Azure CNI Cluster (No Cilium)

```bash
CL2_CILIUM_METRICS_ENABLED=false \
CL2_PROMETHEUS_SCRAPE_CILIUM_OPERATOR=false \
CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT=false \
./podstartup-generick8s-test/run.sh \
  -k /path/to/acn-perf-tests/hyperscale/terraform/ind-azurecni.conf \
  -n 1000 -p 40 -N 100 -D 40 \
  azurecni-1000node-test
```

Disable Cilium metrics since there's no Cilium on this cluster.

### Small Cluster Validation (10 nodes)

```bash
CL2_LOAD_TEST_THROUGHPUT=20 CL2_REPEATS=2 \
./podstartup-generick8s-test/run.sh \
  -k ~/ind-mesh.conf \
  -n 10 -p 50 -N 10 -D 1 \
  mesh-10node-validation
```

Lower throughput and fewer repeats for quick validation.

---

## 10. Test Results & Output

### Output Directory

Results are saved to: `results/<test-name>/<timestamp>/`

```
results/mesh-1000node-test/20260315T1430/
├── cl2-output.txt                           # Full CL2 stdout/stderr log
├── prometheus-snapshot/                     # Prometheus TSDB snapshot (raw data)
├── PodStartupLatency_*.json                 # Pod startup percentiles
├── APIResponsivenessPrometheus_*.json        # API latency breakdown
├── ApiserverAvgCPUUsage_*.json              # API server CPU
├── ApiserverMaxMemUsage_*.json              # API server memory
├── CiliumAvgCPUUsage_*.json                 # Cilium agent CPU
├── CiliumEndpointPropagationDelay_*.json    # Endpoint propagation
├── KubeletPodStartupSLIDuration_*.json      # Kubelet SLI latency
├── KubeletRuntimeOperationDuration_*.json   # Runtime ops breakdown
└── ... (more measurement JSON files)
```

### Prometheus Snapshot

CL2 creates a Prometheus TSDB snapshot and downloads it to the report directory. You can load it into a local Prometheus for post-test analysis:

```bash
# Start local Prometheus with the snapshot
prometheus --storage.tsdb.path=results/mesh-1000node-test/20260315T1430/prometheus-snapshot/
```

### Keeping Prometheus Running

By default, `CL2_TEAR_DOWN_PROMETHEUS=false` — Prometheus stays up after the test. You can port-forward and query live:

```bash
kubectl --kubeconfig $KC -n monitoring port-forward svc/prometheus-k8s 9090:9090
# Open http://localhost:9090
```

---

## 11. Monitoring During Tests

### Accessing Prometheus During the Test

```bash
# Port-forward (from another terminal)
kubectl --kubeconfig $KC -n monitoring port-forward prometheus-k8s-0 9090:9090 &

# Or exec into the pod
kubectl --kubeconfig $KC -n monitoring exec prometheus-k8s-0 -c prometheus -- \
  wget -qO- 'http://localhost:9090/api/v1/query?query=<QUERY>'
```

### Key Queries to Monitor During Test

| What to Watch | Query |
|---------------|-------|
| Pod creation rate | `sum(rate(kubelet_running_pods[1m]))` |
| P99 Pod Startup | `histogram_quantile(0.99, sum(rate(kubelet_pod_start_sli_duration_seconds_bucket[5m])) by (le))` |
| P99 Sandbox Creation | `histogram_quantile(0.99, sum(rate(kubelet_run_podsandbox_duration_seconds_bucket[5m])) by (le))` |
| P99 BPF Compilation | `histogram_quantile(0.99, sum(rate(cilium_endpoint_regeneration_time_stats_seconds_bucket{scope="bpfCompilation"}[5m])) by (le))` |
| Runtime ops by type | `histogram_quantile(0.99, sum(rate(kubelet_runtime_operations_duration_seconds_bucket{operation_type=~"run_podsandbox\|start_container"}[5m])) by (le, operation_type))` |
| API Server CPU | `sum(rate(container_cpu_usage_seconds_total{container="kube-apiserver"}[1m]))` |
| Pending pods | `count(kube_pod_status_phase{phase="Pending"})` |

See [monitoring-queries.md](../acn-perf-tests/docs/monitoring-queries.md) for the full list.

---

## 12. Advanced Configuration

### Tuning Throughput for API Server Stability

If the API server becomes overloaded during pod creation:

```bash
# Reduce creation rate
export CL2_LOAD_TEST_THROUGHPUT=50   # default: 100

# This increases saturation time:
# 40,000 pods ÷ 50 pods/sec = 800 seconds ≈ 13 minutes (vs 6.7 min at 100/s)
```

### Adjusting Pod Resource Requests

For non-standard VM sizes:

```bash
# 8-core nodes with 50 pods/node
export CL2_LATENCY_POD_CPU=139    # (8 × 0.87 × 1000) ÷ 50

# 4-core nodes with 40 pods/node
export CL2_LATENCY_POD_CPU=87     # (4 × 0.87 × 1000) ÷ 40

# 2-core nodes with 50 pods/node
export CL2_LATENCY_POD_CPU=34     # (2 × 0.87 × 1000) ÷ 50
```

### Running Fewer Iterations

For quick tests, reduce repeats:

```bash
export CL2_REPEATS=2   # 2 cycles instead of 5 (saves ~2.5 hours)
```

### Disabling Prometheus Teardown

Keep Prometheus running after the test to analyze results in the live UI:

```bash
export CL2_TEAR_DOWN_PROMETHEUS=false   # default: already false
```

### Enabling ClusterMesh API Server Scraping

For mesh clusters, enable clustermesh metrics:

```bash
export CL2_PROMETHEUS_SCRAPE_CLUSTERMESH_APISERVER=true
```

---

## 13. Troubleshooting

### Pods Stuck in Pending

```bash
kubectl --kubeconfig $KC get pods -A | grep Pending | head -20
kubectl --kubeconfig $KC describe pod <pod-name> -n <ns>
```

**Common causes:**
- CPU request too high → reduce `CL2_LATENCY_POD_CPU`
- Nodes not labeled `slo=true` → pods can't schedule
- Node count mismatch → `CL2_NODES` doesn't match actual schedulable nodes

### CL2 Timeout Errors

```
"operation timed out waiting for pods to be running"
```

Increase timeout: `export CL2_OPERATION_TIMEOUT=40m`

### Prometheus Not Starting

```bash
kubectl --kubeconfig $KC -n monitoring get pods
kubectl --kubeconfig $KC -n monitoring describe pod prometheus-k8s-0
```

**Common causes:**
- No node with `prometheus=true` label
- Insufficient resources on Prometheus node
- PVC issues (set `CL2_PROMETHEUS_PVC_ENABLED=false`)

### Cilium Metrics Not Appearing

- Verify Cilium pods are running: `kubectl -n kube-system get pods -l app.kubernetes.io/name=cilium`
- Check PodMonitor exists: `kubectl -n monitoring get podmonitor`
- Verify: `CL2_CILIUM_METRICS_ENABLED=true`

### Cleaning Up After a Failed Test

```bash
# Delete monitoring namespace (removes Prometheus + all monitors)
kubectl --kubeconfig $KC delete namespace monitoring

# Delete test namespaces
kubectl --kubeconfig $KC delete namespace -l prefix=slo
```

---

## File Reference

```
perf-tests/clusterloader2/
├── podstartup-generick8s-test/
│   ├── run.sh                    ← Main entry point (CLI + orchestration)
│   └── env.sh                    ← All tunable parameters + helper functions
├── podstartupanalysis/
│   ├── config.yaml               ← Test definition (create/delete cycles)
│   ├── reconcile-objects.yaml     ← Deployment create/delete step template
│   ├── deployment_template.yaml   ← Pod spec (pause container, resources, tolerations)
│   ├── measurements.yaml          ← API server + pod startup measurements
│   ├── measurements-baseline.yaml ← Same measurements, captured as baseline
│   ├── cilium-measurements.yaml   ← Cilium-specific metrics collection
│   ├── cilium-baseline-measurements.yaml ← Cilium baseline metrics
│   └── kubelet-measurements.yaml  ← Kubelet SLI + runtime op measurements
└── pkg/prometheus/manifests/default/
    ├── prometheus-serviceMonitorKubelet.yaml   ← Kubelet + cAdvisor scrape config
    └── prometheus-podMonitorCiliumAgent.yaml   ← Cilium agent scrape config
```
