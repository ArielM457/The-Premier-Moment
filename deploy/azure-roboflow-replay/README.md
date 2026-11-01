# Reproductor de observaciones Roboflow precalculadas

Este servicio conserva el contrato HTTP de Roboflow Suite, pero no ejecuta
modelos durante la demostración. Reconoce el fotograma recibido mediante una
huella visual y devuelve las detecciones que Roboflow produjo previamente para
uno de los tres vídeos autorizados.

No presenta los resultados como inferencia en tiempo real. La respuesta declara
`device=precomputed-cache` y `execution_mode=precomputed_video_lookup`.

La guía operativa completa está en
`docs/persona-1-datos-y-vision/guia-roboflow-precalculado.md`.
