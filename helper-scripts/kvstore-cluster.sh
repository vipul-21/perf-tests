#!/bin/bash
set -euo pipefail

# Defaults
VM_NAME="etcd-server"
RESOURCE_GROUP="vipul-kvstore-1-rg"
REGION="westus3"
VM_SIZE="Standard_D96ds_v5"  # 96 vCPUs, 384 GB RAM (v5 generation)
ETCD_VERSION="v3.5.11"
ADMIN_USERNAME="azureuser"
SSH_KEY_PATH="${HOME}/.ssh/id_rsa.pub"
ETCD_DATA_DIR="/var/lib/etcd"
ETCD_PORT="2379"
ETCD_PEER_PORT="2380"
DISK_SIZE_GB="512"
VNET_NAME="vipul-kvstore-1-vnet"
SUBNET_NAME="etcd-subnet"
SUBNET_ADDRESS_PREFIX="10.254.0.0/24"

# Parse Arguments
while [[ "$#" -gt 0 ]]; do
    case $1 in
        -n|--name) VM_NAME="$2"; shift ;;
        -g|--resource-group) RESOURCE_GROUP="$2"; shift ;;
        -r|--region) REGION="$2"; shift ;;
        --vm-size) VM_SIZE="$2"; shift ;;
        --etcd-version) ETCD_VERSION="$2"; shift ;;
        --disk-size) DISK_SIZE_GB="$2"; shift ;;
        --ssh-key) SSH_KEY_PATH="$2"; shift ;;
        --vnet-name) VNET_NAME="$2"; shift ;;
        --subnet-name) SUBNET_NAME="$2"; shift ;;
        --subnet-prefix) SUBNET_ADDRESS_PREFIX="$2"; shift ;;
        -h|--help)
            echo "Usage: $0 [options]"
            echo "Options:"
            echo "  -n, --name              VM name (default: etcd-server)"
            echo "  -g, --resource-group    Resource group (default: vipul-kvstore-rg)"
            echo "  -r, --region            Azure region (default: westus3)"
            echo "  --vm-size               VM size (default: Standard_D96ds_v5)"
            echo "  --etcd-version          etcd version (default: v3.5.11)"
            echo "  --disk-size             Data disk size in GB (default: 512)"
            echo "  --ssh-key               Path to SSH public key (default: ~/.ssh/id_rsa.pub)"
            echo "  --vnet-name             VNet name (default: vipul-kvstore-vnet)"
            echo "  --subnet-name           Subnet name to create (default: etcd-subnet)"
            echo "  --subnet-prefix         Subnet address prefix (default: 10.254.0.0/24)"
            exit 0
            ;;
        *) echo "Unknown parameter: $1"; exit 1 ;;
    esac
    shift
done

# Validate SSH key exists
if [ ! -f "$SSH_KEY_PATH" ]; then
    echo "Error: SSH public key not found at $SSH_KEY_PATH"
    echo "Generate one with: ssh-keygen -t rsa -b 4096"
    exit 1
fi

echo "=========================================="
echo "External etcd Setup Configuration"
echo "=========================================="
echo "VM Name:           $VM_NAME"
echo "Resource Group:    $RESOURCE_GROUP"
echo "VNet Name:         $VNET_NAME"
echo "Subnet Name:       $SUBNET_NAME"
echo "Subnet Prefix:     $SUBNET_ADDRESS_PREFIX"
echo "Region:            $REGION"
echo "VM Size:           $VM_SIZE"
echo "etcd Version:      $ETCD_VERSION"
echo "Data Disk Size:    ${DISK_SIZE_GB}GB"
echo "=========================================="

# Ensure Resource Group exists (don't fail if it already exists)
echo "Ensuring resource group $RESOURCE_GROUP exists..."
az group create --name "$RESOURCE_GROUP" --location "$REGION" --output none 2>/dev/null || echo "Resource group already exists"

# Create NSG with etcd ports
echo "Creating Network Security Group..."
NSG_NAME="${VM_NAME}-nsg"
az network nsg create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NSG_NAME" \
    --output none

# Allow SSH
az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "AllowSSH" \
    --priority 100 \
    --source-address-prefixes '*' \
    --destination-port-ranges 22 \
    --protocol Tcp \
    --access Allow \
    --output none

# Allow etcd client port (2379)
az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "AllowEtcdClient" \
    --priority 200 \
    --source-address-prefixes '*' \
    --destination-port-ranges "$ETCD_PORT" \
    --protocol Tcp \
    --access Allow \
    --output none

# Allow etcd peer port (2380)
az network nsg rule create \
    --resource-group "$RESOURCE_GROUP" \
    --nsg-name "$NSG_NAME" \
    --name "AllowEtcdPeer" \
    --priority 210 \
    --source-address-prefixes '*' \
    --destination-port-ranges "$ETCD_PEER_PORT" \
    --protocol Tcp \
    --access Allow \
    --output none

# Create subnet in existing VNet (assumed to exist)
echo "Creating subnet $SUBNET_NAME in VNet $VNET_NAME..."
az network vnet subnet create \
    --resource-group "$RESOURCE_GROUP" \
    --vnet-name "$VNET_NAME" \
    --name "$SUBNET_NAME" \
    --address-prefix "$SUBNET_ADDRESS_PREFIX" \
    --network-security-group "$NSG_NAME" \
    --output none 2>/dev/null || echo "Subnet already exists or couldn't be created"

# Create Public IP
echo "Creating public IP..."
PUBLIC_IP_NAME="${VM_NAME}-ip"
az network public-ip create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PUBLIC_IP_NAME" \
    --sku Standard \
    --allocation-method Static \
    --output none

# Create NIC
echo "Creating network interface..."
NIC_NAME="${VM_NAME}-nic"
az network nic create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_NAME" \
    --vnet-name "$VNET_NAME" \
    --subnet "$SUBNET_NAME" \
    --public-ip-address "$PUBLIC_IP_NAME" \
    --accelerated-networking true \
    --output none

# Create VM with Premium SSD OS disk
echo "Creating VM $VM_NAME (this may take a few minutes)..."
az vm create \
    --resource-group "$RESOURCE_GROUP" \
    --name "$VM_NAME" \
    --nics "$NIC_NAME" \
    --image Ubuntu2204 \
    --size "$VM_SIZE" \
    --admin-username "$ADMIN_USERNAME" \
    --ssh-key-values "@${SSH_KEY_PATH}" \
    --os-disk-size-gb 128 \
    --storage-sku Premium_LRS \
    --output none

# Attach data disk for etcd
echo "Attaching data disk for etcd..."
DISK_NAME="${VM_NAME}-data"
az vm disk attach \
    --resource-group "$RESOURCE_GROUP" \
    --vm-name "$VM_NAME" \
    --name "$DISK_NAME" \
    --new \
    --size-gb "$DISK_SIZE_GB" \
    --sku Premium_LRS \
    --output none

# Get VM public and private IPs
echo "Retrieving VM IP addresses..."
VM_PUBLIC_IP=$(az network public-ip show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$PUBLIC_IP_NAME" \
    --query ipAddress -o tsv)

VM_PRIVATE_IP=$(az network nic show \
    --resource-group "$RESOURCE_GROUP" \
    --name "$NIC_NAME" \
    --query ipConfigurations[0].privateIPAddress -o tsv)

echo "VM created successfully!"
echo "Public IP:  $VM_PUBLIC_IP"
echo "Private IP: $VM_PRIVATE_IP"

# Create cloud-init script for etcd installation
echo "Preparing etcd installation script..."
TEMP_SCRIPT=$(mktemp)
cat > "$TEMP_SCRIPT" << 'EOFSCRIPT'
#!/bin/bash
set -euo pipefail

ETCD_VERSION="__ETCD_VERSION__"
ETCD_DATA_DIR="__ETCD_DATA_DIR__"
VM_PRIVATE_IP="__VM_PRIVATE_IP__"
VM_NAME="__VM_NAME__"

echo "Installing etcd $ETCD_VERSION..."

# Update system
apt-get update
apt-get install -y wget tar

# Format and mount data disk
echo "Setting up data disk..."
# Find the data disk (look for unformatted disks, excluding OS disk and temp disk)
DATA_DISK=$(lsblk -d -n -o NAME,TYPE | grep disk | awk '{print "/dev/"$1}' | while read disk; do
    # Skip if disk has partitions or filesystems
    if ! lsblk -n -o FSTYPE "$disk" | grep -q .; then
        # Skip OS disk (sda) and temp disk (sdb)
        if [[ ! "$disk" =~ sda$ ]] && [[ ! "$disk" =~ sdb$ ]]; then
            echo "$disk"
            break
        fi
    fi
done)

if [ -n "$DATA_DISK" ] && [ -b "$DATA_DISK" ]; then
    echo "Found data disk: $DATA_DISK"
    parted -s "$DATA_DISK" mklabel gpt
    parted -s "$DATA_DISK" mkpart primary ext4 0% 100%
    sleep 2  # Wait for partition to be created
    PARTITION="${DATA_DISK}1"
    mkfs.ext4 -F "$PARTITION"
    mkdir -p "$ETCD_DATA_DIR"
    echo "$PARTITION $ETCD_DATA_DIR ext4 defaults,nofail 0 2" >> /etc/fstab
    mount "$ETCD_DATA_DIR"
    chown -R root:root "$ETCD_DATA_DIR"
else
    echo "Warning: No data disk found, using root filesystem for etcd data"
    mkdir -p "$ETCD_DATA_DIR"
    chown -R root:root "$ETCD_DATA_DIR"
fi

# Download and install etcd
cd /tmp
wget "https://github.com/etcd-io/etcd/releases/download/${ETCD_VERSION}/etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
tar xzf "etcd-${ETCD_VERSION}-linux-amd64.tar.gz"
mv "etcd-${ETCD_VERSION}-linux-amd64/etcd" /usr/local/bin/
mv "etcd-${ETCD_VERSION}-linux-amd64/etcdctl" /usr/local/bin/
rm -rf "etcd-${ETCD_VERSION}-linux-amd64"*

# Create etcd user
useradd -r -s /bin/false etcd || true
chown -R etcd:etcd "$ETCD_DATA_DIR"

# Generate TLS certificates
mkdir -p /etc/etcd/pki
cd /etc/etcd/pki

# Create CA
openssl genrsa -out ca.key 2048
openssl req -x509 -new -nodes -key ca.key -sha256 -days 3650 \
    -out ca.crt \
    -subj "/CN=etcd-ca"

# Create server certificate
cat > server-csr.conf << EOF
[req]
distinguished_name = req_distinguished_name
req_extensions = v3_req
prompt = no

[req_distinguished_name]
CN = etcd-server

[v3_req]
keyUsage = keyEncipherment, digitalSignature
extendedKeyUsage = serverAuth, clientAuth
subjectAltName = @alt_names

[alt_names]
DNS.1 = localhost
DNS.2 = ${VM_NAME}
IP.1 = 127.0.0.1
IP.2 = ${VM_PRIVATE_IP}
EOF

openssl genrsa -out server.key 2048
openssl req -new -key server.key -out server.csr -config server-csr.conf
openssl x509 -req -in server.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out server.crt -days 3650 -extensions v3_req -extfile server-csr.conf

# Create client certificate
openssl genrsa -out client.key 2048
openssl req -new -key client.key -out client.csr \
    -subj "/CN=etcd-client"
openssl x509 -req -in client.csr -CA ca.crt -CAkey ca.key -CAcreateserial \
    -out client.crt -days 3650

# Set permissions
chown -R etcd:etcd /etc/etcd
chmod 600 /etc/etcd/pki/*.key

# Create systemd service
cat > /etc/systemd/system/etcd.service << EOF
[Unit]
Description=etcd key-value store
Documentation=https://github.com/etcd-io/etcd
After=network.target

[Service]
Type=notify
User=etcd
ExecStart=/usr/local/bin/etcd \\
  --name ${VM_NAME} \\
  --data-dir ${ETCD_DATA_DIR} \\
  --listen-client-urls https://${VM_PRIVATE_IP}:2379,https://127.0.0.1:2379 \\
  --advertise-client-urls https://${VM_PRIVATE_IP}:2379 \\
  --listen-peer-urls https://${VM_PRIVATE_IP}:2380 \\
  --initial-advertise-peer-urls https://${VM_PRIVATE_IP}:2380 \\
  --initial-cluster ${VM_NAME}=https://${VM_PRIVATE_IP}:2380 \\
  --initial-cluster-token etcd-cluster \\
  --initial-cluster-state new \\
  --client-cert-auth \\
  --trusted-ca-file /etc/etcd/pki/ca.crt \\
  --cert-file /etc/etcd/pki/server.crt \\
  --key-file /etc/etcd/pki/server.key \\
  --peer-client-cert-auth \\
  --peer-trusted-ca-file /etc/etcd/pki/ca.crt \\
  --peer-cert-file /etc/etcd/pki/server.crt \\
  --peer-key-file /etc/etcd/pki/server.key \\
  --auto-compaction-retention 1 \\
  --max-request-bytes 33554432 \\
  --quota-backend-bytes 8589934592
Restart=on-failure
RestartSec=5
LimitNOFILE=65536

[Install]
WantedBy=multi-user.target
EOF

# Enable and start etcd
systemctl daemon-reload
systemctl enable etcd
systemctl start etcd

# Wait for etcd to be ready
sleep 5

# Test etcd connection
ETCDCTL_API=3 etcdctl \
    --endpoints=https://127.0.0.1:2379 \
    --cacert=/etc/etcd/pki/ca.crt \
    --cert=/etc/etcd/pki/client.crt \
    --key=/etc/etcd/pki/client.key \
    endpoint health

echo "etcd installation complete!"
EOFSCRIPT

# Replace placeholders
sed -i "s|__ETCD_VERSION__|$ETCD_VERSION|g" "$TEMP_SCRIPT"
sed -i "s|__ETCD_DATA_DIR__|$ETCD_DATA_DIR|g" "$TEMP_SCRIPT"
sed -i "s|__VM_PRIVATE_IP__|$VM_PRIVATE_IP|g" "$TEMP_SCRIPT"
sed -i "s|__VM_NAME__|$VM_NAME|g" "$TEMP_SCRIPT"

# Copy and execute script on VM
echo "Installing etcd on VM (this may take a few minutes)..."
scp -o StrictHostKeyChecking=no "$TEMP_SCRIPT" "${ADMIN_USERNAME}@${VM_PUBLIC_IP}:/tmp/install-etcd.sh"
ssh -o StrictHostKeyChecking=no "${ADMIN_USERNAME}@${VM_PUBLIC_IP}" "sudo bash /tmp/install-etcd.sh"

rm "$TEMP_SCRIPT"

# Download certificates for Cilium
echo "Downloading etcd certificates..."
CERT_DIR="./etcd-certs-${VM_NAME}"
mkdir -p "$CERT_DIR"

ssh "${ADMIN_USERNAME}@${VM_PUBLIC_IP}" "sudo cat /etc/etcd/pki/ca.crt" > "${CERT_DIR}/ca.crt"
ssh "${ADMIN_USERNAME}@${VM_PUBLIC_IP}" "sudo cat /etc/etcd/pki/client.crt" > "${CERT_DIR}/client.crt"
ssh "${ADMIN_USERNAME}@${VM_PUBLIC_IP}" "sudo cat /etc/etcd/pki/client.key" > "${CERT_DIR}/client.key"

echo ""
echo "=========================================="
echo "etcd Setup Complete!"
echo "=========================================="
echo "VM Name:        $VM_NAME"
echo "Public IP:      $VM_PUBLIC_IP"
echo "Private IP:     $VM_PRIVATE_IP"
echo "etcd Version:   $ETCD_VERSION"
echo "Certificates:   $CERT_DIR/"
echo ""
echo "SSH Access:"
echo "  ssh ${ADMIN_USERNAME}@${VM_PUBLIC_IP}"
echo ""
echo "Test etcd connection:"
echo "  ETCDCTL_API=3 etcdctl --endpoints=https://${VM_PRIVATE_IP}:2379 \\"
echo "    --cacert=${CERT_DIR}/ca.crt \\"
echo "    --cert=${CERT_DIR}/client.crt \\"
echo "    --key=${CERT_DIR}/client.key \\"
echo "    endpoint health"
echo ""
echo "To configure Cilium with this etcd, create a Kubernetes secret:"
echo "  kubectl create secret generic cilium-etcd-secrets \\"
echo "    --from-file=ca.crt=${CERT_DIR}/ca.crt \\"
echo "    --from-file=tls.crt=${CERT_DIR}/client.crt \\"
echo "    --from-file=tls.key=${CERT_DIR}/client.key \\"
echo "    -n kube-system"
echo ""
echo "Then use these Cilium values:"
echo "  --set etcd.enabled=true \\"
echo "  --set etcd.ssl=true \\"
echo "  --set etcd.endpoints[0]=https://${VM_PRIVATE_IP}:2379 \\"
echo "  --set identityAllocationMode=kvstore"
echo "=========================================="

# Save connection info
cat > "${CERT_DIR}/etcd-info.txt" << EOF
etcd Server Information
=======================
VM Name:     $VM_NAME
Public IP:   $VM_PUBLIC_IP
Private IP:  $VM_PRIVATE_IP
Region:      $REGION
VM Size:     $VM_SIZE
etcd Port:   2379
Peer Port:   2380

SSH Command:
  ssh ${ADMIN_USERNAME}@${VM_PUBLIC_IP}

etcdctl Test Command:
  ETCDCTL_API=3 etcdctl --endpoints=https://${VM_PRIVATE_IP}:2379 \\
    --cacert=ca.crt --cert=client.crt --key=client.key \\
    endpoint health

Kubernetes Secret Creation:
  kubectl create secret generic cilium-etcd-secrets \\
    --from-file=ca.crt=ca.crt \\
    --from-file=tls.crt=client.crt \\
    --from-file=tls.key=client.key \\
    -n kube-system

Cilium Helm Values:
  --set etcd.enabled=true \\
  --set etcd.ssl=true \\
  --set etcd.endpoints[0]=https://${VM_PRIVATE_IP}:2379 \\
  --set identityAllocationMode=kvstore
EOF

echo "Connection details saved to: ${CERT_DIR}/etcd-info.txt"