// Fictitious data only. Don Bigotes' automation (26 November 2026): categories assigned only with the person's own
// evidence (their rules, then their own repeated decisions; not a model), never over their choice and never without
// a useful concept; a loan registered by chat finds and links its money and asks its category once; an unequivocal
// repeat is joined on its own and an ambiguous one is not; and «Gracias» is just a courtesy.
import 'package:doblon/assistant.dart';
import 'package:doblon/auto_category.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/reconcile.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 26, 10);

Transaction tx(String id, String text, int amount,
        {String? category, bool bank = true, TransactionType type = TransactionType.expense, DateTime? date, String? key, DateTime? created, String? external}) =>
    Transaction(
      id: id,
      date: date ?? DateTime(2026, 11, 20),
      type: type,
      amountMinor: amount,
      descriptionText: text,
      sourceAccountId: 'cuenta',
      categoryId: category,
      bankEntryKey: bank ? (key ?? 'enable-entry:s:a:$id') : null,
      createdAt: created,
      externalId: external,
    );

Finances data(List<Transaction> transactions, {List<CategoryRule> rules = const [], List<Category> extra = const []}) => Finances(
      accounts: [Account(id: 'cuenta', name: 'Cuenta ficticia', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 100000)],
      categories: [
        Category(id: 'super', name: 'Supermercado', kind: CategoryKind.expense),
        Category(id: 'ocio', name: 'Ocio', kind: CategoryKind.expense),
        Category(id: 'nomina', name: 'Nómina', kind: CategoryKind.income),
        ...extra,
      ],
      categoryRules: rules,
      transactions: transactions,
    );

void main() {
  group('automatic categories, only with the person\'s own evidence', () {
    test('their history (twice, always the same category) is applied; once, mixed, generic or chosen is not', () {
      final d = data([
        tx('h1', 'MERCADO FICTICIO 01', 3000, category: 'super'),
        tx('h2', 'MERCADO FICTICIO 01', 2500, category: 'super'),
        tx('nuevo', 'MERCADO FICTICIO 01', 1200),
        tx('una', 'TIENDA UNICA', 900, category: 'ocio'),
        tx('una-nueva', 'TIENDA UNICA', 800),
        tx('m1', 'BAZAR MIXTO', 500, category: 'super'),
        tx('m2', 'BAZAR MIXTO', 500, category: 'ocio'),
        tx('mixto-nuevo', 'BAZAR MIXTO', 500),
        tx('generico', 'Movimiento bancario', 4453),
        tx('elegido', 'OTRO COMERCIO', 700, category: 'ocio'),
      ]);
      final found = autoCategories(d);
      expect({for (final a in found) a.transactionId: a.categoryId}, {'nuevo': 'super'}, reason: 'A chosen category is never touched');
      expect(found.single.source, 'history');
      expect(found.single.detail, contains('2 movimientos tuyos'));
    });

    test('a rule of the person comes first; automatic assignments do not count as their decisions; a rejected one is not repeated', () {
      final rule = CategoryRule(id: 'r', phrase: 'mercado ficticio', transactionType: TransactionType.expense, isActive: true, categoryId: 'ocio', updatedAt: DateTime(2026));
      final d = data([
        tx('h1', 'MERCADO FICTICIO 01', 3000, category: 'super'),
        tx('h2', 'MERCADO FICTICIO 01', 2500, category: 'super'),
        tx('nuevo', 'MERCADO FICTICIO 01', 1200),
      ], rules: [rule]);
      expect(autoCategories(d).single.categoryId, 'ocio', reason: 'The explicit rule wins over the history');
      expect(autoCategories(d, rejected: {'nuevo'}), isEmpty);
      final onlyAutomatic = data([tx('a1', 'KIOSKO FICTICIO', 100, category: 'ocio'), tx('a2', 'KIOSKO FICTICIO', 100, category: 'ocio'), tx('k', 'KIOSKO FICTICIO', 100)]);
      expect(autoCategories(onlyAutomatic, automatic: {'a1', 'a2'}), isEmpty, reason: 'Its own guesses are not evidence');
    });

    test('a category the person chose survives a new download, and nothing re-assigns it', () {
      final remote = RemoteAccount(id: 'remota', currency: 'EUR', lastFour: '0000');
      final connection = RemoteConnection(id: '00000000-0000-4000-8000-0000000000dd', bank: 'Banco ficticio', validUntil: '2027-01-01', accounts: [remote]);
      AccountFeed feed() => AccountFeed(connection: connection, account: remote, balances: [], movements: [
            Movement(id: 'r1', bookingDate: '2026-11-20', signedAmountMinor: -1200, currency: 'EUR', description: 'MERCADO FICTICIO 01'),
          ]);
      final doc = <String, dynamic>{
        'formatVersion': 2,
        'accounts': [
          {'id': 'cuenta', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'currencyCode': 'EUR', 'bankIdentityKey': accountIdentity(remote.id)}
        ],
        'transactions': <dynamic>[],
        'snapshots': <dynamic>[],
      };
      var (next, _) = importFeeds(doc, [feed()], DateTime.utc(2026, 11, 26));
      (next['transactions'] as List).cast<Map>().single['categoryID'] = 'ocio';
      (next, _) = importFeeds(next, [feed()], DateTime.utc(2026, 11, 27));
      expect((next['transactions'] as List).cast<Map>().single['categoryID'], 'ocio');
      expect(autoCategories(Finances.fromDocument(next)), isEmpty);
    });
  });

  group('the loan registered by chat finds and links its money', () {
    final income = tx('ingreso', 'Movimiento bancario', 437800, type: TransactionType.income, date: DateTime(2026, 11, 25));
    final spent = tx('cargo', 'Movimiento bancario', 437796, date: DateTime(2026, 11, 25));
    AssistantSession session() {
      var n = 0;
      return AssistantSession(newId: () => 'nuevo-${++n}');
    }

    Future<AssistantPreview> register(AssistantSession s, FinanceCalculator calc, {required String category}) async {
      await s.say('Préstamo de 4.378 € a devolver en 12 meses', calc, now);
      await s.say('Préstamo del coche ficticio', calc, now);
      final ask = await s.say('el 5 de diciembre', calc, now) as AssistantQuestion;
      expect(ask.field, PendingField.recorded);
      final cat = await s.choose('yes', calc, now) as AssistantQuestion;
      expect(cat.field, PendingField.loanCategory, reason: 'The income was found; only its category is asked');
      expect(cat.options.map((o) => o.$1), ['Crear «Préstamo recibido»', 'Dejarlo sin categoría'], reason: 'No category is invented without asking');
      return await s.choose(category, calc, now) as AssistantPreview;
    }

    test('one income of the same amount: linked and categorised in the same confirmation; nothing new but the plan', () async {
      final s = session();
      final calc = FinanceCalculator(data([income, spent]));
      final preview = await register(s, calc, category: 'loancat:new');
      expect(preview.lines.any((l) => l.$1 == 'Dinero recibido'), isTrue);
      final op = s.confirm(preview, calc.data)!;
      final ops = (op.data['ops'] as List).cast<Map>();
      expect(ops.map((o) => o['kind']), ['upsert', 'patch', 'upsert', 'patch']);
      expect(ops[1]['data']['id'], 'ingreso');
      expect(ops[1]['data']['fields']['externalID'], startsWith(loanReceivedMarker));
      expect(ops[2]['data']['entity'], 'categories');
      expect(ops[2]['data']['record']['name'], 'Préstamo recibido');
      expect(ops.any((o) => o['kind'] == 'insert'), isFalse, reason: 'No income, expense or loan is created again');
      expect(ops.any((o) => o['data']['id'] == 'cargo'), isFalse, reason: 'The nearby charge is not touched');
      // Applied: the income is borrowed money, not everyday income.
      final doc = <String, dynamic>{
        'accounts': [
          {'id': 'cuenta', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': 0}
        ],
        'categories': <dynamic>[],
        'installmentPlans': <dynamic>[],
        'transactions': [
          {'id': 'ingreso', 'date': 0, 'typeRaw': 'income', 'amountMinor': 437800, 'descriptionText': 'Movimiento bancario', 'sourceAccountID': 'cuenta'}
        ],
      };
      applyOperation(doc, op);
      final after = Finances.fromDocument(doc);
      expect(after.transactions.single.isLoanDisbursement, isTrue);
      expect(after.category(after.transactions.single.categoryId)!.name, 'Préstamo recibido');
    });

    test('an existing category that fits is offered; several incomes are asked with date, account and amount', () async {
      final loanCategory = Category(id: 'prestamos', name: 'Préstamos', kind: CategoryKind.income);
      final s = session();
      final calc = FinanceCalculator(data([income, spent], extra: [loanCategory]));
      await s.say('Préstamo de 4.378 € a devolver en 12 meses', calc, now);
      await s.say('Coche', calc, now);
      await s.say('el 5 de diciembre', calc, now);
      final cat = await s.choose('yes', calc, now) as AssistantQuestion;
      expect(cat.options.first, ('Préstamos', 'loancat:prestamos'), reason: 'The person\'s own category, not a new one');
      final twice = FinanceCalculator(data([income, tx('otro', 'Movimiento bancario', 437800, type: TransactionType.income, date: DateTime(2026, 11, 10))]));
      final s2 = session();
      await s2.say('Préstamo de 4.378 € a devolver en 12 meses', twice, now);
      await s2.say('Coche', twice, now);
      await s2.say('el 5 de diciembre', twice, now);
      final which = await s2.choose('yes', twice, now) as AssistantQuestion;
      expect(which.field, PendingField.target);
      expect(which.options.length, 2);
      expect(which.options.first.$1, contains('Cuenta ficticia'));
    });

    test('a loan already registered: the conversation links it without a second plan', () async {
      final plan = InstallmentPlan(id: 'plan', name: 'préstamo', kind: InstallmentKind.loan, totalMinor: 437800, schedule: [Installment(DateTime(2026, 12, 5), 437800)], accountId: 'cuenta', alreadyRecorded: true);
      final d = Finances(accounts: data([]).accounts, categories: data([]).categories, transactions: [income, spent], installmentPlans: [plan]);
      final s = session();
      final cat = await s.say('El ingreso de 4.378 € es el dinero del préstamo', FinanceCalculator(d), now) as AssistantQuestion;
      expect(cat.field, PendingField.loanCategory);
      final preview = await s.choose('loancat:none', FinanceCalculator(d), now) as AssistantPreview;
      final ops = preview.operation.kind == 'batch' ? (preview.operation.data['ops'] as List).cast<Map>().map((o) => o['kind']).toList() : [preview.operation.kind];
      expect(ops, ['patch'], reason: 'Only the existing income changes: no plan, no movement');
    });
  });

  group('repeats', () {
    final early = DateTime(2026, 11, 25, 11), late = DateTime(2026, 11, 26, 7);
    test('the latest download reports one and no longer the other: joined on its own, keeping both references', () {
      final d = data([
        tx('a', 'DULCERIA FICTICIA', 1005, date: DateTime(2026, 11, 25), key: 'enable-entry:s:a:ref-a', created: early, category: 'ocio'),
        tx('b', 'DULCERIA FICTICIA', 1005, date: DateTime(2026, 11, 25), key: 'enable-entry:s:a:ref-b', created: late),
      ]);
      final match = unequivocalRepeat(d, {'enable-entry:s:a:ref-b'})!;
      expect(match.first.id, 'b', reason: 'The one the bank still reports is kept');
      final doc = <String, dynamic>{
        'transactions': <dynamic>[
          for (final t in d.transactions)
            {'id': t.id, 'date': referenceSeconds(t.date), 'typeRaw': 'expense', 'amountMinor': 1005, 'descriptionText': t.descriptionText, 'sourceAccountID': 'cuenta', 'categoryID': t.categoryId, 'bankEntryKey': t.bankEntryKey, 'notes': ''}
        ]
      };
      final join = joinOperation(match, d, doc, now)!;
      applyOperation(doc, join.op);
      final after = Finances.fromDocument(doc);
      expect(after.transactions.single.bankEntryKey, allOf(contains('ref-a'), contains('ref-b')));
      expect(after.transactions.single.categoryId, 'ocio', reason: 'The category is kept');
      expect(join.trace.undo(now).kind, 'batch', reason: 'It can be undone');
    });

    test('ambiguous (both still reported, or neither) or kept apart: never joined on its own', () {
      final d = data([
        tx('a', 'DULCERIA FICTICIA', 1005, date: DateTime(2026, 11, 25), key: 'enable-entry:s:a:ref-a', created: early),
        tx('b', 'DULCERIA FICTICIA', 1005, date: DateTime(2026, 11, 25), key: 'enable-entry:s:a:ref-b', created: late),
      ]);
      expect(unequivocalRepeat(d, {'enable-entry:s:a:ref-a', 'enable-entry:s:a:ref-b'}), isNull, reason: 'Two real payments');
      expect(unequivocalRepeat(d, {'enable-entry:s:a:otra'}), isNull);
      final keep = rereportedCases(d).single.id;
      expect(unequivocalRepeat(d, {'enable-entry:s:a:ref-b'}, keptApart: {keep}), isNull);
    });
  });

  test('«Gracias» after saving is a courtesy: a short answer, nothing started; an open draft is kept', () async {
    var n = 0;
    final s = AssistantSession(newId: () => 'id${++n}');
    final calc = FinanceCalculator(data([]));
    for (final text in ['Gracias', 'muchas gracias!', 'vale, perfecto', 'ok', 'nada más']) {
      final reply = await s.say(text, calc, now);
      expect(reply, isA<AssistantMessage>(), reason: text);
      expect((reply as AssistantMessage).text.length, lessThan(80), reason: 'No list of commands');
      expect(s.hasDraft, isFalse);
    }
    await s.say('He gastado 20 €', calc, now);
    final kept = await s.say('gracias', calc, now) as AssistantMessage;
    expect(kept.text, contains('sigue esperando'));
    expect(s.hasDraft, isTrue);
  });
}
