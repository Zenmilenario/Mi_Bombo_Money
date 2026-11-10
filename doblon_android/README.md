# Doblón para Android

Primera versión para Android, en Flutter. Entra con la misma cuenta de Doblón que en el iPhone y muestra las mismas finanzas desde la nube (Supabase, función `finance_snapshot`).

## Qué hace (0.1.0)

- **Entrar o crear cuenta** con correo y contraseña, con la curiosidad del día; sin datos antes de entrar.
- **Inicio:** patrimonio, disponible (descontando reservas), invertido, ingresos, gastos y ahorro del mes, presupuestos y últimos movimientos.
- **Movimientos:** todos, agrupados por día, con buscador. Conceptos del banco legibles y la etiqueta «Pendiente del banco» de los pagos con Apple Pay.
- **Cuentas:** saldo de cada cuenta y dinero reservado.
- **Presupuestos:** por mes, con el arrastre del mes anterior y lo pagado con reservas excluido.
- **Solo lectura:** apuntar, categorizar y conectar bancos se hace de momento desde el iPhone.

## Reglas compartidas con el iPhone

`lib/finance.dart` repite las reglas de `FinanceCalculator.swift` y `ReservedLedger.swift`. `test/finance_test.dart` comprueba los mismos casos ficticios que `Tests/FinancialLogicCheck.swift`. Si cambia una regla en Swift, hay que cambiarla aquí también.

## Compilar

En este repositorio la parte nativa de Android (`android/`) la genera el workflow «Comprobar app Android» con `flutter create`. Ese workflow:
1. pone el nombre «Doblón», el permiso de internet y el icono (ya redimensionado en `assets/launcher`);
2. analiza el código;
3. pasa las pruebas;
4. compila un APK y lo publica como artefacto **Doblon-Android-APK**.

El APK va firmado con la clave de depuración de Flutter: se instala directamente en el móvil, pero no sirve para Google Play.

Con Flutter instalado en local:

```bash
flutter create --platforms=android --org com.zenmilenario --project-name doblon .
flutter test
flutter run
```
