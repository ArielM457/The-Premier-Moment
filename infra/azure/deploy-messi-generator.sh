#!/usr/bin/env bash
set -euo pipefail

repository_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
context_path="${repository_root}/deploy/azure-messi-generator"

resource_group="${MENTOX_AZURE_RESOURCE_GROUP:-rg-mentox-dev}"
location="${MENTOX_AZURE_LOCATION:-northcentralus}"
environment_name="${MENTOX_CONTAINERAPPS_ENVIRONMENT:-cae-mentox-vision-dev}"
# El entorno compartido puede estar en otro grupo; el Job lo usa por su ID.
environment_group="${MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP:-${resource_group}}"
profile_name="${MENTOX_GPU_PROFILE_NAME:-NC8as-T4}"
profile_type="Consumption-GPU-NC8as-T4"
job_name="${MENTOX_MESSI_JOB_NAME:-job-mentox-messi-dev}"
identity_name="${MENTOX_MESSI_IDENTITY_NAME:-id-mentox-messi-dev}"
image_repository="mentox/messi-generator"
image_build_mode="${MENTOX_IMAGE_BUILD_MODE:-local}"
match_count="${MENTOX_MATCH_COUNT:-30}"
match_seconds="${MENTOX_MATCH_SECONDS:-180}"
base_seed="${MENTOX_BASE_SEED:-20261025}"
render_fps="${MENTOX_RENDER_FPS:-15}"
control_fps="${MENTOX_CONTROL_FPS:-15}"
render_mode="${MENTOX_RENDER_MODE:-light}"
state_stride="${MENTOX_STATE_STRIDE:-15}"
batch_id="${MENTOX_BATCH_ID:-messi-${base_seed}-${match_count}x${match_seconds}s}"
container_name="${MENTOX_BLOB_CONTAINER:-synthetic-videos}"
replica_timeout="${MENTOX_JOB_TIMEOUT_SECONDS:-86400}"
start_job="${MENTOX_START_JOB:-0}"

die() {
  echo "Error: $*" >&2
  exit 1
}

for command_name in az find sha256sum sort xargs; do
  command -v "${command_name}" >/dev/null 2>&1 || die "Falta el comando ${command_name}."
done

[[ "${match_count}" =~ ^[1-9][0-9]*$ ]] || die "MENTOX_MATCH_COUNT debe ser un entero positivo."
[[ "${base_seed}" =~ ^[1-9][0-9]*$ ]] || die "MENTOX_BASE_SEED debe ser un entero positivo."
[[ "${replica_timeout}" =~ ^[1-9][0-9]*$ ]] || die "MENTOX_JOB_TIMEOUT_SECONDS debe ser positivo."
[[ "${start_job}" == "0" || "${start_job}" == "1" ]] || die "MENTOX_START_JOB debe ser 0 o 1."
[[ "${render_mode}" == "light" || "${render_mode}" == "rich" || "${render_mode}" == "clean" ]] || \
  die "MENTOX_RENDER_MODE debe ser light, rich o clean."
[[ "${image_build_mode}" == "local" || "${image_build_mode}" == "acr" || "${image_build_mode}" == "existing" ]] || \
  die "MENTOX_IMAGE_BUILD_MODE debe ser local, acr o existing."

az account show --query '{subscription:name,state:state,tenant:tenantId}' --output table
[[ "$(az account show --query state --output tsv)" == "Enabled" ]] || die "La suscripción activa no está habilitada."

az extension add --name containerapp --upgrade --yes >/dev/null
for provider in Microsoft.App Microsoft.ContainerRegistry Microsoft.ManagedIdentity Microsoft.Storage; do
  az provider register --namespace "${provider}" --wait
done

supported_profile="$(az containerapp env workload-profile list-supported \
  --location "${location}" \
  --query "[?name=='${profile_type}'].name | [0]" \
  --output tsv)"
[[ "${supported_profile}" == "${profile_type}" ]] || die "${profile_type} no está disponible en ${location}."

suffix="$(printf '%s' "$(az account show --query id --output tsv):${resource_group}" | sha256sum | cut -c1-8)"
acr_name="${MENTOX_ACR_NAME:-mentox${suffix}}"
if [[ -n "${MENTOX_STORAGE_ACCOUNT:-}" ]]; then
  storage_account="${MENTOX_STORAGE_ACCOUNT}"
else
  mapfile -t storage_accounts < <(az storage account list --resource-group "${resource_group}" --query '[].name' --output tsv)
  [[ "${#storage_accounts[@]}" == "1" ]] || die \
    "Se esperó una cuenta de Storage en ${resource_group} y se encontraron ${#storage_accounts[@]}. Exporte MENTOX_STORAGE_ACCOUNT."
  storage_account="${storage_accounts[0]}"
fi
storage_endpoint="$(az storage account show --resource-group "${resource_group}" --name "${storage_account}" --query primaryEndpoints.blob --output tsv)"
storage_id="$(az storage account show --resource-group "${resource_group}" --name "${storage_account}" --query id --output tsv)"

if ! az storage container show --account-name "${storage_account}" --name "${container_name}" --auth-mode login >/dev/null 2>&1; then
  az storage container create --account-name "${storage_account}" --name "${container_name}" \
    --auth-mode login --public-access off --output none
fi

if ! az acr show --resource-group "${resource_group}" --name "${acr_name}" >/dev/null 2>&1; then
  az acr create --resource-group "${resource_group}" --name "${acr_name}" \
    --location "${location}" --sku Basic --admin-enabled false --output none
fi
login_server="$(az acr show --resource-group "${resource_group}" --name "${acr_name}" --query loginServer --output tsv)"
content_hash="$(find "${context_path}" -type f -print0 | sort -z | xargs -0 sha256sum | sha256sum | cut -c1-12)"
image_tag="${MENTOX_IMAGE_TAG:-${content_hash}}"
image="${login_server}/${image_repository}:${image_tag}"

if [[ "${image_build_mode}" == "acr" ]]; then
  az acr build --registry "${acr_name}" --image "${image_repository}:${image_tag}" \
    --file "${context_path}/Dockerfile" "${context_path}"
elif [[ "${image_build_mode}" == "local" ]]; then
  command -v docker >/dev/null 2>&1 || die "Falta Docker."
  command -v sudo >/dev/null 2>&1 || die "Falta sudo para Docker local."
  docker_config_dir="$(mktemp -d /tmp/mentox-messi-docker.XXXXXX)"
  sudo -v
  keep_sudo_alive() {
    while kill -0 "$$" >/dev/null 2>&1; do
      sudo -n -v || return
      sleep 60
    done
  }
  keep_sudo_alive &
  sudo_keepalive_pid=$!
  cleanup() {
    sudo -n docker --config "${docker_config_dir}" logout "${login_server}" >/dev/null 2>&1 || true
    sudo -n rm -rf -- "${docker_config_dir}" >/dev/null 2>&1 || true
    kill "${sudo_keepalive_pid}" >/dev/null 2>&1 || true
    wait "${sudo_keepalive_pid}" 2>/dev/null || true
  }
  trap cleanup EXIT
  acr_token="$(az acr login --name "${acr_name}" --expose-token --query accessToken --output tsv)"
  printf '%s' "${acr_token}" | docker --config "${docker_config_dir}" login \
    "${login_server}" --username 00000000-0000-0000-0000-000000000000 --password-stdin >/dev/null
  unset acr_token
  sudo docker --config "${docker_config_dir}" build --tag "${image}" --file "${context_path}/Dockerfile" "${context_path}"
  sudo docker --config "${docker_config_dir}" push "${image}"
  cleanup
  trap - EXIT
else
  existing="$(az acr repository show-tags --name "${acr_name}" --repository "${image_repository}" \
    --query "[?@=='${image_tag}'] | [0]" --output tsv)"
  [[ "${existing}" == "${image_tag}" ]] || die "No existe ${image}; use MENTOX_IMAGE_BUILD_MODE=local."
fi

if ! az identity show --resource-group "${resource_group}" --name "${identity_name}" >/dev/null 2>&1; then
  az identity create --resource-group "${resource_group}" --name "${identity_name}" --location "${location}" --output none
fi
identity_id="$(az identity show --resource-group "${resource_group}" --name "${identity_name}" --query id --output tsv)"
principal_id="$(az identity show --resource-group "${resource_group}" --name "${identity_name}" --query principalId --output tsv)"
identity_client_id="$(az identity show --resource-group "${resource_group}" --name "${identity_name}" --query clientId --output tsv)"
acr_id="$(az acr show --resource-group "${resource_group}" --name "${acr_name}" --query id --output tsv)"
# El Job solo escribe en su contenedor: el permiso no abarca el resto de la cuenta.
container_scope="${storage_id}/blobServices/default/containers/${container_name}"

for role_and_scope in "AcrPull|${acr_id}" "Storage Blob Data Contributor|${container_scope}"; do
  role="${role_and_scope%%|*}"
  scope="${role_and_scope#*|}"
  if [[ "$(az role assignment list --assignee-object-id "${principal_id}" --scope "${scope}" --role "${role}" --query 'length(@)' --output tsv)" == "0" ]]; then
    az role assignment create --assignee-object-id "${principal_id}" --assignee-principal-type ServicePrincipal \
      --role "${role}" --scope "${scope}" --output none
  fi
done

if ! az containerapp env show --resource-group "${environment_group}" --name "${environment_name}" >/dev/null 2>&1; then
  az containerapp env create --resource-group "${environment_group}" --name "${environment_name}" \
    --location "${location}" --environment-mode WorkloadProfiles --logs-destination none --output none
fi
environment_id="$(az containerapp env show --resource-group "${environment_group}" --name "${environment_name}" --query id --output tsv)"
if ! az containerapp env workload-profile show --resource-group "${environment_group}" --name "${environment_name}" \
  --workload-profile-name "${profile_name}" >/dev/null 2>&1; then
  az containerapp env workload-profile add --resource-group "${environment_group}" --name "${environment_name}" \
    --workload-profile-name "${profile_name}" --workload-profile-type "${profile_type}" --output none
fi

env_vars=(
  "AZURE_CLIENT_ID=${identity_client_id}"
  "AZURE_BLOB_SERVICE_ENDPOINT=${storage_endpoint}"
  "MENTOX_MATCH_COUNT=${match_count}"
  "MENTOX_MATCH_SECONDS=${match_seconds}"
  "MENTOX_BASE_SEED=${base_seed}"
  "MENTOX_BATCH_ID=${batch_id}"
  "MENTOX_RENDER_FPS=${render_fps}"
  "MENTOX_CONTROL_FPS=${control_fps}"
  "MENTOX_RENDER_MODE=${render_mode}"
  "MENTOX_STATE_STRIDE=${state_stride}"
  "MENTOX_BLOB_CONTAINER=${container_name}"
  "MENTOX_UPLOAD_ENABLED=1"
)

if az containerapp job show --resource-group "${resource_group}" --name "${job_name}" >/dev/null 2>&1; then
  az containerapp job identity assign --resource-group "${resource_group}" --name "${job_name}" \
    --user-assigned "${identity_id}" --output none
  az containerapp job registry set --resource-group "${resource_group}" --name "${job_name}" \
    --server "${login_server}" --identity "${identity_id}" --output none
  az containerapp job update --resource-group "${resource_group}" --name "${job_name}" \
    --image "${image}" --cpu 8 --memory 56Gi --workload-profile-name "${profile_name}" \
    --replica-timeout "${replica_timeout}" --replica-retry-limit 1 --parallelism 1 \
    --replica-completion-count 1 --replace-env-vars "${env_vars[@]}" --output none
else
  az containerapp job create --resource-group "${resource_group}" --name "${job_name}" \
    --environment "${environment_id}" --trigger-type Manual --image "${image}" \
    --mi-user-assigned "${identity_id}" --registry-server "${login_server}" --registry-identity "${identity_id}" \
    --workload-profile-name "${profile_name}" --cpu 8 --memory 56Gi \
    --replica-timeout "${replica_timeout}" --replica-retry-limit 1 --parallelism 1 \
    --replica-completion-count 1 --env-vars "${env_vars[@]}" --output none
fi

echo "Job preparado: ${job_name}"
echo "Imagen: ${image}"
echo "Lote: ${batch_id} (${match_count} vídeos de ${match_seconds}s)"
echo "Render: ${render_mode} a ${render_fps} FPS"
echo "Destino: ${storage_endpoint}${container_name}/messi/${batch_id}/"

if [[ "${start_job}" == "1" ]]; then
  execution_name="$(az containerapp job start --resource-group "${resource_group}" --name "${job_name}" --query name --output tsv)"
  echo "Ejecución iniciada: ${execution_name}"
else
  echo "Revise la configuración y ejecute:"
  echo "az containerapp job start --resource-group ${resource_group} --name ${job_name}"
fi
