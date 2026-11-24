// Fictitious data only. The forecast made understandable (24 November 2026): incomes found even when the bank
// concept names the month, proposed for review and never duplicating a periodic payment; irregular incomes not
// assumed; late incomes; payments before the income and the recovery after it; reserves (free money is not the
// balance); no history; incomes written only for the forecast; the real past line; and Don Bigotes' summary.
import 'package:doblon/finance.dart';
import 'package:doblon/forecast.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 24, 12);
DateTime u(int month, int day, [int year = 2026]) => DateTime.utc(year, month, day);

Account account(String id, {AccountType type = AccountType.checking}) =>
    Account(id: id, name: 'Cuenta $id', type: type, openingDate: DateTime(2026, 1, 1), openingBalanceMinor: 0);

Transaction move(String id, DateTime date, TransactionType type, int minor, String description, {String account = 'a'}) => Transaction(
    id: id, date: date, type: type, amountMinor: minor, descriptionText: description, sourceAccountId: account, bankEntryKey: 'enable-entry:$id');

/// Salary on the 28th from July to October, named with the month as banks do; 1.000 € today from the bank.
List<Transaction> salaries({int day = 28, List<int> months = const [7, 8, 9, 10]}) => [
      for (final m in months)
        move('n$m', DateTime(2026, m, day, 9), TransactionType.income, 180000 + m, 'NOMINA ${['', 'ENERO', 'FEBRERO', 'MARZO', 'ABRIL', 'MAYO', 'JUNIO', 'JULIO', 'AGOSTO', 'SEPTIEMBRE', 'OCTUBRE', 'NOVIEMBRE', 'DICIEMBRE'][m]} EMPRESA FICTICIA'),
    ];

Finances data(
        {List<Transaction> transactions = const [],
        List<RecurringMovement> rules = const [],
        List<ReservedFund> funds = const [],
        List<Account>? accounts,
        List<BalanceSnapshot>? snapshots}) =>
    Finances(
      accounts: accounts ?? [account('a')],
      transactions: [...transactions]..sort((x, y) => y.date.compareTo(x.date)),
      recurringMovements: rules,
      reservedFunds: funds,
      snapshots: snapshots ?? [BalanceSnapshot(id: 's', date: DateTime(2026, 11, 24, 8), balanceMinor: 100000, accountId: 'a', source: 'bankAPI')],
    );

ForecastPlan plan(Finances d, [ForecastSettings settings = const ForecastSettings(horizonDays: 60)]) => buildForecast(FinanceCalculator(d), now, settings);

void main() {
  test('a salary named with the month is found, proposed for review and shows the recovery', () {
    expect(patternWords('NOMINA JULIO EMPRESA FICTICIA'), patternWords('NOMINA AGOSTO EMPRESA FICTICIA'));
    expect(patternWords('TRANSFERENCIA RECIBIDA NOMINA 10/2026 EMPRESA'), 'nomina empresa');
    final p = plan(data(transactions: salaries()));
    final incomes = p.events.where((e) => e.amountMinor > 0).toList();
    expect(incomes.map((e) => e.day), [u(11, 28), u(12, 28)]);
    expect(incomes.first.certainty, ForecastCertainty.estimated);
    expect(incomes.first.detail, contains('por revisar'));
    expect(p.pendingProposals.single.isIncome, isTrue);
    final r = simulateForecast(p);
    expect(r.totalFree[r.indexOf(u(11, 28))], greaterThan(r.totalFree[r.indexOf(u(11, 27))]), reason: 'The line goes up with the income');
    // Confirmed: no longer a proposal, still counted. Left out: not counted.
    final kept = plan(data(transactions: salaries()), p.settings.review(incomes.first.source, keep: true));
    expect(kept.pendingProposals, isEmpty);
    expect(kept.active.where((e) => e.amountMinor > 0).first.detail, contains('confirmado por ti'));
    final out = plan(data(transactions: salaries()), p.settings.review(incomes.first.source, keep: false));
    expect(out.hasIncome, isFalse);
  });

  test('a periodic salary is confirmed and the history does not propose it again', () {
    final rule = RecurringMovement(
        id: 'nomina',
        name: 'Nómina',
        type: TransactionType.income,
        amountMinor: 180000,
        descriptionText: 'Nómina',
        frequency: Frequency.monthly,
        nextDueDate: DateTime(2026, 11, 28, 9),
        sourceAccountId: 'a');
    final p = plan(data(transactions: salaries(), rules: [rule]));
    expect(p.events.where((e) => e.amountMinor > 0).map((e) => (e.day, e.certainty)), [(u(11, 28), ForecastCertainty.confirmed), (u(12, 28), ForecastCertainty.confirmed)]);
    expect(p.proposals, isEmpty, reason: 'Never duplicates a periodic payment');
  });

  test('irregular incomes are not assumed to come back, and that is said', () {
    final p = plan(data(transactions: [
      move('f1', DateTime(2026, 8, 5), TransactionType.income, 40000, 'FACTURA CLIENTE FICTICIO'),
      move('f2', DateTime(2026, 9, 22), TransactionType.income, 125000, 'FACTURA CLIENTE FICTICIO'),
      move('f3', DateTime(2026, 11, 2), TransactionType.income, 9000, 'FACTURA CLIENTE FICTICIO'),
    ]));
    expect(p.hasIncome, isFalse);
    expect(p.irregularIncomes, ['FACTURA CLIENTE FICTICIO']);
    expect(p.limitations.join(), contains('no se cuentan'));
    expect(forecastSummary(simulateForecast(p)).first, contains('No veo ingresos previstos'));
  });

  test('a late income is still expected for a week, today; later it is not counted and that is said', () {
    var p = plan(data(transactions: salaries(day: 20))); // usually on the 20th, today is the 24th
    expect(p.events.where((e) => e.amountMinor > 0).first.day, u(11, 24));
    expect(p.events.where((e) => e.amountMinor > 0).first.detail, contains('aún no ha llegado'));
    p = plan(data(transactions: salaries(day: 14, months: [7, 8, 9, 10])));
    expect(p.events.where((e) => e.amountMinor > 0).map((e) => e.day), [u(12, 14), u(1, 14, 2027)]);
    expect(p.limitations.join(), contains('no ha llegado este mes'));
  });

  test('payments before the income: the lowest point comes first and Don Bigotes says when it recovers', () {
    final rent = RecurringMovement(
        id: 'alquiler',
        name: 'Alquiler',
        type: TransactionType.expense,
        amountMinor: 90000,
        descriptionText: 'Alquiler',
        frequency: Frequency.monthly,
        nextDueDate: DateTime(2026, 11, 26, 9),
        sourceAccountId: 'a');
    final r = simulateForecast(plan(data(transactions: salaries(), rules: [rent]), const ForecastSettings(horizonDays: 30, useHistory: true)));
    expect(r.minimum, (10000, u(11, 26)));
    final moments = forecastMoments(r);
    expect(moments.map((m) => (m.kind, m.day)), containsAllInOrder([(MomentKind.lowest, u(11, 26)), (MomentKind.income, u(11, 28))]));
    expect(forecastSummary(r).first, startsWith('Bajarías a'));
    expect(forecastSummary(r).first, contains('te recuperas el 28/11'));
    final change = r.explain(u(11, 30));
    expect(change.incomes.single.$1.certainty, ForecastCertainty.estimated);
    expect(change.expenses.single.$1.certainty, ForecastCertainty.confirmed);
    expect(change.sureMinor, -90000);
    expect(change.endFree, change.startFree + change.incomeMinor + change.expenseMinor + change.variableMinor);
  });

  test('reserves: the free money is not the balance', () {
    final fund = ReservedFund(id: 'f', name: 'Viaje', amountMinor: 30000, accountId: 'a', createdAt: DateTime(2026, 6, 1));
    final r = simulateForecast(plan(data(funds: [fund]), const ForecastSettings(horizonDays: 30, useHistory: false)));
    final change = r.explain(u(12, 1));
    expect(change.endBalance - change.endFree, 30000);
    expect(r.pastBalance().length, ForecastPlan.pastDays);
  });

  test('without history: nothing invented, and the missing income is pointed out', () {
    final p = plan(data(), const ForecastSettings(horizonDays: 30));
    expect(p.hasIncome, isFalse);
    expect(p.events, isEmpty);
    final r = simulateForecast(p);
    expect(forecastMoments(r).where((m) => m.kind == MomentKind.income), isEmpty);
    expect(forecastSummary(r).first, contains('No veo ingresos previstos'));
  });

  test('an income written for the forecast counts until the real one arrives, which takes its place', () {
    const income = PlannedIncome(id: 'i', name: 'Nómina', amountMinor: 150000, dayOfMonth: 28, accountId: 'a');
    var p = plan(data(), const ForecastSettings(horizonDays: 40, useHistory: false, incomes: [income]));
    expect(p.events.map((e) => (e.day, e.certainty)), [(u(11, 28), ForecastCertainty.assumed), (u(12, 28), ForecastCertainty.assumed)]);
    // Arrived five days early, 3 % different: November is not counted again.
    p = plan(data(transactions: [move('real', DateTime(2026, 11, 23, 9), TransactionType.income, 154000, 'NOMINA')]),
        const ForecastSettings(horizonDays: 40, useHistory: false, incomes: [income]));
    expect(p.events.map((e) => e.day), [u(12, 28)]);
    // Recorded with a later date (on the 26th): it counts as recorded, once, and the expected one is not added.
    p = plan(data(transactions: [move('real', DateTime(2026, 11, 26, 9), TransactionType.income, 154000, 'NOMINA')]),
        const ForecastSettings(horizonDays: 40, useHistory: false, incomes: [income]));
    expect(p.events.map((e) => (e.day, e.certainty)), [(u(11, 26), ForecastCertainty.recorded), (u(12, 28), ForecastCertainty.assumed)]);
    // The same for a salary found in the history.
    p = plan(data(transactions: [...salaries(), move('nov', DateTime(2026, 11, 27, 9), TransactionType.income, 180011, 'NOMINA NOVIEMBRE EMPRESA FICTICIA')]));
    expect(p.events.where((e) => e.amountMinor > 0).map((e) => (e.day, e.certainty)), [(u(11, 27), ForecastCertainty.recorded), (u(12, 28), ForecastCertainty.estimated)]);
    expect(ForecastSettings.fromJson(const ForecastSettings(incomes: [income], accepted: {'pat:x'}).toJson()).incomes.single.amountMinor, 150000);
  });

  test('the past line is the real balance of each day', () {
    final p = plan(
        data(transactions: [move('compra', DateTime(2026, 11, 20, 12), TransactionType.expense, 5000, 'COMPRA')], snapshots: [
          BalanceSnapshot(id: 's', date: DateTime(2026, 11, 10, 8), balanceMinor: 100000, accountId: 'a', source: 'bankAPI'),
        ]),
        const ForecastSettings(horizonDays: 30, useHistory: false));
    final past = simulateForecast(p).pastBalance();
    expect(past[ForecastPlan.pastDays - 5], 100000, reason: '19/11: before the purchase');
    expect(past[ForecastPlan.pastDays - 4], 95000, reason: '20/11: after it');
    expect(p.starts.single.balanceMinor, 95000);
  });
}
