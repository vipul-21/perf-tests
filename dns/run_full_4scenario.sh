#!/bin/bash
# run_full_4scenario.sh — Full pipeline: build v1.19 images + run all 4 scenarios
#
# This script is self-contained. Run it after Docker is available.
# It will:
#   1. Build v1.19 images (v1.18 already built and pushed)
#   2. Run all 4 scenarios with smoke test (30s runs, 1 run each)
#
# Usage:
#   nohup bash ~/ws/perf-tests/dns/run_full_4scenario.sh > ~/ws/perf-tests/dns/full_run.log 2>&1 &
#
# For full production run (5 runs × 600s each):
#   SMOKE=false RUNS=5 nohup bash ~/ws/perf-tests/dns/run_full_4scenario.sh > ~/ws/perf-tests/dns/full_run.log 2>&1 &

set -euo pipefail

SMOKE="${SMOKE:-true}"
RUNS="${RUNS:-1}"
RESOURCE_GROUP="${RESOURCE_GROUP:-dns-perf-full-rg}"

CILIUM_REPO="/home/singhvipul/ws/cilium-private"
PERF_TESTS="/home/singhvipul/ws/perf-tests"
DNS_DIR="$PERF_TESTS/dns"

log() { echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1"; }

# Step 1: Build v1.19 images (v1.18 already done)
log "=== Step 1: Building v1.19 images ==="
cd "$CILIUM_REPO"
bash "$DNS_DIR/build_images.sh" --version v1.19
log "v1.19 images built successfully"

# Step 2: Run all 4 scenarios
log "=== Step 2: Running all 4 scenarios ==="
cd "$DNS_DIR"

SMOKE_FLAG=""
if [ "$SMOKE" = "true" ]; then
    SMOKE_FLAG="--smoke"
fi

RESOURCE_GROUP="$RESOURCE_GROUP" bash "$DNS_DIR/dns_perf_4scenario.sh" \
    --scenario all \
    $SMOKE_FLAG \
    --runs "$RUNS"

log "=== Full pipeline complete ==="
log "Results: $DNS_DIR/dns-perf-4scenario-workdir/results/"
log "Report:  $DNS_DIR/dns-perf-4scenario-workdir/results/comparison_report.txt"
