// Fictitious data only. Inicio as on the iPhone app: the month day by day, the pace against the budget and its cards,
// in two columns on a wide screen (iPad).
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/home.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

double seconds(DateTime d) => d.millisecondsSinceEpoch / 1000 - 978307200;

Finances sample(DateTime month) => Finances.fromDocument({
      'accounts': [
        {'id': 'a1', 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'openingBalanceMinor': 200000},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Comida', 'kindRaw': 'expense'},
      ],
      'budgets': [
        {'id': 'b1', 'categoryID': 'c1', 'monthStart': seconds(DateTime(month.year, month.month)), 'limitMinor': 30000},
      ],
      'goals': [
        {'id': 'g1', 'name': 'Viaje ficticio', 'targetAmountMinor': 100000, 'currentAmountMinor': 25000},
      ],
      'transactions': [
        {'id': 't1', 'date': seconds(DateTime(month.year, month.month, 2, 12)), 'typeRaw': 'expense', 'amountMinor': 1000,
          'descriptionText': 'Compra ficticia', 'sourceAccountID': 'a1', 'categoryID': 'c1'},
        {'id': 't2', 'date': seconds(DateTime(month.year, month.month, 2, 18)), 'typeRaw': 'expense', 'amountMinor': 500,
          'descriptionText': 'Otra compra ficticia', 'sourceAccountID': 'a1', 'categoryID': 'c1'},
        {'id': 't3', 'date': seconds(DateTime(month.year, month.month, 1, 9)), 'typeRaw': 'income', 'amountMinor': 90000,
          'descriptionText': 'Nómina ficticia', 'sourceAccountID': 'a1'},
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

  test('the spending of each day of the month, only expenses', () {
    final now = DateTime.now();
    final calc = FinanceCalculator(sample(now));
    expect(calc.dailySpending(DateTime(now.year, now.month)), {2: 1500});
    expect(calc.dailySpending(DateTime(now.year, now.month - 1)), isEmpty);
  });

  test('the pace of the month against its budget', () {
    final pace = MonthPace(limitMinor: 30000, spentMinor: 12000, day: 10, daysInMonth: 30);
    expect(pace.expectedMinor, 10000, reason: 'An even pace would have spent a third by day 10');
    expect(pace.differenceMinor, -2000, reason: 'Above the pace');
    expect(pace.projectionMinor, 36000);
    expect(pace.daysLeft, 21, reason: 'Today included');
    expect(pace.dailyMarginMinor, 857);
    expect(MonthPace(limitMinor: 1000, spentMinor: 3000, day: 5, daysInMonth: 30).dailyMarginMinor, 0, reason: 'Never negative');
    expect(MonthPace.of(const [], DateTime(2026, 11, 16)), isNull, reason: 'Without budget there is no pace');
  });

  testWidgets('Inicio shows the cards of the iPhone app, in two columns on an iPad', (tester) async {
    final now = DateTime.now();
    final calc = FinanceCalculator(sample(now));
    for (final size in [const Size(390, 3000), const Size(1024, 3000)]) {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      await tester.pumpWidget(app(HomeScreen(calc: calc, month: DateTime(now.year, now.month), onMonth: (_) {})));
      await tester.pumpAndSettle();
      expect(find.textContaining('Tu margen de hoy'), findsOneWidget);
      expect(find.textContaining('en las categorías con presupuesto'), findsOneWidget, reason: 'How the month goes, in words');
      for (final text in ['Disponible para usar', 'Ver el mes día a día', 'Ver reparto y patrimonio', 'Nada pendiente',
        'Presupuestos del mes', 'Objetivo destacado', 'Viaje ficticio']) {
        expect(find.text(text), findsOneWidget, reason: '$text at ${size.width}');
      }
      final calendar = tester.getTopLeft(find.text('Ver el mes día a día'));
      final pace = tester.getTopLeft(find.text('Presupuestos del mes'));
      if (size.width >= 720) {
        expect((calendar.dx - pace.dx).abs(), greaterThan(200), reason: 'Two columns on a wide screen');
      } else {
        expect(calendar.dx, pace.dx, reason: 'One column on a phone');
      }
    }
    addTearDown(tester.view.reset);
  });
}
