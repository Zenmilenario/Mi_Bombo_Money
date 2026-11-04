# Validación de sincronización — estado al 30 de octubre de 2026

## Resultado actual

La corrección del commit `7c0d181` («Update Sync V 0.5») ha superado las pruebas realizadas con el usuario en un iPad. El usuario confirmó que instaló esa compilación. Sus diez checks más recientes de GitHub han terminado correctamente, incluidas las compilaciones Debug para simulador y Release para dispositivo y los tests de sesiones, PKCE y adaptación SwiftData.

Fuentes: [compilación iOS](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41019868725) y [pruebas cloud](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41019868750).

## Pruebas físicas superadas

Se utilizó exclusivamente una categoría ficticia sin movimientos asociados:

1. **Nube → iPad automática.** Se renombró desde Supabase a «Prueba sync 30-10 A». El usuario confirmó que apareció después de esperar en Inicio, sin pulsar Sincronizar ahora.
2. **Conservación sin internet tras cierre completo.** El usuario renombró a «Prueba sync 30-10 B», guardó sin conexión, cerró la app desde la multitarea y la volvió a abrir todavía sin internet. El nombre nuevo seguía presente.
3. **Subida automática al reconectar.** Al recuperar internet y esperar en Inicio sin sincronizar manualmente, Supabase recibió ese nombre nuevo.
4. **Reanudación tras bloqueo.** Con el iPad bloqueado se cambió el nombre en Supabase a «Prueba sync 30-10 C». Después de desbloquear y esperar, apareció automáticamente en el dispositivo.
5. **Eliminación y propagación.** El usuario eliminó la categoría ficticia desde la app. Supabase mantuvo su marca de eliminación y no quedó ningún registro de prueba activo. La comprobación posterior tampoco mostró reaparición. Se comprobaron los recuentos de cuentas y movimientos antes y después, sin variación durante ese ensayo.

La categoría de prueba ya está retirada de las categorías activas. No se ha modificado ningún movimiento personal desde las herramientas ni se han copiado conceptos, importes, identificadores privados o exportaciones del usuario a esta documentación.

## Incidencia anterior y corrección

El 29 de octubre, la descarga manual funcionaba, pero el usuario no recibió automáticamente un cambio durante la espera. Se reforzó el ciclo de sincronización:

- Host `ZStack` estable, separando la carga inicial de la actualización periódica.
- `.task(id:)` con estado de carga, primer plano, desbloqueo y sesión: reinicio al cambiar esos valores.
- Consulta de la presentación de ventanas en cada iteración, ignorando escenas inactivas y presentaciones descartadas o no visibles. Se conserva la pausa para proteger formularios abiertos.
- Explicación del estado de pausa en Cuenta y sincronización.
- Cancelaciones esperadas que no se presentan como fallos de conexión; comprobación de cancelación antes de transmitir una petición.

El [ciclo de vida de tareas documentado por Apple](https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)) permite cancelarlas al desaparecer una vista y reiniciarlas al cambiar el identificador. La revisión reforzó esos puntos. No se dispone de trazas de la versión anterior que demuestren una única causa interna; sí se ha observado que la nueva compilación supera los escenarios físicos enumerados arriba.

## Auditoría y ensayos independientes

- La auditoría de lectura de Supabase no detectó relaciones activas sin destino, reservas sobreasignadas, pagos reservados vinculados a otra cuenta, identificadores bancarios repetidos ni ejecuciones periódicas duplicadas por regla y día. RLS estaba habilitado y forzado en las tablas financieras; las funciones de sincronización se ejecutaban sin elevación de permisos.
- Las 22 pruebas PostgreSQL locales pasaron. Comprueban aislamiento, revisiones, reservas concurrentes y escritura atómica.
- Los tests Swift comprueban combinación de versiones, conflictos, reintentos, conservación de ediciones durante subida y ciclo automático: arranque, repetición, pausa/reanudación, cancelación, nuevo arranque y ausencia de solapamiento del propio ciclo.
- `verify_sync_roundtrip.sql` pasó en el proyecto remoto con dos clientes lógicos representados por instantáneas y revisiones. Rechazó una versión antigua, conservó cambios distintos tras releer y propagó una eliminación. Los propietarios y registros ficticios de ese ensayo se revirtieron con ROLLBACK y no permanecieron en Supabase.

Estas comprobaciones son específicas: no constituyen una certificación de seguridad ni demuestran todos los escenarios de cálculo financiero. Dos clientes simulados no equivalen a dos dispositivos físicos.

## Herramientas reproducibles

- `audit_sync_readonly.sql`: consulta administrativa de solo lectura con recuentos y controles de integridad, sin nombres de cuentas, correos, conceptos, tokens o valores monetarios.
- `verify_sync_roundtrip.sql`: ensayo transaccional sobre propietarios ficticios. No es una migración ni se ejecuta desde la app.
- `Tests/CloudProtocolCheck.swift`: protocolo y ciclo automático; las ramas Apple se comprueban en macOS mediante GitHub Actions.

## Copia y recuperación en 0.6.10 · 4 de noviembre de 2026

El check nativo de `bdede80` pasó con datos ficticios en contenedores SwiftData en memoria. Comprueba restauración repetida, reservas que pasan entre cuentas, reglas, valoraciones, copias cifradas y rechazo de copias inválidas o contraseñas incorrectas. [Exportación y restauración](https://github.com/Zenmilenario/Mi_Bombo_Money/actions/runs/41793245325/job/126451262541).

El usuario confirma que la comprobación de apertura de la copia cifrada en el iPad funcionó sin errores y que sus movimientos permanecieron igual. Procedimiento de la prueba desde Archivos. En **Ajustes → Exportar o restaurar copia**, activar **Proteger copia con contraseña**, exportar a Archivos y volver a abrir el fichero con **Elegir copia JSON o cifrada**. Introducir la contraseña y comparar los recuentos de cuentas y movimientos de la vista previa. Terminar la prueba saliendo de la pantalla tras comprobar los recuentos. El botón **Reemplazar datos con esta copia** inicia una restauración y queda fuera de esta comprobación.

La restauración completa en un dispositivo físico requiere un entorno de prueba separado. También queda pendiente el ensayo de sincronización con un segundo dispositivo. El laboratorio bancario actual oculta la ruta de copias.

## Pendiente

- Mismo usuario en dos dispositivos físicos, cambios independientes y resolución de un conflicto sobre el mismo registro.
- Comprobar físicamente la pausa mientras hay un formulario abierto y su reanudación, así como combinaciones adicionales de navegación y ventanas.
- La bandeja «Por revisar» es posterior a esta validación de sincronización. El usuario probó la 0.6.10. La propagación de cambios de clasificación entre dos dispositivos queda por comprobar. Véase ver [REVISION_MOVIMIENTOS.md](../REVISION_MOVIMIENTOS.md).
