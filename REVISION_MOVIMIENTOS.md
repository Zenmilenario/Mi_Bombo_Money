# Bandeja «Por revisar»

Actualizado: 4 de noviembre de 2026.

## Corrección de compilación iOS · 4 de noviembre de 2026

En el commit `ab61422`, las cuatro compilaciones iOS fallaron en la misma expresión de la lista de Movimientos: Xcode agotó el tiempo de deducción de tipos. Se confirmó en los registros de simulador y dispositivo, tanto del [push](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41792308298) como del [pull request](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41792342146). Los workflows de datos y cálculos, conexión bancaria y almacenamiento cloud pasaron en ese commit.

La corrección local separa la lista, sus secciones y la fila que gestiona selección y acciones al deslizar. Se conserva el acceso al detalle, la selección múltiple y el cambio rápido de categoría. Se mantiene la versión 0.6.10 (build 27).

Pasan el análisis sintáctico Swift de la vista y la revisión de cambios de Git. Falta subir la corrección y verificar las compilaciones de Xcode de ese nuevo commit.

## Estado y acceso

La versión 0.6.10 (build 27) prepara mejoras de presentación y clasificación en el código local; pendiente de compilación nativa y prueba física. En **Movimientos**, la tarjeta **Por revisar** permite alternar entre todos los movimientos de la selección y los que tienen incidencias. Se mantiene la búsqueda y los filtros de cuenta, categoría, tipo y periodo. También hay un control **Solo por revisar** dentro de Filtros, y se puede quitar desde el chip correspondiente.

## Clasificar varios movimientos · 0.6.10

Desde **Movimientos → Más opciones (…) → Seleccionar movimientos** se activan las casillas de selección. Se pueden marcar filas concretas o pulsar **Seleccionar resultados**, que incluye todos los resultados de la búsqueda y filtros actuales. Los movimientos que dejan de aparecer al cambiar filtros salen de la selección. No hay selección oculta de registros de otras búsquedas.

**Elegir categoría para la selección** abre una hoja con el número de movimientos, un desplegable para revisarlos y una lista de categorías con iconos y búsqueda. Solo se ofrecen categorías compatibles con toda la selección; con tipos incompatibles hay que cambiar la selección o disponer de una categoría compatible. El botón **Aplicar (N)** hace explícito cuántos registros se van a actualizar.

El cambio de categoría también está disponible para un movimiento deslizando su fila hacia la derecha. No exige que el movimiento tenga una incidencia pendiente.

La opción **Recordar para próximos movimientos** está desactivada inicialmente en esta hoja. Al activarla, se indica una frase que aparezca en todos los conceptos seleccionados. Si los títulos son iguales, se prepara esa frase automáticamente. Se crea o actualiza una regla por cada tipo seleccionado. No se modifica el historial no seleccionado. Las reglas se aplican por los mecanismos existentes de importación y sugerencias.

La categoría y las reglas se validan antes de escribir y se guardan juntas. Se preservan ID, fecha, tipo, importe, cuentas, texto, referencia bancaria, huella de deduplicación, estado de duplicado, asignación de reserva y vínculo periódico. Una categoría corregida no resuelve por sí sola un posible duplicado. Se rechazan selecciones vacías, repetidas, con elementos desaparecidos o con una categoría archivada/incompatible. Un fallo final de guardado revierte los cambios de la operación.

## Conceptos bancarios legibles · 0.6.10

`TransactionPresentation` genera un título de presentación a partir del texto guardado. En movimientos identificados como bancarios reconoce únicamente el prefijo observado `/TXT/D|` o `/TXT/H|`, sin inferir por esas letras el sentido del movimiento. Retira ese prefijo inicial y compacta espacios del cuerpo; no transforma mayúsculas, nombres, códigos desconocidos ni separadores internos. Si quedara vacío conserva el texto anterior.

Se utiliza en la lista y detalle de movimientos, comparaciones de revisión, movimientos recientes de cuentas y vistas previas de la descarga bancaria. El detalle muestra **Concepto guardado** y las vistas previas **Ver concepto del banco** cuando la presentación difiere. No se modifica `descriptionText`, el contrato de importación, los identificadores ni el cálculo de duplicados. Las búsquedas conservan el texto guardado y también consideran el título mostrado. Las copias y CSV mantienen el texto almacenado.

Los conceptos manuales y CSV sin identificación bancaria conservan su presentación. El texto conservado es el disponible en la app, no una copia de toda la respuesta del banco; una asociación con un movimiento manual puede conservar su descripción y una edición del usuario puede modificarla. El servidor ya limitaba el concepto recibido a 500 caracteres: esta mejora no recupera información que antes no se guardó.

## Comprobaciones de 0.6.10

Pasan las pruebas portables de títulos conocidos, códigos desconocidos, cuerpo vacío, texto manual, referencias sintéticas de sandbox y conservación del texto. Pasa la clasificación con el servicio real y un contexto de prueba: compatibilidad por tipo, selección inválida, frase común, conservación de datos financieros, aprendizaje por tipo, reutilización de reglas y comportamiento previo de las categorías comunes. El contexto portable no sustituye SwiftData.

El check financiero nativo incluye los nuevos casos con un ModelContainer en memoria y comprueba también que la huella real de duplicados no cambia. Su ejecución en macOS está pendiente del push. Pasan el análisis sintáctico Swift y la comprobación de referencias del proyecto/workflow; la compilación SwiftUI/SwiftData y la prueba visual en dispositivo siguen pendientes.

No hay tablas, columnas ni migraciones nuevas. Se usa la sincronización y las copias existentes para categorías y reglas. La incidencia de consulta de BBVA continúa pendiente y no se han hecho consultas bancarias nuevas para esta mejora. Esta entrega no incorpora un modelo de IA.

## Qué se detecta

- Movimientos marcados como posibles duplicados por la detección existente.
- Ingresos, gastos, intereses o comisiones sin categoría.
- Una categoría de ingresos usada para un gasto, o cualquier otra incompatibilidad entre tipo y categoría.

No se considera incidencia una categoría archivada que era válida para un movimiento histórico. Una transferencia puede estar correctamente registrada sin categoría adicional. Una categoría general como Otros gastos no se considera automáticamente incorrecta: esta primera versión no dispone de una señal fiable de que el usuario quiera revisarla.

Se cuenta una vez cada movimiento aunque tenga dos incidencias. El estado vacío dice que no hay incidencias detectadas con la selección actual; no afirma que cada registro haya sido revisado por una persona.

## Acciones rápidas

Al abrir un movimiento pendiente, **Por revisar** permite:

1. Elegir una categoría compatible en un menú con sus iconos, sin recorrer todo el formulario del movimiento.
2. Aplicar una sugerencia de las reglas existentes, explicando qué regla coincide. Usar una regla que ya existe no crea otra más específica.
3. Dejar activado **Recordar esta elección** para crear o actualizar una regla del mismo tipo. La frase se prepara con el título mostrado y puede acortarse al nombre del comercio; debe aparecer en el concepto. Puede desactivarse para un caso puntual. Aplicar una regla existente conserva su alcance y no crea una nueva.
4. Comparar hasta tres movimientos similares mostrando concepto, cuenta/banco, tipo, fecha e importe. Los importes respetan el control de privacidad.
5. Pulsar **Conservar: no es un duplicado** para retirar la marca de sospecha. Conserva los registros; no elimina automáticamente ninguno. Si sobra uno, se puede eliminar desde la lista de Movimientos.

Los cambios se guardan en el contexto actual. En modo cloud usan la sincronización existente. Si el guardado falla, se revierte el cambio de revisión y se explica el error.

## Conservación de decisiones

El formulario solo vuelve a calcular la sospecha de duplicado cuando cambian sus datos relevantes: fecha, cuentas, tipo, importe o descripción normalizada. Cambiar una nota, la categoría o la reserva no debe reabrir una sospecha que el usuario ya descartó.

Se conserva el significado independiente de Conciliado. La revisión de categoría no usa ese indicador como sustituto ni lo modifica. No se cambian importes, cuentas, asignaciones de reserva o tipos al elegir una categoría; el gasto pasa a la categoría que el usuario ha elegido.

## Persistencia y compatibilidad

Se usan las relaciones de categoría, las reglas y el estado de duplicado existentes. No se añade un formato de copia, una columna, una tabla ni una migración. Estas decisiones siguen formando parte de las copias y de la sincronización actuales. La lista de incidencias se calcula al mostrar los movimientos y desaparece al resolver sus causas.

## Comprobaciones

- `Tests/TransactionReviewCheck.swift`: categorías ausentes/incompatibles, historial con categorías archivadas, transferencias sin categoría, combinación de incidencias, conservación de financiación reservada y persistencia de la decisión sobre duplicados al editar datos no relevantes.
- La rama que comprueba las huellas reales usa CryptoKit y se ejecuta en el nuevo paso del workflow **Comprobar datos y cálculos** en macOS.
- Localmente se ejecutaron las pruebas de lógica con las declaraciones de modelos sin macros de SwiftData. Se comprobó sintaxis Swift, referencias del proyecto, plist, YAML y `git diff --check`. No sustituye a compilar la interfaz con el SDK de iOS.
- Los checks verdes del commit anterior corresponden a sincronización. Esta bandeja todavía no ha sido subida ni validada por GitHub Actions o instalada en el iPad.

## Prueba manual de la próxima compilación

1. En un espacio de pruebas, comprobar un posible duplicado junto a un movimiento sin categoría y otro ya clasificado.
2. Activar Por revisar, combinar filtros y restablecerlos. No perder resultados por un filtro invisible.
3. Asignar una categoría compatible y comprobar que desaparece la incidencia; repetir con una regla sugerida y con Recordar desactivado.
4. Conservar un posible duplicado y comprobar que no cambia el saldo ni desaparece el otro registro. Editar después solo su nota o categoría: no debe volver a marcarse por eso.
5. Probar claro/oscuro, texto de accesibilidad y ocultación de importes. Verificar copia/restauración y sincronización de las decisiones.

La detección de parejas de transferencias y la limpieza automática de conceptos se mantienen como trabajo posterior; esta versión no cambia tipos financieros por similitud.
