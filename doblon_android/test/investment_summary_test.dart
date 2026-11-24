// Fictitious data only. The investment summary (24 November 2026): which portfolios make it up is chosen apart from
// net worth and saved with each account in the cloud. By default every portfolio (also one left out of net worth)
// is in it; a change reaches another device of the same person after a sync, is kept after restarting, and a choice
// kept on the device by the earlier version is moved there once. Inicio and Cuentas show the same. For the
// developer's session and for an encrypted guest.
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

  Future<void> settle(WidgetTester tester, [int rounds = 20]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  for (final encrypted in [false, true]) {
    final who = encrypted ? 'guest' : 'developer';

    testWidgets('$who: the choice is saved in the cloud, reaches another device, is kept after restarting, and Inicio and Cuentas agree', (tester) async {
      tester.view.physicalSize = const Size(400, 1600);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: document());
      Future<FinanceRepository> device(Directory directory) async {
        final client = await cloud.client();
        addTearDown(client.dispose);
        final repository = FinanceRepository(store: LocalStore(directory), cloudClient: client);
        addTearDown(repository.dispose);
        await repository.refresh();
        return repository;
      }

      late Directory phone, tablet;
      late FinanceRepository repo;
      await tester.runAsync(() async {
        await cloud.prepare();
        FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
        phone = await Directory.systemTemp.createTemp('doblon-summary-phone');
        tablet = await Directory.systemTemp.createTemp('doblon-summary-tablet');
        for (final d in [phone, tablet]) {
          addTearDown(() async {
            try {
              await d.delete(recursive: true);
            } on FileSystemException catch (_) {}
          });
        }
        repo = await device(phone);
      });
      expect(repo.isAdministrator, !encrypted);
      expect(FinanceCalculator(repo.finances!).invested(), 1500, reason: 'Net worth: only the counted portfolio');

      Future<void> showBoth(FinanceRepository r) async {
        final data = r.finances!;
        await tester.pumpWidget(MaterialApp(
          theme: doblonTheme(Brightness.light),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Scaffold(
            body: Column(children: [
              Expanded(child: HomeScreen(calc: FinanceCalculator(data), month: DateTime(2026, 11), onMonth: (_) {})),
              Expanded(child: AccountsScreen(calc: FinanceCalculator(data), repository: r)),
            ]),
          ),
        ));
        await tester.pump();
      }

      // By default every portfolio is in the summary, also the one out of net worth.
      await showBoth(repo);
      expect(find.text(money(30000 + 3999 + 1500)), findsNWidgets(2), reason: 'Inicio and Cuentas, the same figure');

      // On the phone, the person keeps only the broker's portfolio: saved once in the cloud with that account.
      final saves = cloud.financeSaves;
      final updated = repo.setPortfolioInSummary('pequena', false);
      await settle(tester);
      await updated;
      expect(cloud.financeSaves, saves + 1);
      await showBoth(repo);
      expect(find.text(money(30000 + 3999)), findsNWidgets(2));
      expect(find.textContaining('aportado ${money(3999)}'), findsOneWidget, reason: 'The month\'s line of Inicio, from the same portfolios');

      // Another device of the same person (its own storage, the same cloud) sees it after syncing.
      await tester.runAsync(() async => repo = await device(tablet));
      expect(repo.finances!.accounts.firstWhere((a) => a.id == 'pequena').inInvestmentSummary, isFalse);
      await showBoth(repo);
      expect(find.text(money(30000 + 3999)), findsNWidgets(2));

      // Restarted on the phone: the same.
      await tester.runAsync(() async => repo = await device(phone));
      await showBoth(repo);
      expect(find.text(money(30000 + 3999)), findsNWidgets(2));

      // Net worth is decided apart and did not change.
      expect(repo.finances!.accounts.firstWhere((a) => a.id == 'valores').includeInNetWorth, isFalse);
      expect(repo.finances!.accounts.firstWhere((a) => a.id == 'pequena').includeInNetWorth, isTrue);
      if (encrypted) {
        expect(cloud.plaintextCalls, isEmpty);
        expect(cloud.requests.any((r) => r.contains('inInvestmentSummary')), isFalse, reason: 'Inside the sealed envelope');
      } else {
        expect(jsonEncode(cloud.document), contains('"inInvestmentSummary":false'));
      }
      expect(tester.takeException(), isNull);
    });

    testWidgets('$who: a choice kept on the device by 0.35.2 is moved to the cloud once', (tester) async {
      final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: document());
      late FinanceRepository repo;
      late Directory directory;
      await tester.runAsync(() async {
        await cloud.prepare();
        FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
        directory = await Directory.systemTemp.createTemp('doblon-summary-move');
        addTearDown(() async {
          try {
            await directory.delete(recursive: true);
          } on FileSystemException catch (_) {}
        });
        await LocalStore(directory).saveHiddenPortfolios(cloud.user, {'pequena'});
        final client = await cloud.client();
        addTearDown(client.dispose);
        repo = FinanceRepository(store: LocalStore(directory), cloudClient: client);
        await repo.refresh();
      });
      addTearDown(repo.dispose);
      await settle(tester);
      expect(repo.finances!.accounts.firstWhere((a) => a.id == 'pequena').inInvestmentSummary, isFalse);
      expect(cloud.financeSaves, 1);
      expect(await tester.runAsync(() => LocalStore(directory).loadHiddenPortfolios(cloud.user)), isEmpty, reason: 'The local copy is forgotten');
      // Opening again does not save anything else.
      await tester.runAsync(repo.refresh);
      await settle(tester, 5);
      expect(cloud.financeSaves, 1);
    });
  }
}
