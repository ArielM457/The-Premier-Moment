# Lote MESSI clean y Roboflow precalculado en Azure

## Identificación

- **Fecha:** 1 de noviembre de 2026.
- **Operación:** `infra/azure/run-messi-roboflow.sh`, etapas `prepare`,
  `generate`, `download`, `process`, `fingerprint`, `cpu` y `status`.
- **Suscripción:** Azure for Students del operador de Persona 2, distinta de la
  que alojaba los modelos anteriores.
- **Estado:** lote generado y verificado; Roboflow CPU y TeamSpotting GPU
  desplegados y probados en Azure; vídeo copiado al Storage de la demo y
  configuración del backend actualizada. Falta el despliegue de la demo que la
  aplica y el recorrido en el navegador. Esta evidencia no marca ninguna
  historia como verificada.

## Recursos en Azure

| Recurso | Nombre | Grupo y región |
|---|---|---|
| Entorno de Container Apps compartido con la demo | `cae-mentoxp2-demo-wp`, perfiles `Consumption` y `NC8as-T4` | `rg-mentox-analytics`, `eastus` |
| Registro | `mentox763c928d` | `rg-mentox-dev`, `eastus` |
| Storage del lote | `stprime763c928d0dc2e988`, contenedor `synthetic-videos` | `rg-mentox-dev`, `eastus` |
| Roboflow, ahora CPU | `ca-mentox-roboflow-dev`, `Consumption`, réplicas `0-1` | `rg-mentox-dev`, `eastus` |
| TeamSpotting GPU | `ca-mentox-teamspotting-dev`, `NC8as-T4`, réplicas `0-1` | `rg-mentox-dev`, `eastus` |
| Vídeo de la demo | `authorized-videos/messi/messi-clean-3x180s-20261031/messi-001/`, cinco archivos | `stmentoxp2ske7orupdfe76`, `rg-mentox-analytics` |
| Job MESSI | `job-mentox-messi-dev`, eliminado por `cpu` | `rg-mentox-dev` |

La suscripción admite un solo entorno de Container Apps. Los scripts usan el de
la demo mediante `MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP`. La cuota T4
del entorno es de 2 GPU.

## Resultados

| Etapa | Resultado |
|---|---|
| `prepare` | Perfil T4 agregado al entorno compartido. Roboflow GPU creado con mínimo cero. Storage creado con permisos del operador. |
| `generate` | Ejecución `job-mentox-messi-dev-oi4324z`: `Succeeded`, de 20:09:47 a 21:03:27 UTC. Tres partidos de 180 s, render `clean` a 15 FPS. |
| `download` | Los tres paquetes pasan la verificación de tamaño y SHA-256. |
| `process` | 540 fotogramas, uno por segundo, procesados en `Tesla T4`. Hubo 101 reintentos por cortes de conexión; ninguno agotó sus cinco intentos. |
| `fingerprint` | Huella de primer plano agregada a los 540 registros. Cada fotograma reproducido coincide con su `frame_sha256`. |
| `cpu` | Imagen `roboflow-precomputed-replay:41fe7948fd62` desplegada en `Consumption`. Job MESSI eliminado. |

Vídeos del lote `messi-clean-3x180s-20261031`, MESSI `b04b15c59d36c1e4f44e02d0886b2d0d7261f689`:

| Vídeo | SHA-256 del MP4 | Jugadores detectados | Fotogramas con balón | Detecciones de campo |
|---|---|---|---|---|
| `messi-001` | `d8b56a76ad63ab3f60ef3d358bbb8c9df18831d243ec5df30dd229b5b8c07607` | 2611 | 121 de 180 | 1 |
| `messi-002` | `c6e63d5108376b73aebfeb9df7bd30491001badaf6826939d7b9f8e0cbe029bc` | 2604 | 90 de 180 | 0 |
| `messi-003` | `2da3f6d54333a186371486668ddbaa6389d03dd5bcd56b432b7d12811b96571c` | 2473 | 78 de 180 | 0 |

Catálogo: 540 registros. SHA-256 sin huella de primer plano:
`b0fe4b3df9bfea0395ca57904b2624cd77b4cf233bd03aa89f7351bc63eeac61`. Con ella:
`5215d16725fa3e25843a4d8077aad32a09670d7b6f348a052dc06e74a57c8a8c`.

## Coincidencia visual

Con la miniatura de 32x18, los 360 fotogramas de muestra recibieron 409. La
cámara del render es fija y todos los fotogramas quedan a menos de 0.0002 entre
sí; el margen exigido era 0.002.

Con la huella de primer plano, `app.py` y el catálogo real respondieron así a
180 capturas JPEG 0.82 tomadas en instantes al azar:

| Resultado | Capturas |
|---|---|
| Vídeo correcto, a 1 s o menos | 176 |
| Vídeo correcto, a 1.5 s | 1 |
| 409 entre los segundos 90 y 91, saque del segundo tiempo | 3 |
| Otro vídeo u otro momento | 0 |

29 fotogramas de un render MESSI que no está en el catálogo recibieron 22
respuestas 409, 4 respuestas 422 y 3 respuestas 200.

Prueba contra el servicio desplegado, con fotogramas reales:

```text
messi-001 42.0 s  -> 200 messi-001 42000 ms, 16 jugadores
messi-001 42.7 s  -> 200 messi-001 42000 ms, 16 jugadores
messi-002 100.3 s -> 200 messi-002 100000 ms, 18 jugadores, 1 balón
messi-003 150.5 s -> 200 messi-003 150000 ms, 15 jugadores
messi-003 12.2 s  -> 200 messi-003 12000 ms, 9 jugadores
Sin clave -> 401. Imagen ajena de color plano -> 422.
```

## TeamSpotting

La imagen `soccernet-teamspotting:a69708c66769` ocupa 30.1 GB; doce capas se
reutilizaron de Roboflow. La subida tardó unos 75 minutos con 5 a 20 Mbit/s.
La aplicación se creó después con `MENTOX_IMAGE_BUILD_MODE=existing` y respondió
`ready` en `Tesla T4` unos dos minutos después.

Prueba con `messi-001` contra el servicio desplegado:

```text
Sin clave -> 401
Con clave -> 200 en 196 s, device Tesla T4
217 predicciones: pass 169, drive 34, high pass 8, throw in 3, out 2, header 1
Predicciones con confianza >= 0.3: 0
```

## Conexión con la demo

- Los cinco archivos de `messi-001` están en `authorized-videos` del Storage de
  la demo, con el mismo SHA-256 del MP4.
- `deploy-analytics.ps1` usa ese vídeo por defecto y conserva el perfil T4 si el
  entorno ya lo tiene.
- `apps/backend/.env` apunta a los dos endpoints nuevos con la clave de los
  modelos. El archivo no está en Git.
- Los Event Hubs, el Service Bus y el Storage anteriores de la configuración
  local ya no existen. La demo en Azure no los usa.

## Cambios técnicos

| Archivo | Cambio |
|---|---|
| `infra/azure/deploy-gpu-model-common.sh`, `deploy-messi-generator.sh`, `deploy-roboflow-replay.sh`, `run-messi-roboflow.sh` | Usan un entorno de otro grupo por su ID. |
| `infra/azure/run-messi-roboflow.sh` | `MENTOX_IMAGE_BUILD_MODE=existing` reutiliza una imagen publicada; etapa `fingerprint`. |
| `deploy/azure-roboflow-replay/precompute.py` | Reintentos con espera ante errores de red y respuestas 429 o 5xx; genera la huella de primer plano. |
| `deploy/azure-roboflow-replay/fingerprint.py`, `app.py` | Huella de primer plano y regla de ambigüedad que ignora vecinos del mismo vídeo a 2 s o menos. |
| `deploy/azure-roboflow-replay/add_foreground.py` | Agrega la huella a un catálogo anterior sin GPU. |
| `infra/azure/deploy-analytics.ps1`, `analytics-platform.bicep` | El entorno de la demo puede vivir en otra región; `-GpuWorkloadProfile` conserva el perfil T4. |

## Pruebas automatizadas

`test_replay.py` y `test_pipeline.py`: 13 pruebas aprobadas en Linux. Cubren
los reintentos, la clave rechazada, el agotamiento de intentos, la captura entre
dos segundos, el fotograma compartido por dos vídeos, el fotograma ajeno y el
orden de las etapas.

## Reproducción

Desde la raíz del repositorio, en Linux, con la clave del gestor:

```bash
export MENTOX_AZURE_SUBSCRIPTION_ID="<suscripción>"
export MENTOX_AZURE_RESOURCE_GROUP=rg-mentox-dev
export MENTOX_AZURE_LOCATION=eastus
export MENTOX_CONTAINERAPPS_ENVIRONMENT=cae-mentoxp2-demo-wp
export MENTOX_CONTAINERAPPS_ENVIRONMENT_RESOURCE_GROUP=rg-mentox-analytics
export MENTOX_ACCEPT_MODEL_LICENSES=1
export MENTOX_MODEL_API_KEY="<clave-del-gestor>"
bash infra/azure/run-messi-roboflow.sh status
```

## Entorno verificado

| Componente | Versión |
|---|---|
| Azure CLI | 2.91.0, extensión `containerapp` 1.3.0b5 |
| Docker | Cliente 28.5.2, Docker Desktop 29.8.2 |
| Python | 3.12.16 |
| uv | 0.9.5 |
| ffmpeg | 5.1.9 |
| Imágenes | `roboflow-suite:4c8d1f3f4def`, `messi-generator:714303d55a39`, `roboflow-precomputed-replay:41fe7948fd62`, `soccernet-teamspotting:a69708c66769` |

## Limitaciones

- El modelo de campo casi no detecta nada en el render MESSI clean; está
  entrenado con transmisiones de televisión.
- Las capturas del saque inicial y del segundo tiempo pueden recibir 409.
- La huella no rechaza con seguridad un render MESSI ajeno al catálogo.
- El registro `k` corresponde al fotograma en `k + 0.5` s por el filtro `fps`
  de ffmpeg; `source_video_time_ms` lo etiqueta como `k` segundos.
- Las capturas se simularon con ffmpeg y JPEG 0.82. Falta comprobarlas con el
  navegador de la demo.
- Las respuestas son detecciones precalculadas, no inferencia en tiempo real.
- TeamSpotting no superó 0.3 de confianza en ninguna predicción sobre el render
  MESSI; el modelo está entrenado con transmisiones reales.
- Con mínimo cero, cada arranque de la API enciende la GPU de TeamSpotting unos
  minutos.

## Dependencias y siguientes pasos

- Desplegar la demo con `deploy-analytics.ps1` para aplicar el vídeo, los
  endpoints y las claves nuevas.
- Recorrer el estadio en el navegador: preparación, Play, Pause, Seek y Restart.
