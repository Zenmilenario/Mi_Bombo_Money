// Fictitious data only. What a rebuild of «Movimientos» costs with years of history: every notice of
// FinanceRepository rebuilds the shell and the open tab (Obsidian, «Escalabilidad y experiencia sencilla»).
// The times are from the test machine in debug mode: they compare, they are not a phone's absolute times.
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/accounts.dart';
import 'package:doblon/screens/budgets.dart';
import 'package:doblon/screens/home.dart';
import 'package:doblon/screens/transactions.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// Two bank accounts; one movement in ten without category (what «Pendiente» and the own-transfer search look at).
Finances history(int count) {
  final start = DateTime.utc(2016, 1, 1);
  double seconds(DateTime d) => d.millisecondsSinceEpoch / 1000 - 978307200;
  return Finances.fromDocument({
    'accounts': [
      for (final id in ['a1', 'a2'])
        {'id': id, 'name': 'Cuenta ficticia $id', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': 'enable:${id * 32}'},
    ],
    'categories': [
      {'id': 'c1', 'name': 'Comida', 'kindRaw': 'expense'},
      {'id': 'c2', 'name': 'Nómina', 'kindRaw': 'income'},
    ],
    'transactions': [
      for (var i = 0; i < count; i++)
        {
          'id': 't$i',
          'date': seconds(start.add(Duration(hours: i * 3))),
          'typeRaw': i % 7 == 0 ? 'income' : 'expense',
          'amountMinor': 100 + (i * 37) % 20000,
          'descriptionText': 'Movimiento ficticio ${i % 300}',
          'sourceAccountID': i.isEven ? 'a1' : 'a2',
          'categoryID': i % 10 == 0 ? null : (i % 7 == 0 ? 'c2' : 'c1'),
          'bankEntryKey': 'enable-entry:ficticio-$i',
        },
    ],
  });
}

Widget app(Widget child) => MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Scaffold(body: child),
    );

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  for (final count in [5000, 20000]) {
    testWidgets('rebuilding «Movimientos» with $count movements', (tester) async {
      final data = history(count);
      final repository = FinanceRepository()..finances = data;
      late StateSetter rebuild;
      await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return TransactionsScreen(calc: FinanceCalculator(data), repository: repository);
      })));
      await tester.pumpAndSettle();

      // What a notice of the repository does today: the open tab is built again with the same data.
      const rounds = 5;
      final watch = Stopwatch()..start();
      for (var i = 0; i < rounds; i++) {
        rebuild(() {});
        await tester.pump();
      }
      final perRebuild = watch.elapsedMilliseconds / rounds;
      // ignore: avoid_print
      print('Movimientos con $count: ${perRebuild.toStringAsFixed(0)} ms por redibujado');
      expect(find.byType(TransactionsScreen), findsOneWidget);
    });
  }

  testWidgets('rebuilding the other tabs with 20000 movements', (tester) async {
    final data = history(20000);
    final repository = FinanceRepository()..finances = data;
    final calc = FinanceCalculator(data);
    final month = DateTime(2026, 11);
    final tabs = <String, Widget Function()>{
      'Inicio': () => HomeScreen(calc: calc, month: month, onMonth: (_) {}),
      'Cuentas': () => AccountsScreen(calc: calc, repository: repository),
      'Presupuestos': () => BudgetsScreen(calc: calc, month: month, onMonth: (_) {}, repository: repository),
    };
    for (final MapEntry(key: name, value: tab) in tabs.entries) {
      late StateSetter rebuild;
      await tester.pumpWidget(app(StatefulBuilder(builder: (context, setState) {
        rebuild = setState;
        return tab();
      })));
      await tester.pumpAndSettle();
      final watch = Stopwatch()..start();
      for (var i = 0; i < 5; i++) {
        rebuild(() {});
        await tester.pump();
      }
      // ignore: avoid_print
      print('$name con 20000: ${(watch.elapsedMilliseconds / 5).toStringAsFixed(0)} ms por redibujado');
    }
  });

  testWidgets('what is kept is computed again when the data or the search change', (tester) async {
    final first = history(30);
    final repository = FinanceRepository()..finances = first;
    await tester.pumpWidget(app(TransactionsScreen(calc: FinanceCalculator(first), repository: repository)));
    await tester.pumpAndSettle();
    expect(find.text('Compra recién llegada'), findsNothing);

    final document = {
      'accounts': [
        {'id': 'a1', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': 0},
      ],
      'transactions': [
        {'id': 'nuevo', 'date': DateTime.now().millisecondsSinceEpoch / 1000 - 978307200, 'typeRaw': 'expense', 'amountMinor': 500,
          'descriptionText': 'Compra recién llegada', 'sourceAccountID': 'a1'},
        {'id': 'otro', 'date': DateTime.now().millisecondsSinceEpoch / 1000 - 978307200, 'typeRaw': 'expense', 'amountMinor': 700,
          'descriptionText': 'Otra compra ficticia', 'sourceAccountID': 'a1'},
      ],
    };
    final second = Finances.fromDocument(document);
    repository.finances = second;
    await tester.pumpWidget(app(TransactionsScreen(calc: FinanceCalculator(second), repository: repository)));
    await tester.pumpAndSettle();
    expect(find.text('Compra recién llegada'), findsOneWidget, reason: 'New data is not hidden by the kept list');

    await tester.enterText(find.byType(TextField).first, 'otra');
    await tester.pumpAndSettle();
    expect(find.text('Compra recién llegada'), findsNothing, reason: 'A new search is not hidden by the kept list');
    expect(find.text('Otra compra ficticia'), findsOneWidget);
  });
}
