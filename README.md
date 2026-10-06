# Mi Patrimonio — iPhone y iPad

Aplicación SwiftUI local para consolidar cuentas, efectivo, tarjetas, ahorro e inversiones.

## Inicio sin datos de ejemplo

Una instalación nueva empieza sin cuentas, movimientos, presupuestos ni objetivos precargados. Incluye categorías comunes para clasificar tus datos desde el primer movimiento; puedes editarlas, archivarlas o eliminarlas si no están en uso. Desde Inicio o Cuentas puedes añadir tu primera cuenta. La app es universal para iPhone y iPad; el resumen se adapta al ancho disponible y el iPad admite orientación vertical y horizontal. El icono usa la foto de Doge incluida en `MiPatrimonio/Resources/Assets.xcassets`.

Si ya tenías instalada una versión anterior, tus datos existentes se conservan. Para empezar completamente de cero, ve a **Ajustes → Datos → Empezar desde cero** y confirma la eliminación. Esta acción borra todos los datos financieros locales y no se puede deshacer.

## Cuentas, resumen mensual y avisos

Cuentas utiliza todo el ancho disponible con márgenes laterales de 16 puntos. Los accesos para actualizar un saldo, gestionar reservas y consultar aportaciones se distribuyen en una, dos o tres columnas según el espacio y el tamaño de letra. Se mantienen la búsqueda y las acciones de deslizar de cada cuenta.

En Inicio, los recuadros de ingresos, gastos, ahorro e inversión tienen fondo y borde de color para reconocerlos rápidamente: verde, rojo, azul y morado. El ahorro negativo aparece en rojo. Los nombres e iconos también identifican cada concepto.

Cada aviso permite **Revisado · minimizar**. Queda un icono a la derecha que puedes tocar para desplegarlo de nuevo; si todos están revisados, la tarjeta se convierte en un recordatorio compacto. La app recuerda esta preferencia local al cerrarse. Si cambia el gasto, el límite o alguna categoría superada, el aviso se vuelve a desplegar. Cada mes tiene su propio estado de revisión para los presupuestos. Los avisos activos conservan su color y se identifican como **Revisados · siguen activos**.

## Copia de seguridad y restauración

En **Ajustes → Datos → Copia de seguridad**, pulsa **Exportar todos mis datos** y guarda el archivo JSON en Archivos, por ejemplo en una carpeta privada de iCloud Drive. La copia incluye todas las entidades financieras locales y sus relaciones: cuentas, entidades, tarjetas, movimientos, presupuestos, presupuestos repetidos, reglas de categorías, objetivos, reservas, reglas periódicas, valoraciones e historial de importación. También se pueden importar copias anteriores que no incluyan las dos funciones nuevas. No incluye las preferencias del dispositivo.

Para recuperar los datos, abre la misma pantalla, pulsa **Elegir copia JSON** y selecciona el archivo. La app valida el formato y los vínculos entre registros y enseña la fecha y un resumen antes de permitir la restauración. Al confirmar, **reemplaza** todos los datos financieros actuales por los del archivo. Haz una copia reciente antes de sustituir datos que quieras conservar.

El JSON no está cifrado ni protegido por contraseña; guárdalo en una ubicación privada y no lo compartas. Actualizar la app sin desinstalarla conserva normalmente los datos locales, pero la copia permite recuperarlos si reinstalas la app o cambias de dispositivo.

El workflow **Comprobar datos y cálculos** ejecuta en macOS una prueba de exportación y restauración de todos los modelos, restauración repetida sin duplicados, compatibilidad con copias antiguas, rechazo de archivos inválidos y conservación de datos ante una copia inválida. El formato JSON lleva su propia versión, independiente de la versión de la app.

## Entidades y tarjetas

En **Ajustes → Bancos y entidades** puedes elegir el color con el selector visual de iOS. Al abrir una entidad verás sus cuentas y tarjetas, y podrás añadir una tarjeta con la entidad ya seleccionada. También puedes crear una tarjeta desde **Cuentas** o desde el detalle de una cuenta.

Cada tarjeta puede vincularse a una cuenta y guardar los últimos cuatro dígitos, un límite con su tipo, el estado de compras online, pagos sin contacto, retiradas en cajero, pagos internacionales, cashback y redondeo de compras. Los estados nuevos aparecen como «Sin indicar» hasta que los configures. Son datos de consulta local: la app no cambia la configuración de la tarjeta en el banco ni ejecuta cashback o redondeos.

## Dinero reservado y aportaciones a inversión

En **Ajustes → Dinero reservado** puedes indicar, por ejemplo, cuánto dinero de una cuenta está destinado al máster. También puedes hacerlo desde el detalle de esa cuenta. La reserva no modifica el saldo real ni el patrimonio total: aparece descontada del **Disponible para usar** en Inicio y de la cantidad disponible en la cuenta. Cuando pagues el máster, registra el gasto y reduce o elimina la reserva para evitar descontarlo dos veces. Si la reserva supera el saldo de la cuenta, el disponible aparecerá negativo para mostrar el importe que falta.

Para una aportación mensual, crea primero la cuenta de valores como cuenta de tipo **Inversión**. Después abre **Ajustes → Movimientos recurrentes → Programar aportación mensual a inversión**, elige cuenta origen, cuenta de valores, importe y próxima fecha. La app registrará las mensualidades pendientes al abrirse o volver a primer plano, con una transferencia por fecha prevista y protección frente a duplicados de la misma regla. Esta transferencia reduce el saldo de origen, aumenta el de inversión y se muestra como **Aportado a inversión** en el resumen mensual. No es un gasto, así que no reduce el patrimonio total por sí misma. Puedes pausar o editar la regla en Movimientos recurrentes.

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

## Verificación antes del merge

La revisión local del 5 de octubre de 2026 ha comprobado la sintaxis de los 31 archivos Swift de la app y los dos archivos de pruebas, las referencias del proyecto Xcode, el esquema compartido, `Info.plist`, los recursos del icono y los cuatro workflows con actionlint. Los detalles y las correcciones están en `REVISION_PRE_MERGE.md`.

Estas comprobaciones locales no equivalen a compilar con el SDK de iOS. GitHub Actions compila la app completa en Debug para simulador y en Release para dispositivo; también ejecuta pruebas de exportación/restauración, reservas, transferencias, presupuestos repetidos, reglas y CSV. Hay que esperar a que esas cuatro comprobaciones terminen correctamente antes del merge. La revisión visual en dispositivos sigue la lista de `PRUEBAS_REDISENO.md`.

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
