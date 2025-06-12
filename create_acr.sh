#!/bin/zsh

ACR_NAME="jaganacr052025"
RG_ACR=jaganacr052025


set -e  # Exit on any command failure

# Trap for debugging on error
trap 'echo "❌ Error encountered at line $LINENO with exit code $?"' ERR

az group create --name ${RG_ACR} --location eastus

# Check if the resource group exists
if az group exists --name "$RG_ACR" | grep -q true; then
  echo "✅ Resource group '$RG_ACR' already exists."
else
  echo "❌ Resource group '$RG_ACR' does not exist."
fi


az acr create --name $ACR_NAME --resource-group $RG_ACR --sku basic

# Wait for the ACR to be fully ready
echo "Waiting for Azure Container Registry '$ACR_NAME' to be ready..."
while true; do
  STATUS=$(az acr show --name "$ACR_NAME" --resource-group "$RG_VM" --query "provisioningState" -o tsv)

  if [[ "$STATUS" == "Succeeded" ]]; then
    echo "Azure Container Registry '$ACR_NAME' is ready!"
    break
  elif [[ "$STATUS" == "Failed" ]]; then
    echo "ACR creation failed!"
    exit 1
  else
    echo "ACR status: $STATUS. Waiting..."
    sleep 30  # Check every 30 seconds
  fi
done

# Prompt user for confirmation
echo -n "All looks good? Continue? (y/n): "
read choice
case "$choice" in 
  y|Y ) 
    echo "Okay, continuing....."
    ;;
  * ) 
    echo "Operation canceled."
    exit 0
    ;;
esac


