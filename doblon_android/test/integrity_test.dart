// Fictitious data only. Integrity of bank movements (26 November 2026): a booked entry the bank reports again with
// a new reference is not a second expense; two equal payments stay two; a hold and its final charge are not taken
// twice from «Disponible»; categories confirmed survive later downloads; the person's rules apply on import; a loan's
// money, what was paid with it and its instalments are counted once; and Don Bigotes changes existing movements
// (category, loan) without creating a new income, expense or loan.
import 'package:doblon/assistant.dart';
import 'package:doblon/bank_activity.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/installments.dart';
import 'package:doblon/models.dart';
import 'package:doblon/reconcile.dart';
import 'package:flutter_test/flutter_test.dart';

final remote = RemoteAccount(id: 'cuenta-remota', currency: 'EUR', lastFour: '0000');
final connection = RemoteConnection(id: '00000000-0000-4000-8000-0000000000cc', bank: 'Banco ficticio', validUntil: '2027-01-01', accounts: [remote]);
final day25 = DateTime.utc(2026, 11, 25);
final observed = DateTime.utc(2026, 11, 26, 8);

Map<String, dynamic> document({List<Map<String, dynamic>> transactions = const [], List<Map<String, dynamic>> rules = const []}) => {
      'formatVersion': 2,
      'accounts': [
        {'id': 'cuenta', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'currencyCode': 'EUR', 'bankIdentityKey': accountIdentity(remote.id)},
      ],
      'categories': [
        {'id': 'dulces', 'name': 'Caprichos', 'kindRaw': 'expense'},
        {'id': 'ocio', 'name': 'Ocio', 'kindRaw': 'expense'},
        {'id': 'fuel', 'name': 'Combustible', 'kindRaw': 'expense'},
      ],
      'categoryRules': rules,
      'transactions': transactions,
      'snapshots': <dynamic>[],
    };

AccountFeed feed(List<(String?, int, String)> rows, {String date = '2026-11-25'}) => AccountFeed(connection: connection, account: remote, balances: [], movements: [
      for (final (id, amount, text) in rows) Movement(id: id, bookingDate: date, signedAmountMinor: amount, currency: 'EUR', description: text),
    ]);

List<Map<String, dynamic>> rows(Map<String, dynamic> doc) => (doc['transactions'] as List).cast<Map<String, dynamic>>();

void main() {
  group('the same booked entry reported again with a new reference', () {
    test('kept as one record with both references; later downloads with either reference create nothing', () {
      var (doc, result) = importFeeds(document(), [feed([('ref-a', -1005, 'DULCERIA FICTICIA')])], observed.subtract(const Duration(hours: 20)));
      expect(result.inserted, 1);
      rows(doc).single['categoryID'] = 'dulces'; // confirmed by the person meanwhile
      (doc, result) = importFeeds(doc, [feed([('ref-b', -1005, 'DULCERIA FICTICIA')])], observed);
      expect((result.inserted, result.reidentified), (0, 1), reason: 'Not a second expense');
      expect(rows(doc).single['categoryID'], 'dulces', reason: 'The category confirmed is kept');
      expect(rows(doc).single['bankEntryKey'], startsWith('enable-keys:'));
      for (final ref in ['ref-a', 'ref-b']) {
        final (_, again) = importFeeds(doc, [feed([(ref, -1005, 'DULCERIA FICTICIA')])], observed);
        expect((again.inserted, again.alreadyImported), (0, 1));
      }
      final data = Finances.fromDocument(doc);
      expect(FinanceCalculator(data).monthlySummary(DateTime(2026, 11)).expenseMinor, 1005);
    });

    test('two equal payments the bank still reports separately stay two, and are never proposed as one', () {
      var (doc, result) = importFeeds(document(), [feed([('ref-a', -1005, 'DULCERIA FICTICIA'), ('ref-b', -1005, 'DULCERIA FICTICIA')])], observed);
      expect(result.inserted, 2);
      (doc, result) = importFeeds(doc, [feed([('ref-a', -1005, 'DULCERIA FICTICIA'), ('ref-b', -1005, 'DULCERIA FICTICIA')])], observed);
      expect((result.inserted, result.reidentified, result.alreadyImported), (0, 0, 2));
      final data = Finances.fromDocument(doc);
      expect(rereportedCases(data), isEmpty, reason: 'Same download: two operations');
      expect(classify(data.transactions[0], data.transactions[1], data).kind, isNull);
      // The earlier one still reported and a new one: a new operation.
      (doc, result) = importFeeds(doc, [feed([('ref-a', -1005, 'DULCERIA FICTICIA'), ('ref-b', -1005, 'DULCERIA FICTICIA'), ('ref-c', -1005, 'DULCERIA FICTICIA')])], observed);
      expect((result.inserted, result.reidentified), (1, 0));
      // Another concept on the same day and amount is another operation too.
      final (_, other) = importFeeds(document(transactions: rows(doc)), [feed([('ref-d', -1005, 'OTRA TIENDA FICTICIA')])], observed);
      expect((other.inserted, other.reidentified), (1, 0));
    });

    test('a duplicate already stored (as on 25-26/11) is proposed with its effect and joined only when confirmed, keeping both references', () {
      var (doc, _) = importFeeds(document(), [feed([('ref-a', -1005, 'DULCERIA FICTICIA')])], observed.subtract(const Duration(hours: 20)));
      // Before this fix the second download inserted it again: simulated here as stored by an earlier version.
      final copy = Map<String, dynamic>.from(rows(doc).single)
        ..['id'] = 'copia'
        ..['bankEntryKey'] = '${entryPrefix(remote.id)}ref-b'
        ..['createdAt'] = referenceSeconds(observed);
      doc = document(transactions: [...rows(doc), copy]);
      final data = Finances.fromDocument(doc);
      final cases = rereportedCases(data);
      expect(cases.single.second.id, 'copia', reason: 'The later download is joined into the earlier record');
      expect(classify(cases.single.first, cases.single.second, data).kind, MatchKind.duplicate);
      expect(matchCases(data).where((c) => c.id == cases.single.id), hasLength(1));
      final before = effects([cases.single.first, cases.single.second]);
      expect(before['cuenta'], -2010);
      final join = joinOperation(cases.single, data, doc, DateTime(2026, 11, 26, 9))!;
      applyOperation(doc, join.op);
      final after = Finances.fromDocument(doc);
      expect(after.transactions.single.amountMinor, 1005);
      expect(after.transactions.single.bankEntryKey, contains('ref-a'));
      expect(after.transactions.single.bankEntryKey, contains('ref-b'));
      final (_, again) = importFeeds(doc, [feed([('ref-b', -1005, 'DULCERIA FICTICIA')])], observed);
      expect(again.inserted, 0, reason: 'The next download does not bring it back');
      // Undone: both as they were.
      applyOperation(doc, join.trace.undo(DateTime(2026, 11, 26, 10)));
      expect(Finances.fromDocument(doc).transactions.length, 2);
    });
  });

  group('holds and the final charge', () {
    BankActivity activity(List<PendingMovement> pending, List<BookedMovement> booked) =>
        BankActivity.fromFeed(accountCurrency: 'EUR', balances: const [], movements: booked, pending: pending, observedAt: observed);
    const hold = PendingMovement(id: 'p1', date: '2026-11-25', signedAmountMinor: -1005, currency: 'EUR', description: 'DULCERIA FICTICIA', status: 'PDNG');

    test('booked under the same or another reference: the hold no longer counts; otherwise it does, once', () {
      expect(activity([hold], [const BookedMovement(id: 'p1', bookingDate: '2026-11-25', signedAmountMinor: -1005, currency: 'EUR', description: 'DULCERIA FICTICIA')])
          .pendingMovements, isEmpty);
      expect(activity([hold], [const BookedMovement(id: 'b9', bookingDate: '2026-11-26', signedAmountMinor: -1005, currency: 'EUR', description: 'DULCERIA FICTICIA')])
          .pendingMovements, isEmpty, reason: 'The bank re-identified it when booking it');
      expect(activity([hold], const []).pendingMovements, hasLength(1));
      // Two equal holds and one booked: one still pending.
      expect(
          activity([hold, const PendingMovement(id: 'p2', date: '2026-11-25', signedAmountMinor: -1005, currency: 'EUR', description: 'DULCERIA FICTICIA', status: 'PDNG')],
              [const BookedMovement(id: 'b9', bookingDate: '2026-11-25', signedAmountMinor: -1005, currency: 'EUR', description: 'DULCERIA FICTICIA')]).pendingMovements,
          hasLength(1));
      // Another shop with the same amount is not covered.
      expect(activity([hold], [const BookedMovement(id: 'b9', bookingDate: '2026-11-25', signedAmountMinor: -1005, currency: 'EUR', description: 'OTRA TIENDA')])
          .pendingMovements, hasLength(1));
    });

    test('an income pending on one day and booked the next is shown once', () {
      const income = PendingMovement(id: 'p3', date: '2026-11-25', signedAmountMinor: 1500, currency: 'EUR', description: 'BIZUM FICTICIO CLASES', status: 'PDNG');
      expect(activity([income], const []).pendingMovements, hasLength(1), reason: 'Shown as pending before it is booked');
      expect(activity([income], [const BookedMovement(id: 'b3', bookingDate: '2026-11-26', signedAmountMinor: 1500, currency: 'EUR', description: 'BIZUM FICTICIO CLASES')])
          .pendingMovements, isEmpty);
      final (doc, result) = importFeeds(document(), [feed([('b3', 1500, 'BIZUM FICTICIO CLASES')], date: '2026-11-26')], observed);
      expect(result.inserted, 1, reason: 'Booked a day later: imported with the bank\'s booking date');
      expect(rows(doc).single['typeRaw'], 'income');
    });
  });

  test('the person\'s category rules apply on import (as on the iPhone); without a rule nothing is invented', () {
    final rule = {'id': 'r', 'phrase': 'dulceria', 'transactionTypeRaw': 'expense', 'isActive': true, 'categoryID': 'dulces', 'createdAt': 0, 'updatedAt': 0};
    final (doc, _) = importFeeds(document(rules: [rule]), [feed([('ref-a', -1005, 'DULCERIA FICTICIA'), (null, -4453, 'Movimiento bancario')])], observed);
    final byAmount = {for (final r in rows(doc)) r['amountMinor']: r['categoryID']};
    expect(byAmount[1005], 'dulces');
    expect(byAmount[4453], isNull, reason: 'Only amount and date: no category is invented');
  });

  test('a manual payment and its bank entry are one (proposed, not inserted)', () {
    final manual = {
      'id': 'manual', 'date': referenceSeconds(DateTime.utc(2026, 11, 25, 9)), 'typeRaw': 'expense', 'amountMinor': 1005, 'descriptionText': 'Dulces',
      'sourceAccountID': 'cuenta', 'bankEntryKey': null,
    };
    final (_, result) = importFeeds(document(transactions: [manual]), [feed([('ref-a', -1005, 'DULCERIA FICTICIA')])], observed);
    expect(result.inserted, 0);
    expect(result.proposals.single.candidateIds, ['manual']);
  });

  group('a loan: the money received, what was paid with it and its instalments, each once', () {
    final income = Transaction(
        id: 'ingreso', date: DateTime(2026, 11, 25), type: TransactionType.income, amountMinor: 437800, descriptionText: 'Movimiento bancario', sourceAccountId: 'cuenta', bankEntryKey: 'enable-entry:x:y:1');
    final spent = Transaction(
        id: 'cargo', date: DateTime(2026, 11, 25), type: TransactionType.expense, amountMinor: 437796, descriptionText: 'Movimiento bancario', sourceAccountId: 'cuenta', bankEntryKey: 'enable-entry:x:y:2');
    Finances data({List<InstallmentPlan> plans = const [], List<Transaction> extra = const []}) => Finances(
          accounts: [Account(id: 'cuenta', name: 'Cuenta ficticia', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 100000)],
          categories: [Category(id: 'compras', name: 'Compras', kind: CategoryKind.expense), Category(id: 'fuel', name: 'Combustible', kind: CategoryKind.expense)],
          transactions: [income, spent, ...extra],
          installmentPlans: plans,
        );
    AssistantSession session() {
      var n = 0;
      return AssistantSession(newId: () => 'nuevo-${++n}');
    }

    test('by chat, with no loan recorded: the income is linked and the commitment prepared; nothing new is inserted', () async {
      final s = session();
      final calc = FinanceCalculator(data());
      var reply = await s.say('El ingreso de 4.378 € es el dinero del préstamo', calc, DateTime(2026, 11, 26, 9));
      expect((reply as AssistantQuestion).field, PendingField.loanTotal, reason: 'The total to repay is asked, never assumed');
      reply = await s.choose('total:same', calc, DateTime(2026, 11, 26, 9));
      expect((reply as AssistantQuestion).field, PendingField.count);
      reply = await s.say('12', calc, DateTime(2026, 11, 26, 9));
      expect((reply as AssistantQuestion).field, PendingField.dueDate, reason: 'The name comes from the sentence');
      final plan = await s.say('el 5 de diciembre', calc, DateTime(2026, 11, 26, 9)) as AssistantPreview;
      expect(plan.plan!.kind, InstallmentKind.loan);
      expect((plan.plan!.totalMinor, plan.plan!.count, plan.plan!.alreadyRecorded), (437800, 12, true));
      expect(plan.effects.any((e) => e.contains('queda vinculado como el dinero de este préstamo')), isTrue);
      final op = s.confirm(plan, calc.data)!;
      final kinds = [for (final o in (op.data['ops'] as List)) (o as Map)['kind']];
      expect(kinds, ['upsert', 'patch'], reason: 'A plan and a change of the existing income; no insert');
      final doc = <String, dynamic>{
        'transactions': [
          {'id': 'ingreso', 'externalID': null}
        ],
        'installmentPlans': <dynamic>[],
      };
      applyOperation(doc, op);
      expect(((doc['transactions'] as List).single as Map)['externalID'], '$loanReceivedMarker${plan.id}');
    });

    test('the accounts: borrowed money is not everyday income; the purchase is spending once; instalments do not count it again', () {
      final plan = InstallmentPlan(
          id: 'plan', name: 'Préstamo ficticio', kind: InstallmentKind.loan, totalMinor: 437800, schedule: buildSchedule(437800, 12, DateTime(2026, 12, 5, 12))!,
          accountId: 'cuenta', alreadyRecorded: true);
      final linked = Transaction(
          id: 'ingreso', date: income.date, type: TransactionType.income, amountMinor: 437800, descriptionText: 'Movimiento bancario', sourceAccountId: 'cuenta',
          externalId: '${loanReceivedMarker}plan');
      final instalment = Transaction(
          id: 'cuota', date: DateTime(2026, 12, 5), type: TransactionType.expense, amountMinor: 36483, descriptionText: 'Cuota', sourceAccountId: 'cuenta',
          externalId: installmentLink(plan, 1, 36483));
      final d = Finances(accounts: data().accounts, transactions: [linked, spent, instalment], installmentPlans: [plan]);
      final calc = FinanceCalculator(d);
      final november = calc.monthlySummary(DateTime(2026, 11));
      expect((november.dailyIncomeMinor, november.dailyExpenseMinor), (0, 437796), reason: 'The money received is borrowed; what was bought is spent');
      expect(calc.monthlySummary(DateTime(2026, 12)).dailyExpenseMinor, 0, reason: 'The instalment repays it');
      expect(calc.balance(d.accounts.single, DateTime(2026, 12, 31)), 100000 + 437800 - 437796 - 36483, reason: 'Every movement moves the balance once');
    });

    test('by chat: what was paid with the loan, and a category for an existing movement; never a new movement', () async {
      final plan = InstallmentPlan(
          id: 'plan', name: 'Préstamo ficticio', kind: InstallmentKind.loan, totalMinor: 437800, schedule: buildSchedule(437800, 12, DateTime(2026, 12, 5, 12))!,
          accountId: 'cuenta');
      final calc = FinanceCalculator(data(plans: [plan]));
      final now = DateTime(2026, 11, 26, 9);
      final use = await session().say('El cargo de 4.377,96 € es lo que pagué con el préstamo', calc, now) as AssistantPreview;
      expect(use.kind, PreviewKind.existing);
      final ops = (use.operation.data['ops'] as List).cast<Map>();
      expect(ops.map((o) => o['kind']), ['patch', 'upsert'], reason: 'The expense is noted and the plan learns its money is recorded');
      expect(ops.last['data']['record']['alreadyRecorded'], isTrue);
      expect(use.undoOperation, isNotNull);
      // The 44,53 € charge: classified only because the person says what it is.
      final gas = Transaction(
          id: 'gas', date: DateTime(2026, 11, 25), type: TransactionType.expense, amountMinor: 4453, descriptionText: 'Movimiento bancario', sourceAccountId: 'cuenta', bankEntryKey: 'k');
      final s = session();
      final fuel = await s.say('el cargo de 44,53 € fue de gasolina', FinanceCalculator(data(extra: [gas])), now) as AssistantPreview;
      expect((fuel.targetId, fuel.operation.kind, fuel.operation.data['fields']['categoryID']), ('gas', 'patch', 'fuel'));
      expect(await session().say('el cargo de 99,99 € es de gasolina', calc, now), isA<AssistantMessage>(), reason: 'Not found: nothing is created');
    });
  });
}
