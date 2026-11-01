# Despliegue en Azure y datos ficticios en Supabase

La guía para que cualquier integrante cree el entorno está en [despliegue en Azure paso a paso](../14-despliegue-en-azure.md). Este documento detalla los recursos y las decisiones.

Esta guía deja la analítica funcionando en la nube con datos guardados, en lugar de calcularla con adaptadores provisionales en memoria. Un solo script despliega todos los servicios de la analítica en Azure, y otro carga datos ficticios en Supabase.

- **Estado:** desplegado y verificado el 25 de octubre de 2026, en Azure for Students (`eastus2`), el entorno `cae-mentoxp2-demo-wp` sigue activo, la API lee los 3 partidos y su seguimiento desde Supabase, y la interfaz, el análisis de momentos y la previa responden. Flujo continuo verificado el 25 de octubre de 2026: el trabajo `replay` publicó en `match-events` los 178 eventos del partido de analítica a 8× (como `synthetic-analytics-001-live-20261026003858`). El procesador los aplicó todos a tiempo, con un transporte medio de 51 ms (p95 71 ms) y un procesamiento medio de 27 ms (p95 35 ms). Propuso momentos en 19 eventos y, 30 s después del último, guardó el registro `run-c57436ad-…` con 7 archivos en Blob y en Supabase.
  - La vista previa y la fase 1 salieron bien, y las imágenes están en el registro.
  - La primera fase 2 falló porque Azure creó el entorno en modo Express, que no admite trabajos.
  - La plantilla ya pide el modo `WorkloadProfiles`, y las dos fases validan contra la suscripción.
- **Fecha:** 18 de octubre de 2026.
- **Decisión de Persona 2 a confirmar con el equipo:** Supabase guarda los partidos ficticios y los resultados de la analítica. No reemplaza a Event Hubs ni a Blob Storage (decisión 10). Supabase no es un servicio de Azure; si el jurado exige todo en Azure, el mismo esquema funciona en Azure Database for PostgreSQL, porque es PostgreSQL estándar.

## Qué se despliega

```text
                    ┌───────────────────── Azure (un grupo de recursos) ─────────────────────┐
 Navegador ──────►  │  web (nginx) ──/api──► api (FastAPI)                                    │
                    │                          │  ANALYTICS_ENGINE=persona2                   │
                    │                          │  MATCH_SOURCE=supabase ──────────────┐       │
                    │                                                                │       │
                    │  replay (trabajo manual) ──► Event Hubs match-events           │       │
                    │                                   │                            │       │
                    │                                   ▼                            │       │
                    │                         worker (procesador continuo)           │       │
                    │                          │            │                        │       │
                    │                          ▼            ▼                        │       │
                    │          Event Hubs match-insights   Blob analytics            │       │
                    └──────────────────────────────────────────────────────────────── │ ──────┘
                                                                                     ▼
                                       Supabase (PostgreSQL): esquema match_analytics
                                       partidos, eventos, seguimiento simulado y análisis
```

| Recurso | Para qué | Plantilla |
|---|---|---|
| Event Hubs Standard: `match-events` y `match-insights` | Transportar eventos y salidas de la analítica | `main.bicep` y `analytics.bicep` (sin cambios) |
| Storage: `matches`, `analytics`, `models` y los de Persona 1 | Guardar partidos y registros de análisis | `main.bicep` y `analytics.bicep` |
| Log Analytics | Registros de las aplicaciones, con tope de 0,1 GB al día | `analytics-platform.bicep` |
| Azure Container Registry Basic | Guardar las dos imágenes | `analytics-platform.bicep` |
| Identidad administrada | Leer el registro, publicar y consumir en Event Hubs y escribir en Blob, sin claves | `analytics-platform.bicep` y `modules/analytics-roles.bicep` |
| Entorno de Container Apps en modo `WorkloadProfiles`, solo con el perfil `Consumption` (pago por uso) | Ejecutar las aplicaciones y el trabajo | `analytics-platform.bicep` |
| `api` | API de Persona 4 con la analítica real de Persona 2; pública, con `/docs` | `analytics-platform.bicep` |
| `web` | Interfaz de Persona 4 servida por nginx, que reenvía `/api` a la API | `analytics-platform.bicep` |
| `worker` | Procesador continuo: `match-events` → `match-insights`, Blob y Supabase; apagado por defecto | `analytics-platform.bicep` |
| `replay` | Trabajo manual que repite un partido de Supabase en `match-events` | `analytics-platform.bicep` |

La API y la interfaz se apagan solas sin tráfico (cero réplicas). La primera visita tarda unos segundos en arrancar.

Desde 2026, si no se indica el modo, Azure crea los entornos en modo Express. Ese modo es solo para apps web: no admite trabajos y apaga lo que no recibe HTTP. Por eso la plantilla usa `environmentMode: 'WorkloadProfiles'` con la API `2026-07-01`. El modo no se puede cambiar después.

El entorno se llama `cae-<prefijo>-<entorno>-wp`. Azure for Students permite un solo entorno por región, así que el script reemplaza el anterior, siempre después de pedir confirmación. Las aplicaciones no guardan datos propios y se vuelven a crear. Lo reemplaza en estos casos:

- Tiene el nombre anterior (sin `-wp`).
- Está en modo Express.
- Azure suspendió su cómputo (`ManagedClusterSuspended`).
- Se pidió con `-RecreateEnvironment`.

Al terminar, el script espera 90 s y comprueba que el entorno siga activo.

## Costo estimado con Azure for Students

Precios aproximados de pago por uso en `eastus2`. Confírmelos en la calculadora de precios de Azure antes de desplegar.

| Recurso | Costo aproximado |
|---|---|
| Event Hubs Standard, 1 unidad | 0,03 USD por hora, unos 22 USD al mes. Es el mayor costo y corre aunque nadie lo use. Basic no sirve porque solo admite un grupo de consumidores. |
| Container Registry Basic | Unos 5 USD al mes |
| Container Apps | La cuota gratuita mensual (180 000 vCPU-segundo y 360 000 GiB-segundo) cubre la API y la interfaz apagadas sin tráfico. El procesador encendido todo el mes cuesta entre 4 y 14 USD. |
| Log Analytics y Storage | Céntimos con este volumen |
| Supabase (plan gratuito) | 0 USD. Pausa el proyecto tras una semana sin uso. |

Con el procesador apagado, el gasto es de alrededor de 1 USD al día. Con 100 USD de crédito conviene desplegar pocos días antes de la presentación y borrar el grupo después con `remove-analytics.ps1`.

## Paso 1. Crear la base en Supabase

Esto lo hace la persona dueña de la cuenta. El script nunca crea cuentas ni maneja contraseñas fuera de la variable de entorno.

1. Cree un proyecto gratuito en [supabase.com](https://supabase.com). Elija una región cercana a la de Azure, por ejemplo `East US (North Virginia)` para `eastus2`. Guarde la contraseña de la base.
2. En **Connect**, copie la cadena del **Session pooler**: `postgresql://postgres.<ref>:<contraseña>@aws-0-<región>.pooler.supabase.com:5432/postgres`. No use la conexión directa (`db.<ref>.supabase.co`): solo funciona por IPv6 y Container Apps sale por IPv4.
3. Guarde la cadena solo en la variable de la terminal. No la escriba en archivos del repositorio.

```powershell
$env:SUPABASE_DB_URL = Read-Host 'Cadena del Session pooler de Supabase'
```

## Paso 2. Cargar los datos ficticios

Instale el backend con el extra `db` y ejecute la carga desde la raíz del repositorio:

```powershell
python -m pip install -e "apps/backend[dev,db]"
```

```powershell
python apps/backend/scripts/supabase_seed.py --schema
```

`--schema` aplica `infra/supabase/migrations/20261018120000_match_analytics.sql`, que se puede ejecutar varias veces. Sin conexión, `--dry-run` genera todo y solo muestra los conteos.

| Tabla o vista (esquema `match_analytics`) | Contenido | Origen |
|---|---|---|
| `matches`, `match_players` | 2 partidos: el corto de aceptación (10 eventos) y el de dos tiempos (178 eventos) | Generador de Persona 1 y escenario de Persona 2 |
| `match_events` | `MatchEvent 1.0`, en orden de llegada | Igual |
| `tracking_observations` | 49 222 `VisualTrackObservation` a 5 por segundo, origen `simulated_fixture` | `tests/tracking_mock.py` con el formato de Persona 1 |
| `visual_identities` | `ResolvedVisualIdentity` confirmadas con el resolutor de Persona 1 | Igual |
| `analytics_runs`, `analytics_run_files` | El registro del procesador continuo: los mismos archivos que guarda en Blob, más las cifras y avisos de seguimiento | Motor de Persona 2 |
| Vistas `attention_decisions`, `candidate_proposals`, `final_metrics` y `tracking_alerts` | Las mismas salidas, en filas para consultarlas | Vistas sobre `analytics_run_files` |

Volver a ejecutar la carga reemplaza esos partidos y borra sus análisis anteriores. En Supabase, el editor de tablas muestra el esquema `match_analytics` en el selector de esquemas. Una consulta de ejemplo para el editor SQL:

```sql
select kind, count(*) from match_analytics.attention_decisions
where match_id = 'synthetic-analytics-001' and outcome = 'emitted'
group by kind order by kind;
```

El esquema no se expone en la API de datos de Supabase, y las tablas tienen RLS activado sin políticas. Solo el backend lo lee, con la cadena de conexión.

## Paso 3. Desplegar en Azure

Requisitos:

- Azure CLI: `winget install -e --id Microsoft.AzureCLI`.
- Docker Desktop encendido.
- Una sesión con `az login`.

El script comprueba cada uno y, si falta Bicep, lo instala.

Revise primero qué se crearía:

```powershell
./infra/azure/deploy-analytics.ps1 -ResourceGroup rg-mentox-analytics -Location eastus2 -WhatIf
```

Despliegue todo y cargue los datos en el mismo paso:

```powershell
./infra/azure/deploy-analytics.ps1 -ResourceGroup rg-mentox-analytics -Location eastus2 -SeedDatabase
```

El script:

1. Comprueba Azure CLI, Docker, la sesión y que la región esté permitida. Azure for Students limita las regiones.
2. Registra los proveedores de recursos y crea el grupo si no existe.
3. **Fase 1:** despliega Event Hubs, Storage, Log Analytics, el registro, la identidad con sus roles y el entorno de Container Apps.
4. Construye y publica las imágenes `match-intelligence-api` y `match-intelligence-web` con Docker. Con `-UseAcrBuild`, las construye en Azure, aunque algunas suscripciones de estudiante no permiten ACR Tasks.
5. Con `-SeedDatabase`, carga el esquema y los datos ficticios.
6. **Fase 2:** despliega la API, la interfaz, el procesador y el trabajo `replay`. La cadena de Supabase viaja en un archivo temporal de una carpeta privada (700 y 600 en Linux y macOS; en Windows, la carpeta temporal del usuario). El archivo se borra al terminar y la cadena queda como secreto de Container Apps.
7. Espera a que la API responda y muestra las direcciones y los comandos útiles.

| Opción | Efecto |
|---|---|
| `-Prefix` | Prefijo de 3 a 9 caracteres para los nombres (por defecto `mentoxp2`) |
| `-SkipWeb` | No despliega la interfaz |
| `-WorkerOn` | Deja encendido el procesador continuo |
| `-ApiAlwaysOn` | Mantiene una réplica de la API para evitar el arranque en frío el día de la demo |
| `-ReplayMatchId`, `-ReplaySpeed` | Partido y velocidad del trabajo `replay` |
| `-SupabaseUrl` | URL del proyecto de Supabase con la que la API valida las sesiones de los editores. Por defecto usa `$env:SUPABASE_URL` o `SUPABASE_URL` de `apps/backend/.env`; sin ella, la revisión editorial responde `503` |
| `-VisionVideoBlobName` | Ruta del vídeo MESSI en el contenedor `authorized-videos` del Storage del despliegue. Por defecto, `messi/messi-clean-2x180s-20261026/messi-001/match.mp4`; vacía, la API muestra la cancha sintética |
| `-EnvironmentLocation` | Región del entorno de Container Apps y sus aplicaciones; por defecto, `-Location`. Una suscripción de Azure for Students admite un solo entorno, así que para el estadio con GPU T4 debe ser una región con T4, como `eastus` (`eastus2` no tiene). Si el entorno existe en otra región, el script lo reemplaza después de confirmar |
| `-GpuWorkloadProfile` | Declara el perfil GPU T4 (`NC8as-T4`) que agregan los scripts de MESSI y Roboflow. Úselo en cada despliegue posterior a esos scripts; sin él, el despliegue quitaría la GPU del entorno |
| `-InfraOnly` | Solo la fase 1 |
| `-Yes` | No pide confirmación |

Si no hay cadena de Supabase, la API usa los partidos sintéticos en memoria y no se crea el trabajo `replay`.

### Estadio MESSI en Azure

La pestaña Partido muestra el vídeo MESSI cuando la API puede leer el vídeo y sus cuatro archivos compañeros: `manifest.json`, `events.jsonl`, `tracking.jsonl` y `metadata.jsonl`. La API los lee de su propio Storage con su identidad administrada; no puede leer el Blob de Damon porque está en otro tenant. Antes del primer despliegue con estadio, copie los cinco archivos a `authorized-videos`, en la misma ruta. Su cuenta necesita el rol Storage Blob Data Contributor sobre ese Storage:

```bash
PREFIX=messi/messi-clean-2x180s-20261026/messi-001
for f in manifest.json match.mp4 events.jsonl tracking.jsonl metadata.jsonl; do
  az storage blob download --account-name stdamonhxwjzbiyupwqc --container-name synthetic-videos --name "$PREFIX/$f" --file "$f" --auth-mode login --subscription <suscripción-de-Damon>
  az storage blob upload --account-name <storage-del-despliegue> --container-name authorized-videos --name "$PREFIX/$f" --file "$f" --auth-mode login --subscription <su-suscripción>
done
```

El estadio también exige Roboflow Suite y SoccerNet TeamSpotting, los servicios de Damon. El script toma `ROBOFLOW_SUITE_ENDPOINT`, `ROBOFLOW_SUITE_API_KEY`, `SOCCERNET_ENDPOINT` y `SOCCERNET_API_KEY` de la terminal o de `apps/backend/.env`. Guarda las claves como secretos de Container Apps y nunca las muestra. Sin esos cuatro valores, el vídeo no se reproduce. Cada arranque de la API vuelve a analizar el vídeo con TeamSpotting: tarda unos 3,5 minutos y usa la GPU de Damon. Con `-ApiAlwaysOn`, la API no se apaga y el análisis no se repite.

Con el estadio activo, la API descarga esos archivos al arrancar. El reproductor solo acepta avances de la reproducción vigente que no superen el tiempo transcurrido, y solo el partido con vídeo puede preparar los modelos.

## Paso 4. Mostrar el flujo en directo

1. Abra la interfaz (`webUrl`) o la documentación de la API (`apiUrl/docs`). El estado y los momentos ya salen del motor de Persona 2 con los partidos de Supabase. Las velocidades y distancias salen del seguimiento simulado.
2. Encienda el procesador:

   ```powershell
   az containerapp update -n ca-mentoxp2-worker -g rg-mentox-analytics --min-replicas 1 --max-replicas 1
   ```

3. Repita un partido en `match-events`. El trabajo lo copia como `<partido>-live-<hora>` y publica sus eventos a 8 veces la velocidad del vídeo:

   ```powershell
   az containerapp job start -n caj-mentoxp2-replay -g rg-mentox-analytics
   ```

4. Siga el procesamiento:

   ```powershell
   az containerapp logs show -n ca-mentoxp2-worker -g rg-mentox-analytics --follow
   ```

5. Treinta segundos después del último evento, el registro del análisis aparece en Blob `analytics` y en Supabase:

   ```sql
   select run_id, match_id, produced_by, event_count, candidate_count
   from match_analytics.analytics_runs where produced_by = 'stream-worker'
   order by created_at desc;
   ```

6. Apague el procesador al terminar con `--min-replicas 0`.

## Paso 5. Apagar o borrar

```powershell
./infra/azure/remove-analytics.ps1 -ResourceGroup rg-mentox-analytics -StopOnly
```

Deja las aplicaciones en cero réplicas. Event Hubs y el registro siguen cobrando.

```powershell
./infra/azure/remove-analytics.ps1 -ResourceGroup rg-mentox-analytics
```

Borra el grupo completo después de escribir su nombre. No se puede deshacer. Supabase no se toca.

## Ejecutar la API en local contra Supabase

```powershell
$env:MATCH_SOURCE = 'supabase'
$env:ANALYTICS_ENGINE = 'persona2'
uvicorn match_intelligence.main:app --app-dir apps/backend/src --reload
```

| Variable | Valores | Por defecto |
|---|---|---|
| `ANALYTICS_ENGINE` | `provisional` (Persona 4) o `persona2` | `provisional`, para no cambiar las pruebas de Persona 4 |
| `MATCH_SOURCE` | `synthetic` (generadores en memoria) o `supabase` | `synthetic` |
| `SUPABASE_DB_URL` | Cadena del Session pooler | Sin valor |
| `SUPABASE_URL` | URL del proyecto; la revisión editorial valida con ella las sesiones de los editores | Sin valor: la revisión responde `503` |

La API lee los partidos al arrancar. Si vuelve a cargar los datos, reinicie la API. En Azure, cree una revisión nueva con `az containerapp update -n ca-mentoxp2-api -g rg-mentox-analytics --revision-suffix r<hora>`.

## Cambios en el código

| Archivo | Cambio |
|---|---|
| `application/analytics/presentation.py` | `PresentationAnalytics`: el `AnalyticsPort` de Persona 4 calculado con `MatchAnalytics`. Entrega los contratos de `domain/presentation.py`, que son un subconjunto de los de Persona 2. |
| `adapters/http/registry.py` | Elige motor y origen de los partidos con `ANALYTICS_ENGINE` y `MATCH_SOURCE`; añade `load_match`. Sin variables, se comporta igual que antes. |
| `adapters/provisional/narrative.py` | Titulares en español e inglés para los momentos que solo propone Persona 2 (por ejemplo, `control_shift` o `player_milestone`). Antes mostraba el nombre técnico. |
| `adapters/storage/supabase_store.py` | Lectura y escritura de los contratos en PostgreSQL; adaptadores asíncronos para el procesador |
| `adapters/storage/analytics_sinks.py` | Metadatos del primer origen que los tenga y escritura en varios destinos |
| `adapters/sources/analytics_scenarios.py` | Vuelve a `src`: la API de Persona 4 lo carga como segundo partido desde que se unió con `main` |
| `scripts/analytics_stream_worker.py` | Con `SUPABASE_DB_URL`, también lee metadatos y guarda registros en Supabase |
| `scripts/replay_match_to_event_hubs.py` | Repite un partido de Supabase en `match-events` |
| `scripts/supabase_seed.py` y `tests/supabase_seed_data.py` | Carga de los datos ficticios |
| `apps/backend/Dockerfile`, `apps/frontend/Dockerfile`, `apps/frontend/nginx/` | Imágenes de la API y de la interfaz. La de la API se construye desde la raíz y copia los resultados de visión de Persona 1 |
| `.dockerignore` (raíz) | Lo único que se envía al construir desde la raíz: el backend, los tres resultados de visión y el diagnóstico de `compose.integration.yml` |
| `infra/azure/analytics-platform.bicep`, `modules/analytics-roles.bicep` | Plataforma completa |
| `infra/azure/deploy-analytics.ps1`, `remove-analytics.ps1` | Despliegue y borrado |
| `infra/supabase/migrations/` | Esquema `match_analytics` |

## Qué sigue siendo simulado

| Parte | Situación |
|---|---|
| Partidos y eventos | Sintéticos, como exige el reto |
| Posiciones de jugadores y balón | Simuladas con el formato de Persona 1 (`simulated_fixture`), hasta tener observaciones reales de vídeo |
| xT, VAEP y xG | Desactivados hasta tener un modelo validado |
| Narración | La provisional de Persona 4, hasta integrar a Persona 3. Sus contratos todavía rechazan las salidas de Persona 2. |

## Limitaciones

- El 19 de octubre de 2026, Azure suspendió el cómputo del primer entorno `WorkloadProfiles` un minuto después de arrancar (`ManagedClusterSuspended`, «unknown reasons»). La suscripción estaba habilitada, con cuota de sobra y sin incidentes. Se había creado con el mismo nombre que el entorno Express borrado dos minutos antes; por eso el entorno nuevo usa otro nombre. Si se repite, la alternativa es dejar la API y la interfaz en un entorno Express y correr el procesador y la repetición desde un equipo del equipo durante la demo.
- La cadena de Supabase queda como secreto de Container Apps. Guardarla en Azure Key Vault evitaría que toque el disco local, pero añade otro recurso; queda como mejora.
- La API usa una sola réplica: guarda en memoria la revisión editorial y los reportes de Persona 4.
- La API carga los partidos al arrancar. Con los dos partidos, el arranque tarda unos segundos y un estado con seguimiento, entre 0,1 y 0,15 s en este equipo.
- La entrada de Container Apps corta las peticiones HTTP largas (240 s según su documentación). El canal en directo de la interfaz puede cerrarse en partidos largos; hay que comprobar en el primer despliegue cómo se reconecta.
- El procesador guarda el registro de un partido después de 30 s sin eventos. Si se reinicia antes, ese registro se pierde, pero se puede repetir el partido.
- Los nombres de las aplicaciones en los comandos de ejemplo usan el prefijo `mentoxp2`. Con otro prefijo, el script muestra los nombres correctos.
