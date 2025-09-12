#!/bin/bash
# Daily DNS Performance Test Script
# Runs DNS performance tests once per day for different DNS types
# Uses date-based folder organization instead of build numbers
# Root directory can be overridden via PERF_TESTS_ROOT env var

set -e

# Root (override with: export PERF_TESTS_ROOT=/custom/path)
ROOT_DIR="${PERF_TESTS_ROOT:-/home/singhvipul/ws/perf-tests}"

# Configuration
DNS_DIR="$ROOT_DIR/dns"
PERFDASH_DIR="$ROOT_DIR/perfdash"
BASE_METRICS_DIR="$DNS_DIR/json-metrics-structured"
OUTPUT_DIR="$DNS_DIR/out"
LOG_FILE="$DNS_DIR/daily_automation.log"
PARAMS_FILE="$DNS_DIR/params/kubedns/automated.yaml"

# DNS Types to test daily - only these valid combinations are allowed
DNS_TYPES=("cilium+kubedns" "cilium+node-local" "cilium+dns+node-local" "cilium+acns+nld" "cilium+acnsonly+nld" "oss-sdp-only" "oss-sdp+dnsproxy")

# Function to log messages with timestamp
log() {
    echo "[$(date '+%Y-%m-%d %H:%M:%S')] $1" | tee -a "$LOG_FILE"
}

# Function to validate DNS type input
validate_dns_type() {
    local input_type=$1
    for valid_type in "${DNS_TYPES[@]}"; do
        if [[ "$input_type" == "$valid_type" ]]; then
            return 0
        fi
    done
    return 1
}

# Function to get today's date in folder format
get_date_folder() {
    date '+%Y-%m-%d'
}

# Function to get current time for logging
get_time_label() {
    date '+%H-%M-%S'
}

# Function to create clean labels for the test
create_test_labels() {
    local date_folder=$1
    local dns_type=$2
    local time_label=$3
    local num_runs=${4:-1}
    
    # Create simplified labels object with only DNS type (no date confusion)
    cat << EOF
{
    "time": "$time_label",
    "dns_type": "$dns_type",
    "num_runs": $num_runs,
    "cluster_info": {
        "kubernetes_version": "$(kubectl version --short --client 2>/dev/null | grep Client | cut -d' ' -f3 || echo 'unknown')",
        "node_count": "$(kubectl get nodes --no-headers 2>/dev/null | wc -l || echo 'unknown')"
    }
}
EOF
}

# Function to run DNS performance test for a specific DNS type
run_dns_perf_for_type() {
    local target_dns_type=$1
    local num_runs=${2:-1}  # Default to 1 run if not specified
    local date_folder
    date_folder=$(get_date_folder)
    local time_label
    time_label=$(get_time_label)
    
    log "Starting DNS performance test for type: $target_dns_type (runs: $num_runs)"
        
    # Create date-based directory structure (for our reference)
    local date_output_dir="$OUTPUT_DIR/date-archive/$date_folder"
    local date_artifacts_dir="$date_output_dir/$target_dns_type/artifacts"
    mkdir -p "$date_artifacts_dir"
    
    # Create output directory for this run
    local run_output_dir="$OUTPUT_DIR/$date_folder-$target_dns_type-$time_label"
    mkdir -p "$run_output_dir"
    
    # Create test labels
    local test_labels
    test_labels=$(create_test_labels "$date_folder" "$target_dns_type" "$time_label" "$num_runs")
    
    # Save test metadata
    echo "$test_labels" > "$run_output_dir/test_metadata.json"
    log "Saved test metadata to $run_output_dir/test_metadata.json"
    
    # Run the DNS performance test multiple times (each as independent test)
    for ((run=1; run<=num_runs; run++)); do
        log "Running DNS performance test $run/$num_runs (duration: 10 minutes)..."
        cd "$DNS_DIR" || {
            log "ERROR: Failed to change to DNS directory"
            return 1
        }
        
        # Execute the Python test script with kubedns parameters (using default output)
        local test_command="python3 py/run_perf.py --params $PARAMS_FILE --use-cluster-dns"
        log "Executing: $test_command"
        
        if ! $test_command > "$run_output_dir/test_output_run_$run.log" 2>&1; then
            log "ERROR: DNS performance test failed for $target_dns_type (run $run/$num_runs)"
            cat "$run_output_dir/test_output_run_$run.log" | tail -20 | while read -r line; do
                log "TEST OUTPUT: $line"
            done
            return 1
        fi
        
        log "DNS performance test run $run/$num_runs completed successfully for $target_dns_type"
        
        # Process this run immediately as a separate build
        log "Converting run $run results to JSON format..."
        
        # Run jsonify to convert results for this specific run
        if [[ -d "$DNS_DIR/jsonify" ]]; then
            cd "$DNS_DIR/jsonify" || {
                log "ERROR: Failed to change to jsonify directory"
                return 1
            }
            
            # Build and run jsonify using go run for this individual run
            if ! go mod vendor > "$run_output_dir/jsonify_vendor_run_$run.log" 2>&1; then
                log "WARNING: go mod vendor failed for run $run, continuing anyway"
            fi
            
            # Create separate artifacts directory for this run
            local run_artifacts_dir="$date_artifacts_dir/run_$run"
            mkdir -p "$run_artifacts_dir"
            
            # Convert to JSON with clean labels (no date label) for this run
            if ! go run main.go \
                --benchmarkDirPath="$DNS_DIR/out/latest" \
                --jsonDirPath="$run_artifacts_dir" \
                --benchmarkName="dns" \
                > "$run_output_dir/jsonify_output_run_$run.log" 2>&1; then
                log "ERROR: Failed to convert results to JSON for $target_dns_type (run $run)"
                cat "$run_output_dir/jsonify_output_run_$run.log" | tail -10 | while read -r line; do
                    log "JSONIFY OUTPUT: $line"
                done
                return 1
            fi
            
            # Copy test metadata to artifacts for reference
            cp "$run_output_dir/test_metadata.json" "$run_artifacts_dir/"
            
            # Create perfdash-compatible build structure for this individual run
            local build_number
            build_number=$(create_perfdash_build "$date_folder" "$target_dns_type" "$run_artifacts_dir")
            
            log "JSON conversion completed successfully for $target_dns_type run $run (Build: $build_number)"
        else
            log "ERROR: jsonify binary not found"
            return 1
        fi
        
        # Wait 2 minutes between runs (except for the last run)
        if [ $run -lt $num_runs ]; then
            log "Waiting 2 minutes before next run..."
            sleep 120
        fi
    done
    
    log "All $num_runs DNS performance tests for $target_dns_type completed successfully"
    return 0
}

# Function to create perfdash-compatible build structure
create_perfdash_build() {
    local date_folder=$1
    local dns_type=$2
    local artifacts_dir=$3
    local METRICS_DIR="$BASE_METRICS_DIR/$dns_type"
    local max_build=0
    if [ -d "$METRICS_DIR" ]; then
        for dir in "$METRICS_DIR"/*; do
            if [ -d "$dir" ]; then
                local build_num
                build_num=$(basename "$dir")
                if [[ "$build_num" =~ ^[0-9]+$ ]] && [ "$build_num" -gt "$max_build" ]; then
                    max_build=$build_num
                fi
            fi
        done
    fi
    local build_number=$((max_build + 1))
    local build_dir="$METRICS_DIR/$build_number"
    mkdir -p "$build_dir/artifacts"
    cp -r "$artifacts_dir"/* "$build_dir/artifacts/" 2>/dev/null || true
    cat > "$build_dir/build_info.json" << EOF
{
    "build_number": $build_number,
    "date": "$date_folder",
    "dns_type": "$dns_type",
    "created_at": "$(date -Iseconds)",
    "source_path": "$artifacts_dir"
}
EOF
    log "Created perfdash build $build_number for $date_folder/$dns_type"
    echo "$build_number"
}

# Function to restart perfdash with updated configuration
restart_perfdash() {
    log "Restarting perfdash with updated configuration..."
    pkill -f perfdash || true
    sleep 2
    if [ ! -d "$PERFDASH_DIR" ]; then
        log "ERROR: Perfdash directory not found: $PERFDASH_DIR"
        return 1
    fi
    cd "$PERFDASH_DIR" || { log "ERROR: Failed to enter perfdash directory"; return 1; }
    nohup bash -c "$PERFDASH_DIR/perfdash --www --address=0.0.0.0:8081 --configPath=$PERFDASH_DIR/local-config.yaml --mode=local --logsPath=$BASE_METRICS_DIR --dir=$PERFDASH_DIR/www --builds=30" > /dev/null 2>&1 &
    log "Perfdash restarted on port 8081 (root: $ROOT_DIR)"
}

# Function to run specific DNS type test (for manual testing)
run_specific_type() {
    local target_type=$1
    local num_runs=${2:-1}  # Default to 1 run if not specified
    local date_folder
    date_folder=$(get_date_folder)
    
    log "=== Running specific DNS test for type: $target_type ($num_runs runs) ==="
    
    if run_dns_perf_for_type "$target_type" "$num_runs"; then
        restart_perfdash
        log "=== Specific test for $target_type completed successfully ($num_runs runs) ==="
    else
        log "=== Specific test for $target_type failed ==="
    fi
}

# Main execution
case "${1:-}" in
    "--type"|"-d")
        if [[ -z "${2:-}" ]]; then
            log "ERROR: DNS type required. Usage: $0 --type <dns-type> [--runs <number>]"
            log "Valid types: ${DNS_TYPES[*]}"
            exit 1
        fi
        if ! validate_dns_type "$2"; then
            log "ERROR: Invalid DNS type '$2'"
            log "Valid types: ${DNS_TYPES[*]}"
            exit 1
        fi
        
        # Parse optional parameters
        dns_type="$2"
        num_runs=1
        
        shift 2  # Remove first two arguments
        while [[ $# -gt 0 ]]; do
            case $1 in
                "--runs"|"-r")
                    if [[ -z "${2:-}" ]] || ! [[ "$2" =~ ^[0-9]+$ ]]; then
                        log "ERROR: --runs requires a positive integer"
                        exit 1
                    fi
                    num_runs="$2"
                    shift 2
                    ;;
                "--duration"|"-t")
                    # Duration parameter for future use
                    shift 2
                    ;;
                *)
                    log "ERROR: Unknown parameter: $1"
                    exit 1
                    ;;
            esac
        done
        
        run_specific_type "$dns_type" "$num_runs"
        ;;
    "--list-types")
        echo "Valid DNS types (only these combinations are supported):"
        printf '%s\n' "${DNS_TYPES[@]}"
        echo ""
        echo "Each type represents a specific combination of DNS components:"
        echo "  cilium+kubedns          - Cilium with kube-dns"
        echo "  cilium+node-local       - Cilium with node-local DNS"
        echo "  cilium+dns+node-local   - Cilium with CoreDNS and node-local DNS"
        echo "  cilium+acns+nld         - Cilium with Azure CNS and node-local DNS"
        echo "  cilium+acnsonly+nld     - Cilium with Azure CNS only and node-local DNS"
        echo "  oss-sdp-only            - OSS SDP only"
        echo "  oss-sdp+dnsproxy        - OSS SDP with DNS Proxy"
        ;;
    *)
        echo "Usage: $0 --type <dns-type> [OPTIONS]|--list-types"
        echo ""
        echo "Environment:"
        echo "  PERF_TESTS_ROOT  Override root directory (default: /home/singhvipul/ws/perf-tests)"
        echo ""
        echo "Options:"
        echo "  --type <type> [OPTIONS]  Run test for specific DNS type"
        echo "    --runs|-r <number>     Number of test runs (default: 1, waits 2min between runs)"
        echo "    --duration|-t <time>   Test duration (e.g., 30s, 2m, 10m)"
        echo "  --list-types             List available DNS types"
        echo ""
        echo "Valid DNS types:"
        printf '  %s\n' "${DNS_TYPES[@]}"
        echo ""
        echo "Examples:"
        echo "  PERF_TESTS_ROOT=/data/ws/perf-tests $0 --type cilium+kubedns" 
        echo "  $0 --type cilium+kubedns --runs 3"
        echo "  $0 -d cilium+node-local -r 5"
        echo "  $0 --type cilium+kubedns --runs 3 -t 30s"
        exit 1
        ;;
 esac
