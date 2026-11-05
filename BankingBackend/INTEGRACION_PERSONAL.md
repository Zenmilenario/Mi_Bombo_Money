# Conexión bancaria personal · versión 0.6.2

## Correcciones contables aprendidas — iOS 0.6.17 (34)

Preparado localmente el 5 de noviembre. Guardar una corrección de tipo, categoría y destino de un apunte bancario alimenta un modelo supervisado kNN por perfil. Puede aplicar categorías y transformar un gasto nuevo en una transferencia a inversión del mismo importe y moneda, conservando su referencia bancaria. Necesita ejemplos humanos de varios periodos y superar comprobaciones temporales; con datos ambiguos se abstiene. No hay reglas específicas para importes de una persona ni cambios en el parser o el servidor en esta entrega.

El detalle muestra las acciones automáticas, permite deshacerlas y pausar la automatización. No se usan las predicciones como ejemplos humanos. Se excluyen reservas, cargos periódicos, categorías ya elegidas y posibles contrapartidas; no se crea la recompensa de Saveback ni su retención, no se emparejan automáticamente dos cuentas conectadas y no se modifican consultas bancarias. Los cambios financieros siguen la sincronización cloud existente; el aprendizaje y el historial para deshacer son locales. Los registros anteriores al inicio del aprendizaje se revisan manualmente.

Las pruebas locales del núcleo y del adaptador con sustitutos pasan; SwiftData real y compilación iOS quedan pendientes de GitHub, además de probarlo físicamente. Condiciones precisas, almacenamiento y límites en [aprendizaje de categorías y correcciones](../CloudBackend/APRENDIZAJE_CATEGORIAS.md).

## Descargas de BBVA y Trade Republic — 4 de noviembre de 2026

Las dos conexiones aparecen autorizadas y asociadas en el iPad. El servidor personal respondió correctamente a la comprobación de salud. El registro de Enable Banking del 4 de noviembre a las 13:48:19, hora de Madrid, muestra una sesión de BBVA autorizada y una petición de token a Redsys con HTTP 200. La consulta de movimientos falló en Redsys con HTTP 500, `INTERNAL_SERVER_ERROR` y el mensaje `Service temporary unavailable for BBVA`. Enable Banking devolvió HTTP 400 con `ASPSP_ERROR` a nuestro servidor.

El registro confirma que esa descarga falló antes de que la app recibiera movimientos. No permite determinar si la incidencia fue general ni si sigue activa. No hay indicios en esa consulta de que sea necesario volver a autorizar la cuenta o cambiar el importador. Si vuelve a fallar tras esperar, revisar la nueva petición y facilitar a soporte de Enable Banking su identificador de solicitud por un canal privado. Véase la [guía de errores de Enable Banking](https://enablebanking.com/docs/faq/).

En la consulta manual de Trade Republic de las 13:47, hora de Madrid, el diagnóstico registró `amount_format` en los movimientos. El aviso se produce al convertir el importe. La falta de descripción está contemplada y se presenta como «Movimiento bancario». [Datos de Trade Republic en Enable Banking](https://enablebanking.com/docs/markets/de/#trade-republic).

Tras aceptar importes expresados con más de dos decimales si los dígitos adicionales son ceros, la segunda prueba de Trade Republic llegó al rechazo `amount_sign`. El servidor personal ejecuta la versión `ac687d0d-9730-4868-b30c-97fb6021f30d`. Esta versión normaliza los débitos tanto si llegan con signo negativo como si llegan en magnitud positiva. Un abono marcado como tal con importe negativo sigue siendo incompatible. La conversión conserva los céntimos exactos. Las 47 pruebas del servidor pasaron. Tras desplegar el ajuste, la consulta manual de Trade Republic devolvió HTTP 200 y el usuario confirmó que el aviso desapareció. La incorporación de los movimientos al registro contable queda por confirmar. [Formato y sentido de los importes en la API](https://enablebanking.com/docs/api/reference/#amounttype).

### Incorporación de Trade Republic en iOS 0.6.14

A las 14:11 el iPad mostraba 100 movimientos recibidos y un rechazo al preparar la importación. La pantalla anterior agrupaba varios fallos bajo el mismo aviso. La falta de referencia es un caso compatible con los datos que documenta el proveedor y que el importador anterior rechazaba. [Datos que entrega Trade Republic mediante Enable Banking](https://enablebanking.com/docs/markets/de/#trade-republic).

En 0.6.14, para un apunte de Trade Republic sin referencia ni datos de emparejamiento se construye una clave local por cuenta, fecha, moneda, importe con signo y número de aparición en la descarga completa. Dos apuntes idénticos conservan claves distintas. Otra descarga con los mismos apuntes los reconoce aunque cambie el orden. La clave cuenta apariciones de apuntes indistinguibles y no representa un identificador del banco. Los apuntes nuevos con clave local pasan por confirmación y las coincidencias con registros manuales requieren una decisión. El saldo contable en euros sigue siendo obligatorio y ahora tiene un aviso específico.

La prueba del plan de importación pasó en Swift sobre Linux con apuntes ficticios, incluidos débitos iguales, abonos del mismo importe, una descarga reordenada y el rechazo de un saldo no contable. Queda pendiente validar la compilación iOS y repetir «Actualizar solo Trade Republic» en el iPad. Si aparece «Revisar descarga bancaria», comprobar fecha, importe y posibles coincidencias, confirmar el lote y verificar en Movimientos que otra consulta no vuelve a añadirlo.

**Prueba posterior en el iPad, 14:35.** La descarga llegó y la app la rechazó al validar el saldo, antes de revisar las referencias de los movimientos. El código exige un único saldo contable válido en EUR. Prefiere el saldo contable intradía (`ITBD`) y recurre al de cierre (`CLBD`) cuando falta el primero. El aviso cubre tanto la ausencia como la ambigüedad o un importe fuera de rango. La captura no identifica cuál de estos casos se produjo. [Tipos de saldo en Enable Banking](https://enablebanking.com/docs/api/reference/#balancestatus).

### Adaptador de Trade Republic en iOS 0.6.15

El adaptador interpreta la respuesta de Trade Republic antes de construir el plan de importación. Conserva las claves locales de los apuntes sin referencia que ya generaba la 0.6.14. Acepta un saldo contable válido y agrupa sus repeticiones cuando el importe es idéntico. Si recibe únicamente saldo disponible, saldos contables contradictorios o ningún saldo utilizable, prepara los movimientos para revisión sin registrar un saldo bancario nuevo. En «Tipos de saldo recibidos» se muestran códigos conocidos, EUR u otra moneda y sus recuentos. [Tipos de saldo en Enable Banking](https://enablebanking.com/docs/api/reference/#balancestatus).

La revisión muestra el saldo calculado antes y después de las decisiones de conciliación. Usa la última valoración guardada o el saldo inicial. Si todavía no hay valoración, se puede introducir un saldo de cierre manual con fecha. Los apuntes que preceden a esa referencia se guardan en el historial y solo los posteriores modifican el saldo a partir de ella. La app comprueba de nuevo la vista previa al confirmar y guarda los movimientos y el saldo manual en la misma operación.

Queda pendiente compilar en iOS y probar «Actualizar solo Trade Republic» con la conexión real. Comprobar los tipos de saldo que llegan en esa descarga, resolver coincidencias, confirmar y repetir la consulta para comprobar que no se duplican los apuntes. El tipo recibido en la prueba de las 14:35 sigue sin confirmar.

### Reconocimiento general de aportaciones fraccionadas — iOS 0.6.16

El usuario confirma que actualmente aporta 400 € mediante dos cargos de 200 € y solicita reconocimiento general. La implementación usa la plantilla periódica de cada usuario, su cuenta de origen, destino de inversión, moneda, frecuencia e intervalo. Admite frecuencias semanales, mensuales, trimestrales y anuales. Los periodos se alinean con la semana o el mes de la próxima fecha programada y abarcan el intervalo configurado.

En Movimientos aparece «Reconocer aportaciones a inversión». Cuando hay candidatos completos, muestra el número de propuestas pendientes. La detección se recalcula al cambiar los datos locales, incluidos los movimientos recibidos mediante importación o sincronización. Busca una combinación de uno o varios cargos bancarios que complete el importe previsto tras descontar las transferencias ya registradas al mismo destino en ese periodo. Se excluyen cargos con reserva, vínculo periódico previo o posible duplicado.

Una combinación única se presenta seleccionada. Si existen varias combinaciones, el usuario elige los cargos. La confirmación convierte esos mismos cargos en transferencias y los relaciona con la plantilla. Conserva identificadores, importes, fechas, conceptos, referencias bancarias y notas. Si hay una previsión generada por esa plantilla, se muestra antes de confirmar y se sustituye por los cargos reales. Sus notas se incorporan a los cargos. La operación se guarda de forma atómica y vuelve a comprobar que las cuentas, movimientos y previsión coinciden con la revisión.

Las aportaciones reconocidas pasan al resumen de inversión y dejan de computar como gastos de consumo. La siguiente consulta bancaria reconoce sus referencias ya guardadas. Si se desconecta el banco y vuelve a activarse el registro periódico, el generador comprueba las partes bancarias confirmadas de ese periodo antes de generar otra aportación. El enlace `recurringMovementID` ya forma parte de la copia de seguridad y la sincronización cloud. El reconocedor usa búsqueda acotada de combinaciones exactas y requiere confirmación del destino. Trade Republic puede entregar únicamente importe y fecha, de modo que una coincidencia numérica no verifica por sí sola la finalidad del pago.

Pasaron localmente las pruebas Swift del plan, con repartos iguales y diferentes, combinaciones ambiguas y límites de búsqueda. También se ejecutó el código de reconocimiento con los tipos de modelo de producción y una simulación de almacenamiento, cubriendo sustitución de la previsión, conservación de referencias, repetición y las cuatro frecuencias. Esta simulación comprueba además la supresión de otra aportación tras reactivar el registro periódico.

Pendiente compilar y probar la interfaz en iOS con los datos reales del usuario. Comprobar una propuesta de varios cargos, su reflejo en inversión y presupuesto, y repetir la descarga para verificar que no reaparece como gasto. La prueba con persistencia SwiftData está incluida en el check macOS de importación bancaria.

### Round up y Saveback — investigación del 5 de noviembre de 2026

**Round up.** Trade Republic redondea el pago autorizado al euro superior y permite multiplicar la diferencia por 2, 3, 5 o 10. El importe sale del saldo del usuario, se acumula y se invierte en las fechas de ejecución del servicio. Su documentación indica que el redondeo puede mantenerse aunque el pago se cancele después. Una compra de 2,50 € con multiplicador 2 genera 1 € de redondeo. [Funcionamiento de Round up](https://support.traderepublic.com/es-es/2905-Was-ist-Round-up).

**Saveback.** Es una recompensa sobre pagos elegibles que se invierte en el plan elegido, condicionada a cumplir los requisitos del servicio. La ayuda española consultada distingue un 1 % por pagos con efectivo y un 2 % con crypto. Conviene registrar la recompensa al recibirla o ejecutarse la inversión, una vez cumplidas las condiciones. [Funcionamiento de Saveback](https://support.traderepublic.com/es-es/2810-What-is-Saveback).

**Tratamiento propuesto, pendiente de implementar.** Conservar el gasto original de la tarjeta. Clasificar el redondeo como traslado del efectivo propio hacia inversión y mostrarlo como aportación adicional por redondeo. Saveback se registra como recompensa recibida en inversión si llega directamente allí. Si el extracto muestra un abono en efectivo y la inversión posterior, vincular ambos movimientos y separar el origen de la recompensa de una aportación de dinero propio. El efecto neto sobre el efectivo de esos dos apuntes debe ser cero.

Separar en el resumen las aportaciones periódicas, los redondeos y las recompensas. Excluir redondeos y Saveback identificados de las combinaciones que intentan completar la aportación periódica prevista. Si aparecen retención del redondeo y ejecución posterior, enlazar las etapas para evitar contabilizar dos aportaciones.

**Información pendiente.** Confirmar si los conceptos importados identifican Round up o Saveback. Después comprobar un ejemplo de cada flujo, incluidos posibles abonos compensatorios. El proveedor puede entregar solo fecha e importe. Esos dos campos no permiten atribuir automáticamente un cargo a una recompensa o a un redondeo. El parser podrá usar etiquetas explícitas cuando existan y conservar una propuesta de revisión cuando falten. Esta investigación no modifica movimientos guardados.

**Comprobación en Supabase, 5 de noviembre.** Consulta de solo lectura sobre movimientos activos de cuentas asociadas a Trade Republic, con uniones por propietario y espacio. La mayoría de los apuntes asociados a referencias bancarias conserva el texto genérico «Movimiento bancario». No se encontraron las etiquetas Round up ni Saveback, incluidas variantes con espacios o guiones, en los conceptos guardados. Otros registros conservan descripciones del usuario después de conciliarse, como establece el importador. La limpieza visual conserva el texto almacenado. El servidor genera el concepto genérico cuando faltan remesas descriptivas y nombres de contraparte. El historial consultado en Enable Banking muestra el éxito de la descarga, pero no ofrece el cuerpo de esa respuesta exitosa.

Con estos registros queda pendiente identificar un ejemplo mediante información adicional del banco. Para automatizar la clasificación de beneficios hará falta un identificador o dato descriptivo verificable de la respuesta, o enlazar un extracto que distinga los beneficios. La coincidencia de fecha e importe puede preparar candidatos, pero no demuestra que un apunte sea Saveback o Round up. No se reclasificaron movimientos durante esta comprobación.

**Comprobación directa anterior al parser, 5 de noviembre.** Se verificó la sesión autorizada de Trade Republic y se consultó el endpoint de movimientos de Enable Banking con la clave local de la aplicación personal. Se hicieron dos lecturas del mismo intervalo para completar el inventario de campos. La respuesta contiene 100 apuntes y no indica continuación pendiente. En todos ellos solo están informados el importe con moneda, el sentido del movimiento, el estado y la fecha contable. Concepto, contrapartes, referencias, identificador de transacción, códigos de operación, categoría de comercio, notas y demás campos adicionales están vacíos. La búsqueda en las cadenas de la respuesta no encontró Round up, Saveback, redondeo ni cashback.

El diagnóstico inspeccionó la respuesta de Enable Banking en memoria antes de llamar al normalizador de la app. Su salida contiene únicamente nombres de campos y recuentos. Los cuerpos financieros y la clave privada no se guardaron en el diagnóstico ni en estas notas. Esta lectura confirma que los campos vacíos preceden a nuestro parser en la descarga comprobada. Coincide con la [limitación publicada por Enable Banking para Trade Republic](https://enablebanking.com/docs/markets/de/#trade-republic).

La identificación fiable de cada beneficio sigue requiriendo enriquecer los apuntes con una fuente que detalle su finalidad o disponer de nuevos campos descriptivos del proveedor. La comprobación directa queda terminada para el intervalo consultado. La clasificación de Round up y Saveback continúa pendiente de esa información.

**Revisión de capturas y propuesta, 5 de noviembre.** Las imágenes aportadas identifican nueve ejecuciones distintas de Round up y cuatro de Saveback. Las vistas de lista, sus detalles y una imagen repetida representan los mismos eventos y no deben multiplicar los ejemplos de entrenamiento. Las capturas de Saveback distinguen recompensa bruta, impuestos deducidos y neto invertido. No se reproducen las imágenes ni el historial financiero en esta documentación. Las etiquetas visuales todavía no se han vinculado individualmente con los apuntes descargados.

Las fechas observadas son compatibles con el calendario del producto: Round up los días 2, 9, 16 y 23, con desplazamiento al siguiente día laborable; Saveback el día 2 del mes siguiente o el siguiente hábil. La actividad de tarjeta genera acumulación y el calendario determina la ejecución; no se debe confundir esta coincidencia con la aportación periódica del usuario. [Calendario de Saveback](https://support.traderepublic.com/es-es/3050-Was-ist-Saveback).

No se limitará el reconocimiento a compras presenciales: la tarjeta admite compras online con estos beneficios. Deben respetarse las exclusiones del producto, entre ellas pagos por PayPal para Saveback, sin extrapolarlas a todos los comercios online. [Comunicación oficial de la tarjeta](https://assets.traderepublic.com/assets/files/240109_TradeRepublic_PressRelease_Card_INT_EN1.pdf), [exclusiones actuales de Saveback](https://support.traderepublic.com/es-es/1637-Why-did-I-not-receive-my-Saveback).

**Criterio contable propuesto.** El redondeo reduce efectivo utilizable y pasa dinero propio a inversión; no es consumo ni reduce el patrimonio conjunto por ese traslado. Saveback aumenta la inversión con una recompensa neta, sin consumir por ese hecho efectivo propio. Si el extracto incluye recompensa bruta, retención e inversión neta, conciliar las tres etapas; si solo acredita el neto directamente en valores, no inventar un cargo al efectivo. Conservar la retención real como dato separado cuando esté disponible, sin fijar un porcentaje fiscal para todos los usuarios. No descontar de nuevo una cantidad de Round up ya apartada al autorizar la compra. Separar aportación periódica, redondeos y recompensa; mantener el gasto original de tarjeta una sola vez. La representación del patrimonio en la app depende además de qué cuentas estén incluidas en ese cálculo.

**IA pendiente.** El modelo implementado es una regresión logística multiclase sobre texto que propone categorías de ingresos y gastos; no identifica estos flujos. Se propone una etapa de reconocimiento del tipo de operación antes de categorizar consumo, con ejemplos confirmados y señales de fecha, importe, sentido y contexto disponible. El importe pequeño o el día de ejecución no acreditan por sí solos un beneficio. La extracción local de etiquetas de capturas o documentos mediante OCR puede aportar evidencia explícita y preparar enlaces por fecha e importe, confirmados solo si la correspondencia es inequívoca. OCR es extracción de evidencia y no sustituye al clasificador aprendido.

Los trece eventos etiquetados son una semilla, no una validación de exactitud ni de generalización. Separar entrenamiento y evaluación por periodos; mantener todas las representaciones del mismo evento en el mismo conjunto; incluir compras pequeñas, aportaciones ordinarias y comisiones como casos negativos. Medir precisión y cobertura por tipo y permitir abstención. No activar cambios contables automáticos solo por una puntuación del modelo sin validar. Esta investigación no entrena un modelo nuevo, no reclasifica movimientos ni cambia el esquema cloud. Véase [aprendizaje de categorías](../CloudBackend/APRENDIZAJE_CATEGORIAS.md).

**Configuración declarada por el usuario, 5 de noviembre.** Saveback al 1 % y Round up con multiplicador 1×. Para el diseño, tratarlos como parámetros por tarjeta con vigencia y procedencia, no como constantes del modelo ni como una configuración histórica demostrada. El porcentaje se contrasta con la recompensa bruta; la retención explica la diferencia con el neto invertido. La fórmula del redondeo y la conciliación son cálculos deterministas; la IA propone la identidad de los apuntes cuando faltan etiquetas. Sin el conjunto de autorizaciones elegibles, los periodos completos y la información de reversos o ajustes, no exigir igualdad con una suma reconstruida desde capturas parciales. Esta configuración se documenta como información aportada, sin afirmar que esté guardada ya en la app.

**Actualización de implementación, 5 de noviembre — preparada localmente en 0.6.16.** Ya existe el modelo aprendido de tipos de operación y su tarjeta de revisión en el detalle de movimientos bancarios. Reconoce propuestas de Round up, Saveback y aportación a inversión, admite correcciones y abstención, y permite guardar porcentaje bruto, multiplicador y fecha de vigencia por cuenta. La confirmación es una etiqueta de aprendizaje local, no un cambio financiero. No altera gastos, presupuestos ni saldos y no debe interpretarse como una conciliación terminada. No se han insertado las capturas privadas en el código ni vinculado sus eventos automáticamente a los apuntes. OCR, conciliación de recompensa/retención/inversión y sincronización de etiquetas siguen pendientes. Alcance y comprobaciones en [aprendizaje de categorías y operaciones](../CloudBackend/APRENDIZAJE_CATEGORIAS.md).

## Consulta BBVA pendiente tras probar 0.6.8 — 3 de noviembre de 2026

El usuario comunica el aviso de que el banco o proveedor no ha podido completar la consulta al actualizar BBVA. Revisión rápida, sin pedir nuevos movimientos: `/health` respondió 200 y estado saludable; `/v1/status` sin autenticación respondió 401, como corresponde. El despliegue personal activo sigue siendo `937c0048-3e11-48f9-956f-7385a1771c99`. Pasaron las dos pruebas específicas de clasificación segura de errores del proveedor y de errores de saldos.

Ese texto corresponde a `bank_unavailable`, que el backend produce al recibir una respuesta fallida de Enable Banking con `ASPSP_ERROR` o un código no reconocido. Apunta a un fallo en la respuesta externa, pero no permite atribuir la causa definitiva al banco/proveedor ni descartar un rechazo por alguna característica de la petición. No se capturó el código exacto del intento comunicado. El servidor no presenta una caída en esta comprobación; la incorporación bancaria real continúa pendiente. No se modificaron despliegues, credenciales, conexiones ni datos.

Por indicación del usuario, aparcar esta prueba si la revisión rápida no revela un fallo propio. Para retomarla, capturar una única consulta manual con diagnóstico filtrado y respetar cualquier espera comunicada.

## Preparar y mostrar la descarga al conectar — 0.6.7

Actualizado el 3 de noviembre de 2026. Cliente 0.6.7 (24) preparado localmente; pendiente de checks iOS y prueba física.

### Diagnóstico y alcance

El usuario confirma que en la 0.6.6 las cuentas aparecen conectadas, pero no ve los movimientos que antes se presentaban entre las conexiones y el catálogo. La referencia inicial a Cuentas se ha aclarado: no es un problema visual ni una petición de cambiar sus saldos.

Se han consultado únicamente recuentos en Supabase y en la base del servidor bancario. Los registros contables siguen guardados y las sesiones de producción constan sin caducar; en la consulta de recuentos no había movimientos con referencia de importación bancaria. No se han exportado importes, conceptos, identificadores personales ni credenciales, ni modificado datos remotos. Esto no demuestra que la próxima consulta del banco tenga éxito: todavía debe probarse la descarga con el cliente corregido.

La revisión del código detecta que el retorno de autorización refrescaba metadatos, pero no solicitaba directamente los movimientos. La asociación de cuenta tampoco iniciaba una descarga: ambos dependían de un ciclo automático posterior. La espera heredada podía suprimir también la acción manual. Asimismo, un fallo del catálogo impedía publicar las conexiones recibidas, y una reinstalación sin preferencia del servidor dejaba la descarga sin empezar aunque su origen personal ya esté fijado y validado en la app.

### Correcciones implementadas

- Tras terminar la autorización se invoca un flujo explícito de refresco de conexiones y descarga manual del banco elegido. Tras asociar una cuenta, se hace al cerrar la hoja de asociación. Cancelar esa hoja no inicia una descarga.
- El coordinador reserva esa operación para que la comprobación automática no consuma la acción manual durante el retorno del navegador. Se conservan las revisiones pendientes y se indica si es necesario terminarlas antes de reemplazar una consulta.
- Se usa el origen personal HTTPS ya permitido cuando no existe una preferencia local guardada. Se mantienen la comprobación de identidad cloud y el propietario único del servidor.
- La disponibilidad del catálogo de bancos no bloquea la lectura de las conexiones existentes. Su error se comunica por separado.
- Las restricciones de actualización automática y manual se distinguen y se conservan por banco. Las esperas antiguas que no identifican el tipo de consulta continúan aplicándose a las automáticas, permitiendo que una acción manual explícita sea evaluada por el banco con contexto PSU. Si el banco rechaza también la consulta manual, se respeta su Retry-After para los nuevos intentos manuales. No se simula presencia del usuario en consultas automáticas.
- Se recuerda cuándo se descargó e incorporó una consulta y si quedó revisión pendiente. Tras reiniciar no se presenta como pendiente de conectar un banco cuya descarga ya se incorporó; una revisión perdida al cerrar puede recuperarse actualizando explícitamente ese banco.
- La sección de revisión conserva su ubicación entre conexiones y catálogo. El ancla de desplazamiento pasa a una fila, en vez de envolver la sección completa. Los movimientos nuevos y decisiones preparadas se muestran expandidos de inicio.
- La primera descarga sigue requiriendo «Incorporar descarga revisada». Conectar o autorizar no sustituye esa confirmación ni mezcla registros manuales con bancarios sin conciliarlos.

La cuenta auxiliar de inversión que el usuario mantiene sin asociar no se solicita ni se incorpora. No se han cambiado el diseño de Cuentas, los modelos contables, el protocolo de sincronización cloud ni los cálculos financieros en esta revisión.

### Verificación

Pasan localmente tres suites Swift: política de conexión/esperas, planificación/transferencias y ejecución del coordinador real con transporte y modelos sintéticos. Casos nuevos: retorno de autorización/asociación, ausencia de configuración local, catálogo no disponible, cuenta auxiliar excluida, recuperación de estado tras reiniciar, espera heredada, distinción manual/automática y retorno de autorización concurrente con otra descarga. Pasan el análisis sintáctico de la vista modificada y la revisión de espacios de Git. No se han realizado consultas nuevas a movimientos bancarios reales para estas pruebas.

Referencia para la distinción de consultas manuales y automáticas: [FAQ oficial de Enable Banking, cabeceras PSU y límites](https://enablebanking.com/docs/faq/#what-are-the-psu-headers-in-the-endpoints-for-fetching-account-details-balances-and-transactions-used-for).

### Pendiente de comprobación en iPad

Publicar 0.6.7 con GitHub Desktop y esperar los checks de macOS/iOS. Instalarla, abrir Mis bancos y pulsar una vez «Actualizar solo BBVA» usando la conexión existente. Comprobar si aparece la revisión; si se prepara correctamente, confirmar su incorporación y buscar los movimientos en la pestaña Movimientos. Si el proveedor limita también la consulta manual, copiar el aviso y respetar ese plazo. No borrar datos, recrear cuentas, renovar permisos sin necesidad ni asociar la cuenta auxiliar para esta prueba.


## Descargas y esperas independientes por banco — 0.6.6

Actualizado el 3 de noviembre de 2026. Preparado localmente; pendiente de checks macOS/iOS e instalación.

### Problema confirmado en la prueba física

La 0.6.5 mostraba un límite de consultas de Bankinter. Aunque BBVA estaba asociada, la app reunía todos los bancos en una descarga que fallaba completa si uno respondía con error. Además, se conservaba una espera global, que impedía solicitar BBVA por separado. Esto explica que no se incorporase la descarga conjunta; no demuestra que el cargo concreto esperado falte en la respuesta del proveedor. No hay evidencia de un bloqueo de acceso a la banca del usuario.

### Implementado en 0.6.6, compilación 23

- Descarga de todas las páginas de cada banco por separado. Un error de consulta de un banco se muestra en ese banco y no descarta las descargas completas de los demás.
- Plazos de actualización y restricciones 429 guardados por banco y usuario. Reiniciar, comprobar el servidor o renovar una conexión no salta una restricción vigente. Las comprobaciones de sincronización cloud no generan nuevas consultas bancarias continuas.
- Botón «Actualizar solo [banco]», estado de descarga y fecha del próximo intento por banco.
- Acceso directo a «Revisar e incorporar la descarga recibida». La primera descarga sigue sin escribirse hasta confirmarla. Solicitar otro banco no borra una revisión pendiente; se puede descartar la descarga expresamente sin modificar la contabilidad guardada.
- Los apuntes identificados como transferencias entre cuentas propias conocidas se incorporan juntos cuando ambas partes son compatibles. Si falta o es ambigua la otra parte, solo esos apuntes se difieren: no se convierten en gasto/ingreso ni bloquean las compras normales del banco disponible. Se muestra su número pendiente. Al recuperar las dos partes, se incorpora una sola transferencia y los gastos ya importados no se repiten.
- Se conserva el saldo contable real entregado por el banco disponible; no se inventa un saldo excluyendo los apuntes diferidos. Los bancos que no hayan podido actualizarse conservan sus datos anteriores, por lo que el conjunto puede tener fechas de actualización distintas.

### Espera heredada de la 0.6.5

La versión anterior no guardaba a qué banco pertenecía su espera global. Al migrar se conserva esa restricción para los bancos conocidos hasta que venza, sin adivinar su procedencia ni borrarla para forzar consultas. Es una limitación transitoria: las nuevas esperas sí se registran por banco. No se ha modificado la espera real del dispositivo desde este ordenador.

### Alcance y límites

La selección de transferencias se apoya en la identidad de cuentas conocidas, referencia bancaria, importe, moneda y fecha. No se adivina una transferencia entre apuntes ambiguos. Los apuntes diferidos se vuelven a consultar en futuras descargas dentro del histórico disponible; esta revisión no añade una cola persistente de respuestas bancarias completas. Si la otra parte no llega o carece de referencias compatibles, seguirá requiriendo revisión. No se han cambiado modelos cloud ni aplicado migraciones ni modificado la contabilidad personal del usuario.

El cliente continúa solicitando movimientos contabilizados (BOOK). Una operación pendiente en la banca puede no llegar aún a esta consulta. No se ha consultado el movimiento concreto del usuario para atribuirle ese estado.

### Validación

Comprobadas localmente tres suites Swift: política de conexión y espera por banco; planificación/descarga independiente y selección de transferencias; y ejecución del coordinador real con modelos y transporte de prueba. Se reproducen Bankinter limitado y BBVA disponible, el caso inverso, reinicio, espera persistente, migración conservadora, primera descarga sin confirmar, descarte y recuperación sin duplicados. Las pruebas usan únicamente datos sintéticos y no solicitan movimientos reales.

Se ha ampliado el check de SwiftData para comprobar incorporación parcial de gastos, ausencia de ingresos ficticios, saldo tras recuperar ambos bancos e idempotencia; su ejecución real requiere macOS y está pendiente. El workflow incluye ahora el check del coordinador. Pasan la validación de YAML/rutas, el análisis sintáctico de Swift y la revisión de espacios de Git. La compilación nativa iOS y la validación visual del iPad quedan pendientes de publicar e instalar 0.6.6.

### Cuenta auxiliar de inversión: decisión del propietario

El propietario mantiene sin asociar por ahora una cuenta auxiliar de efectivo ligada a valores. Se registra para diseñar más adelante su visibilidad y tratamiento junto a la cartera, evitando duplicar patrimonio. Esta cuenta no se descarga mientras no esté asociada y no debe bloquear la incorporación de gastos ordinarios de las cuentas seleccionadas. La selección/ocultación explícita de cuentas auxiliares queda pendiente; no se ha asociado ninguna cuenta adicional.

### Siguiente prueba física

Publicar con GitHub Desktop, esperar los checks e instalar el IPA 0.6.6. Respetar la espera anterior si sigue vigente. Actualizar solo BBVA, revisar e incorporar la descarga y buscar el cargo esperado en la cuenta asociada. Comprobar que el estado de Bankinter sigue separado. Confirmar después la recuperación de Bankinter y la ausencia de duplicados. No borrar los datos ni volver a asociar las cuentas por un error 429.


## Consultas bancarias y límites — 0.6.5

Actualizado el 3 de noviembre de 2026.

### Diagnóstico confirmado

Tras autorizar BBVA y asociar una de sus cuentas existentes, la app mostraba «El banco de pruebas no está disponible», junto a un mensaje anterior de primera descarga preparada. La asociación estaba guardada. Una repetición manual, observada mediante diagnóstico temporal filtrado, confirmó una respuesta del proveedor HTTP 429, `ASPSP_RATE_LIMIT_EXCEEDED`, en la consulta de movimientos. No se han copiado identificadores de cuentas, saldos, movimientos ni credenciales a esta documentación. La captura de diagnóstico temporal ha finalizado.

La [FAQ de Enable Banking](https://enablebanking.com/docs/faq/#why-am-i-getting-429-response-code-are-there-rate-limits-for-the-api) distingue consultas iniciadas por la aplicación de consultas iniciadas por el usuario. Las segundas deben enviar el contexto PSU del usuario; las automáticas no deben simular presencia del usuario. Muchos bancos limitan las consultas automáticas a cuatro al día; no se afirma que sea la cuota exacta de esta cuenta. El proveedor recomienda esperar seis horas cuando se alcanza ese límite. La espera no garantiza una hora exacta de desbloqueo.

### Implementado

- El botón «Actualizar movimientos bancarios» identifica la descarga como una acción del usuario. Todas sus páginas conservan esa marca. Las consultas automáticas siguen sin ella.
- El servidor obtiene la IP de la conexión desde la cabecera de Cloudflare y la identificación de la app desde User-Agent, valida ambos datos y los envía únicamente a las consultas de movimientos y saldos del proveedor. No confía en direcciones PSU ni X-Forwarded-For facilitadas por el cliente. No registra IP ni User-Agent.
- Se distinguen límites, permiso caducado, acción del usuario requerida, fallo temporal, datos PSU ausentes, cuenta inaccesible, periodo rechazado y acceso del proveedor denegado. Las respuestas libres del banco no se muestran ni se registran.
- El error de descarga incorpora banco y últimos cuatro dígitos en la app. Se elimina la referencia incorrecta a un banco de pruebas.
- El servidor transmite Retry-After como segundos validados, o seis horas si no se proporciona un plazo válido. La app conserva la espera entre reinicios e impide que el botón de actualización la salte. Este bloqueo afecta a la descarga conjunta actual, no es todavía una planificación independiente por banco.
- Una descarga nueva invalida el plan de revisión anterior. Si falla, no queda un plan antiguo listo para confirmar ni un mensaje anterior de descarga preparada. No se incorpora una descarga parcial.
- Diagnóstico del servidor: únicamente categoría fija de operación, estado HTTP y código reconocido del proveedor. Sin URL, identificadores, cuerpos, excepciones, claves ni datos financieros. La configuración de observabilidad persistente sigue desactivada.

### Despliegue y comprobaciones

El servidor personal actualizado está desplegado. Se conservan la base de datos, secretos y conexiones; no hay migraciones. Comprobado después del despliegue: health responde 200 y el estado privado sin credenciales responde 401. Esto no verifica una descarga bancaria real correcta.

Han pasado 23 pruebas Node y 23 de integración workerd/D1. Incluyen solicitudes manuales frente a automáticas, paginación con contexto, rechazo de IP/contexto inválido, ausencia de cabeceras PSU en configuración, protección de los datos del proveedor y propagación de Retry-After. También pasan las pruebas Swift de política de conexión, contexto del error y plazo de espera, el análisis sintáctico de los archivos Swift modificados, el empaquetado de Wrangler y la revisión de espacios de Git.

### Pendiente

La app 0.6.5, compilación 22, está preparada localmente. Falta que el propietario haga Commit/Push con GitHub Desktop, que pasen los checks macOS/iOS y que instale el nuevo IPA. Después hay que validar una actualización manual de BBVA y la incorporación revisada sin duplicados. No se ha confirmado aún una descarga real correcta tras esta corrección. No es necesario borrar datos ni repetir la asociación por el error 429.


## Estado del 3 de noviembre de 2026

La versión 0.6.1 está instalada y el propietario confirma que Bankinter ya devuelve movimientos reales para revisar. La primera incorporación contable sigue pendiente. Los once checks del commit `a9e5e54` están aprobados, incluidas las compilaciones iOS. La mejora de conciliación 0.6.2 está preparada localmente; todavía no está publicada ni instalada.

- Worker personal independiente desplegado en `https://mi-bombo-banking-personal.albertor7722.workers.dev` y D1 independiente con jurisdicción UE. El servidor sandbox anterior conserva su configuración y sus claves.
- Aplicación PRODUCTION registrada por el propietario en Enable Banking. Su firma, entorno, servicio exclusivo AIS y retorno exacto se han verificado mediante la API. Tras la vinculación realizada por el propietario, se ha verificado mediante la API que figura ACTIVE, con servicio exclusivo AIS y retorno correcto. El catálogo para particulares en España incluye Bankinter.
- Claves nuevas subidas como secretos del Worker personal. Configuración y copia local excluidas de Git, con acceso NTFS limitado al propietario y SYSTEM. No se guardan claves ni identificadores del propietario en esta documentación.
- Migración `20261030000100_bank_account_identity.sql` aplicada y verificada en Supabase: dos campos opcionales, dos índices de unicidad y RLS forzada conservada. No se han modificado movimientos ni importado datos bancarios reales.
- Commit `0722b8c` de la versión 0.6.0 publicado por el propietario y verificado en main: once checks aprobados, incluidas ambas compilaciones iOS, persistencia SwiftData, conciliación personal, sandbox, copias, cálculos y PostgreSQL. No se han detectado archivos privados en el árbol del commit.

## Corrección de autorización · 0.6.1

La primera prueba física devolvía un error al elegir Bankinter, después de la verificación biométrica. Se ha reproducido la respuesta de `POST /auth` sin completar ninguna autorización ni consultar datos de cuentas: el proveedor devuelve `https://tilisy.enablebanking.com`. La lista de destinos del servidor y el cliente 0.6.0 solo admitía `auth.enablebanking.com` en producción.

La corrección admite exactamente los dos hosts oficiales de producción, `auth.enablebanking.com` y `tilisy.enablebanking.com`. La validación sigue exigiendo HTTPS, sin credenciales en la URL ni puertos alternativos. El cliente de producción rechaza el servidor de demostración y el dominio sandbox. No se utilizan comodines ni se reescriben las URLs del proveedor.

La corrección del servidor ya está desplegada con la misma base y configuración de propietario. Se conservan los secretos existentes, sin regenerar claves, alterar consentimientos ni migrar datos. El cliente también necesita actualizarse a 0.6.1: instalar únicamente la corrección del servidor no basta para el IPA 0.6.0. Se añaden mensajes específicos para destino rechazado y respuesta del proveedor incompatible.

Verificación local de esta revisión: 20 pruebas Node, 21 pruebas workerd/D1 y prueba Swift de la política de destinos y ciclo de autenticación, todas aprobadas. Se cubren el dominio real devuelto por producción, el nuevo dominio oficial, destinos parecidos, sandbox en modo real, HTTP, credenciales y puertos alternativos. La compilación nativa de 0.6.1 ya está aprobada en GitHub; el propietario confirma que la descarga real llega a la pantalla de revisión.

Fuentes: [ejemplo oficial de Account Information](https://enablebanking.com/accounts-api/) y [migración de orígenes anunciada por Enable Banking](https://enablebanking.com/blog/2026/06/12/enable-banking-changelog-may-2026).

## Conciliación asistida · 0.6.2

Implementado en la carpeta del proyecto:

- Se normalizan acentos, espacios y separadores del concepto y se retira el prefijo técnico inicial `/TXT/D|` o `/TXT/H|`. Las coincidencias automáticas siguen exigiendo cuenta, importe, tipo compatible, mismo día y concepto equivalente, con un único candidato y sin colisiones.
- Los candidatos compatibles de los tres días próximos se ordenan por concepto relacionado y proximidad de fecha. Una coincidencia de texto destacada o un único registro de igual cuenta, importe y día produce una propuesta que requiere confirmación. Coincidir solo en importe en días diferentes no basta. No se interpreta una puntuación como probabilidad estadística.
- La pantalla separa nuevos, reconocidos automáticamente, asociaciones preparadas por el usuario, propuestas por confirmar y dudas. Los ya importados cuentan las referencias bancarias reconocidas de consultas anteriores, no todos los registros manuales existentes.
- Cada comparación muestra el concepto, fecha e importe del banco junto al registro local, su categoría, destino si es transferencia y aviso si usa dinero reservado. Las propuestas se pueden aceptar juntas; las decisiones individuales previas se conservan. Esta acción prepara elecciones: solo «Incorporar descarga revisada» escribe los datos.
- Las decisiones preparadas se agrupan y pueden volver a revisarse. Se bloquea elegir un registro ya consumido por otra decisión; solo las dos partes complementarias de una transferencia propia pueden compartirlo. Las compras repetidas sin una coincidencia destacada siguen requiriendo decisión individual.
- La asociación conserva el registro local y sus categorías, notas, fecha, reserva y relación periódica. No es necesario borrar datos ni restaurar una copia para utilizarla. No se han realizado escrituras en los datos personales del propietario durante este cambio.

Verificado localmente: el ejecutable Swift de conciliación pasa con prefijos bancarios, propuestas por fecha/importe, conceptos relacionados, compras repetidas, conflictos, aislamiento por cuenta, decisiones individuales conservadas y una descarga sintética de 67 propuestas confirmables en conjunto. Se mantiene la cobertura de transferencias e importaciones repetidas. El análisis sintáctico de los archivos Swift modificados pasa.

Pendiente: ejecutar en macOS los checks de SwiftData y las compilaciones iOS después de que el propietario publique la revisión. Se ha ampliado el check de persistencia existente para comprobar aceptación explícita, conservación de categorías y reservas y una segunda importación sin duplicados; no se puede ejecutar SwiftData en este ordenador Windows. Después se instalará el IPA 0.6.2 para probar la pantalla en el iPad y revisar la primera importación real. No se ha validado visualmente el nuevo SwiftUI en un simulador.

## Flujo implementado

1. Dentro del modo cloud: Ajustes → Mis bancos. La conexión de demostración/sandbox se mantiene aparte en Ajustes → Opciones avanzadas → Laboratorio bancario.
2. Comprobar la conexión con el servidor personal predefinido. Se usa la sesión Supabase; no se pide una clave estática del servidor.
3. Elegir el banco desde el catálogo actual de Enable Banking para España y particulares. El proveedor determina qué modalidades admite; el nombre comercial por sí solo no acredita una cuenta concreta.
4. El propietario autoriza el acceso de consulta en el flujo del banco.
5. Asociar cada cuenta deseada con una cuenta existente de la app, o crear una nueva. Las cuentas existentes conservan su nombre, reservas y relaciones. Primera versión: efectivo en EUR, no posiciones de inversión.
6. Consultar todos los movimientos contabilizados de los últimos 90 días y sus páginas. Revisar la primera descarga y sus coincidencias antes de confirmar.
7. Incorporar la consulta de forma atómica y sincronizar la contabilidad con Supabase mediante el protocolo existente.

Se importan las cuentas asociadas; las demás no se incorporan automáticamente. Si hay una transferencia explícita hacia otra cuenta autorizada que aún no se ha asociado, la consulta se detiene para evitar convertirla en gasto.

## Conciliación y contabilidad

- La identidad bancaria de la cuenta es estable entre permisos renovados. Se calcula en el servidor con HMAC, una clave independiente y la identificación bancaria; no se guarda el IBAN completo en los modelos financieros.
- La vinculación `bankIdentityKey` viaja con la cuenta en la copia de seguridad y en Supabase.
- `bankEntryKey` identifica los apuntes bancarios de un movimiento sin sustituir el identificador CSV original. Una transferencia puede incorporar las referencias de sus dos apuntes sin crear dos movimientos contables.
- Las coincidencias únicas de cuenta, dirección, importe, día y texto normalizado se reconocen automáticamente. Importes iguales cercanos con texto distinto, repeticiones o candidatos múltiples requieren una decisión del propietario.
- Una salida de un banco puede reconocerse como el lado de una transferencia manual existente, incluida una aportación a inversión. Se conserva la transferencia; no se añade además un gasto. Al incorporar la otra cuenta posteriormente, se añaden sus referencias al mismo movimiento si la identificación es coherente.
- La conciliación conserva categoría, notas, fecha, relación con cargos periódicos y financiación con reservas. No deduce por su cuenta que una compra desconocida deba consumir una reserva.
- Un saldo contable ITBD, o CLBD si no hay ITBD, se guarda como valoración autoritativa observada. El historial no se vuelve a sumar sobre ese saldo. La fecha y disponibilidad del dato dependen del banco.
- Las reglas de categorización existentes se aplican a movimientos nuevos. Los que quedan sin categoría aparecen en la revisión habitual.
- Las plantillas periódicas que afectan a cuentas vinculadas dejan de generar apuntes automáticamente: los movimientos reales los suministra el banco. Se mantienen como referencia y para registro manual. Revocar un permiso conserva la vinculación contable y no reactiva automáticamente plantillas atrasadas.

No se fusionan compras por parecido ni se eliminan movimientos automáticamente. Si un banco cambia el importe o la cuenta de un apunte ya reconocido, se detiene esa consulta para revisar la incoherencia.

## Actualización y límites

La app comprueba la conexión al abrir el espacio cloud cuando corresponde. Las consultas automáticas se limitan a una cada seis horas por dispositivo y se reintentan con espera tras errores; el plazo se conserva al reiniciar. El botón Actualizar permite una consulta expresamente solicitada. Los límites del banco pueden ser más restrictivos y aún deben verificarse con Bankinter.

No hay cron de ingesta en el servidor ni actualizaciones con la app cerrada. La sincronización cloud cada 15 segundos no equivale a consultar al banco cada 15 segundos. Se pausa la incorporación al bloquear la app o abrir una ventana de edición durante la consulta automática.

Un permiso vencido requiere renovar la autorización. Desconectar un banco revoca las sesiones de ese banco que conserva el servidor, incluidas las renovadas anteriores; mantiene los movimientos guardados. No se crea ninguna ruta para ordenar pagos.

Las referencias estables y la conciliación reducen duplicados; las diferencias de fecha o importe fuera del criterio de coincidencia necesitan revisión. Borrar un movimiento bancario no equivale a excluirlo permanentemente de futuras descargas. El piloto se validará en un solo dispositivo; quedan pendientes los escenarios de importación bancaria concurrente desde dos dispositivos.

## Controles de acceso

- Servidor personal separado, comprobación del JWT mediante Supabase Auth y propietario único configurado. El token hexadecimal del sandbox no sirve para este servidor.
- La app solo envía su sesión cloud al hostname personal exacto. No sigue redirecciones HTTP que puedan llevar credenciales a otro destino.
- Producción exige una aplicación activa, de entorno PRODUCTION, con servicio exclusivo AIS y retorno exacto; el sandbox sigue exigiendo SANDBOX.
- Sesiones y autorizaciones cifradas con AES-GCM y vinculadas al entorno, la fila y el propietario. HMAC de cuentas con clave separada del cifrado.
- Estados de autorización de un solo uso, caducidad y límites de solicitud. Sin proxy de URLs arbitrarias, rutas de pago ni cuerpos de proveedor en logs.
- La app usa sesión de red efímera, llavero para la sesión cloud y protección de archivos existente. Los datos contables siguen bajo las políticas RLS del propietario en Supabase.
- Páginas públicas informativas: `/privacy` y `/terms`. No incluyen credenciales ni datos financieros.

Son controles implementados y comprobaciones concretas; no constituyen una garantía de ausencia de fallos ni una auditoría externa.

## Comprobaciones realizadas

- 20 pruebas Node del servidor, configuración, cifrado, identidad y proveedor.
- 19 pruebas de integración con workerd/D1, incluido un flujo de producción sintético, renovación, rechazo de otro propietario, revocación y mantenimiento del sandbox.
- 23 pruebas PostgreSQL reales locales: aislamiento, reservas, revisiones, copia completa y nuevas claves bancarias.
- Plan de conciliación compilado y ejecutado con Swift: ambigüedades, renovaciones, transferencias propias y aportaciones vistas solo desde un banco.
- Política del cliente compilada y ejecutada: destino cloud exacto, autorización y retorno.
- Bundle del Worker comprobado con despliegue en seco; servidor personal desplegado. Comprobaciones HTTPS reales: salud correcta, ausencia de credenciales y credenciales ficticias rechazadas, orígenes de navegador rechazados.
- Firma de la aplicación Enable Banking real comprobada sin consultar ninguna cuenta. Estado actualizado tras la vinculación del propietario: PRODUCTION / AIS / ACTIVE. No se han consultado saldos ni movimientos en esta comprobación.

Pendiente del piloto físico: instalar el IPA 0.6.2 y revisar la primera descarga con la conciliación asistida. La 0.6.1 ya conecta y muestra datos de Bankinter, según la prueba del propietario. La vinculación de cuentas propias en el panel ya está completada; no sustituye la autorización desde la app. Los once checks del commit `0722b8c` ya están aprobados. El [workflow número 22](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41055414514) ha terminado correctamente y ofrece el IPA histórico `MiPatrimonio-0.6.0-22-unsigned.ipa` del mismo commit; ese artefacto no contiene las correcciones 0.6.1 ni 0.6.2.  La prueba física verificará saldos, primera importación, reservas, transferencias e idempotencia de una segunda actualización.

## Preparación reproducible

La aplicación de Enable Banking necesita el retorno exacto:

`https://mi-bombo-banking-personal.albertor7722.workers.dev/v1/callback`

La base personal se prepara por separado del sandbox. `tools/setup-personal.mjs` acepta `--app-id`, `--owner-id`, `--database-id` y `--pem` (ruta al archivo). Genera `.personal/wrangler.jsonc` y `.personal/secrets.json` con claves de cifrado e identidad independientes. Rechaza identificadores de ejemplo y no sobrescribe claves existentes. No imprime la clave privada, no despliega y no sube secretos por sí solo.

Desde BankingBackend, después de revisar la configuración:

```powershell
npx wrangler d1 migrations apply DB --remote --config .personal/wrangler.jsonc
npx wrangler secret bulk .personal/secrets.json --config .personal/wrangler.jsonc
npx wrangler deploy --config .personal/wrangler.jsonc
```

Estos pasos ya se han realizado en este despliegue personal. No hay que repetir setup ni regenerar las claves para instalar otro IPA. La migración Supabase también está aplicada y no debe modificarse: cualquier evolución debe usar un nuevo archivo de migración.

## Fuentes del proveedor

- [Cuentas propias y producción restringida](https://enablebanking.com/docs/api/linked-accounts/).
- [Referencia API de Enable Banking](https://enablebanking.com/docs/api/reference/).
- [Catálogo de bancos para España](https://enablebanking.com/open-banking-apis?country=ES).
- [Validación de usuarios con Supabase Auth](https://supabase.com/docs/reference/javascript/auth-getuser).

## Entrada simplificada · 0.6.4

Mis bancos abre directamente la conexión personal en modo cloud, sin pasar por los ajustes de sandbox. Se conserva la separación de espacios y el laboratorio sigue disponible en Avanzado. El selector de destino de entrada dispone de cobertura Swift. No cambia el protocolo, los servidores, los permisos ni las claves. [Navegación y comprobaciones](../AJUSTES.md).
