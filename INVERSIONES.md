# Efectivo e inversiones · 0.6.9

Actualizado el 3 de noviembre de 2026. Implementado en el código local; pendiente de compilación nativa y prueba en el dispositivo.

## Decisión de modelo

El usuario confirma que la cuenta denominada «Inversión + rentabilidad» contiene únicamente efectivo. El efectivo y el valor de la cartera se representan en cuentas distintas. La mejora es genérica para cualquier entidad; no contiene condiciones específicas por nombre de banco ni de cuenta.

El efectivo puede cubrir gastos y reservas. La cartera de tipo Inversión representa el valor invertido y queda fuera del cálculo de dinero disponible para gastar. Ambas cuentas pueden contribuir al patrimonio si tienen activada su inclusión. Una exclusión existente se conserva y se presenta con una acción para revisarla; no se cambian importes ni preferencias existentes al instalar esta versión.

## Implementado

Acceso desde **Cuentas → Efectivo e inversiones**, dentro de las herramientas de cuentas. Usa las filas y cuadrícula adaptables del sistema visual existente; no hay anchos fijos por dispositivo.

Por cartera se muestran:

- Valor registrado de la cartera y acceso a su detalle.
- Cuentas de efectivo de la misma entidad y moneda. Una entidad sin identificar no se interpreta como vínculo entre cuentas.
- Disponible del efectivo cuando hay reservas que lo diferencian del saldo total.
- Aviso y acceso de edición si la cartera está excluida del patrimonio.
- Aportaciones y retiradas realizadas durante el mes actual.
- Acciones para registrar una aportación/reinversión o una retirada, con tipo Transferencia y cuentas ya seleccionadas. Con varias cuentas de efectivo, se elige explícitamente cuál usar.
- Actualización de valoración mediante el formulario existente.

El estado vacío permite crear una cuenta con tipo Inversión preseleccionado. Las transferencias desde otra entidad siguen disponibles en Movimientos.

El formulario de una cartera habla de valor inicial y explica su separación del efectivo. La TAE y el interés anual estimado dejan de mostrarse en carteras de inversión; esos campos corresponden al efectivo remunerado, no a una estimación de rentabilidad de mercado.

El resumen de aportaciones de Inicio utiliza la misma función que este apartado y excluye movimientos futuros. Las transferencias entre dos carteras no se cuentan como nuevas aportaciones o retiradas de efectivo.

## Significado de los movimientos

Una aportación o reinversión traslada dinero del efectivo a la cartera. Una retirada hace el recorrido contrario. Ninguna se convierte en ingreso o gasto por ese traslado. Las aportaciones incluyen las reinversiones registradas como transferencias desde efectivo: todavía no se separa un origen externo de una reinversión mediante una etiqueta específica.

Los intereses o dividendos efectivamente cobrados se registran una sola vez como ingreso de efectivo. Si después se invierten, se registra la transferencia correspondiente; no se registra un segundo ingreso.

Una nueva valoración sustituye el valor anterior de esa cartera a su fecha. Los movimientos posteriores se aplican sobre ella. El saldo mostrado es el registrado en la app; no es una cotización bursátil en tiempo real. No se calcula el beneficio como si toda aportación fuera rentabilidad.

## Conservación de datos y límites

Se reutilizan cuentas, movimientos, entidades y valoraciones existentes. No hay campos nuevos, migración cloud ni cambios de contratos de copia. La inclusión en patrimonio y los vínculos bancarios existentes se conservan. La cuenta auxiliar de inversión que el usuario decidió no asociar continúa sin asociarse.

Este bloque no incorpora posiciones por instrumento, precios automáticos, rentabilidad porcentual, cálculo fiscal ni identificación automática de reinversiones. La representación de carteras agregadas sigue basándose en valoraciones registradas. Tampoco resuelve el fallo de consulta de BBVA, que permanece documentado aparte.

Si varias carteras comparten entidad, las mismas cuentas de efectivo pueden aparecer como opciones relacionadas en sus secciones; no se crea otro saldo ni se suma de nuevo al patrimonio por aparecer allí.

## Comprobaciones

Pasan las comprobaciones locales de cálculos con Swift 6.2.1 sobre Linux usando el calculador real y los modelos sin macros de persistencia: aportación, retirada, movimiento entre carteras, ingreso de intereses, reinversión sin segundo ingreso, exclusión de operaciones futuras, límites de mes y sustitución de valoraciones. También pasan los casos anteriores de reservas, presupuestos, disponible e historial incluidos en ese ejecutable.

Pasa el análisis sintáctico de las vistas modificadas. Se mantiene la prueba financiera nativa en GitHub Actions con los nuevos casos. La compilación SwiftUI/SwiftData requiere macOS; la ejecución local no la sustituye.

Pendiente: subir 0.6.9 (build 26), consultar sus checks, instalar y probar el acceso en iPhone/iPad, la selección de cuentas y el guardado/sincronización de una transferencia y una valoración. No se han modificado datos financieros del usuario durante la implementación.
