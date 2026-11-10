# Instrucciones para Claude Code

@AGENTS.md

## Forma de trabajar acordada

- Responde y documenta en español. Distingue lo implementado, lo probado en CI, lo desplegado y lo comprobado en el iPhone o el iPad.
- Deja anotado en Obsidian (`%USERPROFILE%\Documents\MIBomboMOney\Mi Bombo Money`) cada cambio, decisión o investigación, actualizando la nota existente del tema y `Índice.md`. Las consultas puntuales que el usuario indique no se anotan.
- Trabaja en una rama distinta de `main` por **lotes grandes** que agrupen varios cambios para probarlos de una vez en el dispositivo (decisión del usuario del 10 de noviembre de 2026: probar lotes pequeños le cuesta demasiado tiempo y tokens). Cada cambio lleva su prueba de regresión con datos ficticios en `Tests/`, conectada al workflow correspondiente, y los checks deben estar en verde antes de pedirle que pruebe.
- Cuando un lote está listo y con checks en verde, el usuario genera el IPA desde la rama (Actions → Generar IPA sin firmar), lo instala en el iPad y comunica el resultado. Sube `MARKETING_VERSION` y `CURRENT_PROJECT_VERSION` en `MiPatrimonio.xcodeproj/project.pbxproj` para cada versión que se vaya a instalar.
- El repositorio es público: no incluyas enlaces de sesión de Claude (`Claude-Session:`) en commits ni PR, ni secretos, claves, tokens, IBAN o datos financieros reales.
- Confirma con el usuario antes de publicar, hacer *force push*, desplegar el Worker de Cloudflare, aplicar migraciones de Supabase o tocar servicios reales.
