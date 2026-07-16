# Validación del entregable

Fecha de validación: 16 de julio de 2026.

## Alcance comprobado

- 26 archivos Swift presentes e incluidos en la fase `Sources` del target `MiPatrimonio`.
- Sintaxis de todos los archivos Swift comprobada con `swiftc -frontend -parse`.
- `Info.plist` y `project.pbxproj` validados con `plutil`.
- Proyecto Xcode regenerado desde `Tools/generate_xcodeproj.py` y comprobado para evitar referencias de fuente ausentes.
- Parser CSV compilado y ejecutado de forma aislada con seis movimientos válidos, incluidos formatos decimales españoles, comillas y transferencias.
- Motor financiero compilado y ejecutado de forma aislada con casos de saldo inicial, ingresos, gastos, comisiones, transferencias, presupuestos, valoraciones y pasivos.
- Los casos del Excel reproducen: Bankinter 850,00 €, Trade Republic 650,00 €, BBVA 540,66 € y patrimonio 2.040,66 €.
- Las dos transferencias iniciales no alteran ingresos, gastos ni ahorro mensual.

## Comprobaciones de seguridad y privacidad

- CloudKit está desactivado en `ModelConfiguration`.
- El almacén se crea en `Application Support` y recibe `FileProtectionType.complete`.
- El bloqueo usa `LocalAuthentication` con política de propietario del dispositivo, que admite biometría o código.
- El proyecto no contiene campos para contraseñas bancarias, PIN ni CVV.
- Las tarjetas solo admiten los últimos cuatro dígitos opcionales.
- Keychain usa accesibilidad `WhenUnlockedThisDeviceOnly`.
- El modo de privacidad oculta importes y gráficos financieros.

## Límite de esta validación

Este entorno es Linux y no incluye Xcode ni el SDK de iOS. Por ello no se ha ejecutado `xcodebuild`, el simulador ni una compilación final para dispositivo. El proyecto debe abrirse en Xcode 16 o posterior, seleccionar un equipo de firma y compilarse allí antes de distribuirlo.

## Límites conscientes del MVP

- Importación bancaria funcional en CSV; lectura directa de `.xlsx` queda en la fase 2.
- Sin conexión PSD2/Open Banking real; solo contratos de proveedor preparados.
- Informes consolidados en EUR; el modelo conserva el código de moneda para una futura conversión multidivisa.
- Sin SQLCipher ni cifrado campo a campo. El almacén se protege mediante Data Protection de iOS; AES-GCM queda disponible para secretos o exportaciones cifradas.
- Sin icono definitivo, localización multidioma ni target de pruebas Xcode dentro del proyecto inicial.
