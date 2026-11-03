#!/usr/bin/env bash
# Runs the repro in Azure Container Instances, in a VNet and with a public IP, with and without
# MSAL_MI_DISABLE_IMDS_V2, and with the failing ("after") and working ("before") package versions.
# Prints each container's log.
#
# Usage:  ./deploy.sh            create resources and run every case
#         ./deploy.sh cleanup    delete the resource group
#
# Requires: az CLI signed in (az login), a subscription where you can create resource groups.

set -euo pipefail

# Git Bash on Windows rewrites arguments that look like Unix paths, which mangles resource IDs
# (/subscriptions/...) passed to az.
export MSYS_NO_PATHCONV=1

# az on Windows ends tsv output with \r\n; strip the \r so captured values compare and pass cleanly.
azq() { az "$@" --output tsv | tr -d '\r'; }

RG="${RG:-msal-imdsv2-aci-repro}"
LOCATION="${LOCATION:-australiaeast}"
ACR="${ACR:-msalimdsrepro$RANDOM}"
TIMEOUT_SECONDS="${TIMEOUT_SECONDS:-60}"

if [[ "${1:-}" == "cleanup" ]]; then
  az group delete --name "$RG" --yes --no-wait
  echo "Deleting resource group $RG"
  exit 0
fi

echo "== Resource group, identity, registry"
az group create --name "$RG" --location "$LOCATION" --output none

az identity create --resource-group "$RG" --name repro-identity --output none
IDENTITY_ID=$(azq identity show --resource-group "$RG" --name repro-identity --query id)
CLIENT_ID=$(azq identity show --resource-group "$RG" --name repro-identity --query clientId)
PRINCIPAL_ID=$(azq identity show --resource-group "$RG" --name repro-identity --query principalId)

ACR=$(azq acr list --resource-group "$RG" --query "[0].name" | grep . || echo "$ACR")
az acr create --resource-group "$RG" --name "$ACR" --sku Basic --output none
ACR_ID=$(azq acr show --name "$ACR" --query id)
ACR_SERVER=$(azq acr show --name "$ACR" --query loginServer)

if [[ $(azq role assignment list --assignee "$PRINCIPAL_ID" --role AcrPull --scope "$ACR_ID" --query "length(@)") == 0 ]]; then
  az role assignment create --assignee-object-id "$PRINCIPAL_ID" --assignee-principal-type ServicePrincipal \
    --role AcrPull --scope "$ACR_ID" --output none
fi

echo "== Building images in ACR"
# after:  Azure.Core 1.60.0 + MSAL 4.91.1 (fails)   before: Azure.Core 1.54.0 + MSAL 4.84.0 (works)
az acr build --registry "$ACR" --image repro:after --no-logs . --output none   --build-arg AZURE_CORE_VERSION=1.60.0 --build-arg MSAL_VERSION=4.91.1
az acr build --registry "$ACR" --image repro:before --no-logs . --output none   --build-arg AZURE_CORE_VERSION=1.54.0 --build-arg MSAL_VERSION=4.84.0

echo "== VNet with a subnet delegated to ACI"
az network vnet create --resource-group "$RG" --name repro-vnet --address-prefixes 10.42.0.0/16 \
  --subnet-name aci --subnet-prefixes 10.42.0.0/24 --output none
az network vnet subnet update --resource-group "$RG" --vnet-name repro-vnet --name aci \
  --delegations Microsoft.ContainerInstance/containerGroups --output none

echo "== Waiting 60s for the AcrPull role assignment to propagate"
sleep 60

run_case() {
  local name=$1 tag=$2 network=$3 disable_v2=$4
  local network_args=()

  [[ "$network" == "vnet" ]] && network_args=(--vnet repro-vnet --subnet aci)

  echo
  echo "################ $name: image $tag, $network, MSAL_MI_DISABLE_IMDS_V2=$disable_v2"

  # A VNet container group can't be updated in place, so a rerun replaces it.
  az container delete --resource-group "$RG" --name "$name" --yes --output none 2>/dev/null || true

  az container create --resource-group "$RG" --name "$name" --os-type Linux --cpu 1 --memory 1.5 \
    --image "$ACR_SERVER/repro:$tag" \
    --registry-login-server "$ACR_SERVER" --acr-identity "$IDENTITY_ID" \
    --assign-identity "$IDENTITY_ID" \
    --restart-policy Never \
    --environment-variables "AZURE_CLIENT_ID=$CLIENT_ID" "MSAL_MI_DISABLE_IMDS_V2=$disable_v2" "TIMEOUT_SECONDS=$TIMEOUT_SECONDS" \
    "${network_args[@]}" --output none

  for _ in $(seq 1 60); do
    state=$(azq container show --resource-group "$RG" --name "$name" \
      --query "containers[0].instanceView.currentState.state" 2>/dev/null || true)
    [[ "$state" == "Terminated" ]] && break
    sleep 5
  done

  az container logs --resource-group "$RG" --name "$name" | grep -E "^\[ *[0-9]+ ms\] [^ ]" || true
  az container logs --resource-group "$RG" --name "$name" > "logs-$name.txt" || true
}

run_case vnet-after          after  vnet   false
run_case vnet-after-disabled after  vnet   true
run_case vnet-before         before vnet   false
run_case public-after        after  public false

echo
echo "Full logs, including MSAL verbose output, are in logs-*.txt."
echo "Delete everything with: ./deploy.sh cleanup"
