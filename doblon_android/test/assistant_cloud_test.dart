// Fictitious data only. «Pídeme algo» through the real screen (25 November 2026), for the developer's session and
// an encrypted guest: a sentence, one answer and «Confirmar» record one movement (3 steps instead of the form's 7 to
// 9); it cannot be confirmed twice; another device of the same person sees it once; «Deshacer» removes it; a reserve
// and a query work the same; and the sentence never leaves the device (the only requests are the usual saves).
import 'dart:io';

import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/screens/assistant_screen.dart';
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
      for (final key in ['institutions', 'cards', 'categoryRules', 'budgets', 'recurringBudgets', 'goals', 'importBatches', 'recurringMovements', 'reservedFunds', 'snapshots', 'transactions'])
        key: <dynamic>[],
      'categories': [
        {'id': 'rest', 'name': 'Restaurantes', 'kindRaw': 'expense'},
      ],
      'accounts': [
        {'id': 'nomina', 'name': 'Bankinter nómina', 'typeRaw': 'checking', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'openingBalanceMinor': 150000},
        {'id': 'ahorro', 'name': 'Bankinter ahorro', 'typeRaw': 'savings', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'openingBalanceMinor': 300000},
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

    testWidgets('$who: a sentence, an answer and Confirmar record one movement; undo; a reserve and a query; nothing sent', (tester) async {
      tester.view.physicalSize = const Size(500, 2000);
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
        phone = await Directory.systemTemp.createTemp('doblon-assistant-phone');
        tablet = await Directory.systemTemp.createTemp('doblon-assistant-tablet');
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
      final requestsBefore = cloud.requests.length;
      final now = DateTime(2026, 11, 25, 18);
      var steps = 0;
      Future<void> step(Future<void> Function() action) async {
        steps++;
        await action();
        await settle(tester, 5);
      }

      await tester.pumpWidget(app(AssistantScreen(repository: repo, clock: () => now)));
      await tester.pump();

      // 1. The sentence (typing and sending is one step).
      await step(() async {
        await tester.enterText(find.byType(TextField), 'He gastado 24 € cenando con la de Bankinter');
        await tester.testTextInput.receiveAction(TextInputAction.send);
      });
      expect(find.text('Tienes 2 que encajan. ¿Cuál es?'), findsOneWidget, reason: 'Two accounts named alike: asked, not guessed');
      // 2. The account.
      await step(() => tester.tap(find.widgetWithText(ActionChip, 'Bankinter nómina')));
      expect(find.textContaining('Gasto · 24,00'), findsOneWidget);
      expect(find.textContaining('Saldo de Bankinter nómina'), findsOneWidget);
      // 3. Confirmar.
      final saves = cloud.financeSaves;
      await step(() => tester.tap(find.widgetWithText(FilledButton, 'Confirmar')));
      await settle(tester);
      expect(steps, 3, reason: 'The form needs 7 to 9 interactions for the same movement');
      expect(cloud.financeSaves, saves + 1);
      expect(find.widgetWithText(FilledButton, 'Confirmar'), findsNothing, reason: 'Cannot be confirmed twice');
      final recorded = repo.finances!.transactions.single;
      expect((recorded.amountMinor, recorded.sourceAccountId, recorded.descriptionText), (2400, 'nomina', 'Cena'));

      // Another device of the same person sees it once.
      await tester.runAsync(() async => repo = await device(tablet));
      expect(repo.finances!.transactions.length, 1);

      // Back on the phone: undone.
      await tester.runAsync(() async => repo = await device(phone));
      await tester.pumpWidget(app(AssistantScreen(key: ValueKey(repo), repository: repo, clock: () => now)));
      await tester.pump();
      await step(() async {
        await tester.enterText(find.byType(TextField), 'Reserva 200 € para vacaciones en Bankinter ahorro');
        await tester.testTextInput.receiveAction(TextInputAction.send);
      });
      expect(find.textContaining('Reserva · 200,00'), findsOneWidget);
      await step(() => tester.tap(find.widgetWithText(FilledButton, 'Confirmar')));
      await settle(tester);
      expect(repo.finances!.reservedFunds.single.name, 'Vacaciones');
      await step(() => tester.tap(find.widgetWithText(TextButton, 'Deshacer')));
      await settle(tester);
      expect(repo.finances!.reservedFunds, isEmpty);

      // A query: answered on the device, nothing saved.
      final savesBefore = cloud.financeSaves;
      await step(() async {
        await tester.enterText(find.byType(TextField), '¿Cuánto he gastado este mes?');
        await tester.testTextInput.receiveAction(TextInputAction.send);
      });
      expect(find.text('Resumen de este mes'), findsOneWidget);
      expect(find.textContaining('24,00'), findsWidgets);
      expect(cloud.financeSaves, savesBefore);

      // The sentences never left the device: the only requests are the loads and saves of the finances.
      final sent = cloud.requests.skip(requestsBefore).join('\n');
      expect(sent.contains('cenando') || sent.contains('Reserva 200') || sent.contains('Cuánto he gastado'), isFalse);
      if (encrypted) {
        expect(cloud.plaintextCalls, isEmpty);
        expect(sent.contains('Bankinter'), isFalse, reason: 'A guest\'s finances stay inside the sealed envelope');
      }
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('Corregir opens the usual form already filled in, and nothing is recorded until it is saved there', (tester) async {
    tester.view.physicalSize = const Size(500, 2000);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cloud = profiles.Cloud('fictitious-admin', encrypted: false, document: document());
    late FinanceRepository repo;
    await tester.runAsync(() async {
      await cloud.prepare();
      FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
      final dir = await Directory.systemTemp.createTemp('doblon-assistant-correct');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException catch (_) {}
      });
      final client = await cloud.client();
      addTearDown(client.dispose);
      repo = FinanceRepository(store: LocalStore(dir), cloudClient: client);
      addTearDown(repo.dispose);
      await repo.refresh();
    });
    await tester.pumpWidget(app(AssistantScreen(repository: repo, clock: () => DateTime(2026, 11, 25, 18))));
    await tester.enterText(find.byType(TextField), 'Gasté 24 € cenando con Bankinter nómina');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(tester, 5);
    await tester.tap(find.widgetWithText(OutlinedButton, 'Corregir'));
    await settle(tester, 5);
    expect(find.widgetWithText(TextField, '24,00'), findsOneWidget);
    expect(find.widgetWithText(TextField, 'Cena'), findsOneWidget);
    expect(repo.finances!.transactions, isEmpty);
    expect(tester.takeException(), isNull);
  });

  testWidgets('the keyboard hides on an empty part or when scrolling, keeps the text, and a large text size does not overflow', (tester) async {
    tester.view.physicalSize = const Size(360, 740);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cloud = profiles.Cloud('fictitious-admin', encrypted: false, document: document());
    late FinanceRepository repo;
    await tester.runAsync(() async {
      await cloud.prepare();
      FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
      final dir = await Directory.systemTemp.createTemp('doblon-assistant-keyboard');
      addTearDown(() async {
        try {
          await dir.delete(recursive: true);
        } on FileSystemException catch (_) {}
      });
      final client = await cloud.client();
      addTearDown(client.dispose);
      repo = FinanceRepository(store: LocalStore(dir), cloudClient: client);
      addTearDown(repo.dispose);
      await repo.refresh();
    });
    await tester.pumpWidget(MediaQuery(
      data: const MediaQueryData(size: Size(360, 740), textScaler: TextScaler.linear(2)),
      child: app(AssistantScreen(repository: repo, clock: () => DateTime(2026, 11, 25, 18))),
    ));
    await tester.enterText(find.byType(TextField), 'He gastado 44,53 en la gasolinera con Bankinter nómina');
    await tester.testTextInput.receiveAction(TextInputAction.send);
    await settle(tester, 5);
    expect(find.textContaining('Gasto · 44,53'), findsOneWidget);
    expect(tester.takeException(), isNull, reason: 'No overflow with text at 200 %');
    // Typing again, then tapping an empty part of the conversation: the keyboard hides and the text stays.
    await tester.tap(find.byType(TextField));
    await tester.enterText(find.byType(TextField), 'eran 45');
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.tapAt(const Offset(350, 120));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    expect(find.widgetWithText(TextField, 'eran 45'), findsOneWidget);
    // Back to the field: it opens again; scrolling the conversation hides it.
    await tester.tap(find.byType(TextField));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isTrue);
    await tester.drag(find.byType(ListView), const Offset(0, 200));
    await tester.pump();
    expect(tester.testTextInput.isVisible, isFalse);
    // The buttons still answer: Confirmar records it.
    await tester.tapAt(const Offset(350, 120)); // closes the text menu the second tap on the field opened
    await tester.pump(const Duration(milliseconds: 600)); // the scroll to the last card after focusing ends
    await tester.drag(find.byType(ListView), const Offset(0, -800)); // back down to the card
    await tester.pump(const Duration(milliseconds: 300));
    await tester.tap(find.widgetWithText(FilledButton, 'Confirmar'));
    await settle(tester);
    expect(repo.finances!.transactions.single.descriptionText, 'Gasolinera');
    expect(tester.takeException(), isNull);
  });
}
