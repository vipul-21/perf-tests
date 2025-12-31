#!/bin/bash
# Allow Prometheus to schedule on master/control-plane nodes
export CL2_PROMETHEUS_TOLERATE_MASTER=true
# Enable Prometheus scraping of Cilium Operator metrics (port 9963)
export CL2_PROMETHEUS_SCRAPE_CILIUM_OPERATOR=true
# Enable Prometheus scraping of Cilium Agent metrics (port 9962)
export CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT=true
# Enable Prometheus scraping of ClusterMesh API Server metrics (ports 9962/9963/9964)
export CL2_PROMETHEUS_SCRAPE_CLUSTERMESH_APISERVER=true

# Automatically delete test namespaces after test completion
export DELETE_AUTOMANAGED_NAMESPACES=true

# Number of pods to create per second during test (controls test duration)
export CL2_LOAD_TEST_THROUGHPUT=100  
# Total number of pods to create per node (total pods = NODES × PODS_PER_NODE)
export CL2_PODS_PER_NODE=100

# CPU request for each latency measurement pod in millicores
# Formula: (NODE_CPU_CORES × 0.87 × 1000) ÷ PODS_PER_NODE
# - NODE_CPU_CORES: Total CPU cores on your node (e.g., 4, 8, 16, 32)
# - 0.87: Utilization factor (87% usage, leaving 13% for system overhead)
# - 1000: Conversion from cores to millicores
# - PODS_PER_NODE: Ensures even distribution of latency measurement pods
# 
# Examples:
#   4-core node:  (4 × 0.87 × 1000) ÷ 100 = 34m
#   8-core node:  (8 × 0.87 × 1000) ÷ 100 = 69m
#   16-core node: (16 × 0.87 × 1000) ÷ 100 = 139m
export CL2_LATENCY_POD_CPU=34
# Number of times to repeat the entire test
export CL2_REPEATS=1
# Number of test steps (internal ClusterLoader2 parameter)
export CL2_STEPS=1
# Maximum time allowed for operations (pod creation, deletion, etc.)
export CL2_OPERATION_TIMEOUT="40m"
# Prometheus memory limit multiplier factor (scaled for test cluster size)
export CL2_PROMETHEUS_MEMORY_LIMIT_FACTOR=100.0  # Adjusted for test cluster (2Gi instead of 100Gi)
# Prometheus memory scaling factor (affects memory requests/limits)
export CL2_PROMETHEUS_MEMORY_SCALE_FACTOR=100.0  # Adjusted for test cluster
# Prometheus CPU scaling factor (affects CPU requests/limits)
export CL2_PROMETHEUS_CPU_SCALE_FACTOR=30.0     # Adjusted for test cluster
# Prometheus node selector (commented out - using default scheduling)
#export CL2_PROMETHEUS_NODE_SELECTOR="prometheus:\"true\""
# Maximum acceptable pod startup latency threshold (triggers SLO violation if exceeded)
export CL2_POD_STARTUP_LATENCY_THRESHOLD="3m"
# Enable Cilium-specific metrics collection (agent, operator, clustermesh)
export CL2_CILIUM_METRICS_ENABLED=true
# Disable kubelet metrics collection (not needed for Cilium tests)
export CL2_KUBELET_METRICS_ENABLED=false
# Prometheus scrape interval for Cilium Agent metrics
export CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT_INTERVAL="30s"

if [ $# -lt 6 ] || [ $# -gt 8 ]; then
        echo "Usage: $0 <RESULTSFOLDER> <KUBECONFIG PATH> <RG> <NODES> <DEPLOYMENT SIZE> <SCENARIO> [SLO_NODES] [PROMETHEUS_NODES]"
        echo "  SCENARIO: 'default' or 'ces'"
        echo "  SLO_NODES: (optional) grep pattern to match SLO node names (e.g., 'vmss1' or 'aks-nodepool1')"
        echo "  PROMETHEUS_NODES: (optional) grep pattern to match Prometheus node names (e.g., 'vmss2' or 'aks-nodepool2')"
        echo ""
        echo "Examples:"
        echo "  # Without node labeling:"
        echo "  $0 test-cluster ~/.kube/config my-rg 3 100 default"
        echo ""
        echo "  # With node labeling:"
        echo "  $0 test-cluster ~/.kube/config my-rg 3 100 default 'vmss1' 'vmss2'"
        exit 1
fi
FOLDER="$1"
KUBECONFIG="$2"
RG="$3"
REPLICAS="$5"
SCENARIO="$6"
SLO_NODES="${7:-}"  # Optional: empty if not provided
PROMETHEUS_NODES="${8:-}"  # Optional: empty if not provided

# Number of nodes in the test cluster
export CL2_NODES="$4"
# Number of namespaces to create for test objects
export CL2_NAMESPACES=10
# Number of pod replicas per deployment (affects deploymentsPerNamespace calculation)
export CL2_DEPLOYMENT_SIZE=${REPLICAS}

for i in $(seq 1 1); do
	echo "RUN $i"

	# Label nodes based on VMSS name
	echo "=========================================="
	echo "Labeling specified nodes..."
	echo "=========================================="
	
	# Label SLO nodes
	if [ -n "$SLO_NODES" ]; then
		echo "Labeling SLO nodes matching pattern: $SLO_NODES"
		
		# Get all nodes matching the grep pattern
		matching_nodes=$(kubectl get nodes -o name | grep "$SLO_NODES" | sed 's|node/||')
		
		if [ -z "$matching_nodes" ]; then
			echo "  Warning: No nodes found matching pattern '$SLO_NODES'"
		else
			echo "  Found nodes: $matching_nodes"
			
			while IFS= read -r node_name; do
				echo "  Labeling node $node_name with slo=true"
				kubectl label node "$node_name" "slo=true" --overwrite
				
				# Add node taint for slo workloads
				echo "  Adding taint slo=true:NoSchedule to node $node_name"
				kubectl taint node "$node_name" "slo=true:NoSchedule" --overwrite
			done <<< "$matching_nodes"
		fi
	fi
	
	# Label Prometheus nodes
	if [ -n "$PROMETHEUS_NODES" ]; then
		echo ""
		echo "Labeling Prometheus nodes matching pattern: $PROMETHEUS_NODES"
		
		# Get all nodes matching the grep pattern
		matching_nodes=$(kubectl get nodes -o name | grep "$PROMETHEUS_NODES" | sed 's|node/||')
		
		if [ -z "$matching_nodes" ]; then
			echo "  Warning: No nodes found matching pattern '$PROMETHEUS_NODES'"
		else
			echo "  Found nodes: $matching_nodes"
			
			while IFS= read -r node_name; do
				echo "  Labeling node $node_name with prometheus=true"
				kubectl label node "$node_name" "prometheus=true" --overwrite
			done <<< "$matching_nodes"
		fi
	fi
	
	echo ""
	echo "Node labels updated:"
	kubectl get nodes -L slo,prometheus
	echo ""

	# Uncomment if running more than one run
	#kubectl rollout restart deployment -n kube-system cilium-operator
	#kubectl rollout status deployment -n kube-system cilium-operator
	#kubectl rollout restart ds -n kube-system cilium
	#kubectl rollout status ds -n kube-system cilium

	REPORT_DIR="results/${FOLDER}/$(date +"%Y%m%dT%H%M")/"
	OUTPUT_FILE="${REPORT_DIR}/cl2-output.txt"

	mkdir -p $REPORT_DIR
	CLUSTER_NAME="${RG}/large"

	echo "Cluster Name: ${CLUSTER_NAME}" >> $OUTPUT_FILE
	echo "Start Time: $(date '+%d/%m/%Y %H:%M:%S')" >> $OUTPUT_FILE

	go run cmd/clusterloader.go \
	--kubeconfig "$KUBECONFIG" \
    	--report-dir $REPORT_DIR \
    	--testconfig podstartupanalysis/config.yaml \
    	--provider aks \
	--prometheus-scrape-kubelets=false \
	--prometheus-ready-timeout=15m \
	--enable-prometheus-server=true --v=2 \
    	--experimental-prometheus-snapshot-to-report-dir=true \
    	--tear-down-prometheus-server=false \
    	2>&1 | tee -a $OUTPUT_FILE
	
	#--dry-run \
	#--testoverrides=./modules.yaml 2>&1 | tee -a $OUTPUT_FILE
	#--prometheus-scrape-kubelets=true \
	echo "End Time: $(date '+%d/%m/%Y %H:%M:%S')" >> $OUTPUT_FILE

	# Automatically organize results for perfdash
	echo ""
	echo "=========================================="
	echo "Organizing results for perfdash..."
	echo "=========================================="
	
	# Validate scenario parameter
	if [[ "$SCENARIO" != "default" && "$SCENARIO" != "ces" ]]; then
		echo "Error: SCENARIO must be either 'default' or 'ces'"
		echo "Got: '$SCENARIO'"
		exit 1
	fi
	
	# Determine the job prefix based on scenario
	case "$SCENARIO" in
		"default")
			JOB_PREFIX="pod-startup-default"
			;;
		"ces")
			JOB_PREFIX="pod-startup-ces"
			;;
	esac
	
	BASE_DIR="results/logs"
	mkdir -p "$BASE_DIR/$JOB_PREFIX"
	
	# Find next build number
	BUILD_NUM=1
	while [ -d "$BASE_DIR/$JOB_PREFIX/$BUILD_NUM" ]; do
		BUILD_NUM=$((BUILD_NUM + 1))
	done
	
	echo "  Scenario: $SCENARIO"
	echo "  Job prefix: $JOB_PREFIX"
	echo "  Build number: $BUILD_NUM"
	echo "  Source: $REPORT_DIR"
	
	# Create build directory with artifacts subdirectory
	BUILD_DIR="$BASE_DIR/$JOB_PREFIX/$BUILD_NUM"
	ARTIFACTS_DIR="$BUILD_DIR/artifacts"
	mkdir -p "$ARTIFACTS_DIR"
	
	# Copy all JSON metric files to artifacts directory
	echo "Copying metric files..."
	find "$REPORT_DIR" -maxdepth 1 -name "*.json" -type f -exec cp {} "$ARTIFACTS_DIR/" \;
	
	# Copy additional files if they exist
	if [ -f "$REPORT_DIR/cl2-metadata.json" ]; then
		cp "$REPORT_DIR/cl2-metadata.json" "$ARTIFACTS_DIR/"
	fi
	
	if [ -f "$REPORT_DIR/junit.xml" ]; then
		cp "$REPORT_DIR/junit.xml" "$ARTIFACTS_DIR/"
	fi
	
	# Create finished.json in the build directory (NOT in artifacts)
	cat > "$BUILD_DIR/finished.json" << EOF
{
  "timestamp": $(date +%s),
  "result": "SUCCESS",
  "metadata": {
    "scenario": "$SCENARIO",
    "job-prefix": "$JOB_PREFIX",
    "build-number": $BUILD_NUM,
    "test-folder": "$FOLDER",
    "report-dir": "$REPORT_DIR"
  }
}
EOF
	
	echo "✅ Test results organized successfully!"
	echo "   Location: $BUILD_DIR"
	echo ""

done

echo "=========================================="
echo "All runs complete!"
echo "=========================================="
echo "To view results in perfdash, run:"
echo "   cd ../perfdash && make run-local"
echo ""
echo "Then open: http://localhost:8080"
