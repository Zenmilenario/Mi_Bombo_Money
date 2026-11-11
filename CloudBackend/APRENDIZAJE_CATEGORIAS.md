# Aprendizaje de categorías y modelo de datos

## IA individual, común y datos cifrados — 11/11/2026

El ajuste por persona es aprendizaje automático real; no depende de compartir los datos entre usuarios para ser IA. Se mantienen una base de arranque común y el aprendizaje personal, sincronizado entre sus propios dispositivos. El cifrado de invitados se aplica al documento financiero y al aprendizaje antes de enviarlos, y se descifran en el dispositivo antes de entrenar o predecir: los modelos y sus umbrales siguen siendo los mismos.

En este lote no se ha creado un modelo colectivo que use las correcciones de invitados ni se han subido sus ejemplos a un dataset común. Esa fase queda pendiente de participación voluntaria y de protección de las actualizaciones (agregación segura y privacidad diferencial si se adopta aprendizaje federado). Compartir pesos sin esas medidas no garantiza anonimato. Los datos propios autorizados y los sintéticos permiten evolucionar la base común sin abrir los de invitados.

Cifrado preparado localmente, pendiente de CI iOS y despliegue coordinado. Detalles y límites del servidor bancario: [Privacidad de invitados](privacy-encryption.md).

Primera entrega preparada en 0.6.11, compilación 28. Actualizado el 7 de noviembre de 2026 con el aprendizaje por eventos de 0.6.18, compilación 35. Quedan pendientes la compilación iOS en GitHub y la comprobación en el dispositivo.

## Experiencia en la app

- **Movimientos → Por revisar → detalle** muestra una propuesta de IA para movimientos sin categoría compatible cuando el modelo encuentra señales suficientes. Las reglas explícitas tienen prioridad. El usuario puede confirmar la propuesta o elegir otra categoría.
- El formulario de un movimiento nuevo y la hoja de categorías del CSV ofrecen una propuesta en su propio flujo. La elección de CSV se aprende cuando termina la importación.
- Confirmar, corregir una categoría o cambiarla en lote guarda una señal de aprendizaje después de guardar el movimiento. El modelo se actualiza en el dispositivo de forma automática.
- El clasificador de texto conserva su función de propuestas. En 0.6.17 un modelo separado aprende acciones completas de las correcciones explícitas y puede aplicar categorías o convertir determinados gastos bancarios en transferencias a inversión cuando supera las comprobaciones temporales descritas más abajo.

## Datos de entrenamiento

El clasificador de regresión logística multiclase aprende pesos de palabras y fragmentos de tres caracteres. Se entrenan modelos distintos para gastos y para ingresos. La app restringe las propuestas a categorías activas compatibles.

El arranque reúne ejemplos ficticios de consumo habitual y, dentro de cada perfil, el historial disponible antes de activar el aprendizaje. Los ejemplos ficticios existen únicamente en el código del modelo. El historial se lee del almacén SwiftData del perfil activo, que recibe los movimientos ya sincronizados cuando la nube está activa. Se excluyen categorías genéricas, duplicados pendientes, coincidencias con reglas vigentes y cargos periódicos del historial inicial. El origen exacto de algunas etiquetas antiguas se desconoce. Por ello su peso es 0,55, frente a 1 para el ejemplo ficticio y 5 para una decisión explícita. Las confirmaciones tienen prioridad al limitar el tamaño de la muestra. Textos equivalentes de la misma categoría cuentan una vez.

Una confirmación local relaciona el UUID del movimiento con una huella de concepto, tipo y categoría. Confirmar otra categoría sustituye esa huella. Para entrenar se exige que el movimiento siga existiendo y que coincida con su confirmación. El entrenamiento conserva el texto de los movimientos en memoria y aprende en una tarea de segundo plano. La muestra se deriva de los movimientos, la fecha de arranque y las confirmaciones. Si la muestra se repite, la app reutiliza el modelo en memoria.

## Nube y almacenamiento

| Información | Lugar | Papel |
| --- | --- | --- |
| Movimiento, categoría y sus relaciones | SwiftData y tablas de Supabase existentes | Registro financiero y sincronización |
| Confirmación del usuario y corrección contable | Archivos protegidos junto al almacén SwiftData de cada perfil | Procedencia de las etiquetas y acciones para entrenar en ese dispositivo |
| Ejemplos ficticios | Código de la app | Arranque del modelo |
| Pesos y vocabulario | Memoria del dispositivo | Modelo reconstruible al iniciar la app |

El archivo local usa escritura atómica y protección completa. Solicita la exclusión de la copia del sistema. Las copias financieras incluyen las categorías guardadas y el dispositivo puede reconstruir un modelo inicial a partir del historial recuperado. Las confirmaciones del aprendizaje son locales. Por eso dos dispositivos pueden generar propuestas distintas aunque tengan los mismos movimientos y categorías.

La arquitectura usa el almacén existente como fuente de datos y entrena sin llamadas a un servicio de IA. Usa el esquema actual de Supabase. Las correcciones financieras se sincronizan por el flujo existente; los ejemplos y auditorías del aprendizaje son locales. La copia de seguridad financiera no exporta estos archivos de aprendizaje. [Configuración del almacén SwiftData](https://developer.apple.com/documentation/swiftdata/modelconfiguration/url).

## Cómo presentarlo en el TFM

El componente es un clasificador supervisado de texto basado en regresión logística multiclase. Aprende sus coeficientes de ejemplos etiquetados y los usa para inferir categorías. La OCDE incluye la regresión logística entre las técnicas de aprendizaje automático. En esta versión la app propone y el usuario confirma. [Panorama técnico de la IA según la OCDE](https://www.oecd.org/en/publications/artificial-intelligence-in-society_eedfee77-en/full-report/component-6.html).

La aportación de bases de datos es la separación entre el dato financiero, la procedencia de la etiqueta y el modelo derivado. Se puede reproducir la evaluación con ejemplos ficticios, justificar la separación de datos y medir cuánto mejora el modelo tras una corrección.

Si el aprendizaje entre dispositivos se vuelve prioritario, la evolución propuesta es una tabla de confirmaciones. Su clave sería propietario, espacio y movimiento. Guardaría la categoría confirmada, la revisión del movimiento, la fecha y el origen de la confirmación. Las claves foráneas incluirían propietario y espacio, como las tablas financieras. Una política RLS aislaría cada usuario. Un guardado con la misma clave y revisión se trataría como la misma confirmación. Un cambio de categoría o un borrado requeriría invalidar la confirmación según la revisión vigente. El modelo se reconstruiría en cada dispositivo con las confirmaciones sincronizadas. Esta tabla es un diseño para evaluar y no se ha implementado.

Para una evaluación reproducible conviene registrar la versión de la representación del texto, el tamaño de cada conjunto, su corte temporal, las categorías elegibles y los resultados de precisión y cobertura. Reservar compras de comercios distintos para medir generalización. Los ejemplos del TFM deben ser ficticios o anonimizados y mantenerse separados de la contabilidad personal.

Una comparación pendiente es ejecutar las reglas actuales y el clasificador sobre el mismo conjunto de movimientos posteriores al entrenamiento, con las categorías de referencia verificadas antes de comparar. Medir el acierto entre las propuestas y qué porcentaje de los movimientos recibe una propuesta permite separar la mejora del modelo de la facilidad del conjunto de prueba.

## Categorías de efectivo en 0.6.12

El catálogo inicial incorpora **Retirada de efectivo** para gastos e **Ingreso de efectivo** para ingresos. Los perfiles existentes pueden añadir ambas desde **Ajustes → Categorías → Añadir categorías de efectivo**. El botón añade las que falten y conserva las categorías archivadas. Los movimientos de efectivo entre una cuenta bancaria y una cartera que ya se lleva en la app se registran como transferencias entre cuentas propias, para evitar contar dos veces el dinero.

Se añadieron ejemplos ficticios de cajeros y ventanilla para que el modelo pueda proponer estas categorías. La selección manual tiene búsqueda en el formulario, en Por revisar y al corregir el CSV. Añadir categorías nuevas sigue siendo útil cuando ayudan a distinguir movimientos que la persona quiera analizar. La prueba del modelo incluye un reintegro y un ingreso en cajero con textos distintos de los del entrenamiento. La validación de la interfaz en iOS está pendiente.

## Evidencia disponible

### Correcciones aprendidas — preparado localmente en 0.6.17 (34)

**Implementado.** Al guardar una edición humana de un movimiento bancario, se conserva la observación previa y la acción elegida: tipo, categoría y cuenta de destino. También cuentan las categorías confirmadas desde la revisión individual o en lote. Se aprende desde esta versión; las antiguas ediciones sin procedencia verificable no se convierten retrospectivamente en etiquetas de transferencia. Identificar «Saveback» en la tarjeta semántica sigue siendo distinto de editar la acción contable.

El tercer modelo utiliza **clasificación supervisada por los tres vecinos más próximos (kNN)**. Aprende de los ejemplos humanos de cada perfil; no incorpora reglas de comercios, importes personales ni las capturas privadas al código. Conserva el concepto bancario previo aunque el usuario lo renombre durante la corrección. Usa texto, importe, sentido, día y día de la semana; exige la misma cuenta y sentido para comparar. La distancia ponderada y sus umbrales son hiperparámetros del algoritmo, no reglas de clasificación para una persona. Los cambios de condiciones de tarjeta siguen perteneciendo al modelo semántico; no demuestran una acción contable.

**Condiciones de aplicación.** Debe haber al menos seis observaciones humanas distintas de la acción propuesta, tres de otras acciones y ejemplos de la acción repartidos en al menos dos meses. Los tres vecinos deben coincidir, estar próximos y separados de la alternativa. Además se hacen comprobaciones temporales: cada ejemplo se predice usando exclusivamente meses anteriores. La acción necesita al menos tres aciertos temporales de esa cuenta y sentido, sin falsos positivos observados para ella. Una observación repetida no aumenta la evidencia y los ejemplos contradictorios compiten. Estos filtros no acreditan una precisión estadística garantizada. Sin evidencia suficiente, el resultado es abstención y revisión manual.

**Alcance automático actual.** Solo apuntes bancarios llegados después de iniciar este aprendizaje, todavía sin categoría ni destino, sin decisión manual, reserva, periodicidad, referencia externa de CSV o duplicado pendiente. Se puede asignar una categoría compatible manteniendo el tipo, o convertir un gasto en transferencia hacia una cuenta de inversión activa, de la misma moneda y sin conexión bancaria propia. El destino debe existir desde la fecha del apunte. Se conserva importe, fecha, cuenta de efectivo, concepto, notas, lote y referencia bancaria. Se modifica el mismo registro; no se crean dos movimientos. Las reglas explícitas y clasificaciones ya guardadas tienen prioridad.

El procesador reutiliza el modelo en memoria mientras la app está activa. En 0.6.17 comprobaba cada veinte segundos y en 0.6.18 reacciona a los eventos descritos abajo. Se pausa con formularios, hojas abiertos o cambios sin guardar y vuelve a comprobar los ejemplos y destinos después de entrenar. Los registros anteriores a la activación o al último mes usado para aprender quedan fuera del alcance automático.

**Control y recuperación.** En el detalle se puede desactivar «Aplicar correcciones aprendidas» para todo el perfil. Una aplicación automática muestra su procedencia y ofrece «Deshacer corrección y enseñar a la IA». Deshacer restaura la acción anterior, conserva los datos del banco, añade evidencia negativa y protege el registro frente a una repetición automática. Las predicciones aplicadas no se utilizan como etiquetas humanas. Si el usuario cambia tipo, destino o categoría, su edición tiene prioridad. No se tocan pagos reservados ni vínculos periódicos. Si existe una posible contrapartida ya registrada o una transferencia manual equivalente, se requiere revisión.

**Persistencia.** Se amplía el archivo protegido de operaciones con ejemplos de corrección, acciones y auditorías para deshacer. Estos ejemplos contienen el texto y contexto necesarios del apunte previo; se guardan dentro del almacenamiento privado de la app, sin enviarlos a un servicio de IA. Se conservan las confirmaciones antiguas y su formato de huella. Se escribe la información de recuperación antes del guardado financiero; una etiqueta pendiente solo se usa si sigue coincidiendo con el movimiento guardado. Ante un fallo se revierte SwiftData; una auditoría pendiente no aparece como aplicada. Esto no es una transacción distribuida entre el archivo y SwiftData. Se conserva una etiqueta anterior para no perder un ejemplo válido tras una edición fallida. Una actualización normal conserva los archivos; reinstalar o borrar el perfil puede perderlos. Dos dispositivos comparten los resultados financieros sincronizados, pero todavía no comparten este aprendizaje ni la auditoría para deshacer.

**Saveback y Round up.** Corregir un débito confirmado de gasto a transferencia y seleccionar su destino enseña esa acción. Si vuelve un apunte comparable y se cumplen los filtros, podrá aplicarla solo. Con descripciones vacías, compras y beneficios parecidos pueden seguir siendo indistinguibles; no se promete identificar todos los Saveback. Esta entrega no crea la recompensa bruta, su retención o un abono compensatorio, ni completa automáticamente la conciliación multietapa o el objetivo de una aportación periódica. No cambia un ingreso a transferencia ni empareja dos cuentas bancarias conectadas.

**Validación.** Las pruebas del modelo usan datos ficticios y comprueban otro periodo, cambio de destino/categoría, aislamiento por cuenta, observaciones repetidas, ausencia de alternativas, contradicciones y abstención. Las pruebas del adaptador cubren aplicación sobre el mismo registro, conservación de datos, ausencia de autoentrenamiento, deshacer, edición revertida, pausa, reservas/periodicidad, contrapartidas, destinos archivados o de otra moneda, persistencia y perfiles separados. La ejecución local usa sustitutos de SwiftData y hashing: no valida los frameworks ni la protección de archivos de Apple. Se conectan a CI las pruebas con SwiftData/CryptoKit reales, además de conservar las suites anteriores. Compilación Debug/Release de iOS y prueba física pendientes tras subir la versión.

### Aprendizaje por eventos — preparado localmente en 0.6.18 (35)

**Implementado.** Cuando se guarda una importación o una descarga de la nube añade movimientos bancarios al perfil, la app evalúa los nuevos apuntes elegibles. La señal contiene la ubicación del almacén local y los identificadores de los movimientos. Las importaciones repetidas, las filas conciliadas con un movimiento existente y los guardados fallidos quedan fuera de esa señal.

Al guardar una corrección humana, confirmar una categoría o deshacer una corrección automática, la app actualiza los ejemplos protegidos del perfil y vuelve a comprobar los movimientos elegibles. Las predicciones aplicadas por el modelo no se convierten en ejemplos confirmados. La apertura de la app comprueba si quedó trabajo pendiente. Mientras la app está abierta, el procesador espera si hay un formulario abierto, cambios sin guardar, una sincronización cloud en curso o un conflicto por resolver. Los eventos son internos al dispositivo y no generan solicitudes bancarias adicionales.

**Validación.** Las pruebas locales con sustitutos verifican que se seleccionan los identificadores del lote, que repetir la evaluación no reaplica la corrección y que una corrección automática o un guardado revertido no emiten confirmaciones humanas. La prueba del importador en CI comprueba que el aviso se publica después del guardado y que repetir la descarga no lo vuelve a emitir. La compilación iOS y la validación en un dispositivo siguen pendientes.

**Pendiente.** Medir cobertura, correcciones del usuario y tiempo hasta la propuesta. El reconocimiento de cargos recurrentes y la conciliación multietapa de transferencias siguen fuera de este flujo.

### Reconocimiento de beneficios de inversión — preparado localmente en 0.6.16

Actualizado el 5 de noviembre de 2026. Se ha incorporado un segundo clasificador supervisado de regresión logística multiclase, separado del modelo de categorías. Distingue otro movimiento, aportación a inversión, Round up y Saveback. Aprende pesos de palabras, fragmentos de texto y, con confirmaciones reales, importe, sentido, día, día de la semana y contexto de cuenta. Las condiciones de la tarjeta, si se conocen para ese periodo, se añaden al contexto. Los ejemplos ficticios iniciales enseñan vocabulario; no fijan un calendario ni importes personales para decidir la clase.

En **Movimientos → detalle → Reconocimiento de inversión**, el usuario puede confirmar una propuesta, identificar otro tipo, corregirlo o retirar la identificación. Las condiciones de Saveback bruto y el multiplicador de Round up se guardan por cuenta con una fecha de vigencia. Los valores iniciales del formulario son 1 % y 1×; solo se guardan tras una acción explícita. Las condiciones posteriores no se aplican a movimientos anteriores. Cambiar estas condiciones no elimina una identidad confirmada; se reconstruyen las características del entrenamiento con las condiciones aplicables.

Para textos genéricos, el modelo se abstiene mientras no haya al menos ocho observaciones diferentes de esa cuenta, distribuidas entre dos meses y dos clases. Una propuesta contextual necesita al menos tres observaciones de su clase y tres de otras clases, además de superar el umbral de puntuación y margen. Son barreras para mostrar propuestas, no precisión validada ni autorización para modificar la contabilidad. Las observaciones repetidas no aumentan la evidencia; las idénticas con etiquetas contradictorias se excluyen del entrenamiento.

Las confirmaciones guardan UUID, huella de identidad y tipo en un archivo protegido junto al almacén del perfil; no duplican conceptos ni importes en ese archivo. Las condiciones de la cuenta se guardan allí también. El modelo deriva los ejemplos vigentes de los movimientos y se entrena en segundo plano. Una edición del importe, fecha, concepto, tipo, cuenta, moneda o referencia bancaria invalida la etiqueta antigua. Una corrección sustituye la anterior; una predicción sin confirmar nunca se utiliza como etiqueta. Los beneficios confirmados quedan fuera del entrenamiento de categorías ordinarias. La revisión suprime la propuesta de categoría de consumo cuando hay una identificación especializada o una propuesta de operación pendiente; conserva la clasificación manual y las reglas explícitas.

El archivo usa escritura atómica y protección completa, y se excluye de la copia del sistema. Se conserva en una actualización normal que mantenga el almacén. Las confirmaciones y condiciones son locales a cada dispositivo y perfil; no se han añadido tablas cloud ni se incluyen en la exportación financiera. Reinstalar o borrar el almacenamiento puede perderlas. En 0.6.16 no había aplicación contable automática; el alcance limitado añadido en 0.6.17 se explica arriba. La sincronización del aprendizaje y su copia portable siguen pendientes.

**Validación local:** pasan las pruebas del núcleo con conceptos distintos de las semillas, aprendizaje contextual sobre otro periodo, correcciones, aislamiento por cuenta, abstención y repetición de observaciones. Sigue pasando la prueba anterior de categorías. El adaptador se ha compilado y ejecutado con los modelos reales sin macros y sustitutos de SwiftData y hashing: persistencia del archivo, correcciones, invalidación, vigencia de condiciones, aislamiento de perfil/sandbox y conservación de los datos financieros. No valida las garantías de SwiftData, CryptoKit ni los atributos de protección de Apple. El workflow incorpora las pruebas del núcleo y del adaptador con SwiftData real para macOS. Compilación iOS y prueba física pendientes de GitHub y del dispositivo.

### Alcance que continúa pendiente

Pendiente de implementar: aplicar el tipo semántico confirmado a una conciliación contable multietapa completa. Round up representa dinero propio trasladado a inversión y Saveback una recompensa; una categoría de gasto por sí sola no representa correctamente estos efectos. Identificar un beneficio no cambia por sí solo la contabilidad. Las correcciones completas de 0.6.17 sí pueden aprender una acción financiera limitada, con los filtros descritos arriba.

El clasificador de categorías sigue aprendiendo del texto; el nuevo de operaciones admite contexto. Los apuntes de Trade Republic inspeccionados carecen de descripciones, por lo que añadir palabras sintéticas al entrenamiento no resuelve ese caso. Sin suficientes confirmaciones se requiere identificación explícita. La lectura de capturas mediante OCR y su vinculación verificable con los apuntes todavía no están implementadas.

Las capturas revisadas aportan trece eventos distintos etiquetados; no se almacenan aquí imágenes ni datos financieros personales. Las vistas repetidas del mismo evento no son muestras independientes. La evidencia visual todavía no está vinculada individualmente a los apuntes bancarios. Esta muestra permite preparar un prototipo, pero no acreditar precisión suficiente para cambiar contabilidad automáticamente. La evaluación debe reservar periodos completos, incluir operaciones parecidas de otros tipos y medir precisión y cobertura por clase. No usar la puntuación softmax como una garantía de acierto.

Para una evolución cloud, registrar la procedencia, revisión y versión del modelo con aislamiento por usuario. El cálculo de saldos, el control de duplicados y la conservación del dinero deben seguir siendo deterministas e independientes de la predicción. Detalles del producto y del tratamiento contable propuesto en [integración bancaria personal](../BankingBackend/INTEGRACION_PERSONAL.md).

### Prueba inicial del clasificador de categorías

La prueba ejecutable en Swift usa 12 conceptos ficticios distintos del conjunto de entrenamiento. El modelo propuso 8 y acertó las 8. También se comprobó que sustituir una etiqueta cambia la predicción de un concepto parecido, que distingue ingresos de gastos y que se abstiene ante una referencia puramente numérica. La muestra es inicial. El acierto con el historial real y la cobertura por categoría quedan por medir antes de activar la asignación automática.

El núcleo se compiló y ejecutó con Swift 6.2.1 en Linux. Se comprobó la sintaxis de la integración y los tipos del adaptador con sustitutos de SwiftData y CryptoKit. La ejecución con los frameworks de Apple queda pendiente del check de Xcode. La prueba del modelo se ejecuta en el workflow de datos y cálculos.
