# Prueba privada de conexión bancaria · cliente 0.3.1

## Qué está preparado

La corrección 0.3.1 afecta únicamente al cliente iOS: coordinación de autenticación y retorno del navegador. Si el servidor demo ya está desplegado, no es necesario repetir despliegue, migraciones ni generación/subida de claves. El número de build del IPA puede variar porque GitHub Actions utiliza su número de ejecución; comprueba la versión **0.3.1**.

Backend para **Cloudflare Workers Free + D1 Free** y pantalla **Ajustes → Datos → Conexión bancaria · Prueba** en iOS/iPadOS. Dos modos: `demo` (no llama a ningún proveedor) y `sandbox` (API oficial de Enable Banking con datos de prueba).

**El acceso a cuentas reales está bloqueado en el código.** Cambiar una variable a `production` no lo habilita. El servidor comprueba que las claves de Enable Banking pertenecen realmente a una aplicación SANDBOX, activa, con servicio AIS y la URL de retorno exacta.

Se pueden autorizar conexiones, consultar cuentas, saldos y movimientos contabilizados de los últimos 30 días, paginar y revocar. Esta primera fase **no importa los datos a la contabilidad**, no modifica saldos existentes y no crea ni ejecuta pagos. No conecta la cartera de valores de Trade Republic.

La importación automática de dinero real requiere una fase posterior: vinculación explícita con cuentas locales, reconciliación con movimientos manuales/periódicos, emparejamiento de transferencias propias y tratamiento de pendientes/valoraciones. No debe activarse sin esas comprobaciones.

## Preparación local

Necesitas Node.js 24 y una cuenta personal de Cloudflare con autenticación multifactor. Mantén Workers en **Free**; no actives productos o suscripciones de pago.

En una terminal situada en `BankingBackend`:

```powershell
npm ci --ignore-scripts --no-fund
npm test
npm run test:integration
npm run check
npm run setup
```

El último comando genera **en tu ordenador**, sin imprimir las claves:

- `.dev.vars`: huella SHA-256 del acceso del dispositivo y clave de cifrado AES de las sesiones.
- `.client-setup.json`: clave de acceso que introducirás en la app.

Ambos archivos están excluidos de Git. No los adjuntes al chat, a una incidencia ni a un pull request. En Windows el modo de archivo POSIX no configura los permisos NTFS: verifica en **Propiedades → Seguridad** que los archivos sean accesibles únicamente por tu usuario y los administradores del equipo. Conserva una copia protegida de la clave de cifrado si necesitas recuperar las sesiones.

`npm run dev` sirve para diagnóstico en el ordenador; la app exige HTTPS y la dirección del despliegue propio en `workers.dev`. No se añaden excepciones HTTP a iOS.

## Desplegar la demostración en Cloudflare

1. Inicia sesión en tu cuenta desde tu equipo:

   ```powershell
   npx wrangler login
   npx wrangler d1 create mi-bombo-banking
   ```

2. En `wrangler.jsonc`, sustituye `database_id` por el UUID que devuelve el comando. Configura `PUBLIC_ORIGIN` con la dirección exacta de tu Worker: `https://mi-bombo-banking.TU-SUBDOMINIO.workers.dev`. Tu subdominio se consulta en Workers & Pages. Conserva `PROVIDER_MODE: "demo"`. La configuración inicial tiene marcadores que impiden atender consultas hasta que se sustituyan.

   Si Wrangler añade automáticamente otra entrada en `d1_databases`, conserva una sola entrada para esta base de datos: `binding: "DB"`, `database_name: "mi-bombo-banking"`, el UUID real en `database_id` y `migrations_dir: "migrations"`. No debe quedar la entrada con UUID de ceros. Puedes comprobar el UUID de tu cuenta con `npx wrangler d1 list --json`.

3. Crea las tablas, sube los secretos y despliega:

   ```powershell
   npx wrangler d1 migrations apply DB --remote
   npm run deploy
   node tools/upload-secrets.mjs
   ```

   El primer despliegue crea el Worker sin acceso habilitado; hasta subir sus secretos no admite consultas privadas. `upload-secrets.mjs` pasa los secretos por entrada estándar, sin ponerlos en argumentos de comandos ni mostrarlos. Requiere que `wrangler login` ya esté completado. Estos comandos crean recursos en tu cuenta: comprueba que sigues en Free y que la base de datos es la nueva del prototipo.

4. Abre la app actualizada → **Ajustes → Datos → Conexión bancaria · Prueba**. Introduce la URL de TU despliegue y la clave del campo `token` del archivo local `.client-setup.json`. La app comprobará el servidor y pedirá Face ID/Touch ID/código; el dispositivo debe tener código configurado.

5. Pulsa un banco y **Conectar cuenta ficticia**. Consulta los saldos/movimientos y prueba **Desconectar**. Los nombres de los bancos en demostración son etiquetas de prueba, no conexiones reales. Cerrar/reabrir la app conserva la configuración del dispositivo; los datos de consulta se mantienen solo en memoria.

6. Cuando hayas guardado la clave en la app, elimina la copia local de `.client-setup.json` o consérvala únicamente en tu gestor de contraseñas. Desconecta las sesiones antes de usar «Olvidar acceso»: borrar la clave del dispositivo no revoca por sí solo el acceso del servidor.

## Segunda prueba: sandbox de Enable Banking

Después de validar la demostración:

1. Crea una aplicación **SANDBOX** en [Enable Banking](https://enablebanking.com/sign-in/). Registra exactamente `https://TU-WORKER.TU-SUBDOMINIO.workers.dev/v1/callback` como URL de retorno. La app debe estar activa y tener servicio AIS.
2. Genera o exporta una clave RSA de 4096 bits en formato PKCS#8 (`BEGIN PRIVATE KEY`) y registra su certificado público. Si la exportación está en PKCS#1, conviértela localmente a PKCS#8. La clave privada se configura únicamente como secreto de Cloudflare; no en el repositorio ni en el iPhone.
3. Configura los dos secretos con las herramientas de Cloudflare, sin compartirlos en el chat:

   ```powershell
   npx wrangler secret put ENABLE_APP_ID
   Get-Content -Raw -LiteralPath 'C:\RUTA-PRIVADA\private-pkcs8.pem' | npx wrangler secret put ENABLE_PRIVATE_KEY
   ```

4. Cambia solo `PROVIDER_MODE` a `sandbox`, vuelve a desplegar y actualiza las conexiones en la app. Se consulta el catálogo sandbox para ES y particulares y se muestran Bankinter, BBVA y Trade Republic únicamente cuando estén disponibles en ese entorno. Si el catálogo de pruebas no los ofrece, se mostrará vacío: no se inventa cobertura.
5. Usa exclusivamente las identidades de prueba que facilite el sandbox. Una conexión sandbox no comprueba que funcione tu cuenta real. Las conexiones demo no aparecen en sandbox y sus datos no pueden descifrarse cambiando de modo; se eliminan al caducar.

## Seguridad y límites

- **Un propietario.** La clave personal de 256 bits da acceso a todas las conexiones de este despliegue. No sirve como arquitectura para varios usuarios; no la compartas. Una filtración exige rotarla.
- **En el dispositivo:** clave en Keychain `WhenPasscodeSetThisDeviceOnly`, no sincronizada con iCloud, fuera de los JSON de copia de seguridad. Sesión de red efímera, sin caché/cookies, HTTPS obligatorio y redirecciones de API rechazadas. Autorización mediante navegador del sistema, validando el identificador de flujo.
- **En el servidor:** secretos fuera del código; D1 conserva metadatos de caducidad, huellas y sesiones cifradas con AES-256-GCM, IV aleatorio y vinculación al registro/entorno. No guarda historial de movimientos, IBAN completo ni contraseñas bancarias.
- **Autorización:** estado aleatorio de 256 bits, huella en D1, caducidad de 10 minutos y consumo atómico. Dos callbacks simultáneos solo permiten un canje. Los códigos del proveedor no se devuelven al iPhone; la URL de retorno a la app lleva únicamente un identificador opaco y el resultado.
- **API limitada:** autenticación obligatoria, comprobación de pertenencia de cuentas, destinos fijos, validación de importes/fechas/tamaños, cuotas por minuto, sin CORS para navegadores y sin rutas de pagos ni de escritura contable. Los JWT del proveedor duran 5 minutos y se reutilizan brevemente para reducir CPU.
- **Registros:** el código no imprime datos bancarios, URLs de autorización, cuerpos de respuesta ni claves. Observabilidad del Worker y métricas de uso de Wrangler desactivadas. Cloudflare, los bancos y Enable Banking siguen siendo partes de confianza y pueden conservar sus propios metadatos operativos.
- **Coste:** Workers y D1 se mantienen en Free y devuelven errores al agotar las cuotas. El prototipo no activa servicios de pago ni usa una tarjeta. El límite de 10 ms de CPU de Workers Free debe medirse en Cloudflare con firma RSA/importación de claves y varias cuentas: las pruebas locales no certifican ese límite. Si no cabe, no se cambia automáticamente a pago.
- **Privacidad:** la app oculta su contenido al quedar inactiva, también en el selector de aplicaciones. Las conexiones locales se conservan para no interrumpir el navegador de autorización; se bloquean interacción y accesibilidad cuando el contenido está oculto.

No se promete seguridad absoluta: quedan fuera de la protección un dispositivo/ordenador comprometido, un administrador de la cuenta de alojamiento comprometido, fallos del proveedor y la copia voluntaria de una clave. Antes de cuentas reales hace falta revisar estos controles con una evaluación independiente y completar las pruebas en iOS y Cloudflare.

## Revocar y rotar

- **Conexión:** «Desconectar» revoca primero en el proveedor y luego borra la sesión cifrada. Si falla la revocación, no se borra la referencia para permitir reintentarlo. Una sesión que el proveedor ya no tiene se considera revocada.
- **Dispositivo perdido/clave filtrada:** cambia `ACCESS_TOKEN_SHA256` por la huella de un nuevo token aleatorio de 32 bytes y configura ese nuevo token solo en tus dispositivos autorizados. No cambies `DATA_ENCRYPTION_KEY` al rotar el acceso: las sesiones existentes requieren la misma clave para revocarse.
- **Clave de cifrado perdida:** ya no podrás descifrar las sesiones. Revoca los consentimientos desde Enable Banking/banco y elimina los registros antes de configurar otra clave y conectar de nuevo. No restaures una D1 antigua sin la clave correspondiente.
- **Clave del proveedor filtrada:** revoca la aplicación/certificado en Enable Banking, revoca los consentimientos y sustituye la clave. La autenticación multifactor de Cloudflare y Enable Banking protege las cuentas administrativas; la clave de la app no sustituye esas protecciones.
- Desinstalar la app o «Empezar desde cero» borra contabilidad local pero no revoca consentimientos externos. Gestiona las conexiones desde su pantalla antes de hacerlo; el llavero puede conservar elementos tras desinstalar.

## Verificación

`npm test`: criptografía, autenticación, configuración cerrada, validación de entrada, importes y JWT RSA. `npm run test:integration`: motor real workerd con D1 local, consentimientos simulados, callbacks simultáneos/repetidos/caducados, autorización por cuenta, revocación, paginación y rechazo de credenciales de producción. Las llamadas del proveedor se simulan: ninguna prueba consulta una cuenta real.

`npm run check` empaqueta el Worker sin desplegar. GitHub Actions ejecuta estos controles sin secretos y la compilación iOS por separado. Este equipo Windows no puede compilar ni ejecutar la UI iOS; hay que comprobarla en Actions y en dispositivo antes de integrar.

### Fuentes técnicas

- [Enable Banking: API, JWT, autorización y sesiones](https://enablebanking.com/docs/api/reference/).
- [Uso personal restringido y condiciones](https://enablebanking.com/terms/).
- [Cloudflare Workers Free](https://developers.cloudflare.com/workers/platform/pricing/), [D1 Free](https://developers.cloudflare.com/d1/platform/pricing/) y [secretos](https://developers.cloudflare.com/workers/configuration/secrets/).
