# Validación de sincronización — 29 de octubre de 2026

## Estado verificado

Se ha consultado el proyecto configurado en la app mediante el panel de Supabase. Existe un usuario confirmado y una carga real del espacio personal. Esta nota no incluye identificadores, conceptos, importes, credenciales ni una exportación de sus registros.

La auditoría de lectura no detectó relaciones activas sin destino, reservas sobreasignadas, pagos reservados vinculados a una cuenta diferente, identificadores bancarios repetidos ni ejecuciones periódicas duplicadas por regla y día. RLS estaba habilitado y forzado en las tablas financieras y las dos funciones públicas de sincronización se ejecutaban sin elevación de permisos. Estos controles son concretos: no constituyen una auditoría de seguridad completa ni una certificación de todos los cálculos financieros.

## Prueba real en iPad

La prueba usa exclusivamente una categoría ficticia sin movimientos asociados.

1. **Creación y subida manual: comprobadas.** El usuario creó una categoría de gasto y pulsó Sincronizar ahora. La nueva categoría apareció en Supabase; el número de movimientos permaneció igual. «Gastos» es el tipo de la categoría, no un movimiento contable.
2. **Edición sin conexión: comprobada.** El usuario desconectó internet y renombró la categoría. Confirmó que el nombre nuevo se veía al volver a Categorías. Durante ese periodo, Supabase conservaba el nombre anterior.
3. **Reenvío automático al reconectar: comprobado.** Tras recuperar internet, dejar Inicio abierto y esperar sin sincronización manual, el nombre modificado apareció en Supabase.
4. **Descarga manual desde nube: comprobada. Descarga automática: no superó la comprobación en la versión instalada.** Se renombró únicamente esa categoría ficticia en Supabase. La operación exigió modificar exactamente una fila y revirtió ante cualquier otro resultado. El usuario no vio el nombre nuevo durante la espera y confirmó que sí apareció al pulsar Sincronizar ahora. No se dispone de un registro del ciclo de vida de SwiftUI que demuestre una causa única del fallo.
5. **Eliminación de la categoría ficticia y propagación: pendiente.** Se conserva activa la categoría «Prueba sync desde nube», sin movimientos asociados, para repetir las pruebas. No se ha eliminado ningún movimiento personal.

No se ha demostrado todavía la recuperación tras forzar el cierre de la app sin conexión ni la resolución de conflictos en dos dispositivos físicos. El usuario solo dispone del iPad ahora y podrá usar otro dispositivo más adelante.

## Corrección preparada para la siguiente compilación

- La carga inicial y la actualización periódica pasan a tareas separadas. Un contenedor `ZStack` estable evita que el trabajo de apertura dependa de sustituir una rama de `Group` por la pantalla principal.
- El ciclo periódico usa `.task(id:)` con el estado actual de carga, primer plano, desbloqueo y sesión. Se reinicia cuando cambia cualquiera de esos valores y no arranca mientras la app está bloqueada o inactiva.
- El [ciclo de vida de las tareas de SwiftUI documentado por Apple](https://developer.apple.com/documentation/swiftui/view/task(id:priority:_:)) permite cancelarlas al desaparecer la vista y reiniciarlas cuando cambia el identificador. La revisión refuerza esos puntos; su eficacia en el escenario del iPad aún debe comprobarse.
- Se consulta la presencia de ventanas abiertas en cada iteración; se ignoran escenas que no están activas y presentaciones ya descartadas o sin ventana visible. Se mantiene la pausa para proteger formularios abiertos. Cuenta y sincronización explica cuándo hay una pausa por presentación.
- Una cancelación esperada del ciclo no debe mostrarse como fallo de conexión. Se comprueba la cancelación antes de enviar una petición.
- Se añade `CloudAutomaticSync.swift` al proyecto Xcode y al workflow de pruebas. Los tests nuevos verifican arranque, repetición, pausa/reanudación, cancelación, nuevo arranque y ausencia de peticiones simultáneas del mismo ciclo; también que una tarea ya cancelada no envía credenciales.

La corrección está en el código local. No está instalada automáticamente en el iPad ni se ha validado allí. Hace falta compilar/subir la nueva versión y repetir la descarga automática.

## Ensayos de servidor y protocolo

- Las 22 pruebas de PostgreSQL en una base local temporal han pasado. Incluyen aislamiento, revisiones, reservas concurrentes y transacciones atómicas.
- Las pruebas Swift del protocolo han pasado en Linux: combinación de versiones, conflictos, reintentos y conservación de ediciones durante una subida. Las ramas dependientes de CryptoKit/SwiftData/macOS no se ejecutaron en Linux.
- `verify_sync_roundtrip.sql` pasó en el proyecto remoto usando dos clientes lógicos representados por instantáneas y revisiones. Rechazó una versión obsoleta, conservó cambios distintos tras releer y propagó una eliminación mediante marca. Los propietarios y registros ficticios del ensayo se revirtieron con ROLLBACK. Esto no equivale a probar dos iPhone/iPad ni emisión de JWT.

## Herramientas guardadas en el repositorio

- `audit_sync_readonly.sql`: consulta de solo lectura para el administrador del proyecto. Devuelve recuentos y resultados de integridad, sin nombres de cuentas, correos, conceptos, tokens o valores monetarios. No sustituye a las políticas RLS.
- `verify_sync_roundtrip.sql`: ensayo transaccional con propietarios ficticios, sin tocar los registros del usuario. Requiere un entorno autorizado y permisos administrativos; no se instala en la app ni como migración.

## Qué probar al volver

1. Subir los cambios en una rama y esperar los checks del último commit antes del merge. Compilar e instalar la nueva versión del iPad.
2. Repetir nube → iPad con la categoría ficticia, dejando Inicio visible, sin formularios ni hojas abiertas, sin pulsar Sincronizar ahora. Confirmar que llega el cambio y avanza Última sincronización.
3. Repetir tras cambiar de pestaña, bloquear/desbloquear, salir/regresar a la app y desconectar/reconectar internet. Comprobar que un formulario abierto muestra la pausa y que se reanuda al cerrarlo.
4. Hacer una edición sin conexión, forzar el cierre, volver a abrir sin internet y comprobar su conservación. Reconectar y comprobar su subida.
5. Eliminar únicamente la categoría ficticia desde la app y comprobar que su eliminación se propaga sin reaparecer tras sincronizar.
6. Cuando haya un segundo dispositivo, probar misma cuenta en ambos, cambios independientes, edición conflictiva del mismo registro y separación respecto a otra cuenta cloud.

La auditoría final mantuvo un único usuario confirmado y no detectó relaciones rotas, problemas de reservas ni los duplicados comprobados. Los usuarios ficticios del ensayo no permanecen en Supabase. No se necesita una migración ni desplegar el servidor bancario para esta corrección.

Desde Windows se comprobaron la sintaxis, las referencias del proyecto, el YAML del workflow y el protocolo Swift ejecutable. También se hizo una comprobación auxiliar de tipos del coordinador con sustitutos locales de las dependencias exclusivas de Apple; esto no verifica SwiftData ni la interfaz real. La compilación completa y la prueba física se mantienen pendientes.
