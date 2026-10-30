# Conectar las cuentas propias · estado actual

El servidor personal está preparado y separado del sandbox. La aplicación de Enable Banking registrada es de producción y solo admite AIS (consulta); su firma y retorno se han comprobado. Sigue inactiva: todavía no se ha autorizado ni leído ninguna cuenta real.

El primer piloto será con una cuenta personal de Bankinter, después de que los checks de la nueva versión iOS pasen y se instale el IPA. El sandbox solo admite cuentas ficticias: los datos reales requieren producción restringida a cuentas propias.

La versión 0.6.0 añade asociación con cuentas existentes, conciliación con movimientos manuales y periódicos, conservación de reservas y sincronización con Supabase. La primera descarga se revisa antes de guardarse. Las claves permanecen en el servidor y no se incluyen en el IPA.

Pasos, comprobaciones realizadas, límites y pendientes: [integración personal](INTEGRACION_PERSONAL.md). Evaluación de cobertura y coste personal: [Enable Banking](EVALUACION_ENABLE_BANKING.md).

No regeneres las claves del sandbox ni del servidor personal para actualizar el IPA. No cambies el modo del servidor de pruebas para conectar una cuenta real.
