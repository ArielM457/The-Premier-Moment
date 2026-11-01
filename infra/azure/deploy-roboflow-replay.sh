#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
context_path="${repository_root}/deploy/azure-roboflow-replay"
resource_group="${MENTOX_AZURE_RESOURCE_GROUP:-rg-mentox-dev}"
location="${MENTOX_AZURE_LOCATION:-northcentralus}"
environment_name="${MENTOX_CONTAINERAPPS_ENVIRONMENT:-cae-mentox-vision-dev}"
environment_group="${MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP:-${resource_group}}"
app_name="${MENTOX_ROBOFLOW_APP_NAME:-ca-mentox-roboflow-dev}"
identity_name="${MENTOX_ROBOFLOW_IDENTITY_NAME:-id-mentox-roboflow-dev}"
image_repository="mentox/roboflow-precomputed-replay"
image_build_mode="${MENTOX_IMAGE_BUILD_MODE:-local}"
min_replicas="${MENTOX_MIN_REPLICAS:-0}"
max_replicas="${MENTOX_MAX_REPLICAS:-1}"

die() {
  echo "Error: $*" >&2
  exit 1
}

for command_name in az sha256sum find sort xargs; do
  command -v "${command_name}" >/dev/null 2>&1 || die "Falta ${command_name}."
done

[[ -n "${MENTOX_MODEL_API_KEY:-}" ]] || die "Exporte MENTOX_MODEL_API_KEY."
[[ "${#MENTOX_MODEL_API_KEY}" -ge 32 ]] || die "MENTOX_MODEL_API_KEY debe tener al menos 32 caracteres."
[[ "${image_build_mode}" == "local" || "${image_build_mode}" == "existing" ]] || \
  die "MENTOX_IMAGE_BUILD_MODE debe ser local o existing."
[[ "${min_replicas}" =~ ^[01]$ ]] || die "MENTOX_MIN_REPLICAS debe ser 0 o 1."
[[ "${max_replicas}" == "1" ]] || die "MENTOX_MAX_REPLICAS debe ser 1."
[[ -s "${context_path}/data/catalog.json" ]] || \
  die "Falta data/catalog.json. Ejecute precompute.py con los tres vídeos."

deployment_subscription="${MENTOX_AZURE_SUBSCRIPTION_ID:-$(command az account show --query id --output tsv)}"
az() {
  if [[ "${1:-}" == "extension" ]]; then
    command az "$@"
  else
    command az "$@" --subscription "${deployment_subscription}"
  fi
}

[[ "$(az account show --query state --output tsv)" == "Enabled" ]] || die "La suscripción no está habilitada."
az group show --name "${resource_group}" >/dev/null 2>&1 || die "No existe ${resource_group}; despliegue primero Roboflow GPU."
environment_id="$(az containerapp env show --resource-group "${environment_group}" --name "${environment_name}" \
  --query id --output tsv 2>/dev/null)" || die "No existe el entorno ${environment_name} en ${environment_group}."

suffix="$(printf '%s' "$(az account show --query id --output tsv):${resource_group}" | sha256sum | cut -c1-8)"
acr_name="${MENTOX_ACR_NAME:-mentox${suffix}}"
login_server="$(az acr show --resource-group "${resource_group}" --name "${acr_name}" --query loginServer --output tsv)"
content_hash="$(find "${context_path}" -type f ! -path '*/__pycache__/*' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)"
image_tag="${MENTOX_IMAGE_TAG:-${content_hash}}"
image="${login_server}/${image_repository}:${image_tag}"

if [[ "${image_build_mode}" == "local" ]]; then
  command -v docker >/dev/null 2>&1 || die "Falta Docker."
  docker_prefix=()
  if ! docker info >/dev/null 2>&1; then
    command -v sudo >/dev/null 2>&1 || die "Docker requiere sudo y sudo no está disponible."
    docker_prefix=(sudo)
  fi
  docker_config_dir="$(mktemp -d /tmp/prime-replay-docker.XXXXXX)"
  cleanup() {
    "${docker_prefix[@]}" docker --config "${docker_config_dir}" logout "${login_server}" >/dev/null 2>&1 || true
    "${docker_prefix[@]}" rm -rf -- "${docker_config_dir}" >/dev/null 2>&1 || true
  }
  trap cleanup EXIT
  acr_token="$(az acr login --name "${acr_name}" --expose-token --query accessToken --output tsv)"
  printf '%s' "${acr_token}" | "${docker_prefix[@]}" docker --config "${docker_config_dir}" login \
    "${login_server}" --username 00000000-0000-0000-0000-000000000000 --password-stdin >/dev/null
  unset acr_token
  "${docker_prefix[@]}" docker build --tag "${image}" --file "${context_path}/Dockerfile" "${context_path}"
  "${docker_prefix[@]}" docker --config "${docker_config_dir}" push "${image}"
  cleanup
  trap - EXIT
else
  existing="$(az acr repository show-tags --name "${acr_name}" --repository "${image_repository}" \
    --query "[?@=='${image_tag}'] | [0]" --output tsv)"
  [[ "${existing}" == "${image_tag}" ]] || die "No existe ${image}."
fi

identity_id="$(az identity show --resource-group "${resource_group}" --name "${identity_name}" --query id --output tsv)"
principal_id="$(az identity show --resource-group "${resource_group}" --name "${identity_name}" --query principalId --output tsv)"
acr_id="$(az acr show --resource-group "${resource_group}" --name "${acr_name}" --query id --output tsv)"
if [[ "$(az role assignment list --assignee-object-id "${principal_id}" --scope "${acr_id}" --role AcrPull --query 'length(@)' --output tsv)" == "0" ]]; then
  az role assignment create --assignee-object-id "${principal_id}" --assignee-principal-type ServicePrincipal \
    --role AcrPull --scope "${acr_id}" --output none
fi

# La aplicación GPU ya no es necesaria después de crear el catálogo. Se recrea
# con el mismo nombre y contrato sobre el perfil CPU Consumption.
if az containerapp show --resource-group "${resource_group}" --name "${app_name}" >/dev/null 2>&1; then
  az containerapp delete --resource-group "${resource_group}" --name "${app_name}" --yes --output none
fi

az containerapp create --resource-group "${resource_group}" --name "${app_name}" \
  --environment "${environment_id}" --image "${image}" --user-assigned "${identity_id}" \
  --registry-server "${login_server}" --registry-identity "${identity_id}" \
  --workload-profile-name Consumption --cpu 0.5 --memory 1Gi \
  --ingress external --target-port 8000 --transport auto \
  --min-replicas "${min_replicas}" --max-replicas "${max_replicas}" \
  --secrets model-api-key="${MENTOX_MODEL_API_KEY}" \
  --env-vars MENTOX_MODEL_API_KEY=secretref:model-api-key --output none

fqdn="$(az containerapp show --resource-group "${resource_group}" --name "${app_name}" \
  --query properties.configuration.ingress.fqdn --output tsv)"
echo "Reproductor Roboflow precalculado desplegado."
echo "Aplicación: ${app_name}"
echo "Imagen: ${image}"
echo "Réplicas CPU: ${min_replicas}-${max_replicas}"
echo "Endpoint: https://${fqdn}"
