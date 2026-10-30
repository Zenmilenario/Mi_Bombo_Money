# Base cloud de Mi Bombo Money

## Estado real de esta entrega

Proyecto **mi-bombo-money-dev**, plan Free, región específica Frankfurt (`eu-central-1`).
URL pública: https://coeicjffmpclqowsqeys.supabase.co. La configuración de la app contiene únicamente la URL y la clave publicable; no incluye claves administrativas ni contraseñas.

La migración `supabase/migrations/20261029000100_finance.sql` está aplicada en este proyecto mediante el editor SQL, envuelta en una transacción. Se comprobó su SHA-256 antes de ejecutarla; queda registrado en `project.json`.

La base tiene **14 tablas**: un espacio de trabajo y los 13 modelos de SwiftData. Se verificaron RLS y ausencia de permisos anónimos/borrado físico en todas. La prueba remota `verify_remote.sql` pasó usando la función `auth.uid()` y los roles reales de Supabase. Sus dos usuarios y cuentas ficticias se revirtieron al finalizar.

La migración `20261029000200_snapshot_protocol.sql` también está aplicada y probada en remoto. Añade lectura y escritura atómicas del conjunto de datos, bloqueo por espacio y control de revisiones. La prueba remota rechazó una versión obsoleta y la lectura del espacio de otro usuario; todos los datos ficticios se revirtieron.

**Implementado en el código:** acceso con correo y contraseña, confirmación y recuperación mediante PKCE, sesiones en Keychain, copia local por usuario y sincronización con revisión explícita de conflictos. Se activa desde **Ajustes → Datos → Conectar sincronización cloud**. El modo local continúa disponible. Ya se ha observado la carga del usuario desde la app; la documentación de validación no copia sus conceptos ni importes. No se ha modificado el servidor bancario.

**Validado el 30 de octubre de 2026 con un iPad:** acceso, descarga automática desde Supabase, edición sin conexión conservada tras cierre completo, subida automática al reconectar, reanudación tras bloquear/desbloquear y propagación de una eliminación. El commit de sincronización `7c0d181` pasó sus diez checks más recientes, incluidas ambas compilaciones de iOS. Sigue pendiente la prueba entre dos dispositivos físicos y la interacción con formularios abiertos. El detalle y los límites están en [VALIDACION_SINCRONIZACION_2026_10_29.md](VALIDACION_SINCRONIZACION_2026_10_29.md). La URL exacta de retorno `mibombomoney-cloud://auth` está configurada sin comodines; se mantiene la confirmación de correo.

## Modelo y seguridad

- `finance_workspaces`: propietario y origen `personal`, `sandbox` o `demo`. El tipo/origen no se puede cambiar, para evitar convertir datos ficticios en personales.
- `finance_institutions`, `finance_accounts`, `finance_cards`: entidades, cuentas y tarjetas. Solo se admiten los últimos cuatro dígitos de tarjeta; no hay campos para PIN, CVV ni claves bancarias.
- `finance_categories`, `finance_category_rules`: categorías y reglas.
- `finance_reserved_funds`, `finance_transactions`: financiación reservada y movimientos.
- `finance_monthly_budgets`, `finance_recurring_budgets`: presupuestos y tratamiento del sobrante.
- `finance_savings_goals`, `finance_recurring_movements`: objetivos y cargos/aportaciones periódicos.
- `finance_balance_snapshots`, `finance_import_batches`: saldos de referencia y trazabilidad de importaciones.

Cada registro pertenece a `owner_id = auth.uid()`. Los identificadores de regla periódica e importación guardados en un movimiento son trazabilidad histórica: se conservan aunque se elimine la regla o el registro de importación y no permiten consultar datos de otro propietario. Las claves foráneas incluyen propietario y espacio: no basta con adivinar el UUID de la cuenta de otra persona ni se puede vincular un pago sandbox con una cuenta personal. Los UUID originales pueden conservarse dentro de ese ámbito.

Se revocan los privilegios por defecto y se conceden únicamente SELECT, INSERT y UPDATE a `authenticated`. RLS está habilitado y forzado. `anon` no tiene acceso. `service_role` es administrativo y no debe estar en la app ni en Git. Las funciones auxiliares están en un esquema privado. Solo el contrato estático de campos se puede consultar desde las funciones de sincronización; los auxiliares de escritura no son API pública. Las dos funciones RPC públicas usan los permisos y RLS del usuario que llama, sin elevarlo a administrador.

Las eliminaciones se representan con `deleted_at`. Un dispositivo debe conservar esas marcas para transmitir eliminaciones y mantener la historia de los pagos reservados. La retención/purga futura necesitará reconocimiento por dispositivo: esta entrega no implementa una purga ni un registro de dispositivos.

`revision` y `updated_at` los genera el servidor. `finance_save_snapshot` exige la revisión exacta del espacio que el cliente leyó, bloquea el espacio y aplica todos los registros en una transacción. Una revisión obsoleta se rechaza con SQLSTATE `40001`; ningún dato se escribe parcialmente. No se usa el reloj del dispositivo como cursor.

## Dinero reservado

Los importes usan `bigint` en céntimos. `amount_minor` de una reserva es la financiación total, incluidos los pagos ya realizados; no es el saldo que queda.

El vínculo del movimiento guarda qué parte fue cubierta por la reserva. Solo esa parte se excluye del presupuesto mensual. El gasto real, el saldo de la cuenta y el patrimonio reflejan el importe completo.

Una clave foránea exige que la reserva pertenezca a la cuenta de origen. Las asignaciones se comprueban con bloqueos de fila en orden estable: dos dispositivos no pueden comprometer simultáneamente más dinero que el financiado. Los pagos futuros también comprometen reserva. Editar, marcar como eliminado o restaurar un pago libera o vuelve a comprometer su asignación.

## Pruebas reproducibles

En un PostgreSQL **local y desechable**, instala Python 3.12+ y las dependencias:

```sh
python -m pip install -r CloudBackend/requirements-test.txt
python supabase/tests/test_finance.py
```

`CLOUD_TEST_ADMIN_DSN` indica la conexión administrativa local. El valor por defecto es `dbname=postgres user=postgres`, apropiado al ejecutar como usuario postgres en Linux. El script rechaza hosts remotos, crea una base temporal de nombre aleatorio y elimina exclusivamente esa base al terminar.

Las 22 pruebas incluyen los permisos de todas las tablas, suplantación de propietario, relaciones cruzadas, marcas de eliminación, revisiones obsoletas, datos inválidos, deduplicación y dos pagos realmente concurrentes sobre la misma reserva, ida y vuelta de los 13 modelos, escritura atómica, historial sin regla activa y control de revisiones del protocolo. Se ejecutaron correctamente en PostgreSQL 18 local. GitHub Actions las ejecuta sobre PostgreSQL 17, sin claves cloud ni datos personales.

`bootstrap_local.sql` simula únicamente `auth.users`, `auth.uid()` y los roles en esa base temporal. **Nunca se aplica al proyecto remoto.** Las pruebas locales no verifican emisión/validación de JWT, correo, recuperación de contraseña ni el SDK de iOS. La prueba remota verifica el contexto de identidad y RLS reales, pero tampoco es un inicio de sesión extremo a extremo.

El script `audit_sync_readonly.sql` comprueba la carga y coherencia mediante recuentos. `verify_sync_roundtrip.sql` comprueba dos clientes lógicos y la propagación de cambios sobre propietarios ficticios, dentro de una transacción revertida. Son herramientas administrativas de verificación, no migraciones ni llamadas desde la app. La prueba con dos dispositivos físicos sigue siendo independiente.

## Migraciones y despliegue

En un proyecto NUEVO, `supabase db push` aplica la migración después de vincular el proyecto con el CLI. No ejecutes `supabase db reset --linked` contra esta base.

La instalación inicial actual se hizo por el editor SQL, por lo que el historial del CLI aún debe conciliarse **una vez** antes de adoptar `db push`:

```sh
supabase link --project-ref coeicjffmpclqowsqeys
supabase migration repair --status applied 20261029000100 20261029000200
supabase migration list
```

Ese paso marca la migración que ya está aplicada, no vuelve a ejecutarla. La contraseña y el acceso administrativo se introducen localmente, nunca por chat ni como argumentos publicados. Antes de reparar el historial, comprobar esquema y hash de `project.json`. Las migraciones futuras deben ser aditivas, revisadas y probadas. No editar una migración ya desplegada.

El archivo `config.toml` configura el entorno local; no cambia automáticamente el correo ni los proveedores Auth del proyecto remoto. La base está en Free: deben conservarse exportaciones privadas independientes antes de introducir datos personales; la copia local de iOS no es un respaldo cloud automático.

## Comportamiento de la sincronización

- La primera conexión ofrece copiar los datos locales únicamente si el espacio remoto está vacío. Los originales permanecen en el almacén local. No se copian pruebas bancarias ni credenciales.
- Cada cuenta cloud tiene un archivo SwiftData separado por UUID. Se guardan la última base de comparación y una copia previa a la aplicación de cambios, cifradas con la clave local del llavero.
- Se compara cada registro con la última versión conocida: los cambios independientes se combinan; dos cambios incompatibles en el mismo registro requieren elegir una versión. También se comprueban relaciones y financiación de reservas. Las eliminaciones se deducen de esa base y se conservan como marcas en el servidor.
- El ciclo automático se inicia cuando el espacio está preparado, con sesión, primer plano y desbloqueo; se reinicia al cambiar esos estados y consulta cada 15 segundos durante el uso. Se pausa la sincronización automática mientras hay formularios presentados. Se vuelven a capturar los datos después de cada espera de red para conservar ediciones hechas durante la subida.
- Un fallo de red conserva los cambios en el dispositivo. Cerrar sesión conserva la copia pendiente, accesible al volver a entrar con la misma cuenta; no la mezcla con otra identidad. El primer acceso en un dispositivo necesita conexión.
- Los cargos automáticos usan UUID derivados de la regla y su fecha programada: dos dispositivos que registren la misma ejecución no crean dos cargos.
- El protocolo envía una instantánea completa, con límite de 10 MB. Es una primera implementación para uso personal; grandes históricos requerirán sincronización incremental y medir consumos.

## Acceso y protección

La app conecta por HTTPS únicamente al proyecto configurado, rechaza redirecciones de peticiones con credenciales y no registra contraseñas ni tokens. El correo devuelve un código PKCE de un solo uso: el verificador permanece en Keychain y la app pide confirmar la cuenta antes de abrirla. La confirmación y recuperación deben iniciarse y completarse en el mismo dispositivo.

La contraseña cloud es independiente del bloqueo local. Face ID/Touch ID protege la apertura de la app; no sustituye a Supabase Auth. No se debe confundir este acceso con la autorización de los bancos.

No hay cifrado de extremo a extremo en PostgreSQL: Supabase y un administrador autorizado del proyecto pueden acceder al contenido. RLS aísla a los usuarios; no protege frente a credenciales administrativas comprometidas. Los archivos iOS tienen protección del sistema y las copias internas de recuperación usan AES-GCM. No se promete seguridad absoluta.

No se ha contratado correo propio. El correo integrado de desarrollo tiene límites y puede restringir destinatarios; antes de ampliar a otros usuarios hay que configurar SMTP y probar entregas. No bajar las protecciones para eludir esos límites.

## Verificación pendiente en dispositivos

1. Subir los cambios en una rama y esperar todas las comprobaciones, incluidos **Validar app iOS**, **Comprobar datos y cálculos** y **Comprobar almacenamiento cloud**. El nuevo workflow comprueba protocolo, PKCE y adaptación SwiftData en macOS.
2. Instalar la app, crear una cuenta con correo y confirmar en ese dispositivo. Elegir primero empezar sin copiar y crear datos ficticios, incluidas una reserva y un pago cubierto parcialmente por ella.
3. Entrar con la misma cuenta en un segundo dispositivo y comprobar saldos, reserva restante y gasto presupuestario. Modificar registros distintos y luego el mismo registro para comprobar combinación y resolución.
4. Probar sin conexión, reconectar, cerrar y abrir sesión, restaurar una copia y eliminar datos. Comprobar que otro usuario no ve el espacio anterior.
5. Exportar una copia cifrada independiente antes de copiar datos personales a cloud. El proveedor Free puede pausar proyectos; esta entrega no instala un servicio de respaldos remotos ni borra automáticamente copias del dispositivo.

Para el máster, `analytics/monthly_expenses.sql` es una primera consulta de gastos reales frente a gasto presupuestario. No se ha ejecutado con datos reales ni exporta nada automáticamente. El análisis debe filtrar el espacio y usar el contexto de usuario apropiado; las credenciales administrativas no son una solución de permisos para los informes. El conjunto académico inicial debe ser sintético.

Referencias: [RLS](https://supabase.com/docs/guides/database/postgres/row-level-security), [seguridad de API](https://supabase.com/docs/guides/api/securing-your-api), [Swift](https://supabase.com/docs/guides/getting-started/tutorials/with-swift).
