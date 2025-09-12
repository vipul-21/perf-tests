# DNS Performance Automation Script (daily_dns_perf.sh)

This document explains how to run the automated DNS performance test script and view results in a local Perfdash instance.

## 1. Prerequisites

Cluster:
- A reachable Kubernetes cluster (`kubectl get nodes` must work).
- Correct kubeconfig in your environment.

If testing DNS proxy / policies:
- Apply the Cilium Network Policy (CNP) or custom variant before running (only needed if validating DNS proxy path):
  ```bash
  kubectl apply -f dns/cnp.yaml
  # or
  kubectl apply -f dns/custom-cnp.yaml
  ```

Local tools:
- Python 3 with numpy (e.g. `pip install numpy`).
- Go toolchain (for `go run` conversion step).
- Built Perfdash binary at: `$PERF_TESTS_ROOT/perfdash/perfdash`.

Environment (optional):
- `PERF_TESTS_ROOT` overrides the default root path. Default: `/home/singhvipul/ws/perf-tests`.
  ```bash
  export PERF_TESTS_ROOT=$HOME/src/perf-tests
  ```

## 2. Run the Script

Change to the dns directory:
```bash
cd "$PERF_TESTS_ROOT/dns"
```
List supported DNS type combinations:
```bash
./daily_dns_perf.sh --list-types
```

Run a single test:
```bash
./daily_dns_perf.sh --type cilium+kubedns
```
Run multiple sequential tests (2 minute wait between runs):
```bash
./daily_dns_perf.sh --type cilium+kubedns --runs 3
```

Outputs:
- Raw run logs: `$PERF_TESTS_ROOT/dns/out/<date>-<dns_type>-<time>/`
- Converted JSON metrics (Perfdash builds): `$PERF_TESTS_ROOT/dns/json-metrics-structured/<dns_type>/<build_number>/artifacts/`
- Metadata: `build_info.json` in each build directory.

## 3. Run / View the Dashboard

The script automatically restarts Perfdash after a successful run (listens on `http://localhost:8081/`).

If you need to start it manually:
```bash
cd "$PERF_TESTS_ROOT/perfdash"
./perfdash \
  --www \
  --address=0.0.0.0:8081 \
  --configPath=$PERF_TESTS_ROOT/perfdash/local-config.yaml \
  --mode=local \
  --logsPath=$PERF_TESTS_ROOT/dns/json-metrics-structured \
  --dir=www \
  --builds=30
```
Open: http://localhost:8081/

## Troubleshooting
| Issue | Check |
|-------|-------|
| No jobs appear | Ensure `local-config.yaml` has matching job prefixes and JSON build dirs exist. |
| Perfdash not running | Run it in foreground without `nohup` to see errors. |
| Missing metrics | Inspect `jsonify_output_run_<n>.log` in the run output directory. |
| Wrong paths | Confirm `PERF_TESTS_ROOT` export and directory structure. |

## Cleanup
Old builds can be pruned manually by deleting older numbered directories under `json-metrics-structured/<dns_type>/`.

## Example End-to-End
```bash
export PERF_TESTS_ROOT=$HOME/src/perf-tests
cd $PERF_TESTS_ROOT/dns
kubectl apply -f dns/cnp.yaml   # only if testing DNS proxy
./daily_dns_perf.sh --type cilium+kubedns --runs 2
# After completion open the dashboard:
xdg-open http://localhost:8081/ 2>/dev/null || echo "Open http://localhost:8081/ in your browser"
```
