#!/bin/bash
export CL2_PROMETHEUS_TOLERATE_MASTER=true
export CL2_PROMETHEUS_SCRAPE_CILIUM_OPERATOR=true
export CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT=true

export DELETE_AUTOMANAGED_NAMESPACES=true

export CL2_LOAD_TEST_THROUGHPUT=100
export CL2_PODS_PER_NODE=100 # Warm Up

export CL2_LATENCY_POD_CPU=34 # (4 * 0.87 * 1000) // $PODS_PER_NODE
export CL2_REPEATS=1
export CL2_STEPS=1
export CL2_OPERATION_TIMEOUT="40m"
export CL2_PROMETHEUS_TOLERATE_MASTER=true
export CL2_PROMETHEUS_MEMORY_LIMIT_FACTOR=100.0
export CL2_PROMETHEUS_MEMORY_SCALE_FACTOR=100.0
export CL2_PROMETHEUS_CPU_SCALE_FACTOR=30.0
#export CL2_PROMETHEUS_NODE_SELECTOR="prometheus:\"true\""
export CL2_POD_STARTUP_LATENCY_THRESHOLD="3m"
export CL2_CILIUM_METRICS_ENABLED=true
export CL2_KUBELET_METRICS_ENABLED=false
export CL2_PROMETHEUS_SCRAPE_CILIUM_AGENT_INTERVAL="30s"

#export KUBECONFIG="$HOME/.kube/config"

# CL2 hardcodes module paths to live in ./testing/load, even
# if the path given is relative.
# cp ./podstartupanalysis/measurements.yaml ./testing/load
# echo \
#    '{"CL2_ADDITIONAL_MEASUREMENT_MODULES": ["./additional-measurements.yaml"]}' \
# > modules.yaml

if [ $# -ne 4 ]; then
        echo "Usage: $0 <RESULTSFOLDER> <KUBECONFIG PATH> <RG> <NODES>"
        exit 1
fi
FOLDER="$1"
KUBECONFIG="$2"
RG="$3"

export CL2_NODES="$4"
export CL2_NAMESPACES=100
export CL2_DEPLOYMENT_SIZE=${REPLICAS}

for i in $(seq 1 1); do
	echo "RUN $i"

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
    	--testconfig netpolanalysis/config.yaml \
    	--provider aks \
	--prometheus-scrape-kubelets=false \
	--prometheus-ready-timeout=15m \
	--enable-prometheus-server=true --v=2 \
    	--experimental-prometheus-snapshot-to-report-dir=true \
    	--tear-down-prometheus-server=true \
    	2>&1 | tee -a $OUTPUT_FILE
	
	#--dry-run \
	#--testoverrides=./modules.yaml 2>&1 | tee -a $OUTPUT_FILE
	#--prometheus-scrape-kubelets=true \
	echo "End Time: $(date '+%d/%m/%Y %H:%M:%S')" >> $OUTPUT_FILE

done
