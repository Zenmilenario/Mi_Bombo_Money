# Aprendizaje de categorías y modelo de datos

Primera entrega preparada en 0.6.11, compilación 28. Actualizado el 4 de noviembre de 2026. Pendientes la compilación iOS en GitHub y la evaluación en el iPad.

## Experiencia en la app

- **Movimientos → Por revisar → detalle** muestra una propuesta de IA para movimientos sin categoría compatible cuando el modelo encuentra señales suficientes. Las reglas explícitas tienen prioridad. El usuario puede confirmar la propuesta o elegir otra categoría.
- El formulario de un movimiento nuevo y la hoja de categorías del CSV ofrecen una propuesta en su propio flujo. La elección de CSV se aprende cuando termina la importación.
- Confirmar, corregir una categoría o cambiarla en lote guarda una señal de aprendizaje después de guardar el movimiento. El modelo se actualiza en el dispositivo de forma automática.
- Esta entrega es la fase de propuestas. La asignación sin confirmación queda supeditada a una evaluación con movimientos reales. Las transferencias quedan fuera del clasificador.

## Datos de entrenamiento

El clasificador de regresión logística multiclase aprende pesos de palabras y fragmentos de tres caracteres. Se entrenan modelos distintos para gastos y para ingresos. La app restringe las propuestas a categorías activas compatibles.

El arranque reúne ejemplos ficticios de consumo habitual y, dentro de cada perfil, el historial disponible antes de activar el aprendizaje. Los ejemplos ficticios existen únicamente en el código del modelo. El historial se lee del almacén SwiftData del perfil activo, que recibe los movimientos ya sincronizados cuando la nube está activa. Se excluyen categorías genéricas, duplicados pendientes, coincidencias con reglas vigentes y cargos periódicos del historial inicial. El origen exacto de algunas etiquetas antiguas se desconoce. Por ello su peso es 0,55, frente a 1 para el ejemplo ficticio y 5 para una decisión explícita. Las confirmaciones tienen prioridad al limitar el tamaño de la muestra. Textos equivalentes de la misma categoría cuentan una vez.

Una confirmación local relaciona el UUID del movimiento con una huella de concepto, tipo y categoría. Confirmar otra categoría sustituye esa huella. Para entrenar se exige que el movimiento siga existiendo y que coincida con su confirmación. El entrenamiento conserva el texto de los movimientos en memoria y aprende en una tarea de segundo plano. La muestra se deriva de los movimientos, la fecha de arranque y las confirmaciones. Si la muestra se repite, la app reutiliza el modelo en memoria.

## Nube y almacenamiento

| Información | Lugar | Papel |
| --- | --- | --- |
| Movimiento, categoría y sus relaciones | SwiftData y tablas de Supabase existentes | Registro financiero y sincronización |
| Confirmación del usuario | Archivo protegido junto al almacén SwiftData de cada perfil | Procedencia de la etiqueta para entrenar en ese dispositivo |
| Ejemplos ficticios | Código de la app | Arranque del modelo |
| Pesos y vocabulario | Memoria del dispositivo | Modelo reconstruible al iniciar la app |

El archivo local usa escritura atómica y protección completa. Solicita la exclusión de la copia del sistema. Las copias financieras incluyen las categorías guardadas y el dispositivo puede reconstruir un modelo inicial a partir del historial recuperado. Las confirmaciones del aprendizaje son locales. Por eso dos dispositivos pueden generar propuestas distintas aunque tengan los mismos movimientos y categorías.

La arquitectura usa el almacén existente como fuente de datos y entrena sin llamadas a un servicio de IA. Esta entrega usa el esquema actual de Supabase. La copia de seguridad, la sincronización y los cambios de categoría siguen sus flujos de persistencia actuales. [Configuración del almacén SwiftData](https://developer.apple.com/documentation/swiftdata/modelconfiguration/url).

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

### Reconocimiento de beneficios de inversión — preparado localmente en 0.6.16

Actualizado el 5 de noviembre de 2026. Se ha incorporado un segundo clasificador supervisado de regresión logística multiclase, separado del modelo de categorías. Distingue otro movimiento, aportación a inversión, Round up y Saveback. Aprende pesos de palabras, fragmentos de texto y, con confirmaciones reales, importe, sentido, día, día de la semana y contexto de cuenta. Las condiciones de la tarjeta, si se conocen para ese periodo, se añaden al contexto. Los ejemplos ficticios iniciales enseñan vocabulario; no fijan un calendario ni importes personales para decidir la clase.

En **Movimientos → detalle → Reconocimiento de inversión**, el usuario puede confirmar una propuesta, identificar otro tipo, corregirlo o retirar la identificación. Las condiciones de Saveback bruto y el multiplicador de Round up se guardan por cuenta con una fecha de vigencia. Los valores iniciales del formulario son 1 % y 1×; solo se guardan tras una acción explícita. Las condiciones posteriores no se aplican a movimientos anteriores. Cambiar estas condiciones no elimina una identidad confirmada; se reconstruyen las características del entrenamiento con las condiciones aplicables.

Para textos genéricos, el modelo se abstiene mientras no haya al menos ocho observaciones diferentes de esa cuenta, distribuidas entre dos meses y dos clases. Una propuesta contextual necesita al menos tres observaciones de su clase y tres de otras clases, además de superar el umbral de puntuación y margen. Son barreras para mostrar propuestas, no precisión validada ni autorización para modificar la contabilidad. Las observaciones repetidas no aumentan la evidencia; las idénticas con etiquetas contradictorias se excluyen del entrenamiento.

Las confirmaciones guardan UUID, huella de identidad y tipo en un archivo protegido junto al almacén del perfil; no duplican conceptos ni importes en ese archivo. Las condiciones de la cuenta se guardan allí también. El modelo deriva los ejemplos vigentes de los movimientos y se entrena en segundo plano. Una edición del importe, fecha, concepto, tipo, cuenta, moneda o referencia bancaria invalida la etiqueta antigua. Una corrección sustituye la anterior; una predicción sin confirmar nunca se utiliza como etiqueta. Los beneficios confirmados quedan fuera del entrenamiento de categorías ordinarias. La revisión suprime la propuesta de categoría de consumo cuando hay una identificación especializada o una propuesta de operación pendiente; conserva la clasificación manual y las reglas explícitas.

El archivo usa escritura atómica y protección completa, y se excluye de la copia del sistema. Se conserva en una actualización normal que mantenga el almacén. Las confirmaciones y condiciones son locales a cada dispositivo y perfil; no se han añadido tablas cloud ni se incluyen en la exportación financiera. Reinstalar o borrar el almacenamiento puede perderlas. La sincronización del aprendizaje, su copia portable y la clasificación contable automática siguen pendientes.

**Validación local:** pasan las pruebas del núcleo con conceptos distintos de las semillas, aprendizaje contextual sobre otro periodo, correcciones, aislamiento por cuenta, abstención y repetición de observaciones. Sigue pasando la prueba anterior de categorías. El adaptador se ha compilado y ejecutado con los modelos reales sin macros y sustitutos de SwiftData y hashing: persistencia del archivo, correcciones, invalidación, vigencia de condiciones, aislamiento de perfil/sandbox y conservación de los datos financieros. No valida las garantías de SwiftData, CryptoKit ni los atributos de protección de Apple. El workflow incorpora las pruebas del núcleo y del adaptador con SwiftData real para macOS. Compilación iOS y prueba física pendientes de GitHub y del dispositivo.

### Alcance que continúa pendiente

Pendiente de implementar: aplicar el tipo confirmado a una conciliación contable completa. Round up representa dinero propio trasladado a inversión y Saveback una recompensa; una categoría de gasto por sí sola no representa correctamente estos efectos. En esta entrega identificar un beneficio no cambia saldos, presupuestos, tipo de movimiento ni aportaciones periódicas. La interfaz lo indica expresamente.

El clasificador de categorías sigue aprendiendo del texto; el nuevo de operaciones admite contexto. Los apuntes de Trade Republic inspeccionados carecen de descripciones, por lo que añadir palabras sintéticas al entrenamiento no resuelve ese caso. Sin suficientes confirmaciones se requiere identificación explícita. La lectura de capturas mediante OCR y su vinculación verificable con los apuntes todavía no están implementadas.

Las capturas revisadas aportan trece eventos distintos etiquetados; no se almacenan aquí imágenes ni datos financieros personales. Las vistas repetidas del mismo evento no son muestras independientes. La evidencia visual todavía no está vinculada individualmente a los apuntes bancarios. Esta muestra permite preparar un prototipo, pero no acreditar precisión suficiente para cambiar contabilidad automáticamente. La evaluación debe reservar periodos completos, incluir operaciones parecidas de otros tipos y medir precisión y cobertura por clase. No usar la puntuación softmax como una garantía de acierto.

Para una evolución cloud, registrar la procedencia, revisión y versión del modelo con aislamiento por usuario. El cálculo de saldos, el control de duplicados y la conservación del dinero deben seguir siendo deterministas e independientes de la predicción. Detalles del producto y del tratamiento contable propuesto en [integración bancaria personal](../BankingBackend/INTEGRACION_PERSONAL.md).

### Prueba inicial del clasificador de categorías

La prueba ejecutable en Swift usa 12 conceptos ficticios distintos del conjunto de entrenamiento. El modelo propuso 8 y acertó las 8. También se comprobó que sustituir una etiqueta cambia la predicción de un concepto parecido, que distingue ingresos de gastos y que se abstiene ante una referencia puramente numérica. La muestra es inicial. El acierto con el historial real y la cobertura por categoría quedan por medir antes de activar la asignación automática.

El núcleo se compiló y ejecutó con Swift 6.2.1 en Linux. Se comprobó la sintaxis de la integración y los tipos del adaptador con sustitutos de SwiftData y CryptoKit. La ejecución con los frameworks de Apple queda pendiente del check de Xcode. La prueba del modelo se ejecuta en el workflow de datos y cálculos.
