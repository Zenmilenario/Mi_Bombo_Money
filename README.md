# Mi Patrimonio — iPhone y iPad

Aplicación SwiftUI local para consolidar cuentas, efectivo, tarjetas, ahorro e inversiones.

## Inicio sin datos de ejemplo

Una instalación nueva empieza sin cuentas, movimientos, categorías, presupuestos ni objetivos precargados. Desde Inicio o Cuentas puedes añadir tu primera cuenta y registrar tus datos. La app es universal para iPhone y iPad; el resumen se adapta al ancho disponible y el iPad admite orientación vertical y horizontal. El icono usa la foto de Doge incluida en `MiPatrimonio/Resources/Assets.xcassets`.

Si ya tenías instalada una versión anterior, tus datos existentes se conservan. Para empezar completamente de cero, ve a **Ajustes → Datos → Empezar desde cero** y confirma la eliminación. Esta acción borra todos los datos financieros locales y no se puede deshacer.

## Entidades y tarjetas

En **Ajustes → Bancos y entidades** puedes elegir el color con el selector visual de iOS. Al abrir una entidad verás sus cuentas y tarjetas, y podrás añadir una tarjeta con la entidad ya seleccionada. También puedes crear una tarjeta desde **Cuentas** o desde el detalle de una cuenta.

Cada tarjeta puede vincularse a una cuenta y guardar los últimos cuatro dígitos, un límite con su tipo, el estado de compras online, pagos sin contacto, retiradas en cajero, pagos internacionales, cashback y redondeo de compras. Los estados nuevos aparecen como «Sin indicar» hasta que los configures. Son datos de consulta local: la app no cambia la configuración de la tarjeta en el banco ni ejecuta cashback o redondeos.

## Dinero reservado y aportaciones a inversión

En **Ajustes → Dinero reservado** puedes indicar, por ejemplo, cuánto dinero de una cuenta está destinado al máster. También puedes hacerlo desde el detalle de esa cuenta. La reserva no modifica el saldo real ni el patrimonio total: aparece descontada del **Disponible para usar** en Inicio y de la cantidad disponible en la cuenta. Cuando pagues el máster, registra el gasto y reduce o elimina la reserva para evitar descontarlo dos veces. Si la reserva supera el saldo de la cuenta, el disponible aparecerá negativo para mostrar el importe que falta.

Para una aportación mensual, crea primero la cuenta de valores como cuenta de tipo **Inversión**. Después abre **Ajustes → Movimientos recurrentes → Programar aportación mensual a inversión**, elige cuenta origen, cuenta de valores, importe y próxima fecha. La app registrará las mensualidades pendientes al abrirse o volver a primer plano, con una transferencia por fecha prevista y protección frente a duplicados de la misma regla. Esta transferencia reduce el saldo de origen, aumenta el de inversión y se muestra como **Aportado a inversión** en el resumen mensual. No es un gasto, así que no reduce el patrimonio total por sí misma. Puedes pausar o editar la regla en Movimientos recurrentes.

## Rediseño 0.2.0

Esta entrega incorpora un rediseño completo de la experiencia de uso sin cambiar el modelo financiero ni los datos guardados:

- Inicio más corto y jerarquizado, con métricas mensuales en cuadrícula adaptable.
- Avisos accionables y resumen global de presupuesto.
- Botón rápido de movimiento abajo a la derecha, solo en Inicio y Movimientos.
- Análisis de gastos dentro de Movimientos y comparativa presupuestaria dentro de Presupuestos.
- Resumen de activos, deudas y patrimonio neto en Cuentas.
- Ajustes simplificados y redactados para usuarios no técnicos.
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

La app ya no inserta datos de ejemplo al abrirse. En una instalación nueva, la base local está vacía hasta que añadas cuentas, categorías y movimientos o importes un archivo CSV.

## Importación CSV

En `Samples/` se incluyen:

- `plantilla_csv_minima.csv`: fecha, concepto, importe y referencia.
- `ejemplo_importacion.csv`: formato completo con cuentas, tipo, categoría y transferencias.

El importador acepta `;`, `,` o tabulador; UTF-8, Latin-1 y Windows-1252; y varias cabeceras habituales en español e inglés. Los duplicados exactos se omiten. Los posibles duplicados se muestran desmarcados.

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

## Verificación realizada en esta entrega

- Todos los archivos Swift pasan el parser del compilador Swift 6.2.
- `Info.plist` y `project.pbxproj` pasan validación de plist.
- La lógica del Excel se contrastó contra sus hojas, saldos y fórmulas.

El entorno de generación no incluye Xcode ni el SDK de iOS, por lo que la compilación final, las previews y la ejecución en simulador deben verificarse en macOS antes de publicar.

Consulta `ESPECIFICACION_FUNCIONAL_Y_TECNICA.md` para el análisis completo, el diseño de pantallas, el modelo, las fórmulas, la arquitectura y el plan por fases.

## Probar desde Windows mediante GitHub Actions

El repositorio incluye `.github/workflows/build-ios-simulator.yml`. Cada subida a `main` intenta compilar el proyecto en un runner macOS de GitHub y genera el artefacto `MiPatrimonio-iOS-Simulator`.

Desde Windows, entra en **Actions**, abre **Compilar para iOS Simulator** y ejecuta **Run workflow**. Al terminar, descarga el artefacto desde la página de la ejecución. El archivo `MiPatrimonio-Simulator.zip` contiene la aplicación `.app` compilada para el simulador; no es un `.ipa` instalable directamente en un iPhone o iPad físico.

Consulta `SUBIR_DESDE_WINDOWS.md` para las instrucciones de subida.

## Generar un IPA desde GitHub Actions

El repositorio dispone de dos procesos adicionales:

- `.github/workflows/build-ios-ipa.yml`: crea inmediatamente un IPA sin firmar para instalarlo posteriormente mediante AltStore, Sideloadly u otro proceso de firma.
- `.github/workflows/build-ios-ipa-signed.yml`: crea un IPA firmado e instalable en los dispositivos incluidos en el perfil de aprovisionamiento, una vez configurados los certificados como GitHub Actions Secrets.

Desde GitHub entra en **Actions**, selecciona el workflow correspondiente y pulsa **Run workflow**. Consulta `DISTRIBUCION_IPA.md` para la configuración completa y las medidas de seguridad.
