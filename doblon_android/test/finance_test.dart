// Same fictitious cases as Tests/FinancialLogicCheck.swift: Android must give the iPhone's numbers.
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime date(int month, [int day = 1]) => DateTime(2024, month, day, 12);

Account account(String id, {int opening = 0, DateTime? openingDate, AccountType type = AccountType.checking}) =>
    Account(id: id, name: 'Cuenta $id', type: type, openingBalanceMinor: opening, openingDate: openingDate ?? date(1));

Transaction tx(String id, DateTime date, TransactionType type, int amount,
        {String? source, String? destination, String? category, String? fund, int? reserved}) =>
    Transaction(
        id: id,
        date: date,
        type: type,
        amountMinor: amount,
        descriptionText: 'Movimiento ficticio',
        sourceAccountId: source,
        destinationAccountId: destination,
        categoryId: category,
        reservedFundId: fund,
        reservedAmountMinor: reserved);

/// The reference rule, written the slow way: every movement read for each balance.
int scannedBalance(Account a, DateTime at, List<Transaction> txs, List<BalanceSnapshot> snaps) {
  int effect(Transaction t) {
    final isSource = t.sourceAccountId == a.id, isDestination = t.destinationAccountId == a.id;
    return switch (t.type) {
      TransactionType.income || TransactionType.interest => isSource ? t.amountMinor : 0,
      TransactionType.expense || TransactionType.fee => isSource ? -t.amountMinor : 0,
      TransactionType.transfer => isSource ? -t.amountMinor : (isDestination ? t.amountMinor : 0),
    };
  }

  final own = snaps.where((s) => s.accountId == a.id && !s.date.isAfter(at)).toList()..sort((x, y) => y.date.compareTo(x.date));
  if (own.isNotEmpty) {
    return own.first.balanceMinor + txs.where((t) => t.date.isAfter(own.first.date) && !t.date.isAfter(at)).fold(0, (s, t) => s + effect(t));
  }
  if (a.openingDate.isAfter(at)) return 0;
  return a.openingBalanceMinor + txs.where((t) => !t.date.isBefore(a.openingDate) && !t.date.isAfter(at)).fold(0, (s, t) => s + effect(t));
}

void main() {
  test('the balance index agrees with the slow rule on every account and date, edges included', () {
    final current = account('corriente', opening: 50000, openingDate: date(1, 10));
    final savings = account('ahorro', type: AccountType.savings);
    final investing = account('inversion', openingDate: date(2), type: AccountType.investment);
    final accounts = [current, savings, investing];
    const kinds = [
      TransactionType.expense,
      TransactionType.income,
      TransactionType.transfer,
      TransactionType.fee,
      TransactionType.interest,
      TransactionType.transfer
    ];
    final txs = <Transaction>[];
    for (var i = 0; i < 60; i++) {
      final kind = kinds[i % kinds.length];
      final source = accounts[i % 3];
      final destination = kind == TransactionType.transfer ? [savings, investing, current, source][i % 4] : null;
      txs.add(tx('t$i', date(1 + i % 6, 1 + i % 27), kind, 100 + i * 37, source: source.id, destination: destination?.id));
    }
    txs.add(tx('borde', date(1, 10), TransactionType.expense, 999, source: current.id));
    txs.add(tx('mismo-dia', date(3, 15), TransactionType.income, 555, source: savings.id));
    final snaps = [
      BalanceSnapshot(id: 's1', date: date(3, 15), balanceMinor: 12345, accountId: savings.id),
      BalanceSnapshot(id: 's2', date: date(5, 2), balanceMinor: 20000, accountId: savings.id),
      BalanceSnapshot(id: 's3', date: date(4, 1), balanceMinor: 7000, accountId: investing.id),
    ];
    final index = BalanceIndex(txs, snaps);
    for (final a in accounts) {
      for (final when in [date(1), date(1, 10), date(2, 14), date(3, 15), date(4, 20), date(5, 2), date(7), DateTime(2000)]) {
        expect(index.balance(a, when), scannedBalance(a, when, txs, snaps), reason: '${a.id} at $when');
      }
    }
  });

  test('a reserved payment lowers the balance and the reserve, not the free money twice', () {
    final current = account('corriente', opening: 100000);
    final fund = ReservedFund(id: 'f', name: 'Máster', amountMinor: 60000, accountId: current.id);
    final payment = tx('p', date(1, 5), TransactionType.expense, 20000, source: current.id, fund: fund.id, reserved: 20000);
    final calc = FinanceCalculator(Finances(accounts: [current], transactions: [payment], reservedFunds: [fund]));
    expect(calc.balance(current), 80000);
    expect(calc.reservedAmount(current), 40000);
    expect(calc.spendableCash(), 40000);
  });

  test('a transfer moves reserved money between accounts; an unfunded history is rejected', () {
    final origin = account('origen', opening: 100000);
    final destination = account('destino', opening: 10000);
    final fund = ReservedFund(id: 'f', name: 'Vacaciones', amountMinor: 30000, accountId: origin.id);
    final move = tx('m', date(1, 3), TransactionType.transfer, 25000, source: origin.id, destination: destination.id, fund: fund.id, reserved: 20000);
    final calc = FinanceCalculator(Finances(accounts: [origin, destination], transactions: [move], reservedFunds: [fund]));
    expect(calc.reservedAmount(origin), 10000);
    expect(calc.reservedAmount(destination), 20000);
    expect(calc.spendableCash(), (100000 - 25000 - 10000) + (10000 + 25000 - 20000));
    final entries = [ReservedEntry(id: 'x', date: date(1), source: 'a', amount: 50)];
    expect(reservedBalances('a', 40, entries), isNull, reason: 'Paying more than the reserve holds');
  });

  test('budgets exclude reserved payments and carry forward unspent money (Swift: 35.000 → 85.000)', () {
    final current = account('corriente', opening: 100000);
    final category = Category(id: 'formacion', name: 'Formación', kind: CategoryKind.expense);
    const fund = 'fondo';
    final payment = tx('p', date(1, 5), TransactionType.expense, 20000, source: current.id, category: category.id, fund: fund, reserved: 20000);
    final mixed = tx('m', date(1, 6), TransactionType.expense, 30000, source: current.id, category: category.id, fund: fund, reserved: 20000);
    final ordinary = tx('o', date(1, 7), TransactionType.expense, 5000, source: current.id, category: category.id);
    final budget = MonthlyBudget(id: 'b', monthStart: date(1), limitMinor: 15000, categoryId: category.id);
    BudgetProgress progress(List<Transaction> txs) =>
        FinanceCalculator(Finances(accounts: [current], categories: [category], transactions: txs, budgets: [budget])).budgetProgress(date(1))[0];
    expect(progress([payment]).spentMinor, 0, reason: 'A fully reserved payment does not consume budget');
    expect(progress([mixed]).spentMinor, 10000);
    expect(progress([payment, mixed, ordinary]).spentMinor, 15000);
    expect(progress([payment, mixed, ordinary]).fraction, 1);

    final summary = FinanceCalculator(Finances(transactions: [payment, mixed, ordinary])).monthlySummary(date(1));
    expect(summary.expenseMinor, 55000);
    expect(summary.reservedExpenseMinor, 40000);
    expect(summary.budgetExpenseMinor, 15000);
    expect(summary.netSavingsMinor, -55000);

    final plan = RecurringBudget(id: 'r', startMonth: date(1), baseLimitMinor: 50000, remainderChoice: RemainderChoice.carryForward, categoryId: category.id);
    final calc = FinanceCalculator(Finances(categories: [category], transactions: [payment, mixed, ordinary], recurringBudgets: [plan]));
    final spent = <int, int>{monthKey(date(1)): 15000};
    final carried = FinanceCalculator.budgetLimit(category, date(2), const [], [plan], spent, asOf: date(2, 15));
    expect(carried.carriedInMinor, 35000);
    expect(carried.limitMinor, 85000);
    final viaProgress = calc.budgetProgress(date(2), asOf: date(2, 15)).first;
    expect(viaProgress.limitMinor, 85000);
    expect(viaProgress.carriedInMinor, 35000);
    expect(viaProgress.isRecurring, isTrue);
  });

  test('a monthly override replaces the plan and carries nothing in', () {
    final category = Category(id: 'c', name: 'Ocio', kind: CategoryKind.expense);
    final plan = RecurringBudget(id: 'r', startMonth: date(1), baseLimitMinor: 10000, remainderChoice: RemainderChoice.carryForward, categoryId: 'c');
    final override = MonthlyBudget(id: 'o', monthStart: date(2), limitMinor: 3000, categoryId: 'c');
    final limit = FinanceCalculator.budgetLimit(category, date(2), [override], [plan], const {}, asOf: date(3));
    expect(limit.limitMinor, 3000);
    expect(limit.carriedInMinor, 0);
  });

  test('net worth counts only included, active accounts', () {
    final included = account('a', opening: 1000);
    final hidden = Account(id: 'b', name: 'Fuera', type: AccountType.checking, openingBalanceMinor: 5000, openingDate: date(1), includeInNetWorth: false);
    final archived = Account(id: 'c', name: 'Archivada', type: AccountType.checking, openingBalanceMinor: 7000, openingDate: date(1), isArchived: true);
    final calc = FinanceCalculator(Finances(accounts: [included, hidden, archived]));
    expect(calc.netWorth(), 1000);
  });
}
