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

- **Entrada:** con la misma cuenta de Doblón; alta de cuenta nueva y bloqueo con huella o PIN del móvil.
- **Inicio:**
  - patrimonio con su gráfico de 12 meses y la variación del mes;
  - disponible e invertido, y lo disponible al día hasta fin de mes;
  - ingresos, gastos y ahorro del mes, presupuestos y últimos movimientos.
- **Movimientos:**
  - apuntar, editar y borrar; categorizar uno o varios;
  - «Por revisar»: duplicados, sin categoría o con categoría incompatible;
  - filtros, detalle y emparejado de traspasos entre tus cuentas;
  - categoría sugerida por tus reglas, con opción de recordar la regla;
  - pagos con dinero reservado.
- **Cuentas:**
  - crear, editar, archivar y recuperar cuentas;
  - actualizar el saldo a mano;
  - tarjetas, dinero reservado y últimos movimientos de cada cuenta.
- **Presupuestos:**
  - límite solo de este mes o de todos los meses (guardar o arrastrar lo que sobra);
  - gasto sin presupuesto;
  - objetivos de ahorro, a mano o siguiendo el saldo de una cuenta.
- **Ajustes:**
  - Mis bancos: conectar, actualizar, revisar coincidencias con lo apuntado y desconectar;
  - categorías, reglas de categorización, cargos y aportaciones periódicas (se apuntan solos al abrir), y bancos y entidades;
  - apariencia, ocultar importes, Don Bigotes y bloqueo;
  - importar CSV, exportar CSV y copia de seguridad (guardar y restaurar).
- **Don Bigotes:** en la barra superior. Dormido si no hay nada y con un número si hay avisos: revisión, posibles traspasos, cargos próximos, cuentas sin actualizar y pagos que no llegan del banco. Señala, nunca aconseja.
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
