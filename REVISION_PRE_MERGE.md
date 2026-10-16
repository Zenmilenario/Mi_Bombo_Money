# Revisión previa al merge

Fecha: 5 de octubre de 2026. Rama: `codex/dynamic-clean-start-icon`.

## Prueba completa con datos · 0.4.2 (16 de octubre de 2026)

- Diagnóstico remoto: BBVA devolvió siete cuentas y cero movimientos. Tres cuentas ofrecían CLBD; otras OPBD/XPCD causaban el rechazo completo. El importador admite ahora ITBD o CLBD y explica individualmente las cuentas incompatibles; las cargas con movimientos incoherentes siguen rechazándose antes de escribir.
- Cargado el escenario propio en Mock ASPSP a través del panel autenticado: tres cuentas, 75 apuntes de agosto a octubre y saldos coherentes. Autorización completada tras confirmación del usuario de los términos del proveedor. Lectura autenticada por el Worker: 6 apuntes en Máster, 9 en Inversión y 60 en Día a día; todos los movimientos normalizados coinciden exactamente con el archivo de comprobación.
- Espacio local específico del escenario; conserva el anterior sandbox manual y las finanzas reales. Importación de 90 días, emparejamiento recíproco con referencias explícitas (seis transferencias), identidad estable al renovar este escenario y selección de su conexión más reciente. No se generaliza esa renovación a bancos reales.
- Reglas de categorías, cuatro presupuestos repetidos (uno superado), reserva de 1.500 €, tarjeta vinculada y dos plantillas periódicas pausadas, instaladas una vez en este escenario. Las plantillas se pausan para impedir duplicados con los cargos importados del banco.
- Versión 0.4.2, build local 19. Sin cambio del esquema SwiftData, D1 o formato de copia. Worker desplegado: `fee149ef-7d5e-4220-bf91-39a1ae62b55b`. No se regeneraron secretos ni se eliminaron conexiones/datos anteriores. La conexión Mock queda preparada para el usuario.
- Pruebas de servidor: 13 unitarias y 17 de integración superadas; empaquetado seco correcto. El caso nuevo cubre todo el escenario en workerd/D1 con páginas de diez operaciones, cifrado y reautorización. La prueba SwiftData de Actions añade saldos, resumen mensual, reserva, presupuesto, categorías, compras de igual importe, repetición y aislamiento. Su compilación y ejecución requieren macOS; no se han ejecutado en Windows. Pasos/resultados en `Samples/sandbox/LEEME.md`.
- Revisión local final: 43 archivos Swift sin errores sintácticos; las 39 fuentes de app incluidas exactamente una vez; versión Debug/Release, familias iPhone/iPad, plist y esquemas correctos; cinco workflows y 21 scripts comprobados; JSON y codificación UTF-8 válidos; `git diff --check` limpio; auditoría npm sin vulnerabilidades conocidas. No hay claves privadas seguidas por Git. Los ejemplos locales se instalan una vez y se respetan sus modificaciones/eliminaciones al actualizar.

## Activación del sandbox del proveedor · 0.4.1 (16 de octubre de 2026)

- Verificada la clave RSA local (4096 bits), exclusión de Git y ausencia en su historial. Petición autenticada al proveedor: aplicación SANDBOX activa, AIS, ID coherente y callback exacto. Conversión PKCS#8 en memoria y subida de dos secretos a Cloudflare sin imprimir contenido ni alterar las claves de acceso/cifrado anteriores.
- Catálogo real consultado: BBVA, Banco de Sabadell y Mock ASPSP disponibles para particulares ES. Se habilitan solo esos nombres del catálogo; las etiquetas demo Bankinter/Trade Republic no se ofrecen como sandbox sin cobertura. Producción sigue bloqueada.
- Una prueba de inicio detectó que la API utiliza `tilisy-sandbox.enablebanking.com`. Corregidas las listas exactas de destinos en Worker e iOS y añadidas pruebas de dominio parecido, HTTP, usuario y puerto. El JWT no abandona las peticiones del servidor al API oficial.
- Archivos de prueba separados por origen HTTPS canónico y modo, con hash completo en el nombre. El importador rechaza archivos de otro servidor/entorno y el almacén real. Si el entorno cambia con el espacio abierto, se informa y se exige reabrir. Los archivos demo anteriores no se borran.
- Versión 0.4.1, build local 18; se requiere IPA nuevo por la validación de URL de iOS. Pruebas locales: 11 unitarias y 16 de integración superadas y empaquetado seco correcto. Añadidas pruebas Swift de separación de almacenes y del dominio sandbox; compilación/ejecución pendientes de macOS/Actions y del dispositivo.
- Publicado el Worker `5e091c47-746c-4a7f-8803-0df369ea1789` con el modo sandbox y los secretos existentes. Verificación remota autenticada: estado y catálogo 200, inicio de autorización BBVA y Mock ASPSP 201, origen HTTPS oficial validado. Estas comprobaciones no completaron autorización, crearon conexiones ni importaron movimientos. La autorización y consulta completas se deben probar en el dispositivo.
- Revisión local del cliente: 43 archivos Swift sin errores en el analizador sintáctico; 39 fuentes de app registradas una vez; Debug/Release 0.4.1 (18), plist/esquemas válidos, cinco workflows y 21 scripts comprobados. `git diff --check` sin errores; no hay archivos PEM ni claves privadas seguidos por Git. No sustituye la compilación del SDK de Apple.

## Integración del espacio bancario · 0.4.0 (15 de octubre de 2026)

- La conexión deja de terminar únicamente en una consulta: tras autorizar abre un espacio completo con las vistas habituales. Las conexiones anteriores tienen acceso directo sin repetir autorización. También se puede abrir Conexiones bancarias desde Cuentas → +.
- El espacio usa el mismo esquema con un archivo distinto (`MiPatrimonioBankingTests.store`), categorías comunes, indicador permanente, salida directa, protección de archivos y cortina de privacidad/bloqueo durante la inactividad. El importador rechaza la configuración real `LocalFinance` y almacenes persistentes que no sean el archivo de prueba. No cambia el esquema ni el formato de copia de las finanzas reales; se ocultan importación/exportación dentro de la prueba.
- La carga reúne todas las páginas antes de guardar; rechaza bucles, cargas excesivas, fechas/importes/monedas inválidos o falta de IDs/saldo CLBD. Las identidades se separan por servidor, entorno y cuenta. La repetición conserva las categorías elegidas y el saldo se refleja mediante una valoración contable sin volver a sumar el historial. Se actualiza al abrir/regresar con un mínimo de un minuto, o manualmente; no sincroniza con la app cerrada.
- Corregida la fecha de los movimientos demo: queda asociada a la creación de la conexión y ya no cambia con la fecha final de consulta. Se respeta el intervalo de historial solicitado.
- El usuario confirma que solo ha configurado Cloudflare. Se documenta la dependencia de Enable Banking y los pasos de uso personal restringido, sin activar producción ni solicitar claves en el chat. La vinculación/renovación de cuentas reales, conciliación manual/periódica, transferencias propias y cartera de valores siguen pendientes; no se presentan como implementadas por la prueba.
- Pruebas locales del servidor: 11 unitarias y 13 de integración superadas, además del empaquetado seco. Nuevas pruebas Swift preparadas para cuentas, resumen mensual, reglas, saldo, repetición, aislamiento y rechazo atómico de cargas inválidas en un job macOS de Actions. Su ejecución y la compilación iOS no se han podido realizar en Windows. Versión 0.4.0, build local 17; el IPA de Actions conserva su número de ejecución como build.
- Revisión local: 43 archivos Swift sin errores en el analizador sintáctico, 39 fuentes de app registradas exactamente una vez, proyecto/plist/esquemas válidos, cinco workflows y 21 scripts comprobados con actionlint y `bash -n`. Esto no equivale a comprobar tipos con el SDK de Apple. Servidor demo actualizado a `965c288a-69f6-47f4-b599-635ac7d1fc21`; consulta autenticada de estado HTTP 200 con acceso real desactivado. No se regeneraron secretos ni se cambiaron datos financieros reales.

## Autorizaciones antiguas en la demostración · 15 de octubre de 2026

- Ante el aviso `invalid_authorization` después de pulsar Conectar, se ha probado un flujo nuevo en el servidor desplegado: inicio 201, formulario 200 con estado coincidente, consentimiento 303, retorno correlacionado y conexión disponible. Se eliminó solo la conexión creada por esa comprobación (204). No se puede determinar a partir del mensaje si el intento del usuario había caducado, ya estaba consumido o no existía.
- La página de consentimiento valida ahora que la autorización siga pendiente antes de mostrar el formulario. Las autorizaciones inexistentes, caducadas o ya usadas muestran instrucciones de reinicio en español tanto al abrir como al enviar, conservando HTTP 400, sin exponer el estado ni redirigir a destinos suministrados por el navegador. La caducidad de diez minutos y el consumo atómico de un solo uso se mantienen.
- Verificación local: 10 pruebas unitarias y 13 de integración superadas, incluido el nuevo caso de formularios inexistentes/caducados/usados, recarga sin consumir y conexión nueva tras el rechazo. Empaquetado seco correcto. No requiere otro IPA, migraciones ni regeneración de claves.
- Publicado el Worker `3c5d6550-5288-495b-bf8a-36742c5cfdd1`. Comprobación remota de esta versión completada: formulario inexistente con instrucciones 400; autorización nueva 201, formulario 200, consentimiento 303 y retorno correlacionado; conexión y consulta de saldo/movimientos 200 con importes coherentes; reenvío bloqueado con instrucciones 400. Se eliminó solo la conexión de esta prueba (204). No se verificó desde un iPad ni se accedió a bancos reales.

## Corrección del formulario de demostración · 15 de octubre de 2026

- El formulario devolvía `forbidden`: su cabecera `no-referrer` provoca `Origin: null` en envíos POST del navegador, mientras que el servidor exige el origen HTTPS exacto. Solo la página de consentimiento pasa a `strict-origin`, sin incluir ruta ni parámetros en la referencia. Se mantienen la comprobación estricta de origen y el estado con caducidad y consumo único; la API y el retorno a la app conservan `no-referrer`.
- La prueba de regresión falló con la cabecera anterior y pasa con la corrección. Verificación local: 10 pruebas unitarias y 12 de integración con workerd/D1 superadas; empaquetado seco de Wrangler correcto. Se cubren el formulario generado, el retorno, los orígenes ausentes/nulos/externos y el rechazo de reutilización del estado.
- No cambia el cliente, el esquema D1 ni los secretos. Para publicar esta corrección hay que actualizar el Worker; no hace falta generar otro IPA.
- Worker actualizado en la cuenta existente (versión de despliegue `b059af1e-5333-4178-bd60-f97e292de614`, al 100%). Verificación remota tras la propagación: cinco consultas del formulario con HTTP 200 y `strict-origin`; API autenticada HTTP 200 en modo demo, con banca real e importación desactivadas. Esta comprobación no creó conexiones ni modificó registros financieros. Pendiente confirmar el envío desde el iPad.

## Corrección del 15 de octubre de 2026 · 0.3.1

- El registro de cierre aportado de la versión 0.3.0 sitúa el fallo en el hilo principal, en `CheckedContinuation.resume(throwing:)` dentro de `BankingBrowserAuthorization.authorize`, con `EXC_BREAKPOINT / SIGTRAP`. Había dos caminos de finalización: `start()` devolvía false y después podía llegar el callback asíncrono.
- El navegador tiene ahora una finalización única identificada por operación. Los callbacks repetidos/tardíos y las cancelaciones se ignoran una vez finalizada la operación. Se espera brevemente una ventana activa real y se informa si no puede presentarse, evitando un ancla vacía.
- La autenticación local se centraliza en AppLockManager. Bloqueo general y acciones bancarias comparten una petición de identidad; una verificación de hasta 30 segundos puede reutilizarse. El cambio transitorio a `inactive` oculta el contenido sin invalidar la autenticación ni lanzar otra. El segundo plano real sigue bloqueando e invalida resultados tardíos.
- Durante el flujo protegido no se lanza una segunda autenticación automática. Al cancelar/fallar una petición no se reintenta automáticamente; el usuario puede pulsar Desbloquear para reintentar. Desactivar el bloqueo de entrada no elimina la verificación requerida para banca.
- Las pruebas Swift de política cubren cambios repetidos de actividad, cancelación, segundo plano, expiración de reutilización, resultados antiguos y la finalización duplicada observada en el cierre. Se incluyen en el workflow del cliente junto a las políticas de red.
- Verificación local completada: 39 archivos Swift sin errores en el analizador sintáctico; las 36 fuentes de app incluidas una sola vez en Sources; configuraciones Debug/Release, plist y esquemas válidos; cinco workflows comprobados con actionlint y sus 20 scripts con `bash -n`; `git diff --check` sin errores. Este análisis no sustituye la compilación ni la ejecución de las pruebas Swift con Xcode.
- Versión 0.3.1, build local 16; los IPA de Actions mantienen su número de ejecución como build. No cambia el servidor, el esquema de datos, los secretos ni las claves existentes. La compilación Xcode, las nuevas pruebas Swift y la verificación con Touch ID en dispositivo siguen pendientes de Actions/dispositivo.

## Actualización del 15 de octubre de 2026 · 0.3.0 (15)

- Preparado un prototipo personal con Cloudflare Workers/D1 y pantalla de consulta en Ajustes. Demostración independiente del proveedor y sandbox oficial; producción bloqueada en código y verificación de entorno/servicio/retorno en la aplicación del proveedor.
- Acceso de dispositivo en Keychain con código obligatorio y sin sincronización/copia; red efímera HTTPS, destinos restringidos y sin seguir redirecciones. Claves del proveedor únicamente en secretos del servidor.
- Sesiones cifradas AES-256-GCM y estado OAuth de un solo uso con consumo atómico y caducidad. API de consulta y revocación, autenticación obligatoria, cuotas, cuentas comprobadas y tamaños/fechas/importes validados. El historial no se persiste en el servidor.
- El contenido se oculta al quedar inactivo sin destruir el flujo del navegador. La vista de prueba no modifica contabilidad ni permite pagos. No se ha cambiado el esquema SwiftData ni el formato de copia.
- Añadidos pruebas locales criptográficas y de integración con el motor workerd/D1, empaquetado seco y auditoría npm. Nuevo workflow sin secretos para repetirlas y comprobar la política del cliente Swift en macOS.
- Verificación local: 16 pruebas de servidor superadas (6 criptografía/contratos y 10 workerd/D1), empaquetado seco correcto y auditoría npm sin vulnerabilidades conocidas. Las 35 fuentes de app y 3 de pruebas pasan el análisis sintáctico, las 35 de app figuran una vez en Sources, y los cinco workflows/20 scripts pasan revisión de configuración/sintaxis. La política Swift nueva queda pendiente de ejecución en el runner macOS.
- Pendientes: compilación y ejecución en iOS, prueba del navegador/llavero/bloqueo en dispositivo, despliegue en la cuenta del usuario, prueba oficial sandbox y medición de CPU en Cloudflare Free. La conexión de cuentas reales y la importación contable son una fase posterior documentada en `BankingBackend/README.md`.

## Actualización del 6 de octubre de 2026 · 0.2.12 (14)

- Avisos minimizados integrados en la cabecera adaptable. La lista de Inicio elimina completamente la fila de alertas cuando todas están revisadas; los iconos permiten desplegarlas y se conserva el estado de revisión por datos/mes.
- Validación visible del formulario de movimientos mediante alerta; una descripción vacía o de espacios se rechaza antes de insertar datos y permite enfocar el campo al aceptar.
- Identificación común de cuentas con banco primero y nombre de cuenta después. Aplicada en movimientos, filtros, reservas, cargos periódicos, objetivos, tarjetas e importación CSV; los identificadores y los nombres guardados no se cambian.
- Los tres accesos de gestión de Cuentas son botones independientes. Cada herramienta tiene salida directa a Cuentas; el selector de saldo presenta tarjetas adaptables y abre el formulario tras terminar su cierre.
- El motor periódico admite gastos, comisiones, ingresos e intereses además de transferencias. Exige categorías compatibles para movimientos no transferidos, respeta cuentas activas/fecha de apertura/fecha de fin y conserva la protección por regla y fecha. Las nuevas reglas pueden ser automáticas y las anteriores conservan su modo. Los guardados fallidos revierten cambios pendientes.
- Pruebas preparadas: tres suscripciones, tres ingresos y dos comisiones pendientes, saldo y presupuesto resultantes, apertura repetida sin duplicados, reglas pausadas/manuales/futuras/incompatibles, identificación de dos cuentas del mismo banco, exportación/restauración de suscripciones y lectura de reglas antiguas sin modo automático.
- Se conserva el esquema SwiftData y el formato de copia de seguridad. Versión 0.2.12, build 14, en Debug y Release. La compilación con Xcode y las pruebas ejecutables deben pasar en Actions antes del merge; la revisión visual requiere dispositivo o simulador.
- Validación local completada: 34 fuentes Swift sin errores de sintaxis; 32 fuentes de app incluidas una sola vez; configuraciones, esquema, plist y assets válidos; cuatro workflows revisados con actionlint y 14 scripts con `bash -n`; `git diff --check` sin errores. Esta revisión no sustituye la comprobación de tipos ni la ejecución en macOS.

## Actualización del 6 de octubre de 2026 · 0.2.11 (13)

- Retirado el máximo de 840 puntos de Cuentas y fijados únicamente los márgenes laterales de la lista. Los accesos de gestión usan columnas adaptables al ancho y al tamaño de letra; los nombres de las cuentas vinculadas a tarjetas pueden ocupar varias líneas.
- Recuperada la separación visual de las métricas mensuales con fondos y bordes de color, conservando títulos, iconos y ocultación de importes.
- Añadida minimización individual de avisos revisados. Se guardan en las preferencias locales y mantienen un icono visible para desplegarlos. Un cambio en los datos del aviso lo muestra de nuevo; los presupuestos se distinguen por mes y por categorías, límites y gastos.
- `DashboardAlertReviewState.swift` se incluye en el target de la app y en las pruebas de servicios. Las pruebas cubren reapertura, mayor gasto, otra categoría con el mismo importe, cambio de mes, avisos independientes y preferencias inválidas.
- Validación local: 34 archivos Swift sin errores de sintaxis; las 32 fuentes de la app están incluidas una sola vez en el proyecto. La compilación con Xcode, las nuevas pruebas ejecutables y la revisión visual siguen pendientes de GitHub/dispositivo según el procedimiento de este documento.

Las secciones siguientes conservan el detalle de la revisión del 5 de octubre.

## Correcciones realizadas

1. **Compilación del diseño dinámico.** El registro adjunto identifica una declaración de `@ScaledMetric` sin valor inicial en `AdaptiveCardGrid`. Se ha inicializado la propiedad y se conserva el ancho personalizado de cada instancia. Las otras declaraciones de `@ScaledMetric` también tienen valor inicial.
2. **Mes al navegar a Presupuestos.** Inicio y Presupuestos compartían el concepto de mes, pero guardaban estados independientes. Ahora reciben el mismo estado desde `RootTabView`: abrir el detalle o crear un presupuesto conserva el mes que se estaba consultando.
3. **Gráfico patrimonial.** El último punto usaba el final del mes, aunque el patrimonio principal se calcula a fecha actual. Ahora la historia se corta en la fecha solicitada y no incorpora movimientos ni valoraciones posteriores a ella.
4. **Importes mal escritos.** El parser eliminaba caracteres y podía aceptar el prefijo de un número incompleto. Ahora valida el número completo y rechaza importes fuera del rango admitido. Se mantienen la coma decimal, el punto decimal y los separadores españoles e ingleses combinados.
5. **Reintentar un guardado fallido.** Registrar una valoración o una aportación periódica revierte las modificaciones pendientes si falla la escritura. Así se evita dejar una inserción pendiente que pueda guardarse después de mostrar un error.
6. **Comprobaciones antes del merge.** `Validar app iOS` se ejecutará al subir ramas `codex/…` y en los pull requests a `main`. Compila la app completa en Debug para simulador y Release para dispositivo sin firma; guarda un registro independiente por compilación.

No se ha cambiado el esquema SwiftData, el identificador de la app ni la configuración de almacenamiento durante esta revisión.

## Comprobaciones locales completadas

| Comprobación | Resultado |
| --- | --- |
| Sintaxis Swift con tree-sitter-swift | Los 31 archivos de la app y los 2 de pruebas se analizan sin errores sintácticos. No es una comprobación de tipos. |
| Proyecto Xcode con parser OpenStep | Las rutas existen y los 31 archivos Swift de la app figuran exactamente una vez en `Sources`; los ejecutables de pruebas no se incluyen en el target de la app. |
| Esquema y configuraciones | El esquema compartido referencia el target correcto; Debug y Release mantienen iOS 17, familias iPhone/iPad y versión 0.2.10, build 12. |
| Recursos | `Info.plist`, el XML del esquema y los JSON de assets se leen correctamente. El icono es PNG RGB de 1024 × 1024, sin canal alfa. |
| GitHub Actions | Los cuatro workflows pasan [actionlint](https://github.com/rhysd/actionlint); los 14 scripts de los workflows pasan `bash -n` y las rutas de fuentes usadas por las pruebas existen. |
| Diferencias Git | `git diff --check` no detecta errores de espacios o marcadores de conflicto. |

## Pruebas preparadas para ejecutar en GitHub

`Comprobar datos y cálculos` contiene dos trabajos que utilizan las clases y servicios reales de la app:

- **Exportación y restauración:** todos los modelos, incluyendo reglas de categoría y presupuestos repetidos; restauración repetida sin duplicados; lectura de copias anteriores sin esas colecciones; rechazo de datos inválidos y conservación de los datos actuales ante una copia inválida.
- **Cálculos y aportaciones automáticas:** saldos y valoraciones; reserva del máster excluida del disponible y conservada en el patrimonio; transferencia a inversión sin gasto ni incremento patrimonial; historial sin datos futuros; sobrante como ahorro o acumulado solo desde meses cerrados; ajuste de un presupuesto mensual; detención de repetición; tres aportaciones pendientes y una segunda apertura sin duplicados; categorías con iconos y restauración sin duplicados; reglas compatibles y prioridad de frases específicas; archivos CSV de ejemplo e importes inválidos.

Estas pruebas nuevas **todavía no se han ejecutado**: este equipo Windows no dispone de Swift, Xcode ni el SDK de iOS. La validación definitiva requiere subir el commit a la rama y esperar a los resultados del runner macOS.

## Antes de integrar

1. En GitHub Desktop, hacer commit de todos los cambios y pulsar **Push origin** en la rama de trabajo.
2. En Actions, comprobar que el último commit supera las dos compilaciones de **Validar app iOS** y los dos trabajos de **Comprobar datos y cálculos**. No hace falta hacer merge para ejecutarlos.
3. Revisar el aspecto siguiendo `PRUEBAS_REDISENO.md`, especialmente iPhone pequeño, iPad vertical/horizontal, pantalla dividida y texto de accesibilidad.

Esta configuración añade comprobaciones, pero no modifica la protección de `main`: por sí sola no impide pulsar Merge cuando un trabajo falla. Tampoco sustituye las pruebas de interacción y aspecto en un simulador o dispositivo real.
