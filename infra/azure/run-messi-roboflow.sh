#!/usr/bin/env bash
# Orquestación del lote: no modifica apps/backend ni apps/frontend.
set -euo pipefail

repo_root="$(cd "$(dirname "${BASH_SOURCE[0]}")/../.." && pwd)"
cd "$repo_root"
action="${1:-help}"
usage() {
  echo "Uso: bash infra/azure/run-messi-roboflow.sh <etapa>"
  echo "Orden: prepare -> generate -> download -> process -> cpu -> status"
  echo "all: ejecuta el orden completo. stop: detiene el job y escala Roboflow a cero."
  echo "Requiere MENTOX_AZURE_SUBSCRIPTION_ID y MENTOX_MODEL_API_KEY."
  echo "Guía: docs/persona-1-datos-y-vision/ejecutar-lote-messi-roboflow.md"
}
case "$action" in
  help|-h|--help) usage; exit 0 ;;
  all|prepare|generate|download|process|cpu|status|stop) ;;
  *) usage >&2; exit 2 ;;
esac
die() { echo "Error: $*" >&2; exit 1; }
for tool in az python3; do
  command -v "$tool" >/dev/null || die "Falta $tool."
done
: "${MENTOX_AZURE_SUBSCRIPTION_ID:?Exporte el ID de la suscripción del operador}"
export MENTOX_AZURE_RESOURCE_GROUP="${MENTOX_AZURE_RESOURCE_GROUP:-rg-mentox-dev}"
export MENTOX_AZURE_LOCATION="${MENTOX_AZURE_LOCATION:-northcentralus}"
export MENTOX_ROBOFLOW_APP_NAME="${MENTOX_ROBOFLOW_APP_NAME:-ca-mentox-roboflow-dev}"
export MENTOX_MESSI_JOB_NAME="${MENTOX_MESSI_JOB_NAME:-job-mentox-messi-dev}"
export MENTOX_CONTAINERAPPS_ENVIRONMENT="${MENTOX_CONTAINERAPPS_ENVIRONMENT:-cae-mentox-vision-dev}"
export MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP="${MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP:-$MENTOX_AZURE_RESOURCE_GROUP}"
export MENTOX_BATCH_ID="${MENTOX_BATCH_ID:-messi-clean-3x180s-20261031}"
export MENTOX_BASE_SEED="${MENTOX_BASE_SEED:-20261031}"
export MENTOX_BLOB_CONTAINER="${MENTOX_BLOB_CONTAINER:-synthetic-videos}"
export MENTOX_MATCH_COUNT=3 MENTOX_MATCH_SECONDS=180 MENTOX_RENDER_MODE=clean
export MENTOX_CONTROL_FPS=15 MENTOX_RENDER_FPS=15 MENTOX_STATE_STRIDE=15
export MENTOX_START_JOB=0 MENTOX_MIN_REPLICAS=0 MENTOX_MAX_REPLICAS=1
export MENTOX_IMAGE_BUILD_MODE=local
[[ "$MENTOX_BATCH_ID" =~ ^[a-zA-Z0-9_-]+$ ]] || die "MENTOX_BATCH_ID inválido."
suffix="$(printf '%s' "$MENTOX_AZURE_SUBSCRIPTION_ID:$MENTOX_AZURE_RESOURCE_GROUP" | sha256sum | cut -c1-16)"
export MENTOX_STORAGE_ACCOUNT="${MENTOX_STORAGE_ACCOUNT:-stprime${suffix}}"
batch_dir="$repo_root/evidencias-generadas/$MENTOX_BATCH_ID"
match_root="$batch_dir/messi/$MENTOX_BATCH_ID"
venv_dir="$repo_root/evidencias-generadas/roboflow-tools-venv"
catalog="$repo_root/deploy/azure-roboflow-replay/data/catalog.json"

# Los scripts históricos usan la cuenta activa. La selección es explícita y
# se vuelve a comprobar antes de invocarlos; no contiene IDs personales.
az account set --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID"
actual_id="$(az account show --query id --output tsv)"
[[ "${actual_id,,}" == "${MENTOX_AZURE_SUBSCRIPTION_ID,,}" ]] || die "Suscripción activa incorrecta."
azs() { az "$@" --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID"; }

require_key() {
  [[ -n "${MENTOX_MODEL_API_KEY:-}" ]] || die "Exporte MENTOX_MODEL_API_KEY."
  [[ ${#MENTOX_MODEL_API_KEY} -ge 32 ]] || die "MENTOX_MODEL_API_KEY debe tener al menos 32 caracteres."
}
endpoint() {
  local fqdn
  fqdn="$(azs containerapp show -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_ROBOFLOW_APP_NAME" \
    --query properties.configuration.ingress.fqdn -o tsv)"
  [[ -n "$fqdn" ]] || die "La aplicación no tiene endpoint."
  export ROBOFLOW_SUITE_ENDPOINT="https://$fqdn"
  export ROBOFLOW_SUITE_API_KEY="$MENTOX_MODEL_API_KEY"
}
verify_batch() {
  python3 deploy/azure-roboflow-replay/verify_messi_batch.py "$match_root"
}
prepare() {
  require_key
  [[ "${MENTOX_ACCEPT_MODEL_LICENSES:-0}" == 1 ]] || die "Revise las licencias y exporte MENTOX_ACCEPT_MODEL_LICENSES=1."
  for tool in docker uv ffmpeg curl sha256sum; do
    command -v "$tool" >/dev/null || die "Falta $tool."
  done
  mkdir -p "$batch_dir"
  uv venv --python 3.12 --allow-existing "$venv_dir"
  uv pip install --python "$venv_dir/bin/python" \
    --requirements deploy/azure-roboflow-replay/requirements.txt
  bash infra/azure/deploy-roboflow-suite.sh
  azs provider register --namespace Microsoft.Storage --wait
  if ! azs storage account show -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_STORAGE_ACCOUNT" >/dev/null 2>&1; then
    azs storage account create -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_STORAGE_ACCOUNT" \
      --location "$MENTOX_AZURE_LOCATION" --sku Standard_LRS --kind StorageV2 \
      --allow-blob-public-access false --allow-shared-key-access false --output none
  fi
  local operator_id storage_id
  operator_id="$(az ad signed-in-user show --query id -o tsv)"
  storage_id="$(azs storage account show -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_STORAGE_ACCOUNT" --query id -o tsv)"
  if [[ "$(azs role assignment list --assignee-object-id "$operator_id" --scope "$storage_id" \
    --role 'Storage Blob Data Contributor' --query 'length(@)' -o tsv)" == 0 ]]; then
    azs role assignment create --assignee-object-id "$operator_id" --assignee-principal-type User \
      --role 'Storage Blob Data Contributor' --scope "$storage_id" --output none
  fi
  local ready=0
  for ((attempt=0; attempt<60; attempt++)); do
    if az storage container create --account-name "$MENTOX_STORAGE_ACCOUNT" --name "$MENTOX_BLOB_CONTAINER" \
      --auth-mode login --public-access off --output none; then ready=1; break; fi
    sleep 10
  done
  [[ "$ready" == 1 ]] || die "RBAC de Storage no se propagó. Repita prepare más tarde."
  echo "Preparación completa. GPU configurada con mínimo cero."
}
generate() {
  local existing execution status deadline
  existing="$(azs containerapp job execution list -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" \
    --query "[?properties.status=='Running'].name | [0]" -o tsv 2>/dev/null || true)"
  [[ -z "$existing" ]] || die "MESSI ya tiene una ejecución activa: $existing. Use status."
  # No regenerar un lote remoto terminado bajo el mismo identificador.
  if [[ "$(az storage blob exists --account-name "$MENTOX_STORAGE_ACCOUNT" -c "$MENTOX_BLOB_CONTAINER" \
    -n "messi/$MENTOX_BATCH_ID/batch-manifest.json" --auth-mode login --query exists -o tsv)" == true ]]; then
    echo "El lote remoto ya existe. Continúe con download o use otro MENTOX_BATCH_ID."
    return
  fi
  bash infra/azure/deploy-messi-generator.sh
  execution="$(azs containerapp job start -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" --query name -o tsv)"
  [[ -n "$execution" ]] || die "Azure no devolvió el nombre de ejecución."
  mkdir -p "$batch_dir"
  printf '%s\n' "$execution" > "$batch_dir/execution-name.txt"
  echo "Generando tres partidos clean: $execution"
  deadline=$((SECONDS + ${MENTOX_PIPELINE_WAIT_SECONDS:-86400}))
  while ((SECONDS < deadline)); do
    status="$(azs containerapp job execution list -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" \
      --query "[?name=='$execution'].properties.status | [0]" -o tsv)"
    echo "MESSI: ${status:-pendiente}"
    case "$status" in
      Succeeded) return ;;
      Failed|Stopped|Degraded) die "MESSI terminó con estado $status. Revise logs; no continúe con Roboflow." ;;
    esac
    sleep 20
  done
  azs containerapp job stop -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" \
    --job-execution-name "$execution" --output none
  die "Se agotó el tiempo de espera; se solicitó detener la ejecución MESSI."
}
download() {
  mkdir -p "$batch_dir"
  az storage blob download-batch --account-name "$MENTOX_STORAGE_ACCOUNT" --auth-mode login \
    --source "$MENTOX_BLOB_CONTAINER" --destination "$batch_dir" \
    --pattern "messi/$MENTOX_BATCH_ID/*" --overwrite true --output none
  verify_batch
  echo "Paquetes completos guardados en $match_root"
}
gpu_off() { bash infra/azure/stop-roboflow-gpu.sh; }
process() (
  require_key
  verify_batch
  [[ -x "$venv_dir/bin/python" ]] || die "Falta el entorno Python; ejecute prepare."
  endpoint
  # Incluso si falla el generador o se interrumpe la terminal, solicitar escala cero.
  trap gpu_off EXIT
  azs containerapp update -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_ROBOFLOW_APP_NAME" \
    --min-replicas 1 --max-replicas 1 --output none
  local ready=0
  for ((attempt=0; attempt<120; attempt++)); do
    if curl --fail --silent --show-error --max-time 15 "$ROBOFLOW_SUITE_ENDPOINT/health/ready" \
      | python3 -c 'import json,sys; p=json.load(sys.stdin); sys.exit(0 if p.get("status")=="ready" and p.get("device") not in ("precomputed-cpu", "precomputed-cache") else 1)'; then
      ready=1; break
    fi
    sleep 10
  done
  [[ "$ready" == 1 ]] || die "La GPU no quedó lista en el plazo esperado."
  "$venv_dir/bin/python" deploy/azure-roboflow-replay/precompute.py \
    --video "messi-001=$match_root/messi-001/match.mp4" \
    --video "messi-002=$match_root/messi-002/match.mp4" \
    --video "messi-003=$match_root/messi-003/match.mp4" --output "$catalog"
  cp "$catalog" "$batch_dir/roboflow-catalog.json"
  sha256sum "$catalog" "$batch_dir/roboflow-catalog.json"
)
cpu() {
  require_key
  verify_batch
  [[ -s "$batch_dir/roboflow-catalog.json" ]] || die "Falta el respaldo del catálogo; ejecute process."
  cmp "$catalog" "$batch_dir/roboflow-catalog.json" || die "El catálogo y su respaldo difieren."
  bash infra/azure/deploy-roboflow-replay.sh
  if azs containerapp job show -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" >/dev/null 2>&1; then
    MENTOX_CONFIRM_DELETE_JOB=1 bash infra/azure/delete-messi-generator-job.sh
  fi
  echo "Se conserva Storage con el lote y ACR con las imágenes. La aplicación ahora usa CPU."
}
status() {
  azs containerapp show -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_ROBOFLOW_APP_NAME" \
    --query '{name:name,profile:properties.workloadProfileName,min:properties.template.scale.minReplicas,fqdn:properties.configuration.ingress.fqdn}' -o json
  azs containerapp revision list -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_ROBOFLOW_APP_NAME" \
    --query '[].{name:name,replicas:properties.replicas,state:properties.runningState}' -o table
  azs containerapp job execution list -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" \
    --query '[].{name:name,status:properties.status}' -o table || true
  [[ ! -d "$match_root" ]] || verify_batch
}
stop() {
  gpu_off
  if azs containerapp job show -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" >/dev/null 2>&1; then
    azs containerapp job stop -g "$MENTOX_AZURE_RESOURCE_GROUP" -n "$MENTOX_MESSI_JOB_NAME" --output none
  fi
}
if [[ "$action" == all ]]; then
  prepare
  generate
  download
  process
  cpu
  status
else
  "$action"
fi
