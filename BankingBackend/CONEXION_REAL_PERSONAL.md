# Conectar las cuentas propias · estado actual

El servidor personal está preparado y separado del sandbox. La aplicación de Enable Banking registrada es de producción y solo admite AIS (consulta); su firma y retorno se han comprobado. El propietario ha vinculado la cuenta de prueba en el panel y se ha verificado la aplicación activa, con servicio exclusivo AIS. En esta verificación solo se han consultado la configuración de la aplicación y el catálogo de bancos, sin leer saldos ni movimientos. Falta completar la conexión desde la app.

El primer piloto será con una cuenta personal de Bankinter, después de instalar el IPA 0.6.0. Los once checks del commit `0722b8c` están aprobados, incluidas las compilaciones iOS y las pruebas SwiftData. El sandbox solo admite cuentas ficticias: los datos reales requieren producción restringida a cuentas propias.

La versión 0.6.0 añade asociación con cuentas existentes, conciliación con movimientos manuales y periódicos, conservación de reservas y sincronización con Supabase. La primera descarga se revisa antes de guardarse. Las claves permanecen en el servidor y no se incluyen en el IPA.

Pasos, comprobaciones realizadas, límites y pendientes: [integración personal](INTEGRACION_PERSONAL.md). Evaluación de cobertura y coste personal: [Enable Banking](EVALUACION_ENABLE_BANKING.md).

No regeneres las claves del sandbox ni del servidor personal para actualizar el IPA. No cambies el modo del servidor de pruebas para conectar una cuenta real.

## Actualización necesaria: 0.6.1

Se corrigió la validación del dominio real que devuelve Bankinter a través de Enable Banking. El servidor está actualizado; el cliente 0.6.0 también debe sustituirse por 0.6.1 tras publicar y validar esta revisión. No hace falta volver a vincular la cuenta en el panel ni cambiar las claves. [Detalle y pruebas](INTEGRACION_PERSONAL.md#corrección-de-autorización--061).
