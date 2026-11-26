// Fictitious data only. Don Bigotes' conversational architecture (26 November 2026): a request is an action on a
// selection of movements (conditions, most recent first, how many), and a follow-up changes only what it states.
// Two regressions motivated it:
//  - «Tengo movimientos sin categorías, ¿puedes ponérselas?» was answered with every movement of the month, and «No,
//    pero los que no tienen categoría» with the month's expenses (categorised ones included);
//  - «¿Me puedes poner categoría a los últimos 4 movimientos que no tengan?» worked on all 45 without category and
//    repeated them in a second list: the number was lost (no field for it) and «4» was read as 4 €.
// The conversations below use other phrasings, misspellings, corrections, changes of subject and combined requests,
// with the rules alone, with the interpreter (faked) and with it failing. They check the movements selected, shown
// and modified, not only the words of the answer.
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

final _accounts = [
  Account(id: 'nomina', name: 'Nómina ficticia', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 200000),
  Account(id: 'inversion', name: 'Inversión ficticia', type: AccountType.savings, openingDate: DateTime(2026), openingBalanceMinor: 500000),
];
final _categories = [
  Category(id: 'super', name: 'Supermercado', kind: CategoryKind.expense),
  Category(id: 'rest', name: 'Restaurantes', kind: CategoryKind.expense),
  Category(id: 'ocio', name: 'Ocio', kind: CategoryKind.expense),
  Category(id: 'fuel', name: 'Combustible', kind: CategoryKind.expense),
  Category(id: 'sueldo', name: 'Sueldo', kind: CategoryKind.income),
];

List<Transaction> _base() => [
      tx('cafe', 'CAFETERIA FICTICIA', 825, category: 'rest', date: DateTime(2026, 11, 24)),
      tx('h1', 'PANADERIA LUNA', 300, category: 'super', date: DateTime(2026, 10, 3)),
      tx('h2', 'PANADERIA LUNA', 350, category: 'super', date: DateTime(2026, 10, 17)),
      tx('pan', 'PANADERIA LUNA', 450), // the person's own history says Supermercado
      tx('cine', 'CINES FICTICIOS', 900), // only the learning proposes one
      tx('generico', 'Movimiento bancario', 4453, account: 'inversion'), // only amount and date: never guessed
      tx('entrada', 'Movimiento bancario', 437800, type: TransactionType.income, account: 'inversion'),
      tx('libro', 'LIBRERIA PAPEL', 1200, date: DateTime(2026, 10, 15)), // last month: no period was said
      tx('traspaso', 'Traspaso propio', 5000, type: TransactionType.transfer, to: 'inversion'), // takes no category
    ];

Finances data([List<Transaction>? transactions]) => Finances(accounts: _accounts, categories: _categories, transactions: transactions ?? _base());

/// Many movements: twelve without category on different days, with categorised ones in between.
Finances many() => data([
      for (var day = 1; day <= 12; day++) ...[
        tx('sin-$day', 'TIENDA NUMERO $day', 100 * day, date: DateTime(2026, 11, day)),
        tx('con-$day', 'CAFETERIA FICTICIA', 500, category: 'rest', date: DateTime(2026, 11, day, 1)),
      ],
      tx('h1', 'PANADERIA LUNA', 300, category: 'super', date: DateTime(2026, 9, 3)),
      tx('h2', 'PANADERIA LUNA', 350, category: 'super', date: DateTime(2026, 9, 17)),
      tx('pan', 'PANADERIA LUNA', 450, date: DateTime(2026, 11, 11)),
      tx('cine', 'CINES FICTICIOS', 900, date: DateTime(2026, 11, 10)),
      tx('generico', 'Movimiento bancario', 4453, account: 'inversion', date: DateTime(2026, 11, 12)),
    ]);

/// What the repository does with the person's evidence (their rules and history), faked over the same data.
Future<List<AutoCategory>> Function(Set<String>) evidenceOver(Finances d) =>
    (ids) async => [for (final a in autoCategories(d)) if (ids.contains(a.transactionId)) a];

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

AssistantSession session({FakeModel? model, Finances? over}) {
  var n = 0;
  return AssistantSession(newId: () => 'nuevo-${++n}', propose: learning, applyEvidence: evidenceOver(over ?? data()), remote: model?.call);
}

Set<String> ids(AssistantReply r) => {for (final t in (r as AssistantResult).transactions) t.id};

/// The movements a categorisation works on, in the order shown.
List<String> shown(AssistantReply r) => [for (final i in (r as AssistantPreview).items) i.transaction.id];

/// The movements that confirming would modify, and to which category.
Map<String, String> saves(AssistantSession s, AssistantPreview p, Finances d) {
  final op = s.confirm(p, d);
  if (op == null) return {};
  return {
    for (final o in op.data['ops'] as List)
      ((o as Map)['data'] as Map)['id'] as String: ((o['data'] as Map)['fields'] as Map)['categoryID'] as String,
  };
}

void main() {
  final calc = FinanceCalculator(data());

  group('the first regression, as conversations', () {
    test('with the rules alone: the request categorises, and the clarification keeps the action and its condition', () async {
      final s = session();
      final reply = await s.say('Tengo movimientos sin categorías puedes ponérselas?', calc, now) as AssistantPreview;
      expect(reply.kind, PreviewKind.categories, reason: 'Categorising is an action, never a list');
      expect(shown(reply), ['pan', 'generico', 'entrada', 'cine', 'libro'],
          reason: 'Most recent first, stable on the same day; income too; last month too (no month imposed); never a categorised one or a transfer');
      expect(reply.automatic, ['pan'], reason: 'The person\'s own history is applied, with provenance and undo');
      expect(reply.assignments, [('cine', 'ocio', 'model')], reason: 'The learning\'s guess is proposed, to confirm');
      expect(reply.followUps, isEmpty, reason: 'No second list repeating them');
      final again = await s.say('No pero los que no tienen categoría', calc, now) as AssistantPreview;
      expect(again.kind, PreviewKind.categories, reason: 'A clarification of a categorisation is still one');
      expect(shown(again), contains('entrada'), reason: 'Not narrowed to expenses');
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
        ('¿Puedes organizar los gastos sin clasificar?', {'pan', 'cine', 'generico', 'libro'}),
        ('ponle categoria a los q no tienen', {'pan', 'cine', 'generico', 'entrada', 'libro'}),
        ('clasifica lo del mes pasado', {'libro'}),
        ('Rellena las categorías que faltan, porfa', {'pan', 'cine', 'generico', 'entrada', 'libro'}),
      ]) {
        final reply = await session().say(sentence, calc, now);
        expect(reply, isA<AssistantPreview>(), reason: sentence);
        expect(shown(reply).toSet(), expected, reason: sentence);
      }
    });

    test('an action the chat does not have is said, never replaced by another one', () async {
      // Without the interpreter, deleting is not understood: said, with where to do it.
      final rules = await session().say('borra los movimientos de ayer', calc, now) as AssistantMessage;
      expect(rules.text, startsWith('Sin el intérprete no puedo borrar'));
      // With it, what the app does not have at all (moving real money) is said and never turned into something else.
      final model = FakeModel([said({'kind': 'unsupported', 'purpose': 'enviar dinero a otra persona'})]);
      final reply = await session(model: model).say('mándale 50 pavos a mi hermano por el banco', calc, now) as AssistantMessage;
      expect(reply.text, startsWith('Eso no puedo hacerlo desde el chat («enviar dinero a otra persona»)'));
    });
  });

  group('how many: the selection keeps its number up to saving', () {
    final busy = FinanceCalculator(many());

    test('the four most recent without category among many, categorised ones in between excluded; one of them without data stays', () async {
      final s = session(over: many());
      final reply = await s.say('clasifícame los cuatro más recientes que estén sin categoría', busy, now) as AssistantPreview;
      expect(shown(reply), ['sin-12', 'generico', 'sin-11', 'pan'],
          reason: 'Most recent first; the same day keeps a stable order; no categorised one; exactly four');
      final generic = reply.items.firstWhere((i) => i.transaction.id == 'generico');
      expect(generic.categoryId, isNull, reason: 'Without data it stays in the selection, pending, not replaced by an older one');
      expect(reply.automatic, ['pan']);
      expect(reply.title, 'Los 4 últimos sin categoría');
      expect(saves(s, reply, many()), isEmpty, reason: 'Nothing proposed among these four: nothing else is saved');
    });

    test('other numbers and ways of saying it', () async {
      for (final (sentence, count) in [
        ('pon categoría solo a los 3 últimos que no tienen', 3),
        ('categoriza el último que no tenga', 1),
        ('a los dos más recientes sin categoría ponles una', 2),
        ('ponles categoría a los 6 últimos movimientos sin categoría', 6),
      ]) {
        final reply = await session(over: many()).say(sentence, busy, now) as AssistantPreview;
        expect(reply.items, hasLength(count), reason: sentence);
        expect(shown(reply).first, 'sin-12', reason: sentence);
      }
    });

    test('a number of movements is never an amount, and «4 €» is never a number of movements', () {
      expect(Signals('¿Me pones categoría a los últimos 4 que no tienen?', now).amountMinor, isNull);
      expect(Signals('¿Me pones categoría a los últimos 4 que no tienen?', now).limit, 4);
      expect(Signals('solo estos dos', now).limit, 2);
      expect(Signals('he gastado 4 € en pan', now).limit, isNull);
      expect(Signals('he gastado 4 € en pan', now).amountMinor, 400);
      expect(Signals('4.378 € en 12 meses', now).limit, isNull);
    });

    test('fewer than asked: works with those and says so', () async {
      final reply = await session().say('ponme categoría a los diez últimos sin categoría de noviembre... bueno, de este mes', calc, now) as AssistantPreview;
      expect(shown(reply), ['pan', 'generico', 'entrada', 'cine']);
      expect(reply.effects, contains('Solo hay 4 sin categoría este mes.'));
    });

    test('a correction of the number narrows the selection; the earlier card can no longer be confirmed', () async {
      final s = session(over: many());
      final first = await s.say('ponles categoría a los que no tienen', busy, now) as AssistantPreview;
      expect(first.items, hasLength(AssistantSession.categorizeBatch), reason: 'Without a number: the most recent ten, said');
      expect(first.effects.join(' '), contains('Hay 15 sin categoría'));
      final narrowed = await s.say('no, solo cuatro', busy, now) as AssistantPreview;
      expect(shown(narrowed), ['sin-12', 'generico', 'sin-11', 'pan']);
      expect(s.isCurrent(first), isFalse);
      expect(s.confirm(first, many()), isNull, reason: 'Proposals outside the new selection are no longer applicable');
      final two = await s.say('solo estos dos', busy, now) as AssistantPreview;
      expect(shown(two), ['sin-12', 'generico']);
    });

    test('with the interpreter: its number (a marker resolved here); a list step of the same movements is not repeated', () async {
      final model = FakeModel([
        said({'kind': 'categorize', 'uncategorized': true, 'limit': 'N1'}),
        said({
          'kind': 'listMovements',
          'uncategorized': true,
          'limit': 2,
          'also': [
            {'kind': 'categorize', 'uncategorized': true}
          ]
        }),
      ]);
      final s = session(model: model, over: many());
      expect(shown(await s.say('los 3 más nuevos sin categoría, clasifícalos', busy, now)), ['sin-12', 'generico', 'sin-11']);
      expect(model.received.first['sentence'], 'los [N1] más nuevos sin categoría, clasifícalos');
      final combined = await s.say('enséñame los últimos 2 sin categoría y pónselas', busy, now) as AssistantPreview;
      expect(shown(combined), ['sin-12', 'generico']);
      expect(combined.followUps, isEmpty, reason: 'The cards already show them: no second list');
    });

    test('a category chosen on a card or said in the chat goes to that movement only; saving touches only the cards shown', () async {
      final s = session();
      final reply = await s.say('categoriza los cuatro últimos que no tienen', calc, now) as AssistantPreview;
      expect(shown(reply), ['pan', 'generico', 'entrada', 'cine']);
      final said = await s.say('el de 44,53 € es gasolina', calc, now) as AssistantMessage;
      expect(said.text, contains('irá a Combustible'));
      expect(s.chooseCategory(reply, 'entrada', 'sueldo'), isTrue);
      expect(s.chooseCategory(reply, 'libro', 'ocio'), isFalse, reason: 'A movement not shown cannot be chosen');
      expect(s.chooseCategory(reply, 'pan', 'ocio'), isFalse, reason: 'The one applied by the person\'s evidence is undone, not overwritten');
      // Meanwhile «cine» got a category elsewhere: it is validated again and not overwritten; nothing else is added.
      final meanwhile = data([for (final t in _base()) t.id == 'cine' ? tx('cine', 'CINES FICTICIOS', 900, category: 'rest') : t]);
      expect(saves(s, reply, meanwhile), {'generico': 'fuel', 'entrada': 'sueldo'});
      expect(s.confirm(reply, data()), isNull, reason: 'Never applied twice');
    });

    test('undo puts back only what it set', () async {
      final s = session();
      final reply = await s.say('pon categoría a lo que no tiene', calc, now) as AssistantPreview;
      expect(saves(s, reply, data()), {'cine': 'ocio'});
      final applied = data([for (final t in _base()) t.id == 'cine' ? tx('cine', 'CINES FICTICIOS', 900, category: 'ocio') : t]);
      final undo = s.undo(reply, applied, now)!;
      final ops = undo.data['ops'] as List;
      expect(ops, hasLength(1));
      expect((ops.single as Map)['data']['fields'], containsPair('categoryID', null));
    });

    test('nothing left without category: said, nothing executed', () async {
      final tidy = FinanceCalculator(data([tx('cafe', 'CAFETERIA FICTICIA', 825, category: 'rest')]));
      final reply = await session().say('ponles categoría', tidy, now) as AssistantResult;
      expect(reply.lines.first, 'No hay ninguno sin categoría.');
    });
  });

  group('with the interpreter', () {
    test('its capability and its correction; the context carries the last request with its conditions', () async {
      final model = FakeModel([
        said({'kind': 'categorize', 'uncategorized': true}),
        said({'kind': 'categorize', 'refine': true, 'scope': 'expenses'}),
      ]);
      final s = session(model: model);
      expect(await s.say('me ayudas con lo que está sin categorizar?', calc, now), isA<AssistantPreview>());
      final second = await s.say('vale pero solo con los gastos', calc, now);
      expect(model.received[1]['lastQuery'], 'poner categoría: Movimientos sin categoría de cualquier fecha');
      expect(shown(second).toSet(), {'pan', 'generico', 'cine', 'libro'}, reason: 'The correction changed only the type');
    });

    test('when it fails the rules do the same, and say so', () async {
      final reply = await session(model: FakeModel([])).say('Tengo movimientos sin categorías puedes ponérselas?', calc, now);
      expect(reply, isA<AssistantPreview>());
      expect(reply.note, 'El intérprete no ha respondido: lo interpreto con mis reglas.');
    });

    test('a combined request runs its steps in order, within limits; a second thing to confirm waits', () async {
      final model = FakeModel([
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
      // The expense is ready (the usual account); the reserve needs its account; the summary is answered meanwhile.
      final question = await s.say('apunta 20 € de comida, dime cómo voy y reserva 50 para el viaje', calc, now) as AssistantQuestion;
      expect(question.text, '¿En qué cuenta lo reservo?');
      expect(question.note!.replaceAll(' ', ' '), 'Ya tengo gasto · 20,00 €; para lo siguiente me falta un dato.');
      expect((question.followUps.single as AssistantResult).title, startsWith('Resumen'));
      expect(s.hasParked, isFalse, reason: 'The expense was not set aside by its own steps');
      // Both, confirmed together with one tap.
      final both = await s.choose('nomina', calc, now) as AssistantPreview;
      expect(both.kind, PreviewKind.batch);
      expect(both.parts.map((p) => p.title.replaceAll(' ', ' ')), ['Gasto · 20,00 €', 'Reserva · 50,00 €']);
      final ops = s.confirm(both, data())!.data['ops'] as List;
      expect(ops, hasLength(2));
      expect(s.confirm(both, data()), isNull, reason: 'Never twice');
    });

    test('topic changes keep each thing: a draft set aside comes back intact', () async {
      final s = session();
      // Fewer questions: the account the person uses for most of their expenses is proposed, said on the card.
      final first = await s.say('he gastado 12 € en un café', calc, now) as AssistantPreview;
      expect(first.lines, contains(('Cuenta', 'Nómina ficticia (la que sueles usar)')));
      final aside = await s.say('por cierto, ¿qué tengo sin categoría?', calc, now) as AssistantResult;
      expect(aside.note, startsWith('Dejo aparte el gasto de 12,00'));
      expect(ids(aside), isNot(contains('cafe')));
      final back = await s.resume(calc, now) as AssistantPreview;
      expect(back.draft!.amountMinor, 1200, reason: 'The expense comes back intact');
    });
  });

  group('through the real screen, for the developer and a guest', () {
    setUpAll(() => initializeDateFormatting('es'));
    setUp(() {
      runTraining = <T>(T Function() work) async => work();
      CloudPrivacy.forgetAll();
      SharedPreferences.setMockInitialValues({});
    });

    Map<String, dynamic> record(String id, int day, String? category, {String text = 'PANADERIA LUNA', int amount = 450}) => {
          'id': id,
          'date': profiles.seconds(DateTime(2026, 11, day)),
          'typeRaw': 'expense',
          'amountMinor': amount,
          'descriptionText': text,
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
            {'id': 'ocio', 'name': 'Ocio', 'kindRaw': 'expense'},
          ],
          'accounts': [
            {'id': 'nomina', 'name': 'Nómina ficticia', 'typeRaw': 'checking', 'openingDate': profiles.seconds(DateTime(2026)), 'currencyCode': 'EUR', 'openingBalanceMinor': 150000},
          ],
          'transactions': [
            record('h1', 3, 'super'),
            record('h2', 10, 'super'),
            record('viejo', 5, null, text: 'KIOSCO FICTICIO', amount: 300),
          ],
        };

    Future<void> settle(WidgetTester tester, [int rounds = 20]) async {
      for (var i = 0; i < rounds; i++) {
        await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
        await tester.pump(const Duration(milliseconds: 100));
      }
    }

    for (final encrypted in [false, true]) {
      testWidgets('${encrypted ? 'guest' : 'developer'}: the two most recent as cards; one chosen on its card; saved once, only those', (tester) async {
        tester.view.physicalSize = const Size(400, 1400);
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
          // New movements after opening (opening the app already assigns what it can): the chat works on them.
          await repo.apply(Operation('insert', {'record': record('pan', 25, null)}));
          await repo.apply(Operation('insert', {'record': record('misterio', 24, null, text: 'Movimiento bancario', amount: 4453)}));
        });
        expect(repo.isAdministrator, !encrypted);
        await tester.pumpWidget(MaterialApp(
          theme: doblonTheme(Brightness.dark),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          // The guest reads with a large text size: the cards wrap without overflowing.
          builder: (context, child) => MediaQuery(data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(encrypted ? 1.6 : 1)), child: child!),
          home: AssistantScreen(repository: repo, clock: () => now),
        ));
        await tester.pump();
        final saves = cloud.financeSaves;
        await tester.enterText(find.byType(TextField), '¿Le pones categoría a los 2 últimos que no tengan?');
        await tester.testTextInput.receiveAction(TextInputAction.send);
        await settle(tester);
        expect(find.text('Los 2 últimos sin categoría'), findsOneWidget);
        expect(find.text('Panaderia Luna'), findsOneWidget);
        expect(find.textContaining('−4,50'), findsOneWidget, reason: 'Signed amount');
        expect(find.text('Puesta como la sueles poner'), findsOneWidget, reason: 'From the person\'s history, applied on its own');
        expect(find.text('Dime qué es'), findsOneWidget);
        expect(find.textContaining('Kiosco'), findsNothing, reason: 'An older one is never brought in');
        expect(cloud.financeSaves, saves + 1, reason: 'Only the automatic one saved so far');
        expect(tester.takeException(), isNull);

        await tester.ensureVisible(find.widgetWithText(ActionChip, 'Elegir categoría'));
        await tester.pump();
        await tester.tap(find.widgetWithText(ActionChip, 'Elegir categoría'));
        await settle(tester, 5);
        await tester.tap(find.widgetWithText(ListTile, 'Ocio'));
        await settle(tester, 5);
        expect(find.text('Elegida por ti'), findsOneWidget);
        await tester.ensureVisible(find.widgetWithText(FilledButton, 'Guardar 1'));
        await tester.pump();
        expect(tester.takeException(), isNull, reason: 'No overflow after choosing');
        await tester.tap(find.widgetWithText(FilledButton, 'Guardar 1'));
        await settle(tester);
        expect(find.text('Clasificados: 2 de 2.'), findsOneWidget);
        final byId = {for (final t in repo.finances!.transactions) t.id: t.categoryId};
        expect(byId, {'h1': 'super', 'h2': 'super', 'viejo': null, 'pan': 'super', 'misterio': 'ocio'}, reason: 'Only the movements shown');
        expect(cloud.financeSaves, saves + 2, reason: 'One save for the confirmation');
        expect(find.widgetWithText(FilledButton, 'Guardar 1'), findsNothing, reason: 'Cannot be saved twice');
        // The learning's delayed sync (scheduled once its save finishes, later for an encrypted guest).
        await settle(tester);
        await tester.pump(const Duration(seconds: 3));
        await settle(tester, 5);
      });
    }
  });
}
