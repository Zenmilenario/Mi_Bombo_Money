// The screens build and react with fictitious data (no cloud involved).
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/transaction_form.dart';
import 'package:doblon/screens/transactions.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

FinanceRepository repositoryWith(Finances data) => FinanceRepository()..finances = data;

Finances sample() => Finances.fromDocument({
      'accounts': [
        {'id': 'a1', 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'openingBalanceMinor': 100000},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Comida', 'kindRaw': 'expense'},
      ],
      'transactions': [
        {'id': 't1', 'date': 815184000, 'typeRaw': 'expense', 'amountMinor': 450, 'descriptionText': 'Gasolinera ficticia', 'sourceAccountID': 'a1'},
        {
          'id': 't2',
          'date': 815184000,
          'typeRaw': 'expense',
          'amountMinor': 990,
          'descriptionText': 'Cena ficticia',
          'sourceAccountID': 'a1',
          'categoryID': 'c1'
        },
      ],
    });

Widget app(Widget child) => MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: child,
    );

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  testWidgets('the form explains what is missing before saving', (tester) async {
    await tester.pumpWidget(app(TransactionFormScreen(repository: repositoryWith(sample()))));
    await tester.pumpAndSettle();
    expect(find.text('Nuevo movimiento'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Guardar movimiento'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    expect(find.text('Escribe un importe mayor que cero.'), findsOneWidget);
  });

  testWidgets('the list shows what needs review and filters it', (tester) async {
    final data = sample();
    await tester.pumpWidget(app(Scaffold(body: TransactionsScreen(calc: FinanceCalculator(data), repository: repositoryWith(data)))));
    await tester.pumpAndSettle();
    expect(find.text('Por revisar · 1'), findsOneWidget, reason: 'The movement without category');
    expect(find.text('Cena ficticia'), findsOneWidget);
    await tester.tap(find.text('Por revisar · 1'));
    await tester.pumpAndSettle();
    expect(find.text('Cena ficticia'), findsNothing);
    expect(find.text('Gasolinera ficticia'), findsOneWidget);
  });

  testWidgets('a long press starts selecting to categorize several', (tester) async {
    final data = sample();
    await tester.pumpWidget(app(Scaffold(body: TransactionsScreen(calc: FinanceCalculator(data), repository: repositoryWith(data)))));
    await tester.pumpAndSettle();
    await tester.longPress(find.text('Gasolinera ficticia'));
    await tester.pumpAndSettle();
    expect(find.text('1 seleccionados'), findsOneWidget);
    expect(find.text('Categorizar 1'), findsOneWidget);
  });
}
