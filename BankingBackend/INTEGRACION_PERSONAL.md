# Conexión bancaria personal · versión 0.6.0

## Estado del 30 de octubre de 2026

Implementación preparada en la carpeta del proyecto. Primer piloto previsto: una cuenta personal de Bankinter. No se ha autorizado ni consultado ninguna cuenta real.

- Worker personal independiente desplegado en `https://mi-bombo-banking-personal.albertor7722.workers.dev` y D1 independiente con jurisdicción UE. El servidor sandbox anterior conserva su configuración y sus claves.
- Aplicación PRODUCTION registrada por el propietario en Enable Banking. Su firma, entorno, servicio exclusivo AIS y retorno exacto se han verificado mediante la API. Sigue INACTIVE hasta que el propietario vincule una cuenta.
- Claves nuevas subidas como secretos del Worker personal. Configuración y copia local excluidas de Git, con acceso NTFS limitado al propietario y SYSTEM. No se guardan claves ni identificadores del propietario en esta documentación.
- Migración `20261030000100_bank_account_identity.sql` aplicada y verificada en Supabase: dos campos opcionales, dos índices de unicidad y RLS forzada conservada. No se han modificado movimientos ni importado datos bancarios reales.
- Código iOS, pruebas nuevas y registro de fuentes preparados. La compilación nativa y las pruebas de persistencia SwiftData requieren ejecutar los checks de GitHub Actions antes de instalar esta versión. Las comprobaciones locales no sustituyen esa compilación.

## Flujo implementado

1. Dentro del modo cloud: Ajustes → Datos → Conexiones bancarias → Conectar mis bancos reales.
2. Comprobar la conexión con el servidor personal predefinido. Se usa la sesión Supabase; no se pide una clave estática del servidor.
3. Elegir el banco desde el catálogo actual de Enable Banking para España y particulares. El proveedor determina qué modalidades admite; el nombre comercial por sí solo no acredita una cuenta concreta.
4. El propietario autoriza el acceso de consulta en el flujo del banco.
5. Asociar cada cuenta deseada con una cuenta existente de la app, o crear una nueva. Las cuentas existentes conservan su nombre, reservas y relaciones. Primera versión: efectivo en EUR, no posiciones de inversión.
6. Consultar todos los movimientos contabilizados de los últimos 90 días y sus páginas. Revisar la primera descarga y sus coincidencias antes de confirmar.
7. Incorporar la consulta de forma atómica y sincronizar la contabilidad con Supabase mediante el protocolo existente.

Se importan las cuentas asociadas; las demás no se incorporan automáticamente. Si hay una transferencia explícita hacia otra cuenta autorizada que aún no se ha asociado, la consulta se detiene para evitar convertirla en gasto.

## Conciliación y contabilidad

- La identidad bancaria de la cuenta es estable entre permisos renovados. Se calcula en el servidor con HMAC, una clave independiente y la identificación bancaria; no se guarda el IBAN completo en los modelos financieros.
- La vinculación `bankIdentityKey` viaja con la cuenta en la copia de seguridad y en Supabase.
- `bankEntryKey` identifica los apuntes bancarios de un movimiento sin sustituir el identificador CSV original. Una transferencia puede incorporar las referencias de sus dos apuntes sin crear dos movimientos contables.
- Las coincidencias únicas de cuenta, dirección, importe, día y texto normalizado se reconocen automáticamente. Importes iguales cercanos con texto distinto, repeticiones o candidatos múltiples requieren una decisión del propietario.
- Una salida de un banco puede reconocerse como el lado de una transferencia manual existente, incluida una aportación a inversión. Se conserva la transferencia; no se añade además un gasto. Al incorporar la otra cuenta posteriormente, se añaden sus referencias al mismo movimiento si la identificación es coherente.
- La conciliación conserva categoría, notas, fecha, relación con cargos periódicos y financiación con reservas. No deduce por su cuenta que una compra desconocida deba consumir una reserva.
- Un saldo contable ITBD, o CLBD si no hay ITBD, se guarda como valoración autoritativa observada. El historial no se vuelve a sumar sobre ese saldo. La fecha y disponibilidad del dato dependen del banco.
- Las reglas de categorización existentes se aplican a movimientos nuevos. Los que quedan sin categoría aparecen en la revisión habitual.
- Las plantillas periódicas que afectan a cuentas vinculadas dejan de generar apuntes automáticamente: los movimientos reales los suministra el banco. Se mantienen como referencia y para registro manual. Revocar un permiso conserva la vinculación contable y no reactiva automáticamente plantillas atrasadas.

No se fusionan compras por parecido ni se eliminan movimientos automáticamente. Si un banco cambia el importe o la cuenta de un apunte ya reconocido, se detiene esa consulta para revisar la incoherencia.

## Actualización y límites

La app comprueba la conexión al abrir el espacio cloud cuando corresponde. Las consultas automáticas se limitan a una cada seis horas por dispositivo y se reintentan con espera tras errores; el plazo se conserva al reiniciar. El botón Actualizar permite una consulta expresamente solicitada. Los límites del banco pueden ser más restrictivos y aún deben verificarse con Bankinter.

No hay cron de ingesta en el servidor ni actualizaciones con la app cerrada. La sincronización cloud cada 15 segundos no equivale a consultar al banco cada 15 segundos. Se pausa la incorporación al bloquear la app o abrir una ventana de edición durante la consulta automática.

Un permiso vencido requiere renovar la autorización. Desconectar un banco revoca las sesiones de ese banco que conserva el servidor, incluidas las renovadas anteriores; mantiene los movimientos guardados. No se crea ninguna ruta para ordenar pagos.

Las referencias estables y la conciliación reducen duplicados; las diferencias de fecha o importe fuera del criterio de coincidencia necesitan revisión. Borrar un movimiento bancario no equivale a excluirlo permanentemente de futuras descargas. El piloto se validará en un solo dispositivo; quedan pendientes los escenarios de importación bancaria concurrente desde dos dispositivos.

## Controles de acceso

- Servidor personal separado, comprobación del JWT mediante Supabase Auth y propietario único configurado. El token hexadecimal del sandbox no sirve para este servidor.
- La app solo envía su sesión cloud al hostname personal exacto. No sigue redirecciones HTTP que puedan llevar credenciales a otro destino.
- Producción exige una aplicación activa, de entorno PRODUCTION, con servicio exclusivo AIS y retorno exacto; el sandbox sigue exigiendo SANDBOX.
- Sesiones y autorizaciones cifradas con AES-GCM y vinculadas al entorno, la fila y el propietario. HMAC de cuentas con clave separada del cifrado.
- Estados de autorización de un solo uso, caducidad y límites de solicitud. Sin proxy de URLs arbitrarias, rutas de pago ni cuerpos de proveedor en logs.
- La app usa sesión de red efímera, llavero para la sesión cloud y protección de archivos existente. Los datos contables siguen bajo las políticas RLS del propietario en Supabase.
- Páginas públicas informativas: `/privacy` y `/terms`. No incluyen credenciales ni datos financieros.

Son controles implementados y comprobaciones concretas; no constituyen una garantía de ausencia de fallos ni una auditoría externa.

## Comprobaciones realizadas

- 20 pruebas Node del servidor, configuración, cifrado, identidad y proveedor.
- 19 pruebas de integración con workerd/D1, incluido un flujo de producción sintético, renovación, rechazo de otro propietario, revocación y mantenimiento del sandbox.
- 23 pruebas PostgreSQL reales locales: aislamiento, reservas, revisiones, copia completa y nuevas claves bancarias.
- Plan de conciliación compilado y ejecutado con Swift: ambigüedades, renovaciones, transferencias propias y aportaciones vistas solo desde un banco.
- Política del cliente compilada y ejecutada: destino cloud exacto, autorización y retorno.
- Bundle del Worker comprobado con despliegue en seco; servidor personal desplegado. Comprobaciones HTTPS reales: salud correcta, ausencia de credenciales y credenciales ficticias rechazadas, orígenes de navegador rechazados.
- Firma de la aplicación Enable Banking real comprobada sin consultar ninguna cuenta. Estado: PRODUCTION / AIS / INACTIVE.

Pendientes antes del piloto: compilación iOS y pruebas nativas SwiftData de esta revisión en Actions, instalar el nuevo IPA, vincular únicamente la cuenta personal de Bankinter y completar la autorización en la app. La prueba física verificará saldos, primera importación, reservas, transferencias e idempotencia de una segunda actualización.

## Preparación reproducible

La aplicación de Enable Banking necesita el retorno exacto:

`https://mi-bombo-banking-personal.albertor7722.workers.dev/v1/callback`

La base personal se prepara por separado del sandbox. `tools/setup-personal.mjs` acepta `--app-id`, `--owner-id`, `--database-id` y `--pem` (ruta al archivo). Genera `.personal/wrangler.jsonc` y `.personal/secrets.json` con claves de cifrado e identidad independientes. Rechaza identificadores de ejemplo y no sobrescribe claves existentes. No imprime la clave privada, no despliega y no sube secretos por sí solo.

Desde BankingBackend, después de revisar la configuración:

```powershell
npx wrangler d1 migrations apply DB --remote --config .personal/wrangler.jsonc
npx wrangler secret bulk .personal/secrets.json --config .personal/wrangler.jsonc
npx wrangler deploy --config .personal/wrangler.jsonc
```

Estos pasos ya se han realizado en este despliegue personal. No hay que repetir setup ni regenerar las claves para instalar otro IPA. La migración Supabase también está aplicada y no debe modificarse: cualquier evolución debe usar un nuevo archivo de migración.

## Fuentes del proveedor

- [Cuentas propias y producción restringida](https://enablebanking.com/docs/api/linked-accounts/).
- [Referencia API de Enable Banking](https://enablebanking.com/docs/api/reference/).
- [Catálogo de bancos para España](https://enablebanking.com/open-banking-apis?country=ES).
- [Validación de usuarios con Supabase Auth](https://supabase.com/docs/reference/javascript/auth-getuser).
