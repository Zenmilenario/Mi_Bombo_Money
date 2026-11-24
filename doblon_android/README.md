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
  - apuntar, editar y borrar; categorizar uno o varios. Al guardar (0.34.1), el formulario no admite toques mientras guarda («Guardando…»), guarda una sola vez y cierra solo su pantalla: lo que siga abierto encima, como el menú de categorías, se cierra antes como cancelado (`closeOwnScreen` en `lib/screens/navigation.dart`, usado por todas las pantallas que se cierran tras guardar o borrar). Si el guardado falla en el dispositivo, la edición se conserva para reintentar; si falla la nube, queda en la cola y se sube después;
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
- **Inversiones con comisión** (0.35.0, `lib/investments.dart`):
  - una orden comprada desde el efectivo de un bróker es un traspaso del efectivo a la cuenta de tipo Inversión por el capital, y su comisión un movimiento «comisión» del mismo efectivo, vinculado a la orden (`externalID` `investment-fee:<id de la orden>` e identificador derivado de la orden, sin campos nuevos ni migración); la salida del efectivo es la suma y la cartera solo recibe el capital;
  - qué es una aportación lo decide el tipo de la cuenta de destino (Inversión), no el nombre de la categoría; si la categoría parece de inversión y el destino no es una cartera, el formulario lo advierte;
  - en el formulario de un traspaso a una cartera, el importe es el total cargado y la comisión, opcional, se escribe aparte; se muestra y valida el desglose (lo invertido, la comisión y la salida total); orden y comisión se guardan, corrigen y borran juntas;
  - la comisión no cuenta como gasto del día a día ni en presupuestos; Inicio (resumen del mes) y Cuentas (Inversiones) muestran aportado, retirado y comisiones del mes por separado, y el valor registrado de las carteras; aportar no es rentabilidad;
  - el banco (Enable Banking) no envía comisiones ni desglose: llegan el importe total y el concepto. Un cargo posterior se propone para conciliar con la orden registrada a mano (el total de orden y comisión, o cada parte si llegan separadas), sin insertar otra salida;
  - una valoración posterior de la cartera sustituye al saldo anterior y no suma otra vez la aportación; la inclusión en el patrimonio se respeta;
  - «Invertido» (Inicio y Cuentas, 0.35.2) es el resumen de inversión: por defecto todas las carteras activas, también las que están fuera del patrimonio; desde «Ver carteras» (`lib/screens/invested_breakdown.dart`) se elige cuáles lo forman. Es una decisión distinta de la inclusión en el patrimonio, que se mantiene en cada cuenta y no cambia. La elección se guarda por persona en el dispositivo (`portfolios-<usuario>.json`, se conserva al reiniciar y sincronizar y se borra al cerrar sesión) y la usan igual Inicio, Cuentas y la línea de inversión del mes. El desglose muestra cada cartera con su valor, si cuenta en el patrimonio y de dónde sale: la valoración que indicaste o el saldo comunicado por el banco, con su fecha (y su antigüedad si pasa de una semana), más los movimientos posteriores; no es una cotización en tiempo real.
- **Disponible** (0.35.1): el mismo en Inicio y Cuentas, el dinero disponible de las cuentas corrientes, de ahorro, efectivo y otras del patrimonio, menos lo que el banco retiene en esas mismas cuentas (`spendableHolds`), una sola vez: el saldo del banco que se usa es el contable, que no incluye las retenciones. Las retenciones de tarjetas de crédito o de cuentas fuera del patrimonio no lo reducen.
- **Reservas:** dinero apartado en una cuenta (un pago futuro o un colchón): sale del disponible libre; los pagos que cubre y los ingresos destinados a ella quedan fuera del resultado cotidiano (Inicio, Movimientos, calendario, análisis y presupuestos), que muestran aparte el historial completo; los traslados solo cambian dónde está.
- **Presupuestos:**
  - detalle de cada presupuesto (0.33.0, `lib/screens/budget_detail.dart`): al pulsarlo, el mes consultado con límite (y lo arrastrado del mes anterior aparte), consumido y restante o exceso, y los movimientos que lo consumen agrupados por día, con fecha, concepto, cuenta e importe; un pago en parte cubierto por una reserva muestra el total y lo que consume. Usa la misma regla que el cálculo (`FinanceCalculator.countsInBudget` y `budgetContributions`): gastos y comisiones de la categoría con fecha en ese mes, de todas las cuentas, sin transferencias; la suma coincide siempre con el gasto del presupuesto. Cada movimiento abre su detalle y una edición actualiza detalle y resumen a la vez; «Editar presupuesto» en la barra superior;
  - límite solo de este mes o de todos los meses (guardar o arrastrar lo que sobra);
  - gasto sin presupuesto;
  - objetivos de ahorro, a mano o siguiendo el saldo de una cuenta.
- **Previsión** (rediseñada en 0.34.0, `lib/forecast.dart`, `lib/forecast_store.dart`, `lib/screens/forecast_screen.dart`; se abre con «Ver previsión» en el resumen del mes de Inicio y desde los avisos de Don Bigotes):
  - al entrar, la previsión base: Don Bigotes resume en una o dos frases lo que sale del cálculo y señala fechas (ingreso esperado, mínimo de disponible, posible descubierto, colchón) que se abren con su explicación;
  - «¿Cuánto tendré el…?»: dinero libre (saldo menos reservas) y saldo total en una fecha (fin de mes por defecto, o la que se toque en la gráfica o se elija), con lo que lo explica desde hoy: ingresos, pagos previstos y gasto variable estimado, y qué parte es segura (apuntado o periódico) y cuál estimada;
  - gráfica con el dinero libre real de los últimos 30 días (reconstruido desde el saldo de hoy con los movimientos reales), la línea prevista discontinua, «Hoy» marcado, los ingresos como puntos verdes y el saldo total como línea fina; 30, 60 o 90 días y por cuenta;
  - ingresos: las recurrencias confirmadas; lo que se repite cada mes en el historial (agrupado sin números, meses ni palabras de relleno del concepto) se propone para revisar («¿Cuento con él?») y nunca duplica un pago periódico; los ingresos sin día o importe fijos no se cuentan y se indican; si no hay ingresos previstos, se avisa de que la previsión no es fiable y se puede añadir un ingreso previsto solo para la previsión (no crea movimientos);
  - sin dobles cuentas: el movimiento real (también uno apuntado con fecha futura) sustituye a su previsión aunque llegue unos días antes o después; un presupuesto solo añade lo que deja libre; lo repetido no se estima si ya hay un pago periódico parecido;
  - «Lo que viene», datos de partida (saldo del banco, indicado a mano o calculado, con su fecha y límites) y supuestos editables (botón de ajustes);
  - simulaciones, aparte al final («Simular una decisión»): compra puntual (también con una reserva), gasto mensual, cambio o retraso de un ingreso y aportación a una reserva, comparadas con la base sin mezclarse;
  - todo se calcula con reglas fijas en el dispositivo, sin aprendizaje automático ni servicios externos; supuestos, ingresos previstos y simulaciones se guardan solo en el dispositivo (`forecast-<usuario>.json`), no crean movimientos ni enseñan a la IA, y se borran al cerrar sesión. Aún no se comparten entre dispositivos.
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

## Privacidad del repositorio

El repositorio es público para usar las comprobaciones y compilaciones de GitHub Actions. Por eso:

- el código y las pruebas usan solo datos ficticios; las pruebas no acceden a finanzas reales;
- los datos personales (exportaciones, copias de la app, hojas de cálculo, extractos, claves y configuración personal del servidor bancario) quedan fuera del repositorio y del seguimiento de Git (`.gitignore`);
- `Tools/privacy_check.py` revisa en cada PR y en `main` (workflow «Comprobar privacidad») que los archivos versionados no contengan claves privadas, tokens que no sean públicos, correos de proveedores personales, IBAN fuera de los datos de prueba ni archivos de datos personales. Solo indica la ubicación y el tipo, nunca el valor; `--self-test` comprueba que lo detecta;
- los secretos de CI se usan solo como secretos de GitHub, sin imprimirlos ni incluirlos en artefactos. Los instalables no llevan datos personales: solo la dirección pública del servidor bancario y la configuración pública de la nube.
