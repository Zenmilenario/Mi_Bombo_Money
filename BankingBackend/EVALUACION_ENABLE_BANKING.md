# Recuperar Enable Banking — evaluación del 30 de octubre de 2026

> Evolución posterior de esta evaluación: ya se ha preparado la [integración personal](INTEGRACION_PERSONAL.md). La compilación nativa y los once checks del commit `0722b8c` han pasado; el piloto real sigue pendiente.

## Recomendación

Retomar Enable Banking encaja con el objetivo de consultar las finanzas sin introducir manualmente cada gasto. La siguiente etapa propuesta es conectar una cuenta propia de BBVA con acceso solo de lectura, integrar los datos con la contabilidad personal y ampliar después a Bankinter. No se ha activado producción en esta revisión.

## Qué tenemos

El repositorio ya incluye un Worker de Cloudflare, sesiones de conexión y un escenario sandbox que importa cuentas, saldos, movimientos, categorías y transferencias ficticias a un almacén de pruebas separado. El proveedor se verifica como SANDBOX y el acceso real está bloqueado en el código. El catálogo permitido por ese Worker está limitado a BBVA, Banco de Sabadell y Mock ASPSP.

Supabase guarda ahora la contabilidad personal y se ha validado su sincronización con el iPad. La conexión bancaria y la persistencia cloud son módulos distintos: todavía falta asociar las conexiones con la identidad de Supabase y con las cuentas personales existentes.

## Coste y alcance verificados

Las [condiciones oficiales](https://enablebanking.com/terms/), leídas en la web renderizada, tienen fecha de actualización 9 de enero de 2026. Publican gratuidad dentro de su alcance: sandbox y producción restringida a cuentas vinculadas para uso personal o evaluación. El uso empresarial/comercial necesita un acuerdo aparte. No equivale a una garantía de precio invariable ni cubre automáticamente el alojamiento de nuestra app.

La [guía de cuentas vinculadas](https://enablebanking.com/docs/api/linked-accounts/) indica que una aplicación PRODUCTION puede activarse en modo restringido enlazando las cuentas propias concretas. La vinculación en el panel y el consentimiento mediante la API son pasos distintos; hay que incluir cada cuenta deseada.

## Cobertura y límites relevantes

- El [catálogo público para España](https://enablebanking.com/open-banking-apis?country=ES), consultado en el navegador el 30 de octubre de 2026, muestra BBVA, Bankinter, Banco Santander y Banco de Sabadell con AISP y entornos Sandbox y Production. También aparece ING Bank (Ing Bank, N.V. Sucursal en España), con las etiquetas ING e ING Wholesale Banking y los mismos servicios y entornos. Esta ficha no confirma por sí sola que una cuenta particular concreta de ING sea accesible: hay que verificar su modalidad. La cobertura publicada tampoco demuestra que todas las cuentas entreguen los campos que necesitamos.
- Ampliación propuesta, pendiente: obtener del proveedor el catálogo de bancos disponible para el entorno y para particulares, en vez de limitar la futura selección a las tres entidades iniciales. La lista permitida del sandbox actual no se ha modificado.
- Enable Banking señala que, desde agosto de 2026, la API PSD2 de Trade Republic entrega importe, moneda y fecha contable, sin datos descriptivos adicionales. Esto limita la clasificación por comercio. El usuario confirmó el enlace de su cuenta mediante QR en el iPad. Queda por comprobar qué movimientos e identificadores devuelve la primera descarga. [Documentación de Enable Banking sobre Trade Republic](https://enablebanking.com/docs/markets/de/#trade-republic).
- La app no integra posiciones de acciones o ETF. Obtener efectivo y movimientos de una cuenta no demuestra que se pueda importar su cartera de inversión.
- Según la [FAQ oficial](https://enablebanking.com/docs/faq/), la categorización corresponde a la aplicación; hay límites de consulta bancaria, periodos de consentimiento y disponibilidad de histórico variables. Por tanto, no se propone una actualización bancaria cada 15 segundos ni se promete un flujo instantáneo.

## Ventajas para esta app

- Incorporar movimientos y saldos de las cuentas compatibles con menos trabajo manual.
- Reutilizar el backend y las pruebas que ya existen, en vez de construir conexiones bancarias individuales.
- Aplicar nuestras reglas y mostrar las excepciones en Por revisar.
- Consolidar la información en Supabase y mostrarla desde los dispositivos del usuario.
- Ofrecer un proyecto de máster con ingesta, normalización, controles de calidad y análisis, usando conjuntos sintéticos o anonimizados para el trabajo académico.

## Desventajas y trabajo pendiente

- Dependencia del proveedor y de la disponibilidad y datos de cada banco.
- Reautorizaciones y posibles retrasos de actualización.
- Protección y mantenimiento de consentimientos, claves e identidad del propietario de cada conexión.
- Continuidad tras renovar una conexión: reconocer la misma cuenta sin crear otra ni repetir su historial.
- Conciliación con lo ya introducido: un pago manual, un cargo periódico generado por la app y el apunte descargado del banco pueden corresponder a una sola operación.
- Conciliación de saldo e historial para evitar sumar dos veces el dinero.
- Reconocimiento de transferencias propias y conservación de la financiación con reservas. El banco no conoce la intención personal de reservar dinero para un objetivo.

## Arquitectura objetivo

Banco → Enable Banking → backend bancario → contabilidad en Supabase → app.

Este es el objetivo propuesto, no el flujo personal real ya desplegado. Las claves del proveedor permanecen en el servidor. Solo se solicitaría información de cuentas; esta etapa no incluye iniciar pagos. La actualización programada desde el servidor aún debe implementarse y respetar los límites del banco.

## Orden de implementación propuesto

1. Preparar en sandbox el enlace entre usuario cloud, conexión y cuenta financiera; simular renovaciones y evitar duplicados con movimientos manuales y periódicos.
2. Añadir una primera carga supervisada que explique qué cuentas y movimientos se incorporarán y qué coincidencias requieren revisión.
3. Crear/activar una aplicación PRODUCTION restringida a una cuenta propia de BBVA y validar los datos que devuelve. La autorización bancaria la realiza el usuario.
4. Incorporar Bankinter después de comprobar su cuenta concreta. Evaluar por separado el efectivo y las limitaciones de Trade Republic.
5. Añadir actualización programada y seguimiento de errores. Mantener importación de archivos como alternativa para lo que las APIs no proporcionen.

No se han consultado cuentas reales, leído claves privadas, cambiado permisos, activado una aplicación de producción ni desplegado código en esta evaluación.

## Conceptos bancarios y marcadores /TXT/ — aclaración del 3 de noviembre

**Estado: primera mejora de presentación implementada en el código local de 0.6.10; compilación nativa y prueba física pendientes.**

El flujo es banco → Enable Banking → servidor personal → app. Enable Banking adapta las respuestas de bancos distintos a una estructura común; no aporta por defecto una capa propia de enriquecimiento o categorización. Si el banco entrega códigos de operación, comercio o finalidad, el proveedor puede trasladarlos en los campos correspondientes, según disponibilidad. Fuente: [base de conocimiento, apartado Data](https://enablebanking.com/knowledge-base).

Los movimientos llegan por la API como JSON con campos separados para importe, moneda, fechas, sentido del apunte e identificadores, además del concepto. /TXT/ forma parte de un texto descriptivo recibido; no significa que el movimiento llegue como un archivo TXT. Referencia: [API de movimientos](https://enablebanking.com/docs/api/reference/#get-account-transactions).

Comprobado en nuestro código: normalizeTransaction, en BankingBackend/src/provider.mjs, une las cadenas de remittance_information con espacios y limita el concepto a 500 caracteres. Si no hay concepto, utiliza el nombre del acreedor/deudor o un texto genérico. No añade marcadores /TXT/ ni los elimina. Por ello esos marcadores ya vienen en el texto entregado por Enable Banking. No se ha contrastado la respuesta original directa del banco ni confirmado el significado concreto de cada marcador; no se deben atribuir significados a D/H u otros prefijos sin verificarlo.

En 0.6.10 se deriva un título legible sin modificar el campo almacenado. Se retiran únicamente los prefijos iniciales observados `/TXT/D|` y `/TXT/H|` en movimientos bancarios identificados; el texto guardado sigue accesible en el detalle y las vistas previas. Los formatos desconocidos se conservan. La presentación y la categoría no sustituyen los identificadores usados para detectar duplicados. Véase [Revisión y clasificación de movimientos](../REVISION_MOVIMIENTOS.md). El campo actual de 500 caracteres no equivale a conservar la respuesta bancaria completa; una descripción manual conservada al conciliar o editada después tampoco garantiza ser el texto original del proveedor.

## Alta para un piloto con varios participantes

Evaluación del 4 de noviembre de 2026. El piloto multiusuario es una propuesta. El servidor bancario actual admite exclusivamente el usuario de Supabase configurado y usa ese propietario al proteger las sesiones.

La vinculación desde el panel de Enable Banking habilita cuentas propias en producción restringida. La autorización desde la app es un paso independiente. Las condiciones publicadas delimitan el acceso restringido a las cuentas del usuario del panel que las vinculó. La activación completa requiere acuerdo, verificación y revisión por Enable Banking. Para un piloto cerrado con datos de otras personas conviene consultar qué modalidad autoriza el proveedor, qué costes tiene y qué requisitos aplica. [Cuentas propias](https://enablebanking.com/docs/api/linked-accounts) · [Condiciones de uso](https://enablebanking.com/terms/) · [Activación en el panel](https://enablebanking.com/docs/api/control-panel/).

Con una modalidad aprobada, cada participante entraría en Mi Bombo Money con su invitación y elegiría su banco. El servidor iniciaría la autorización y la app abriría la página correspondiente. El participante se identificaría y aprobaría el acceso con su banco. Al volver, la app ofrecería crear o asociar las cuentas autorizadas y revisar la primera descarga. La API ya permite iniciar y completar este flujo sin que el participante abra el panel. [Referencia de sesiones](https://enablebanking.com/docs/api/reference/#start-user-authorization).

Antes del piloto real hace falta aislar las invitaciones, sesiones bancarias, credenciales de sesión y operaciones de lectura y desconexión por usuario, y probar el aislamiento entre dos perfiles. La decisión de participar en el estudio del TFM se plantearía aparte del consentimiento bancario. El piloto puede comenzar en sandbox con datos ficticios y medir tiempos, pasos y errores. Una opción para evaluar la clasificación con datos reales es procesar un extracto en el dispositivo y recoger solo métricas agregadas de quien acepte participar.

## Verificación de Trade Republic desde otro dispositivo

El alta en el panel y la autorización de Mi Bombo Money son pasos separados. Si el bloqueo aparece en el panel, se puede volver a iniciar el flujo en el navegador de un móvil propio con cámara. Si aparece en la app, la opción a probar es iniciar y terminar la autorización en un iPhone con Mi Bombo Money y la misma cuenta de Mi nube. El servidor registra las conexiones por usuario y el iPad puede consultarlas desde Mis bancos. Esta prueba con dos dispositivos queda pendiente. [Vinculación de cuentas propias](https://enablebanking.com/docs/api/linked-accounts).

Con acceso a la app de Trade Republic, su sección de Ayuda permite contactar por chat o llamada y pedir instrucciones para completar la verificación. El banco decide qué método admite. Como alternativa para incorporar movimientos, Trade Republic documenta un extracto de efectivo en PDF. Mi Bombo Money admite importar CSV y requeriría convertir el extracto en el dispositivo. [Atención al cliente](https://traderepublic.com/en-es?openModal=imprint) · [Extracto de efectivo](https://support.traderepublic.com/es-es/267).

## Trade Republic muestra la página de descarga con la app instalada

El panel de Enable Banking muestra Trade Republic entre las cuentas vinculadas de la aplicación de producción. En el iPhone, la autorización iniciada desde Mi Bombo Money llega a una página de Trade Republic que ofrece descargar la app. Abrir Trade Republic desde la tienda llevó al usuario a su cuenta sin mostrar la solicitud de consentimiento. La evidencia sitúa la incidencia antes de que la autorización llegue a nuestro servidor. La causa exacta del salto a la app queda por confirmar.

## Conectar Trade Republic desde el iPad con un QR

El usuario confirmó el 4 de noviembre de 2026 que pudo enlazar Trade Republic desde el iPad al solicitar la versión de escritorio y escanear el QR con el móvil. La versión de escritorio de la página del banco muestra el QR dentro de la autorización iniciada en Mi Bombo Money. El iPad muestra el código y la cámara del móvil lo escanea.

1. Si la cuenta aún no figura en **Linked accounts** de la aplicación de producción de Enable Banking, vincúlala allí. En producción restringida, este alta habilita la cuenta para autorizarla después desde Mi Bombo Money. [Vinculación de cuentas propias](https://enablebanking.com/docs/api/linked-accounts).
2. En el iPad, abre **Mi Bombo Money → Ajustes → Mis bancos**, elige **Trade Republic** y continúa desde la tarjeta de instrucciones.
3. En la página de Trade Republic, abre el menú de la parte superior y selecciona la opción para solicitar el sitio web de escritorio. Si el QR ya aparece, pasa al siguiente paso. [Cómo solicitar el sitio de escritorio en el iPad](https://support.apple.com/es-mx/guide/ipad/ipad54f3cde6/ipados).
4. Deja abierta la página en el iPad. Escanea el QR con la cámara del móvil donde tienes Trade Republic, inicia sesión allí si se solicita y confirma que quieres compartir la cuenta con Enable Banking.
5. Al terminar, vuelve a **Mis bancos** en el iPad. Si Trade Republic aún no aparece, pulsa **Comprobar conexión**. Asocia el efectivo a la cuenta que ya llevas en Mi Bombo Money y revisa la primera descarga antes de incorporarla.

La tarjeta nueva está implementada en 0.6.13 y queda pendiente probar su presentación en iOS. El QR lo genera Trade Republic para la solicitud activa. Para las instrucciones de la app basta con explicar cómo obtenerlo y escanearlo.
