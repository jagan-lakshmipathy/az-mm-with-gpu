#!/bin/zsh

ADMIN_NAME="jagan-admin"
USRNAME="$ADMIN_NAME"  # Ensure USERNAME is set for SSH
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

create_and_verify_rg $RG_ACR "eastus"

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

# Log in to ACR (replace with your ACR name)
az acr login --name $ACR_NAME
echo "🔐 Logged in to ACR."

docker buildx build --no-cache --platform linux/amd64 -f Dockerfile.jupyter.temp -t $ACR_NAME.azurecr.io/mm-openlab-jupyter:latest --push .


# Wait a few seconds to ensure the image is available
sleep 5

# Check if the image exists in ACR
echo "Checking if the image exists in ACR..."
az acr repository show-tags --name $ACR_NAME --repository mm-openlab-jupyter --query "[?contains(@, 'latest')]" --output tsv


# If the image tag is found, confirm success
if [[ $? -eq 0 ]]; then
    echo "✅ Image $IMAGE_NAME:$TAG successfully pushed to ACR!"
else
    echo "❌ Image not found in ACR. Check your push command or permissions."
fi

