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

# Assign Managed Identity to the VM
az vm identity assign --name ${VM_NAME} --resource-group ${RG_VM}
echo "✅ VM Identity Assigned successfully."

# Retrieve Managed Identity Principal ID
MANAGED_ID=$(az vm show --name ${VM_NAME} --resource-group ${RG_VM} --query identity.principalId -o tsv)

# Get ACR Scope
SCOPE=$(az acr show --name ${ACR_NAME} --query id --output tsv)

# Assign AcrPull Role to the Managed Identity
az role assignment create --assignee ${MANAGED_ID} --role AcrPull --scope ${SCOPE}
echo "✅ Role Assigned to the Identity successfully."

# Verify Role Assignment
az role assignment list --assignee ${MANAGED_ID} --role AcrPull --scope ${SCOPE}

# Extract subscription id
subscription_id=$(az account show --query id --output tsv)

# Retrieve VM Public IP
VM_IP=$(az vm list-ip-addresses --resource-group ${RG_VM} --name ${VM_NAME} --query "[0].virtualMachine.network.publicIpAddresses[0].ipAddress" --output tsv)


# Wait for Managed Identity to be ready
echo "⏳ Waiting for VM's Managed Identity to be ready..."
for i in {1..6}; do
  result=$(az vm run-command invoke \
    --resource-group ${RG_VM} \
    --name ${VM_NAME} \
    --command-id RunShellScript \
    --scripts "az login --identity --allow-no-subscriptions && az account show --query id -o tsv" \
    --query 'value[0].message' -o tsv 2>/dev/null)

  if [[ -n "$result" && "$result" != *"ERROR"* ]]; then
    echo "✅ Managed Identity is ready with subscription ID: $result"
    break
  else
    echo "⏳ Waiting for Managed Identity to fully initialize... retrying in 10s"
    sleep 10
  fi
done

# SSH into VM to Configure Docker and Pull Image (with retries)
for i in {1..3}; do
  echo "🔐 Attempting SSH and setup (try $i)..."
  ssh -o StrictHostKeyChecking=no ${USRNAME}@${VM_IP} <<EOF
    set -e

    # Login with Managed Identity
    az login --identity --allow-no-subscriptions
    az account show
    echo "✅ VM logged in with Identity."

    # Ensure Docker is running
    sudo systemctl status docker --no-pager || sudo systemctl start docker

    # Add user to Docker group
    sudo usermod -aG docker \$USER
    newgrp docker

    # Get ACR access token
    ACCESS_TOKEN=\$(az acr login --name ${ACR_NAME} --expose-token --output tsv --query accessToken)
    echo "✅ Extracted access-token successfully."

    # Authenticate with Docker
    docker login ${ACR_NAME}.azurecr.io --username 00000000-0000-0000-0000-000000000000 --password \${ACCESS_TOKEN}
    echo "✅ Docker logged in with access-token."

    # Ensure Docker socket permissions
    sudo chmod 666 /var/run/docker.sock

    # Pull the container image
    docker pull ${ACR_NAME}.azurecr.io/mm-openlab-jupyter:latest
    echo "✅ Image was successfully pulled in."

    # Run the Docker container
    # sudo docker run --gpus all -p 8888:8888 -d ${ACR_NAME}.azurecr.io/mm-openlab-jupyter:latest || exit 1
EOF

  if [ $? -eq 0 ]; then
    echo "✅ SSH and setup completed successfully."
    break
  else
    echo "❌ SSH or setup failed. Retrying in 15 seconds..."
    sleep 15
  fi
done
