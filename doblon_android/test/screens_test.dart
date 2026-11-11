// The screens build and react with fictitious data (no cloud involved).
import 'package:doblon/bank_activity.dart';
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/accounts.dart';
import 'package:doblon/screens/budgets.dart';
import 'package:doblon/screens/home.dart';
import 'package:doblon/screens/learning.dart';
import 'package:doblon/screens/manage.dart';
import 'package:doblon/screens/tools.dart';
import 'package:doblon/screens/transaction_detail.dart';
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

  testWidgets('a transfer can carry the selected reserve to another cash account', (tester) async {
    final data = Finances.fromDocument({
      'accounts': [
        {'id': 'source', 'name': 'Origen ficticio', 'typeRaw': 'checking', 'openingDate': 0, 'openingBalanceMinor': 100000},
        {'id': 'destination', 'name': 'Destino ficticio', 'typeRaw': 'checking', 'openingDate': 0}
      ],
      'reservedFunds': [
        {'id': 'reserve', 'name': 'Reserva ficticia', 'accountID': 'source', 'amountMinor': 30000}
      ]
    });
    await tester.pumpWidget(app(TransactionFormScreen(repository: repositoryWith(data))));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Traspaso'));
    await tester.pumpAndSettle();
    final reserveField = find.ancestor(of: find.text('Trasladar dinero reservado'), matching: find.byType(DropdownButtonFormField<String?>));
    await tester.ensureVisible(reserveField);
    await tester.pumpAndSettle();
    await tester.tap(reserveField);
    await tester.pumpAndSettle();
    expect(find.text('Reserva ficticia'), findsOneWidget);
    await tester.tap(find.text('Reserva ficticia'));
    await tester.pumpAndSettle();
    expect(find.text('Parte de la reserva que se traslada (€)'), findsOneWidget);
    expect(tester.takeException(), isNull);
  });

  testWidgets('a long press starts selecting to categorize several', (tester) async {
    final data = sample();
    await tester.pumpWidget(app(Scaffold(body: TransactionsScreen(calc: FinanceCalculator(data), repository: repositoryWith(data)))));
    await tester.pumpAndSettle();
    final movement = find.ancestor(of: find.text('Gasolinera ficticia'), matching: find.byType(InkWell)).last;
    await tester.ensureVisible(movement);
    await tester.pumpAndSettle();
    await tester.longPress(movement);
    await tester.pumpAndSettle();
    expect(find.text('1 seleccionados'), findsOneWidget);
    expect(find.text('Categorizar 1'), findsOneWidget);
  });

  testWidgets('every new screen opens with fictitious data', (tester) async {
    final data = sample();
    final repository = repositoryWith(data);
    final calc = FinanceCalculator(data);
    final pages = <Widget>[
      Scaffold(body: HomeScreen(calc: calc, month: DateTime.now(), onMonth: (_) {})),
      Scaffold(body: AccountsScreen(calc: calc, repository: repository)),
      AccountDetailScreen(repository: repository, accountId: 'a1'),
      AccountFormScreen(repository: repository),
      Scaffold(body: BudgetsScreen(calc: calc, month: DateTime.now(), onMonth: (_) {}, repository: repository)),
      BudgetEditorScreen(repository: repository, category: data.category('c1')!, month: DateTime.now()),
      GoalFormScreen(repository: repository),
      CategoriesScreen(repository: repository),
      RulesScreen(repository: repository),
      RuleFormScreen(repository: repository),
      RecurringScreen(repository: repository),
      RecurringFormScreen(repository: repository),
      InstitutionsScreen(repository: repository),
      CardFormScreen(repository: repository, accountId: 'a1'),
      ReserveFormScreen(repository: repository, accountId: 'a1'),
      CsvImportScreen(repository: repository),
      BackupScreen(repository: repository),
    ];
    for (final page in pages) {
      await tester.pumpWidget(app(page));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull, reason: '${page.runtimeType} must open without errors');
    }
  });

  testWidgets('learning, holds and investment recognition show in their screens', (tester) async {
    runTraining = <T>(T Function() work) async => work();
    final data = Finances.fromDocument({
      'accounts': [
        {'id': 'a1', 'name': 'Banco ficticio', 'typeRaw': 'checking', 'openingDate': 0, 'openingBalanceMinor': 100000, 'bankIdentityKey': 'enable:x'},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Supermercado', 'kindRaw': 'expense'},
        {'id': 'c2', 'name': 'Restaurantes', 'kindRaw': 'expense'},
      ],
      'transactions': [
        {
          'id': 'b1',
          'date': 815184000,
          'typeRaw': 'expense',
          'amountMinor': 1200,
          'descriptionText': 'Supermercado La Cesta compra',
          'sourceAccountID': 'a1',
          'bankEntryKey': 'enable-entry:x:1'
        },
      ],
    });
    final repository = repositoryWith(data)
      ..learning = Learning()
      ..bankActivity = {
        'enable:x': BankActivity(observedAt: DateTime.now(), currency: 'EUR', bookedBalance: 98800, availableBalance: 96300, pendingMovements: const [
          PendingMovement(id: 'p1', date: '2026-11-09', signedAmountMinor: -2500, currency: 'EUR', description: 'Gasolinera retenida', status: 'HOLD'),
        ]),
      };
    await tester.pumpWidget(app(LearningScreen(repository: repository)));
    await tester.pumpAndSettle();
    expect(find.text('Aprende de lo que confirmas'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Aplicar correcciones aprendidas'), 200, scrollable: find.byType(Scrollable).first);

    await tester.pumpWidget(app(TransactionDetailScreen(repository: repository, transactionId: 'b1')));
    await tester.pumpAndSettle();
    expect(find.text('Usar propuesta de IA: Supermercado'), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Reconocimiento de inversión'), 200, scrollable: find.byType(Scrollable).first);
    expect(find.text('Identificar operación'), findsOneWidget);

    await tester.pumpWidget(app(AccountDetailScreen(repository: repository, accountId: 'a1')));
    await tester.pumpAndSettle();
    expect(find.text('Saldos comunicados por el banco'), findsOneWidget);
    expect(find.text('Gasolinera retenida'), findsOneWidget);
    expect(find.text('Saldo tras retenciones'), findsOneWidget);

    await tester.pumpWidget(app(Scaffold(body: TransactionsScreen(calc: FinanceCalculator(data), repository: repository))));
    await tester.pumpAndSettle();
    expect(find.text('1 movimiento pendiente del banco'), findsOneWidget);
  });
}
