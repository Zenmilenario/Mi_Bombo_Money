# Doblón (Flutter)

Desde el 10 de noviembre de 2026 esta es la app única de Doblón para Android y, más adelante, para iPhone (ver la nota «Paridad iPhone y Android»).

Primera versión para Android, en Flutter. Entra con la misma cuenta de Doblón que en el iPhone y muestra las mismas finanzas desde la nube (Supabase, función `finance_snapshot`).

## Qué hace (0.10.0)

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
  - reconoce aportaciones a inversión, Round up y Saveback en los movimientos del banco («Reconocimiento de inversión» en el detalle), con las condiciones de la tarjeta;
  - repite una corrección que has hecho varias veces (tipo, categoría y cuenta de destino) solo después de comprobar que acertó en meses posteriores; se puede desactivar y deshacer, y deshacerla también enseña;
  - lo aprendido se guarda en el dispositivo y el perfil (`learning-<usuario>.json`), como en el iPhone: no va a la nube. Ajustes → Inteligencia artificial muestra cuánto ha aprendido.
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
flutter create --platforms=android --org com.zenmilenario --project-name doblon .
flutter test
flutter run
```
