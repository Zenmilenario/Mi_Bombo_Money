// Fictitious data only. «Write as you speak, Don Bigotes does the rest» (26 November 2026):
//  - privacy: amounts (in digits or words), the person's names and their movements never leave the device; markers
//    are resolved here;
//  - stories: several things told at once are prepared together and confirmed with one tap;
//  - the new capabilities through the chat: transfers, editing and deleting a movement, budgets, goals and category
//    rules, each with its preview, its exact operation and its undo.
// The interpreter is faked by a script that reads the masked context it receives, as the real one does.
import 'dart:convert';

import 'package:doblon/assistant.dart';
import 'package:doblon/assistant_privacy.dart';
import 'package:doblon/edits.dart' show Operation;
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 26, 10);

Transaction tx(String id, String text, int amount, {String account = 'nomina', String? category, TransactionType type = TransactionType.expense, DateTime? date, bool bank = false}) =>
    Transaction(
      id: id,
      date: date ?? DateTime(2026, 11, 20),
      type: type,
      amountMinor: amount,
      descriptionText: text,
      sourceAccountId: account,
      categoryId: category,
      bankEntryKey: bank ? 'enable-entry:s:a:$id' : null,
    );

Finances data({List<SavingsGoal> goals = const [], List<Transaction> extra = const []}) => Finances(
      accounts: [
        Account(id: 'nomina', name: 'Nómina Ficticia', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 200000),
        Account(id: 'ahorro', name: 'Ahorro Inventado', type: AccountType.savings, openingDate: DateTime(2026), openingBalanceMinor: 500000),
      ],
      categories: [
        Category(id: 'rest', name: 'Restaurantes', kind: CategoryKind.expense),
        Category(id: 'ocio', name: 'Ocio', kind: CategoryKind.expense),
        Category(id: 'super', name: 'Supermercado', kind: CategoryKind.expense),
        Category(id: 'fuel', name: 'Combustible', kind: CategoryKind.expense),
        Category(id: 'devol', name: 'Devoluciones', kind: CategoryKind.income),
      ],
      goals: goals,
      transactions: [
        // The person's habits: expenses and income in the salary account.
        for (var i = 1; i <= 6; i++) tx('g$i', 'TIENDA $i', 1000 + i, category: 'ocio', date: DateTime(2026, 11, i)),
        for (var i = 1; i <= 5; i++) tx('i$i', 'BIZUM $i', 2000 + i, type: TransactionType.income, category: 'devol', date: DateTime(2026, 10, i)),
        tx('cafe', 'CAFETERIA FICTICIA', 1200, category: 'rest', date: DateTime(2026, 11, 24)),
        tx('gasolina', 'ESTACION FICTICIA', 4453, category: 'fuel', date: DateTime(2026, 11, 25), bank: true),
        ...extra,
      ],
    );

typedef Turn = Map<String, Object?> Function(Map<String, Object?> context);

/// The interpreter, scripted: each turn reads the masked context (as the real one) and answers with markers.
class Script {
  Script(this.turns);
  final List<Turn> turns;
  final received = <Map<String, Object?>>[];
  Future<RemoteInterpretation> call(Map<String, Object?> context) async {
    received.add(context);
    if (turns.isEmpty) return (intent: null, error: 'assistant_unavailable');
    return (intent: AssistantIntent.fromJson(turns.removeAt(0)(context)), error: null);
  }
}

/// The markers in the masked sentence, in order («[N1]», «[CUENTA_2]»…).
List<String> markers(Map<String, Object?> context) => [for (final m in RegExp(r'\[([A-Z]+_\d+|N\d+)\]').allMatches('${context['sentence']}')) m.group(1)!];

/// The marker of a shown movement by its position («el segundo»).
String shownAt(Map<String, Object?> context, int position) => '${(context['shown'] as List)[position - 1]}'.split(':').first;

AssistantSession session(Script model, Finances d) {
  var n = 0;
  final document = {'transactions': [for (final t in d.transactions) {'id': t.id, 'descriptionText': t.descriptionText, 'amountMinor': t.amountMinor}]};
  return AssistantSession(
    newId: () => 'nuevo-${++n}',
    remote: model.call,
    record: (entity, id) => (document[entity] ?? const []).where((r) => r['id'] == id).firstOrNull,
  );
}

/// Lines as text (amounts use a non-breaking space).
List<(String, String)> lines(AssistantPreview p) => [for (final (a, b) in p.lines) (a, b.replaceAll('\u00a0', ' '))];

List<Map<String, dynamic>> ops(Operation op) =>
    op.kind == 'batch' ? [for (final o in op.data['ops'] as List) Map<String, dynamic>.from(o as Map)] : [op.toJson()];

void main() {
  group('privacy: what leaves the device', () {
    test('numbers in words become digits, so they are masked like any amount', () {
      expect(wordsToDigits('pagué cuarenta y cinco con cincuenta'), 'pagué 45,50');
      expect(wordsToDigits('quiero guardar doscientos pavos'), 'quiero guardar 200 pavos');
      expect(wordsToDigits('doce euros con cincuenta de un café'), '12,50 euros de un café');
      expect(wordsToDigits('dos mil quinientos para el coche'), '2500 para el coche');
      expect(wordsToDigits('un café y una tostada'), 'un café y una tostada', reason: 'Articles are not numbers');
    });

    test('amounts, names and movements become markers; days of dates and ordinary words stay', () {
      final m = AssistantMasker(data());
      final masked = m.mask('Pagué unos 62,40 con la ficticia el 5 de diciembre, la de nómina, y lo pongo en Restaurantes; el día 10 de cada mes');
      expect(masked, 'Pagué unos [N1] con la [CUENTA_1] el 5 de diciembre, la de nómina, y lo pongo en [CATEGORIA_1]; el día 10 de cada mes');
      expect(m.amountOf('N1'), 6240);
      expect(m.accountOf('[CUENTA_1]')!.id, 'nomina');
      expect(m.categoryOf('CATEGORIA_1')!.id, 'rest');
      expect(m.unmask('el [N1] en [CATEGORIA_1]'), 'el 62,40 en Restaurantes');
      expect(m.accountOf('CUENTA_9'), isNull, reason: 'A marker never sent resolves to nothing, never to a guess');
      expect(m.amountsIn('el 5 de diciembre pagué 62,40'), {6240}, reason: 'A day is not an amount');
    });
  });

  group('a story with several things, confirmed together', () {
    test('«Ayer pagué la cena, unos 62, y me devolvieron 20 de la entrada del cine»', () async {
      final model = Script([
        (c) {
          final n = markers(c);
          return {
            'kind': 'expense',
            'amount': n[0],
            'date': '2026-11-25',
            'concept': 'Cena',
            'category': 'restaurante',
            'also': [
              {'kind': 'income', 'amount': n[1], 'date': '2026-11-25', 'concept': 'Entrada del cine', 'category': 'devolución'}
            ]
          };
        },
      ]);
      final d = data();
      final s = session(model, d);
      final reply = await s.say('Ayer pagué la cena, unos 62, y me devolvieron 20 de la entrada del cine', FinanceCalculator(d), now) as AssistantPreview;
      expect(model.received.single['sentence'], 'Ayer pagué la cena, unos [N1], y me devolvieron [N2] de la entrada del cine');
      expect(reply.kind, PreviewKind.batch, reason: 'One card, one tap');
      expect(reply.parts.map((p) => p.draft!.amountMinor), [6200, 2000]);
      expect(reply.parts.map((p) => p.draft!.type), [TransactionType.expense, TransactionType.income]);
      expect(reply.parts.map((p) => p.draft!.categoryId), ['rest', 'devol'], reason: 'The person\'s words resolved to their own categories');
      expect(reply.parts.map((p) => p.draft!.sourceAccountId), ['nomina', 'nomina'], reason: 'The account they usually use, not asked');
      final op = s.confirm(reply, d)!;
      expect(ops(op).map((o) => o['kind']), ['insert', 'insert']);
      expect(s.confirm(reply, d), isNull, reason: 'Never twice');
      final saved = data(extra: [for (final p in reply.parts) tx(p.id, 'x', p.draft!.amountMinor)]);
      expect(ops(s.undo(reply, saved, now)!).map((o) => (o['kind'], o['data']['id'])), [('delete', 'nuevo-1'), ('delete', 'nuevo-2')]);
    });
  });

  group('the new capabilities, by chat', () {
    test('a transfer between own accounts: prepared, previewed and only recorded', () async {
      final model = Script([
        (c) => {'kind': 'transfer', 'amount': markers(c).first, 'account': 'CUENTA_1', 'toAccount': 'CUENTA_2'},
      ]);
      final d = data();
      final reply = await session(model, d).say('pasa 300 de la nómina a la de ahorro', FinanceCalculator(d), now) as AssistantPreview;
      expect(lines(reply), [('Desde', 'Nómina Ficticia'), ('A', 'Ahorro Inventado'), ('Fecha', 'hoy, 26/11')]);
      expect(reply.effects.last, 'Solo se apunta: no mueve dinero en tu banco.');
      expect((reply.draft!.type, reply.draft!.amountMinor, reply.draft!.destinationAccountId), (TransactionType.transfer, 30000, 'ahorro'));
    });

    test('editing a movement on screen («el segundo era de 15, no de 12»): only that one, only what was said; undo puts it back', () async {
      final model = Script([
        (c) => {'kind': 'listMovements', 'scope': 'expenses', 'period': 'thisMonth', 'limit': 2},
        (c) {
          final n = markers(c);
          return {'kind': 'editMovement', 'target': shownAt(c, 2), 'amount': n.first};
        },
      ]);
      final d = data();
      final s = session(model, d);
      final list = await s.say('enséñame mis dos últimos gastos', FinanceCalculator(d), now) as AssistantResult;
      expect(list.transactions.map((t) => t.id), ['gasolina', 'cafe']);
      final edit = await s.say('el segundo era de 15, no de 12', FinanceCalculator(d), now) as AssistantPreview;
      expect(model.received[1]['shown'], hasLength(2), reason: 'What is on screen, as markers');
      expect(edit.targetId, 'cafe');
      expect(edit.lines.single.$1, 'Importe');
      final save = s.confirm(edit, d)!;
      expect((save.kind, save.data['id'], save.data['fields']['amountMinor']), ('patch', 'cafe', 1500));
      expect(save.data['fields']['categoryID'], 'rest', reason: 'Its category stays as it was');
      final undo = edit.undoOperation!;
      expect((undo.data['id'], undo.data['fields']['amountMinor'], undo.data['fields']['categoryID']), ('cafe', 1200, 'rest'));
    });

    test('deleting by amount and day: the bank warns it comes back; two alike are asked, never guessed; undo restores it', () async {
      final d = data(extra: [tx('otra', 'OTRA ESTACION', 4453, date: DateTime(2026, 11, 2))]);
      final model = Script([
        (c) => {'kind': 'deleteMovement', 'findAmount': markers(c).first, 'findDate': '2026-11-25'},
        (c) => {'kind': 'deleteMovement', 'findAmount': markers(c).first},
      ]);
      final s = session(model, d);
      final byDay = await s.say('borra el de 44,53 de ayer', FinanceCalculator(d), now) as AssistantPreview;
      expect((byDay.kind, byDay.targetId), (PreviewKind.delete, 'gasolina'));
      expect(byDay.warnings.single, startsWith('Viene de tu banco: volverá a aparecer'));
      expect(s.confirm(byDay, d)!.toJson(), {'kind': 'delete', 'data': {'id': 'gasolina'}});
      expect(ops(byDay.undoOperation!).single['kind'], 'insert', reason: 'The record exactly as it was');
      final which = await s.say('y borra el otro de 44,53', FinanceCalculator(d), now) as AssistantQuestion;
      expect(which.options.map((o) => o.$2), ['target:gasolina', 'target:otra']);
    });

    test('a budget: every month by default, «solo este mes» changes only that; undo removes it', () async {
      final model = Script([
        (c) => {'kind': 'setBudget', 'category': markers(c).last, 'amount': markers(c).first},
        (c) => {'kind': 'correction', 'recurring': false},
      ]);
      final d = data();
      final s = session(model, d);
      final every = await s.say('ponme 200 al mes para Restaurantes', FinanceCalculator(d), now) as AssistantPreview;
      expect(model.received.first['sentence'], 'ponme [N1] al mes para [CATEGORIA_1]');
      expect(lines(every).first, ('Límite', '200,00 € cada mes desde noviembre'));
      final only = await s.say('mejor solo este mes', FinanceCalculator(d), now) as AssistantPreview;
      expect(lines(only).first, ('Límite', '200,00 € solo en noviembre'));
      final op = s.confirm(only, d)!;
      expect(ops(op).single['data']['entity'], 'budgets');
      expect(ops(only.undoOperation!).single['kind'], 'remove');
    });

    test('a goal and money put aside for it', () async {
      final model = Script([
        (c) => {'kind': 'createGoal', 'purpose': 'Viaje a Japón', 'amount': markers(c).first, 'date': '2027-08-31'},
        (c) => {'kind': 'addToGoal', 'goal': 'OBJETIVO_1', 'amount': markers(c).firstWhere((m) => m.startsWith('N'))},
      ]);
      final d = data();
      final s = session(model, d);
      final goal = await s.say('quiero ahorrar mil quinientos para irme a Japón en agosto', FinanceCalculator(d), now) as AssistantPreview;
      expect(model.received.first['sentence'], 'quiero ahorrar [N1] para irme a Japón en agosto');
      expect(lines(goal), [('Meta', '1.500,00 €'), ('Para', '31 de agosto de 2027')]);
      final record = ops(s.confirm(goal, d)!).single['data']['record'] as Map;
      expect((record['name'], record['targetAmountMinor'], record['currentAmountMinor']), ('Viaje a Japón', 150000, 0));
      final withGoal = data(goals: [SavingsGoal(id: 'nuevo-1', name: 'Viaje a Japón', targetAmountMinor: 150000)]);
      final saved = await s.say('he metido 100 en lo de Japón', FinanceCalculator(withGoal), now) as AssistantPreview;
      expect(lines(saved).single, ('Ahorrado', '0,00 € → 100,00 € de 1.500,00 €'));
      expect(saved.effects.last, 'Solo se apunta en el objetivo: no mueve dinero entre cuentas.');
    });

    test('a category rule from a sentence, with how many are waiting for it', () async {
      final model = Script([(c) => {'kind': 'createRule', 'concept': 'MERCADO LUNA', 'category': 'super'}]);
      final d = data(extra: [tx('m1', 'MERCADO LUNA 0001', 900), tx('m2', 'MERCADO LUNA 0002', 700)]);
      final rule = await session(model, d).say('siempre que ponga Mercado Luna mételo en el súper', FinanceCalculator(d), now) as AssistantPreview;
      expect(rule.title, 'Regla · «MERCADO LUNA» → Supermercado');
      expect(rule.effects.last, 'Ya tienes 2 sin categoría con ese texto: después, pídeme que les ponga categoría.');
      expect(ops(rule.undoOperation!).single['kind'], 'remove');
    });
  });

  test('nothing sensitive left the device in any of these conversations', () async {
    final model = Script([
      (c) => {'kind': 'listMovements', 'scope': 'expenses', 'limit': 2},
      (c) => {'kind': 'unknown'},
    ]);
    final d = data();
    final s = session(model, d);
    await s.say('enséñame los dos últimos gastos de la ficticia', FinanceCalculator(d), now);
    await s.say('y el de 44,53 qué era, ¿de Combustible?', FinanceCalculator(d), now);
    final sent = jsonEncode(model.received);
    for (final secret in ['Ficticia', 'ficticia', 'Inventado', 'Combustible', '44,53', '4453', 'ESTACION', 'CAFETERIA', '200000']) {
      expect(sent.contains(secret), isFalse, reason: '«$secret» left the device');
    }
  });
}
