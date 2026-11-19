// Fictitious data only. Adding a movement with less work (18 November 2026): the amount ready to type, the account
// never guessed, the optional details folded away, and a clear message when something is missing.
import 'package:doblon/data.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/transaction_form.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

Widget app(Widget child) => MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: child,
    );

Finances data({bool typedBefore = false}) => Finances.fromDocument({
      'accounts': [
        {'id': 'a1', 'name': 'Primera ficticia', 'typeRaw': 'checking', 'openingDate': 0},
        {'id': 'a2', 'name': 'Segunda ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'sortOrder': 1},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Comida', 'kindRaw': 'expense'},
      ],
      'transactions': [
        if (typedBefore)
          {'id': 't1', 'date': 815184000, 'typeRaw': 'expense', 'amountMinor': 450, 'descriptionText': 'Pan ficticio', 'sourceAccountID': 'a2'},
      ],
    });

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  testWidgets('the amount is ready to type and the optional details are folded', (tester) async {
    await tester.pumpWidget(app(TransactionFormScreen(repository: FinanceRepository()..finances = data())));
    await tester.pumpAndSettle();
    final focused = FocusManager.instance.primaryFocus?.context?.findAncestorWidgetOfExactType<TextField>();
    expect(focused?.decoration?.labelText, 'Importe (€)');
    expect(find.text('Categoría (opcional)'), findsOneWidget);
    expect(find.text('Notas (opcional)'), findsNothing, reason: 'Folded under «Más opciones»');
    await tester.ensureVisible(find.text('Más opciones'));
    await tester.tap(find.text('Más opciones'));
    await tester.pumpAndSettle();
    expect(find.text('Notas (opcional)'), findsOneWidget);
  });

  testWidgets('with several accounts and nothing typed before, the account is asked, not guessed', (tester) async {
    await tester.pumpWidget(app(TransactionFormScreen(repository: FinanceRepository()..finances = data())));
    await tester.pumpAndSettle();
    expect(find.text('Primera ficticia'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Importe (€)'), '12,50');
    await tester.enterText(find.widgetWithText(TextField, 'Concepto'), 'Compra ficticia');
    await tester.scrollUntilVisible(find.text('Guardar movimiento'), 200, scrollable: find.byType(Scrollable).first);
    await tester.tap(find.text('Guardar movimiento'));
    await tester.pumpAndSettle();
    expect(find.text('Elige la cuenta.'), findsOneWidget);
    expect(find.text('12,50'), findsOneWidget, reason: 'What was typed stays');
    expect(find.text('Compra ficticia'), findsOneWidget);
  });

  testWidgets('the account of the last movement typed by hand is offered, and can be changed', (tester) async {
    await tester.pumpWidget(app(TransactionFormScreen(repository: FinanceRepository()..finances = data(typedBefore: true))));
    await tester.pumpAndSettle();
    expect(find.text('Segunda ficticia'), findsOneWidget);
  });
}
