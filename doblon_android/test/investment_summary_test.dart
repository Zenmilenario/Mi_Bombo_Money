// Fictitious data only. The investment summary (24 November 2026): which portfolios make it up is chosen apart from
// net worth; by default every portfolio (also one left out of net worth) is in it; the choice is kept per person on
// the device after restarting and after a sync, never touches the finances, and Inicio and Cuentas show the same.
// For the developer's session and for an encrypted guest.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/presentation.dart' show money;
import 'package:doblon/screens/accounts.dart';
import 'package:doblon/screens/home.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'forecast_profiles_test.dart' as profiles show Cloud, seconds;

Map<String, dynamic> document() => {
      'formatVersion': 2,
      for (final key in ['institutions', 'cards', 'categoryRules', 'budgets', 'recurringBudgets', 'goals', 'importBatches', 'recurringMovements', 'reservedFunds', 'categories'])
        key: <dynamic>[],
      'accounts': [
        {'id': 'efectivo', 'name': 'Efectivo ficticio', 'typeRaw': 'checking', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'openingBalanceMinor': 200000},
        // The broker's portfolio, left out of net worth by the person; and a small portfolio a bank reports, counted.
        {'id': 'valores', 'name': 'Cartera de valores ficticia', 'typeRaw': 'investment', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'includeInNetWorth': false},
        {'id': 'pequena', 'name': 'Cartera pequeña ficticia', 'typeRaw': 'investment', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR'},
      ],
      'snapshots': [
        {'id': 'v', 'accountID': 'valores', 'balanceMinor': 30000, 'date': profiles.seconds(DateTime(2026, 11, 3)), 'sourceRaw': 'manual'},
        {'id': 'b', 'accountID': 'pequena', 'balanceMinor': 1500, 'date': profiles.seconds(DateTime(2026, 11, 20)), 'sourceRaw': 'bankAPI'},
      ],
      'transactions': [
        {
          'id': 'orden',
          'date': profiles.seconds(DateTime(2026, 11, 10, 10)),
          'typeRaw': 'transfer',
          'amountMinor': 3999,
          'descriptionText': 'Orden ficticia',
          'notes': '',
          'sourceAccountID': 'efectivo',
          'destinationAccountID': 'valores',
        },
      ],
    };

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es'));
  setUp(() {
    runTraining = <T>(T Function() work) async => work();
    CloudPrivacy.forgetAll();
    SharedPreferences.setMockInitialValues({});
  });

  for (final encrypted in [false, true]) {
    testWidgets('${encrypted ? 'guest' : 'developer'}: the summary choice is kept after restarting and syncing, and Inicio and Cuentas agree', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: document());
      late Directory directory;
      late FinanceRepository repo;
      Future<FinanceRepository> open() async {
        final client = await cloud.client();
        addTearDown(client.dispose);
        final repository = FinanceRepository(store: LocalStore(directory), cloudClient: client);
        addTearDown(repository.dispose);
        await repository.refresh();
        return repository;
      }

      await tester.runAsync(() async {
        await cloud.prepare();
        FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
        directory = await Directory.systemTemp.createTemp('doblon-summary');
        addTearDown(() async {
          try {
            await directory.delete(recursive: true);
          } on FileSystemException catch (_) {}
        });
        repo = await open();
      });
      expect(repo.isAdministrator, !encrypted);
      final before = jsonEncode(repo.document);
      final calc = FinanceCalculator(repo.finances!);
      expect(calc.invested(), 1500, reason: 'Net worth: only the counted portfolio');

      // By default every portfolio is in the summary, also the one out of net worth.
      Future<void> showBoth() async {
        final data = repo.finances!;
        await tester.pumpWidget(MaterialApp(
          theme: doblonTheme(Brightness.light),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: Column(children: [
              Expanded(child: HomeScreen(calc: FinanceCalculator(data), month: DateTime(2026, 11), onMonth: (_) {}, hiddenPortfolios: repo.hiddenPortfolios)),
              Expanded(child: AccountsScreen(calc: FinanceCalculator(data), repository: repo)),
            ]),
          ),
        ));
        await tester.pump();
      }

      await showBoth();
      expect(find.text(money(30000 + 3999 + 1500)), findsNWidgets(2), reason: 'Inicio and Cuentas, the same figure');

      // The person keeps only the broker's portfolio in the summary.
      await tester.runAsync(() => repo.setPortfolioInSummary('pequena', false));
      await showBoth();
      expect(find.text(money(30000 + 3999)), findsNWidgets(2));
      expect(find.textContaining('aportado ${money(3999)}'), findsOneWidget, reason: 'The month\'s line of Inicio, from the same portfolios');

      // Restarted (a new repository on the same device) and synced again: the choice is kept.
      await tester.runAsync(() async {
        repo = await open();
        await repo.refresh();
      });
      expect(repo.hiddenPortfolios, {'pequena'});
      await showBoth();
      expect(find.text(money(30000 + 3999)), findsNWidgets(2));

      // Nothing of this is in the finances: net worth and the cloud document are as they were.
      expect(jsonEncode(repo.document), before);
      expect(cloud.financeSaves, 0);
      expect(repo.finances!.accounts.firstWhere((a) => a.id == 'valores').includeInNetWorth, isFalse);
      if (encrypted) expect(cloud.plaintextCalls, isEmpty);
      expect(tester.takeException(), isNull);
    });
  }

  test('each person has their own choice, and signing out forgets it', () async {
    final directory = await Directory.systemTemp.createTemp('doblon-summary-people');
    addTearDown(() => directory.delete(recursive: true));
    final store = LocalStore(directory);
    await store.saveHiddenPortfolios('persona-a', {'x'});
    expect(await store.loadHiddenPortfolios('persona-a'), {'x'});
    expect(await store.loadHiddenPortfolios('persona-b'), isEmpty);
    await store.clear('persona-a');
    expect(await store.loadHiddenPortfolios('persona-a'), isEmpty);
  });
}
