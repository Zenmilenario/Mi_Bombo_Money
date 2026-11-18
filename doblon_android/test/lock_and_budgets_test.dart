// Fictitious data only. The lock asks once on opening and once after the background, never again on its own after a
// failed Face ID (it looped); and Presupuestos shows what the iPhone app showed.
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/main.dart';
import 'package:doblon/models.dart';
import 'package:doblon/preferences.dart';
import 'package:doblon/screens/budgets.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

double seconds(DateTime d) => d.millisecondsSinceEpoch / 1000 - 978307200;

Widget app(Widget child) => MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: child,
    );

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  testWidgets('a failed Face ID is not asked again on its own; coming back from the background is', (tester) async {
    var asked = 0;
    var answer = false;
    final preferences = AppPreferences()..lockEnabled = true;
    await tester.pumpWidget(app(LockGate(
        preferences: preferences,
        authenticator: (_) async {
          asked++;
          return answer;
        },
        child: const Text('Dentro'))));
    await tester.pumpAndSettle();
    expect(asked, 1, reason: 'Asked on opening');
    expect(find.text('Tu dinero, con calma.'), findsOneWidget);

    // The Face ID sheet makes the app inactive and active again: that must not ask again.
    for (var i = 0; i < 3; i++) {
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
      tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
      await tester.pumpAndSettle();
    }
    expect(asked, 1, reason: 'No loop');

    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.paused);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.hidden);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.inactive);
    tester.binding.handleAppLifecycleStateChanged(AppLifecycleState.resumed);
    await tester.pumpAndSettle();
    expect(asked, 2, reason: 'Asked again after the background');

    answer = true;
    await tester.ensureVisible(find.text('Volver a intentar con Face ID o huella'));
    await tester.tap(find.text('Volver a intentar con Face ID o huella'));
    await tester.pumpAndSettle();
    expect(find.text('Dentro'), findsOneWidget);
  });

  test('the pace sentence of the budgets', () {
    final now = DateTime(2026, 11, 10);
    expect(budgetPacingText(0, 0, now, now), 'Define límites para empezar a controlar el mes');
    expect(budgetPacingText(30000, 5000, now, now), contains('por debajo del ritmo previsto'));
    expect(budgetPacingText(30000, 20000, now, now), contains('por encima del ritmo previsto'));
    expect(budgetPacingText(30000, 40000, DateTime(2026, 10), now), 'Cerraste el mes por encima del presupuesto');
    expect(budgetPacingText(30000, 0, DateTime(2026, 12), now), 'Presupuesto preparado para un mes futuro');
  });

  testWidgets('Presupuestos shows the overview, the comparison, the states and the categories to add', (tester) async {
    final now = DateTime.now();
    final month = DateTime(now.year, now.month);
    final data = Finances.fromDocument({
      'accounts': [
        {'id': 'a1', 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': 0},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Comida', 'kindRaw': 'expense', 'systemImage': 'basket.fill'},
        {'id': 'c2', 'name': 'Ocio', 'kindRaw': 'expense', 'systemImage': 'gamecontroller.fill'},
        {'id': 'c3', 'name': 'Viajes', 'kindRaw': 'expense', 'systemImage': 'airplane'},
      ],
      'budgets': [
        {'id': 'b1', 'categoryID': 'c1', 'monthStart': seconds(month), 'limitMinor': 10000},
        {'id': 'b2', 'categoryID': 'c2', 'monthStart': seconds(month), 'limitMinor': 20000},
      ],
      'transactions': [
        {'id': 't1', 'date': seconds(DateTime(now.year, now.month, 1, 12)), 'typeRaw': 'expense', 'amountMinor': 12000,
          'descriptionText': 'Compra ficticia', 'sourceAccountID': 'a1', 'categoryID': 'c1'},
        {'id': 't2', 'date': seconds(DateTime(now.year, now.month, 1, 13)), 'typeRaw': 'expense', 'amountMinor': 1000,
          'descriptionText': 'Cine ficticio', 'sourceAccountID': 'a1', 'categoryID': 'c2'},
      ],
    });
    tester.view.physicalSize = const Size(390, 3000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(Scaffold(
        body: BudgetsScreen(calc: FinanceCalculator(data), month: month, onMonth: (_) {}, repository: FinanceRepository()..finances = data))));
    await tester.pumpAndSettle();
    for (final text in ['Vista general', 'Superado', 'Gasto frente a límite', 'Necesitan atención', 'Dentro del presupuesto', 'Añadir al presupuesto']) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    expect(find.byIcon(Icons.flight), findsOneWidget, reason: 'Viajes, without a limit, can be added with its icon');
  });
}
