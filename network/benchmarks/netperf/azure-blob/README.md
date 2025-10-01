# Azure Blob FIO Benchmark

This utility provisions a blob container through the Azure Blob CSI driver and runs an `fio` workload against it. The flow relies on managed identity authentication so that storage accounts configured without shared keys (`Allow shared key access` disabled) can still be mounted from AKS nodes.

## Prerequisites

- Azure CLI logged in with access to the target subscription
- `kubectl`, `helm`, `jq`, and `envsubst` (provided by `gettext`) available in your shell
- An AKS cluster with the [Azure Blob CSI driver](https://github.com/kubernetes-sigs/blob-csi-driver) supported
- The `netperf` namespace created in the cluster (the `create.sh` script does not create it)

## Required environment variables

Before running `create.sh`, export the following variables:

| Variable | Description |
| --- | --- |
| `STORAGE_RG` | Resource group that owns (or will own) the storage account. |
| `STORAGE_ACCOUNT` | Name of the storage account to mount. The script creates it if it does not exist. |
| `PRINCIPAL_ID` | Object ID of the managed identity used by the node pool (typically the `aks-<cluster>-agentpool` identity). |
| `SUBSCRIPTION` | Azure subscription ID that contains the resources. |
| `CLUSTER_TYPE` | Label used to group run artifacts (for example `baseline`, `cilium`, `accelerated`). |

Optional overrides:

| Variable | Default | Description |
| --- | --- | --- |
| `MANAGED_RG` | `MC_vipul-cilium_vipul-cilium_eastus2` | Resource group that contains the managed identity. Override if your cluster uses a different node resource group. |
| `LOCATION` | `eastus` | Azure region for storage account creation when absent. |
| `BLOB_CONTAINER` | `fio-workload` | Blob container name to mount. |
| `AKS_CLUSTER_RG` | `vipul-cilium` | Resource group for the AKS cluster (used to resolve the control-plane identity automatically). |
| `AKS_CLUSTER_NAME` | `vipul-cilium` | AKS cluster name. |
| `CONTROL_PLANE_PRINCIPAL_ID` | _(resolved dynamically)_ | Override if the control-plane managed identity can’t be queried automatically. |
| `AZURE_STORAGE_IDENTITY_CLIENT_ID` | _(resolved dynamically)_ | Client ID of the managed identity. Populate manually if resolution via `PRINCIPAL_ID` fails. |
| `FIO_IMAGE` | `registry.k8s.io/e2e-test-images/fio:1.28.4` | Container image used for the fio runner pod. |
| `BLOCK_SIZES` | `"4k 64k 1M 64M 256M 1G 2G"` | Space-delimited list of block sizes (defaults now include large sequential tests up to 2&nbsp;GiB blocks). |
| `FIO_RUNTIME` | `120` | Run duration (seconds) for each fio invocation. |
| `LOCAL_RESULTS_DIR` | `fio-results` | Local directory where JSON reports are copied. |

If you prefer the script to derive the kubelet identity automatically, skip `PRINCIPAL_ID` and instead provide `AKS_CLUSTER_RG` and `AKS_CLUSTER_NAME` so it can look up the object ID.

## Managed identity permissions

`create.sh` grants:

- `Storage Blob Data Contributor` and `Storage Account Contributor` to the kubelet managed identity (`PRINCIPAL_ID`).
- `Storage Account Contributor` to the AKS control-plane identity (resolved automatically or overridden via `CONTROL_PLANE_PRINCIPAL_ID`).

If assignments already exist the commands are ignored. Role propagation can take ~30 seconds; the script waits briefly before applying manifests.

## Running the workflow

```bash
export STORAGE_RG=your-storage-rg
export STORAGE_ACCOUNT=yourblobaccount
export PRINCIPAL_ID=<object-id-of-node-managed-identity>
export SUBSCRIPTION=<subscription-id>
export CLUSTER_TYPE=<cluster-label>
# optional: export MANAGED_RG=MC_yourcluster_yourcluster_region

./create.sh
```

The script performs the following steps:

1. Creates the storage account (if missing) with shared-key access disabled.
2. Ensures the blob container exists using Azure AD login.
3. Resolves the managed identity client ID and applies the role assignments.
4. Installs or upgrades the Blob CSI driver Helm chart.
5. Applies the templated StorageClass (`azure-blob-fio`), PVC, and `fio` runner Pod.
6. For each block size in `BLOCK_SIZES`, runs sequential write and read tests, collects the JSON reports under `${LOCAL_RESULTS_DIR}/${CLUSTER_TYPE}`, and prints a quick summary via `jq`.
7. Cleans up the pod, PVC, and StorageClass when the sweep finishes.

When finished, clean up the resources with:

```bash
kubectl delete pod fio-blob-runner -n netperf
kubectl delete pvc fio-blob-pvc -n netperf
kubectl delete storageclass azure-blob-fio
# Delete the storage account manually if it was created only for this test.
```

## Troubleshooting

- **`KeyBasedAuthenticationNotPermitted`**: Confirm that the manifest rendered from `storageclass-azure-blob-fio.yaml` includes `AzureStorageAuthType: MSI` and a valid `AzureStorageIdentityClientID`. The generated YAML is available via `envsubst < storageclass-azure-blob-fio.yaml`.
- **`forbidden` on role assignment**: Make sure your Azure identity has permissions to assign roles at the required scope. You may need subscription-level `Owner` or `User Access Administrator` rights.
- **PVC stuck in `Pending`**: Check `kubectl describe pvc fio-blob-pvc -n netperf` for CSI driver events and verify the managed identity appears on the agent pool via `az identity list -g "$MANAGED_RG"`.
