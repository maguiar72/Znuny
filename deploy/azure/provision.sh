#!/usr/bin/env bash
# =============================================================================
# Turnkey provisioning of Znuny on Azure Container Apps.
#
# Run this from a machine that is authenticated to the target subscription
# (e.g. SERPRO-CLOUD). It logs in, selects the subscription, deploys the Bicep
# template, builds the image in ACR and points the Container App at it.
#
# Usage:
#   export AZURE_SUBSCRIPTION_ID="<subscription-id>"   # e.g. SERPRO-CLOUD
#   export MYSQL_ADMIN_PASSWORD='<strong-password>'
#   ./deploy/azure/provision.sh
#
# Optional overrides (with defaults):
#   RESOURCE_GROUP=znuny-rg  LOCATION=brazilsouth  NAME_PREFIX=znuny
# =============================================================================
set -euo pipefail

: "${AZURE_SUBSCRIPTION_ID:?Set AZURE_SUBSCRIPTION_ID to the target subscription id}"
: "${MYSQL_ADMIN_PASSWORD:?Set MYSQL_ADMIN_PASSWORD to a strong password}"

RESOURCE_GROUP="${RESOURCE_GROUP:-znuny-rg}"
LOCATION="${LOCATION:-brazilsouth}"
NAME_PREFIX="${NAME_PREFIX:-znuny}"
IMAGE_TAG="${IMAGE_TAG:-$(git rev-parse --short HEAD 2>/dev/null || echo latest)}"

# Resolve the repository root so the script works from any CWD.
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
REPO_ROOT="$(cd "${SCRIPT_DIR}/../.." && pwd)"

echo "==> Subscription : ${AZURE_SUBSCRIPTION_ID}"
echo "==> Resource grp : ${RESOURCE_GROUP} (${LOCATION})"
echo "==> Name prefix  : ${NAME_PREFIX}"
echo "==> Image tag    : ${IMAGE_TAG}"

# --- Authentication ----------------------------------------------------------
# If not already logged in, this opens an interactive login. For a sovereign
# endpoint run `az cloud set --name <AzureCloud|...>` beforehand.
if ! az account show >/dev/null 2>&1; then
    az login >/dev/null
fi
az account set --subscription "${AZURE_SUBSCRIPTION_ID}"

# --- Resource group ----------------------------------------------------------
az group create --name "${RESOURCE_GROUP}" --location "${LOCATION}" --output none

# --- Infrastructure ----------------------------------------------------------
echo "==> Deploying infrastructure (Bicep)..."
outputs=$(az deployment group create \
    --resource-group "${RESOURCE_GROUP}" \
    --template-file "${REPO_ROOT}/deploy/azure/main.bicep" \
    --parameters "${REPO_ROOT}/deploy/azure/main.parameters.example.json" \
    --parameters namePrefix="${NAME_PREFIX}" \
    --parameters mysqlAdminPassword="${MYSQL_ADMIN_PASSWORD}" \
    --parameters customDomain="${CUSTOM_DOMAIN:-}" \
    --query properties.outputs -o json)

ACR_NAME=$(echo "${outputs}"    | jq -r .acrName.value)
ACR_SERVER=$(echo "${outputs}"  | jq -r .acrLoginServer.value)
APP_NAME=$(echo "${outputs}"    | jq -r .containerAppName.value)
APP_URL=$(echo "${outputs}"     | jq -r .appUrl.value)
DEFAULT_FQDN=$(echo "${outputs}" | jq -r .defaultFqdn.value)
DOMAIN_VERIFY_ID=$(echo "${outputs}" | jq -r .customDomainVerificationId.value)

# --- Image build (runs inside ACR, no local Docker needed) -------------------
echo "==> Building image ${ACR_SERVER}/znuny:${IMAGE_TAG} in ACR..."
az acr build \
    --registry "${ACR_NAME}" \
    --image "znuny:${IMAGE_TAG}" \
    --image "znuny:latest" \
    --file "${REPO_ROOT}/deploy/docker/Dockerfile" \
    "${REPO_ROOT}"

# --- Point the app at the freshly built image --------------------------------
echo "==> Updating Container App image..."
az containerapp update \
    --name "${APP_NAME}" \
    --resource-group "${RESOURCE_GROUP}" \
    --image "${ACR_SERVER}/znuny:${IMAGE_TAG}" \
    --output none

echo ""
echo "============================================================"
echo " Znuny provisioned successfully."
if [ -n "${CUSTOM_DOMAIN:-}" ]; then
    echo "   URL   : https://${CUSTOM_DOMAIN}"
else
    echo "   URL   : ${APP_URL}"
fi
echo "   Login : root@localhost / root   (change immediately)"
echo ""
echo " Custom domain setup (only if using CUSTOM_DOMAIN):"
echo "   Default FQDN (CNAME target) : ${DEFAULT_FQDN}"
echo "   Domain verification id      : ${DOMAIN_VERIFY_ID}"
echo "   Create these DNS records at your DNS provider, THEN re-run"
echo "   this script with CUSTOM_DOMAIN set:"
echo "     CNAME  <subdomain>         -> ${DEFAULT_FQDN}"
echo "     TXT    asuid.<subdomain>   -> ${DOMAIN_VERIFY_ID}"
echo "============================================================"
