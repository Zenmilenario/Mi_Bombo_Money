# Lista de pruebas del rediseño

## Sandbox del proveedor · 0.4.1

- [ ] Actualizar conexiones muestra entorno Sandbox y los bancos de prueba disponibles. BBVA/Sabadell usan las credenciales ficticias documentadas por Enable Banking.
- [ ] El navegador abre la autorización oficial del sandbox sin error de destino inválido y vuelve a la app tras autorizar. Cancelar permite volver a intentarlo sin cerrar la app.
- [ ] El espacio nuevo indica Sandbox y no incluye las cuentas ni movimientos de la demostración anterior. Volver a mis finanzas mantiene los datos reales.
- [ ] Cambiar de servidor o de entorno mientras está abierto el espacio impide sincronizar en el archivo anterior y pide cerrar/reabrir; no se importan datos parciales.
- [ ] Mock ASPSP, con datos configurados en el panel, permite ensayar ingresos, gastos, paginación, repetición y revocación. Las pruebas con el proveedor y en iPad quedan pendientes hasta completarlas con su autorización.

## Integración bancaria en toda la app · 0.4.0

- [ ] Con una conexión ya creada, abrir Ajustes → Datos → Conexiones bancarias → Abrir Inicio, Cuentas y Movimientos de prueba. No pide volver a autorizar el banco.
- [ ] Una conexión nueva abre automáticamente el espacio completo al volver del navegador.
- [ ] El indicador «App de prueba · Datos ficticios» y Volver a mis finanzas permanecen visibles en todas las pestañas. En iPhone estrecho, iPad en vertical/horizontal, Split View y letra grande, título y botones se apilan sin recortes.
- [ ] Para una sola cuenta demo, Cuentas muestra 1.234,56 €, Movimientos contiene un ingreso de 1.500,00 € y un gasto de 265,44 €, e Inicio refleja ambos. Los movimientos tienen categoría e icono.
- [ ] Actualizar varias veces no crea más cuentas, movimientos, importaciones ni valoraciones duplicadas. Cambiar una categoría y actualizar conserva la categoría elegida.
- [ ] Crear un presupuesto de Otros gastos en el espacio de prueba y comprobar que el gasto ficticio afecta al presupuesto y al resumen.
- [ ] Volver a mis finanzas conserva exactamente las cuentas, movimientos y saldos reales anteriores; la copia JSON normal no incluye el espacio de prueba. Las opciones de importar/exportar no aparecen dentro de la prueba.
- [ ] Cancelar una carga o fallar una página conserva los datos anteriores y permite reintentar sin guardar una carga parcial.
- [ ] Pasar a segundo plano oculta también la pantalla completa de prueba. Volver requiere desbloquear si el bloqueo está activo. La actualización no provoca nuevas peticiones de identidad.
- [ ] Tras desconectar un banco, su historial de prueba permanece, pero deja de actualizarse. No se presenta como una conexión bancaria real.
- [ ] La información explica que Cloudflare solo aloja el servidor, incluye el enlace a Enable Banking y no pide contraseñas bancarias ni la clave privada en la app.

## Inicio

- [ ] El botón azul aparece abajo a la derecha y no tapa la barra inferior.
- [ ] Se muestra un saludo según la hora en lugar del título `Inicio`.
- [ ] Las métricas mensuales y la tasa de ahorro se ven sin desplazamiento horizontal; la aportación a inversión aparece cuando corresponde.
- [ ] Cada métrica mensual destaca con fondo y borde: verde para ingresos, rojo para gastos, azul para ahorro positivo (rojo si es negativo) y morado para inversión; los importes se leen en claro y oscuro.
- [ ] La tarjeta principal muestra patrimonio, variación mensual y fecha de actualización.
- [ ] Ocultar importes también oculta cifras y gráficos.
- [ ] Los avisos abren la pestaña adecuada.
- [ ] `Revisado · minimizar` convierte ese aviso en un icono a la derecha; los demás avisos permanecen desplegados.
- [ ] Al minimizar todos los avisos queda una tarjeta compacta con sus iconos y `Revisados · siguen activos`.
- [ ] Tocar un icono vuelve a desplegar ese aviso; `Volver a minimizar` lo devuelve al estado compacto.
- [ ] Cerrar y volver a abrir la app mantiene minimizados los avisos revisados si sus datos no han cambiado.
- [ ] Añadir gasto a una categoría superada o superar otra categoría despliega de nuevo el aviso, incluso si sigue habiendo el mismo número de presupuestos superados.
- [ ] Cambiar a otro mes no marca como revisados los avisos de ese mes. Volver al anterior conserva su estado cuando los datos siguen iguales.
- [ ] La minimización se puede usar con importes ocultos y VoiceOver anuncia que el aviso revisado sigue activo.
- [ ] No hay lista de cuentas repetida en Inicio; el aviso de cuentas sin actualizar abre Cuentas.
- [ ] `Ver movimientos` abre Movimientos.
- [ ] `Ver detalle` y `Crear presupuestos` abren Presupuestos conservando el mes seleccionado en Inicio; cambiar el mes en Presupuestos mantiene el mismo mes al regresar a Inicio.
- [ ] El selector 3 M / 6 M / 1 A / Todo cambia el gráfico.
- [ ] La evolución termina en el mes actual aunque se consulte otro mes en el resumen mensual.
- [ ] Si hay movimientos o valoraciones con fecha futura dentro del mes, el último punto del gráfico patrimonial coincide con el patrimonio actual y no los incluye.
- [ ] Las tarjetas se distribuyen en columnas cuando caben y pasan a una columna al estrechar la ventana; el resumen mensual queda antes del gráfico en la lectura vertical.

## Movimientos

- [ ] El botón flotante abre el formulario de nuevo movimiento.
- [ ] No aparece un segundo botón `+` en la barra superior.
- [ ] Los filtros activos aparecen como chips y se pueden quitar individualmente.
- [ ] `Limpiar` elimina todos los filtros.
- [ ] La búsqueda sigue funcionando con los filtros.
- [ ] Deslizar a la izquierda permite eliminar; el detalle del movimiento permite editar.
- [ ] Los posibles duplicados se pueden revisar desde el aviso.
- [ ] `Análisis de gastos` muestra el gráfico y el detalle por categoría.

## Cuentas

- [ ] Cuentas muestra herramientas de gestión, sin otro resumen patrimonial.
- [ ] Cuentas aprovecha todo el ancho disponible con márgenes laterales de 16 puntos, sin quedarse en 840 puntos; comprobar también ventana de más de 1200 puntos y pantalla dividida.
- [ ] Sus tres accesos de gestión pasan de una a dos o tres columnas según el ancho y la letra, sin cambiar de pantalla ni perder la búsqueda.
- [ ] Las acciones de deslizar para editar, archivar o actualizar siguen funcionando con la lista a cualquier ancho.
- [ ] El selector Cuentas / Tarjetas funciona y la búsqueda encuentra nombres, bancos y cuentas vinculadas; en tarjetas también encuentra los últimos cuatro dígitos.
- [ ] Las cuentas se agrupan por día a día, ahorro, inversión, deudas y otras cuentas.
- [ ] `Actualizar un saldo o valoración` y la acción de deslizar abren el formulario para la cuenta elegida.
- [ ] El formulario de valoración muestra el saldo actual; cancelar no guarda cambios.
- [ ] En una cuenta con reservas se muestran el saldo y el disponible correctamente; las tarjetas no repiten ese saldo.
- [ ] Los accesos a reservas y cargos periódicos abren la pantalla correcta.
- [ ] Las cuentas antiguas muestran `Sin actualizar`.
- [ ] Revisar saldos sin actualizar filtra las cuentas; `Mostrar todas las cuentas` retira el filtro.
- [ ] Archivar una cuenta la mueve a `Elementos archivados`.
- [ ] Restaurar una cuenta o tarjeta vuelve a mostrarla en la lista principal.
- [ ] Añadir y editar cuentas y tarjetas sigue funcionando.

## Presupuestos

- [ ] El resumen global coincide con la suma de los presupuestos del mes.
- [ ] Las categorías superadas aparecen primero.
- [ ] Las categorías sin límite aparecen juntas en una tarjeta de iconos, con su nombre accesible mediante VoiceOver.
- [ ] Tocar un icono abre el editor de esa categoría. Tras guardar desaparece de la tarjeta y aparece en los presupuestos activos del mes.
- [ ] El punto naranja solo aparece si hay gasto sin presupuesto en la categoría.
- [ ] El gráfico compara gasto y límite únicamente de presupuestos activos; con más de seis se indica el recuento y se puede abrir la comparativa completa.
- [ ] Ocultar importes oculta también el gráfico de presupuestos.
- [ ] Cambiar de mes actualiza el gráfico y la tarjeta de categorías; los presupuestos repetidos y el sobrante mantienen sus cálculos.
- [ ] Tocar una categoría permite editar su límite.
- [ ] La pantalla de análisis compara presupuesto y gasto real.

## Ajustes

- [ ] Face ID o código sigue activándose y desactivándose.
- [ ] El tema automático, claro y oscuro funciona.
- [ ] La información de datos locales muestra los recuentos correctos.
- [ ] Privacidad y Ayuda se abren correctamente.
- [ ] Movimientos recurrentes conserva sus funciones anteriores.

## Revisión visual

- [ ] Probar en modo claro y oscuro.
- [ ] Probar con importes visibles y ocultos.
- [ ] Probar al menos en iPhone 14 Pro y en un iPhone más pequeño si Appetize lo permite.
- [ ] Probar en iPad vertical, horizontal y Split View, incluyendo una anchura estrecha.
- [ ] Comprobar que ningún importe se corta con cantidades grandes.
- [ ] Comprobar que las pantallas siguen siendo legibles con un tamaño de texto mayor.

## Diseño dinámico 0.2.10

- [ ] Cambiar continuamente el ancho de la ventana: las columnas se recalculan sin reiniciar la app y sin perder el mes, la búsqueda ni la categoría seleccionados.
- [ ] Repetir la prueba en horizontal, vertical y pantalla dividida; el mismo ancho disponible produce la misma disposición en cualquier dispositivo.
- [ ] Probar letra normal, grande y tamaños de accesibilidad: las tarjetas tienen menos columnas cuando la letra crece y las filas apilan descripción e importe cuando hace falta.
- [ ] Comprobar nombres de cuentas y categorías largos e importes grandes: los textos se pueden leer sin desplazamiento horizontal.
- [ ] El resumen y el gráfico de Presupuestos se colocan juntos cuando hay espacio y uno debajo del otro al reducirlo.
- [ ] El botón rápido respeta las barras de navegación y pestañas y el último movimiento queda accesible al desplazarse.

## Ajustes de uso 0.2.12 (14)

- [ ] Superar un presupuesto y minimizar su aviso: la tarjeta compacta aparece en la cabecera sin dejar una fila vacía; tocar el icono vuelve a desplegarla. Probar un aviso, varios y una mezcla de revisados/nuevos.
- [ ] Repetir en iPhone pequeño, iPad vertical/horizontal, Split View y letra de accesibilidad: la cabecera y el selector visual se reorganizan con el ancho disponible.
- [ ] Guardar un movimiento con descripción vacía o solo espacios: aparece un aviso, no se inserta el movimiento y «Aceptar» permite escribir la descripción. Después guardar normalmente.
- [ ] Crear dos cuentas del mismo banco con nombres distintos: los selectores, filtros, movimientos, reservas y transferencias muestran el banco primero y conservan la distinción entre cuentas. Una cuenta sin banco usa su nombre.
- [ ] Abrir reservas y volver directamente a Cuentas; repetir con cargos periódicos. Al añadir/editar un elemento, guardar o cancelar regresa a la herramienta correspondiente y «Volver a Cuentas» cierra la herramienta.
- [ ] Abrir «Actualizar saldo o valoración»: elegir una tarjeta con icono/color/banco/cuenta. Guardar o cancelar la valoración regresa a Cuentas. Cerrar el selector sin elegir no abre un formulario.
- [ ] Programar una suscripción mensual con categoría Suscripciones, cuenta e importe: cada vencimiento resta de esa cuenta y consume el presupuesto de la categoría. No crea una transferencia a inversión.
- [ ] Reabrir la app y comprobar que los cargos no se duplican; comprobar una regla pausada, otra manual y una con fecha futura. Probar fecha de fin inclusiva y editar una regla anterior para activar su registro automático.
- [ ] Exportar y restaurar una copia con una suscripción automática: conserva cuenta, categoría, fecha siguiente y modo automático. Las copias antiguas sin modo automático conservan reglas manuales.

## Conexión bancaria de prueba 0.3.0 (15)

- [ ] Ejecutar las pruebas de backend y desplegar en una cuenta Cloudflare Workers/D1 Free siguiendo `BankingBackend/README.md`. No introducir cuentas ni credenciales reales.
- [ ] Configurar la dirección HTTPS propia y clave en Ajustes → Datos → Conexión bancaria · Prueba; sin código del dispositivo debe fallar el guardado protegido. Verificar errores de clave, host, HTTP, red y servidor no configurado.
- [ ] Conectar un banco ficticio, completar o cancelar el navegador del sistema y volver a la app. El bloqueo/ocultación al quedar inactiva no destruye el flujo. Repetir con Face ID/Touch ID y bloqueo por código.
- [ ] Consultar cuentas, saldos y movimientos ficticios. Confirmar que no cambian las cuentas, transacciones, presupuestos ni patrimonio actuales.
- [ ] Dejar la app en segundo plano y abrir el selector de aplicaciones: el contenido debe quedar oculto incluso si el bloqueo de entrada está desactivado. Al volver, comprobar que la consulta funciona y se respeta el bloqueo configurado.
- [ ] Cerrar/reabrir la app: URL y acceso se recuperan del llavero; no deben aparecer claves, sesiones ni la vista previa en el JSON de copia de seguridad.
- [ ] Desconectar: desaparece la conexión y deja de poder consultarse. Si falla la revocación, debe conservarse para reintentar. Olvidar acceso explica que solo borra la clave local.
- [ ] Probar sandbox con claves exclusivamente SANDBOX. Una aplicación de producción se rechaza antes de iniciar autorización, aunque se haya configurado por error.
- [ ] Revisar iPhone/iPad y texto grande; comprobar retorno de autorización, navegación, importes ocultos y cancelaciones repetidas.
- [ ] Medir en Cloudflare el consumo de CPU del primer firmado RSA y las consultas con varias cuentas. No activar planes de pago automáticamente si supera Free.

## Corrección de huella y cierre 0.3.1

- [ ] Abrir la app y autenticar una vez. Entrar en Conexión bancaria y tocar BBVA inmediatamente: la verificación reciente se reutiliza y se abre el navegador de demostración sin bucle de huella.
- [ ] Esperar más de 30 segundos antes de conectar: se solicita una única verificación adicional y después se abre el navegador.
- [ ] Cancelar la huella o introducir un código incorrecto: no se debe lanzar otra petición automáticamente. El botón Desbloquear permite reintentar.
- [ ] Repetir conectar/cancelar el navegador al menos cinco veces: la app no debe cerrarse ni quedar permanentemente ocupada. Un fallo al abrir el navegador muestra un aviso para reintentar.
- [ ] Enviar la app realmente a segundo plano durante la verificación: al volver, ningún resultado antiguo debe desbloquearla. Comprobar ocultación en el selector de aplicaciones.
- [ ] Completar o cancelar el navegador tras cambiar de app: el desbloqueo de retorno espera a que termine el flujo y no compite con él.
- [ ] Repetir con el bloqueo general activado y desactivado: la operación bancaria sigue requiriendo verificación aunque el bloqueo de entrada esté desactivado.
- [ ] Comprobar Touch ID en el iPad afectado, Face ID y cancelación mediante el código del dispositivo. Confirmar versión 0.3.1 del IPA instalado; su build puede diferir del proyecto por el número de ejecución de Actions.

## Comprobaciones antes del merge

- [ ] Subir el commit a la rama de trabajo desde GitHub Desktop con `Push origin`.
- [ ] En Actions, `Validar app iOS` supera ambas compilaciones: Debug para simulador y Release para dispositivo.
- [ ] `Comprobar datos y cálculos` supera exportación/restauración y cálculos/movimientos automáticos.
- [ ] Las comprobaciones corresponden al último commit que se va a integrar.
- [ ] `Comprobar conexión bancaria de prueba` supera las pruebas de backend/workerd/D1 y la política de destinos/retorno del cliente Swift.
- [ ] Probar los cambios visuales en iPhone pequeño, iPad vertical/horizontal y ventana estrecha; la compilación automática no comprueba el aspecto en pantalla.
