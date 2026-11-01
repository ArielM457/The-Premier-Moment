# Reproductor de observaciones Roboflow precalculadas

Este servicio conserva el contrato HTTP de Roboflow Suite, pero no ejecuta
modelos durante la demostración. Reconoce el fotograma recibido mediante una
huella visual y devuelve las detecciones que Roboflow produjo previamente para
uno de los tres vídeos autorizados.

No presenta los resultados como inferencia en tiempo real. La respuesta declara
`device=precomputed-cache` y `execution_mode=precomputed_video_lookup`.

Si el catálogo trae la huella de primer plano, el servicio la usa en lugar de la
miniatura de 32x18. Resta el fondo común de los fotogramas y compara solo los
marcadores, el balón y el reloj, que es lo único que cambia en el render MESSI
con cámara fija. `/health/ready` indica el método en `visual_match`.
`precompute.py` la genera. Para un catálogo anterior, `add_foreground.py` la
agrega sin GPU y comprueba antes el SHA-256 de cada fotograma.

La guía operativa completa está en
`docs/persona-1-datos-y-vision/guia-roboflow-precalculado.md`.
