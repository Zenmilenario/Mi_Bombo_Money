# Privacidad de invitados, cifrado y aprendizaje

Revisión del 11 de noviembre de 2026. Implementación **local**, pendiente de revisión de CI/macOS, despliegue coordinado de Supabase y prueba física en iPhone/Android. No se ha aplicado esta migración al proyecto real.

## Decisión

Las finanzas y el aprendizaje sincronizado de los invitados se cifran en el dispositivo. La identidad de desarrollo puede conservar el almacenamiento relacional actual, mediante una excepción administrada en el servidor. Cambiar la edición, el binario o una preferencia no convierte a un invitado en usuario sin cifrado.

El usuario ha elegido un **código de recuperación guardado por la persona**. No se deriva de la contraseña de acceso ni se guarda en Supabase. La app exige confirmar que se ha guardado antes de activar el cifrado. Perder el código y todos los dispositivos con la clave supone perder la capacidad de recuperar los datos; cambiar la contraseña no soluciona esa pérdida.

## Implementado en este lote

- Swift/CryptoKit y Flutter/cryptography comparten AES-256-GCM: clave aleatoria de 32 bytes, nonce aleatorio de 12 bytes y etiqueta de 16 bytes. El contexto autenticado vincula usuario, espacio, tipo de documento, revisión y clave. Cambiar cualquiera de esos datos invalida el descifrado.
- Código `DBL1-…` con la clave codificada; su formato no es una contraseña elegida por la persona. **Es un secreto**, nunca debe aparecer en logs, notas, incidencias, capturas públicas ni llamadas RPC.
- Clave guardada por identidad en el llavero de iOS, accesible con el dispositivo desbloqueado y sin sincronización del llavero, o almacenamiento seguro de Android. El segundo dispositivo pide el código y verifica un pequeño documento cifrado antes de abrir las finanzas.
- La entrada cloud espera a que se compruebe la política y se disponga de la clave. Un fallo de red no activa un transporte sin cifrado. Un dispositivo ya preparado puede abrir su copia local sin conexión.
- Finanzas y aprendizaje se cifran por separado. Tras descifrarlos, se utilizan los modelos y la combinación de cambios existentes. No se ejecuta el modelo sobre el texto cifrado ni se cambia a un motor de reglas.
- La migración inicial copia ambos documentos, verifica localmente su descifrado y guarda la clave en el dispositivo antes de la llamada de activación. La llamada comprueba las revisiones, guarda ambos sobres y elimina las filas financieras y de aprendizaje antiguas **en la misma transacción**. Ante conflicto no elimina nada. Si se pierde la respuesta, se puede comprobar de nuevo el estado y usar el código ya guardado.
- El servidor conserva documentos opacos, revisiones y metadatos de cuenta. Las versiones antiguas y las llamadas REST directas no pueden escribir finanzas ni aprendizaje sin cifrar de un invitado. La excepción del desarrollador solo la puede establecer un administrador.
- Se conserva el control de revisión para impedir que un dispositivo sobrescriba silenciosamente lo guardado por otro. Los clientes verifican el documento y las asignaciones de reservas porque el servidor ya no puede comprobar el contenido cifrado con SQL.

## Alcance y límites reales

Esto protege la **copia activa en Supabase** frente a lectura directa de sus importes, conceptos y ejemplos de aprendizaje, incluso con acceso administrativo a las tablas. Supabase sigue viendo identidad, tamaños de documentos, revisiones y horas de actualización. No se promete protección frente a un dispositivo comprometido, una actualización maliciosa de la app o una persona que conoce el código.

**La conexión bancaria no es de extremo a extremo frente a nuestro servidor.** El Worker y Enable Banking procesan información bancaria descifrada para entregarla al dispositivo; quien administra ese servidor conserva capacidad técnica sobre ese tramo. El nuevo cifrado no modifica ese hecho ni permite anunciar «ni el operador puede acceder nunca a tus datos bancarios». Para esa promesa haría falta rediseñar también la obtención bancaria y su modelo de confianza.

Las copias de seguridad antiguas de la base, WAL y sus plazos de retención no se purgan por ejecutar la migración. Hay que revisar esa retención al activar el piloto. Las exportaciones que solicite expresamente una persona y los archivos locales privados siguen su política existente; no están convertidos en copias cifradas por este nuevo protocolo cloud. No deben confundirse RLS, cifrado de almacenamiento del proveedor, protección del sistema operativo y este cifrado de aplicación.

## IA común y personal

Los clasificadores actuales son **aprendizaje automático supervisado**, aunque el ajuste sea individual: sus pesos se entrenan con ejemplos y correcciones. Ser colectivo no es un requisito para ser IA. Todas las instalaciones pueden partir de una base común y después adaptarse a cada persona.

En este lote **no se han enviado correcciones de invitados a un modelo colectivo** ni se ha creado un conjunto de datos con sus movimientos. El aprendizaje privado continúa sincronizándose cifrado entre sus dispositivos y las correcciones pueden mejorar sus futuras predicciones bajo los umbrales existentes.

Para un modelo común que mejore con los invitados, queda pendiente una participación voluntaria separada del uso de la app. Una futura arquitectura federada entrenaría localmente y compartiría actualizaciones protegidas por agregación segura y privacidad diferencial. Las actualizaciones del modelo también pueden filtrar información; compartir pesos sin protección no equivale a anonimizar. Un piloto pequeño no permite prometer anonimato de grupo. Por ahora la base común puede evolucionar con datos sintéticos y datos propios autorizados del desarrollador, manteniendo privados los de los invitados.

Para el TFM: conservar el esquema relacional con datos propios o sintéticos permite estudiar SQL y análisis; el piloto sirve para evaluar almacenamiento cifrado, aislamiento, revisiones y recuperación. Las consultas SQL del servidor ya no pueden analizar directamente los gastos cifrados de los invitados.

## Operaciones bancarias y edición

«Solo consulta bancaria» describe el permiso de Enable Banking. La persona **sí puede** añadir, editar, eliminar, categorizar o conciliar registros en Doblón, y registrar transferencias entre sus cuentas. Esos cambios afectan a la contabilidad de Doblón. No ordenan transferencias reales, no pagan recibos y no modifican el extracto ni el saldo del banco. El original bancario y la edición contable no deben confundirse.

## Activación pendiente — procedimiento coordinado

1. Revisar los cambios y pasar las comprobaciones completas de iOS y Flutter. La app nueva necesita `finance_privacy_profile`; no instalarla contra un servidor sin esta migración.
2. Preparar una copia recuperable y comprobar la política de retención. No usar datos reales de invitados para estas pruebas.
3. Aplicar `supabase/migrations/20261111000300_client_encryption.sql` y registrar la identidad del desarrollador en `finance_private.developer_plaintext_users` dentro de una operación administrativa coordinada. El UUID se introduce por un canal privado; no está incrustado en el código ni en esta nota. Ejemplo de sentencia: `INSERT INTO finance_private.developer_plaintext_users(owner_id) VALUES ('UUID_DEL_DESARROLLADOR');`. Ningún invitado debe añadirse a esa tabla.
4. Distribuir ambos clientes actualizados. Las versiones antiguas de invitados quedarán bloqueadas para sincronizar, conservando su copia local. La cuenta de desarrollo exenta mantiene su protocolo anterior.
5. Probar con una cuenta ficticia: generar y guardar código, migrar, corregir una categoría, sincronizar, recuperar en otro dispositivo, comprobar aprendizaje, editar sin conexión y reconectar. Probar también código incorrecto y conflicto entre dispositivos.
6. Solo tras comprobarlo, incorporar invitados con el aviso de privacidad que explique también el tramo bancario. Requiere aprobación del usuario antes de aplicar la migración o tocar el servicio real.

## Resultado local del 11/11

- 35 pruebas correctas en PostgreSQL 17 local efímero, con datos ficticios y roles reales.
- 81 pruebas Flutter correctas; análisis estático sin incidencias.
- APK Release Android 0.13.0 (9) compilado correctamente. No instalar todavía contra la base sin migrar.
- iOS 0.7.16 (57): código y comprobaciones de CI preparados; compilación macOS y prueba física pendientes.
- No se ha hecho push, desplegado el Worker ni aplicado la migración real.

## Comprobaciones

- PostgreSQL real local y efímero: pruebas de política por defecto, RLS, excepción del desarrollador, rechazo de API antigua, migración atómica, conflictos, aislamiento de clave/espacio y sobres malformados, junto con las pruebas relacionales existentes.
- Flutter: vector AES-GCM independiente de Node/OpenSSL, código de recuperación, nonce aleatorio, alteración, contexto incorrecto, céntimos exactos, recuperación en otro dispositivo simulado, transporte sin texto financiero y misma predicción del modelo tras descifrar el aprendizaje.
- CI macOS: `Tests/CloudCipherCheck.swift`, protocolo cloud y compilación de la app iOS. **Pendiente de ejecutar con este lote**; no confundir con las pruebas locales de Flutter/PostgreSQL.
- Auditoría externa criptográfica y prueba física: pendientes. No se afirma que este cambio constituya una certificación de seguridad.

Referencias técnicas: [CryptoKit AES.GCM](https://developer.apple.com/documentation/cryptokit/aes/gcm), [cryptography para Dart](https://pub.dev/packages/cryptography), [Flutter Secure Storage](https://pub.dev/packages/flutter_secure_storage), [aprendizaje federado con privacidad diferencial](https://www.tensorflow.org/federated/tutorials/federated_learning_with_differential_privacy).
