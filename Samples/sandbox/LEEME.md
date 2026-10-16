# Prueba completa · Mock ASPSP · 0.4.2

## Ya preparado el 16 de octubre de 2026

Las tres cuentas se han cargado en **Enable Banking → Mock ASPSP**. Se ha completado la autorización del proveedor y verificado la consulta a través del Worker desplegado: 75 apuntes recibidos, con importes, identificadores y referencias de transferencias iguales a los del archivo preparado. La conexión queda disponible para tu app; la sesión del proveedor caduca y puede requerir una nueva autorización.

El Worker ya está actualizado. **Necesitas instalar el IPA 0.4.2**, generado después de subir estos cambios y de que pasen las comprobaciones de GitHub Actions. No hace falta repetir migraciones, generar claves ni usar la terminal.

1. Actualiza la app conservando la instalación y sus datos.
2. Ve a **Ajustes → Datos → Conexiones bancarias → Actualizar conexiones**.
3. Si aparece Mock ASPSP, pulsa **Abrir Inicio, Cuentas y Movimientos de prueba**.
4. Si su autorización ha caducado, elige **Mock ASPSP**, continúa la autorización, inicia sesión en Enable Banking si lo pide y marca las **tres** cuentas antes de autorizar. No uses claves de bancos reales.
5. Se abrirá **Prueba completa · Mock ASPSP** y se cargarán los datos en las pestañas habituales. Puedes salir con **Volver a mis finanzas**.

La prueba usa otro archivo local. La cuenta «Prueba x» y otros datos introducidos en el espacio sandbox anterior se conservan allí; no se suman a este escenario. Tus finanzas reales también conservan su propio archivo.

## Qué comprobar

Datos de agosto, septiembre y octubre de 2026, hasta el día 16:

| Pantalla / concepto | Resultado inicial |
| --- | ---: |
| Cuentas · Día a día | 3.570,68 € |
| Cuentas · Máster (ahorro) | 1.909,00 € |
| Cuentas · Inversión | 1.281,50 € |
| Inicio · Patrimonio total | **6.761,18 €** |
| Inicio · Reservado para el máster | 1.500,00 € |
| Inicio · Disponible para usar | **3.979,68 €** |
| Octubre · Ingresos | 2.540,00 € |
| Octubre · Gastos | 1.452,94 € |
| Octubre · Ahorro neto | 1.087,06 € |
| Octubre · Aportado a inversión | 250,00 € |
| Presupuesto Supermercado · Límite / gasto | 180,00 € / 203,95 € |
| Presupuesto Supermercado · Exceso | 23,95 € |

- **Movimientos:** 69 operaciones en total. Los 12 apuntes de transferencias se emparejan en seis operaciones propias; no se cuentan como ingresos/gastos. Hay dos cafés del mismo importe y fecha por mes, con IDs diferentes: deben conservarse ambos.
- **Categorías:** se incluyen reglas para reconocer nómina, supermercado, alquiler, suministros, transporte, farmacia, restaurantes, suscripción, ocio, mascotas, reembolsos, intereses, dividendos y comisiones. Una categoría que cambies manualmente se conserva al actualizar.
- **Presupuestos:** cuatro categorías con repetición mensual; unas dejan el sobrante como ahorro y otras lo añaden al mes siguiente. Puedes revisar/minimizar el aviso del supermercado y volver a abrirlo desde su icono.
- **Cuentas:** una tarjeta ficticia vinculada a Día a día, con límite, compras online y cashback de ejemplo. No añade otro saldo.
- **Reservas:** el máster se descuenta del disponible, manteniéndose dentro del patrimonio.
- **Cargos periódicos:** dos plantillas locales (suscripción y aportación a inversión), inicialmente **pausadas** para evitar duplicar operaciones ya sincronizadas. Puedes activarlas si quieres probar el registro periódico por separado.
- **Actualizar:** cero movimientos nuevos; las cuentas, operaciones, tarjeta, reserva, reglas y presupuestos no deben duplicarse. Reautorizar este escenario conocido tampoco crea otras copias de las cuentas.

Los presupuestos, reserva, tarjeta y plantillas son ejemplos locales preparados por la app al reconocer este escenario. No proceden de una API bancaria de tarjetas/presupuestos. La cuenta de inversión es una simulación en euros, sin valores ni cotizaciones reales.

## Por qué BBVA no mostraba movimientos

La consulta comprobada de sus siete cuentas devolvió cero movimientos en el intervalo consultado. Solo tres daban saldo CLBD; otras ofrecían OPBD (apertura) o XPCD (previsto). El importador rechazaba el conjunto completo. Ahora se importan las cuentas con saldo contable compatible y las restantes se explican individualmente, sin convertir saldos previstos en dinero contabilizado. Se admite ITBD, con preferencia sobre CLBD, y se consultan 90 días.

## Reproducir o renovar las fechas

`mi-patrimonio-mock.json` contiene solo datos inventados, con IBAN sintético y referencias estables. `resultados-esperados.json` recoge sus totales. El archivo ya está cargado en el panel: **no lo vuelvas a subir ahora**, para evitar cuentas repetidas.

Para generar otro conjunto con fechas actuales, desde `BankingBackend`:

```powershell
node tools/generate-sandbox-scenario.mjs
```

Después habrá que actualizar los datos del escenario en Mock ASPSP. El generador no modifica el proveedor ni tus datos por sí solo. Los totales dependen del día de generación; no crea operaciones futuras. Los archivos de esta entrega son una instantánea del 16 de octubre, no un banco simulado que genere nuevas operaciones cada día.

## Validación

- 13 pruebas unitarias y 17 de integración del servidor, incluidas paginación, cifrado, renovación y datos del escenario.
- Autorización y lectura completas con el Mock ASPSP real, utilizando el servidor personal.
- Prueba SwiftData preparada en Actions: importa el mismo JSON normalizado que usa el servidor y comprueba saldo, resumen mensual, seis transferencias propias, reserva, categorías, presupuesto superado, repetición y aislamiento.
- La compilación iOS y la ejecución SwiftData requieren macOS/Actions; no se han ejecutado desde este Windows. La comprobación visual final corresponde al IPA instalado en el dispositivo.
