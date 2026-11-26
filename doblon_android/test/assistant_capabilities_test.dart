// Fictitious data only. Don Bigotes' conversational architecture (26 November 2026): a request is an action on a
// selection of movements, and a follow-up changes only what it states. The regression that motivated it: «Tengo
// movimientos sin categorías, ¿puedes ponérselas?» was answered with every movement of the month, and «No, pero los
// que no tienen categoría» with the month's expenses (categorised ones included). These conversations use other
// phrasings, misspellings, corrections, changes of subject and combined requests, with the rules alone, with the
// interpreter (faked) and with the interpreter failing; they check the action, the selection and what is executed.
import 'dart:io';

import 'package:doblon/assistant.dart';
import 'package:doblon/auto_category.dart';
import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/edits.dart' show Operation;
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

final now = DateTime(2026, 11, 26, 10);

Transaction tx(String id, String text, int amount,
        {String? category, TransactionType type = TransactionType.expense, DateTime? date, String account = 'nomina', String? to, bool bank = true}) =>
    Transaction(
      id: id,
      date: date ?? DateTime(2026, 11, 25),
      type: type,
      amountMinor: amount,
      descriptionText: text,
      sourceAccountId: account,
      destinationAccountId: to,
      categoryId: category,
      bankEntryKey: bank ? 'enable-entry:s:a:$id' : null,
    );

Finances data() => Finances(
      accounts: [
        Account(id: 'nomina', name: 'Nómina ficticia', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 200000),
        Account(id: 'inversion', name: 'Inversión ficticia', type: AccountType.savings, openingDate: DateTime(2026), openingBalanceMinor: 500000),
      ],
      categories: [
        Category(id: 'super', name: 'Supermercado', kind: CategoryKind.expense),
        Category(id: 'rest', name: 'Restaurantes', kind: CategoryKind.expense),
        Category(id: 'ocio', name: 'Ocio', kind: CategoryKind.expense),
        Category(id: 'sueldo', name: 'Sueldo', kind: CategoryKind.income),
      ],
      transactions: [
        tx('cafe', 'CAFETERIA FICTICIA', 825, category: 'rest', date: DateTime(2026, 11, 24)),
        tx('h1', 'PANADERIA LUNA', 300, category: 'super', date: DateTime(2026, 10, 3)),
        tx('h2', 'PANADERIA LUNA', 350, category: 'super', date: DateTime(2026, 10, 17)),
        tx('pan', 'PANADERIA LUNA', 450), // the person's own history says Supermercado
        tx('cine', 'CINES FICTICIOS', 900), // only the learning proposes one
        tx('generico', 'Movimiento bancario', 4453, account: 'inversion'), // only amount and date: never guessed
        tx('entrada', 'Movimiento bancario', 437800, type: TransactionType.income, account: 'inversion'),
        tx('libro', 'LIBRERIA PAPEL', 1200, date: DateTime(2026, 10, 15)), // last month: no period was said
        tx('traspaso', 'Traspaso propio', 5000, type: TransactionType.transfer, to: 'inversion'), // takes no category
      ],
    );

/// What the repository does with the person's evidence, faked over the same data (rules and history).
Future<List<String>> evidence(Set<String> ids) async => [for (final a in autoCategories(data())) if (ids.contains(a.transactionId)) a.transactionId];

/// The learning's proposal, faked: it only knows cinemas.
Future<(String, String)?> learning(String text, TransactionType type) async => text.toLowerCase().contains('cines') ? ('ocio', 'model') : null;

class FakeModel {
  FakeModel(this.answers);
  final List<RemoteInterpretation> answers;
  final received = <Map<String, Object?>>[];
  Future<RemoteInterpretation> call(Map<String, Object?> context) async {
    received.add(context);
    return answers.isEmpty ? (intent: null, error: 'assistant_unavailable') : answers.removeAt(0);
  }
}

RemoteInterpretation said(Map<String, Object?> json) => (intent: AssistantIntent.fromJson(json), error: null);

AssistantSession session({FakeModel? model}) {
  var n = 0;
  return AssistantSession(newId: () => 'nuevo-${++n}', propose: learning, applyEvidence: evidence, remote: model?.call);
}

Set<String> ids(AssistantReply r) => {for (final t in (r as AssistantResult).transactions) t.id};

void main() {
  final calc = FinanceCalculator(data());

  group('the regression of the screenshots, as conversations', () {
    void expectCategorized(AssistantReply reply) {
      final result = reply as AssistantResult;
      expect(result.title, startsWith('Poner categoría'), reason: 'Categorising is an action, never a list');
      expect(result.automatic, ['pan'], reason: 'The person\'s own history is applied, with provenance and undo');
      expect(ids(result), {'generico', 'entrada', 'libro'},
          reason: 'Only what has no evidence is asked: income too (not only expenses), last month too (no month imposed)');
      expect(ids(result), isNot(contains('cafe')), reason: 'Never a movement that already has a category');
      expect(ids(result), isNot(contains('traspaso')), reason: 'A transfer between own accounts takes no category');
      final proposals = result.followUps.single as AssistantPreview;
      expect(proposals.kind, PreviewKind.categories);
      expect(proposals.assignments, [('cine', 'ocio', 'model')], reason: 'The learning\'s guess is proposed, to confirm with one tap');
    }

    test('with the rules alone: the request categorises, and the clarification keeps the action and its condition', () async {
      final s = session();
      expectCategorized(await s.say('Tengo movimientos sin categorías puedes ponérselas?', calc, now));
      final again = await s.say('No pero los que no tienen categoría', calc, now) as AssistantResult;
      expect(again.title, startsWith('Poner categoría'), reason: 'A clarification of a categorisation is still one');
      expect(ids(again), isNot(contains('cafe')));
      expect(ids(again), contains('entrada'), reason: 'Not narrowed to expenses');
    });

    test('a list corrected to «without category» keeps all movements and every date', () async {
      final s = session();
      final all = await s.say('enséñame los movimientos', calc, now) as AssistantResult;
      expect(all.lines, contains('No has dicho periodo: te enseño este mes.'), reason: 'A default scope is said');
      expect(ids(all), containsAll(['cafe', 'pan', 'entrada']));
      final narrowed = await s.say('no, solo los que no tienen categoria', calc, now) as AssistantResult;
      expect(narrowed.title, 'Movimientos sin categoría de cualquier fecha');
      expect(ids(narrowed), {'pan', 'cine', 'generico', 'entrada', 'libro'});
      final expenses = await s.say('y solo los gastos', calc, now) as AssistantResult;
      expect(ids(expenses), {'pan', 'cine', 'generico', 'libro'}, reason: 'Only the type changes; «sin categoría» stays');
      final lastMonth = await s.say('¿y el mes pasado?', calc, now) as AssistantResult;
      expect(ids(lastMonth), {'libro'}, reason: 'Only the period changes');
    });

    test('other phrasings and misspellings reach the same action with the right selection', () async {
      for (final (sentence, expected) in [
        ('¿Puedes organizar los gastos sin clasificar?', {'generico', 'libro'}),
        ('ponle categoria a los q no tienen', {'generico', 'entrada', 'libro'}),
        ('clasifica lo del mes pasado', {'libro'}),
        ('Rellena las categorías que faltan, porfa', {'generico', 'entrada', 'libro'}),
      ]) {
        final reply = await session().say(sentence, calc, now) as AssistantResult;
        expect(reply.title, startsWith('Poner categoría'), reason: sentence);
        expect(ids(reply), expected, reason: sentence);
      }
    });

    test('an action the chat does not have is said, never replaced by another one', () async {
      final reply = await session().say('borra los movimientos de ayer', calc, now) as AssistantMessage;
      expect(reply.text, startsWith('Eso no puedo hacerlo desde el chat'));
    });
  });

  group('with the interpreter', () {
    test('its capability and its correction; the context carries the last request with its conditions', () async {
      final model = FakeModel([
        said({'kind': 'categorize', 'uncategorized': true}),
        said({'kind': 'categorize', 'refine': true, 'scope': 'expenses'}),
      ]);
      final s = session(model: model);
      final first = await s.say('me ayudas con lo que está sin categorizar?', calc, now) as AssistantResult;
      expect(first.title, startsWith('Poner categoría'));
      final second = await s.say('vale pero solo con los gastos', calc, now) as AssistantResult;
      expect(model.received[1]['lastQuery'], 'poner categoría: Movimientos sin categoría de cualquier fecha');
      expect(ids(second), {'generico', 'libro'}, reason: 'The correction changed only the type');
    });

    test('an interpreter that reads it as a query (or an older one without the capability) does not turn it into a list', () async {
      final model = FakeModel([said({'kind': 'listMovements', 'scope': 'all'})]);
      final reply = await session(model: model).say('Tengo movimientos sin categorías puedes ponérselas?', calc, now) as AssistantResult;
      expect(reply.title, startsWith('Poner categoría'));
      expect(reply.automatic, ['pan']);
    });

    test('when it fails the rules do the same, and say so', () async {
      final reply = await session(model: FakeModel([])).say('Tengo movimientos sin categorías puedes ponérselas?', calc, now) as AssistantResult;
      expect(reply.title, startsWith('Poner categoría'));
      expect(reply.note, 'El intérprete no ha respondido: lo interpreto con mis reglas.');
    });

    test('a combined request runs its steps in order, within limits; a second thing to confirm waits', () async {
      final model = FakeModel([
        said({
          'kind': 'listMovements',
          'uncategorized': true,
          'also': [
            {'kind': 'categorize', 'uncategorized': true}
          ]
        }),
        said({
          'kind': 'expense',
          'amountMinor': 2000,
          'concept': 'Comida',
          'also': [
            {'kind': 'summary'},
            {'kind': 'reserve', 'amountMinor': 5000, 'purpose': 'Viaje'},
          ]
        }),
      ]);
      final s = session(model: model);
      final list = await s.say('enséñame los sin categoría y pónselas', calc, now) as AssistantResult;
      expect(list.title, 'Movimientos sin categoría de cualquier fecha');
      expect((list.followUps.first as AssistantResult).title, startsWith('Poner categoría'));
      final expense = await s.say('apunta 20 € de comida, dime cómo voy y reserva 50 para el viaje', calc, now);
      expect(expense, isA<AssistantQuestion>(), reason: 'The expense asks its account first');
      expect((expense.followUps[0] as AssistantResult).title, startsWith('Resumen'));
      expect((expense.followUps[1] as AssistantMessage).text, startsWith('La reserva que también pediste lo preparo cuando termines'));
      expect(s.hasParked, isFalse, reason: 'The expense was not set aside by its own steps');
    });

    test('topic changes keep each thing: a draft set aside comes back intact', () async {
      final s = session();
      await s.say('he gastado 12 € en un café', calc, now);
      final aside = await s.say('por cierto, ¿qué tengo sin categoría?', calc, now) as AssistantResult;
      expect(aside.note, startsWith('Dejo aparte el gasto de 12,00'));
      expect(ids(aside), isNot(contains('cafe')));
      final back = await s.resume(calc, now) as AssistantQuestion;
      expect(back.text, contains('cuenta'), reason: 'The expense comes back with its amount, asking what was missing');
    });
  });

  group('what categorising executes', () {
    test('only categories, only on movements still without one, once; undo puts back only what it set', () async {
      final s = session();
      final result = await s.say('pon categoría a lo que no tiene', calc, now) as AssistantResult;
      final proposals = result.followUps.single as AssistantPreview;
      final op = s.confirm(proposals, data())!;
      final ops = [for (final o in op.data['ops'] as List) Operation.fromJson(Map<String, dynamic>.from(o as Map))];
      expect([for (final o in ops) '${o.kind} ${o.data['id']} ${(o.data['fields'] as Map).keys.toList()..sort()}'], ['patch cine [categoryID, updatedAt]'],
          reason: 'No amount, date or new movement is ever touched');
      expect(s.confirm(proposals, data()), isNull, reason: 'Never applied twice');

      final again = session();
      final card = ((await again.say('pon categoría a lo que no tiene', calc, now)) as AssistantResult).followUps.single as AssistantPreview;
      final chosenMeanwhile = Finances(
          accounts: data().accounts,
          categories: data().categories,
          transactions: [for (final t in data().transactions) t.id == 'cine' ? tx('cine', 'CINES FICTICIOS', 900, category: 'rest') : t]);
      expect(again.confirm(card, chosenMeanwhile), isNull, reason: 'A category chosen meanwhile is never overwritten');

      final applied = Finances(
          accounts: data().accounts,
          categories: data().categories,
          transactions: [for (final t in data().transactions) t.id == 'cine' ? tx('cine', 'CINES FICTICIOS', 900, category: 'ocio') : t]);
      final undo = s.undo(proposals, applied, now)!;
      expect(((undo.data['ops'] as List).single as Map)['data']['fields'], containsPair('categoryID', null));
    });

    test('nothing left without category: said, nothing executed', () async {
      final tidy = FinanceCalculator(Finances(accounts: data().accounts, categories: data().categories, transactions: [tx('cafe', 'CAFETERIA FICTICIA', 825, category: 'rest')]));
      final reply = await session().say('ponles categoría', tidy, now) as AssistantResult;
      expect(reply.lines.first, 'No hay ninguno sin categoría.');
      expect(reply.followUps, isEmpty);
    });
  });

  group('through the real screen, for the developer and a guest', () {
    setUpAll(() => initializeDateFormatting('es'));
    setUp(() {
      runTraining = <T>(T Function() work) async => work();
      CloudPrivacy.forgetAll();
      SharedPreferences.setMockInitialValues({});
    });

    Map<String, dynamic> record(String id, int day, String? category) => {
          'id': id,
          'date': profiles.seconds(DateTime(2026, 11, day)),
          'typeRaw': 'expense',
          'amountMinor': 450,
          'descriptionText': 'PANADERIA LUNA',
          'sourceAccountID': 'nomina',
          'categoryID': category,
          'bankEntryKey': 'enable-entry:s:a:$id',
        };

    Map<String, dynamic> document() => {
          'formatVersion': 2,
          for (final key in ['institutions', 'cards', 'categoryRules', 'budgets', 'recurringBudgets', 'goals', 'importBatches', 'recurringMovements', 'reservedFunds', 'snapshots'])
            key: <dynamic>[],
          'categories': [
            {'id': 'super', 'name': 'Supermercado', 'kindRaw': 'expense'},
          ],
          'accounts': [
            {'id': 'nomina', 'name': 'Nómina ficticia', 'typeRaw': 'checking', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'openingBalanceMinor': 150000},
          ],
          'transactions': [for (final (id, day) in [('h1', 3), ('h2', 10)]) record(id, day, 'super')],
        };

    Future<void> settle(WidgetTester tester, [int rounds = 20]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    for (final encrypted in [false, true]) {
      testWidgets('${encrypted ? 'guest' : 'developer'}: «ponles categoría» assigns from their history, saved once; undo takes it back', (tester) async {
        tester.view.physicalSize = const Size(500, 2000);
        tester.view.devicePixelRatio = 1;
        addTearDown(tester.view.reset);
        final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: document());
        late FinanceRepository repo;
        await tester.runAsync(() async {
          await cloud.prepare();
          FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
          final dir = await Directory.systemTemp.createTemp('doblon-capabilities');
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
          // A new movement after opening (opening the app already assigns what it can): the chat assigns it.
          await repo.apply(Operation('insert', {'record': record('pan', 25, null)}));
        });
        expect(repo.isAdministrator, !encrypted);
        await tester.pumpWidget(MaterialApp(
          theme: doblonTheme(Brightness.light),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: AssistantScreen(repository: repo, clock: () => now),
        ));
        await tester.pump();
        final saves = cloud.financeSaves;
        await tester.enterText(find.byType(TextField), 'Tengo movimientos sin categorías, ¿puedes ponérselas?');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await settle(tester);
        expect(find.textContaining('He puesto categoría a 1'), findsOneWidget);
        expect(repo.finances!.transactions.firstWhere((t) => t.id == 'pan').categoryId, 'super');
        expect(cloud.financeSaves, saves + 1, reason: 'Saved once');
        await tester.tap(find.text('Deshacer las 1 automáticas'));
        await settle(tester);
        expect(repo.finances!.transactions.firstWhere((t) => t.id == 'pan').categoryId, isNull);
        expect(AutoCategoryStore.instance.rejected, contains('pan'), reason: 'Taken back: not assigned again');
      });
    }
  });
}
