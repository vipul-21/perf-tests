#!/bin/bash

set -euo pipefail

: "${STORAGE_RG:?Environment variable STORAGE_RG must be set (resource group for the storage account).}"
: "${STORAGE_ACCOUNT:?Environment variable STORAGE_ACCOUNT must be set (storage account name).}"
: "${SUBSCRIPTION:?Environment variable SUBSCRIPTION must be set (subscription ID).}"
: "${CLUSTER_TYPE:?Environment variable CLUSTER_TYPE must be set (cluster type label for organizing results).}"

PRINCIPAL_ID=${PRINCIPAL_ID:-}
AKS_CLUSTER_RG=${AKS_CLUSTER_RG:-}
AKS_CLUSTER_NAME=${AKS_CLUSTER_NAME:-}

MANAGED_RG=${MANAGED_RG:-MC_vipul-cilium_vipul-cilium_eastus2}
LOCATION=${LOCATION:-eastus}
if [[ -z "${PRINCIPAL_ID}" ]]; then
  if [[ -z "${AKS_CLUSTER_RG}" || -z "${AKS_CLUSTER_NAME}" ]]; then
    echo "PRINCIPAL_ID is not set. Provide AKS_CLUSTER_RG and AKS_CLUSTER_NAME to resolve it automatically." >&2
    exit 1
  fi

  echo "Deriving kubelet principal ID from AKS cluster ${AKS_CLUSTER_RG}/${AKS_CLUSTER_NAME}..."
  PRINCIPAL_ID=$(az aks show -g "${AKS_CLUSTER_RG}" -n "${AKS_CLUSTER_NAME}" \
    --query identityProfile.kubeletidentity.objectId -o tsv 2>/dev/null || true)

  if [[ -z "${PRINCIPAL_ID}" || "${PRINCIPAL_ID}" == "null" ]]; then
    NODE_RG=$(az aks show -g "${AKS_CLUSTER_RG}" -n "${AKS_CLUSTER_NAME}" --query nodeResourceGroup -o tsv)
    if [[ -n "${NODE_RG}" ]]; then
      PRINCIPAL_ID=$(az identity list -g "${NODE_RG}" \
        --query "[?contains(name, 'agentpool')].principalId | [0]" -o tsv 2>/dev/null || true)
    fi
  fi

  if [[ -z "${PRINCIPAL_ID}" || "${PRINCIPAL_ID}" == "null" ]]; then
    echo "Failed to resolve PRINCIPAL_ID automatically. Please export it manually." >&2
    exit 1
  fi
fi

BLOB_CONTAINER=${BLOB_CONTAINER:-fio-workload}
BLOCK_SIZES=${BLOCK_SIZES:-"4k 64k 1M 64M 256M 1G 2G"}
FIO_RUNTIME=${FIO_RUNTIME:-120}
LOCAL_RESULTS_DIR=${LOCAL_RESULTS_DIR:-fio-results}
RESULTS_DIR="${LOCAL_RESULTS_DIR}/${CLUSTER_TYPE}"

echo "Ensuring storage account ${STORAGE_ACCOUNT} exists in ${STORAGE_RG}..."
if ! az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${STORAGE_RG}" >/dev/null 2>&1; then
  az storage account create \
    --name "${STORAGE_ACCOUNT}" \
    --resource-group "${STORAGE_RG}" \
    --location "${LOCATION}" \
    --sku Standard_LRS \
    --kind StorageV2 \
    --allow-shared-key-access false
fi

echo "Ensuring blob container ${BLOB_CONTAINER} exists..."
az storage container create \
  --account-name "${STORAGE_ACCOUNT}" \
  --name "${BLOB_CONTAINER}" \
  --auth-mode login \
  --only-show-errors >/dev/null

echo "Resolving managed identity client ID from principal ${PRINCIPAL_ID}..."
if [[ -z "${AZURE_STORAGE_IDENTITY_CLIENT_ID:-}" ]]; then
  AZURE_STORAGE_IDENTITY_CLIENT_ID=$(az identity list --resource-group "${MANAGED_RG}" \
    --query "[?principalId=='${PRINCIPAL_ID}'].clientId | [0]" -o tsv)
fi

if [[ -z "${AZURE_STORAGE_IDENTITY_CLIENT_ID:-}" ]]; then
  echo "Failed to resolve AZURE_STORAGE_IDENTITY_CLIENT_ID; please export it manually." >&2
  exit 1
fi

echo "Granting managed identity access to the storage account..."
STORAGE_ACCOUNT_ID=$(az storage account show --name "${STORAGE_ACCOUNT}" --resource-group "${STORAGE_RG}" --query id -o tsv)
az role assignment create \
  --assignee-object-id "${PRINCIPAL_ID}" \
  --role "Storage Blob Data Contributor" \
  --scope "${STORAGE_ACCOUNT_ID}" \
  --only-show-errors >/dev/null || true
az role assignment create \
  --assignee-object-id "${PRINCIPAL_ID}" \
  --role "Storage Account Contributor" \
  --scope "/subscriptions/${SUBSCRIPTION}/resourceGroups/${STORAGE_RG}" \
  --only-show-errors >/dev/null || true

export STORAGE_RG STORAGE_ACCOUNT BLOB_CONTAINER AZURE_STORAGE_IDENTITY_CLIENT_ID

echo "Installing/upgrading Blob CSI driver chart..."
helm repo add blob-csi-driver https://raw.githubusercontent.com/kubernetes-sigs/blob-csi-driver/master/charts >/dev/null
helm upgrade --install blob-csi-driver blob-csi-driver/blob-csi-driver --namespace kube-system >/dev/null

echo "Cleaning any existing resources..."
kubectl delete pod fio-blob-runner -n netperf --ignore-not-found
kubectl delete pvc fio-blob-pvc -n netperf --ignore-not-found
kubectl delete storageclass azure-blob-fio --ignore-not-found

echo "Applying Kubernetes manifests..."
envsubst < storageclass-azure-blob-fio.yaml | kubectl apply -f -
kubectl apply -f pvc-fio-blob.yaml
envsubst < fio-blob-runner.yaml | kubectl apply -f -

kubectl wait --namespace netperf --for=jsonpath='{.status.phase}'=Bound pvc/fio-blob-pvc --timeout=5m
kubectl wait --namespace netperf --for=condition=Ready pod/fio-blob-runner --timeout=5m

mkdir -p "${RESULTS_DIR}"
echo "Results will be copied to ${RESULTS_DIR}"

for bs in ${BLOCK_SIZES}; do
  echo "Running write workload with block size ${bs}..."
  kubectl exec -n netperf fio-blob-runner -- \
    fio --name="blob-write-${bs}" --directory=/mnt/blob \
        --rw=write --bs="${bs}" --size=4G --ioengine=libaio --iodepth=16 \
        --runtime="${FIO_RUNTIME}" --numjobs=1 --time_based \
        --group_reporting --output="/mnt/blob/fio-write-${bs}.json" \
        --output-format=json

  kubectl cp -n netperf fio-blob-runner:"/mnt/blob/fio-write-${bs}.json" "${RESULTS_DIR}/fio-write-${bs}.json"
  kubectl exec -n netperf fio-blob-runner -- cat \
    "/mnt/blob/fio-write-${bs}.json" | jq \
      --arg mode "write" --arg bs "${bs}" \
      '.jobs[0] | {mode:$mode, bs:$bs, bw_MBps:(((.write.bw // 0) / 1024)), iops:(.write.iops // 0), lat_ns:(.write.lat_ns // null)}'

  echo "Running read workload with block size ${bs}..."
  kubectl exec -n netperf fio-blob-runner -- \
    fio --name="blob-read-${bs}" --directory=/mnt/blob \
        --rw=read --bs="${bs}" --size=4G --ioengine=libaio --iodepth=16 \
        --runtime="${FIO_RUNTIME}" --numjobs=1 --time_based \
        --group_reporting --output="/mnt/blob/fio-read-${bs}.json" \
        --output-format=json

  kubectl cp -n netperf fio-blob-runner:"/mnt/blob/fio-read-${bs}.json" "${RESULTS_DIR}/fio-read-${bs}.json"
  kubectl exec -n netperf fio-blob-runner -- cat \
    "/mnt/blob/fio-read-${bs}.json" | jq \
      --arg mode "read" --arg bs "${bs}" \
      '.jobs[0] | {mode:$mode, bs:$bs, bw_MBps:(((.read.bw // 0) / 1024)), iops:(.read.iops // 0), lat_ns:(.read.lat_ns // null)}'
done

kubectl delete pod fio-blob-runner -n netperf
kubectl delete pvc fio-blob-pvc -n netperf
kubectl delete storageclass azure-blob-fio