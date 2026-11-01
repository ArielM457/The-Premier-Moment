# Generador MESSI para The Prime Moment

Este paquete ejecuta MESSI en una GPU T4 como un Azure Container Apps Job. Genera
30 partidos sintéticos comprimidos, sube cada MP4 y sus datos de repetición a Azure
Blob Storage y termina. No mantiene una API ni una réplica encendida.

## Alcance predeterminado

- 30 vídeos de 180 segundos.
- Partido completo comprimido, con descanso en la mitad del vídeo.
- Renderizado `light` a 15 FPS.
- Simulación a 15 Hz. Ambos valores deben coincidir para evitar que MESSI conserve
  todos los subpasos físicos del lote durante el `lax.scan` de JAX.
- Tracking persistido cada 15 pasos, aproximadamente una muestra por segundo.
- MESSI fijado al commit `b04b15c59d36c1e4f44e02d0886b2d0d7261f689`.
- Estilos `balanced`, `tiki_taka` y `long_ball` combinados entre los partidos.

El modo se puede cambiar con `MENTOX_RENDER_MODE=rich` o
`MENTOX_RENDER_MODE=clean`. `light` genera una vista táctica rápida de 672 × 448;
`rich` genera una vista detallada de 1920 × 1080 con todos los paneles técnicos;
`clean` usa esa misma vista detallada, pero conserva únicamente el partido,
los dorsales, el balón, el marcador y el reloj. En `clean` se ocultan el panel
`MATCH EVENTS`, la minimapa, los paneles tácticos, la línea de fuera de juego,
las bancas y las barras de energía que cubrían parcialmente los dorsales.
También se ocultan los puntos dinámicos de la minimapa; no se modifica ningún
evento ni dato de seguimiento.

Los eventos no se eliminan: continúan disponibles en `events.jsonl`, mientras
que las posiciones siguen en `tracking.jsonl`. De esta manera, la interfaz de
The Prime Moment puede mostrar la información fuera del video y sin duplicarla.

Ejemplo de una prueba corta antes de producir un lote:

```bash
export MENTOX_IMAGE_BUILD_MODE=local
export MENTOX_MATCH_COUNT=1
export MENTOX_MATCH_SECONDS=10
export MENTOX_RENDER_MODE=clean
export MENTOX_BATCH_ID="messi-preflight-clean-hud"
export MENTOX_START_JOB=1
bash infra/azure/deploy-messi-generator.sh
```

El parche se aplica sobre la revisión fijada de MESSI durante la construcción.
Si el código externo cambia y el parche deja de coincidir, la imagen falla en
`git apply --check` en lugar de producir videos con una interfaz inesperada.
El parche `clean-hud` se recuperó del commit de integración
`1f6e8dd5f72520923089a9dc727a80d946244c84`.

Para la demo de tres vídeos con Roboflow precalculado use
`MENTOX_RENDER_MODE=clean` y `MENTOX_MATCH_COUNT=3`. El flujo completo está en
[Ejecutar MESSI clean y Roboflow](../../docs/persona-1-datos-y-vision/ejecutar-lote-messi-roboflow.md).

No son 90 minutos de vídeo real. Cada archivo representa un partido completo en
una reproducción táctica comprimida de tres minutos. Generar 30 vídeos de 90
minutos se admite cambiando `MENTOX_MATCH_SECONDS=5400`, pero multiplicaría el
tiempo de renderizado, el almacenamiento y la transferencia.

## Artefactos

```text
synthetic-videos/
└── messi/<batch-id>/
    ├── batch-manifest.json
    ├── messi-001/
    │   ├── match.mp4
    │   ├── events.jsonl
    │   ├── tracking.jsonl
    │   ├── metadata.jsonl
    │   └── manifest.json
    └── messi-030/
```

Los contenedores de Storage permanecen privados. La aplicación debe solicitar al
backend una URL SAS de lectura corta; la credencial de Storage nunca se entrega al
navegador.

## Licencia y procedencia

MESSI declara Apache-2.0. Este contenedor conserva el commit, la semilla y los
hashes de cada artefacto. The Prime Moment utiliza únicamente los partidos
sintéticos generados; no incorpora ni redistribuye vídeo real de la Premier League.

## Ejecución

La creación del Job está documentada en:

```bash
bash infra/azure/deploy-messi-generator.sh
```

El script no inicia la generación automáticamente salvo que se configure
`MENTOX_START_JOB=1`. Esto permite revisar el Job antes de comenzar a consumir GPU.

Antes del lote completo se debe ejecutar una prueba corta con una semilla y un
`batch_id` independientes. Solo se inicia el lote de 30 cuando esa ejecución
termina en `Succeeded` y publica sus cinco artefactos.

Cuando la ejecución termine y se comprueben los 30 manifiestos, se puede eliminar
solamente el Job:

```bash
export MENTOX_CONFIRM_DELETE_JOB=1
bash infra/azure/delete-messi-generator-job.sh
```

Los vídeos permanecen en Blob Storage. La identidad, ACR y el entorno compartido
no se eliminan porque otros servicios de The Prime Moment pueden utilizarlos.
