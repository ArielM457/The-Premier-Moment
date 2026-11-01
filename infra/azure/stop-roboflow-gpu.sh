#!/usr/bin/env bash
set -euo pipefail

resource_group="${MENTOX_AZURE_RESOURCE_GROUP:-rg-mentox-dev}"
app_name="${MENTOX_ROBOFLOW_APP_NAME:-ca-mentox-roboflow-dev}"
subscription="${MENTOX_AZURE_SUBSCRIPTION_ID:-$(az account show --query id --output tsv)}"

az containerapp update --subscription "${subscription}" \
  --resource-group "${resource_group}" --name "${app_name}" \
  --min-replicas 0 --max-replicas 1 --output none

echo "Roboflow quedó configurado con cero réplicas mínimas."
echo "Compruebe que properties.replicas llegue a 0 antes de cerrar la sesión."
az containerapp revision list --subscription "${subscription}" \
  --resource-group "${resource_group}" --name "${app_name}" \
  --query "[].{revision:name,replicas:properties.replicas,state:properties.runningState}" --output table
