# Mi Patrimonio — MVP iPhone

Aplicación SwiftUI local para consolidar cuentas, efectivo, tarjetas, ahorro e inversiones. El proyecto parte del Excel `Control_financiero_3_bancos(3).xlsx` y carga sus datos iniciales la primera vez que se ejecuta.

El archivo Excel original no se incluye dentro del proyecto empaquetado; solo se incorporan la estructura, las reglas y los datos iniciales necesarios para el seed.


## Rediseño 0.2.0

Esta entrega incorpora un rediseño completo de la experiencia de uso sin cambiar el modelo financiero ni los datos guardados:

- Inicio más corto y jerarquizado, con métricas mensuales en cuadrícula 2 × 2.
- Avisos accionables y resumen global de presupuesto.
- Botón rápido de movimiento abajo a la derecha, solo en Inicio y Movimientos.
- Análisis de gastos dentro de Movimientos y comparativa presupuestaria dentro de Presupuestos.
- Resumen de activos, deudas y patrimonio neto en Cuentas.
- Ajustes simplificados y redactados para usuarios no técnicos.
- Sistema visual común, modo oscuro y mejoras de accesibilidad.

Consulta `CAMBIOS_REDISENO.md` para el detalle y `PRUEBAS_REDISENO.md` para una lista práctica de comprobaciones en Appetize o en un iPhone.

## Requisitos

- macOS con Xcode 16 o posterior recomendado.
- iOS 17.0 o posterior.
- Un equipo de firma configurado para ejecutar en un iPhone físico; el simulador no exige biometría real y ofrece la simulación desde Xcode.

## Ejecutar

1. Abre `MiPatrimonio.xcodeproj`.
2. Selecciona el target `MiPatrimonio`.
3. En **Signing & Capabilities**, elige tu equipo.
4. Selecciona un iPhone o simulador.
5. Pulsa Run.

No hay dependencias de terceros ni pasos de instalación.

## Qué contiene el MVP

- Patrimonio total y saldo derivado de cada cuenta.
- Cuentas corrientes, ahorro, efectivo, crédito, inversiones y otras.
- Tarjetas como medios de pago vinculados, sin guardar PAN completo ni CVV.
- Ingresos, gastos, intereses, comisiones y transferencias internas.
- Categorías, presupuestos, objetivos y reglas periódicas.
- Búsqueda y filtros de movimientos.
- Gráficos de patrimonio, categorías y presupuesto.
- Valoraciones puntuales para inversiones o conciliación.
- Importación CSV con revisión y detección de duplicados.
- Face ID, Touch ID o código del dispositivo.
- Ocultación de importes y apariencia clara, oscura o automática.
- Almacenamiento SwiftData local con CloudKit desactivado.

## Datos iniciales del Excel

La primera ejecución crea:

- Bankinter — Nómina: 850,00 € después de la transferencia.
- Trade Republic — Ahorro: 650,00 € después de la transferencia.
- BBVA — Cuenta joven: 540,66 €.
- Patrimonio: 2.040,66 €.
- Presupuesto de julio de 2026: 900,00 €.

El seed se ejecuta una sola vez y únicamente si la base está vacía. Para repetirlo durante desarrollo, elimina la app del simulador o dispositivo y vuelve a instalarla.

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
  Core/Seed/           datos derivados del Excel
  Features/            pantallas por funcionalidad
  Shared/              formato, apariencia y componentes
  Resources/           Info.plist
```

## Verificación realizada en esta entrega

- Todos los archivos Swift pasan el parser del compilador Swift 6.2.
- `Info.plist` y `project.pbxproj` pasan validación de plist.
- La lógica del Excel se contrastó contra sus hojas, saldos y fórmulas.

El entorno de generación no incluye Xcode ni el SDK de iOS, por lo que la compilación final, las previews y la ejecución en simulador deben verificarse en macOS antes de publicar.

Consulta `ESPECIFICACION_FUNCIONAL_Y_TECNICA.md` para el análisis completo, el diseño de pantallas, el modelo, las fórmulas, la arquitectura y el plan por fases.

## Probar desde Windows mediante GitHub Actions

El repositorio incluye `.github/workflows/build-ios-simulator.yml`. Cada subida a `main` intenta compilar el proyecto en un runner macOS de GitHub y genera el artefacto `MiPatrimonio-iOS-Simulator`.

Desde Windows, entra en **Actions**, abre **Compilar para iOS Simulator** y ejecuta **Run workflow**. Al terminar, descarga el artefacto desde la pagina de la ejecucion. El archivo `MiPatrimonio-Simulator.zip` contiene la aplicacion `.app` compilada para el simulador; no es un `.ipa` instalable directamente en un iPhone.

Consulta `SUBIR_DESDE_WINDOWS.md` para las instrucciones de subida.
