# Roboflow precalculado para tres vídeos fijos

Para ejecutar el recorrido completo desde un solo script, siga
[Ejecutar MESSI clean y Roboflow](ejecutar-lote-messi-roboflow.md). Esta guía
conserva los pasos individuales como referencia técnica.

Esta guía prepara las observaciones de Roboflow una sola vez con GPU y después
reemplaza el servicio por una API CPU compatible. No requiere cambios en
`apps/backend` ni `apps/frontend`.

Los resultados deben describirse como observaciones de Roboflow precalculadas,
no como inferencia en tiempo real. Use únicamente vídeos sintéticos o
autorizados.

## Resultado

El flujo conserva estos endpoints:

```text
GET  /health/live
GET  /health/ready
POST /v1/predict?models=all
```

También conserva `X-API-Key`, el campo multipart `image` y las listas
`player`, `ball` y `pitch`. El backend continúa enviando el fotograma visible.
La API CPU lo identifica mediante una huella visual y devuelve la respuesta
guardada.

## 1. Preparar la computadora del operador

Ejecute desde la raíz del repositorio:

```bash
az login
az account list --output table
az account set --subscription "<suscripción-del-operador>"
az account show --query "{nombre:name,estado:state,id:id}" --output table

export MENTOX_AZURE_SUBSCRIPTION_ID="<id-suscripción-del-operador>"
export MENTOX_AZURE_RESOURCE_GROUP="rg-mentox-dev"
export MENTOX_AZURE_LOCATION="northcentralus"
export MENTOX_MODEL_API_KEY="$(openssl rand -hex 32)"
export MENTOX_ACCEPT_MODEL_LICENSES=1
export MENTOX_IMAGE_BUILD_MODE=local
export MENTOX_MIN_REPLICAS=0
export MENTOX_MAX_REPLICAS=1
```

La clave permanece en la terminal del operador. No la copie a Git, documentos,
capturas ni mensajes públicos. Antes de continuar, lea las licencias descritas
en `deploy/azure-roboflow-suite/README.md`.

Compruebe Docker y la disponibilidad del perfil:

```bash
docker info

az containerapp env workload-profile list-supported \
  --location "$MENTOX_AZURE_LOCATION" \
  --query "[?name=='Consumption-GPU-NC8as-T4'].name" \
  --output table
```

## 2. Desplegar Roboflow GPU apagado

```bash
bash infra/azure/deploy-roboflow-suite.sh
```

El script crea el grupo si falta, ACR Basic, identidad, entorno, perfil T4 y
Container App. `MENTOX_MIN_REPLICAS=0` evita dejar una GPU encendida durante la
preparación.

Obtenga el endpoint sin exponer la clave:

```bash
export ROBOFLOW_SUITE_ENDPOINT="https://$(az containerapp show \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --resource-group "$MENTOX_AZURE_RESOURCE_GROUP" \
  --name ca-mentox-roboflow-dev \
  --query properties.configuration.ingress.fqdn --output tsv)"

export ROBOFLOW_SUITE_API_KEY="$MENTOX_MODEL_API_KEY"
```

## 3. Preparar los tres vídeos

Para esta demo se generan tres partidos nuevos con MESSI en modo `clean`.
Se reutilizan `deploy-messi-generator.sh`, `inspect-messi-generator.sh` y
`delete-messi-generator-job.sh`. No es necesario desplegar Event Hubs ni Service
Bus para generar los vídeos y crear este catálogo.

El soporte `clean` se recuperó del commit
`1f6e8dd5f72520923089a9dc727a80d946244c84` de la rama de integración. Usa el
renderizador `rich` con `--clean-hud`: conserva cancha, jugadores, dorsales,
marcador y reloj; oculta paneles, minimapa y barras del HUD. El generador MESSI
base sigue fijado a `b04b15c59d36c1e4f44e02d0886b2d0d7261f689`; no se cambia
la simulación para conseguir este aspecto visual.

### Preparar Storage en la suscripción del operador

Si el operador ya tiene Storage en el grupo, exporte su nombre. Si no lo tiene,
cree uno con un nombre global único de 3 a 24 letras minúsculas y números:

```bash
export MENTOX_STORAGE_ACCOUNT="<nombre-global-unico>"
export MENTOX_BLOB_CONTAINER=synthetic-videos

az storage account create \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --resource-group "$MENTOX_AZURE_RESOURCE_GROUP" \
  --name "$MENTOX_STORAGE_ACCOUNT" \
  --location "$MENTOX_AZURE_LOCATION" \
  --sku Standard_LRS --kind StorageV2 \
  --allow-blob-public-access false --allow-shared-key-access false

operator_id="$(az ad signed-in-user show --query id --output tsv)"
storage_id="$(az storage account show \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --resource-group "$MENTOX_AZURE_RESOURCE_GROUP" \
  --name "$MENTOX_STORAGE_ACCOUNT" --query id --output tsv)"

az role assignment create \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --assignee-object-id "$operator_id" --assignee-principal-type User \
  --role "Storage Blob Data Contributor" --scope "$storage_id"
```

El rol permite crear el contenedor y descargar los resultados. Puede tardar en
propagarse; espere antes de continuar si Storage devuelve un error de permisos.
El script MESSI asigna por separado permisos a la identidad del job.

### Generar exactamente tres partidos clean

Ejecute en la misma terminal que seleccionó la suscripción del operador. Los
scripts MESSI existentes usan la cuenta activa de Azure CLI:

```bash
az account set --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID"

export MENTOX_MATCH_COUNT=3
export MENTOX_MATCH_SECONDS=180
export MENTOX_BASE_SEED=20261031
export MENTOX_RENDER_MODE=clean
export MENTOX_CONTROL_FPS=15
export MENTOX_RENDER_FPS=15
export MENTOX_STATE_STRIDE=15
export MENTOX_BATCH_ID=messi-clean-3x180s-20261031
export MENTOX_START_JOB=0
export MENTOX_IMAGE_BUILD_MODE=local

bash infra/azure/deploy-messi-generator.sh

az containerapp job start \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --resource-group "$MENTOX_AZURE_RESOURCE_GROUP" \
  --name job-mentox-messi-dev

bash infra/azure/inspect-messi-generator.sh
```

El job consume GPU mientras genera los partidos y termina automáticamente.
Mantenga Roboflow en escala cero durante esta etapa. La inspección debe mostrar
`Succeeded` y estos cinco archivos para `messi-001`, `messi-002` y `messi-003`:

```text
match.mp4
events.jsonl
tracking.jsonl
metadata.jsonl
manifest.json
```

### Descargar y verificar el lote

Use un directorio vacío y conserve el paquete completo:

```bash
export MENTOX_LOCAL_BATCH_DIR="$PWD/evidencias-generadas/$MENTOX_BATCH_ID"
mkdir -p "$MENTOX_LOCAL_BATCH_DIR"

az storage blob download-batch \
  --account-name "$MENTOX_STORAGE_ACCOUNT" \
  --auth-mode login --source "$MENTOX_BLOB_CONTAINER" \
  --destination "$MENTOX_LOCAL_BATCH_DIR" \
  --pattern "messi/$MENTOX_BATCH_ID/*"

export MENTOX_LOCAL_MATCH_ROOT="$MENTOX_LOCAL_BATCH_DIR/messi/$MENTOX_BATCH_ID"

python3 deploy/azure-roboflow-replay/verify_messi_batch.py \
  "$MENTOX_LOCAL_MATCH_ROOT"
```

La verificación exige tres partidos `clean`, comprueba los tamaños y SHA-256 de
los cuatro artefactos de cada manifiesto, y rechaza archivos faltantes. No
elimine el job hasta completar esta descarga y mantener un respaldo del lote.
Después reutilice el script de limpieza existente:

```bash
MENTOX_CONFIRM_DELETE_JOB=1 bash infra/azure/delete-messi-generator-job.sh
```

Cada vídeo recibe un identificador estable para el catálogo. Compruebe sus hashes:

```bash
sha256sum \
  "$MENTOX_LOCAL_MATCH_ROOT/messi-001/match.mp4" \
  "$MENTOX_LOCAL_MATCH_ROOT/messi-002/match.mp4" \
  "$MENTOX_LOCAL_MATCH_ROOT/messi-003/match.mp4"
```

Prepare un Python temporal; no modifica el backend:

```bash
uv venv --python 3.12 /tmp/prime-roboflow-replay-venv
uv pip install \
  --python /tmp/prime-roboflow-replay-venv/bin/python \
  numpy==2.1.2 pillow==11.0.0
```

## 4. Encender una sola GPU

```bash
az containerapp update \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --resource-group "$MENTOX_AZURE_RESOURCE_GROUP" \
  --name ca-mentox-roboflow-dev \
  --min-replicas 1 --max-replicas 1
```

Espere hasta recibir `status=ready`:

```bash
until curl --fail --silent --show-error \
  "$ROBOFLOW_SUITE_ENDPOINT/health/ready"; do
  sleep 10
done
```

## 5. Generar el catálogo

El generador extrae un fotograma por segundo, llama a los tres modelos y guarda
la respuesta completa, hashes y huella visual:

```bash
/tmp/prime-roboflow-replay-venv/bin/python \
  deploy/azure-roboflow-replay/precompute.py \
  --video messi-001="$MENTOX_LOCAL_MATCH_ROOT/messi-001/match.mp4" \
  --video messi-002="$MENTOX_LOCAL_MATCH_ROOT/messi-002/match.mp4" \
  --video messi-003="$MENTOX_LOCAL_MATCH_ROOT/messi-003/match.mp4"
```

La salida queda en:

```text
deploy/azure-roboflow-replay/data/catalog.json
```

El archivo está ignorado por Git porque puede ser grande y contiene resultados
derivados de los vídeos. Debe respaldarse por un canal autorizado antes de
eliminar la GPU.

El comando falla si no recibe exactamente tres vídeos, si falta un archivo o si
Roboflow no devuelve `player`, `ball` y `pitch`.

## 6. Apagar la GPU inmediatamente

Aunque el siguiente paso también reemplaza la aplicación, apague primero la
réplica para detener el consumo si ocurre cualquier problema posterior:

```bash
bash infra/azure/stop-roboflow-gpu.sh
```

No continúe hasta que la tabla muestre cero réplicas.

## 7. Probar la API CPU localmente

Instale las dependencias de la API en el entorno temporal:

```bash
uv pip install \
  --python /tmp/prime-roboflow-replay-venv/bin/python \
  --requirements deploy/azure-roboflow-replay/requirements.txt
```

Inicie la API:

```bash
MENTOX_MODEL_API_KEY="$MENTOX_MODEL_API_KEY" \
MENTOX_PRECOMPUTED_CATALOG="$PWD/deploy/azure-roboflow-replay/data/catalog.json" \
/tmp/prime-roboflow-replay-venv/bin/python -m uvicorn app:app \
  --app-dir deploy/azure-roboflow-replay \
  --host 127.0.0.1 --port 8010
```

En otra terminal, con la misma clave:

```bash
curl --fail http://127.0.0.1:8010/health/ready

ffmpeg -hide_banner -loglevel error -y \
  -ss 5 -i "$MENTOX_LOCAL_MATCH_ROOT/messi-001/match.mp4" -frames:v 1 /tmp/prime-frame.jpg

curl --fail-with-body \
  --header "X-API-Key: $MENTOX_MODEL_API_KEY" \
  --form "image=@/tmp/prime-frame.jpg" \
  "http://127.0.0.1:8010/v1/predict?models=all"
```

La respuesta debe incluir los tres modelos y
`execution_mode=precomputed_video_lookup`.

## 8. Reemplazar la GPU por el contenedor CPU

El script construye y sube la imagen CPU. Solo después elimina la aplicación
GPU y crea otra con el mismo nombre y contrato sobre `Consumption`:

```bash
export MENTOX_IMAGE_BUILD_MODE=local
export MENTOX_MIN_REPLICAS=0

bash infra/azure/deploy-roboflow-replay.sh
```

Guarde el endpoint impreso. Si coincide con el anterior, no se cambia ninguna
configuración. Si Azure entrega otro FQDN, actualice únicamente
`ROBOFLOW_SUITE_ENDPOINT` en el entorno del backend; no cambie su código.

Para preparar una demo sin arranque en frío:

```bash
az containerapp update \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --resource-group "$MENTOX_AZURE_RESOURCE_GROUP" \
  --name ca-mentox-roboflow-dev \
  --min-replicas 1 --max-replicas 1
```

La réplica ahora es CPU de 0.5 vCPU y 1 GiB, no T4. Al terminar:

```bash
az containerapp update \
  --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID" \
  --resource-group "$MENTOX_AZURE_RESOURCE_GROUP" \
  --name ca-mentox-roboflow-dev \
  --min-replicas 0 --max-replicas 1
```

## 9. Verificaciones obligatorias

1. Los tres hashes de vídeo coinciden con el manifiesto.
2. El catálogo contiene los tres `video_id`.
3. `/health/ready` informa `precomputed-cpu`.
4. `/v1/predict` devuelve exactamente `player`, `ball` y `pitch`.
5. Un fotograma ajeno devuelve error; no usa el resultado más cercano sin límite.
6. Play, Pause, Seek y Restart funcionan desde la interfaz sin cambiarla.
7. Azure muestra cero réplicas GPU.
8. La demo identifica los resultados como precalculados.

## Limitaciones

- La huella visual debe calibrarse con las capturas reales de los navegadores de
  la demo. Los umbrales pueden configurarse con
  `MENTOX_REPLAY_MAX_VISUAL_SCORE` y `MENTOX_REPLAY_MIN_SCORE_MARGIN`.
- Un vídeo nuevo exige repetir el preprocesamiento.
- La API rechaza fotogramas desconocidos o ambiguos en lugar de inventar datos.
- ACR Basic y una réplica CPU activa todavía pueden generar cargos pequeños.
