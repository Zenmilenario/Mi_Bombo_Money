# Mi Patrimonio — iPhone y iPad

Aplicación SwiftUI local para consolidar cuentas, efectivo, tarjetas, ahorro e inversiones.

## Almacenamiento cloud en desarrollo

El proyecto de Supabase `mi-bombo-money-dev` ya dispone de un esquema PostgreSQL con permisos por usuario y pruebas de aislamiento. El código incorpora acceso cloud y sincronización con copia local separada por usuario; queda pendiente su validación completa en iOS y entre dispositivos. Se activa desde Ajustes → Activar mi nube. Instalación, estado verificado y pruebas reproducibles: [CloudBackend/README.md](CloudBackend/README.md).

## Categorías de efectivo y búsqueda de bancos · 0.6.12

Los perfiles nuevos incluyen **Retirada de efectivo** e **Ingreso de efectivo**. En un perfil existente se añaden desde **Ajustes → Categorías → Añadir categorías de efectivo**. La IA puede sugerir ambas. El selector de movimientos muestra categorías compatibles con búsqueda por nombre y Ajustes las agrupa por tipo.

En **Ajustes → Mis bancos**, la búsqueda muestra solo los bancos que coinciden con el nombre escrito. El catálogo completo queda plegado bajo **Ver bancos disponibles**. La compilación nativa y la prueba de navegación en iOS quedan pendientes.

## Aprendizaje de categorías · 0.6.11

La app propone categorías en **Por revisar**, en el alta de movimientos y en la revisión del CSV. El modelo combina ejemplos ficticios con el historial del perfil y aprende de las confirmaciones dentro del dispositivo. La primera entrega funciona en modo propuestas. Está preparada localmente y pendiente de checks iOS y prueba en el iPad. [Diseño y evaluación del aprendizaje](CloudBackend/APRENDIZAJE_CATEGORIAS.md).

## Conceptos y clasificación · 0.6.10

La 0.6.10 incluye títulos bancarios legibles para los prefijos conocidos, texto guardado accesible en el detalle, selección de varios movimientos para asignar una categoría, acceso rápido desde una fila y aprendizaje de reglas con una frase común. Flujo: **Movimientos → (…) → Seleccionar movimientos → Elegir categoría para la selección**. La selección respeta búsqueda y filtros. Los importes, vínculos de reserva, referencias bancarias y decisiones de duplicados se conservan.

Las reglas opcionales se guardan para futuros movimientos; la corrección inmediata afecta a la selección confirmada. Detalles, límites y pruebas en [Revisión y clasificación de movimientos](REVISION_MOVIMIENTOS.md). El usuario confirma que instaló y probó la 0.6.10 (build 27). No hay una migración cloud nueva.

## Efectivo e inversiones · 0.6.9

Disponible el acceso **Cuentas → Efectivo e inversiones**. El usuario confirma que ha probado la versión 0.6.9. Se distinguen el efectivo de cada entidad y el valor registrado de la cartera; se muestran aportaciones y retiradas del mes, acciones con las cuentas preseleccionadas y actualización de valoraciones. Las carteras excluidas del patrimonio tienen una acción para revisar su configuración. Las aportaciones futuras dejan de contarse como realizadas en Inicio. No se modifican automáticamente saldos ni preferencias existentes.

La cartera se actualiza con valoraciones registradas; no hay cotizaciones ni posiciones automáticas. Detalles, pruebas y límites en [Efectivo e inversiones](INVERSIONES.md). La prueba del usuario de 0.6.9 (build 26) está confirmada; quedan por revisar los checks del commit instalado y comprobar específicamente sincronización y recuperación de estos casos.

## Dinero reservado entre cuentas · 0.6.8

Una reserva puede repartirse entre tus cuentas de efectivo. Al registrar o editar una transferencia propia, elige la reserva en **Origen del dinero → Dinero que trasladas**. El importe reservado acompaña al dinero hasta la cuenta de destino; la transferencia no consume la reserva ni cuenta como gasto.

Al registrar o editar el cobro posterior, selecciona **Pagar con → tu reserva**. También aparecen las reservas originadas en otras cuentas. Si existe una única transferencia propia compatible en los 35 días anteriores, se prepara su vínculo y se muestra antes de guardar; no se añade otro movimiento. Si hay varias, se elige la transferencia en el mismo formulario. Sin una transferencia registrada que aporte dinero reservado, no se inventa saldo ni se atribuye el pago por su descripción.

La parte cubierta reduce la reserva y el saldo real de la cuenta, mantiene el disponible libre y queda fuera del presupuesto mensual. El resto sí consume presupuesto y disponible. Editar un pago recalcula la asignación; borrar una transferencia necesaria para pagos posteriores se impide. Las copias JSON v2 conservan los traslados y los pagos, y se siguen leyendo copias anteriores.

La migración cloud de esta función ya está aplicada en `mi-bombo-money-dev`. El usuario confirma 0.6.8 instalada y el recorrido principal de reservas comprobado en un iPad. **Pendiente:** propagación cloud y recuperación de ese caso. Detalle, ejemplo sintético y comprobaciones: [Reservas entre cuentas](RESERVAS.md). No hace falta borrar datos ni duplicar reservas.

## Integración bancaria de prueba 0.4.2

Disponible en **Ajustes → Opciones avanzadas → Laboratorio bancario** (solo pruebas). Las cuentas personales se conectan desde **Ajustes → Mis bancos** o **Cuentas → + → Conectar banco**. En el laboratorio, al conectar un banco de prueba se puede abrir un espacio separado con Inicio, Cuentas, Movimientos y Presupuestos. Cada servidor y entorno tiene un archivo `MiPatrimonioBankingTests-<entorno>-<hash>.store`, separado de `MiPatrimonio.store`. Un indicador permanente identifica Sandbox o Demostración y permite **Volver a mis finanzas**. Las conexiones existentes tienen un botón para abrir ese espacio.

El despliegue personal ya está configurado en **Sandbox de Enable Banking**. El catálogo verificado permite BBVA, Banco de Sabadell y Mock ASPSP. La versión 0.4.1 admite el dominio oficial de autorización que está devolviendo este sandbox y separa los datos de la demostración anterior. Las credenciales de prueba y los pasos están en [BankingBackend/README.md](BankingBackend/README.md#sandbox-activado-en-el-despliegue-personal).

**Prueba completa lista:** las tres cuentas de Mock ASPSP ya contienen 75 apuntes ficticios. La app 0.4.2 los incorpora como 69 operaciones, reconociendo seis transferencias propias; prepara categorías, presupuestos, reserva del máster y una tarjeta de ejemplo. El escenario tiene su propio archivo local para conservar también los datos manuales del sandbox anterior. Pasos y resultados esperados: [Prueba completa](Samples/sandbox/LEEME.md). El Worker ya está desplegado; instala el IPA nuevo tras pasar Actions. No necesitas repetir comandos ni claves.

**Las cuentas reales siguen bloqueadas y los datos ficticios no se mezclan con tus finanzas reales.** Cloudflare solo aloja el servidor: para llegar a datos reales falta configurar el proveedor y completar la vinculación/conciliación contable. El siguiente paso para uso personal está en [Conectar mis cuentas reales](BankingBackend/CONEXION_REAL_PERSONAL.md). No hay claves compartidas incluidas en la app.

La actualización se realiza al abrir el espacio de prueba o volver a primer plano, con un intervalo mínimo de un minuto, y con **Actualizar**. No se prometen actualizaciones con la app cerrada. Se reciben todas las páginas antes de guardar; los identificadores por servidor/entorno/cuenta evitan duplicar movimientos al actualizar y los saldos contables se guardan sin sumar dos veces el historial. Se aplican las reglas de categorías y, en su ausencia, Otros ingresos/Otros gastos. La prueba admite euros y saldos contables ITBD o CLBD; las cuentas con saldos incompatibles se explican por separado. Se consultan 90 días. Las copias de tus finanzas reales no incluyen este espacio; no se permite importar/exportar copias desde el espacio de prueba para evitar confusiones.

La versión 0.3.1 corrige el cierre en el retorno del navegador y coordina la huella/Face ID del bloqueo general con las operaciones bancarias. Una verificación reciente se reutiliza durante un máximo de 30 segundos; pasar realmente a segundo plano la invalida y sigue ocultando el contenido. Cancelar una autenticación no inicia reintentos automáticos.

## Inicio sin datos de ejemplo

Una instalación nueva empieza sin cuentas, movimientos, presupuestos ni objetivos precargados. Incluye categorías comunes para clasificar tus datos desde el primer movimiento; puedes editarlas, archivarlas o eliminarlas si no están en uso. Desde Inicio o Cuentas puedes añadir tu primera cuenta. La app es universal para iPhone y iPad; el resumen se adapta al ancho disponible y el iPad admite orientación vertical y horizontal. El icono usa la foto de Doge incluida en `MiPatrimonio/Resources/Assets.xcassets`.

Si ya tenías instalada una versión anterior, tus datos existentes se conservan. Para empezar completamente de cero, ve a **Ajustes → Opciones avanzadas → Eliminar todos los datos financieros** y confirma la eliminación. En modo local esta acción borra los datos financieros del dispositivo. En modo cloud la eliminación se sincroniza también con los otros dispositivos de la misma cuenta. Revisa la confirmación y exporta una copia antes de continuar.

## Cuentas, resumen mensual y avisos

Cuentas utiliza todo el ancho disponible con márgenes laterales de 16 puntos. Los accesos para actualizar un saldo, gestionar reservas y consultar aportaciones se distribuyen en una, dos o tres columnas según el espacio y el tamaño de letra. Se mantienen la búsqueda y las acciones de deslizar de cada cuenta.

En Inicio, los recuadros de ingresos, gastos, ahorro e inversión tienen fondo y borde de color para reconocerlos rápidamente: verde, rojo, azul y morado. El ahorro negativo aparece en rojo. Los nombres e iconos también identifican cada concepto.

Cada aviso permite **Revisado · minimizar**. Si todos están revisados, los iconos pasan a una tarjeta compacta en la cabecera; no queda una fila vacía donde estaba la tarjeta grande. La cabecera se apila cuando no cabe en horizontal. Toca un icono para desplegar el aviso. La app recuerda esta preferencia local al cerrarse. Si cambia el gasto, el límite o alguna categoría superada, el aviso se vuelve a desplegar. Cada mes tiene su propio estado de revisión para los presupuestos. Los avisos activos conservan su color y su descripción accesible indica que siguen activos.

Los accesos **Gestionar dinero reservado** y **Aportaciones y cargos periódicos** abren herramientas independientes con **Volver a Cuentas**. **Actualizar saldo o valoración** muestra tarjetas que se adaptan al ancho disponible, con icono, color, banco, nombre de cuenta y saldo actual. En los selectores y movimientos aparece primero el banco y después el nombre de la cuenta, para distinguir varias cuentas de la misma entidad. Si una cuenta no tiene banco, se usa su nombre. Al guardar un movimiento sin descripción, un aviso explica qué falta y permite volver al campo.

## Copia de seguridad y restauración

En **Ajustes → Exportar o restaurar copia**, pulsa **Exportar copia cifrada** y guarda el archivo y su contraseña. Si desactivas la protección puedes exportar un JSON sin cifrar; ambas opciones usan Archivos. La copia incluye todas las entidades financieras locales y sus relaciones: cuentas, entidades, tarjetas, movimientos, presupuestos, presupuestos repetidos, reglas de categorías, objetivos, reservas, reglas periódicas, valoraciones e historial de importación. También se pueden importar copias anteriores que no incluyan las dos funciones nuevas. No incluye las preferencias del dispositivo.

Para recuperar los datos, abre la misma pantalla, pulsa **Elegir copia JSON** y selecciona el archivo. La app valida el formato y los vínculos entre registros y enseña la fecha y un resumen antes de permitir la restauración. Al confirmar, **reemplaza** todos los datos financieros actuales por los del archivo. Haz una copia reciente antes de sustituir datos que quieras conservar.

Puedes exportar una copia cifrada con contraseña (opción predeterminada) o un JSON sin cifrar. El JSON sin cifrar contiene los datos financieros en claro; guárdalo en una ubicación privada. Las copias nuevas usan AES-256-GCM con PBKDF2-SHA256 y se siguen leyendo las copias cifradas anteriores. Actualizar la app sin desinstalarla conserva normalmente los datos locales, pero la copia permite recuperarlos si reinstalas la app o cambias de dispositivo.

El workflow **Comprobar datos y cálculos** ejecuta en macOS una prueba de exportación y restauración de todos los modelos, restauración repetida sin duplicados, compatibilidad con copias antiguas, rechazo de archivos inválidos y conservación de datos ante una copia inválida. El formato JSON lleva su propia versión, independiente de la versión de la app.

## Entidades y tarjetas

En **Ajustes → Bancos y entidades** puedes elegir el color con el selector visual de iOS. Al abrir una entidad verás sus cuentas y tarjetas, y podrás añadir una tarjeta con la entidad ya seleccionada. También puedes crear una tarjeta desde **Cuentas** o desde el detalle de una cuenta.

Cada tarjeta puede vincularse a una cuenta y guardar los últimos cuatro dígitos, un límite con su tipo, el estado de compras online, pagos sin contacto, retiradas en cajero, pagos internacionales, cashback y redondeo de compras. Los estados nuevos aparecen como «Sin indicar» hasta que los configures. Son datos de consulta local: la app no cambia la configuración de la tarjeta en el banco ni ejecuta cashback o redondeos.

## Dinero reservado y aportaciones a inversión

En **Ajustes → Dinero reservado** puedes indicar, por ejemplo, cuánto dinero de una cuenta está destinado al máster. También puedes hacerlo desde el detalle de esa cuenta. La reserva no modifica el saldo real ni el patrimonio total: aparece descontada del **Disponible para usar** en Inicio y de la cantidad disponible en la cuenta. Cuando pagues el máster, registra el gasto y selecciona esa reserva en «Pagar con»: el importe pendiente se recalcula automáticamente. No lo reduzcas otra vez a mano. Si la reserva supera el saldo de la cuenta, el disponible aparecerá negativo para mostrar el importe que falta.

Para una aportación mensual, crea primero la cuenta de valores como cuenta de tipo **Inversión**. Después abre **Ajustes → Movimientos recurrentes → Programar aportación mensual a inversión**, elige cuenta origen, cuenta de valores, importe y próxima fecha. La app registrará las mensualidades pendientes al abrirse o volver a primer plano, con una transferencia por fecha prevista y protección frente a duplicados de la misma regla. Esta transferencia reduce el saldo de origen, aumenta el de inversión y se muestra como **Aportado a inversión** en el resumen mensual. No es un gasto, así que no reduce el patrimonio total por sí misma. Puedes pausar o editar la regla en Movimientos recurrentes.

## Suscripciones, recibos e ingresos automáticos

Desde **Cuentas → Aportaciones y cargos periódicos → Añadir suscripción o recibo** puedes indicar nombre, importe, banco y cuenta, categoría, periodicidad, próxima fecha y fecha de fin opcional. Usa **+** para otros movimientos periódicos, incluidos ingresos y transferencias. Las nuevas reglas tienen **Registrar automáticamente** activado; puedes desactivarlo para confirmarlas manualmente. Las reglas anteriores conservan su configuración.

Al abrir la app o volver a primer plano se registran los vencimientos pendientes, una vez por regla y fecha prevista. Una suscripción o comisión resta de su cuenta y cuenta en los gastos y el presupuesto de la categoría elegida; un ingreso suma a su cuenta. Las aportaciones a inversión mantienen su tratamiento de transferencia propia. Puedes pausar, editar o eliminar las reglas, y la copia de seguridad incluye su configuración automática. Las reglas con una cuenta archivada o una categoría incompatible no se registran automáticamente.

## Reglas de categorías y presupuestos repetidos

Al introducir un movimiento, la app preselecciona la última cuenta activa utilizada y puedes activar **Recordar esta categoría para esta descripción**. Puedes escribir una frase corta como «Mercadona» o dejar el campo vacío para usar toda la descripción. La próxima vez que una descripción contenga esa frase, la app propondrá la misma categoría; si la cambias manualmente, respetará tu elección. Puedes crear reglas más generales, editarlas, pausarlas o borrarlas en **Ajustes → Reglas de categorías**. Las reglas también se aplican en la vista previa de importación CSV cuando el archivo no trae una categoría reconocida. La frase más específica tiene prioridad.

En **Presupuestos**, crea o abre un límite y elige **Repetir desde este mes**. Indica el importe base y qué hacer si sobra: **Dejarlo como ahorro** mantiene el importe base el mes siguiente; **Añadirlo al mes siguiente** suma el sobrante al límite del próximo mes cuando termine el mes anterior. También puedes modificar solo un mes o detener la repetición desde el mes elegido. El sobrante afecta únicamente al presupuesto disponible; no mueve dinero ni crea un ingreso o una transferencia. Los importes se calculan con los gastos reales y se actualizan si corriges un movimiento anterior. Los meses futuros aún no incorporan un sobrante pendiente de confirmar.

## Rediseño 0.2.10

Esta entrega incorpora un rediseño completo de la experiencia de uso sin cambiar el modelo financiero ni los datos guardados:

- Inicio con saludo según la hora, patrimonio y dinero disponible, sin repetir la lista de cuentas.
- Diseño dinámico según el espacio disponible: las tarjetas de Inicio y Presupuestos se distribuyen en columnas cuando caben y se apilan al estrechar la ventana. El ancho mínimo de las tarjetas crece con el tamaño de letra, y los tamaños de accesibilidad usan una columna. Funciona igual al rotar, usar pantalla dividida o redimensionar la ventana, sin detectar un modelo de dispositivo.
- Avisos accionables y resumen global de presupuesto; la tasa de ahorro aparece como información compacta.
- Botón rápido de movimiento abajo a la derecha, solo en Inicio y Movimientos.
- Análisis de gastos dentro de Movimientos y comparativa presupuestaria dentro de Presupuestos.
- Cuentas orientada a la gestión: búsqueda por nombre o banco, selector Cuentas / Tarjetas y agrupación por día a día, ahorro, inversiones y deudas.
- Acceso directo para actualizar un saldo o valoración, revisar cuentas sin actualizar y gestionar reservas y aportaciones periódicas. Las tarjetas vinculadas no repiten el saldo de la cuenta.
- Presupuestos sin configurar agrupados en una tarjeta de iconos; al tocar uno se abre su editor. Un punto naranja identifica categorías con gasto sin límite.
- Gráfico de gasto frente a límite para los seis presupuestos con mayor uso, con acceso a la comparativa completa. El gráfico se oculta al ocultar importes.
- Ajustes simplificados y redactados para usuarios no técnicos.
- Filas y cabeceras que pasan a disposición vertical si el texto y los importes no caben juntos; gráficos cuya altura acompaña al tamaño de letra.
- El botón de añadir movimiento se coloca en el área segura de la pantalla, respetando la posición de la barra de pestañas.
- Sistema visual común, modo oscuro y mejoras de accesibilidad.

Consulta `CAMBIOS_REDISENO.md` para el detalle y `PRUEBAS_REDISENO.md` para una lista práctica de comprobaciones en Appetize o en un dispositivo iOS.

## Requisitos

- macOS con Xcode 16 o posterior recomendado.
- iOS 17.0 o posterior.
- Un equipo de firma configurado para ejecutar en un iPhone o iPad físico; el simulador no exige biometría real y ofrece la simulación desde Xcode.

## Ejecutar

1. Abre `MiPatrimonio.xcodeproj`.
2. Selecciona el target `MiPatrimonio`.
3. En **Signing & Capabilities**, elige tu equipo.
4. Selecciona un iPhone, iPad o simulador.
5. Pulsa Run.

No hay dependencias de terceros ni pasos de instalación.

## Qué contiene el MVP

- Patrimonio total y saldo derivado de cada cuenta.
- Cuentas corrientes, ahorro, efectivo, crédito, inversiones y otras.
- Tarjetas como medios de pago vinculados, con opciones de uso y ventajas, sin guardar PAN completo ni CVV.
- Ingresos, gastos, intereses, comisiones y transferencias internas.
- Categorías, presupuestos, objetivos y reglas periódicas.
- Búsqueda y filtros de movimientos.
- Gráficos de patrimonio, categorías y presupuesto.
- Valoraciones puntuales para inversiones o conciliación.
- Importación CSV con revisión y detección de duplicados.
- Face ID, Touch ID o código del dispositivo.
- Ocultación de importes y apariencia clara, oscura o automática.
- Almacenamiento SwiftData local con CloudKit desactivado.

## Inicialización local

La app no inserta saldos ni movimientos de ejemplo. En una instalación nueva solo crea el catálogo de categorías habituales. Al registrar un movimiento, propone una categoría general según su tipo y exige que elijas una válida. En **Ajustes → Categorías** puedes cambiar el nombre, el icono y el color mediante controles visuales; el menú de opciones permite volver a añadir las categorías habituales que falten. En **Presupuestos → Crear presupuesto** puedes seleccionar una categoría sin límite y fijar su presupuesto para el mes mostrado. Las tarjetas vinculadas muestran su cuenta asociada, sin repetir su saldo.

## Movimientos por revisar

La nueva tarjeta **Por revisar** reúne posibles duplicados y movimientos sin categoría o con una categoría incompatible. Desde el detalle puedes asignar una categoría con su icono, usar una regla sugerida o conservar un movimiento que no está duplicado. La elección de categoría puede recordarse para próximos conceptos similares. Se respetan los filtros y la ocultación de importes. Implementación y pruebas de la próxima compilación: [REVISION_MOVIMIENTOS.md](REVISION_MOVIMIENTOS.md).

## Importación CSV

En `Samples/` se incluyen:

- `plantilla_csv_minima.csv`: fecha, concepto, importe y referencia.
- `ejemplo_importacion.csv`: formato completo con cuentas, tipo, categoría y transferencias.

El importador acepta `;`, `,` o tabulador; UTF-8, Latin-1 y Windows-1252; y varias cabeceras habituales en español e inglés. Los duplicados exactos se omiten. Los posibles duplicados se muestran desmarcados.

En la revisión, toca el nombre o el icono de una categoría para cambiarla. Puedes activar **Recordar como regla** y elegir una frase de la descripción: por ejemplo, «Mercadona» en lugar del concepto completo. **Aplicar** prepara la corrección; la categoría y la regla se guardan al pulsar **Importar**. Las filas desmarcadas o duplicadas no guardan reglas. Cambiar de archivo descarta las correcciones pendientes. Si hay más de 200 filas, **Mostrar más movimientos** permite revisarlas todas.

La corrección manual tiene prioridad en esa fila. Las reglas se usarán en futuros movimientos y en futuras importaciones sin categoría reconocida; las demás filas de la revisión actual conservan su categoría. Una misma frase y tipo actualiza la regla existente, sin crear otra. Si dos correcciones proponen categorías distintas para la misma regla, la app pide resolverlo antes de guardar. Las reglas se incluyen en la copia JSON habitual.

La importación `.xlsx` bancaria queda para la siguiente fase porque iOS no ofrece un lector nativo de Excel y conviene seleccionar y probar una biblioteca local con ficheros reales de cada banco.

## Seguridad

- No se solicitan ni guardan contraseñas bancarias.
- La autenticación usa la política de propietario del dispositivo.
- La app se bloquea al pasar a segundo plano.
- El almacén se crea en Application Support y se marca con protección completa de archivos.
- CloudKit está desactivado.
- `LocalEncryptionService` genera su clave AES-GCM en el primer uso y la guarda en Keychain con acceso solo mientras el dispositivo está desbloqueado y sin migración a otro dispositivo. El almacén SwiftData se protege mediante Data Protection; no se presenta el helper AES como sustituto de SQLCipher.

El MVP usa el cifrado de datos de iOS mediante Data Protection. No añade SQLCipher al almacén SwiftData.

## Estructura

```text
MiPatrimonio/
  App/                 punto de entrada, bloqueo y pestañas
  Core/Models/         entidades SwiftData
  Core/Persistence/    almacén local
  Core/Security/       LocalAuthentication, Keychain y AES-GCM
  Core/Services/       cálculos, CSV, duplicados y periódicos
  Features/            pantallas por funcionalidad
  Shared/              formato, apariencia y componentes
  Resources/           Info.plist e icono de la app
```

## Diseño visual

La revisión de navegación cloud, paletas clara/oscura y distribución adaptable de Inicio se documenta en [DISENO_VISUAL_2026_10_29.md](DISENO_VISUAL_2026_10_29.md), con sus referencias y pruebas pendientes en dispositivos.

## Verificación antes del merge

La revisión local del 5 de octubre de 2026 ha comprobado la sintaxis de los 31 archivos Swift de la app y los dos archivos de pruebas, las referencias del proyecto Xcode, el esquema compartido, `Info.plist`, los recursos del icono y los cuatro workflows con actionlint. Los detalles y las correcciones están en `REVISION_PRE_MERGE.md`.

Estas comprobaciones locales no equivalen a compilar con el SDK de iOS. GitHub Actions compila la app completa en Debug para simulador y en Release para dispositivo; también ejecuta pruebas de exportación/restauración, reservas, transferencias, presupuestos repetidos, reglas, CSV, servidor bancario y política de conexión del cliente. Hay que esperar a que todas las comprobaciones del último commit terminen correctamente antes del merge. La revisión visual en dispositivos sigue la lista de `PRUEBAS_REDISENO.md`.

Consulta `ESPECIFICACION_FUNCIONAL_Y_TECNICA.md` para el análisis completo, el diseño de pantallas, el modelo, las fórmulas, la arquitectura y el plan por fases.

## Probar desde Windows mediante GitHub Actions

El repositorio incluye `.github/workflows/build-ios-simulator.yml`, mostrado en Actions como **Validar app iOS**. Cada subida a `main` o a una rama `codex/…`, y cada pull request hacia `main`, compila el proyecto en un runner macOS de GitHub en Debug para simulador y Release para dispositivo sin firma. La compilación del simulador genera el artefacto `MiPatrimonio-iOS-Simulator`. El workflow **Comprobar datos y cálculos** ejecuta las pruebas en cada subida y pull request.

Desde GitHub Desktop, haz commit de los cambios y pulsa **Push origin** manteniéndote en tu rama. Abre **Actions** y espera a que **Validar app iOS** y **Comprobar datos y cálculos** estén en verde para ese commit. No necesitas hacer merge para comprobarlo. También puedes usar **Run workflow** seleccionando la rama.

Al terminar, descarga el artefacto desde la página de la ejecución. El archivo `MiPatrimonio-Simulator.zip` contiene la aplicación `.app` compilada para el simulador; no es un `.ipa` instalable directamente en un iPhone o iPad físico. La comprobación de Release guarda su registro y valida la compilación usada por el generador de IPA.

Consulta `SUBIR_DESDE_WINDOWS.md` para las instrucciones de subida.

## Generar un IPA desde GitHub Actions

El repositorio dispone de dos procesos adicionales:

- `.github/workflows/build-ios-ipa.yml`: crea inmediatamente un IPA sin firmar para instalarlo posteriormente mediante AltStore, Sideloadly u otro proceso de firma.
- `.github/workflows/build-ios-ipa-signed.yml`: crea un IPA firmado e instalable en los dispositivos incluidos en el perfil de aprovisionamiento, una vez configurados los certificados como GitHub Actions Secrets.

Desde GitHub entra en **Actions**, selecciona el workflow correspondiente y pulsa **Run workflow**. Consulta `DISTRIBUCION_IPA.md` para la configuración completa y las medidas de seguridad.

## Enable Banking personal · 0.6.2

Conexión personal separada del sandbox, autenticada con Supabase, con selección de bancos del proveedor y vinculación con cuentas existentes. La importación concilia pagos ya registrados y conserva reservas; la primera descarga requiere revisión. La revisión 0.6.2 añade comparación con registros existentes, propuestas confirmables en conjunto y contadores de nuevos, reconocidos y dudas. Está preparada localmente; quedan los checks macOS y la instalación. [Estado, seguridad, pruebas y piloto Bankinter](BankingBackend/INTEGRACION_PERSONAL.md).

## UX y revisión · 0.6.3

Primera adaptación a la referencia oscura elegida en Stitch, conservando los modos Claro, Oscuro y Automático. Inicio separa disponible y reservado y sitúa Añadir movimiento en la barra. Las filas compartidas miden su contenido para evitar huecos grandes; Por revisar deja de activar un filtro vacío cuando no hay incidencias. Incluye navegación adaptable desde iOS 18. Preparado localmente y con pruebas de geometría y revisión aprobadas; quedan checks macOS y revisión física. La gestión de inversión/reinversión se estudiará después del UX. [Detalle de implementación, pruebas y pendientes](DISENO_VISUAL_2026_10_29.md#evolución-del-3-de-noviembre-de-2026--063).

## Ajustes simplificados · 0.6.4

Búsqueda por nombre y tarea, acceso directo a Mis bancos y Mi nube y opciones secundarias desplegables en la misma pantalla. Laboratorio, resumen de datos y eliminación confirmada quedan en Avanzado. Se retiran la opción de Excel sin implementar y textos bancarios obsoletos. Las funciones financieras, copias y autenticación se conservan. [Mapa de navegación, comprobaciones y pendientes](AJUSTES.md).

## Consultas bancarias manuales y límites · 0.6.5

Corrección del error bancario 429: el botón de actualización identifica una consulta iniciada por el usuario y el servidor envía su contexto PSU validado. Las consultas automáticas mantienen sus límites. La app muestra el banco y la cuenta que fallan, respeta Retry-After con espera persistente y no deja una descarga anterior lista para incorporar tras un error.

Servidor personal actualizado; cliente 0.6.5 (22) preparado localmente. Pasan 46 pruebas Node/workerd, las pruebas Swift de política y el empaquetado del servidor. Pendientes: checks de macOS/iOS e instalación para validar BBVA. [Detalle técnico y diagnóstico](BankingBackend/INTEGRACION_PERSONAL.md#consultas-bancarias-y-límites--065).

## Bancos independientes · 0.6.6

Las descargas y esperas se gestionan por banco: un error de Bankinter no descarta los movimientos completos de BBVA. Mis bancos muestra el resultado de cada entidad, permite actualizarla por separado y ofrece acceso directo a incorporar la primera descarga revisada. Las transferencias propias sin una pareja compatible quedan diferidas sin contarlas como gasto o ingreso; los demás movimientos pueden continuar.

Preparado localmente: 0.6.6 (23). Pasan tres suites Swift de política, planificación y coordinación con datos sintéticos. Pendientes: persistencia SwiftData y compilación iOS/macOS en GitHub, instalación y prueba real. Se conserva la espera global heredada de 0.6.5 hasta su vencimiento. [Detalle y límites](BankingBackend/INTEGRACION_PERSONAL.md#descargas-y-esperas-independientes-por-banco--066).

## Descarga después de conectar · 0.6.7

Autorizar o asociar una cuenta solicita directamente la descarga de ese banco. Se separan el catálogo y las conexiones existentes, las esperas manuales y automáticas, y la descarga y su incorporación contable. Los movimientos recibidos se muestran en la revisión; la primera incorporación requiere confirmación. La cuenta auxiliar no asociada sigue excluida.

Cliente 0.6.7 (24) preparado. Pasan tres suites Swift locales, análisis sintáctico y revisión de espacios. Pendientes: checks de iOS/macOS e instalación para verificar la descarga real. Los recuentos remotos confirman registros conservados; no se han alterado datos ni saldos para esta comprobación. [Detalle](BankingBackend/INTEGRACION_PERSONAL.md#preparar-y-mostrar-la-descarga-al-conectar--067).
