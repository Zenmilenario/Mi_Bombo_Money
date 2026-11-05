# Comprobaciones de GitHub sin ejecuciones duplicadas

Preparado localmente el 5 de noviembre de 2026. Pendiente de ejecutar la configuración nueva en GitHub.

## Cuándo se comprueba

Los cuatro workflows de validación comparten esta política:

| Acción | Resultado |
| --- | --- |
| Abrir una pull request, también en borrador | Batería completa sobre la integración de la rama con su destino. |
| Subir cambios a una rama con PR abierta | Una ejecución por workflow mediante `pull_request`, sin otra por el push de la rama. |
| Reabrir una PR | Batería completa de nuevo. |
| Hacer merge o push directamente a `main` | Batería completa sobre el estado real de `main`. |
| Crear una etiqueta | Batería completa; la generación de IPA mantiene sus propios eventos. |
| Usar una cola de merge | Batería completa para el evento `merge_group/checks_requested`. |
| Trabajar en una rama sin PR | No hay ejecución automática por push. Abrir una PR en borrador o usar **Actions → workflow → Run workflow**, seleccionando la rama. |

Para el flujo habitual con GitHub Desktop, conviene abrir pronto una PR en borrador. Cada push posterior actualiza la PR y dispara todas las comprobaciones. No es necesario fusionarla para comprobarla. Si se quiere comprobar una rama sin PR, ejecutar los cuatro workflows: **Validar app iOS**, **Comprobar datos y cálculos**, **Comprobar conexión bancaria de prueba** y **Comprobar almacenamiento cloud**.

GitHub no ejecuta los workflows `pull_request` cuando la PR tiene conflictos de merge. Resolver los conflictos y subir la resolución antes de interpretar la ausencia de checks. No se utiliza `pull_request_target` para ejecutar el código de la PR. La activación manual de workflows está disponible si su definición existe en la rama predeterminada.

La validación posterior al merge en `main` se conserva: comprueba el estado integrado que se distribuirá. No es la ejecución duplicada push de rama + actualización de PR que se ha retirado. Tampoco se suprimen ejecuciones manuales solicitadas expresamente.

## Qué se conserva y qué mejora

- Los diez trabajos anteriores conservan sus identificadores, nombres, comandos, pasos, tiempos máximos, permisos y matrices. El trabajo iOS sigue generando dos comprobaciones: Debug para simulador y Release para dispositivo, con `fail-fast: false`.
- Se mantienen pruebas de exportación/restauración, cálculos, reservas, transferencias, recurrencias, categorías, modelos de IA, filas adaptables, seguridad, integración bancaria, PostgreSQL, aislamiento y sincronización cloud.
- No se han introducido condiciones que salten trabajos o pasos, ni `continue-on-error`, ni se han retirado suites.
- Se retiran los filtros de archivos del workflow cloud. Las pruebas cloud se ejecutan en todas las PR y en los cambios de `main`, incluidas modificaciones fuera de las rutas que antes activaban ese workflow. Esto amplía cobertura; puede sumar trabajo en cambios que antes no ejecutaban cloud.
- Se añade **Configuración y cobertura de los checks**, un trabajo corto en Ubuntu. Comprueba eventos, permisos, concurrencia, las dos configuraciones nativas y que cada `Tests/*Check.swift` aparezca en un comando de compilación seguido de su ejecución. Conserva también las comprobaciones de geometría, PostgreSQL, servidor y auditoría de dependencias. No sustituye a ejecutar esas suites ni es una prueba del planificador interno de GitHub.
- Los procesos de generación de IPA firmado y sin firmar conservan su configuración.

## Ejecuciones sustituidas por cambios posteriores

Los cuatro workflows usan un grupo que contiene nombre del workflow, tipo de evento y número de PR o referencia. Si llega otro cambio a la misma PR, la ejecución anterior pendiente o en curso se cancela y se conserva la nueva. El nuevo commit ejecuta la batería completa: no reutiliza resultados parciales del anterior.

Una ejecución manual no cancela la validación de una PR; tampoco se cancelan workflows distintos entre sí. Un estado **Cancelled** de un commit anterior no acredita ni invalida el último: revisar siempre los checks del commit actual y esperar a que terminen.

No se han cambiado las protecciones de ramas, los checks obligatorios configurados en GitHub, la visibilidad ni los límites de facturación. Mantener nombres permite conservar las referencias existentes a checks obligatorios. Los checks solo bloquean un merge si las reglas del repositorio lo exigen: esta revisión no configura esas reglas remotas.

## Validación realizada

1. `actionlint` 1.7.12 valida los seis workflows. Se utilizó el binario oficial con checksum comprobado.
2. `python Tests/check_ci_workflows.py` pasa sus tres grupos de comprobaciones, incluidos doce escenarios de eventos para cada workflow.
3. Comparación con `HEAD`: los diez trabajos previos son idénticos como estructuras YAML; ambos workflows de IPA están intactos, normalizando los finales de línea de Windows.
4. `bash -n` acepta los scripts de los trabajos de validación y `git diff --check` no detecta problemas de espacios.

No se ha vuelto a compilar la app ni a ejecutar las pruebas financieras durante este cambio de planificación: sus comandos no se han modificado. Xcode, SwiftData y la ejecución real de GitHub quedan pendientes del próximo push/PR. No se han modificado los datos financieros ni el código de la app.

## Uso y costes

La reducción afecta directamente a ejecuciones y consumo de GitHub Actions. El ahorro depende del número de pushes, PR y trabajos cancelados; no se promete un porcentaje fijo. No cambia los límites ni el precio de Codex. Puede reducir revisiones repetidas de registros durante el desarrollo, sin garantizar un ahorro concreto de cuota de IA.

## Referencias

- [Eventos de GitHub Actions](https://docs.github.com/en/actions/reference/workflows-and-actions/events-that-trigger-workflows).
- [Concurrencia y cancelación](https://docs.github.com/en/actions/how-tos/write-workflows/choose-when-workflows-run/control-workflow-concurrency).
- [Validador actionlint](https://github.com/rhysd/actionlint/releases/tag/v1.7.12).
