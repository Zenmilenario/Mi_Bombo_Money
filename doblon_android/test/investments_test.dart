// Fictitious data only. An investment order with a fee (24 November 2026): 49,99 € bought from the broker's cash with
// a 1 € fee, 50,99 € out of the cash. The capital is a transfer to the portfolio, the fee a linked «fee» movement, out
// of everyday spending and budgets; the month's investing shows contributed, withdrawn and fees apart; a later bank
// charge (together or separate) is reconciled with what was recorded by hand; a later valuation is not added again.
// The form and the detail are checked for the developer's session and for an encrypted guest.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/banking.dart';
import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/investments.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/transaction_detail.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'forecast_profiles_test.dart' as profiles show Cloud, seconds;

final now = DateTime(2026, 11, 24, 18);
final orderDay = DateTime(2026, 11, 20, 10);

Account cash([String id = 'cash']) => Account(id: id, name: 'Efectivo $id', type: AccountType.checking, openingDate: DateTime(2026, 1, 1), openingBalanceMinor: 100000);
Account portfolio({bool counted = true}) =>
    Account(id: 'cartera', name: 'Cartera', type: AccountType.investment, openingDate: DateTime(2026, 1, 1), includeInNetWorth: counted);

Transaction order(int minor, {String id = 'orden', String from = 'cash', DateTime? date}) => Transaction(
    id: id, date: date ?? orderDay, type: TransactionType.transfer, amountMinor: minor, descriptionText: 'Compra de valores', sourceAccountId: from, destinationAccountId: 'cartera');
Transaction fee(int minor, {String of = 'orden', DateTime? date}) => Transaction(
    id: investmentFeeId(of),
    date: date ?? orderDay,
    type: TransactionType.fee,
    amountMinor: minor,
    descriptionText: 'Comisión · Compra de valores',
    sourceAccountId: 'cash',
    externalId: '$investmentFeeMarker$of');

Finances finances(List<Transaction> transactions, {List<Account>? accounts, List<BalanceSnapshot> snapshots = const []}) => Finances(
      accounts: accounts ?? [cash(), portfolio()],
      transactions: [...transactions]..sort((a, b) => b.date.compareTo(a.date)),
      snapshots: snapshots,
      categories: [Category(id: 'super', name: 'Supermercado', kind: CategoryKind.expense)],
    );

void main() {
  group('calculation', () {
    test('order of 49,99 € with a 1 € fee: 50,99 € out of the cash, 49,99 € invested, 1 € of fees, no everyday spending', () {
      final data = finances([order(4999), fee(100)]);
      final calc = FinanceCalculator(data);
      expect(calc.balance(data.account('cash')!, now), 100000 - 5099);
      expect(calc.balance(data.account('cartera')!, now), 4999, reason: 'Only the capital is invested');
      final flows = investmentFlows(data, DateTime(2026, 11), now: now);
      expect((flows.contributedMinor, flows.withdrawnMinor, flows.feesMinor), (4999, 0, 100));
      final month = calc.monthlySummary(DateTime(2026, 11));
      expect(month.dailyExpenseMinor, 0, reason: 'The fee is a cost of investing, not everyday spending');
      expect(month.expenseMinor, 100, reason: 'Kept in the full history');
      expect(calc.netWorth(now), 100000 - 100, reason: 'Net worth goes down only by the fee');
      expect(linkedFee(data, 'orden')!.amountMinor, 100);
    });

    test('without a fee, another fee or an unknown one: the split always adds up to what left the cash', () {
      expect(investmentFlows(finances([order(5099)]), DateTime(2026, 11), now: now).feesMinor, 0);
      final other = finances([order(4849), fee(250)]);
      expect(FinanceCalculator(other).balance(other.account('cash')!, now), 100000 - 5099);
      expect(investmentFlows(other, DateTime(2026, 11), now: now).contributedMinor, 4849);
      expect(validateSplit(totalMinor: 5099, feeMinor: 100), isNull);
      expect(validateSplit(totalMinor: 5099, feeMinor: 5099), isNotNull);
      expect(validateSplit(totalMinor: 5099, feeMinor: -1), isNotNull);
    });

    test('money moved to the broker\'s cash and then the order: one contribution, never two', () {
      final data = finances([
        Transaction(
            id: 'traslado',
            date: DateTime(2026, 11, 18),
            type: TransactionType.transfer,
            amountMinor: 5099,
            descriptionText: 'Al broker',
            sourceAccountId: 'banco',
            destinationAccountId: 'cash'),
        order(4999),
        fee(100),
      ], accounts: [cash('banco'), cash(), portfolio()]);
      final flows = investmentFlows(data, DateTime(2026, 11), now: now);
      expect((flows.contributedMinor, flows.operations), (4999, 1));
    });

    test('a later valuation that already includes the order is not added again; the net worth choice is kept', () {
      final valued = finances([order(4999), fee(100)],
          snapshots: [BalanceSnapshot(id: 'v', date: DateTime(2026, 11, 22), balanceMinor: 5150, accountId: 'cartera', source: 'manual')]);
      expect(FinanceCalculator(valued).balance(valued.account('cartera')!, now), 5150);
      final outside = finances([order(4999), fee(100)], accounts: [cash(), portfolio(counted: false)]);
      expect(FinanceCalculator(outside).invested(), 0);
      expect(investmentFlows(outside, DateTime(2026, 11), now: now).contributedMinor, 4999, reason: 'Still a contribution of the month');
    });

    test('the fee is out of budgets and of the everyday spending of the month', () {
      final data = finances([order(4999), fee(100)]);
      expect(FinanceCalculator.budgetExpenseAmount(fee(100)), 0);
      expect(FinanceCalculator(data).dailySpending(DateTime(2026, 11)), isEmpty);
    });

    test('editing and deleting keep order and fee together and never add another outflow', () {
      final data = finances([order(4999), fee(100)]);
      // The fee corrected to 1,50 € (the total stays 50,99 €): the fee is patched, not duplicated.
      final ops = feeOperations(
          transferId: 'orden', currentFee: linkedFee(data, 'orden'), feeMinor: 150, sourceAccountId: 'cash', date: orderDay, orderDescription: 'Compra', now: now);
      expect(ops.single.kind, 'patch');
      expect(ops.single.data['id'], investmentFeeId('orden'));
      // Removed when it is set to nothing.
      expect(feeOperations(transferId: 'orden', currentFee: linkedFee(data, 'orden'), feeMinor: 0, sourceAccountId: 'cash', date: orderDay, orderDescription: '', now: now)
          .single
          .kind, 'delete');
      // Added once to an order recorded without it.
      final added = feeOperations(transferId: 'orden', currentFee: null, feeMinor: 100, sourceAccountId: 'cash', date: orderDay, orderDescription: 'Compra', now: now);
      expect((added.single.kind, added.single.data['record']['externalID']), ('insert', '${investmentFeeMarker}orden'));
    });
  });

  group('bank reconciliation', () {
    final remote = RemoteAccount(id: 'tr-cash', currency: 'EUR', lastFour: '0000');
    final connection = RemoteConnection(id: '00000000-0000-4000-8000-0000000000aa', bank: 'Broker ficticio', validUntil: '2027-01-01', accounts: [remote]);
    Map<String, dynamic> document({bool withFee = true}) => {
          'formatVersion': 2,
          'accounts': [
            {'id': 'cash', 'name': 'Efectivo', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': accountIdentity('tr-cash')},
            {'id': 'cartera', 'name': 'Cartera', 'typeRaw': 'investment', 'openingDate': 0},
          ],
          'transactions': [
            {
              'id': 'orden',
              'date': profiles.seconds(orderDay),
              'typeRaw': 'transfer',
              'amountMinor': withFee ? 4999 : 5099,
              'descriptionText': 'Compra de valores',
              'sourceAccountID': 'cash',
              'destinationAccountID': 'cartera',
              'bankEntryKey': null,
            },
            if (withFee)
              {
                'id': investmentFeeId('orden'),
                'date': profiles.seconds(orderDay),
                'typeRaw': 'fee',
                'amountMinor': 100,
                'descriptionText': 'Comisión',
                'sourceAccountID': 'cash',
                'externalID': '${investmentFeeMarker}orden',
                'isReconciled': false,
                'bankEntryKey': null,
              },
          ],
          'snapshots': [],
        };
    AccountFeed feed(List<int> charges) => AccountFeed(connection: connection, account: remote, balances: [], movements: [
          for (final (i, c) in charges.indexed) Movement(id: 'b$i', bookingDate: '2026-11-21', signedAmountMinor: -c, currency: 'EUR', description: 'Compra Trade Ficticia'),
        ]);

    test('one charge of 50,99 € is the order and its fee: proposed against the order, then reconciled without a new outflow', () {
      final doc = document();
      final (proposed, result) = importFeeds(doc, [feed([5099])], now);
      expect(result.inserted, 0, reason: 'Never inserted as a new expense');
      expect(result.proposals.single.candidateIds, ['orden']);
      final key = result.proposals.single.key;
      final (done, after) = importFeeds(doc, [feed([5099])], now, decisions: {key: 'orden'});
      expect((after.matched, after.inserted), (1, 0));
      final rows = (done['transactions'] as List).cast<Map<String, dynamic>>();
      expect(rows.length, 2);
      expect(rows.firstWhere((t) => t['id'] == 'orden')['bankEntryKey'], key);
      expect(rows.firstWhere((t) => t['typeRaw'] == 'fee')['isReconciled'], isTrue, reason: 'Reconciled inside the same charge');
      final data = Finances.fromDocument(done);
      expect(FinanceCalculator(data).balance(data.account('cash')!, now), -5099);
      expect(proposed, isNotNull);
    });

    test('separate charges of 49,99 € and 1 €: each one goes to its part', () {
      final doc = document();
      final (_, result) = importFeeds(doc, [feed([4999, 100])], now);
      expect(result.inserted, 0);
      final byAmount = {for (final p in result.proposals) p.amountMinor: p.candidateIds};
      expect(byAmount[-4999], ['orden']);
      expect(byAmount[-100], [investmentFeeId('orden')]);
    });

    test('an order recorded without a fee is also found by its own amount', () {
      final (_, result) = importFeeds(document(withFee: false), [feed([5099])], now);
      expect(result.inserted, 0);
      expect(result.proposals.single.candidateIds, ['orden']);
    });
  });

  group('form and detail', () {
    TestWidgetsFlutterBinding.ensureInitialized();
    setUpAll(() => initializeDateFormatting('es'));
    setUp(() {
      runTraining = <T>(T Function() work) async => work();
      CloudPrivacy.forgetAll();
      SharedPreferences.setMockInitialValues({});
    });

    Map<String, dynamic> cloudDocument() => {
          'formatVersion': 2,
          for (final key in ['institutions', 'cards', 'categoryRules', 'budgets', 'recurringBudgets', 'goals', 'importBatches', 'snapshots', 'recurringMovements', 'reservedFunds'])
            key: <dynamic>[],
          'accounts': [
            {'id': 'cash', 'name': 'Efectivo ficticio', 'typeRaw': 'checking', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'openingBalanceMinor': 100000},
            {'id': 'cartera', 'name': 'Cartera ficticia', 'typeRaw': 'investment', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR'},
          ],
          'categories': [
            {'id': 'inversion', 'name': 'Inversión', 'kindRaw': 'transfer'},
          ],
          // As the person recorded it: one transfer of 50,99 € to the portfolio.
          'transactions': [
            {
              'id': 'orden',
              'date': profiles.seconds(DateTime(2026, 11, 20, 10)),
              'typeRaw': 'transfer',
              'amountMinor': 5099,
              'descriptionText': 'Orden de compra ficticia',
              'notes': '',
              'sourceAccountID': 'cash',
              'destinationAccountID': 'cartera',
              'categoryID': 'inversion',
            },
          ],
        };

    for (final encrypted in [false, true]) {
      testWidgets('${encrypted ? 'guest' : 'developer'}: the recorded 50,99 € is split into 49,99 € and a 1 € fee, edited and deleted together', (tester) async {
        tester.view.physicalSize = const Size(400, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: cloudDocument());
        late FinanceRepository repo;
        await tester.runAsync(() async {
          await cloud.prepare();
          FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
          final directory = await Directory.systemTemp.createTemp('doblon-investment');
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
        expect(repo.isAdministrator, !encrypted);
        Future<void> settle([int rounds = 60]) async {
          for (var i = 0; i < rounds; i++) {
            await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
            await tester.pump(const Duration(milliseconds: 100));
          }
        }

        await tester.pumpWidget(MaterialApp(
          theme: doblonTheme(Brightness.light),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: TransactionDetailScreen(repository: repo, transactionId: 'orden'),
        ));
        await tester.pumpAndSettle();
        expect(find.text('Aportado a la inversión'), findsOneWidget);
        await tester.tap(find.byTooltip('Editar'));
        await tester.pumpAndSettle();
        expect(find.text('Importe total cargado (€)'), findsOneWidget);
        await tester.enterText(find.widgetWithText(TextField, 'Comisión de la orden (€, opcional)'), '1');
        await tester.pump();
        expect(find.textContaining('Se invierten 49,99'), findsOneWidget);
        await tester.tap(find.text('Guardar cambios'));
        await settle();

        Map<String, dynamic> row(String id) => Map<String, dynamic>.from(
            (repo.document!['transactions'] as List).cast<Map>().firstWhere((t) => '${t['id']}'.toLowerCase() == id.toLowerCase()));
        expect((repo.document!['transactions'] as List).length, 2, reason: 'The order and its fee, no other outflow');
        expect(row('orden')['amountMinor'], 4999);
        expect((row(investmentFeeId('orden'))['amountMinor'], row(investmentFeeId('orden'))['externalID']), (100, '${investmentFeeMarker}orden'));
        expect(cloud.financeSaves, 1, reason: 'Saved together, once');
        final data = repo.finances!;
        expect(FinanceCalculator(data).balance(data.account('cash')!, now), 100000 - 5099, reason: 'The cash goes down by 50,99 € once');
        expect(find.text('Comisión de la orden'), findsOneWidget);
        expect(find.text('Salida total del efectivo'), findsOneWidget);

        // Edited again: the form shows the total and the fee; changing the fee keeps the total.
        await tester.tap(find.byTooltip('Editar'));
        await tester.pumpAndSettle();
        expect(tester.widget<TextField>(find.widgetWithText(TextField, 'Importe total cargado (€)')).controller!.text, '50,99');
        await tester.enterText(find.widgetWithText(TextField, 'Comisión de la orden (€, opcional)'), '1,50');
        await tester.tap(find.text('Guardar cambios'));
        await settle();
        expect((row('orden')['amountMinor'], row(investmentFeeId('orden'))['amountMinor']), (4949, 150));
        expect((repo.document!['transactions'] as List).length, 2);

        // Deleted: the order and its fee go together.
        await tester.tap(find.byTooltip('Borrar'));
        await tester.pumpAndSettle();
        expect(find.textContaining('También se borra su comisión'), findsOneWidget);
        await tester.tap(find.text('Borrar').last);
        await settle();
        expect(repo.document!['transactions'], isEmpty);
        if (encrypted) {
          expect(cloud.plaintextCalls, isEmpty);
          expect(cloud.requests.any((r) => r.contains('Orden de compra ficticia')), isFalse, reason: 'Only sealed envelopes');
        } else {
          expect(jsonEncode(cloud.document['transactions']), '[]');
        }
        expect(tester.takeException(), isNull);
      });
    }
  });
}
