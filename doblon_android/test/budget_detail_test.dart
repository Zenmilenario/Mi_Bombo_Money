// Fictitious data only. The detail of a budget (24 November 2026): the movements behind its spending in the month
// being looked at, with the same rules as the budget (its total always matches), payments partly made with a
// reserve, carried-over money apart, no transfers, no other months, and an edit changing detail and budget at once,
// for the developer's session and for an encrypted guest.
import 'dart:io';

import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:doblon/presentation.dart' show money;
import 'package:doblon/screens/budget_detail.dart';
import 'package:doblon/screens/budgets.dart';
import 'package:doblon/screens/transaction_detail.dart';
import 'package:doblon/screens/widgets.dart' show MonthSelector;
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:intl/intl.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'forecast_profiles_test.dart' as profiles show Cloud, seconds;

Transaction spend(String id, DateTime date, int minor, {String category = 'compras', TransactionType type = TransactionType.expense, String? fund, int? reserved}) =>
    Transaction(
        id: id,
        date: date,
        type: type,
        amountMinor: minor,
        descriptionText: 'Compra $id',
        sourceAccountId: 'a',
        destinationAccountId: type == TransactionType.transfer ? 'b' : null,
        categoryId: category,
        reservedFundId: fund,
        reservedAmountMinor: reserved);

void main() {
  test('the movements add up to the budget, each counted as the budget counts it', () {
    final shopping = Category(id: 'compras', name: 'Compras', kind: CategoryKind.expense);
    final other = Category(id: 'ocio', name: 'Ocio', kind: CategoryKind.expense);
    final data = Finances(
      accounts: [Account(id: 'a', name: 'Cuenta', type: AccountType.checking, openingDate: DateTime(2025)), Account(id: 'b', name: 'Ahorro', type: AccountType.savings, openingDate: DateTime(2025))],
      categories: [shopping, other],
      reservedFunds: [ReservedFund(id: 'f', name: 'Regalos', amountMinor: 50000, accountId: 'a', createdAt: DateTime(2026, 1))],
      recurringBudgets: [RecurringBudget(id: 'b', startMonth: DateTime(2026, 9), baseLimitMinor: 20000, remainderChoice: RemainderChoice.carryForward, categoryId: 'compras')],
      transactions: [
        spend('oct', DateTime(2026, 10, 31, 23, 30), 1000), // the last minute of October: not November
        spend('n1', DateTime(2026, 11, 3, 10), 3000),
        spend('n2', DateTime(2026, 11, 3, 18), 2000),
        spend('mitad', DateTime(2026, 11, 10), 10000, fund: 'f', reserved: 4000), // 40 € from the reserve
        spend('entera', DateTime(2026, 11, 12), 2500, fund: 'f', reserved: 2500), // all from the reserve
        spend('comision', DateTime(2026, 11, 14), 300, type: TransactionType.fee),
        spend('traspaso', DateTime(2026, 11, 15), 9900, type: TransactionType.transfer), // own transfer, even with the category
        spend('ingreso', DateTime(2026, 11, 16), 700, type: TransactionType.income),
        spend('otra', DateTime(2026, 11, 17), 1500, category: 'ocio'),
        spend('dic', DateTime(2026, 12, 1, 0, 5), 800),
      ]..sort((x, y) => y.date.compareTo(x.date)),
    );
    final calc = FinanceCalculator(data);
    final november = DateTime(2026, 11);
    final budget = calc.budgetProgress(november, asOf: DateTime(2026, 11, 20)).firstWhere((b) => b.category.id == 'compras');
    final detail = calc.budgetContributions('compras', november);
    expect(detail.map((c) => c.transaction.id), ['comision', 'entera', 'mitad', 'n2', 'n1']);
    expect(detail.fold(0, (sum, c) => sum + c.countedMinor), budget.spentMinor);
    expect(budget.spentMinor, 300 + 0 + 6000 + 2000 + 3000);
    final half = detail.firstWhere((c) => c.transaction.id == 'mitad');
    expect((half.totalMinor, half.reservedMinor, half.countedMinor, half.isPartial), (10000, 4000, 6000, true));
    expect(detail.firstWhere((c) => c.transaction.id == 'entera').countedMinor, 0);
    // Carried over (September left 200 €, October 390 € of its 400 €): it changes the limit, not the spending.
    expect(budget.carriedInMinor, 39000);
    expect(budget.limitMinor, 20000 + 39000);
    for (final month in [DateTime(2026, 10), DateTime(2026, 12)]) {
      final b = calc.budgetProgress(month, asOf: DateTime(2026, 12, 20)).firstWhere((b) => b.category.id == 'compras');
      expect(calc.budgetContributions('compras', month).fold(0, (sum, c) => sum + c.countedMinor), b.spentMinor);
    }
  });

  group('screens', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() => initializeDateFormatting('es'));
    setUp(() {
      runTraining = <T>(T Function() work) async => work();
      CloudPrivacy.forgetAll();
      SharedPreferences.setMockInitialValues({});
    });

    final now = DateTime.now();
    final previous = DateTime(now.year, now.month - 1);
    DateTime inPrevious(int day, [int hour = 12]) => DateTime(previous.year, previous.month, day, hour);
    Map<String, dynamic> document(String who) => {
          'formatVersion': 2,
          for (final key in ['institutions', 'cards', 'categoryRules', 'budgets', 'goals', 'importBatches', 'snapshots', 'recurringMovements']) key: <dynamic>[],
          'accounts': [
            {'id': 'a', 'name': 'Cuenta $who', 'typeRaw': 'checking', 'openingDate': profiles.seconds(DateTime(2025)), 'currencyCode': 'EUR', 'openingBalanceMinor': 100000},
          ],
          'categories': [
            {'id': 'compras', 'name': 'Compras', 'kindRaw': 'expense'},
            {'id': 'ocio', 'name': 'Ocio', 'kindRaw': 'expense'},
          ],
          'reservedFunds': [
            {'id': 'f', 'name': 'Reserva $who', 'amountMinor': 20000, 'accountID': 'a', 'createdAt': profiles.seconds(DateTime(2025, 6))},
          ],
          'recurringBudgets': [
            {'id': 'p', 'startMonth': profiles.seconds(DateTime(2025, 1, 1, 12)), 'baseLimitMinor': 20000, 'remainderChoiceRaw': 'save', 'categoryID': 'compras'},
          ],
          'transactions': [
            for (final (id, day, minor, reserved) in [('t1', 3, 3000, null), ('t2', 3, 2000, null), ('t3', 10, 10000, 4000)])
              {
                'id': id,
                'date': profiles.seconds(inPrevious(day)),
                'typeRaw': 'expense',
                'amountMinor': minor,
                'descriptionText': 'Tienda $who $id',
                'sourceAccountID': 'a',
                'categoryID': 'compras',
                if (reserved != null) ...{'reservedFundID': 'f', 'reservedAmountMinor': reserved},
              },
            {
              'id': 'now1',
              'date': profiles.seconds(DateTime(now.year, now.month, 1, 12)),
              'typeRaw': 'expense',
              'amountMinor': 1500,
              'descriptionText': 'Tienda $who de este mes',
              'sourceAccountID': 'a',
              'categoryID': 'compras',
            },
          ],
        };

    Future<void> settle(WidgetTester tester, [int rounds = 6]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 30)));
        await tester.pump(const Duration(milliseconds: 300));
      }
    }

    for (final encrypted in [false, true]) {
      final who = encrypted ? 'Beta' : 'Alfa';
      testWidgets('${encrypted ? 'guest' : 'developer'}: from Presupuestos to the detail of the month chosen, and an edit updates both', (tester) async {
        tester.view.physicalSize = const Size(400, 900);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: document(who));
        late FinanceRepository repo;
        await tester.runAsync(() async {
          await cloud.prepare();
          FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
          final directory = await Directory.systemTemp.createTemp('doblon-budget-detail');
          addTearDown(() async {
            try {
              await directory.delete(recursive: true);
            } on FileSystemException catch (_) {}
          });
          final client = await cloud.client();
          addTearDown(client.dispose);
          repo = FinanceRepository(store: LocalStore(directory), cloudClient: client);
          await repo.refresh();
        });
        addTearDown(repo.dispose);
        expect(repo.error, isNull);
        expect(repo.isAdministrator, !encrypted);

        var month = DateTime(now.year, now.month);
        await tester.pumpWidget(MaterialApp(
          theme: doblonTheme(Brightness.light),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: StatefulBuilder(
            builder: (context, setState) => ListenableBuilder(
              listenable: repo,
              builder: (context, _) => BudgetsScreen(calc: FinanceCalculator(repo.finances!), month: month, onMonth: (m) => setState(() => month = m), repository: repo),
            ),
          ),
        ));
        await settle(tester, 2);

        // The month being looked at: the previous one.
        await tester.tap(find.descendant(of: find.byType(MonthSelector), matching: find.byIcon(Icons.chevron_left)));
        await settle(tester, 2);
        // The budget's row, under «Dentro del presupuesto» (the list builds it once scrolled to).
        await tester.scrollUntilVisible(find.text('Dentro del presupuesto'), 300, scrollable: find.byType(Scrollable).first);
        await tester.pump();
        await tester.tap(find.text('Compras').last);
        await settle(tester, 2);
        expect(find.byType(BudgetDetailScreen), findsOneWidget);
        final monthName = toBeginningOfSentenceCase(DateFormat('MMMM yyyy', 'es').format(previous));
        expect(find.text(monthName), findsOneWidget);
        // 30 + 20 + 60 (100 € with 40 € from the reserve) = 110 € consumed of 200 €.
        expect(find.text(money(11000)), findsWidgets);
        expect(find.text('Suma: ${money(11000)}'), findsOneWidget);
        expect(find.text('Restante'), findsOneWidget);
        expect(find.textContaining('Total ${money(10000)}, ${money(4000)} con «Reserva $who»'), findsOneWidget);
        expect(find.textContaining('Pagado con reservas: ${money(4000)}'), findsOneWidget);
        expect(find.textContaining('de este mes'), findsNothing, reason: 'Another month is never mixed in');
        expect(find.textContaining(encrypted ? 'Alfa' : 'Beta'), findsNothing);
        expect(find.textContaining('Cuenta $who'), findsNWidgets(3), reason: 'The account of each movement');

        // A movement opens its existing detail.
        await tester.tap(find.text('Tienda $who t1'));
        await settle(tester, 2);
        expect(find.byType(TransactionDetailScreen), findsOneWidget);
        Navigator.of(tester.element(find.byType(TransactionDetailScreen))).pop();
        await settle(tester, 2);

        // Edits: another category, the whole payment from the reserve, another month. Detail and budget follow.
        await tester.runAsync(() => repo.apply(Operation('patch', {'id': 't1', 'fields': {'categoryID': 'ocio'}})));
        await settle(tester, 2);
        expect(find.text('Tienda $who t1'), findsNothing);
        expect(find.text('Suma: ${money(8000)}'), findsOneWidget);
        await tester.runAsync(() => repo.apply(Operation('patch', {'id': 't3', 'fields': {'reservedAmountMinor': 10000}})));
        await settle(tester, 2);
        expect(find.text('Suma: ${money(2000)}'), findsOneWidget);
        expect(find.textContaining('Total ${money(10000)}, pagado con «Reserva $who»'), findsOneWidget);
        await tester.runAsync(() => repo.apply(Operation('patch', {'id': 't2', 'fields': {'date': profiles.seconds(DateTime(now.year, now.month, 1, 13))}})));
        await settle(tester, 2);
        expect(find.text('Suma: ${money(0)}'), findsOneWidget);
        Navigator.of(tester.element(find.byType(BudgetDetailScreen))).pop();
        await settle(tester, 2);
        expect(find.textContaining('Gastado: ${money(0)}'), findsOneWidget, reason: 'The budget says the same as its detail');

        // The current month: what moved into it, and its own purchase.
        Navigator.of(tester.element(find.byType(BudgetsScreen)))
            .push(MaterialPageRoute<void>(builder: (_) => BudgetDetailScreen(repository: repo, categoryId: 'compras', month: DateTime(now.year, now.month))));
        await settle(tester, 2);
        await tester.scrollUntilVisible(find.textContaining('Suma:'), 300, scrollable: find.byType(Scrollable).last);
        expect(find.text('Suma: ${money(3500)}'), findsOneWidget);
        expect(tester.takeException(), isNull);
        if (encrypted) expect(cloud.plaintextCalls, isEmpty);
      });
    }

    testWidgets('a budget without movements this month says so', (tester) async {
      final cloud = profiles.Cloud('fictitious-admin', encrypted: false, document: document('Alfa')..['transactions'] = <dynamic>[]);
      late FinanceRepository repo;
      await tester.runAsync(() async {
        FlutterSecureStorage.setMockInitialValues({});
        final directory = await Directory.systemTemp.createTemp('doblon-budget-empty');
        addTearDown(() async {
          try {
            await directory.delete(recursive: true);
          } on FileSystemException catch (_) {}
        });
        final client = await cloud.client();
        addTearDown(client.dispose);
        repo = FinanceRepository(store: LocalStore(directory), cloudClient: client);
        await repo.refresh();
      });
      addTearDown(repo.dispose);
      final month = DateTime(now.year, now.month);
      await tester.pumpWidget(MaterialApp(
        theme: doblonTheme(Brightness.light),
        locale: const Locale('es', 'ES'),
        supportedLocales: const [Locale('es', 'ES')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: BudgetDetailScreen(repository: repo, categoryId: 'compras', month: month),
      ));
      await tester.pump();
      final name = DateFormat('MMMM yyyy', 'es').format(month);
      expect(find.text('Sin gastos de Compras en $name'), findsOneWidget);
      expect(find.text('Restante'), findsOneWidget);
    });
  });
}
