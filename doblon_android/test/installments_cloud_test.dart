// Fictitious data only. Payments in instalments in the cloud (25 November 2026): the sign-up asks for what it needs
// (never assumes the first due date), a plan travels with the finances to another device of the same person, a
// payment recorded from its detail is one movement, and undoing it removes it everywhere. For the developer's session
// (plaintext storage, `finance_installment_plans`) and for an encrypted guest (inside the sealed envelope).
import 'dart:convert';
import 'dart:io';

import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/installments.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/installments_screen.dart';
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
      for (final key in ['institutions', 'cards', 'categoryRules', 'budgets', 'recurringBudgets', 'goals', 'importBatches', 'recurringMovements', 'reservedFunds', 'categories', 'snapshots', 'transactions'])
        key: <dynamic>[],
      'accounts': [
        {'id': 'cuenta', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'openingBalanceMinor': 500000},
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

  Widget app(Widget home) => MaterialApp(
        theme: doblonTheme(Brightness.light),
        locale: const Locale('es', 'ES'),
        supportedLocales: const [Locale('es', 'ES')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: home,
      );

  for (final encrypted in [false, true]) {
    final who = encrypted ? 'guest' : 'developer';

    testWidgets('$who: sign-up without assumed dates, sync to another device, a payment from the detail and its undo', (tester) async {
      tester.view.physicalSize = const Size(500, 2400);
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
        phone = await Directory.systemTemp.createTemp('doblon-plazos-phone');
        tablet = await Directory.systemTemp.createTemp('doblon-plazos-tablet');
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

      // The sign-up: the kind first, then the fields. Without the first due date it does not save (never assumed).
      await tester.pumpWidget(app(InstallmentFormScreen(repository: repo)));
      await tester.tap(find.text('Compra a plazos'));
      await tester.pump();
      await tester.enterText(find.widgetWithText(TextField, 'Nombre o concepto'), 'Compra ficticia');
      await tester.enterText(find.widgetWithText(TextField, 'Importe total pendiente (€)'), '4378');
      await tester.enterText(find.widgetWithText(TextField, 'Número de cuotas'), '12');
      await tester.pump();
      await tester.tap(find.text('Guardar'));
      await tester.pump();
      expect(find.text('Elige la fecha del primer vencimiento.'), findsOneWidget);
      expect(repo.finances!.installmentPlans, isEmpty);
      expect(find.text('Calendario'), findsNothing, reason: 'No calendar until the date is given');

      // Saved with a first due date written by the person (here, in the test).
      final schedule = buildSchedule(437800, 12, DateTime(2026, 11, 5, 12))!;
      final plan = InstallmentPlan(
          id: 'plan-ficticio', name: 'Compra ficticia', kind: InstallmentKind.purchase, totalMinor: 437800, schedule: schedule, accountId: 'cuenta');
      final saves = cloud.financeSaves;
      final saved = repo.apply(savePlanOperation(plan: plan, create: true, data: repo.finances!, now: DateTime(2026, 11, 1)));
      await settle(tester);
      await saved;
      expect(cloud.financeSaves, saves + 1);

      // The detail: total, pending, 0/12; the payment of the first instalment, recorded from its row.
      await tester.pumpWidget(app(InstallmentDetailScreen(repository: repo, planId: 'plan-ficticio')));
      await tester.pump();
      expect(find.textContaining('0/12 cuotas pagadas'), findsOneWidget);
      await tester.tap(find.textContaining('1. 5 nov 2026'));
      await settle(tester, 5);
      await tester.tap(find.text('Registrar el pago'));
      await settle(tester, 5);
      await tester.tap(find.text('Guardar'));
      await settle(tester);
      final paid = repo.finances!.transactions.where((t) => t.installmentPlanId == 'plan-ficticio').toList();
      expect(paid.single.amountMinor, 36483);
      expect(paid.single.installmentNumber, 1);
      expect(find.textContaining('1/12 cuotas pagadas'), findsOneWidget);

      // Another device of the same person sees the plan and the payment once.
      await tester.runAsync(() async => repo = await device(tablet));
      expect(repo.finances!.installmentPlans.single.schedule.length, 12);
      expect(repo.finances!.installmentPlans.single.schedule.fold(0, (a, i) => a + i.amountMinor), 437800);
      expect(repo.finances!.transactions.where((t) => t.installmentPlanId == 'plan-ficticio').length, 1);

      // Undone from the tablet: the payment recorded by hand is deleted, the plan stays.
      await tester.pumpWidget(app(InstallmentDetailScreen(repository: repo, planId: 'plan-ficticio')));
      await tester.pump();
      await tester.tap(find.textContaining('1. 5 nov 2026'));
      await settle(tester, 5);
      await tester.tap(find.text('Deshacer el pago'));
      await settle(tester);
      await tester.runAsync(() async => repo = await device(phone));
      expect(repo.finances!.transactions, isEmpty);
      expect(repo.finances!.installmentPlans.single.name, 'Compra ficticia');

      if (encrypted) {
        expect(cloud.plaintextCalls, isEmpty);
        expect(cloud.requests.any((r) => r.contains('installmentPlans') || r.contains('Compra ficticia')), isFalse, reason: 'Inside the sealed envelope');
      } else {
        expect(jsonEncode(cloud.document), contains('"installmentPlans"'));
      }
      expect(tester.takeException(), isNull);
    });
  }

  test('people are kept apart: another person\'s cloud has none of these plans', () async {
    final mine = profiles.Cloud('fictitious-admin', encrypted: false, document: {...document(), 'installmentPlans': [
      {'id': 'p', 'name': 'Compra ficticia', 'accountID': 'cuenta', 'kindRaw': 'purchase', 'totalMinor': 1000, 'schedule': []}
    ]});
    final other = profiles.Cloud('fictitious-guest', encrypted: true, document: document());
    expect(Finances.fromDocument(other.document).installmentPlans, isEmpty);
    expect(Finances.fromDocument(mine.document).installmentPlans.single.id, 'p');
  });
}
