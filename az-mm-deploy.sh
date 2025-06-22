#!/bin/zsh

VM_NAME="jagan-vm-06032025"
RG_VM="jagan-vm-06032025-rg"
ADMIN_NAME="jagan-admin"
USRNAME="$ADMIN_NAME"
LOCATION="eastus"

ACR_NAME="jaganacr062025"
RG_ACR="jaganacr-062025-rg"


set -e  # Exit on any command failure

# Trap for debugging on error
trap 'echo "❌ Error encountered at line $LINENO with exit code $?"' ERR


create_and_verify_rg() {
  local RG_NAME="$1"
  local LOCATION="$2"

  echo "📦 Creating resource group: $RG_NAME in $LOCATION..."
  az group create --name "$RG_NAME" --location "$LOCATION" --output none

  # Check if the resource group exists
  if az group exists --name "$RG_NAME" | grep -q true; then
    echo "✅ Resource group '$RG_NAME' verified to exist."
    return 0
  else
    echo "❌ Failed to verify resource group '$RG_NAME'."
    return 1
  fi
}

verify_rg() {
  local RG_NAME="$1"

  echo "📦 Verifying the resource group: $RG_NAME..."

  # Check if the resource group exists
  if az group exists --name "$RG_NAME" | grep -q true; then
    echo "✅ Resource group '$RG_NAME' verified to exist."
    return 0
  else
    echo "❌ Failed to verify resource group '$RG_NAME'."
    return 1
  fi
}

wait_for_acr() {
  local ACR_NAME="$1"
  local RG_NAME="$2"

  echo "📦 Waiting for Azure Container Registry '$ACR_NAME' to be ready..."

  while true; do
    STATUS=$(az acr show --name "$ACR_NAME" --resource-group "$RG_NAME" --query "provisioningState" -o tsv)

    if [[ "$STATUS" == "Succeeded" ]]; then
      echo "✅ Azure Container Registry '$ACR_NAME' is ready!"
      return 0
    elif [[ "$STATUS" == "Failed" ]]; then
      echo "❌ ACR creation failed!"
      return 1
    else
      echo "⏳ ACR status: $STATUS. Waiting..."
      sleep 30  # Check every 30 seconds
    fi
  done
}



confirm_action() {
  echo -n "All looks good? Continue? (y/n): "
  read choice
  case "$choice" in 
    y|Y ) 
      echo "✅ Okay, continuing..."
      return 0
      ;;
    * ) 
      echo "❌ Operation canceled."
      return 1
      ;;
  esac
}

create_and_verify_rg $RG_VM "eastus"
verify_rg $RG_VM

echo "🚀 Creating VM: $VM_NAME in resource group $RG_VM..."
az vm create --resource-group "$RG_VM" \
  --name "$VM_NAME" \
  --image Canonical:0001-com-ubuntu-server-focal:20_04-lts:latest \
  --size Standard_NC6s_v3 \
  --admin-username "$ADMIN_NAME" \
  --generate-ssh-keys \
  --os-disk-size-gb 128 \
  --output none

echo "✅ VM '$VM_NAME' creation completed successfully."

#az vm identity assign \
#  --name ${VM_NAME} \
#  --resource-group ${RG_VM}

# Create ACR 
az acr create --name ${ACR_NAME} --resource-group $RG_ACR --sku basic

# wait for ACR to become available
wait_for_acr ${ACR_NAME} ${RG_ACR}


# Example Usage
if confirm_action; then
  echo "Proceeding with the next steps..."
else
  echo "Exiting script."
fi

# Get ACR resource ID (in rg-acr)
ACR_ID=$(az acr show --name ${ACR_NAME} --resource-group ${RG_ACR} --query id --output tsv)

# Get VM's managed identity principal ID (in rg-vm)
#VM_IDENTITY=$(az vm show --name ${VM_NAME} --resource-group ${RG_VM} --query identity.principalId --output tsv)

# Assign AcrPull role across resource groups
#az role assignment create \
#  --assignee "$VM_IDENTITY" \
#  --scope "$ACR_ID" \
#  --role AcrPull


# Get the public IP (fixed variable name)
VM_IP=$(az vm list-ip-addresses \
  --resource-group ${RG_VM} \
  --name ${VM_NAME} \
  --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" \
  --output tsv)

echo "🌐 VM IP Address: $VM_IP"

# SSH and install NVIDIA drivers
ssh -o StrictHostKeyChecking=no ${USRNAME}@${VM_IP} << 'EOF'
  sudo apt-get update && sudo apt-get upgrade -y
  
  # Ensure non-interactive package installation
  sudo DEBIAN_FRONTEND=noninteractive apt-get install -y nvidia-driver-470
  
  sudo nohup reboot &
EOF


# Wait for the system to become reachable again
echo "Waiting for VM to reboot..."

# Loop to check VM availability
while ! ssh -o StrictHostKeyChecking=no -o ConnectTimeout=5 ${USRNAME}@${VM_IP} "echo VM is back online" 2>/dev/null; do
  sleep 5
done

echo "✅ VM rebooted successfully! Running 'nvidia-smi' to verify GPU setup."

# Run NVIDIA driver check after reboot
ssh ${USRNAME}@${VM_IP} "nvidia-smi"

# Install Docker and start service
ssh -o StrictHostKeyChecking=no ${USRNAME}@${VM_IP} << EOF
  ARCH=\$(dpkg --print-architecture)
  distribution=\$(. /etc/os-release; echo \$ID\$VERSION_ID)

  sudo apt-get update
  sudo apt-get install -y docker.io
  sudo systemctl start docker
  sudo systemctl enable docker
  echo "🐳 Docker installed and running."


  # Remove broken NVIDIA repository
  sudo rm -rf /etc/apt/sources.list.d/nvidia-container-toolkit.list
  sudo apt-get update

  # Install NVIDIA CUDA Toolkit (Avoid broken APT repository issues)
  curl -fsSL https://developer.download.nvidia.com/compute/cuda/repos/ubuntu2004/x86_64/cuda-keyring_1.0-1_all.deb -o cuda-keyring.deb || exit 1
  sudo dpkg -i cuda-keyring.deb || exit 1
  sudo apt-get update || exit 1
  #sudo apt-get install -y cuda-toolkit-11-8 || exit 1

  # Install NVIDIA Container Runtime
  sudo apt-get install -y nvidia-container-toolkit || exit 1
  sudo apt-get install -y nvidia-container-runtime || exit 1
  sudo systemctl restart docker
  echo "🧠 NVIDIA Container Toolkit installed and Docker restarted."

  # Install Azure CLI before logging in
  curl -sL https://aka.ms/InstallAzureCLIDeb | sudo bash && sleep 5 || exit 1
  export PATH=\$PATH:/usr/bin
EOF




