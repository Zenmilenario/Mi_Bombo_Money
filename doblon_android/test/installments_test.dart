// Fictitious data only. Payments in instalments (25 November 2026): a total split in cents that adds up exactly,
// an agreed instalment, a plan started before the app, a purchase already recorded or not (spending and budgets
// never twice), payments of another amount, bank charges to confirm, undoing, and periodic movements that overlap.
import 'package:doblon/banking.dart';
import 'package:doblon/cloud_document_validation.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/forecast.dart';
import 'package:doblon/installments.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

import 'forecast_profiles_test.dart' as profiles show seconds;

final now = DateTime(2026, 11, 25, 12);
final first = DateTime(2026, 11, 5, 12);

InstallmentPlan plan(
        {int total = 437800,
        int count = 12,
        int? agreed,
        bool recorded = false,
        int costs = 0,
        int paidBefore = 0,
        int paidBeforeMinor = 0,
        DateTime? from}) =>
    InstallmentPlan(
      id: 'plan',
      name: 'Compra ficticia',
      kind: InstallmentKind.purchase,
      totalMinor: total,
      schedule: buildSchedule(total, count, from ?? first, agreedMinor: agreed)!,
      accountId: 'cuenta',
      agreedInstallmentMinor: agreed,
      costsMinor: costs,
      alreadyRecorded: recorded,
      paidBeforeCount: paidBefore,
      paidBeforeMinor: paidBeforeMinor,
    );

Transaction payment(InstallmentPlan p, int number, int amount, DateTime date, {String? bank}) => Transaction(
    id: 'pago$number',
    date: date,
    type: TransactionType.expense,
    amountMinor: amount,
    descriptionText: 'Cuota $number',
    sourceAccountId: 'cuenta',
    externalId: installmentLink(p, number, amount),
    bankEntryKey: bank);

Finances data(InstallmentPlan p, [List<Transaction> transactions = const [], List<RecurringMovement> rules = const []]) => Finances(
      accounts: [Account(id: 'cuenta', name: 'Cuenta', type: AccountType.checking, openingDate: DateTime(2026, 1, 1), openingBalanceMinor: 1000000)],
      categories: [Category(id: 'compras', name: 'Compras', kind: CategoryKind.expense)],
      transactions: [...transactions]..sort((a, b) => b.date.compareTo(a.date)),
      recurringMovements: rules,
      installmentPlans: [p],
    );

void main() {
  test('4.378 € in 12 monthly instalments: equal ones, the cents in the last, exactly the total', () {
    final amounts = splitTotal(437800, 12)!;
    expect(amounts.length, 12);
    expect(amounts.fold(0, (a, b) => a + b), 437800);
    expect(amounts.take(11).toSet(), {36483});
    expect(amounts.last, 36487);
    final schedule = buildSchedule(437800, 12, first)!;
    expect(schedule.map((i) => (i.dueDate.month, i.dueDate.day)).take(3), [(11, 5), (12, 5), (1, 5)]);
    expect(schedule.last.dueDate, DateTime(2027, 10, 5, 12));
    // An agreed instalment: all of it but the last, which takes what is left; never more than the total.
    expect(splitTotal(437800, 12, agreedMinor: 36500), [for (var i = 0; i < 11; i++) 36500, 437800 - 36500 * 11]);
    expect(splitTotal(437800, 12, agreedMinor: 40000), isNull, reason: 'The last one would be negative');
    expect(splitTotal(5, 12), isNull);
  });

  test('a plan started before the app: its first instalments are paid without inventing movements', () {
    final p = plan(paidBefore: 3, paidBeforeMinor: 3 * 36483);
    final progress = installmentProgress(p, data(p), now);
    expect(progress.states.take(3).map((s) => s.status), everyElement(InstallmentStatus.paidBefore));
    expect(progress.paidCount, 3);
    expect(progress.next!.number, 4);
    expect(progress.pendingMinor, 437800 - 3 * 36483);
    expect(data(p).transactions, isEmpty);
  });

  test('purchase not recorded: each instalment is spending; already recorded: only its share of the costs', () {
    final notRecorded = plan();
    final pay = payment(notRecorded, 1, 36483, DateTime(2026, 11, 5, 9));
    expect(FinanceCalculator.budgetExpenseAmount(Transaction(
        id: 'x', date: pay.date, type: pay.type, amountMinor: pay.amountMinor, descriptionText: '', sourceAccountId: 'cuenta', categoryId: 'compras', externalId: pay.externalId)), 36483);

    // The purchase was recorded (4.000 €) and the plan adds 378 € of interest: only that share is new spending.
    final recorded = plan(recorded: true, costs: 37800);
    final repay = Transaction(
        id: 'r', date: DateTime(2026, 11, 5, 9), type: TransactionType.expense, amountMinor: 36483, descriptionText: '', sourceAccountId: 'cuenta', categoryId: 'compras',
        externalId: installmentLink(recorded, 1, 36483));
    final share = (37800 * 36483 / 437800).round();
    expect(FinanceCalculator.budgetExpenseAmount(repay), share);
    final calc = FinanceCalculator(data(recorded, [repay]));
    expect(calc.monthlySummary(DateTime(2026, 11)).dailyExpenseMinor, share, reason: 'Not spent twice');
    expect(calc.budgetContributions('compras', DateTime(2026, 11)).single.repaidMinor, 36483 - share);
    expect(calc.balance(calc.data.accounts.single, now), 1000000 - 36483, reason: 'The money leaves the account once');
    // Without costs nothing is spending again.
    expect(FinanceCalculator.budgetExpenseAmount(Transaction(
        id: 'z', date: now, type: TransactionType.expense, amountMinor: 36483, descriptionText: '', sourceAccountId: 'cuenta',
        externalId: installmentLink(plan(recorded: true), 1, 36483))), 0);
  });

  test('payments: on time, of another amount, the calendar adjusted only when confirmed, and undone', () {
    final p = plan();
    var d = data(p, [payment(p, 1, 36483, DateTime(2026, 11, 5, 9)), payment(p, 2, 50000, DateTime(2026, 11, 20, 9))]);
    var progress = installmentProgress(p, d, now);
    expect(progress.states.take(2).map((s) => s.status), [InstallmentStatus.paid, InstallmentStatus.paid], reason: 'The second, paid in advance');
    expect(progress.states[1].differenceMinor, 50000 - 36483);
    expect(progress.paidMinor, 36483 + 50000);
    expect(progress.scheduleOutOfStep, isTrue, reason: 'Pending instalments no longer add up: proposed, not changed');
    final proposal = rescheduled(progress)!;
    expect(proposal.fold(0, (a, i) => a + i.amountMinor), 437800, reason: 'The new calendar still adds up to the total');
    expect(proposal.take(2).map((i) => i.amountMinor), [36483, 50000]);
    expect(proposal.skip(2).every((i) => i.amountMinor < 36483), isTrue);
    // Undoing: a payment recorded by hand is deleted; a bank charge only unlinked.
    expect(undoPaymentOperation(d.transactions.last, now).kind, 'delete');
    final bank = payment(p, 1, 36483, DateTime(2026, 11, 5), bank: 'enable-entry:x');
    expect(undoPaymentOperation(bank, now).data['fields']['externalID'], isNull);
  });

  test('an overdue instalment, and a bank charge proposed for it (not linked alone)', () {
    final p = plan(from: DateTime(2026, 10, 5, 12));
    final charge = Transaction(
        id: 'banco', date: DateTime(2026, 10, 7), type: TransactionType.expense, amountMinor: 36483, descriptionText: 'CARGO FICTICIO', sourceAccountId: 'cuenta', bankEntryKey: 'enable-entry:b');
    final d = data(p, [charge]);
    final progress = installmentProgress(p, d, now);
    expect(progress.states.first.status, InstallmentStatus.overdue);
    final found = compatibleCharges(progress, d);
    expect(found.single.$1.number, 1);
    expect(found.single.$2.id, 'banco');
    final linked = linkOperation(p, 1, charge, now);
    expect(linked.data['fields']['externalID'], '${installmentMarker}plan:1');
    // Applied: the same movement, now its payment. One effect on the balance.
    final doc = <String, dynamic>{
      'transactions': <dynamic>[
        <String, dynamic>{'id': 'banco', 'externalID': null}
      ]
    };
    applyOperation(doc, linked);
    expect(((doc['transactions'] as List).single as Map)['externalID'], '${installmentMarker}plan:1');
  });

  test('a periodic movement of the same payment is pointed out, so it is not counted twice', () {
    final p = plan();
    final rule = RecurringMovement(
        id: 'r', name: 'Cuota', type: TransactionType.expense, amountMinor: 36483, descriptionText: 'Cuota', frequency: Frequency.monthly, nextDueDate: first, sourceAccountId: 'cuenta');
    expect(overlappingRecurring(p, data(p, const [], [rule])).single.id, 'r');
  });

  test('saving a plan keeps the links of its payments in step with what counts as spending', () {
    final p = plan();
    final d = data(p, [payment(p, 1, 36483, DateTime(2026, 11, 5, 9))]);
    final changed = InstallmentPlan(
        id: p.id, name: p.name, kind: p.kind, totalMinor: p.totalMinor, schedule: p.schedule, accountId: p.accountId, alreadyRecorded: true, costsMinor: 37800);
    final op = savePlanOperation(plan: changed, create: false, data: d, now: now);
    expect(op.kind, 'batch');
    final ops = (op.data['ops'] as List).cast<Map>();
    expect(ops.last['data']['fields']['externalID'], startsWith('${installmentMarker}plan:1:'));
    expect(InstallmentPlan.fromJson({...Map<String, dynamic>.from(ops.first['data']['record'] as Map)}).schedule.length, 12);
  });

  test('an encrypted document: a plan must point to one of the accounts; documents without plans are valid', () {
    Map<String, dynamic> doc(List<dynamic>? plans) => {
          'formatVersion': 2,
          for (final key in ['institutions', 'categories', 'cards', 'reservedFunds', 'categoryRules', 'recurringBudgets', 'budgets', 'goals', 'recurringMovements', 'importBatches', 'snapshots', 'transactions'])
            key: <dynamic>[],
          'accounts': [
            {'id': 'cuenta'}
          ],
          if (plans != null) 'installmentPlans': plans,
        };
    validatePrivateDocument(doc(null), 'finance');
    validatePrivateDocument(doc([
      {'id': 'p', 'accountID': 'cuenta'}
    ]), 'finance');
    expect(() => validatePrivateDocument(doc([
          {'id': 'p', 'accountID': 'otra'}
        ]), 'finance'), throwsFormatException);
  });

  test('forecast: open instalments are planned once; a periodic movement of the same payment and paid ones are not', () {
    final p = plan();
    final rule = RecurringMovement(
        id: 'r', name: 'Cuota', type: TransactionType.expense, amountMinor: 36483, descriptionText: 'Cuota', frequency: Frequency.monthly, nextDueDate: DateTime(2026, 12, 5, 12), sourceAccountId: 'cuenta');
    final d = data(p, [payment(p, 1, 36483, DateTime(2026, 11, 5, 9))], [rule]);
    final events = buildForecast(FinanceCalculator(d), now, const ForecastSettings(horizonDays: 60)).events;
    final planned = events.where((e) => e.source == 'inst:plan').toList();
    expect(planned.map((e) => e.key), ['inst:plan:2', 'inst:plan:3'], reason: 'The paid one is not planned again');
    expect(planned.every((e) => e.amountMinor == -36483 && e.certainty == ForecastCertainty.confirmed), isTrue);
    expect(events.where((e) => e.source == 'rec:r'), isEmpty, reason: 'The periodic movement of the same payment gives way to the plan');
    // Without the plan the periodic movement is planned as usual.
    final alone = buildForecast(FinanceCalculator(Finances(accounts: d.accounts, recurringMovements: [rule])), now, const ForecastSettings(horizonDays: 60)).events;
    expect(alone.where((e) => e.source == 'rec:r'), isNotEmpty);
  });

  test('a payment recorded by hand, and later the bank charge: proposed as the same payment, never a second one', () {
    final remote = RemoteAccount(id: 'banco-cuenta', currency: 'EUR', lastFour: '0000');
    final connection = RemoteConnection(id: '00000000-0000-4000-8000-0000000000bb', bank: 'Banco ficticio', validUntil: '2027-01-01', accounts: [remote]);
    final p = plan();
    final manual = paymentOperation(p, 1, 36483, DateTime(2026, 11, 5, 12), now, 'manual');
    final doc = <String, dynamic>{
      'formatVersion': 2,
      'accounts': [
        {'id': 'cuenta', 'name': 'Cuenta', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': accountIdentity('banco-cuenta')}
      ],
      'transactions': <dynamic>[],
      'snapshots': <dynamic>[],
    };
    applyOperation(doc, manual);
    AccountFeed feed() => AccountFeed(connection: connection, account: remote, balances: [], movements: [
          Movement(id: 'c1', bookingDate: '2026-11-10', signedAmountMinor: -36483, currency: 'EUR', description: 'CARGO FICTICIO'),
        ]);
    final (_, proposed) = importFeeds(doc, [feed()], now);
    expect(proposed.inserted, 0);
    expect(proposed.proposals.single.candidateIds, ['manual'], reason: 'Five days later: still proposed');
    final (done, result) = importFeeds(doc, [feed()], now, decisions: {proposed.proposals.single.key: 'manual'});
    expect((result.matched, result.inserted), (1, 0));
    final rows = (done['transactions'] as List).cast<Map<String, dynamic>>();
    expect(rows.single['externalID'], '${installmentMarker}plan:1', reason: 'Still the payment of the instalment');
    expect(rows.single['bankEntryKey'], isNotNull);
    final after = Finances.fromDocument(done);
    expect(installmentProgress(p, after, now).paidCount, 1);
    expect(FinanceCalculator(after).balance(after.accounts.single, now), -36483);
    expect(profiles.seconds(DateTime(2026)), isPositive);
  });

  test('Don Bigotes: an overdue instalment, a bank charge to confirm and a calendar out of step, each opening the plan', () {
    final p = plan(from: DateTime(2026, 9, 5, 12));
    final charge = Transaction(
        id: 'banco', date: DateTime(2026, 10, 6), type: TransactionType.expense, amountMinor: 36483, descriptionText: 'CARGO FICTICIO', sourceAccountId: 'cuenta', bankEntryKey: 'enable-entry:b');
    var notes = installmentNotes(data(p, [charge]), now);
    expect(notes.map((n) => n.id), ['installment:plan:2:charge:banco', 'installment:plan:1:overdue:2']);
    expect(notes.last.urgent, isTrue);
    expect(notes.every((n) => n.tab == 2), isTrue);
    notes = installmentNotes(data(p, [payment(p, 1, 50000, DateTime(2026, 9, 5)), payment(p, 2, 36483, DateTime(2026, 10, 5)), payment(p, 3, 36483, DateTime(2026, 11, 5))]), now);
    expect(notes.single.id, startsWith('installment:plan:schedule:'));
    // Archived plans and plans without incidents say nothing: Inicio stays clear.
    expect(installmentNotes(data(plan()), DateTime(2026, 11, 1)), isEmpty);
  });
}
