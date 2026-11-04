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

## Evidencia disponible

La prueba ejecutable en Swift usa 12 conceptos ficticios distintos del conjunto de entrenamiento. El modelo propuso 8 y acertó las 8. También se comprobó que sustituir una etiqueta cambia la predicción de un concepto parecido, que distingue ingresos de gastos y que se abstiene ante una referencia puramente numérica. La muestra es inicial. El acierto con el historial real y la cobertura por categoría quedan por medir antes de activar la asignación automática.

El núcleo se compiló y ejecutó con Swift 6.2.1 en Linux. Se comprobó la sintaxis de la integración y los tipos del adaptador con sustitutos de SwiftData y CryptoKit. La ejecución con los frameworks de Apple queda pendiente del check de Xcode. La prueba del modelo se ejecuta en el workflow de datos y cálculos.
