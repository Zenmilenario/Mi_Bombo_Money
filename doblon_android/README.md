# Doblón (Flutter)

Desde el 10 de noviembre de 2026 esta es la app única de Doblón para Android y, más adelante, para iPhone (ver la nota «Paridad iPhone y Android»).

Primera versión para Android, en Flutter. Entra con la misma cuenta de Doblón que en el iPhone y muestra las mismas finanzas desde la nube (Supabase, función `finance_snapshot`).

## Qué hace

- **Entrar o crear cuenta** con correo y contraseña, con la curiosidad del día; sin datos antes de entrar.
- **Inicio:** patrimonio, disponible (descontando reservas), invertido, ingresos, gastos y ahorro del mes, presupuestos y últimos movimientos.
- **Movimientos:** todos, agrupados por día, con buscador. Conceptos del banco legibles y la etiqueta «Pendiente del banco» de los pagos con Apple Pay.
- **Cuentas:** saldo de cada cuenta y dinero reservado.
- **Presupuestos:** por mes, con el arrastre del mes anterior y lo pagado con reservas excluido.
- **Mis bancos (0.2.0, en Ajustes):**
  - conectar un banco en su propia web y volver a Doblón;
  - ver las conexiones y desconectarlas;
  - «Actualizar movimientos», que descarga 90 días y guarda en la nube lo nuevo.
  Usa las mismas claves que el iPhone, así que nada se duplica entre dispositivos. Guarda con el control de versiones de la nube: si otro dispositivo guardó a la vez, vuelve a leer y reintenta.
- **Movimientos completos (0.3.0):**
  - apuntar, editar y borrar (gasto, comisión, ingreso, interés y traspaso entre cuentas);
  - categorizar uno o varios (pulsación larga);
  - «Por revisar» (sin categoría, categoría incompatible, posible duplicado), con «Conservar: no es un duplicado»;
  - filtros por periodo, tipo, cuenta y categoría;
  - detalle de cada movimiento.
  Las reglas son las del iPhone: huella, posibles duplicados, categorías compatibles y límites de lo pagado con dinero reservado.
- **Sin conexión:** la app guarda en el móvil la última copia y los cambios pendientes. Se ven al momento y se suben a la nube cuando hay red, aplicados sobre la copia más reciente para no pisar lo que haya guardado otro dispositivo.
- **Aún no** (siguientes lotes): cuentas, presupuestos y objetivos editables, periódicos, reglas, Don Bigotes, revisión bancaria completa, CSV, copias de seguridad y bloqueo.

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
flutter create --platforms=android --org com.zenmilenario --project-name doblon .
flutter test
flutter run
```
