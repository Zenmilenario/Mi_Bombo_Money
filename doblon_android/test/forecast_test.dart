// Fictitious data only. The forecast and the «what if» simulations (23 November 2026): balances and free money
// day by day, reserves, own transfers, periodic payments replaced by the real movement, budgets that do not count a
// payment twice, little or old history, late or early payments, and simulations that never touch the finances.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/finance.dart';
import 'package:doblon/forecast.dart';
import 'package:doblon/forecast_store.dart';
import 'package:doblon/models.dart';
import 'package:doblon/presentation.dart' show money;
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 10, 12);
DateTime d(int month, int day, [int year = 2026]) => DateTime(year, month, day, 9);
DateTime u(int month, int day, [int year = 2026]) => DateTime.utc(year, month, day);

Account account(String id, {AccountType type = AccountType.checking, String? bank}) =>
    Account(id: id, name: 'Cuenta $id', type: type, openingDate: DateTime(2025, 1, 1), bankIdentityKey: bank);

BalanceSnapshot bankBalance(String account, int minor, DateTime date, {String source = 'bankAPI'}) =>
    BalanceSnapshot(id: 'snap-$account-${date.millisecondsSinceEpoch}', date: date, balanceMinor: minor, accountId: account, source: source);

Transaction move(String id, DateTime date, TransactionType type, int minor,
        {String account = 'a', String? to, String description = 'Movimiento', String? category, String? rule, String? fund, int? reserved}) =>
    Transaction(
        id: id,
        date: date,
        type: type,
        amountMinor: minor,
        descriptionText: description,
        sourceAccountId: account,
        destinationAccountId: to,
        categoryId: category,
        recurringMovementId: rule,
        reservedFundId: fund,
        reservedAmountMinor: reserved);

RecurringMovement rule(String id, TransactionType type, int minor, DateTime next, {String account = 'a', String? to, String? category}) => RecurringMovement(
    id: id,
    name: 'Pago $id',
    type: type,
    amountMinor: minor,
    descriptionText: 'Pago $id',
    frequency: Frequency.monthly,
    nextDueDate: next,
    sourceAccountId: account,
    destinationAccountId: to,
    categoryId: category);

/// One account with 1.000 € from the bank today, older history so the estimates are not limited.
Finances base(
        {List<Account>? accounts,
        List<Transaction> transactions = const [],
        List<RecurringMovement> rules = const [],
        List<BalanceSnapshot>? snapshots,
        List<ReservedFund> funds = const [],
        List<Category> categories = const [],
        List<RecurringBudget> budgets = const [],
        List<SavingsGoal> goals = const []}) =>
    Finances(
      accounts: accounts ?? [account('a')],
      transactions: [...transactions]..sort((x, y) => y.date.compareTo(x.date)),
      recurringMovements: rules,
      snapshots: snapshots ?? [bankBalance('a', 100000, d(11, 10))],
      reservedFunds: funds,
      categories: categories,
      recurringBudgets: budgets,
      goals: goals,
    );

ForecastPlan plan(Finances data, {ForecastSettings settings = const ForecastSettings(horizonDays: 30, useHistory: false), List<(String, int)> holds = const []}) =>
    buildForecast(FinanceCalculator(data), now, settings, holds: holds);

void main() {
  test('periodic payments and incomes move the balance on their day; the starting balance says where it comes from', () {
    final p = plan(base(rules: [
      rule('alquiler', TransactionType.expense, 60000, d(11, 15)),
      rule('nomina', TransactionType.income, 150000, d(11, 28)),
    ]));
    final r = simulateForecast(p);
    expect(p.starts.single.basis, StartBasis.bank);
    expect(p.starts.single.basisText, 'Saldo recibido del banco el 10/11');
    expect(r.totalFree[r.indexOf(u(11, 14))], 100000);
    expect(r.totalFree[r.indexOf(u(11, 15))], 40000);
    expect(r.totalFree[r.indexOf(u(11, 28))], 190000);
    expect(r.minimum, (40000, u(11, 15)));
    expect(p.events.where((e) => e.source == 'rec:alquiler').map((e) => e.day), [u(11, 15), u(12, 15)].where((day) => !day.isAfter(p.end)));
    expect(p.events.every((e) => e.certainty == ForecastCertainty.confirmed), isTrue);
  });

  test('reserved money is not free; paying with a reserve lowers balance and reserve once, and leaves the free money', () {
    final fund = ReservedFund(id: 'viaje', name: 'Viaje', amountMinor: 30000, accountId: 'a', createdAt: d(10, 1));
    final p = plan(base(funds: [fund]));
    final r = simulateForecast(p);
    expect(r.totalFree.first, 70000, reason: '1.000 € minus 300 € set aside');
    final paid = Scenario(id: 's', name: 'Billetes', changes: [ScenarioChange(kind: ScenarioKind.purchase, amountMinor: 20000, day: u(11, 20), accountId: 'a', reserveId: 'viaje')]);
    final withReserve = simulateForecast(p, scenarioEvents(p, paid));
    final i = withReserve.indexOf(u(11, 20));
    expect(withReserve.balance()[i], 80000);
    expect(withReserve.reserved['a']![i], 10000);
    expect(withReserve.totalFree[i], 70000, reason: 'The reserve paid it: nothing taken twice from the free money');
    final comparison = ScenarioComparison(r, withReserve, paid);
    expect(comparison.reserveChange, -20000);
    expect(comparison.summary, contains('Usa ${money(20000)} de tus reservas.'));

    final notFromReserve = Scenario(id: 't', name: 'Billetes', changes: [ScenarioChange(kind: ScenarioKind.purchase, amountMinor: 20000, day: u(11, 20), accountId: 'a')]);
    final plain = simulateForecast(p, scenarioEvents(p, notFromReserve));
    expect(plain.totalFree[i], 50000);
    expect(ScenarioComparison(r, plain, notFromReserve).summary, contains('Tus reservas no se tocan.'));
  });

  test('a transfer between own accounts moves money between them without creating income or spending', () {
    final p = plan(base(
      accounts: [account('a'), account('b', type: AccountType.savings)],
      snapshots: [bankBalance('a', 100000, d(11, 10)), bankBalance('b', 50000, d(11, 10))],
      rules: [rule('ahorro', TransactionType.transfer, 20000, d(11, 12), to: 'b')],
    ));
    final r = simulateForecast(p);
    final i = r.indexOf(u(11, 12));
    expect(r.balance('a')[i], 80000);
    expect(r.balance('b')[i], 70000);
    expect(r.totalFree[i], 150000, reason: 'The total does not change');
  });

  test('the real movement replaces its forecast: arrived early, late, or recorded with a future date', () {
    // Paid two days early from the bank (no link to the periodic payment): not counted again on its day.
    var p = plan(base(
      rules: [rule('luz', TransactionType.expense, 5000, d(11, 12))],
      transactions: [move('banco-luz', d(11, 10), TransactionType.expense, 5200, description: 'RECIBO LUZ')],
    ));
    expect(p.events.where((e) => e.day == u(11, 12)), isEmpty);

    // Due three days ago and not arrived: still expected, today, and said so.
    p = plan(base(rules: [rule('agua', TransactionType.expense, 3000, d(11, 7))]));
    final late = p.events.where((e) => e.source == 'rec:agua').first;
    expect(late.day, u(11, 10));
    expect(late.detail, contains('aún no ha llegado'));
    // Arrived late, after its day: replaced.
    p = plan(base(
      rules: [rule('agua', TransactionType.expense, 3000, d(11, 7))],
      transactions: [move('banco-agua', d(11, 9), TransactionType.expense, 3000)],
    ));
    expect(p.events.where((e) => e.source == 'rec:agua' && e.day.month == 11), isEmpty);

    // Recorded with a future date and linked to its periodic payment: it counts once, as recorded.
    p = plan(base(
      rules: [rule('cuota', TransactionType.expense, 4000, d(11, 20))],
      transactions: [move('cuota-nov', d(11, 20), TransactionType.expense, 4000, rule: 'cuota')],
    ));
    final r = simulateForecast(p);
    expect(p.events.where((e) => e.day == u(11, 20)).map((e) => e.certainty), [ForecastCertainty.recorded]);
    expect(r.totalFree[r.indexOf(u(11, 20))], 96000);
  });

  test('a budget includes the payments of its category: only what it leaves free is added', () {
    final home = Category(id: 'hogar', name: 'Hogar', kind: CategoryKind.expense);
    final p = plan(base(
      categories: [home],
      budgets: [RecurringBudget(id: 'b', startMonth: DateTime(2026, 1), baseLimitMinor: 70000, remainderChoice: RemainderChoice.save, categoryId: 'hogar')],
      rules: [rule('alquiler', TransactionType.expense, 60000, d(11, 15), category: 'hogar')],
    ));
    final variableNovember = p.events.where((e) => e.isVariable && e.day.month == 11).fold(0, (sum, e) => sum - e.amountMinor);
    expect(variableNovember, 10000, reason: '700 € budget minus the 600 € rent already in the forecast');
    expect(p.variableFromBudgetsMinor, 10000);
  });

  test('little history: no invented estimates, and the limit is said', () {
    final p = plan(
        base(transactions: [move('x', d(11, 1), TransactionType.expense, 2000, description: 'Super')]),
        settings: const ForecastSettings(horizonDays: 30));
    expect(p.events.where((e) => e.isVariable), isEmpty);
    expect(p.limitations.join(), contains('Poco historial'));
  });

  test('old data is pointed out, and a balance without a bank or manual figure is shown as calculated', () {
    var p = plan(base(snapshots: [bankBalance('a', 100000, d(10, 21))]));
    expect(p.limitations, contains('El saldo de «Cuenta a» es de hace 20 días.'));
    p = plan(base(snapshots: const []));
    expect(p.starts.single.basis, StartBasis.computed);
    expect(p.limitations.join(), contains('saldo calculado con tus movimientos'));
  });

  test('repeated in the history: an estimate on its usual day, once it has arrived only from the next month; late, today', () {
    final salary = [
      for (final month in [7, 8, 9, 10]) move('n$month', d(month, 28), TransactionType.income, 180000 + month, description: 'NOMINA EMPRESA FICTICIA $month'),
    ];
    var p = plan(base(transactions: salary), settings: const ForecastSettings(horizonDays: 30));
    final next = p.events.where((e) => e.source.startsWith('pat:')).single;
    expect(next.day, u(11, 28));
    expect(next.certainty, ForecastCertainty.estimated);

    // Usually on the 8th: two days late, still expected today.
    final early = [for (final month in [7, 8, 9, 10]) move('m$month', d(month, 8), TransactionType.income, 90000, description: 'PENSION FICTICIA')];
    p = plan(base(transactions: early), settings: const ForecastSettings(horizonDays: 30));
    final pension = p.events.where((e) => e.source.startsWith('pat:')).toList();
    expect(pension.first.day, u(11, 10));
    expect(pension.first.detail, contains('aún no ha llegado'));
    // Arrived this month: not counted again until December.
    p = plan(base(transactions: [...early, move('m11', d(11, 9), TransactionType.income, 90000, description: 'PENSION FICTICIA')]),
        settings: const ForecastSettings(horizonDays: 30));
    expect(p.events.where((e) => e.source.startsWith('pat:')).map((e) => e.day), [u(12, 8)]);
  });

  test('assumptions can be switched off or changed without touching the payments', () {
    final data = base(rules: [rule('gimnasio', TransactionType.expense, 4000, d(11, 15))]);
    var p = plan(data, settings: const ForecastSettings(horizonDays: 30, useHistory: false, excluded: {'rec:gimnasio'}));
    expect(simulateForecast(p).endFree, 100000);
    p = plan(data, settings: const ForecastSettings(horizonDays: 30, useHistory: false, amounts: {'rec:gimnasio': 2500}));
    expect(simulateForecast(p).endFree, 97500);
    expect(data.recurringMovements.single.amountMinor, 4000);
  });

  test('simulations: a monthly expense, a late and smaller income, and setting money aside', () {
    final fund = ReservedFund(id: 'colchon', name: 'Imprevistos', amountMinor: 0, accountId: 'a', createdAt: d(1, 1));
    final p = plan(
        base(funds: [fund], rules: [rule('nomina', TransactionType.income, 150000, d(11, 28))]),
        settings: const ForecastSettings(horizonDays: 60, useHistory: false, cushionMinor: 50000));
    final r = simulateForecast(p);

    final gym = Scenario(id: 'g', name: 'Gimnasio', changes: [ScenarioChange(kind: ScenarioKind.monthlyExpense, amountMinor: 3000, day: u(11, 20))]);
    expect(scenarioEvents(p, gym).where((e) => e.source == 'sim:g').map((e) => e.day), [u(11, 20), u(12, 20)]);

    final late = Scenario(id: 'l', name: 'Retraso', changes: [
      ScenarioChange(kind: ScenarioKind.incomeChange, amountMinor: -20000, day: u(11, 10), incomeSource: 'rec:nomina', delayDays: 5),
    ]);
    final events = scenarioEvents(p, late);
    expect(events.where((e) => e.source == 'rec:nomina').map((e) => (e.day, e.amountMinor)), [(u(12, 3), 130000), (u(1, 2, 2027), 130000)]);
    expect(p.active.where((e) => e.source == 'rec:nomina').first.day, u(11, 28), reason: 'The base forecast is left as it was');

    final saving = Scenario(id: 'r', name: 'Apartar', changes: [
      ScenarioChange(kind: ScenarioKind.reserveContribution, amountMinor: 60000, day: u(11, 12), reserveId: 'colchon'),
    ]);
    final s = simulateForecast(p, scenarioEvents(p, saving));
    final i = s.indexOf(u(11, 12));
    expect(s.balance()[i], 100000, reason: 'Set aside in the same account: the balance does not change');
    expect(s.totalFree[i], 40000);
    final comparison = ScenarioComparison(r, s, saving);
    expect(comparison.summary.first, 'Bajarías del colchón el 12/11.');
    expect(comparison.summary, contains('Aparta ${money(60000)} más en tus reservas.'));
  });

  test('the comparison names the accounts and goals affected and the new shortfalls', () {
    final goal = SavingsGoal(id: 'g', name: 'Coche', targetAmountMinor: 500000, linkedAccountId: 'b');
    final p = plan(base(
      accounts: [account('a'), account('b', type: AccountType.savings)],
      snapshots: [bankBalance('a', 10000, d(11, 10)), bankBalance('b', 300000, d(11, 10))],
      goals: [goal],
    ));
    final r = simulateForecast(p);
    final buy = Scenario(id: 'p', name: 'Portátil', changes: [ScenarioChange(kind: ScenarioKind.purchase, amountMinor: 120000, day: u(11, 15), accountId: 'b')]);
    final c = ScenarioComparison(r, simulateForecast(p, scenarioEvents(p, buy)), buy);
    expect(c.affectedAccounts.map((a) => a.id), ['b']);
    expect(c.affectedGoals.map((g) => g.name), ['Coche']);
    expect(c.minimumChange, -120000);

    final big = Scenario(id: 'q', name: 'Sofá', changes: [ScenarioChange(kind: ScenarioKind.purchase, amountMinor: 30000, day: u(11, 15), accountId: 'a')]);
    final c2 = ScenarioComparison(r, simulateForecast(p, scenarioEvents(p, big)), big);
    expect(c2.summary, contains('«Cuenta a» se quedaría sin saldo el 15/11.'));
  });

  test('Don Bigotes: an account short for a charge while another one has money, and the cushion; never the variable spending', () {
    final p = plan(
        base(
          accounts: [account('a'), account('b', type: AccountType.savings)],
          snapshots: [bankBalance('a', 5000, d(11, 10)), bankBalance('b', 200000, d(11, 10))],
          rules: [rule('seguro', TransactionType.expense, 30000, d(11, 13))],
        ),
        settings: const ForecastSettings(horizonDays: 30, useHistory: false, cushionMinor: 190000));
    final notes = forecastNotes(simulateForecast(p));
    expect(notes.map((n) => n.id), ['forecast:account:a:2026-11-13', 'forecast:cushion:2026-11-13']);
    expect(notes.first.title, '«Cuenta a» podría quedarse sin saldo el 13/11');
    expect(notes.first.detail, 'Pago seguro (${money(30000)}, confirmado). En otras cuentas tienes dinero libre suficiente.');
    expect(notes.first.urgent, isTrue);
    expect(notes.last.detail, contains('Pago seguro'));
  });

  test('bank holds are already taken from the money available today', () {
    final p = plan(base(), holds: [('a', -2500)]);
    expect(simulateForecast(p).totalFree.first, 97500);
  });

  test('assumptions and simulations are kept on the device apart from the finances, and read back', () async {
    final directory = await Directory.systemTemp.createTemp('doblon-forecast');
    addTearDown(() => directory.delete(recursive: true));
    final store = await ForecastStore.open(directory, 'persona-ficticia');
    await store.saveSettings(const ForecastSettings(horizonDays: 90, cushionMinor: 50000, excluded: {'var'}));
    await store.saveScenario(Scenario(id: 's1', name: 'Portátil', changes: [ScenarioChange(kind: ScenarioKind.purchase, amountMinor: 90000, day: u(11, 20))]));
    await store.saveScenario(Scenario(id: 's2', name: 'Gimnasio', changes: [ScenarioChange(kind: ScenarioKind.monthlyExpense, amountMinor: 3000, day: u(12, 1))]));
    await store.saveScenario(Scenario(id: 's1', name: 'Portátil nuevo', changes: [ScenarioChange(kind: ScenarioKind.purchase, amountMinor: 95000, day: u(11, 21))]));
    await store.deleteScenario('s2');
    final again = await ForecastStore.open(directory, 'persona-ficticia');
    expect(again.settings.horizonDays, 90);
    expect(again.settings.cushionMinor, 50000);
    expect(again.settings.excluded, {'var'});
    expect(again.scenarios.map((s) => (s.name, s.changes.single.amountMinor, s.changes.single.day)), [('Portátil nuevo', 95000, u(11, 21))]);
    expect(directory.listSync().map((f) => f.uri.pathSegments.last), ['forecast-persona-ficticia.json'], reason: 'Its own file, nothing else');
    expect(jsonDecode(await ForecastStore.fileFor(directory, 'persona-ficticia').readAsString()), isNot(contains('transactions')));
  });

  test('the forecast cannot write: it does not use the repository, the operations or the learning', () {
    for (final file in ['lib/forecast.dart', 'lib/forecast_store.dart']) {
      final imports = File(file).readAsLinesSync().where((l) => l.startsWith('import'));
      for (final forbidden in ['data.dart', 'edits.dart', 'learning.dart', 'supabase']) {
        expect(imports.any((l) => l.contains(forbidden)), isFalse, reason: '$file must not import $forbidden');
      }
    }
  });
}
