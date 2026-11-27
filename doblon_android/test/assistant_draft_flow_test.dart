// Fictitious data only. The whole path of an operation in Don Bigotes' chat (27 November 2026): the account said by its
// name or its bank, the draft being prepared corrected in place, set aside and resumed with its changes, a saved
// movement edited, the form opened from «Corregir» and what really happened there. The regression, seen on a phone:
//  - «gasto de 99 € en <banco> …» asked for the account although the bank had one current account;
//  - «ingreso de 100 € en la cuenta de <banco>» chose that account as «la que sueles usar»;
//  - «Ponle categoría Compras» on a prepared expense was read as editing a saved movement: «¿Qué movimiento quieres
//    cambiar?», and «El de 99 € de la freidora» looked for it among the saved ones;
//  - «Corregir» dropped the draft before opening the form, so nothing in the chat could still change or confirm it.
// Each turn checks the state (the draft, its id, what confirming would save), not only the words of the answer.
import 'dart:io';

import 'package:doblon/assistant.dart';
import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/assistant_screen.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'forecast_profiles_test.dart' as profiles show Cloud, seconds;

final now = DateTime(2026, 11, 27, 12);

// The order fixes the markers sent to the interpreter: CUENTA_1…CUENTA_5, CATEGORIA_1…CATEGORIA_4.
final _accounts = [
  Account(id: 'corriente', name: 'Inversión + extra', type: AccountType.checking, openingDate: DateTime(2026), institutionId: 'b1', openingBalanceMinor: 300000),
  Account(id: 'valores', name: 'Cuenta de valores', type: AccountType.investment, openingDate: DateTime(2026), institutionId: 'b1'),
  Account(id: 'nomina', name: 'Nómina + uso diario', type: AccountType.checking, openingDate: DateTime(2026), institutionId: 'b2', openingBalanceMinor: 100000),
  Account(id: 'casa', name: 'Gastos casa', type: AccountType.checking, openingDate: DateTime(2026), institutionId: 'b3'),
  Account(id: 'viajes', name: 'Ahorro viajes', type: AccountType.savings, openingDate: DateTime(2026), institutionId: 'b3'),
];
final _institutions = [Institution(id: 'b1', name: 'Banco Ficticio'), Institution(id: 'b2', name: 'Caja Inventada'), Institution(id: 'b3', name: 'Banco Doble')];
final _categories = [
  Category(id: 'compras', name: 'Compras', kind: CategoryKind.expense),
  Category(id: 'ocio', name: 'Ocio', kind: CategoryKind.expense),
  Category(id: 'otros', name: 'Otros ingresos', kind: CategoryKind.income),
  Category(id: 'sueldo', name: 'Sueldo', kind: CategoryKind.income),
];

Transaction tx(String id, String text, int amount, {TransactionType type = TransactionType.expense, required DateTime date, String account = 'nomina', String? category}) =>
    Transaction(id: id, date: date, type: type, amountMinor: amount, descriptionText: text, sourceAccountId: account, categoryId: category);

/// The person's habit: almost every expense and income from «Nómina + uso diario».
Finances data() => Finances(institutions: _institutions, accounts: _accounts, categories: _categories, transactions: [
      for (var day = 1; day <= 8; day++) tx('g$day', 'TIENDA $day', 1000 + day, date: DateTime(2026, 11, day), category: 'compras'),
      for (var day = 1; day <= 6; day++) tx('i$day', 'ABONO $day', 1500, type: TransactionType.income, date: DateTime(2026, 11, day + 10), category: 'otros'),
      tx('lampara', 'Lámpara', 3000, date: DateTime(2026, 11, 26)),
    ]);

class FakeModel {
  FakeModel(this.answers);
  final List<Map<String, Object?>?> answers;
  final received = <Map<String, Object?>>[];
  Future<RemoteInterpretation> call(Map<String, Object?> context) async {
    received.add(context);
    final next = answers.isEmpty ? null : answers.removeAt(0);
    return next == null ? (intent: null, error: 'network') : (intent: AssistantIntent.fromJson(next), error: null);
  }
}

AssistantSession session([FakeModel? model]) {
  var n = 0;
  return AssistantSession(newId: () => 'nuevo-${++n}', remote: model?.call);
}

String line(AssistantReply r, String label) => (r as AssistantPreview).lines.firstWhere((l) => l.$1 == label).$2;

/// The record confirming [p] would save (the movement's fields as stored).
Map<String, dynamic> saved(AssistantSession s, AssistantPreview p, Finances d) => Map<String, dynamic>.from(s.confirm(p, d)!.data['record'] as Map);

void main() {
  final calc = FinanceCalculator(data());

  group('the account said by its name or its bank', () {
    test('rules: a bank with one current account is that account, said, not guessed', () async {
      final s = session();
      final p = await s.say('Apunta un gasto de 99 € en Banco Ficticio con concepto Freidora mamá', calc, now) as AssistantPreview;
      expect(p.draft!.sourceAccountId, 'corriente', reason: 'Its securities account does not take an everyday expense');
      expect(line(p, 'Cuenta'), 'Inversión + extra');
    });

    test('interpreter: the bank is masked, and a wrong pick among its accounts is corrected by what was said', () async {
      final model = FakeModel([
        {'kind': 'expense', 'amount': 'N1', 'account': 'CUENTA_2', 'concept': 'Freidora mamá'},
      ]);
      final s = session(model);
      final p = await s.say('Apunta un gasto de 99€ en Banco Ficticio con concepto Freidora mamá', calc, now) as AssistantPreview;
      final sent = model.received.single['sentence'] as String;
      expect(sent, isNot(contains('Ficticio')), reason: 'A bank of the person never leaves the phone in clear');
      expect(sent, contains('CUENTA_1 o CUENTA_2'));
      expect(p.draft!.sourceAccountId, 'corriente');
      expect(line(p, 'Cuenta'), 'Inversión + extra');
    });

    test('interpreter: the exact name with symbols is taken even when the interpreter only repeats the marker as text', () async {
      final model = FakeModel([
        {'kind': 'expense', 'amount': 'N1', 'accountText': '[CUENTA_1]', 'concept': 'freidora'},
      ]);
      final s = session(model);
      final p = await s.say('Apunta 99€ de comprar una freidora en la cuenta de Inversión + extra', calc, now);
      expect(p, isA<AssistantPreview>(), reason: 'Not asked again');
      expect((p as AssistantPreview).draft!.sourceAccountId, 'corriente');
    });

    test('an account said explicitly is not presented as the usual one; one not said still is', () async {
      final s = session();
      final said = await s.say('Apunta un ingreso de 100 € con concepto Freidora mamá en la cuenta de Caja Inventada', calc, now);
      expect(line(said, 'Cuenta'), 'Nómina + uso diario', reason: 'Named by its bank: no «(la que sueles usar)»');
      final other = session();
      final guessed = await other.say('Apunta un ingreso de 100 € con concepto Regalo', calc, now);
      expect(line(guessed, 'Cuenta'), 'Nómina + uso diario (la que sueles usar)');
    });

    test('a bank with several fitting accounts asks only among them, with bank and name', () async {
      final s = session();
      final q = await s.say('he gastado 20 € en Banco Doble en la ferretería', calc, now) as AssistantQuestion;
      expect(q.options.map((o) => o.$1), ['Banco Doble · Gastos casa', 'Banco Doble · Ahorro viajes']);
      final p = await s.choose('viajes', calc, now) as AssistantPreview;
      expect(p.draft!.sourceAccountId, 'viajes');
      expect(p.draft!.amountMinor, 2000, reason: 'The amount is kept');
    });
  });

  group('correcting what is being prepared', () {
    test('interpreter: «Ponle categoría Compras» updates the draft: same id, nothing else changes, nothing set aside', () async {
      final model = FakeModel([
        {'kind': 'expense', 'amount': 'N1', 'account': 'CUENTA_1', 'concept': 'Freidora mamá'},
        {'kind': 'editMovement', 'category': 'CATEGORIA_1'},
      ]);
      final s = session(model);
      final first = await s.say('Apunta un gasto de 99 € en Banco Ficticio con concepto Freidora mamá', calc, now) as AssistantPreview;
      expect(line(first, 'Categoría'), 'Sin categoría');
      final second = await s.say('Ponle categoría Compras', calc, now);
      expect(second, isA<AssistantPreview>(), reason: 'Never «¿Qué movimiento quieres cambiar?»');
      second as AssistantPreview;
      expect(second.note, isNull, reason: 'Not set aside');
      expect(s.hasParked, isFalse);
      expect(second.id, first.id, reason: 'The same operation, corrected');
      expect(line(second, 'Categoría'), 'Compras');
      expect([second.draft!.amountMinor, second.draft!.sourceAccountId, second.draft!.description, second.draft!.date],
          [first.draft!.amountMinor, first.draft!.sourceAccountId, first.draft!.description, first.draft!.date]);
      expect(s.confirm(first, data()), isNull, reason: 'The previous card can no longer save its old version');
      final record = saved(s, second, data());
      expect([record['id'], record['amountMinor'], record['categoryID'], record['descriptionText']], [first.id, 9900, 'compras', 'Freidora mamá']);
      expect(s.confirm(second, data()), isNull, reason: 'Confirmed twice, saved once');
    });

    test('interpreter: the draft named by its amount and concept («el de 99 € de la freidora») is the draft', () async {
      final model = FakeModel([
        {'kind': 'expense', 'amount': 'N1', 'account': 'CUENTA_1', 'concept': 'Freidora'},
        {'kind': 'editMovement', 'findAmount': 'N1', 'concept': 'freidora', 'category': 'CATEGORIA_1'},
      ]);
      final s = session(model);
      final first = await s.say('Apunta 99 € en Banco Ficticio, una freidora', calc, now) as AssistantPreview;
      final second = await s.say('El de 99 € de la freidora ponlo en Compras', calc, now) as AssistantPreview;
      expect(second.id, first.id);
      expect(line(second, 'Categoría'), 'Compras');
      expect(line(second, 'Concepto'), 'Freidora', reason: 'Naming it is not renaming it');
    });

    test('interpreter: other wordings and kinds of reading (categorise, describe) also correct the draft', () async {
      for (final reading in [
        {'kind': 'categorize', 'category': 'CATEGORIA_2'},
        {'kind': 'describeExisting', 'role': 'category', 'category': 'CATEGORIA_2'},
        {'kind': 'correction', 'category': 'CATEGORIA_2'},
      ]) {
        final model = FakeModel([
          {'kind': 'expense', 'amount': 'N1', 'concept': 'Entradas'},
          reading,
        ]);
        final s = session(model);
        final first = await s.say('gasté 30 en entradas', calc, now) as AssistantPreview;
        final second = await s.say('mejor mételo en ocio', calc, now) as AssistantPreview;
        expect([second.id, line(second, 'Categoría')], [first.id, 'Ocio'], reason: '${reading['kind']}');
      }
    });

    test('rules, with misspellings: the category changes and the concept stays', () async {
      for (final sentence in ['Ponle categoría Compras', 'ponle la categoria conpras', 'categoría compras', 'cambia la categoría a Compras']) {
        final s = session();
        final first = await s.say('Apunta un gasto de 99 € con concepto Freidora mamá', calc, now) as AssistantPreview;
        final second = await s.say(sentence, calc, now);
        expect(second, isA<AssistantPreview>(), reason: sentence);
        expect([line(second, 'Categoría'), line(second, 'Concepto'), (second as AssistantPreview).id], ['Compras', 'Freidora mamá', first.id], reason: sentence);
      }
    });

    test('a saved movement is edited when it is the one named (another amount), and the draft comes back intact', () async {
      final model = FakeModel([
        {'kind': 'expense', 'amount': 'N1', 'account': 'CUENTA_3', 'concept': 'Freidora'},
        {'kind': 'editMovement', 'category': 'CATEGORIA_1'},
        {'kind': 'editMovement', 'findAmount': 'N1', 'category': 'CATEGORIA_2'},
      ]);
      final s = session(model);
      final first = await s.say('Apunta 99 € en Caja Inventada, una freidora', calc, now) as AssistantPreview;
      await s.say('Ponle categoría Compras', calc, now);
      final edit = await s.say('La lámpara de 30 € de ayer era ocio', calc, now) as AssistantPreview;
      expect(edit.kind, PreviewKind.existing);
      expect(edit.targetId, 'lampara');
      expect(edit.note, startsWith('Dejo aparte el gasto de 99,00'), reason: 'Another movement: what was being prepared is set aside, said');
      final back = await s.resume(calc, now) as AssistantPreview;
      expect([back.id, line(back, 'Categoría'), back.draft!.amountMinor], [first.id, 'Compras', 9900], reason: 'Its last version, with the category');
    });

    test('with nothing being prepared, a change goes to the saved movement', () async {
      final model = FakeModel([
        {'kind': 'editMovement', 'findAmount': 'N1', 'category': 'CATEGORIA_2'},
      ]);
      final s = session(model);
      final edit = await s.say('Cambia la categoría del de 30 € a Ocio', calc, now) as AssistantPreview;
      expect([edit.kind, edit.targetId], [PreviewKind.existing, 'lampara']);
    });

    test('rules: set aside and resumed keeps the change made before', () async {
      final s = session();
      final first = await s.say('Apunta un gasto de 99 € con concepto Freidora', calc, now) as AssistantPreview;
      await s.say('categoría compras', calc, now);
      final aside = await s.say('por cierto, ¿qué tengo sin categoría?', calc, now);
      expect(aside.note, startsWith('Dejo aparte'));
      final back = await s.resume(calc, now) as AssistantPreview;
      expect([back.id, line(back, 'Categoría'), line(back, 'Concepto')], [first.id, 'Compras', 'Freidora']);
    });

    test('two operations with the same concept are never mixed', () async {
      final model = FakeModel([
        {'kind': 'expense', 'amount': 'N1', 'account': 'CUENTA_1', 'concept': 'Freidora mamá'},
        {'kind': 'income', 'amount': 'N1', 'account': 'CUENTA_3', 'concept': 'Freidora mamá'},
        {'kind': 'editMovement', 'category': 'CATEGORIA_3'},
      ]);
      final s = session(model);
      final expense = await s.say('Apunta un gasto de 99€ en Banco Ficticio con concepto Freidora mamá', calc, now) as AssistantPreview;
      final income = await s.say('Apunta un ingreso de 100€ con concepto Freidora mamá en la cuenta de Caja Inventada', calc, now) as AssistantPreview;
      expect(income.id, isNot(expense.id));
      expect([income.draft!.type, income.draft!.amountMinor, income.draft!.sourceAccountId], [TransactionType.income, 10000, 'nomina']);
      final corrected = await s.say('Categoría Otros ingresos', calc, now) as AssistantPreview;
      expect([corrected.id, line(corrected, 'Categoría'), corrected.draft!.amountMinor], [income.id, 'Otros ingresos', 10000]);
      final savedIncome = saved(s, corrected, data());
      final back = await s.resume(calc, now) as AssistantPreview;
      expect([back.id, back.draft!.type, back.draft!.amountMinor, line(back, 'Categoría')], [expense.id, TransactionType.expense, 9900, 'Sin categoría']);
      final savedExpense = saved(s, back, data());
      expect({savedIncome['id'], savedExpense['id']}, hasLength(2), reason: 'Two records, one each');
    });

    test('nothing reaches the balances before confirming, however many corrections and resumptions', () async {
      final s = session();
      final d = data();
      final before = FinanceCalculator(d).balance(d.account('nomina')!);
      await s.say('Apunta un gasto de 99 € con concepto Freidora', calc, now);
      await s.say('categoría compras', calc, now);
      await s.say('fue ayer', calc, now);
      await s.say('¿qué tengo sin categoría?', calc, now);
      await s.resume(calc, now);
      expect(FinanceCalculator(d).balance(d.account('nomina')!), before);
      expect(d.transactions.where((t) => t.descriptionText == 'Freidora'), isEmpty);
    });
  });

  group('«Corregir» opens the same draft in the form, for the developer and a guest', () {
    setUpAll(() => initializeDateFormatting('es'));
    setUp(() {
      runTraining = <T>(T Function() work) async => work();
      CloudPrivacy.forgetAll();
      SharedPreferences.setMockInitialValues({});
    });

    Map<String, dynamic> document() => {
          'formatVersion': 2,
          for (final key in ['cards', 'categoryRules', 'budgets', 'recurringBudgets', 'goals', 'importBatches', 'recurringMovements', 'reservedFunds', 'snapshots'])
            key: <dynamic>[],
          'institutions': [
            {'id': 'b2', 'name': 'Caja Inventada'},
          ],
          'categories': [
            {'id': 'compras', 'name': 'Compras', 'kindRaw': 'expense'},
          ],
          'accounts': [
            {
              'id': 'nomina',
              'name': 'Nómina + uso diario',
              'typeRaw': 'checking',
              'institutionID': 'b2',
              'openingDate': profiles.seconds(DateTime(2026)),
              'currencyCode': 'EUR',
              'openingBalanceMinor': 150000,
            },
          ],
          'transactions': <dynamic>[],
        };

    Future<void> settle(WidgetTester tester, [int rounds = 20]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    Future<void> waitFor(WidgetTester tester, Finder finder) async {
      for (var i = 0; i < 500 && finder.evaluate().isEmpty; i++) {
        await settle(tester, 2);
      }
      await settle(tester, 5);
    }

    for (final encrypted in [false, true]) {
      testWidgets('${encrypted ? 'guest' : 'developer'}: closed without saving keeps the card; saved there is said, linked and never saved twice', (tester) async {
        tester.view.physicalSize = const Size(420, 1600);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: document());
        late FinanceRepository repo;
        await tester.runAsync(() async {
          await cloud.prepare();
          FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
          final dir = await Directory.systemTemp.createTemp('doblon-draft-flow');
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
        expect(repo.isAdministrator, !encrypted);
        await tester.pumpWidget(MaterialApp(
          theme: doblonTheme(Brightness.dark),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: AssistantScreen(repository: repo, clock: () => now),
        ));
        await tester.pump();
        int freidoras() => repo.finances!.transactions.where((t) => t.descriptionText == 'Freidora').length;

        await tester.enterText(find.byType(TextField), 'Apunta un gasto de 99 € en Caja Inventada con concepto Freidora');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await waitFor(tester, find.text('Preparado · sin guardar'));
        expect(find.textContaining('Nómina + uso diario'), findsWidgets);
        expect(find.textContaining('la que sueles usar'), findsNothing, reason: 'The account was said');

        // Opened and closed without saving: nothing saved, the same card can still be confirmed or corrected.
        await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Corregir'));
        await tester.tap(find.widgetWithText(OutlinedButton, 'Corregir'));
        await settle(tester, 5);
        expect(find.text('Nuevo movimiento'), findsOneWidget);
        await tester.tap(find.byType(BackButton));
        await waitFor(tester, find.textContaining('Has cerrado el formulario sin guardar'));
        expect(find.textContaining('la tarjeta sigue pendiente aquí'), findsOneWidget);
        expect(find.text('Preparado · sin guardar'), findsOneWidget);
        expect(find.textContaining('Abierto en el formulario'), findsNothing, reason: 'Never said before it happens');
        expect(freidoras(), 0);

        // Corrected in the chat while it is still the same draft.
        await tester.enterText(find.byType(TextField), 'categoría compras');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await waitFor(tester, find.text('Sustituido'));
        expect(find.text('Preparado · sin guardar'), findsOneWidget, reason: 'Only the current version is active');

        // Opened again and saved there: one movement, with the draft's data; said, with a link; no Confirmar left.
        await tester.ensureVisible(find.widgetWithText(OutlinedButton, 'Corregir'));
        await tester.tap(find.widgetWithText(OutlinedButton, 'Corregir'));
        await settle(tester, 5);
        await tester.ensureVisible(find.text('Guardar movimiento'));
        await tester.tap(find.text('Guardar movimiento'));
        await waitFor(tester, find.text('Guardado desde el formulario'));
        expect(freidoras(), 1);
        final record = repo.finances!.transactions.firstWhere((t) => t.descriptionText == 'Freidora');
        expect([record.amountMinor, record.categoryId, record.sourceAccountId], [9900, 'compras', 'nomina']);
        expect(find.textContaining('Gasto · 99,00'), findsWidgets);
        expect(find.widgetWithText(FilledButton, 'Confirmar'), findsNothing, reason: 'No old card can save it again');
        expect(tester.takeException(), isNull);
        await settle(tester);
        await tester.pump(const Duration(seconds: 3));
        await settle(tester, 5);
        expect(freidoras(), 1);
      });
    }
  });
}
