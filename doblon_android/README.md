# Doblón (Flutter)

## Cifrado de invitados — preparado el 11/11/2026

El lote iOS 0.7.16 (57) / Flutter 0.13.0 (9) incorpora cifrado de aplicación para las finanzas y el aprendizaje cloud de invitados, con código de recuperación guardado por la persona y excepción de desarrollo administrada en el servidor. La IA sigue entrenando y prediciendo en el dispositivo. No se comparten sus correcciones en un modelo colectivo. El Worker bancario sigue procesando los datos de conexión; este cifrado protege la copia activa en Supabase, no elimina el acceso técnico al tramo bancario.

**Estado: local, no desplegado.** Requiere CI macOS, migración coordinada `20261111000300_client_encryption.sql`, registro privado de la identidad de desarrollo y prueba física. No instalar estos clientes contra un servidor sin la nueva política. Véase [Privacidad, recuperación y límites](../CloudBackend/privacy-encryption.md).

Desde el 10 de noviembre de 2026 esta es la app única de Doblón para Android y, más adelante, para iPhone (ver la nota «Paridad iPhone y Android»).

Primera versión para Android, en Flutter. Entra con la misma cuenta de Doblón que en el iPhone y muestra las mismas finanzas desde la nube (Supabase, función `finance_snapshot`).

## Fiabilidad y paridad (0.12.0, compilación 8)

Lote preparado el 11 de noviembre de 2026 en `claude/flutter-lote-1`. Corrige Flutter, actualmente usado en Android. No modifica el cliente Swift instalado en iOS, el Worker ni el esquema SQL.

- **Aislamiento bancario:** cada cuenta se descarga e incorpora por separado. El fallo de una descarga o de su guardado no descarta las demás. Las esperas y los errores se muestran por banco. Las consultas tienen tiempo máximo de respuesta.
- **Actualización automática:** al abrir, volver a primer plano y cada 30 segundos mientras está abierta se comprueba qué trabajo corresponde. Eso no implica una consulta al banco cada 30 segundos: las descargas correctas esperan seis horas; los fallos, diez minutos; se respetan `Retry-After` y un mínimo de un minuto entre intentos, incluso manuales. Los plazos se guardan por perfil y sobreviven al cierre.
- **Selección de cuentas:** solo se descargan las asociadas explícitamente. Mis bancos permite elegir una cuenta existente o crear otra. Las secundarias quedan fuera hasta seleccionarlas. Una cuenta archivada no se recrea ni se duplica; se recupera desde Cuentas.
- **Revisión recuperable:** la descarga pendiente de incorporar se guarda en el almacenamiento privado del perfil. Si falla la nube se reintenta sin pedirla otra vez al banco. Las coincidencias guardadas siguen disponibles tras reabrir. Una revisión pendiente ya guardada no reescribe la nube en cada comprobación. Se conserva hasta resolverla o cerrar sesión; está fuera de las copias financieras y del aprendizaje.
- **Reservas entre cuentas:** el formulario admite trasladar una reserva junto con una transferencia. Su pago posterior consume la reserva de destino y queda fuera del presupuesto. Se valida toda la secuencia para impedir que editar un traslado deje sin respaldo un pago posterior.
- **Aportaciones fraccionadas:** Movimientos ofrece «Revisar aportaciones» cuando varios cargos pueden cubrir un plan periódico de inversión. No fija importes ni nombres de personas: usa cuentas, frecuencia, período y suma pendiente. La persona confirma; una combinación de importes por sí sola no demuestra que sean inversiones. La operación sustituye los apuntes previstos por los cargos reales de forma conjunta, conserva sus claves bancarias y vuelve a validar la copia cloud antes de guardar. Los casos ambiguos requieren selección; un abono de destino coincidente exige revisar primero el traspaso. La IA no transforma por su cuenta los candidatos de esa conciliación.
- **Recuperación cloud:** reintenta los cambios guardados sin internet y recupera cambios de otro dispositivo en primer plano. Las escrituras locales y financieras se coordinan para evitar archivos temporales concurrentes y sobrescrituras de una copia antigua. Se comprueba el perfil antes de incorporar resultados asíncronos.

Regresiones: `test/bank_sync_test.dart`, `test/banking_safety_test.dart`, `test/contributions_test.dart`, `test/cloud_retry_test.dart` y `test/screens_test.dart`. Los casos ficticios de combinaciones están en `Tests/Fixtures/contribution_recognition_cases.json`. Todos se ejecutan en el workflow Android mediante `flutter test`. Queda validar el commit en GitHub y los recorridos físicos en Android; compilar Flutter para iOS y reemplazar Swift sigue pendiente.

Validación local del lote: 76 pruebas Flutter correctas, `flutter analyze` sin incidencias, tres controles de activación CI correctos y APK Release 0.12.0 (8) compilado. No equivale a comprobar conexiones bancarias reales ni la instalación en un dispositivo.

## Qué hace

- **Entrada:** con la misma cuenta de Doblón; alta de cuenta nueva y bloqueo con Face ID, huella o PIN del móvil, o con el correo y la contraseña de la cuenta; el bloqueo cubre todas las pantallas y, al salir de la app, una cubierta oculta los datos también en la vista de apps recientes.
- **Inicio** (0.25.0):
  - Disponible en su tarjeta, con lo reservado, retenido e invertido;
  - el mes: gastos, ingresos y ahorro, lo presupuestado con su ritmo y margen, y el calendario de gasto diario (cada día lista sus movimientos);
  - patrimonio con su variación del mes y la línea desde el primer mes con historial (valor y fecha al tocarla);
  - presupuestos y objetivo destacado.
- **Abajo:** Don Bigotes (avatar con contador de avisos) y «+ Añadir» (una pulsación), flotantes y separados sobre las pestañas; las etiquetas de las pestañas se ocultan, sin partirse, cuando no caben al tamaño de texto elegido; la cabecera se recoge al bajar.
- **Plataformas:** el mismo código en iOS y Android; solo «Pagos con Apple Pay» es exclusivo de iOS.
- **Movimientos:**
  - apuntar, editar y borrar; categorizar uno o varios;
  - alta con el importe enfocado, la cuenta sin adivinar y lo opcional en «Más opciones»;
  - «Pendiente»: posibles duplicados o categoría incompatible (la categoría es opcional y no cuenta como tarea);
  - herramientas de revisión y entrenamiento de la IA solo para el administrador, en Ajustes › Avanzado;
  - filtros y detalle;
  - «Revisar y unir»: traspasos entre tus cuentas (también si un lado ya era traspaso) y duplicados, comparados, con vista previa del efecto en los saldos y deshacer; con la cuenta de administrador, «Unir o conciliar» dos movimientos elegidos a mano;
  - categoría sugerida por tus reglas, con opción de recordar la regla;
  - pagos con dinero reservado.
- **Cuentas:**
  - crear, editar, archivar y recuperar cuentas;
  - actualizar o regularizar el saldo a mano, con concepto y diferencia calculada, y deshacerlo desde «Ajustes de saldo»;
  - tarjetas, dinero reservado y últimos movimientos de cada cuenta.
- **Reservas:** dinero apartado en una cuenta (un pago futuro o un colchón): sale del disponible libre; los pagos que cubre y los ingresos destinados a ella quedan fuera del resultado cotidiano (Inicio, Movimientos, calendario, análisis y presupuestos), que muestran aparte el historial completo; los traslados solo cambian dónde está.
- **Presupuestos:**
  - límite solo de este mes o de todos los meses (guardar o arrastrar lo que sobra);
  - gasto sin presupuesto;
  - objetivos de ahorro, a mano o siguiendo el saldo de una cuenta.
- **Previsión y simulaciones** (0.32.0, `lib/forecast.dart`, `lib/forecast_store.dart`, `lib/screens/forecast_screen.dart`; se abre desde la tarjeta Disponible de Inicio y desde los avisos de Don Bigotes):
  - saldo y disponible libre (saldo menos reservas) día a día a 30, 60 o 90 días, en conjunto o por cuenta, con gráfica, calendario y detalle de cada día;
  - parte de hoy y distingue el saldo recibido del banco, el indicado a mano y el calculado con movimientos, con su fecha y los límites de la previsión (poco historial, saldos antiguos, otra moneda);
  - cuenta lo ya apuntado con fecha futura, los pagos periódicos (confirmados), lo que se repite cada mes en el historial y el gasto variable (estimados) y los cargos retenidos por el banco;
  - sin dobles cuentas: el movimiento real sustituye a su previsión aunque llegue unos días antes o después (un pago retrasado hasta 7 días se sigue esperando, para hoy); lo repetido en el historial no se estima si ya hay un pago periódico parecido; un presupuesto solo añade lo que deja libre después de los pagos previstos de su categoría;
  - supuestos editables sin tocar movimientos ni pagos: colchón, gasto variable automático o propio, aprender del historial, y dejar fuera o cambiar el importe de cada pago previsto;
  - simulaciones guardadas («qué pasaría si»): compra puntual (también pagada con una reserva), gasto mensual nuevo, cambio o retraso de un ingreso y aportación a una reserva; se comparan con la previsión base (mínimo y fecha, final del periodo, colchón, reservas, cuentas sin saldo y objetivos afectados);
  - los supuestos y las simulaciones se guardan solo en el dispositivo (`forecast-<usuario>.json`), fuera de la nube y de la contabilidad: no crean movimientos, no cambian saldos ni enseñan a la IA, y se borran al cerrar sesión. Aún no se comparten entre dispositivos.
- **Ajustes:**
  - Mis bancos: conectar, actualizar, revisar coincidencias con lo apuntado y desconectar;
  - categorías, reglas de categorización, cargos y aportaciones periódicas (se apuntan solos al abrir), y bancos y entidades;
  - apariencia, ocultar importes, Don Bigotes y bloqueo;
  - importar CSV, exportar CSV y copia de seguridad (guardar y restaurar).
- **Don Bigotes:** en la barra superior. Dormido si no hay nada y con un número si hay avisos: revisión, posibles traspasos, cargos próximos, cuentas sin actualizar, pagos que no llegan del banco y, desde la 0.32.0, una cuenta que podría quedarse sin saldo para un cargo previsto o el disponible por debajo del colchón en los próximos 30 días (abre la previsión en ese día y cuenta). Señala, nunca aconseja ni mueve dinero.
- **Sin conexión:** copia local y cola de cambios; se suben sobre la copia más reciente de la nube.
- **Inteligencia artificial** (`lib/learning.dart`, los mismos tres modelos y umbrales que el iPhone):
  - propone la categoría a partir del concepto, en el formulario, en «Por revisar» y al importar un CSV;
  - cuando la IA no tiene propuesta, reconoce cerca de 1.000 cadenas presentes en España (supermercados, restaurantes, gasolineras, ropa, hoteles…) con el catálogo de marcas de OpenStreetMap (`lib/brand_catalogue.dart`, generado con `tool/brand_catalogue.py`). Nunca cambia una propuesta de la IA ni actúa en Bizum, transferencias, devoluciones o nóminas; el iPhone hace lo mismo con los casos comunes de `Tests/Fixtures/brand_lookup_cases.json`;
  - reconoce aportaciones a inversión, Round up y Saveback en los movimientos del banco («Reconocimiento de inversión» en el detalle), con las condiciones de la tarjeta;
  - repite una corrección que has hecho varias veces (tipo, categoría y cuenta de destino) solo después de comprobar que acertó en meses posteriores; se puede desactivar y deshacer, y deshacerla también enseña;
  - lo aprendido se comparte entre el iPhone y el Android a través de la nube privada de la persona (tabla `finance_learning`, contrato en `CloudBackend/learning-contract.md`). En el móvil se guarda como `learning-<usuario>.json` y se combina con la nube al abrir la app y unos segundos después de cada cambio. Ajustes → Inteligencia artificial muestra cuánto ha aprendido.
- **Lo que comunica el banco** (`lib/bank_activity.dart`):
  - saldo contable y disponible, retenciones y pendientes en el detalle de la cuenta, con el saldo tras retenciones;
  - pendientes del banco en Movimientos y aviso de Don Bigotes de «cargos en camino»;
  - en Mis bancos, los últimos apuntes recibidos de cada cuenta y los que el banco envió con otro estado (cancelados, informativos…);
  - se guarda solo en el dispositivo durante 7 días y se borra al cerrar sesión.
- **Aún no** respecto al iPhone: el equivalente a Apple Pay, que en Android sería leer avisos de pago con permiso.

## Reglas compartidas con el iPhone

`lib/finance.dart` repite las reglas de `FinanceCalculator.swift` y `ReservedLedger.swift`. `test/finance_test.dart` comprueba los mismos casos ficticios que `Tests/FinancialLogicCheck.swift`. Si cambia una regla en Swift, hay que cambiarla aquí también.

## Compilar

El workflow «Comprobar app Android»:
1. comprueba el manifiesto (nombre «Doblón», internet, vuelta del banco) y el icono;
2. analiza el código;
3. pasa las pruebas;
4. compila un APK y lo publica como artefacto **Doblon-Android-APK**.

El APK va firmado con la clave de depuración de Flutter: se instala directamente en el móvil, pero no sirve para Google Play.

Con Flutter instalado en local: (las carpetas `android/` e `ios/` ya están en el repositorio)

```bash
flutter pub get
flutter analyze
flutter test
flutter build apk --release
flutter run
```

## Datos de terceros

- **Name Suggestion Index** de OpenStreetMap (marcas y su tipo de comercio): © name-suggestion-index contributors, licencia BSD 3-Clause. Texto en `third_party/name-suggestion-index/LICENSE.md`.
