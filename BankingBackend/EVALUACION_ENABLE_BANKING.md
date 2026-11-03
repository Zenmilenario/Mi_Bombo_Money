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
- La [documentación de Trade Republic](https://enablebanking.com/docs/markets/de/#trade-republic) señala que, desde agosto de 2026, su API PSD2 entrega importe, moneda y fecha contable, sin datos descriptivos adicionales, para todos los países. Esto limita especialmente la clasificación por comercio. No se ha probado el acceso a la cuenta concreta del usuario ni la disponibilidad de identificadores suficientes.
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

**Estado: mejora acordada con el usuario el 3 de noviembre de 2026; pendiente de implementar.**

El flujo es banco → Enable Banking → servidor personal → app. Enable Banking adapta las respuestas de bancos distintos a una estructura común; no aporta por defecto una capa propia de enriquecimiento o categorización. Si el banco entrega códigos de operación, comercio o finalidad, el proveedor puede trasladarlos en los campos correspondientes, según disponibilidad. Fuente: [base de conocimiento, apartado Data](https://enablebanking.com/knowledge-base).

Los movimientos llegan por la API como JSON con campos separados para importe, moneda, fechas, sentido del apunte e identificadores, además del concepto. /TXT/ forma parte de un texto descriptivo recibido; no significa que el movimiento llegue como un archivo TXT. Referencia: [API de movimientos](https://enablebanking.com/docs/api/reference/#get-account-transactions).

Comprobado en nuestro código: normalizeTransaction, en BankingBackend/src/provider.mjs, une las cadenas de remittance_information con espacios y limita el concepto a 500 caracteres. Si no hay concepto, utiliza el nombre del acreedor/deudor o un texto genérico. No añade marcadores /TXT/ ni los elimina. Por ello esos marcadores ya vienen en el texto entregado por Enable Banking. No se ha contrastado la respuesta original directa del banco ni confirmado el significado concreto de cada marcador; no se deben atribuir significados a D/H u otros prefijos sin verificarlo.

Mejora propuesta, pendiente de implementar: separar el concepto bancario original de un título legible, limpiar únicamente patrones conocidos y conservar el original en el detalle. La presentación y la categoría no deben sustituir los identificadores bancarios usados para detectar duplicados. No se ha implementado esta limpieza ni se han modificado movimientos en esta aclaración. El campo actual de 500 caracteres no equivale a conservar la respuesta bancaria completa.
