#!/bin/bash
set -eu

# Script to set up custom hostNetwork clustermesh-apiserver
# This should be run AFTER Cilium is installed and clustermesh is enabled via cilium CLI

# Parse Arguments
CLUSTER_NAME=""
CLUSTERMESH_IMAGE_REPO="acnpublic.azurecr.io/cilium/clustermesh-apiserver"
CLUSTERMESH_IMAGE_TAG="test2"
CILIUM_IMAGE_REPO="acnpublic.azurecr.io/cilium/cilium"
CILIUM_IMAGE_TAG="ces-node-6"

while [[ "$#" -gt 0 ]]; do
    case $1 in
        --cluster) CLUSTER_NAME="$2"; shift ;;
        --clustermesh-image) CLUSTERMESH_IMAGE_REPO="$2"; shift ;;
        --clustermesh-tag) CLUSTERMESH_IMAGE_TAG="$2"; shift ;;
        --cilium-image) CILIUM_IMAGE_REPO="$2"; shift ;;
        --cilium-tag) CILIUM_IMAGE_TAG="$2"; shift ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

if [ -z "$CLUSTER_NAME" ]; then
    echo "Error: --cluster is required"
    exit 1
fi

echo "=== Setting up custom hostNetwork clustermesh-apiserver ==="
echo "Cluster: ${CLUSTER_NAME}"
echo "Clustermesh image: ${CLUSTERMESH_IMAGE_REPO}:${CLUSTERMESH_IMAGE_TAG}"
echo "Cilium image: ${CILIUM_IMAGE_REPO}:${CILIUM_IMAGE_TAG}"

# Create temporary directory for manifests
TEMP_MESH_DIR=$(mktemp -d)
echo "Using temporary directory: ${TEMP_MESH_DIR}"

# Step 1: Delete the standard clustermesh deployment created by Cilium CLI
echo "Deleting standard clustermesh-apiserver deployment..."
kubectl --context "${CLUSTER_NAME}" -n kube-system delete deployment clustermesh-apiserver --ignore-not-found=true
kubectl --context "${CLUSTER_NAME}" -n kube-system delete service clustermesh-apiserver --ignore-not-found=true

# Step 2: Get ALL node IPs for certificate generation
echo "Getting all node IPs for certificate generation..."
ALL_NODE_IPS=$(kubectl --context "${CLUSTER_NAME}" get nodes -o jsonpath='{.items[*].status.addresses[?(@.type=="InternalIP")].address}')

if [ -z "${ALL_NODE_IPS}" ]; then
    echo "Error: No node IPs found" >&2
    exit 1
fi

echo "Certificate will include all node IPs: ${ALL_NODE_IPS}"

# Step 3: Regenerate server certificates with ALL node IPs
echo "Regenerating server certificates with all node IPs: ${ALL_NODE_IPS}..."

# Extract CA
kubectl --context "${CLUSTER_NAME}" -n kube-system get secret cilium-ca \
    -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TEMP_MESH_DIR}/ca.crt"
kubectl --context "${CLUSTER_NAME}" -n kube-system get secret cilium-ca \
    -o jsonpath='{.data.ca\.key}' | base64 -d > "${TEMP_MESH_DIR}/ca.key"

# Build IP entries for all nodes
IP_ENTRIES="IP.1 = 127.0.0.1
IP.2 = ::1"
ip_index=3
for node_ip in ${ALL_NODE_IPS}; do
    IP_ENTRIES="${IP_ENTRIES}
IP.${ip_index} = ${node_ip}"
    ip_index=$((ip_index + 1))
done

# Create OpenSSL config with all node IPs
cat > "${TEMP_MESH_DIR}/openssl.cnf" <<EOFSSL
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = clustermesh-apiserver.kube-system.svc.cluster.local

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = clustermesh-apiserver.kube-system.svc.cluster.local
DNS.2 = clustermesh-apiserver.kube-system.svc
DNS.3 = clustermesh-apiserver.kube-system
DNS.4 = clustermesh-apiserver
DNS.5 = localhost
DNS.6 = *.mesh.cilium.io
${IP_ENTRIES}
EOFSSL

# Generate new server certificate
openssl genrsa -out "${TEMP_MESH_DIR}/tls.key" 2048
openssl req -new -key "${TEMP_MESH_DIR}/tls.key" \
    -out "${TEMP_MESH_DIR}/tls.csr" -config "${TEMP_MESH_DIR}/openssl.cnf"
openssl x509 -req -in "${TEMP_MESH_DIR}/tls.csr" \
    -CA "${TEMP_MESH_DIR}/ca.crt" \
    -CAkey "${TEMP_MESH_DIR}/ca.key" \
    -CAcreateserial \
    -out "${TEMP_MESH_DIR}/tls.crt" \
    -days 3650 \
    -extensions v3_req \
    -extfile "${TEMP_MESH_DIR}/openssl.cnf"

# Update server certificate secret
kubectl --context "${CLUSTER_NAME}" -n kube-system delete secret clustermesh-apiserver-server-cert --ignore-not-found=true
kubectl --context "${CLUSTER_NAME}" -n kube-system create secret generic clustermesh-apiserver-server-cert \
    --from-file=tls.crt="${TEMP_MESH_DIR}/tls.crt" \
    --from-file=tls.key="${TEMP_MESH_DIR}/tls.key" \
    --from-file=ca.crt="${TEMP_MESH_DIR}/ca.crt"

# Regenerate admin client certificate with correct key usage for etcd
echo "Regenerating admin client certificate..."

# First, check if CA is RSA or ECDSA
CA_KEY_TYPE=$(openssl pkey -in "${TEMP_MESH_DIR}/ca.key" -text -noout 2>/dev/null | head -1)

# Generate client key and certificate
openssl genrsa -out "${TEMP_MESH_DIR}/admin.key" 2048

# Create OpenSSL config for client certificate - matching Cilium CLI format exactly
cat > "${TEMP_MESH_DIR}/client.cnf" <<EOFCLIENT
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = root

[v3_req]
keyUsage = critical, digitalSignature, keyEncipherment
extendedKeyUsage = clientAuth
basicConstraints = critical, CA:FALSE
subjectKeyIdentifier = hash
EOFCLIENT

# Generate CSR
openssl req -new -key "${TEMP_MESH_DIR}/admin.key" \
    -out "${TEMP_MESH_DIR}/admin.csr" \
    -config "${TEMP_MESH_DIR}/client.cnf"

# Sign the certificate with proper extensions
openssl x509 -req \
    -in "${TEMP_MESH_DIR}/admin.csr" \
    -CA "${TEMP_MESH_DIR}/ca.crt" \
    -CAkey "${TEMP_MESH_DIR}/ca.key" \
    -CAcreateserial \
    -out "${TEMP_MESH_DIR}/admin.crt" \
    -days 3650 \
    -sha256 \
    -extfile "${TEMP_MESH_DIR}/client.cnf" \
    -extensions v3_req

# Verify the certificate
echo "Verifying admin client certificate..."
openssl x509 -in "${TEMP_MESH_DIR}/admin.crt" -text -noout | grep -A 15 "X509v3 extensions"
openssl verify -CAfile "${TEMP_MESH_DIR}/ca.crt" "${TEMP_MESH_DIR}/admin.crt"

# Create etcd config with client certificates
echo "Creating etcd config with client certificate authentication..."
cat > "${TEMP_MESH_DIR}/etcd-config.yaml" <<EOFETCDCONFIG
---
endpoints:
- https://127.0.0.1:2379
trusted-ca-file: /var/lib/cilium/etcd-secrets/ca.crt
key-file: /var/lib/cilium/etcd-secrets/tls.key
cert-file: /var/lib/cilium/etcd-secrets/tls.crt
EOFETCDCONFIG

# Create empty users config
echo "Creating users config..."
cat > "${TEMP_MESH_DIR}/users.yaml" <<EOFUSERS
---
# Remote cluster users configuration
EOFUSERS

# Create or update the clustermesh-remote-users ConfigMap
kubectl --context "${CLUSTER_NAME}" -n kube-system create configmap clustermesh-remote-users \
    --from-file=users.yaml="${TEMP_MESH_DIR}/users.yaml" \
    --dry-run=client -o yaml | kubectl --context "${CLUSTER_NAME}" apply -f -

# Update admin client certificate secret with etcd config
kubectl --context "${CLUSTER_NAME}" -n kube-system delete secret clustermesh-apiserver-admin-cert --ignore-not-found=true
kubectl --context "${CLUSTER_NAME}" -n kube-system create secret generic clustermesh-apiserver-admin-cert \
    --from-file=tls.crt="${TEMP_MESH_DIR}/admin.crt" \
    --from-file=tls.key="${TEMP_MESH_DIR}/admin.key" \
    --from-file=ca.crt="${TEMP_MESH_DIR}/ca.crt" \
    --from-file=etcd-config.yaml="${TEMP_MESH_DIR}/etcd-config.yaml"

# Step 4: Deploy custom hostNetwork clustermesh-apiserver
echo "Deploying custom hostNetwork clustermesh-apiserver..."

# Get the Kubernetes service cluster IP to use instead of hostname
K8S_SERVICE_HOST=$(kubectl --context "${CLUSTER_NAME}" get svc kubernetes -n default -o jsonpath='{.spec.clusterIP}')
K8S_SERVICE_PORT=$(kubectl --context "${CLUSTER_NAME}" get svc kubernetes -n default -o jsonpath='{.spec.ports[0].port}')

echo "Using Kubernetes API server: https://${K8S_SERVICE_HOST}:${K8S_SERVICE_PORT}"

cat > "${TEMP_MESH_DIR}/deployment.yaml" <<'EOFMANIFEST'
apiVersion: apps/v1
kind: Deployment
metadata:
  name: clustermesh-apiserver
  namespace: kube-system
  labels:
    app.kubernetes.io/name: clustermesh-apiserver
    app.kubernetes.io/part-of: cilium
    k8s-app: clustermesh-apiserver
spec:
  replicas: 1
  selector:
    matchLabels:
      k8s-app: clustermesh-apiserver
  template:
    metadata:
      labels:
        app.kubernetes.io/name: clustermesh-apiserver
        app.kubernetes.io/part-of: cilium
        k8s-app: clustermesh-apiserver
    spec:
      hostNetwork: true
      dnsPolicy: ClusterFirstWithHostNet
      serviceAccountName: clustermesh-apiserver
      automountServiceAccountToken: true
      nodeSelector:
        kubernetes.io/os: linux
      priorityClassName: system-cluster-critical
      tolerations:
      - operator: Exists
      initContainers:
      - name: etcd-init
        image: CLUSTERMESH_IMAGE
        imagePullPolicy: Always
        command:
        - /usr/bin/clustermesh-apiserver
        args:
        - etcdinit
        - --etcd-cluster-name=clustermesh-apiserver
        - --etcd-initial-cluster-token=$(INITIAL_CLUSTER_TOKEN)
        - --etcd-data-dir=/var/run/etcd
        env:
        - name: CILIUM_CLUSTER_NAME
          valueFrom:
            configMapKeyRef:
              name: cilium-config
              key: cluster-name
        - name: INITIAL_CLUSTER_TOKEN
          valueFrom:
            fieldRef:
              fieldPath: metadata.uid
        volumeMounts:
        - name: etcd-data-dir
          mountPath: /var/run/etcd
      containers:
      - name: etcd
        image: CLUSTERMESH_IMAGE
        imagePullPolicy: Always
        command:
        - /usr/bin/etcd
        args:
        - --data-dir=/var/run/etcd
        - --name=clustermesh-apiserver
        - --client-cert-auth
        - --trusted-ca-file=/var/lib/etcd-secrets/ca.crt
        - --cert-file=/var/lib/etcd-secrets/tls.crt
        - --key-file=/var/lib/etcd-secrets/tls.key
        - --listen-client-urls=https://0.0.0.0:2379
        - --advertise-client-urls=https://127.0.0.1:2379
        - --initial-cluster-token=$(INITIAL_CLUSTER_TOKEN)
        - --auto-compaction-retention=1
        - --listen-metrics-urls=http://0.0.0.0:19963
        - --metrics=basic
        env:
        - name: ETCDCTL_API
          value: "3"
        - name: INITIAL_CLUSTER_TOKEN
          valueFrom:
            fieldRef:
              fieldPath: metadata.uid
        ports:
        - name: etcd
          containerPort: 2379
          hostPort: 2379
          protocol: TCP
        - name: etcd-metrics
          containerPort: 19963
          hostPort: 19963
          protocol: TCP
        volumeMounts:
        - name: etcd-data-dir
          mountPath: /var/run/etcd
        - name: etcd-server-secrets
          mountPath: /var/lib/etcd-secrets
          readOnly: true
      - name: apiserver
        image: CLUSTERMESH_IMAGE
        imagePullPolicy: Always
        command:
        - /usr/bin/clustermesh-apiserver
        args:
        - clustermesh
        - --cluster-name=$(CLUSTER_NAME)
        - --cluster-id=$(CLUSTER_ID)
        - --kvstore-opt=etcd.config=/var/lib/cilium/etcd-config.yaml
        - --kvstore-opt=etcd.qps=20
        - --kvstore-opt=etcd.bootstrapQps=10000
        - --max-connected-clusters=255
        - --health-port=9880
        - --cluster-users-enabled
        - --cluster-users-config-path=/var/lib/cilium/etcd-config/users.yaml
        - --prometheus-serve-addr=:19962
        - --controller-group-metrics=all
        - --enable-cilium-endpoint-slice
        - --k8s-api-server=https://K8S_SERVICE_HOST:K8S_SERVICE_PORT
        env:
        - name: CLUSTER_NAME
          valueFrom:
            configMapKeyRef:
              name: cilium-config
              key: cluster-name
        - name: CLUSTER_ID
          valueFrom:
            configMapKeyRef:
              name: cilium-config
              key: cluster-id
              optional: true
        - name: ENABLE_K8S_ENDPOINT_SLICE
          valueFrom:
            configMapKeyRef:
              name: cilium-config
              key: enable-k8s-endpoint-slice
              optional: true
        ports:
        - name: apiserv-health
          containerPort: 9880
          hostPort: 9880
          protocol: TCP
        - name: apiserv-metrics
          containerPort: 19962
          hostPort: 19962
          protocol: TCP
        readinessProbe:
          httpGet:
            path: /readyz
            port: apiserv-health
            scheme: HTTP
        volumeMounts:
        - name: etcd-admin-client
          mountPath: /var/lib/cilium/etcd-secrets
          readOnly: true
        - name: etcd-users-config
          mountPath: /var/lib/cilium/etcd-config
          readOnly: true
      - name: kvstoremesh
        image: CLUSTERMESH_IMAGE
        imagePullPolicy: Always
        command:
        - /usr/bin/clustermesh-apiserver
        args:
        - kvstoremesh
        - --cluster-name=$(CLUSTER_NAME)
        - --cluster-id=$(CLUSTER_ID)
        - --kvstore-opt=etcd.config=/var/lib/cilium/etcd-config.yaml
        - --kvstore-opt=etcd.qps=100
        - --kvstore-opt=etcd.bootstrapQps=10000
        - --kvstore-opt=etcd.maxInflight=10
        - --clustermesh-config=/var/lib/cilium/clustermesh
        - --max-connected-clusters=255
        - --clustermesh-cache-ttl=0s
        - --health-port=9881
        - --prometheus-serve-addr=:19964
        - --controller-group-metrics=all
        - --enable-heartbeat=false
        env:
        - name: CLUSTER_NAME
          valueFrom:
            configMapKeyRef:
              name: cilium-config
              key: cluster-name
        - name: CLUSTER_ID
          valueFrom:
            configMapKeyRef:
              name: cilium-config
              key: cluster-id
        ports:
        - name: kvmesh-health
          containerPort: 9881
          hostPort: 9881
          protocol: TCP
        - name: kvmesh-metrics
          containerPort: 19964
          hostPort: 19964
          protocol: TCP
        readinessProbe:
          httpGet:
            path: /readyz
            port: kvmesh-health
            scheme: HTTP
        volumeMounts:
        - name: etcd-admin-client
          mountPath: /var/lib/cilium/etcd-secrets
          readOnly: true
        - name: kvstoremesh-secrets
          mountPath: /var/lib/cilium/clustermesh
          readOnly: true
      volumes:
      - name: etcd-data-dir
        emptyDir: {}
      - name: etcd-server-secrets
        projected:
          defaultMode: 420
          sources:
          - secret:
              name: clustermesh-apiserver-server-cert
      - name: etcd-admin-client
        projected:
          defaultMode: 420
          sources:
          - secret:
              name: clustermesh-apiserver-admin-cert
      - name: etcd-users-config
        configMap:
          name: clustermesh-remote-users
      - name: kvstoremesh-secrets
        projected:
          defaultMode: 420
          sources:
          - secret:
              name: cilium-kvstoremesh
              optional: true
          - secret:
              name: clustermesh-apiserver-remote-cert
              optional: true
EOFMANIFEST

# Replace placeholders in deployment
sed -i "s|CLUSTERMESH_IMAGE|${CLUSTERMESH_IMAGE_REPO}:${CLUSTERMESH_IMAGE_TAG}|g" "${TEMP_MESH_DIR}/deployment.yaml"
sed -i "s|K8S_SERVICE_HOST|${K8S_SERVICE_HOST}|g" "${TEMP_MESH_DIR}/deployment.yaml"
sed -i "s|K8S_SERVICE_PORT|${K8S_SERVICE_PORT}|g" "${TEMP_MESH_DIR}/deployment.yaml"

# Apply the deployment
kubectl --context "${CLUSTER_NAME}" apply -f "${TEMP_MESH_DIR}/deployment.yaml"

# Wait for deployment to be ready
echo "Waiting for clustermesh-apiserver to be ready..."
kubectl --context "${CLUSTER_NAME}" -n kube-system rollout status deployment/clustermesh-apiserver --timeout=600s

# Detect which node the pod actually landed on
echo "Detecting which node clustermesh-apiserver is running on..."
ACTUAL_NODE_NAME=$(kubectl --context "${CLUSTER_NAME}" -n kube-system get pod -l k8s-app=clustermesh-apiserver -o jsonpath='{.items[0].spec.nodeName}')
ACTUAL_NODE_IP=$(kubectl --context "${CLUSTER_NAME}" get node "${ACTUAL_NODE_NAME}" -o jsonpath='{.status.addresses[?(@.type=="InternalIP")].address}')

if [ -z "${ACTUAL_NODE_IP}" ]; then
    echo "Error: Could not determine node IP for clustermesh-apiserver pod" >&2
    exit 1
fi

echo "✓ Clustermesh-apiserver is running on node: ${ACTUAL_NODE_NAME} (${ACTUAL_NODE_IP})"

# Step 5: Create cilium-clustermesh secret for agents to connect
echo "Creating clustermesh config secret for Cilium agents: ${ACTUAL_NODE_IP}:2379..."

# Get admin certificates and decode them to files
kubectl --context "${CLUSTER_NAME}" -n kube-system get secret cilium-ca -o jsonpath='{.data.ca\.crt}' | base64 -d > "${TEMP_MESH_DIR}/ca.crt"
kubectl --context "${CLUSTER_NAME}" -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\.key}' | base64 -d > "${TEMP_MESH_DIR}/client.key"
kubectl --context "${CLUSTER_NAME}" -n kube-system get secret clustermesh-apiserver-admin-cert -o jsonpath='{.data.tls\.crt}' | base64 -d > "${TEMP_MESH_DIR}/client.crt"

# Generate clustermesh config with the ACTUAL node IP where pod is running
cat > "${TEMP_MESH_DIR}/clustermesh-config" <<EOFCONFIG
endpoints:
- https://${ACTUAL_NODE_IP}:2379
trusted-ca-file: /var/lib/cilium/clustermesh/${CLUSTER_NAME}.etcd-client-ca.crt
key-file: /var/lib/cilium/clustermesh/${CLUSTER_NAME}.etcd-client.key
cert-file: /var/lib/cilium/clustermesh/${CLUSTER_NAME}.etcd-client.crt
EOFCONFIG

# Create the secret with Helm labels and annotations
# Use --from-file for all entries to avoid double base64 encoding
kubectl --context "${CLUSTER_NAME}" -n kube-system create secret generic cilium-clustermesh \
    --from-file="${CLUSTER_NAME}=${TEMP_MESH_DIR}/clustermesh-config" \
    --from-file="${CLUSTER_NAME}.etcd-client-ca.crt=${TEMP_MESH_DIR}/ca.crt" \
    --from-file="${CLUSTER_NAME}.etcd-client.key=${TEMP_MESH_DIR}/client.key" \
    --from-file="${CLUSTER_NAME}.etcd-client.crt=${TEMP_MESH_DIR}/client.crt" \
    --dry-run=client -o yaml | kubectl --context "${CLUSTER_NAME}" apply -f -

# Add Helm labels and annotations to the secret
kubectl --context "${CLUSTER_NAME}" -n kube-system label secret cilium-clustermesh \
    app.kubernetes.io/managed-by=Helm \
    app.kubernetes.io/part-of=cilium \
    --overwrite

kubectl --context "${CLUSTER_NAME}" -n kube-system annotate secret cilium-clustermesh \
    meta.helm.sh/release-name=cilium \
    meta.helm.sh/release-namespace=kube-system \
    --overwrite

# Step 6: Configure Cilium to enable clustermesh and sync CiliumNodes
echo "Configuring Cilium to enable clustermesh and read CiliumNodes from clustermesh API server..."

# Update cilium-config ConfigMap to enable clustermesh and the read-ces-from-clustermesh flag
kubectl --context "${CLUSTER_NAME}" -n kube-system get configmap cilium-config -o yaml | \
    sed '/^data:/a\  clustermesh-config: /var/lib/cilium/clustermesh/\n  read-ces-from-clustermesh: "true"' | \
    kubectl --context "${CLUSTER_NAME}" apply -f -

# Patch the Cilium DaemonSet to mount clustermesh secrets
echo "Patching Cilium DaemonSet to mount clustermesh configuration..."
kubectl --context "${CLUSTER_NAME}" -n kube-system patch daemonset cilium --type=json -p='[
  {
    "op": "add",
    "path": "/spec/template/spec/volumes/-",
    "value": {
      "name": "clustermesh-secrets",
      "projected": {
        "defaultMode": 256,
        "sources": [
          {
            "secret": {
              "name": "cilium-clustermesh",
              "optional": true
            }
          },
          {
            "secret": {
              "name": "clustermesh-apiserver-remote-cert",
              "optional": true
            }
          }
        ]
      }
    }
  },
  {
    "op": "add",
    "path": "/spec/template/spec/containers/0/volumeMounts/-",
    "value": {
      "name": "clustermesh-secrets",
      "mountPath": "/var/lib/cilium/clustermesh",
      "readOnly": true
    }
  }
]' || echo "Volume mount may already exist, continuing..."

# Step 7: Update Cilium agent image
echo "Updating Cilium agent image to ${CILIUM_IMAGE_REPO}:${CILIUM_IMAGE_TAG}..."
kubectl --context "${CLUSTER_NAME}" -n kube-system set image daemonset/cilium \
    cilium-agent="${CILIUM_IMAGE_REPO}:${CILIUM_IMAGE_TAG}"

# Wait for Cilium agents to be updated
echo "Waiting for Cilium agents to be updated..."
kubectl --context "${CLUSTER_NAME}" -n kube-system rollout status daemonset/cilium --timeout=15m

# Step 8: Force restart of Cilium agents to pick up clustermesh secret
echo "Restarting Cilium agents to pick up clustermesh configuration..."
kubectl --context "${CLUSTER_NAME}" -n kube-system rollout restart daemonset/cilium

# Wait for restart to complete
echo "Waiting for Cilium agents to restart..."
kubectl --context "${CLUSTER_NAME}" -n kube-system rollout status daemonset/cilium --timeout=15m

# Clean up temp directory
rm -rf "${TEMP_MESH_DIR}"

echo ""
echo "✅ Clustermesh setup complete!"
echo "   📍 Clustermesh-apiserver deployed in hostNetwork mode"
echo "   📍 Running on node: ${ACTUAL_NODE_NAME} (${ACTUAL_NODE_IP})"
echo "   📍 Cilium agents updated with custom image: ${CILIUM_IMAGE_REPO}:${CILIUM_IMAGE_TAG}"
echo "   📍 Clustermesh enabled - agents will read CiliumNodes from clustermesh API server"
echo ""
echo "Verification:"
echo "  kubectl --context ${CLUSTER_NAME} -n kube-system get pod -l k8s-app=clustermesh-apiserver"
echo "  kubectl --context ${CLUSTER_NAME} -n kube-system get pod -l k8s-app=cilium"
echo "  kubectl --context ${CLUSTER_NAME} -n kube-system logs -l k8s-app=cilium -c cilium-agent | grep -i clustermesh"
echo "  kubectl --context ${CLUSTER_NAME} -n kube-system exec -it ds/cilium -c cilium-agent -- cilium-dbg clustermesh status"

# Rollout core dns pods
echo "Restarting CoreDNS pods to ensure DNS resolution works with clustermesh..."
kubectl --context "${CLUSTER_NAME}" -n kube-system rollout restart deployment/coredns