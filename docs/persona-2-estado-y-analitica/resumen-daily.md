# Resumen para el daily · Persona 2 (estado y analítica)

Actualizado el 26 de octubre de 2026. Rama `persona-2/estado-analitica`, subida a GitHub.

## En un minuto

- **Hecho:** la analítica ya funciona en Azure con datos guardados.
  - La API de The Prime Moment usa el motor real de Persona 2, no la analítica provisional.
  - Lee los partidos y el seguimiento desde una base en Supabase.
  - La pestaña Resumen explica cada momento con cifras medidas.
  - La tarjeta «Visión IA», dentro de la pestaña Partido, une nuestro trabajo con el de Persona 1. En Azure muestra los resultados guardados de sus modelos y aclara que son de otro vídeo. Con su vídeo y su GPU, muestra la captura en vivo.
  - Pasan 438 pruebas. Las 10 que fallan ya fallaban en `main` y son de Persona 1 (ver más abajo).
- **Desde el último daily:**
  - Base de datos con partidos ficticios en Supabase.
  - Script que despliega todo en Azure.
  - La API usa la analítica real.
  - Unión con `main`, con `develop` y dos veces con `integration/modelos-frontend-20261025` (Persona 1). La segunda trajo la captura de visión en vivo y los modelos en GPU.
  - Dos reglas nuevas: situaciones del partido y lecturas «¿qué habría pasado si…?».
  - Pestaña Resumen con datos.
  - Guía para que cualquiera del equipo cree el entorno.
  - Revisión general del frontend y el backend, con siete correcciones.
  - Centro del partido pulido: asistente con controles claros, campos y barras con el tema, y modo claro completo.
  - Revisión de seguridad con tres correcciones: límite de tamaño en la captura, vídeo por partes y contraseñas ocultas en los registros.
- **Demo en Azure:**
  - Interfaz: <https://ca-mentoxp2-web.yellowbush-4175ef32.eastus.azurecontainerapps.io>
  - API: <https://ca-mentoxp2-api.yellowbush-4175ef32.eastus.azurecontainerapps.io/docs>
  - Versión desplegada: API `bdc42b4` e interfaz `79c1b79`.
  - El tablero local sigue en [`demo/tablero.html`](demo/tablero.html).
- **Flujo continuo probado en Azure:** 178 eventos por Event Hubs, todos aplicados a tiempo, con 51 ms de transporte medio y 27 ms de procesamiento. El registro quedó en Blob y en Supabase.
- **Siguiente:**
  - Acordar los contratos con Persona 3.
  - Unir la rama `uidesign` de Eliana cuando la actualice desde `develop` o desde la nuestra.
  - Decidir en equipo los cuatro puntos abiertos de la revisión general.
  - Abrir el PR cuando el equipo lo decida.
- **Bloqueos y avisos:**
  - Los contratos de Persona 3 todavía rechazan las salidas del motor.
  - La tabla de eventos de Supabase que llegó con `main` mezcla eventos de partidos distintos.
  - Persona 1 debe revisar los cambios hechos en sus archivos al unir (ver «Detalle de los avisos para Persona 1»).
  - `uidesign` parte de `main` y choca con 8 archivos de la interfaz; unirla hoy rehace parte de su diseño sin ella.

## Novedades desde el último daily

### Base de datos en Supabase

| Qué | Detalle |
|---|---|
| Esquema | `match_analytics`, separado del resto y sin exponer en la API pública de Supabase; RLS activo |
| Datos ficticios | 3 partidos (aceptación, analítica de 22 jugadores y partido en vivo de Persona 4), sus eventos, 92 982 posiciones simuladas con el formato de Persona 1 y el análisis de cada partido |
| Carga | `supabase_seed.py --schema`: crea las tablas, aplica las migraciones y reemplaza los partidos. Se puede repetir |
| Consulta | Vistas listas para SQL: decisiones de atención, métricas finales, propuestas de momentos y avisos de seguimiento |

La base de datos es una decisión de Persona 2, todavía por confirmar con el equipo. No reemplaza a Event Hubs ni a Blob Storage. Es PostgreSQL estándar, así que también funcionaría en Azure Database for PostgreSQL.

### Despliegue en Azure

`./infra/azure/deploy-analytics.ps1` crea todo en un grupo de recursos y en dos fases, con la construcción de las imágenes entre ambas.

| Recurso | Para qué |
|---|---|
| Event Hubs (`match-events`, `match-insights`) y Storage | Transporte de eventos y salidas; registros de cada análisis |
| Container Registry e identidad administrada | Imágenes y permisos sin claves |
| Container Apps en modo `WorkloadProfiles` | API, interfaz, procesador continuo y trabajo que repite partidos de Supabase |
| Log Analytics | Registros, con tope de 0,1 GB al día |

- **Costo real hasta hoy:** 6,51 USD de los 100 de Azure for Students. La previsión para octubre es 12,49 USD. Casi todo es Event Hubs, alrededor de 1 USD al día.
- **Al terminar la demo** hay que borrar el grupo con `remove-analytics.ps1`.

Llegar hasta aquí costó tres intentos. Quedaron resueltos en el script y documentados:

1. **Modo Express.** Azure crea ahora los entornos en ese modo, que no admite trabajos. La plantilla pide `WorkloadProfiles` y el script recrea el entorno si hace falta.
2. **Suspensión.** Azure suspendió un entorno recreado con el mismo nombre (`ManagedClusterSuspended`). El entorno nuevo usa otro nombre, y el script comprueba 90 s después de desplegar que siga activo.
3. **Cadena solo IPv6.** Con la conexión directa de Supabase, Azure no alcanzaba la base. Ahora el script rechaza esa cadena antes de desplegar, y la API arranca con los partidos sintéticos si no alcanza la base.

### La API usa la analítica real

- `PresentationAnalytics` pone `MatchAnalytics` detrás del `AnalyticsPort` de Persona 4. Entrega sus mismos contratos.
- Dos variables eligen el modo:
  - `ANALYTICS_ENGINE=persona2` usa el motor real; sin ella, se mantiene el provisional para no romper las pruebas de Persona 4.
  - `MATCH_SOURCE=supabase` lee los partidos de la base.
- En Azure, la API comprobada lee los 3 partidos y el seguimiento de Supabase: el estado trae las velocidades de los 22 jugadores.

### Unión con `main`, `develop` y la integración de Persona 1

- **`main` trajo la integración de Persona 1:** visión, enrutamiento de eventos y su propia persistencia en Supabase (esquema `public`). No choca con la nuestra.
- **`develop` trajo la experiencia en vivo de Persona 4:**
  - partidos de 11 contra 11;
  - un partido en vivo con faltas, tarjetas, una lesión y reanudaciones;
  - la cancha con seguimiento;
  - la previa táctica.

  También cambió el contrato de eventos de Persona 1 (cinco tipos y tres campos nuevos) y partes de nuestra analítica.

Lo que adapté:

| Tema | Qué se hizo |
|---|---|
| Cancha en vivo | `develop` la construyó sobre el formato viejo de seguimiento. Ahora usa nuestro modelo y entrega el mismo JSON (`TrackingFrame v1`), sin cambios en la interfaz. La simulación de posiciones volvió a `src/` porque la API la usa al ejecutarse |
| Faltas, tarjetas y lesiones | Regla nueva `situation@1`. Ahora el motor real también las propone como momentos: la roja siempre, amarillas y lesión en todos los modos, faltas solo para el analista |
| Campos nuevos de los eventos | Migración nueva en Supabase para guardar receptor, situación y duración de la detención |
| Pestañas de la interfaz | Se conserva la estructura nueva de `develop`. La visión de Persona 1 tuvo primero su propia pestaña, «Visión IA», y después pasó a una tarjeta dentro de Partido (ver más abajo) |
| Imagen de Docker | Conserva la estructura del repositorio para que la previa táctica encuentre sus datos en Azure |

### Pestaña Resumen con analítica

Antes, el «resultado estimado» era el mismo texto para cualquier momento y la cancha usaba una formación fija. Ahora la ruta `/moments/{id}/analysis` entrega lo que sabe el motor y la pestaña lo muestra:

- **Por qué es un momento:** prioridad, umbral del perfil y cada motivo con sus puntos.
- **Datos medidos:** avance, duración, pases, distancia del remate… con unidades.
- **Cancha real:** las posiciones de ese instante, con los jugadores de la alternativa marcados.
- **¿Qué habría pasado si…? (`what_if@1`):** cada opción compara el instante real con una alternativa medida:
  - el pase un segundo antes: espacio del pasador y del receptor;
  - el remate un segundo antes: distancia, ángulo y espacio del rematador;
  - el apoyo hacia el compañero más libre: su espacio frente al del compañero más cercano;
  - el arquero 3 m más adelante: distancia al balón y a su línea de gol.

Si una opción no aplica, la pestaña lo dice («el momento no incluye un remate»). Las posiciones son simuladas y la pestaña lo avisa: compara espacios, no predice el resultado. Funciona con el motor real y con el provisional, y ya responde desde Azure.

### Unión con `integration/modelos-frontend-20261025`

Esta rama de Persona 1 une `develop` con su visión. También prepara el despliegue de sus modelos con GPU en Azure: Roboflow y SoccerNet, con las historias DV-US-30 y DV-US-31. No toca la analítica.

- **Ya está unida** a nuestra rama (commit `5d2b136`).
- **Conflictos:** hubo 2, en la interfaz, y se resolvieron con su solución. El panel de visión pasa a una pestaña propia, «Visión IA», en lugar de ir dentro de la pestaña Partido. Así deja de pedir datos de visión en la pestaña principal.
- **Resumen:** conserva el `matchId` con el que carga el análisis del momento.
- **Comprobación:** las pruebas dan el mismo resultado (413 pasan; las 10 que fallan son las de `main`). La interfaz compila y en local muestra las cinco pestañas sin errores.

Ahora nuestra rama contiene `main`, `develop` y esta integración; las demás ramas no tienen nada que falte en la nuestra.

### Pestaña «Visión IA» en local y en Azure

Decía «Visión no disponible» por tres motivos:

1. **Ruta de los archivos.** La API busca los resultados de los modelos en `experiments/…/output-real`, que solo existe en el equipo de Persona 1. Las copias están en `docs/mentox-modelos-20261023T045413Z/resultados`. En local basta con apuntar tres variables a esa carpeta.
2. **Finales de línea.** En Windows, Git cambiaba esos archivos y su huella SHA-256 dejaba de coincidir. Un `.gitattributes` lo evita.
3. **Imagen.** En Azure no estaban los archivos. Ahora la imagen de la API se construye desde la raíz del repositorio y trae los tres resultados (8,5 MB) con sus variables. El `.dockerignore` de la raíz solo deja pasar lo que usan las imágenes.

En Azure se actualizaron la API, la interfaz, el procesador y el trabajo `replay` a la imagen `78cf10c`. Solo cambió la imagen; la cadena de Supabase siguió como secreto. La API responde `ready`, con 16 324 detecciones de Roboflow, 127 acciones de SoccerNet y 12 candidatos de fusión, y sigue leyendo los 3 partidos de Supabase. La imagen no incluye el vídeo, que la pestaña no necesita.

### Revisión general del frontend y el backend

Se recorrieron las 42 rutas de la API con los dos motores y con identificadores reales: todas responden lo esperado, sin errores 500. También se recorrieron todas las pantallas en español y en inglés. Se corrigió:

- **Tipos de momento sin nombre.** Siete tipos de la analítica de Persona 2 aparecían con su nombre interno (por ejemplo, `fast_progression`). Ahora tienen nombre en los dos idiomas, y una prueba nueva avisa si falta alguno.
- **Botones dentro de botones.** La lista de momentos dibujaba a cada jugador como botón dentro de la tarjeta, que también es un botón. Ahora la cancha pequeña es solo una imagen.
- **Reloj de las estadísticas.** Mostraba el tiempo del vídeo en lugar del reloj del partido.
- **Números.** Las estadísticas y la visión usaban punto decimal en español («87.5%»). Ahora usan coma («87,5%»).
- **Visión IA.** Pedía el estado cada segundo y, pasado el segundo 30, mostraba ceros sin explicar. Ahora pide el estado una vez y avisa que los resultados cubren solo los primeros 30 s del vídeo analizado.
- **Textos internos.** «language:es · mode:casual» ahora se lee «Español · Aficionado», y dos mensajes de error ya siguen el idioma elegido.
- **Código sin uso.** Se quitaron 2 componentes de la interfaz, 3 funciones y 7 importaciones del backend.

Quedan para decidir en equipo:

- **Panel de retraso.** Persona 4 lo documenta, pero un cambio posterior lo quitó de la pantalla; la interfaz sigue midiendo el retraso sin mostrarlo.
- **Simulación oculta.** «Iniciar partido en vivo» también llama a `POST /simulation` y descarta el resultado. Los textos para mostrar colas, rutas y recortes destacados siguen sin uso, igual que las rutas de recortes.
- **Estado de los partidos por identificador.** La API marca «Final», «Próximo» o «En vivo» según el identificador. Así, el partido de analítica, el más completo, solo abre la previa.
- **Vocabulario de revisión.** La revisión editorial usa `approve`/`reject` y la de recortes `approved`/`rejected`.

### Centro del partido: visión, asistente y campos

- **Visión IA dentro de Partido.** Deja de ser una pestaña y pasa a una tarjeta bajo el campo, con la forma de los comentarios en vivo. Muestra la ventana de vídeo, cuántas detecciones, acciones y candidatos hay, y las últimas acciones de SoccerNet traducidas. Fuera de los 30 s analizados, da los totales del vídeo. Se mantiene porque es la única muestra de los modelos de Persona 1 en la demo, siempre marcada como experimental.
- **Asistente.** La flecha suelta entre el campo y el panel se reemplazó por dos controles con sentido: un interruptor «Asistente» junto a «Comentarios en vivo» y un botón para cerrar el panel en su cabecera. Al cerrarlo, el foco pasa al interruptor.
- **Campos y barras.** Todos los select comparten un estilo con los colores del tema; en Chrome y Edge, también la lista desplegable. Las barras de desplazamiento son finas y siguen el tema.
- **Modo claro.** Los comentarios en vivo, los interruptores y el select de velocidad seguían oscuros sobre fondo blanco. Ahora siguen el tema.

Ya está en Azure, junto con la revisión general: la API, la interfaz, el procesador y el trabajo `replay` usan la imagen `5fd326b`. Solo cambió la imagen. La visión responde `ready`, la API sigue leyendo los 3 partidos de Supabase y las revisiones nuevas están sanas.

### Segunda unión con `integration/modelos-frontend-20261025` (26 de octubre)

Persona 1 subió un commit grande: modelos en GPU de Azure, captura de visión en vivo, un worker de eventos importantes y el generador MESSI.

- **Modelos en Azure.** Según su evidencia (DV-US-31), la suite de Roboflow y TeamSpotting quedaron desplegadas en una GPU T4 de su suscripción, no de la nuestra.
- **Captura en vivo (DV-US-34).** Con un vídeo de Blob Storage, el navegador envía un fotograma por segundo y Roboflow devuelve las detecciones por Event Hubs. Solo se activa con su configuración; nuestro despliegue sigue con la cancha sintética.
- **Conflictos:** 4 archivos de la interfaz. Su panel de visión y nuestra tarjeta iban en la misma dirección, así que quedaron unidos. Con vídeo, la tarjeta muestra la captura en vivo (fotogramas, detecciones y resúmenes como «22 jugadores · 2 árbitros · 1 balón»). Sin vídeo, muestra los resultados guardados y dice que son de otro vídeo, no de este partido.
- **Arreglos que hizo falta hacer:**
  - Su adaptador de GameState usaba `TrackedKind.REFEREE`, que ya no existía en nuestra rama. Se añadió como valor nuevo, sin quitar `UNASSIGNED`.
  - En inglés, los textos de visión estaban dentro de `editorial`, no de `match`. Con la tarjeta, la pantalla del partido se rompía en inglés; la versión `5fd326b` de Azure tenía ese error, ya corregido. Ahora `npm run lint` también comprueba que español e inglés tengan las mismas claves.
  - Faltaban 3 rutas nuevas en la colección de Postman.
- **Comprobación:** pasan 429 pruebas; fallan las mismas 10 de Persona 1 de siempre. Todas las rutas responden con los dos motores, y la tarjeta funciona en español y en inglés sin errores.
- **En Azure:** la API, la interfaz, el procesador y el trabajo `replay` usan la imagen `79c1b79` (con esta unión y el permiso acotado del generador MESSI). La visión responde `ready`, la API sigue leyendo los 3 partidos de Supabase y las revisiones nuevas están sanas. Sin la configuración de Persona 1, la captura en vivo queda apagada: `models/prepare` explica qué variables faltan.
- **Revisión de seguridad.** Después del push se corrigieron tres puntos:
  - La captura de fotogramas leía el cuerpo completo antes de comprobar la pausa y el límite de 8 MiB. Ahora lo comprueba antes y corta al pasar el límite.
  - El vídeo de Blob se cargaba entero en memoria. Ahora se envía por partes de 4 MiB.
  - El aviso de Supabase podía escribir la contraseña de una cadena mal formada en los registros. Ahora la oculta.
  - Las dos primeras están en archivos de Persona 1. La API de Azure usa la imagen `bdc42b4`: un fotograma de 9 MiB en pausa se rechaza en medio segundo con 409.

### Guía para el equipo

[`docs/14-despliegue-en-azure.md`](../14-despliegue-en-azure.md) explica, paso a paso:

- si conviene un despliegue compartido o uno por persona (se recomienda uno compartido);
- qué instalar;
- cómo crear la base y desplegar;
- cómo mostrar el flujo en directo;
- cómo cuidar los créditos;
- cómo manejar secretos;
- una tabla con todos los errores que aparecieron y su solución.

## Qué hace el motor con cada evento

```text
MatchEvent 1.0
  → estado: marcador, reloj, período y posesión por tramos
  → estadísticas: tiros, pases, precisión, recuperaciones, presión, pases progresivos…
  → jugadas: agrupa recuperación, pases y tiro en una sola secuencia
  → reglas: progresión rápida, recuperación y tiro, presión sostenida, hitos de jugador,
            cambio de control, fase de caos y situaciones (faltas, tarjetas, lesiones)
  → atención: decide qué momento merece salir en pantalla y por qué
  → salida: MatchSnapshot v1 + InsightCandidate v1 (+ registro de decisiones)

Observaciones de visión de Persona 1 (VisualTrackObservation + identidad resuelta)
  → seguimiento: distancia, velocidad, sprints, velocidad del balón y del tiro,
                 presión por cercanía, forma del equipo y avisos por umbral
  → cancha: cuadros para dibujar el partido en vivo
  → resumen: posiciones del momento y lecturas «¿qué habría pasado si…?»
```

Cuatro ideas para explicarlo:

1. **Toda cifra se puede comprobar.** Cada número lleva fórmula, unidad, versión y los eventos o pistas de donde sale. Si faltan datos, aparece como «no disponible», nunca como cero.
2. **La IA no calcula cifras.** El motor calcula; los agentes de Persona 3 explican. Así un agente no puede inventar un dato.
3. **La prioridad se explica.** Es una suma visible de motivos, y ahora se ve en la pestaña Resumen.
4. **Personalización sin cambiar los hechos.** Los perfiles cambian qué momentos salen, pero no las cifras. Los goles y las rojas del rival salen siempre.

Con el partido de prueba de 178 eventos, el perfil casual recibe 14 momentos, el analista 33 y el modo jugador de L. Sol 9. En el partido en vivo, el casual recibe 7 y el analista 12.

## Qué está acoplado hoy

| Con quién | Qué se conectó | Estado |
|---|---|---|
| Persona 1 (datos) | Contrato `MatchEvent 1.0` (con los campos nuevos), validación, deduplicación y eventos tardíos | Probado en local |
| Persona 1 (vídeo y visión) | `MatchStateRebuilder` y las observaciones `VisualTrackObservation` con identidad resuelta | Probado con observaciones simuladas |
| Persona 1 (visión en vivo) | La tarjeta «Visión IA» muestra su captura en vivo cuando hay vídeo, y sus resultados guardados cuando no | Unido; la captura en vivo no se probó con su vídeo y su GPU |
| Persona 1 (Azure) | Event Hubs y Storage de su plantilla, reutilizados sin cambios | Desplegado |
| Persona 4 (API e interfaz) | `AnalyticsPort` con el motor real, cancha en vivo, análisis de momentos en Resumen | Integrado y desplegado en Azure |
| Persona 3 (agentes) | Tiene los contratos y ejemplos de Persona 2 | Bloqueado: sus contratos rechazan las salidas del motor |

## Qué usa datos simulados (mocks)

| Parte | Qué se simula | Qué lo reemplaza |
|---|---|---|
| Partidos | 3 partidos sintéticos (el reto lo exige) | Partidos más largos de Persona 1 |
| Posiciones de jugadores y balón | `adapters/sources/tracking_mock.py`, con el formato de Persona 1 y origen `simulated_fixture` | Las observaciones reales de vídeo de Persona 1, sin cambiar la analítica |
| Distancias, velocidades, cancha y lecturas del Resumen | El cálculo es real, sobre posiciones simuladas | Lo mismo con posiciones reales |
| Frases de los momentos | Narración provisional de Persona 4 | Los agentes de Persona 3 |

**No es simulado:**
- el estado, las estadísticas, los patrones, los indicadores, los momentos, las prioridades y los motivos;
- el despliegue en Azure y la base en Supabase.

**xT, xG y VAEP** siguen **desactivados** hasta tener datos con licencia para entrenarlos.

## Qué recibe Persona 3 (agentes)

**`InsightCandidate v1` (momento candidato):** un momento que vale la pena narrar, con todo lo necesario para explicarlo sin inventar nada. Ejemplo real del gol, recortado:

```json
{
  "candidate_id": "moment-evt-010",
  "kind": "goal",
  "priority": 100,
  "team_id": "team-aurora",
  "facts": [
    {"key": "goals", "team_id": "team-aurora", "value": 1, "unit": "count",
     "origin": "event_count", "formula_version": "goals@1", "source_event_ids": ["evt-010"]},
    {"key": "shot_distance_m", "value": 14.2, "unit": "meters", "origin": "derived"},
    {"key": "seconds_since_recovery", "value": 11.0, "unit": "seconds"}
  ],
  "source_event_ids": ["evt-006", "evt-007", "evt-008", "evt-009", "evt-010"],
  "evidence_limits": [
    "Relación temporal entre ganar el balón y el tiro; los eventos no demuestran que una acción causara la otra."
  ],
  "reasons": [{"code": "base_kind", "points": 80}, {"code": "measured_fact", "points": 13},
              {"code": "combined_signals", "points": 5}, {"code": "novelty", "points": 10}]
}
```

| Campo | Para qué le sirve al agente |
|---|---|
| `kind` | Qué pasó. Hay 14 tipos: gol, tiro, recuperación y tiro, progresión rápida, presión sostenida, cambio de control, fase de caos, hito de jugador, recuperación alta, pase progresivo, falta, amarilla, roja y detención por lesión |
| `facts` | Las únicas cifras que puede decir, cada una con unidad y eventos de origen |
| `evidence_limits` | Lo que **no** puede afirmar |
| `reasons` | Por qué se eligió el momento |
| `source_event_ids` | Para que el verificador contraste cada afirmación |

**`MatchSnapshot v1` (estado):** el partido en un instante, con unas 250 cifras (unas 340 con seguimiento). Sirve para responder preguntas y para los resúmenes.

**Nuevo para Persona 3:** el análisis de un momento (`/moments/{id}/analysis`) trae lecturas «¿qué habría pasado si…?» medidas. Su agente contrafactual puede partir de ellas en vez de inventar el escenario.

**Qué hay que acordar con Persona 3:**
- Usar estos contratos en lugar de sus copias, o ajustar las cuatro reglas que hoy rechazan las salidas.
- Quién implementa el filtro y el catálogo de jugadas (`RoutingDecision v1`, `PlayContext v1`) que el plan asigna a Persona 2.
- Mantener Event Hubs como canal (decisión 10).

## Qué recibe cada una de las demás personas

| Persona | Qué recibe | Qué necesito de ella |
|---|---|---|
| **Persona 4 (API e interfaz)** | El motor real detrás de su `AnalyticsPort`, la cancha en vivo con nuestro modelo, el análisis de momentos y el despliegue en Azure | Revisar los cambios en sus archivos (registro de partidos, narración provisional, Resumen y pestañas) y decidir si `persona2` pasa a ser el motor predeterminado |
| **Persona 1 (datos y visión)** | La analítica de seguimiento que consume sus observaciones y la cadena de Azure que reutiliza su plantilla | Revisar los cambios hechos en sus archivos al unir. Avisar cuando cambien los resultados de sus modelos (la imagen copia los de `docs/mentox-modelos-20261023T045413Z`) y corregir la tabla `match_events` de su Supabase. Coordinar los cambios de contrato, indicar en las observaciones qué pista es el balón o un portero y conseguir un vídeo permitido |
| **Persona 5 (UX/UI)** | Los bloques nuevos del Resumen, la tarjeta «Visión IA», el interruptor del asistente y el estilo común de los select | Actualizar `uidesign` desde `develop` o desde nuestra rama antes de unirla, y revisar con su paleta estas piezas nuevas, en claro, oscuro y móvil |

Detalle de los avisos para Persona 1:

- **Archivos de experimentos:** su panel de visión los busca en `experiments/…/output-real`, que solo existe en su equipo. Ya funciona apuntando las variables `MENTOX_*_ARTIFACT` a las copias de `docs/mentox-modelos-20261023T045413Z/resultados`, con lo que pasan 8 de las 10 pruebas que fallaban. Las 2 restantes tienen esa ruta fija en la prueba. La imagen de Azure copia esas mismas tres copias; si publica resultados nuevos en otra carpeta, hay que cambiarla en `apps/backend/Dockerfile` y en el `.dockerignore` de la raíz.
- **Panel de visión:** decía «Visión no disponible» aunque la API respondía `ready`, porque leía un campo que la API no envía. Ya está corregido. Ahora su panel y nuestra tarjeta son una sola, `VisionCard`.
- **Tabla `match_events`:** usa `event_id` como clave única, así que dos partidos con `evt-001` se pisan.
- **Cambios en sus archivos al unir:**
  - `integration_router.py` y `live_vision_capture.py`: la captura comprueba la pausa y el tipo antes de leer el fotograma y corta al pasar 8 MiB (413). El vídeo de Blob se envía por partes de 4 MiB.
  - `soccernet_gamestate.py` usa `TrackedKind.REFEREE`, que volvió a existir junto a `UNASSIGNED`.
  - `deploy-messi-generator.sh` da el permiso de escritura solo sobre su contenedor. Si ya ejecutó el script, debe quitar el permiso anterior sobre toda la cuenta de Storage.
  - Sus 3 rutas nuevas están en la colección de Postman.

## Cómo se integra con Azure

```text
Supabase (match_analytics) ──► API (Container Apps) ──► interfaz (nginx, Container Apps)
        ▲                          motor de Persona 2
        │
Trabajo replay ──► Event Hubs · match-events ──► procesador continuo
                                                   ├─► Event Hubs · match-insights
                                                   │      narrative → Persona 3
                                                   │      experience → Persona 4
                                                   ├─► Blob Storage · analytics (registro con SHA-256)
                                                   └─► Supabase · analytics_runs
```

**Listo y verificado en Azure:**
- Infraestructura completa con identidad administrada, sin claves.
- La API con el motor real, que lee Supabase.
- La interfaz, el análisis de momentos, la previa táctica y la tarjeta «Visión IA» en español y en inglés.
- Las rutas de captura de Persona 1 con límites: sin su configuración explican qué falta, y un fotograma grande en pausa se rechaza sin leerlo.

**Flujo continuo verificado el 25 de octubre:** el trabajo `replay` publicó en `match-events` los 178 eventos del partido de analítica a 8× (como `synthetic-analytics-001-live-20261026003858`). El procesador los aplicó todos a tiempo, con un transporte medio de 51 ms (p95 71 ms) y un procesamiento medio de 27 ms (p95 35 ms). Propuso momentos en 19 eventos y, 30 s después del último, guardó el registro `run-c57436ad-…` con 7 archivos en Blob y en Supabase.

**Falta:**
- La prueba de humo `analytics_azure_smoke.py`.
- Cerrar con Persona 3 que el canal sigue siendo Event Hubs.

Medido en local: unos 3 ms de procesamiento por evento y entre 0,1 y 0,15 s por estado con seguimiento.

## Para profundizar

- [Despliegue en Azure paso a paso (para todo el equipo)](../14-despliegue-en-azure.md)
- [Despliegue en Azure y Supabase (detalle técnico)](despliegue-azure-supabase.md)
- [README de Persona 2](README.md)
- [Catálogo de métricas](catalogo-de-metricas.md)
- [Reglas de patrones y atención](reglas-de-patrones-y-atencion.md)
- [Analítica de seguimiento](analitica-de-seguimiento.md)
- [Evidencias](evidencias/README.md)
