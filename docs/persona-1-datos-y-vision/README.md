# Datos, visión e ingesta de eventos

Esta carpeta contiene el plan detallado de Persona 1. Su objetivo es entregar un flujo confiable y reproducible de eventos de fútbol sintéticos, con una vía experimental para obtener observaciones desde vídeo y una integración desplegable en Azure.

## Documentos

- [Flujo actual: Roboflow, TeamSpotting y MESSI](guia-flujo-hibrido-messi.md): datos del mismo MP4, eventos entendibles y configuración sin GameState.
- [Ejecutar MESSI clean y Roboflow desde un solo script](ejecutar-lote-messi-roboflow.md): tres vídeos MESSI `clean`, inferencia Roboflow por etapas, reanudación y entrega al equipo.
- [Roboflow precalculado para tres vídeos fijos](guia-roboflow-precalculado.md): catálogo generado con GPU, servicio CPU con el mismo contrato de Roboflow, verificaciones y limitaciones.
- [Overview para pruebas de modelos](overview-para-pruebas-de-modelos.md): contexto breve, alcance y ruta de trabajo para la persona o IA que ejecutará Roboflow y SoccerNet en una computadora GPU.
- [Evaluación de costos de modelos en la nube](evaluacion-costos-modelos-en-la-nube.md): rendimiento medido, recursos Azure, estimaciones, WebGPU y alternativas de GPU.
- [Comparativa de proveedores GPU](comparativa-proveedores-gpu.md): precios, riesgos y arquitectura híbrida recomendada para ejecutar los modelos fuera de Azure.
- [Despliegue del primer detector en Azure](../../deploy/azure-roboflow-player/README.md): API GPU, ACR privado, identidad administrada y script reproducible para Roboflow Player Detection.
- [Despliegue de los modelos para el equipo](despliegue-modelos-azure-equipo.md): suite Roboflow, TeamSpotting, GameState asíncrono, escala y pruebas.
- [Revisión de integración de modelos](revision-integracion-modelos-20261027.md): fallos corregidos, pruebas reproducibles y capacidades todavía incompletas.
- [Guía de integración del backend](guia-integracion-backend.md): un solo comando para modelos, fusión, API, pruebas, Azure opcional y evidencias sin frontend.
- [Guía de instalación y ejecución desde cero](guia-ejecucion-desde-cero.md): preparación de Ubuntu, GPU, Docker, modelos e interfaz para una persona principiante.
- [Plan general](plan-general.md): alcance, arquitectura, fases, entregables y estrategia de Azure.
- [Requisitos funcionales](requisitos-funcionales.md): capacidades verificables del módulo.
- [Historias de usuario](historias-de-usuario.md): necesidades de los consumidores del módulo y criterios de aceptación.
- [Estado actual](estado-actual.md): resumen consolidado de lo implementado, verificado y pendiente.
- [Resumen del trabajo realizado](resumen-trabajo-realizado.md): lista directa, punto por punto, de lo construido hasta ahora.
- [Diagrama del flujo de datos](diagrama-flujo.md): representación Mermaid del funcionamiento local, la integración Azure y los modelos de visión.
- [Plan de pruebas con servicios reales](plan-pruebas-servicios-reales.md): orden de despliegue, integración Azure, vídeo, modelos e interfaz mínima de comprobación.
- [Evidencias técnicas](evidencias/README.md): implementación, criterios cubiertos, pruebas y limitaciones de cada historia.

## Fuentes de autoridad

Este plan amplía, pero no reemplaza, los siguientes documentos:

- [Asignación de Persona 1](../plan-de-desarrollo/persona-1-datos-y-vision.md).
- [Formato estándar de eventos](../08-formato-de-eventos.md).
- [Requisitos generales](../03-requisitos.md).
- [Casos de uso](<../06-Casos de Uso — Plataforma de Inteligencia de Partidos con IA.md>).
- [Decisiones tomadas](../07-decisiones-tomadas.md).

Si existe una contradicción, se debe resolver en el documento general correspondiente antes de cambiar el contrato compartido.

## Estado

DV-US-01 a DV-US-13 tienen implementación y evidencia local en distintos niveles. DV-US-14, DV-US-15 y DV-US-16 ya están verificadas contra Azure. El vídeo permitido y las ejecuciones reales de Roboflow Sports y SoccerNet todavía no están verificados. DV-US-14 a DV-US-22 separan ese trabajo de integración de las capacidades comprobadas con dobles y datos sintéticos.
