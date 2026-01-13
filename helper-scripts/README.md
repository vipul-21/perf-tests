# BYOCNI Pod Startup Pipeline

This helper scripts package provisions BYOCNI-capable AKS clusters and runs the pod-startup scenario from Kubernetes `clusterloader2`. The workflow is driven by three bash entry points:

- `run-byocni-podstartup-multi.sh` – top-level orchestrator; manages cluster lifecycle, credentials, and test runs.
- `byocni-cluster.sh` – creates or reuses the target AKS cluster, installs Cilium, configures monitoring, and reconciles worker/Prometheus node pools.
- `../clusterloader2/run-podstartup.sh` – prepares node labels, sets `clusterloader2` environment overrides, launches the workload, and stages results for perfdash.

## Prerequisites

- Azure CLI (`az`) authenticated against the subscription that hosts the cluster resources.
- `kubectl` installed with sufficient RBAC to administer the cluster.
- Repository checked out with Go toolchain available (required by `go run cmd/clusterloader.go`).

## Quick Start

Run the orchestrator from this directory. It will:

1. Ensure the target AKS cluster exists (creating or reusing based on flags).
2. Fetch credentials into an ephemeral kubeconfig.
3. Wait for Cilium control-plane components to roll out.
4. Invoke `clusterloader2` with the requested scale and throughput parameters.
5. Collect results under `../clusterloader2/results/` and perfdash archives under `../clusterloader2/results/logs/`.

Example command:

```bash
./run-byocni-podstartup-multi.sh \
  --cluster-name ccp-mesh-6 \
  --mesh \
  --enable-monitoring \
  --reuse \
  --runs 1 \
  --pools 10 \
  --nodes-per-pool 50 \
  --deployment-size 50 \
  --namespaces 100 \
  --load-throughput 100 \
  --pods-per-node 40 \
  --scenario ces
```

## Key Flags

- `--cluster-name` / `--region`: select the AKS cluster identity and location.
- `--mesh` / `--no-mesh`: toggle clustermesh workloads; monitoring defaults to workspace IDs that match the mode.
- `--pools` and `--nodes-per-pool`: control worker scale (total nodes = pools × nodes per pool).
- `--deployment-size`, `--pods-per-node`, `--namespaces`: override the default workload sizing derived in `podstartupanalysis/config.yaml`.
- `--load-throughput` / `--delete-throughput`: set pod creation and deletion QPS (delete defaults to load if omitted).
- `--runs`, `--reuse`, `--recreate`: manage iterations and cluster lifecycle between runs.
- `--enable-monitoring`: configures AMA metrics scraping and Prometheus PodMonitors via `byocni-cluster.sh`.

Generated artifacts live in timestamped folders under `../clusterloader2/results/`. Perfdash-ready archives are organized in `../clusterloader2/results/logs/` with a build counter per scenario.
