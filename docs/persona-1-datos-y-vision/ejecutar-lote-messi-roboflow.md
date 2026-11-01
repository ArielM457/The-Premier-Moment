# Ejecutar MESSI clean y Roboflow desde un solo script

El operador ejecutará `infra/azure/run-messi-roboflow.sh` en su propia
suscripción. El script reúne los despliegues existentes y las herramientas de
preprocesamiento. Genera tres partidos clean de 180 segundos, descarga sus
paquetes completos, crea el catálogo Roboflow y reemplaza la aplicación GPU por
el servicio CPU compatible.

El código de frontend y backend permanece intacto. Los resultados de la demo
son observaciones precalculadas de Roboflow. La coincidencia visual todavía debe
validarse con los tres vídeos y las capturas del navegador antes de la demo.

## Requisitos

Use Ubuntu o WSL, una suscripción habilitada con cuota T4 en `northcentralus`,
permisos para crear recursos y asignar roles, Azure CLI con la extensión
`containerapp`, Docker funcionando, Python 3, `uv`, `ffmpeg`, `curl` y
`sha256sum`. Los scripts históricos de construcción requieren `sudo` para Docker;
ejecute `sudo -v` antes de comenzar y mantenga disponible esa terminal.

Revise las condiciones de modelos en `deploy/azure-roboflow-suite/README.md`.
Utilice una copia del repositorio que incluya los archivos nuevos: estos cambios
todavía no se han confirmado ni publicado mediante Git automáticamente.

## 1. Abrir la terminal y configurar la suscripción del amigo

Desde la raíz del repositorio:

```bash
az login
az account list --output table

export MENTOX_AZURE_SUBSCRIPTION_ID="<UUID-de-la-suscripción-de-tu-amigo>"
export MENTOX_AZURE_RESOURCE_GROUP="rg-mentox-dev"
export MENTOX_AZURE_LOCATION="northcentralus"
export MENTOX_ACCEPT_MODEL_LICENSES=1

# Crear una sola vez y conservar en un gestor de contraseñas.
export MENTOX_MODEL_API_KEY="$(openssl rand -hex 32)"

az account set --subscription "$MENTOX_AZURE_SUBSCRIPTION_ID"
az account show --query '{nombre:name,id:id,estado:state}' --output table
sudo -v
```

Verifique que el ID mostrado sea el de su amigo. El script exige esa variable,
no lleva ningún ID personal incorporado. Los scripts MESSI históricos utilizan
la cuenta activa: evite cambiarla desde otra terminal durante la ejecución.

Si se cierra la terminal, vuelva a exportar las variables y recupere **la misma
clave** del gestor. No genere una clave distinta para reanudar.

Variables opcionales:

```bash
# Solo para usar una cuenta Storage existente en el mismo grupo:
export MENTOX_STORAGE_ACCOUNT="<nombre-storage-existente>"

# Para un lote distinto, establezca un ID nuevo y otra semilla:
export MENTOX_BATCH_ID="messi-clean-demo-01"
export MENTOX_BASE_SEED=20261031

# Para usar un entorno de Container Apps que ya existe en otro grupo:
export MENTOX_CONTAINERAPPS_ENVIRONMENT="<nombre-del-entorno>"
export MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP="<grupo-del-entorno>"
```

Una suscripción Azure for Students admite un solo entorno de Container Apps.
Si la demo ya tiene uno, use ese entorno: `MENTOX_AZURE_LOCATION` debe ser su
región y esa región debe tener T4. La aplicación Roboflow, el job MESSI, el ACR,
las identidades y Storage se crean en `MENTOX_AZURE_RESOURCE_GROUP`. El perfil
T4 se agrega al entorno compartido. A partir de entonces, despliegue la demo con
`-GpuWorkloadProfile` para no quitarlo.

Si no se define Storage, el script calcula un nombre a partir de la suscripción
y el grupo. Por defecto el lote es `messi-clean-3x180s-20261031`. Mantenga estas
variables iguales entre etapas.

## 2. Elegir ejecución completa o por etapas

Para ejecutar el recorrido completo:

```bash
bash infra/azure/run-messi-roboflow.sh all
```

No ejecute a la vez el recorrido completo y las etapas manuales. Durante la
generación puede mostrar `MESSI: Running` por bastante tiempo. El script consulta
el estado cada 20 segundos; la generación de tres renders clean puede ser lenta.
Al terminar continúa automáticamente con las descargas.

Para controlar cada paso, use el siguiente orden en la misma terminal:

| Orden | Comando | Qué hace y qué comprobar |
|---|---|---|
| 1 | `bash infra/azure/run-messi-roboflow.sh prepare` | Instala herramientas Python aisladas, despliega Roboflow en mínimo cero y crea Storage con permisos. Debe terminar con «Preparación completa». |
| 2 | `bash infra/azure/run-messi-roboflow.sh generate` | Reutiliza el despliegue MESSI y espera a que tres partidos `clean` terminen en `Succeeded`. Roboflow sigue en mínimo cero. |
| 3 | `bash infra/azure/run-messi-roboflow.sh download` | Descarga y verifica los cinco archivos de cada partido, con tamaños y SHA-256. |
| 4 | `bash infra/azure/run-messi-roboflow.sh process` | Enciende una GPU Roboflow, espera disponibilidad, procesa los tres MP4 y respalda el catálogo. Solicita volver a mínimo cero al terminar o fallar. |
| 5 | `bash infra/azure/run-messi-roboflow.sh cpu` | Comprueba el respaldo, sube la imagen CPU y reemplaza la aplicación GPU. Elimina el job MESSI; conserva vídeos, imágenes y datos. |
| 6 | `bash infra/azure/run-messi-roboflow.sh status` | Muestra perfil, endpoint, revisiones, réplicas y la integridad de los paquetes locales. |

`cpu` elimina y recrea únicamente la aplicación Roboflow, por lo que habrá una
interrupción. Confirme que el perfil final sea `Consumption` y el mínimo, cero.
La ausencia del job MESSI después del paso 5 es esperada.

## 3. Archivos que recibirá el equipo

El lote completo se guarda en:

```text
evidencias-generadas/<batch-id>/
  execution-name.txt
  roboflow-catalog.json
  messi/<batch-id>/
    batch-manifest.json
    messi-001/
      match.mp4
      events.jsonl
      tracking.jsonl
      metadata.jsonl
      manifest.json
    messi-002/ (los mismos cinco archivos)
    messi-003/ (los mismos cinco archivos)
```

El catálogo usado para construir la imagen CPU también queda en:

```text
deploy/azure-roboflow-replay/data/catalog.json
```

El script compara el catálogo con su respaldo antes de reemplazar la GPU.
Transfiera al equipo el lote completo y el catálogo por un canal autorizado.
No borre Storage hasta tener un respaldo independiente. Estos archivos están
excluidos de Git.

## 4. Conectar el servicio a la aplicación

El script CPU imprime el endpoint. El responsable de la configuración debe usar
ese endpoint y la misma clave en las variables ya existentes:

```bash
export ROBOFLOW_SUITE_ENDPOINT="https://<endpoint-impreso>"
export ROBOFLOW_SUITE_API_KEY="<clave-del-gestor>"
```

Esto actualiza la configuración del servicio y no requiere editar código. El
MP4 reproducido por la app debe ser exactamente uno de los tres generados;
mantenga el paquete MESSI correspondiente. La configuración de cuál vídeo sirve
la app sigue siendo responsabilidad del despliegue existente.

Pruebe los tres vídeos con Play, Pause, Seek y Restart. El servicio conserva
`/health/live`, `/health/ready`, `/v1/predict?models=all`, `X-API-Key`, multipart
`image` y los resultados `player`, `ball` y `pitch`. Puede rechazar con error una
captura desconocida o ambigua: ajuste y compruebe la coincidencia visual antes
de dar la demo por verificada. La guía técnica complementaria es
[guia-roboflow-precalculado.md](guia-roboflow-precalculado.md).

## 5. Si algo falla o hay que interrumpir

Detenga explícitamente el consumo temporal:

```bash
bash infra/azure/run-messi-roboflow.sh stop
bash infra/azure/run-messi-roboflow.sh status
```

`stop` solicita detener las ejecuciones MESSI y bajar el mínimo de Roboflow a
cero. Espere hasta ver cero réplicas: el apagado no es instantáneo. No es una
eliminación de Storage ni del grupo.

Si interrumpe `generate`, el job remoto puede continuar; ejecute `stop` si quiere
cancelarlo. Si solo quiere revisar su progreso, use `status` sin iniciar otra
ejecución. Cuando termine, puede continuar directamente con `download`.

Si falla `process`, la solicitud de apagado se hace mediante un `trap`, pero
depende de que Azure siga accesible. Compruebe siempre `status`. El generador
actual escribe el catálogo al completar todos los fotogramas: un fallo a mitad
del proceso requiere repetir `process`.

Si el lote remoto ya tiene su `batch-manifest.json`, `generate` lo reutiliza y
no empieza otra ejecución con ese mismo lote. Para generar partidos nuevos,
cambie `MENTOX_BATCH_ID` y, si corresponde, la semilla.

El comando `all` tiene las mismas condiciones; al reanudar después de un fallo
use la etapa pendiente en lugar de volver a desplegar todo. No ejecute `prepare`
sobre el contenedor CPU final salvo que quiera volver al servicio GPU.

ACR Basic y Storage conservados pueden generar cargos aunque las réplicas estén
en cero. Este flujo no crea Event Hubs ni Service Bus.
