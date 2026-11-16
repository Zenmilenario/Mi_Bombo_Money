// Fictitious data only. Lote A of recovering the iPhone app's screens: spending by category, the notices of Inicio,
// the quick filters and summary of Movimientos, the groups of Cuentas and the icon of a category.
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/presentation.dart';
import 'package:doblon/screens/accounts.dart';
import 'package:doblon/screens/home.dart';
import 'package:doblon/screens/manage.dart';
import 'package:doblon/screens/transactions.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

double seconds(DateTime d) => d.millisecondsSinceEpoch / 1000 - 978307200;

Finances sample(DateTime now) => Finances.fromDocument({
      'institutions': [
        {'id': 'i1', 'name': 'Banco Ficticio', 'colorHex': '#1E40AF'},
      ],
      'accounts': [
        {'id': 'a1', 'name': 'Nómina ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'institutionID': 'i1', 'lastUpdatedAt': seconds(now)},
        {'id': 'a2', 'name': 'Hucha ficticia', 'typeRaw': 'savings', 'openingDate': 0, 'lastUpdatedAt': seconds(now.subtract(const Duration(days: 60)))},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Comida', 'kindRaw': 'expense', 'systemImage': 'basket.fill'},
        {'id': 'c2', 'name': 'Ocio', 'kindRaw': 'expense', 'systemImage': 'gamecontroller.fill'},
      ],
      'budgets': [
        {'id': 'b1', 'categoryID': 'c2', 'monthStart': seconds(DateTime(now.year, now.month)), 'limitMinor': 1000},
      ],
      'transactions': [
        {'id': 't1', 'date': seconds(DateTime(now.year, now.month, 1, 12)), 'typeRaw': 'expense', 'amountMinor': 3000,
          'descriptionText': 'Compra ficticia', 'sourceAccountID': 'a1', 'categoryID': 'c1'},
        {'id': 't2', 'date': seconds(DateTime(now.year, now.month, 1, 13)), 'typeRaw': 'expense', 'amountMinor': 2000,
          'descriptionText': 'Cine ficticio', 'sourceAccountID': 'a1', 'categoryID': 'c2', 'duplicateStateRaw': 'possible'},
        {'id': 't3', 'date': seconds(DateTime(now.year, now.month, 1, 14)), 'typeRaw': 'income', 'amountMinor': 90000,
          'descriptionText': 'Nómina', 'sourceAccountID': 'a1'},
      ],
    });

Widget app(Widget child) => MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(body: child),
    );

void main() {
  setUpAll(() => initializeDateFormatting('es'));
  final now = DateTime.now();

  test('spending by category, from most to least, without the uncategorized', () {
    final calc = FinanceCalculator(sample(now));
    expect([for (final (c, amount) in calc.spendingByCategory(DateTime(now.year, now.month))) '${c.name} $amount'], ['Comida 3000', 'Ocio 2000']);
  });

  test('the notices of Inicio: budget over its limit, duplicate and account not updated', () {
    final alerts = homeAlerts(FinanceCalculator(sample(now)), DateTime(now.year, now.month), now, Pulso.light);
    expect(alerts.map((a) => a.title), ['Has superado 1 presupuesto', 'Hay 1 posible movimiento duplicado', '1 cuenta lleva más de 30 días sin actualizarse']);
    expect(alerts.map((a) => a.tab), [3, 1, 2]);
  });

  testWidgets('Movimientos: quick filters and the summary of what is shown', (tester) async {
    final data = sample(now);
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(TransactionsScreen(calc: FinanceCalculator(data), repository: FinanceRepository()..finances = data)));
    await tester.pumpAndSettle();
    expect(find.text('3 movimientos'), findsOneWidget);
    await tester.tap(find.widgetWithText(ChoiceChip, 'Ingresos'));
    await tester.pumpAndSettle();
    expect(find.text('1 movimiento'), findsOneWidget);
    expect(find.text('Cine ficticio'), findsNothing);
  });

  testWidgets('Cuentas: the four figures, the accounts by kind and the ones not updated', (tester) async {
    final data = sample(now);
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(AccountsScreen(calc: FinanceCalculator(data), repository: FinanceRepository()..finances = data)));
    await tester.pumpAndSettle();
    for (final text in ['Patrimonio', 'Reservado', 'Invertido', 'Día a día', 'Ahorro', 'Banco Ficticio', 'Sin actualizar']) {
      expect(find.text(text), findsWidgets, reason: text);
    }
    await tester.tap(find.text('Revisar saldos sin actualizar (1)'));
    await tester.pumpAndSettle();
    expect(find.text('Día a día'), findsNothing, reason: 'Only the account not updated');
  });

  testWidgets('a category can be given an icon, with a preview', (tester) async {
    final data = sample(now);
    final repository = FinanceRepository()..finances = data;
    tester.view.physicalSize = const Size(430, 2400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(theme: doblonTheme(Brightness.light), home: CategoryFormScreen(repository: repository, editing: data.category('c1'))));
    await tester.pumpAndSettle();
    expect(find.text('Icono'), findsOneWidget);
    expect(find.byIcon(symbolIcon('basket.fill')), findsNWidgets(2), reason: 'In the grid and in the preview');
    await tester.tap(find.byIcon(symbolIcon('airplane')));
    await tester.pumpAndSettle();
    expect(find.byIcon(Icons.flight), findsNWidgets(2));
  });
}
