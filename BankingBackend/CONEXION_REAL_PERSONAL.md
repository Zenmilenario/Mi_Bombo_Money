# Conectar tus propias cuentas: qué falta

Cloudflare ya aloja el servidor. Eso no le concede acceso a BBVA, Bankinter ni Trade Republic. Los datos de «cuenta ficticia» se generan en el servidor y nunca proceden de esos bancos.

## Estado de la app 0.4.0

- El flujo de prueba deja ver cuentas, movimientos y saldos en Inicio, Cuentas y Movimientos, con un archivo local separado del real. La actualización vuelve a consultar el servidor al abrir ese espacio y al regresar a primer plano, con un intervalo mínimo de un minuto; también hay un botón Actualizar. No hay sincronización en segundo plano cuando la app está cerrada.
- Se importan ingresos/gastos contabilizados con identificador estable, reglas de categoría, deduplicación por cuenta y saldo contable. Se comprueba que hayan llegado todas las páginas antes de guardar. Esta versión de prueba admite euros y saldo `CLBD`; si faltan esos datos o IDs estables se informa sin guardar una importación parcial.
- No se han activado cuentas reales. Antes hacen falta vinculación explícita con cuentas locales, continuidad tras renovar un consentimiento, conciliación con movimientos manuales y periódicos y reconocimiento fiable de transferencias propias. La prueba no certifica esas funciones. Tampoco incluye posiciones de inversión de Trade Republic.

## Tu siguiente paso: Enable Banking

1. Crea una cuenta en el [panel oficial de Enable Banking](https://enablebanking.com/sign-in/). No se necesita comunicar contraseñas bancarias al desarrollador ni a esta conversación.
2. Para datos reales de uso personal, su documentación describe una aplicación **PRODUCTION** activada en modo restringido mediante **Activate by linking accounts**. Solo da acceso a las cuentas concretas que vincules; deben incluirse todas las cuentas deseadas, no solo una por banco. [Guía oficial](https://enablebanking.com/docs/api/linked-accounts).
3. La URL de retorno de este despliegue es `https://mi-bombo-banking.albertor7722.workers.dev/v1/callback`. Los campos que pide el registro y la diferencia entre activación restringida y pública están en la [guía del panel](https://enablebanking.com/docs/api/control-panel/). Si solicita textos o direcciones de privacidad y condiciones que aún no tengas, hay que prepararlos con información real de esta app; no copies los de otra aplicación.
4. Guarda el identificador de la aplicación y el archivo de clave privada que genere el proveedor en una ubicación privada local, fuera del repositorio. No pegues esa clave ni contraseñas bancarias en el chat. La clave privada pertenecerá a los secretos del servidor, nunca al IPA. Las claves actuales de Cloudflare y del dispositivo se conservan.

Crear la aplicación en Enable Banking **no activa por sí solo esta app**: el backend actual rechaza credenciales de producción y la app bloquea entornos reales. Hay que completar la integración contable y sus pruebas antes de levantar esos bloqueos. No cambies `PROVIDER_MODE` a `production` ni regeneres las claves actuales para intentar saltarte ese paso.

## Coste y alcance

El uso restringido para cuentas propias y el despliegue público son situaciones distintas. Enable Banking publica condiciones comerciales basadas en volumen, pero las páginas consultadas no garantizan aquí un precio personalizado ni permanencia gratuita; comprueba las condiciones aplicables al activar tu aplicación. [FAQ oficial](https://enablebanking.com/docs/faq/).

La cobertura de cada cuenta y el historial disponible se comprueban con el proveedor. Una cuenta de efectivo de Trade Republic no representa automáticamente el valor de sus acciones, ETF u otros activos. Para abrir la app a otras personas habría que revisar también las condiciones de acceso del proveedor y sustituir el acceso actual de propietario único.
