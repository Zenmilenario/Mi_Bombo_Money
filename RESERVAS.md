# Reservas entre cuentas · 0.6.8

Actualizado el 3 de noviembre de 2026.

## Implementado

Una reserva conserva un único objetivo y una cuenta inicial, pero puede distribuirse entre varias cuentas de efectivo. No se crean reservas mensuales duplicadas ni transferencias bancarias reales: se clasifica el historial contable de la app.

- Una transferencia propia puede llevar toda o parte de su importe como dinero de una reserva. Se elige en «Origen del dinero → Dinero que trasladas».
- Un gasto o comisión posterior puede consumir la reserva desde la cuenta de destino. Esa parte se excluye automáticamente del presupuesto; sigue siendo un gasto real.
- El formulario ofrece también reservas de otras cuentas. Al elegir una, busca una transferencia registrada, sin reserva asignada, hacia la cuenta pagadora, de la misma moneda y dentro de los 35 días anteriores. Solo propone el importe necesario y valida que no comprometa pagos o traslados futuros.
- Una única candidata válida se prepara automáticamente y se explica antes de guardar. Si hay varias, el usuario escoge en el mismo formulario. Si falta la transferencia o no cubre la parte solicitada, hay que registrar o corregir su vínculo; no se inventa otra transferencia.
- El enlace y el pago se guardan juntos. El plan no modifica objetos al mostrar la sugerencia. Se conserva el origen, la clasificación, la reserva y la trazabilidad bancaria existentes.
- Editar un pago libera su asignación anterior antes de validar. Borrarlo deja el dinero todavía reservado en la cuenta receptora. No se puede borrar o reducir un traslado que dejaría pagos posteriores sin cobertura.
- «Dinero reservado» indica las cuentas en las que sigue quedando reserva. La cuenta inicial no se cambia después de tener movimientos vinculados.

## Ejemplo sintético

La cuenta A tiene 1.000 €, de los que 600 € están reservados; la cuenta B tiene 100 € libres. El disponible conjunto es 500 €.

Se transfieren 200 € de A a B vinculados a la reserva: quedan 400 € reservados en A y 200 € en B. La reserva total sigue siendo de 600 € y el disponible conjunto sigue en 500 €.

Un pago de 200 € desde B con esa reserva deja 400 € reservados en A y ninguno en B. El disponible sigue siendo 500 €. El pago figura como gasto real de 200 €, con 0 € de gasto presupuestario. Si el pago fuera de 250 € y solo 200 € estuvieran cubiertos, el presupuesto y el disponible se reducirían en los otros 50 €.

## Corregir un pago ya existente

1. Editar el gasto y elegir la reserva en «Pagar con».
2. Revisar el mensaje de la transferencia preparada, o escoger una si hay varias candidatas válidas.
3. Guardar. La app vincula la parte necesaria de esa transferencia y el pago en una sola operación.

Si no se encuentra ninguna candidata, editar la transferencia propia correspondiente, seleccionar la reserva en «Dinero que trasladas» y guardar. Después se puede seleccionar esa misma reserva en el gasto. No borrar saldos, historial ni reservas para corregirlo.

## Persistencia y nube

Se reutilizan `reservedFundID` y `reservedAmountMinor` de `FinancialTransaction` en los tipos `expense`, `fee` y `transfer`. La reserva guarda financiación total, incluidos pagos pasados y comprometidos; no se decrementa destructivamente.

`ReservedLedger` es una lógica de valores compartida entre cálculos, validación de copias JSON y revisión del grafo cloud. Se comprueban los importes por cuenta y fecha; las transferencias con la misma marca temporal se recorren antes de los pagos, respetando la disponibilidad del origen y un orden estable por UUID. No se financian ciclos vacíos. Conviene registrar horas distintas si un recorrido circular complejo necesita un orden concreto.

Las copias v2 mantienen los campos y aceptan copias anteriores. Actualizar todos los clientes antes de usar traslados con reserva: versiones antiguas rechazan esa relación durante su validación.

La migración `20261103000100_reserved_fund_transfers.sql` se aplicó al proyecto cloud existente. Las claves siguen incluyendo propietario y espacio; no se amplían permisos. La comprobación remota de estructura confirmó los nuevos controles y las 14 tablas con RLS habilitado y forzado. No se modificaron filas financieras personales para la prueba.

## Prueba física en iPad · 3 de noviembre de 2026

El usuario confirma que tiene la versión 0.6.8 instalada. La reserva ya aparece al editar el cobro desde la cuenta de destino y confirma una mejora en la coherencia de los importes tras revisar reserva, disponible y presupuesto. Se considera comprobado el recorrido principal en ese dispositivo, sin registrar importes ni conceptos personales.

Esta confirmación no equivale a una auditoría de todos los saldos ni a la validación de todos los casos límite. Quedan por comprobar la propagación cloud de este caso y su recuperación desde copia; los resultados nativos de GitHub Actions no se han consultado de nuevo en esta sesión.

## Verificado y pendiente

Verificado localmente:

- Cálculos reales de la app en Swift 6.2.1 sobre Linux, retirando únicamente las macros de persistencia y las dependencias visuales para este ejecutable: traslado, pago, pago parcial, destino sin financiación, cronología, compromisos futuros, ambigüedad y elección de transferencia; también los cálculos de reservas, presupuestos, historial y avisos anteriores.
- Tipos y validación reales de copias: ida y vuelta JSON, aceptación del traslado seguido de pago y rechazo de pagos sin transferencia o anteriores a ella. La prueba nativa adicional cubre restauración con SwiftData en Actions.
- Combinación de datos cloud: grafo válido, rechazo sin traslado y conflicto cuando otro dispositivo elimina una transferencia necesaria.
- 28 pruebas sobre PostgreSQL 18 local desechable: aislamiento, permisos, concurrencia, integridad, historial por cuenta, monedas y restauración de un JSON cuyo pago aparece antes de su transferencia. GitHub ejecuta este conjunto en PostgreSQL 17.
- Análisis sintáctico Swift de los formularios y pruebas modificadas; revisión de referencias del proyecto y fuentes de los workflows.

La versión 0.6.8 (build 25) ya está instalada y su recorrido principal de reservas ha sido comprobado por el usuario en un iPad. Pendiente: consultar los checks nativos del commit instalado y comprobar propagación cloud y recuperación de este caso. Las pruebas de Linux no sustituyen SwiftUI, SwiftData ni el SDK de Apple. No se promete asociación automática de cualquier pago por concepto, ni se ha añadido una regla personal para un banco o un objetivo concreto.
