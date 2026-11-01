#!/usr/bin/env bash
# Implementación común. Ejecute uno de los wrappers deploy-*.sh, no este archivo.
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"

die() {
  echo "Error: $*" >&2
  exit 1
}

normalize_location() {
  printf '%s' "$1" | tr '[:upper:]' '[:lower:]' | tr -d '[:space:]_-'
}

for required_variable in MENTOX_DEPLOY_SLUG MENTOX_DEPLOY_CONTEXT MENTOX_DEPLOY_APP_NAME MENTOX_DEPLOY_IDENTITY_NAME; do
  [[ -n "${!required_variable:-}" ]] || die "Falta la variable interna ${required_variable}. Use un wrapper deploy-*.sh."
done

resource_group="${MENTOX_AZURE_RESOURCE_GROUP:-rg-mentox-dev}"
location="${MENTOX_AZURE_LOCATION:-northcentralus}"
environment_name="${MENTOX_CONTAINERAPPS_ENVIRONMENT:-cae-mentox-vision-dev}"
# Una suscripción de estudiante admite un solo entorno: el de la demo puede vivir
# en otro grupo y las aplicaciones de modelos lo usan por su ID.
environment_group="${MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP:-${resource_group}}"
workload_profile_name="${MENTOX_GPU_PROFILE_NAME:-NC8as-T4}"
workload_profile_type="Consumption-GPU-NC8as-T4"
min_replicas="${MENTOX_MIN_REPLICAS:-0}"
max_replicas="${MENTOX_MAX_REPLICAS:-1}"
ingress="${MENTOX_MODEL_INGRESS:-external}"
image_build_mode="${MENTOX_IMAGE_BUILD_MODE:-local}"
image_repository="mentox/${MENTOX_DEPLOY_SLUG}"
context_path="${repository_root}/${MENTOX_DEPLOY_CONTEXT}"

for command_name in az openssl sha256sum find sort xargs; do
  command -v "${command_name}" >/dev/null 2>&1 || die "Falta el comando ${command_name}."
done

# Fijar la suscripción al iniciar: otra terminal puede cambiar el valor global
# de Azure CLI mientras Docker construye una imagen durante varios minutos.
deployment_subscription="${MENTOX_AZURE_SUBSCRIPTION_ID:-$(command az account show --query id --output tsv)}"
az() {
  if [[ "${1:-}" == "extension" ]]; then
    command az "$@"
  else
    command az "$@" --subscription "${deployment_subscription}"
  fi
}

[[ -d "${context_path}" ]] || die "No existe el contexto ${context_path}."
[[ -f "${context_path}/Dockerfile" ]] || die "No existe ${context_path}/Dockerfile."
[[ "${MENTOX_ACCEPT_MODEL_LICENSES:-0}" == "1" ]] || die \
  "Lea ${MENTOX_DEPLOY_CONTEXT}/README.md y exporte MENTOX_ACCEPT_MODEL_LICENSES=1."
[[ -n "${MENTOX_MODEL_API_KEY:-}" ]] || die \
  "Exporte MENTOX_MODEL_API_KEY con un valor generado por: openssl rand -hex 32"
[[ "${#MENTOX_MODEL_API_KEY}" -ge 32 ]] || die "MENTOX_MODEL_API_KEY debe tener al menos 32 caracteres."
[[ "${min_replicas}" =~ ^[01]$ ]] || die "MENTOX_MIN_REPLICAS debe ser 0 o 1."
[[ "${max_replicas}" == "1" ]] || die "MENTOX_MAX_REPLICAS debe ser 1 para limitar costo y VRAM."
[[ "${ingress}" == "external" || "${ingress}" == "internal" ]] || die \
  "MENTOX_MODEL_INGRESS debe ser external o internal."
[[ "${image_build_mode}" == "acr" || "${image_build_mode}" == "local" || "${image_build_mode}" == "existing" ]] || die \
  "MENTOX_IMAGE_BUILD_MODE debe ser acr, local o existing."

az account show --query '{subscription:name,state:state,tenant:tenantId}' --output table
[[ "$(az account show --query state --output tsv)" == "Enabled" ]] || die "La suscripción activa no está habilitada."

if ! az extension show --name containerapp >/dev/null 2>&1; then
  az extension add --name containerapp --yes >/dev/null
fi
for provider in Microsoft.App Microsoft.ContainerRegistry Microsoft.ManagedIdentity; do
  az provider register --namespace "${provider}" --wait
done

supported_profile="$(az containerapp env workload-profile list-supported \
  --location "${location}" \
  --query "[?name=='${workload_profile_type}'].name | [0]" \
  --output tsv)"
[[ "${supported_profile}" == "${workload_profile_type}" ]] || die \
  "${workload_profile_type} no está disponible en ${location}. Confirme región y cuota."

if ! az group show --name "${resource_group}" >/dev/null 2>&1; then
  az group create --name "${resource_group}" --location "${location}" --output none
fi

suffix="$(printf '%s' "$(az account show --query id --output tsv):${resource_group}" | sha256sum | cut -c1-8)"
acr_name="${MENTOX_ACR_NAME:-mentox${suffix}}"
content_hash="$(find "${context_path}" -type f ! -path '*/__pycache__/*' ! -path '*/.pytest_cache/*' ! -name '*.pyc' -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)"
image_tag="${MENTOX_IMAGE_TAG:-${content_hash}}"

if ! az acr show --resource-group "${resource_group}" --name "${acr_name}" >/dev/null 2>&1; then
  az acr create --resource-group "${resource_group}" --name "${acr_name}" \
    --location "${location}" --sku Basic --admin-enabled false --output none
fi
acr_location="$(az acr show --resource-group "${resource_group}" --name "${acr_name}" --query location --output tsv)"
[[ "$(normalize_location "${acr_location}")" == "$(normalize_location "${location}")" ]] || die \
  "El ACR ${acr_name} está en ${acr_location}, no en ${location}. Use la región existente o otro MENTOX_ACR_NAME."

login_server="$(az acr show --resource-group "${resource_group}" --name "${acr_name}" --query loginServer --output tsv)"
image="${login_server}/${image_repository}:${image_tag}"

if [[ "${image_build_mode}" == "acr" ]]; then
  az acr build --registry "${acr_name}" --image "${image_repository}:${image_tag}" \
    --file "${context_path}/Dockerfile" "${context_path}"
elif [[ "${image_build_mode}" == "local" ]]; then
  command -v docker >/dev/null 2>&1 || die "Falta Docker."
  docker_prefix=()
  if ! docker info >/dev/null 2>&1; then
    command -v sudo >/dev/null 2>&1 || die "Docker no está disponible para el usuario y falta sudo."
    docker_prefix=(sudo)
  fi
  docker_config_dir="$(mktemp -d /tmp/mentox-docker-config.XXXXXX)"
  cleanup_docker_auth() {
    "${docker_prefix[@]}" docker --config "${docker_config_dir}" logout "${login_server}" >/dev/null 2>&1 || true
    "${docker_prefix[@]}" rm -rf -- "${docker_config_dir}"
  }
  trap cleanup_docker_auth EXIT
  acr_access_token="$(az acr login --name "${acr_name}" --expose-token --query accessToken --output tsv)"
  printf '%s' "${acr_access_token}" | "${docker_prefix[@]}" docker --config "${docker_config_dir}" login \
    "${login_server}" --username 00000000-0000-0000-0000-000000000000 --password-stdin >/dev/null
  unset acr_access_token
  "${docker_prefix[@]}" docker --config "${docker_config_dir}" build --tag "${image}" \
    --file "${context_path}/Dockerfile" "${context_path}"
  if [[ "${MENTOX_DEPLOY_SLUG}" == "soccernet-gamestate" ]]; then
    # Detecta errores de importación Python y pesos incompletos antes de publicar.
    "${docker_prefix[@]}" docker run --rm --network none --entrypoint python "${image}" \
      -c 'import sys; sys.path.insert(0, "/opt/prime"); from app import inspect_preloaded_models; print(inspect_preloaded_models())'
  fi
  "${docker_prefix[@]}" docker --config "${docker_config_dir}" push "${image}"
  cleanup_docker_auth
  trap - EXIT
else
  existing_tag="$(az acr repository show-tags --name "${acr_name}" --repository "${image_repository}" \
    --query "[?@=='${image_tag}'] | [0]" --output tsv)"
  [[ "${existing_tag}" == "${image_tag}" ]] || die \
    "No existe ${image_repository}:${image_tag}; use MENTOX_IMAGE_BUILD_MODE=local."
fi

if ! az identity show --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_IDENTITY_NAME}" >/dev/null 2>&1; then
  az identity create --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_IDENTITY_NAME}" \
    --location "${location}" --output none
fi
identity_id="$(az identity show --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_IDENTITY_NAME}" --query id --output tsv)"
principal_id="$(az identity show --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_IDENTITY_NAME}" --query principalId --output tsv)"
acr_id="$(az acr show --resource-group "${resource_group}" --name "${acr_name}" --query id --output tsv)"
if [[ "$(az role assignment list --assignee-object-id "${principal_id}" --scope "${acr_id}" --role AcrPull --query 'length(@)' --output tsv)" == "0" ]]; then
  az role assignment create --assignee-object-id "${principal_id}" \
    --assignee-principal-type ServicePrincipal --role AcrPull --scope "${acr_id}" --output none
fi

if ! az containerapp env show --resource-group "${environment_group}" --name "${environment_name}" >/dev/null 2>&1; then
  az containerapp env create --resource-group "${environment_group}" --name "${environment_name}" \
    --location "${location}" --environment-mode WorkloadProfiles --logs-destination none --output none
else
  env_location="$(az containerapp env show --resource-group "${environment_group}" --name "${environment_name}" --query location --output tsv)"
  [[ "$(normalize_location "${env_location}")" == "$(normalize_location "${location}")" ]] || die \
    "El entorno ${environment_name} está en ${env_location}, no en ${location}."
fi
environment_id="$(az containerapp env show --resource-group "${environment_group}" --name "${environment_name}" --query id --output tsv)"

if ! az containerapp env workload-profile show --resource-group "${environment_group}" \
  --name "${environment_name}" --workload-profile-name "${workload_profile_name}" >/dev/null 2>&1; then
  az containerapp env workload-profile add --resource-group "${environment_group}" \
    --name "${environment_name}" --workload-profile-name "${workload_profile_name}" \
    --workload-profile-type "${workload_profile_type}" --output none
fi

model_env=("MENTOX_MODEL_API_KEY=secretref:model-api-key")
if [[ "${MENTOX_DEPLOY_SLUG}" == "soccernet-gamestate" ]]; then
  model_env+=(
    "MENTOX_MAX_VIDEO_SECONDS=${MENTOX_MAX_VIDEO_SECONDS:-240}"
    "MENTOX_GAMESTATE_ANALYSIS_TIMEOUT_SECONDS=${MENTOX_GAMESTATE_ANALYSIS_TIMEOUT_SECONDS:-3600}"
    "MENTOX_GAMESTATE_SAVE_VISUALIZATION=${MENTOX_GAMESTATE_SAVE_VISUALIZATION:-false}"
  )
fi

if az containerapp show --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_APP_NAME}" >/dev/null 2>&1; then
  # Fijar el modo antes de cambiar la imagen reduce revisiones activas simultáneas.
  az containerapp revision set-mode --resource-group "${resource_group}" \
    --name "${MENTOX_DEPLOY_APP_NAME}" --mode single --output none
  az containerapp identity assign --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_APP_NAME}" \
    --user-assigned "${identity_id}" --output none
  az containerapp registry set --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_APP_NAME}" \
    --server "${login_server}" --identity "${identity_id}" --output none
  az containerapp secret set --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_APP_NAME}" \
    --secrets model-api-key="${MENTOX_MODEL_API_KEY}" --output none
  az containerapp update --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_APP_NAME}" \
    --image "${image}" --cpu 8 --memory 56Gi --min-replicas "${min_replicas}" \
    --max-replicas "${max_replicas}" --set-env-vars "${model_env[@]}" --output none
else
  az containerapp create --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_APP_NAME}" \
    --environment "${environment_id}" --image "${image}" --user-assigned "${identity_id}" \
    --registry-server "${login_server}" --registry-identity "${identity_id}" \
    --workload-profile-name "${workload_profile_name}" --cpu 8 --memory 56Gi \
    --ingress "${ingress}" --target-port 8000 --transport auto \
    --min-replicas "${min_replicas}" --max-replicas "${max_replicas}" \
    --secrets model-api-key="${MENTOX_MODEL_API_KEY}" \
    --env-vars "${model_env[@]}" --output none
fi

# Una sola revisión evita que dos versiones compitan por la GPU T4 disponible.
az containerapp revision set-mode --resource-group "${resource_group}" \
  --name "${MENTOX_DEPLOY_APP_NAME}" --mode single --output none

fqdn="$(az containerapp show --resource-group "${resource_group}" --name "${MENTOX_DEPLOY_APP_NAME}" \
  --query properties.configuration.ingress.fqdn --output tsv)"
echo "Despliegue preparado: ${MENTOX_DEPLOY_SLUG}"
echo "Aplicación: ${MENTOX_DEPLOY_APP_NAME}"
echo "Imagen: ${image}"
echo "Réplicas: ${min_replicas}-${max_replicas}"
[[ -z "${fqdn}" ]] || echo "Endpoint: https://${fqdn}"

