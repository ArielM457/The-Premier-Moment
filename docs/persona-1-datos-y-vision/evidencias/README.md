# Evidencias técnicas de las historias de usuario

Esta carpeta conserva la evidencia de implementación de cada historia de Persona 1. Una historia no se marca como terminada únicamente porque exista código: debe demostrar cada criterio de aceptación con una prueba o una comprobación reproducible.

## Evidencias disponibles

La integración actual de Roboflow, TeamSpotting y el replay MESSI conserva
su [evidencia local y límites](messi-hibrido-20261027.md) y la
[prueba real con ambas GPU, colas, worker e interfaz](messi-azure-20261027/README.md).
GameState está retirado. El lote MESSI clean de tres partidos y su Roboflow
precalculado en CPU tienen su [evidencia del 1 de noviembre](messi-roboflow-lote-20261101.md).

| Historia | Estado | Evidencia |
|---|---|---|
| DV-US-01 · Generar el partido de aceptación | Implementada y verificada localmente | [DV-US-01](DV-US-01.md) |
| DV-US-02 · Reproducir el flujo | Implementada y verificada localmente | [DV-US-02](DV-US-02.md) |
| DV-US-03 · Recibir únicamente eventos válidos | Implementada y verificada localmente | [DV-US-03](DV-US-03.md) |
| DV-US-04 · Evitar el doble conteo | Núcleo y memoria verificados localmente; Event Hubs pendiente | [DV-US-04](DV-US-04.md) |
| DV-US-05 · Reconocer un evento tardío | Detección verificada; reconstrucción pendiente de acuerdo con Persona 2 | [DV-US-05](DV-US-05.md) |
| DV-US-06 · Desplegar recursos en una cuenta propia | Verificada en Azure mediante DV-US-14 | [DV-US-06](DV-US-06.md) |
| DV-US-07 · Publicar eventos en Event Hubs | Verificada en integración mediante DV-US-15 | [DV-US-07](DV-US-07.md) |
| DV-US-08 · Cambiar entre transporte local y Azure | Memoria y Azure comprobados mediante DV-US-15 | [DV-US-08](DV-US-08.md) |
| DV-US-09 · Conservar artefactos autorizados | `matches` y `observations` verificados en Azure mediante DV-US-16; vídeo depende de DV-US-17 | [DV-US-09](DV-US-09.md) |
| DV-US-10 · Sincronizar eventos con vídeo | Coordinación temporal verificada localmente; vídeo e interfaz pendientes | [DV-US-10](DV-US-10.md) |
| DV-US-11 · Evaluar modelos sin comprometer el MVP | Evaluador y ejecuciones reales disponibles; métricas de calidad pendientes de anotación manual | [DV-US-11](DV-US-11.md) |
| DV-US-12 · No inventar identidad de jugadores | Regla y pruebas negativas verificadas localmente; asociación real pendiente | [DV-US-12](DV-US-12.md) |
| DV-US-13 · Fusionar observaciones con trazabilidad | Política y servicio verificados localmente; vídeo real pendiente | [DV-US-13](DV-US-13.md) |
| DV-US-14 · Desplegar y autorizar el entorno real | Verificada en integración | [DV-US-14](DV-US-14.md) |
| DV-US-15 · Probar Event Hubs de extremo a extremo | Verificada en integración | [DV-US-15](DV-US-15.md) |
| DV-US-16 · Probar Blob Storage de extremo a extremo | Verificada en integración | [DV-US-16](DV-US-16.md) |
| DV-US-17 · Preparar el paquete de vídeo permitido | Vídeo sintético de 30 segundos, integridad, metadatos e indicaciones manuales verificados localmente | [DV-US-17](DV-US-17.md) |
| DV-US-18 · Validar sincronización mediante una interfaz mínima | Herramienta aislada y contrato ASGI verificados; recorrido visual y capturas pendientes | [DV-US-18](DV-US-18.md) |
| DV-US-19 · Ejecutar Roboflow Sports | Verificada localmente como experimento; resultado `rejected` para integración | [DV-US-19](DV-US-19.md) |
| DV-US-20 · Ejecutar SoccerNet | Verificada experimentalmente en CPU y GPU; calidad pendiente de anotación manual | [DV-US-20](DV-US-20.md) |
| DV-US-21 · Calibrar identidad y fusión | Verificada experimentalmente; un candidato sin identidad y ningún evento publicado | [DV-US-21](DV-US-21.md) |
| DV-US-22 · Ejecutar el ensayo de aceptación integrado | Verificada en integración; recorrido local, Azure, vídeo, modelos, fusión y fallo controlado comprobados | [DV-US-22](DV-US-22.md) |
| DV-US-28 · Integrar visión con la aplicación oficial | Implementada en rama de integración; frontend y pruebas aisladas verificados | [DV-US-28](DV-US-28.md) |
| DV-US-29 · Separar telemetría y eventos importantes | Verificada en Azure con tres canales y publicación real | [DV-US-29](DV-US-29.md) |
| DV-US-30 · Desplegar el primer detector en una GPU de Azure | Verificada en Azure con Tesla T4 y escala posterior a cero | [DV-US-30](DV-US-30.md) |
| DV-US-31 · Preparar el despliegue de los modelos restantes | Suite Roboflow y TeamSpotting verificados en Azure; ejecución simultánea limitada por cuota | [DV-US-31](DV-US-31.md) |
| DV-US-23 · Integrar el pipeline en el backend oficial | Backend y API HTTP verificados en un recorrido consolidado; Compose y frontend fuera de esta prueba | [DV-US-23](DV-US-23.md) |
| DV-US-24 · Transportar observaciones durante la transmisión | Verificada localmente; canal Azure desplegado y prueba de datos pendiente con identidad autorizada | [DV-US-24](DV-US-24.md) |
| DV-US-25 · Controlar observaciones con la reproducción | Verificada localmente; recorrido visual con Compose pendiente | [DV-US-25](DV-US-25.md) |
| DV-US-26 · Ampliar la percepción espacial de fútbol | Ejecución completa en GPU de 6 GB verificada; calidad pendiente de anotación manual | [DV-US-26](DV-US-26.md) |
| DV-US-27 · Evaluar SoccerNet Game State Reconstruction | Ajustada para 6 GB; descarga automática, construcción y smoke pendientes | [DV-US-27](DV-US-27.md) |
| DV-US-33 · Adaptar un MP4 a SoccerNet GameState | Contratos verificados localmente; inferencia GPU pendiente | [DV-US-33](DV-US-33.md) |
| DV-US-34 · Ejecutar inferencia mientras se reproduce el vídeo | Captura verificada localmente y topología Azure verificada; recorrido visual pendiente | [DV-US-34](DV-US-34.md) |
| DV-US-35 · Consumir eventos importantes con un worker | Worker y recorrido Service Bus verificados; ejecución real de agentes pendiente | [DV-US-35](DV-US-35.md) |
| DV-US-36 · Preparar SoccerNet GameState como servicio GPU | Retirado de la demo; Container App eliminado. Evidencia técnica y calidad insuficiente conservadas | [DV-US-36](DV-US-36.md), [retiro](gamestate-retiro-20261027.md) |

La revisión consolidada de la ejecución GPU se encuentra en
[revisión de modelos GPU del 23 de octubre de 2026](revision-modelos-gpu-2026-10-23.md).

El orden reproducible del ensayo se encuentra en [historias de usuario](../historias-de-usuario.md) y en el [plan de pruebas con servicios reales](../plan-pruebas-servicios-reales.md).
La ejecución en un solo comando está documentada en la
[guía de integración del backend](../guia-integracion-backend.md).

## Contenido obligatorio

Cada evidencia debe registrar:

1. Estado y fecha de la última verificación.
2. Alcance implementado y exclusiones.
3. Entradas y resultados.
4. Archivos creados o modificados.
5. Decisiones técnicas relevantes.
6. Matriz entre criterios de aceptación, implementación y pruebas.
7. Comandos exactos para reproducir la verificación.
8. Versiones del entorno utilizado.
9. Resultado de las pruebas.
10. Limitaciones, riesgos y trabajo pendiente.
11. Dependencias sobre otros módulos o decisiones del equipo.

## Estados permitidos

- **Pendiente:** todavía no comenzó la implementación.
- **En progreso:** existe trabajo parcial, pero falta al menos un criterio.
- **Implementada, pendiente de verificación:** existe código, pero no hay evidencia suficiente.
- **Verificada localmente:** todos los criterios de la historia pasaron en el entorno local documentado.
- **Verificada en integración:** también pasó con sus servicios o consumidores reales.
- **Bloqueada:** no puede continuar por una dependencia explícita.

La evidencia debe distinguir las pruebas locales de las pruebas con Azure, vídeo o modelos externos. Una prueba local no demuestra comportamiento en una transmisión real.

## Plantilla

Copiar [PLANTILLA.md](PLANTILLA.md) al comenzar una historia nueva. El nombre debe conservar el identificador, por ejemplo `DV-US-03.md`.
