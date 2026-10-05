# Revisión previa al merge

Fecha: 5 de octubre de 2026. Rama: `codex/dynamic-clean-start-icon`.

## Correcciones realizadas

1. **Compilación del diseño dinámico.** El registro adjunto identifica una declaración de `@ScaledMetric` sin valor inicial en `AdaptiveCardGrid`. Se ha inicializado la propiedad y se conserva el ancho personalizado de cada instancia. Las otras declaraciones de `@ScaledMetric` también tienen valor inicial.
2. **Mes al navegar a Presupuestos.** Inicio y Presupuestos compartían el concepto de mes, pero guardaban estados independientes. Ahora reciben el mismo estado desde `RootTabView`: abrir el detalle o crear un presupuesto conserva el mes que se estaba consultando.
3. **Gráfico patrimonial.** El último punto usaba el final del mes, aunque el patrimonio principal se calcula a fecha actual. Ahora la historia se corta en la fecha solicitada y no incorpora movimientos ni valoraciones posteriores a ella.
4. **Importes mal escritos.** El parser eliminaba caracteres y podía aceptar el prefijo de un número incompleto. Ahora valida el número completo y rechaza importes fuera del rango admitido. Se mantienen la coma decimal, el punto decimal y los separadores españoles e ingleses combinados.
5. **Reintentar un guardado fallido.** Registrar una valoración o una aportación periódica revierte las modificaciones pendientes si falla la escritura. Así se evita dejar una inserción pendiente que pueda guardarse después de mostrar un error.
6. **Comprobaciones antes del merge.** `Validar app iOS` se ejecutará al subir ramas `codex/…` y en los pull requests a `main`. Compila la app completa en Debug para simulador y Release para dispositivo sin firma; guarda un registro independiente por compilación.

No se ha cambiado el esquema SwiftData, el identificador de la app ni la configuración de almacenamiento durante esta revisión.

## Comprobaciones locales completadas

| Comprobación | Resultado |
| --- | --- |
| Sintaxis Swift con tree-sitter-swift | Los 31 archivos de la app y los 2 de pruebas se analizan sin errores sintácticos. No es una comprobación de tipos. |
| Proyecto Xcode con parser OpenStep | Las rutas existen y los 31 archivos Swift de la app figuran exactamente una vez en `Sources`; los ejecutables de pruebas no se incluyen en el target de la app. |
| Esquema y configuraciones | El esquema compartido referencia el target correcto; Debug y Release mantienen iOS 17, familias iPhone/iPad y versión 0.2.10, build 12. |
| Recursos | `Info.plist`, el XML del esquema y los JSON de assets se leen correctamente. El icono es PNG RGB de 1024 × 1024, sin canal alfa. |
| GitHub Actions | Los cuatro workflows pasan [actionlint](https://github.com/rhysd/actionlint); los 14 scripts de los workflows pasan `bash -n` y las rutas de fuentes usadas por las pruebas existen. |
| Diferencias Git | `git diff --check` no detecta errores de espacios o marcadores de conflicto. |

## Pruebas preparadas para ejecutar en GitHub

`Comprobar datos y cálculos` contiene dos trabajos que utilizan las clases y servicios reales de la app:

- **Exportación y restauración:** todos los modelos, incluyendo reglas de categoría y presupuestos repetidos; restauración repetida sin duplicados; lectura de copias anteriores sin esas colecciones; rechazo de datos inválidos y conservación de los datos actuales ante una copia inválida.
- **Cálculos y aportaciones automáticas:** saldos y valoraciones; reserva del máster excluida del disponible y conservada en el patrimonio; transferencia a inversión sin gasto ni incremento patrimonial; historial sin datos futuros; sobrante como ahorro o acumulado solo desde meses cerrados; ajuste de un presupuesto mensual; detención de repetición; tres aportaciones pendientes y una segunda apertura sin duplicados; categorías con iconos y restauración sin duplicados; reglas compatibles y prioridad de frases específicas; archivos CSV de ejemplo e importes inválidos.

Estas pruebas nuevas **todavía no se han ejecutado**: este equipo Windows no dispone de Swift, Xcode ni el SDK de iOS. La validación definitiva requiere subir el commit a la rama y esperar a los resultados del runner macOS.

## Antes de integrar

1. En GitHub Desktop, hacer commit de todos los cambios y pulsar **Push origin** en la rama de trabajo.
2. En Actions, comprobar que el último commit supera las dos compilaciones de **Validar app iOS** y los dos trabajos de **Comprobar datos y cálculos**. No hace falta hacer merge para ejecutarlos.
3. Revisar el aspecto siguiendo `PRUEBAS_REDISENO.md`, especialmente iPhone pequeño, iPad vertical/horizontal, pantalla dividida y texto de accesibilidad.

Esta configuración añade comprobaciones, pero no modifica la protección de `main`: por sí sola no impide pulsar Merge cuando un trabajo falla. Tampoco sustituye las pruebas de interacción y aspecto en un simulador o dispositivo real.
