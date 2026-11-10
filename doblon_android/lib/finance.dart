// The same accounting rules as the iPhone app (`FinanceCalculator.swift`, `ReservedLedger.swift`).
// Any change here must keep the results of the Swift version; `test/finance_test.dart` repeats its cases.
import 'models.dart';

/// Every movement's effect on each account, sorted by date with running totals, so a balance is two
/// binary searches (Swift: `AccountBalanceIndex`).
class BalanceIndex {
  BalanceIndex(List<Transaction> transactions, List<BalanceSnapshot> snapshots) {
    final effects = <String, List<(DateTime, int)>>{};
    void add(String? account, DateTime date, int effect) {
      if (account != null) (effects[account] ??= []).add((date, effect));
    }

    for (final t in transactions) {
      final amount = t.amountMinor.abs();
      switch (t.type) {
        case TransactionType.income:
        case TransactionType.interest:
          add(t.sourceAccountId, t.date, amount);
        case TransactionType.expense:
        case TransactionType.fee:
          add(t.sourceAccountId, t.date, -amount);
        case TransactionType.transfer:
          add(t.sourceAccountId, t.date, -amount);
          if (t.destinationAccountId != t.sourceAccountId) add(t.destinationAccountId, t.date, amount);
      }
    }
    effects.forEach((account, list) {
      list.sort((a, b) => a.$1.compareTo(b.$1));
      var running = 0;
      final dates = <DateTime>[], totals = <int>[];
      for (final (date, effect) in list) {
        running += effect;
        dates.add(date);
        totals.add(running);
      }
      _ledgers[account] = (dates, totals);
    });
    for (final s in snapshots) {
      if (s.accountId != null) (_snapshots[s.accountId!] ??= []).add(s);
    }
    for (final list in _snapshots.values) {
      list.sort((a, b) => b.date.compareTo(a.date));
    }
  }

  final _ledgers = <String, (List<DateTime>, List<int>)>{};
  final _snapshots = <String, List<BalanceSnapshot>>{};

  /// Sum of effects dated on or before `date` (`inclusive`) or strictly before it.
  int _sum(String account, DateTime date, {required bool inclusive}) {
    final ledger = _ledgers[account];
    if (ledger == null) return 0;
    final (dates, totals) = ledger;
    var low = 0, high = dates.length;
    while (low < high) {
      final middle = (low + high) ~/ 2;
      final before = inclusive ? !dates[middle].isAfter(date) : dates[middle].isBefore(date);
      if (before) {
        low = middle + 1;
      } else {
        high = middle;
      }
    }
    return low == 0 ? 0 : totals[low - 1];
  }

  /// Latest known balance plus later movements; without one, the opening balance plus movements since opening.
  int balance(Account account, [DateTime? at]) {
    final date = at ?? DateTime.now();
    final latest = _snapshots[account.id]?.where((s) => !s.date.isAfter(date)).firstOrNull;
    if (latest != null) {
      return latest.balanceMinor + _sum(account.id, date, inclusive: true) - _sum(account.id, latest.date, inclusive: true);
    }
    if (account.openingDate.isAfter(date)) return 0;
    return account.openingBalanceMinor + _sum(account.id, date, inclusive: true) - _sum(account.id, account.openingDate, inclusive: false);
  }
}

class ReservedEntry {
  ReservedEntry({required this.id, required this.date, required this.source, this.destination, required this.amount});
  final String id;
  final DateTime date;
  final String source;
  final String? destination;
  final int amount;
  bool get isTransfer => destination != null;
}

/// Where a reserve's money is, account by account (Swift: `ReservedLedger.balances`). A transfer moves
/// reserved money; only an expense consumes it. Returns null when the history is not valid.
Map<String, int>? reservedBalances(String origin, int funding, List<ReservedEntry> entries, {DateTime? through}) {
  if (funding < 0) return null;
  final balances = <String, int>{origin: funding};
  final groups = <DateTime, List<ReservedEntry>>{};
  for (final entry in entries) {
    if (through == null || !entry.date.isAfter(through)) (groups[entry.date] ??= []).add(entry);
  }
  for (final instant in groups.keys.toList()..sort()) {
    final group = groups[instant]!;
    if (!group.every((e) => e.amount > 0 && e.destination != e.source)) return null;
    final pending = group.where((e) => e.isTransfer).toList()..sort((a, b) => a.id.toUpperCase().compareTo(b.id.toUpperCase()));
    // Transfers at the same instant may form a chain, but an unfunded circle never creates money.
    while (pending.isNotEmpty) {
      final index = pending.indexWhere((e) => (balances[e.source] ?? 0) >= e.amount);
      if (index < 0) return null;
      final entry = pending.removeAt(index);
      balances[entry.source] = (balances[entry.source] ?? 0) - entry.amount;
      balances[entry.destination!] = (balances[entry.destination!] ?? 0) + entry.amount;
    }
    for (final entry in group.where((e) => !e.isTransfer)) {
      if ((balances[entry.source] ?? 0) < entry.amount) return null;
      balances[entry.source] = (balances[entry.source] ?? 0) - entry.amount;
    }
  }
  return balances;
}

class MonthlySummary {
  MonthlySummary(this.incomeMinor, this.expenseMinor, this.reservedExpenseMinor);
  final int incomeMinor;
  final int expenseMinor;
  final int reservedExpenseMinor;
  int get budgetExpenseMinor => expenseMinor - reservedExpenseMinor;
  int get netSavingsMinor => incomeMinor - expenseMinor;
}

class BudgetLimit {
  BudgetLimit(this.limitMinor, this.carriedInMinor, this.isRecurring);
  final int limitMinor;
  final int carriedInMinor;
  final bool isRecurring;
}

class BudgetProgress {
  BudgetProgress({required this.category, required this.limitMinor, required this.spentMinor, this.carriedInMinor = 0, this.isRecurring = false});
  final Category category;
  final int limitMinor;
  final int spentMinor;
  final int carriedInMinor;
  final bool isRecurring;
  int get availableMinor => limitMinor - spentMinor;
  double get fraction => limitMinor > 0 ? spentMinor / limitMinor : 0;
  String get statusText {
    if (limitMinor <= 0) return 'Sin presupuesto';
    if (spentMinor > limitMinor) return 'Superado';
    if (fraction >= 0.85) return 'Cerca del límite';
    return 'Dentro';
  }
}

class FinanceCalculator {
  FinanceCalculator(this.data) : index = BalanceIndex(data.transactions, data.snapshots);
  final Finances data;
  final BalanceIndex index;

  int balance(Account account, [DateTime? at]) => index.balance(account, at);

  /// The saved allocation is the funding history, even after the reserve is exhausted.
  static int reservedExpenseAmount(Transaction t) {
    if (!t.type.countsAsExpense || t.reservedFundId == null) return 0;
    final reserved = t.reservedAmountMinor ?? 0;
    return reserved < 0 ? 0 : (reserved < t.amountMinor ? reserved : t.amountMinor);
  }

  static int budgetExpenseAmount(Transaction t) => t.type.countsAsExpense ? t.amountMinor.abs() - reservedExpenseAmount(t) : 0;

  List<ReservedEntry> reserveEntries(ReservedFund fund) => [
        for (final t in data.transactions)
          if (t.reservedFundId == fund.id &&
              (t.type.countsAsExpense || t.type == TransactionType.transfer) &&
              t.sourceAccountId != null &&
              t.reservedAmountMinor != null)
            ReservedEntry(
                id: t.id,
                date: t.date,
                source: t.sourceAccountId!,
                destination: t.type == TransactionType.transfer ? t.destinationAccountId : null,
                amount: t.reservedAmountMinor!),
      ];

  /// Reserved money located in this account now, across every reserve.
  int reservedAmount(Account account) {
    var total = 0;
    for (final fund in data.reservedFunds) {
      if (fund.accountId == null) continue;
      total += reservedBalances(fund.accountId!, fund.amountMinor, reserveEntries(fund), through: DateTime.now())?[account.id] ?? 0;
    }
    return total;
  }

  Iterable<Account> get _counted => data.accounts.where((a) => !a.isArchived && a.includeInNetWorth);

  int netWorth([DateTime? at]) => _counted.fold(0, (sum, a) => sum + balance(a, at));

  /// Cash you can spend: current, savings and cash accounts, minus the money reserved in them.
  int spendableCash() =>
      _counted.where((a) => a.type != AccountType.investment && !a.type.isLiability).fold(0, (sum, a) => sum + balance(a) - reservedAmount(a));

  int invested() => _counted.where((a) => a.type == AccountType.investment).fold(0, (sum, a) => sum + balance(a));

  MonthlySummary monthlySummary(DateTime month) {
    final key = monthKey(month);
    var income = 0, expense = 0, reserved = 0;
    for (final t in data.transactions) {
      if (monthKey(t.date) != key) continue;
      if (t.type.countsAsIncome) income += t.amountMinor.abs();
      if (t.type.countsAsExpense) expense += t.amountMinor.abs();
      reserved += reservedExpenseAmount(t);
    }
    return MonthlySummary(income, expense, reserved);
  }

  static RecurringBudget? activeRecurringBudget(Category category, int month, List<RecurringBudget> plans) {
    RecurringBudget? best;
    for (final plan in plans) {
      if (plan.categoryId != category.id) continue;
      final start = monthKey(plan.startMonth);
      final end = plan.endMonth == null ? null : monthKey(plan.endMonth!);
      if (start <= month && (end == null || month < end) && (best == null || plan.startMonth.isAfter(best.startMonth))) best = plan;
    }
    return best;
  }

  /// The limit of a month, with what a carry-forward plan brings from earlier months
  /// (Swift: `FinanceCalculator.budgetLimit`). `spentByMonth` is keyed by `monthKey`.
  static BudgetLimit budgetLimit(Category category, DateTime month, List<MonthlyBudget> budgets, List<RecurringBudget> recurring, Map<int, int> spentByMonth,
      {DateTime? asOf}) {
    final target = monthKey(month);
    final currentRealMonth = monthKey(asOf ?? DateTime.now());
    final plans = recurring.where((p) => p.categoryId == category.id && monthKey(p.startMonth) <= target).toList();
    final overrides = budgets.where((b) => b.categoryId == category.id).toList();
    var current = plans.isEmpty ? target : plans.map((p) => monthKey(p.startMonth)).reduce((a, b) => a < b ? a : b);
    var previousLimit = 0, previousSpent = 0;
    var previousHadPlan = false;
    int? previousMonth;
    RemainderChoice? previousChoice;
    while (current <= target) {
      final plan = activeRecurringBudget(category, current, plans);
      final override = overrides.where((b) => monthKey(b.monthStart) == current).firstOrNull;
      final carry =
          plan != null && previousChoice == RemainderChoice.carryForward && previousHadPlan && previousMonth != null && previousMonth < currentRealMonth
              ? (previousLimit - previousSpent > 0 ? previousLimit - previousSpent : 0)
              : 0;
      final base = override?.limitMinor ?? plan?.baseLimitMinor ?? 0;
      final limit = override != null ? base : base + carry;
      if (current == target) return BudgetLimit(limit, override == null ? carry : 0, plan != null);
      previousLimit = limit;
      previousSpent = spentByMonth[current] ?? 0;
      previousHadPlan = plan != null;
      previousMonth = current;
      previousChoice = plan?.remainderChoice;
      current += 1;
    }
    return BudgetLimit(0, 0, false);
  }

  /// Budgets of a month for every expense category, most used first (Swift: `budgetProgress`).
  List<BudgetProgress> budgetProgress(DateTime month, {DateTime? asOf}) {
    final target = monthKey(month);
    final spentByCategory = <String, Map<int, int>>{};
    final spentThisMonth = <String, int>{};
    for (final t in data.transactions) {
      if (!t.type.countsAsExpense || t.categoryId == null) continue;
      final key = monthKey(t.date);
      if (key > target) continue;
      final amount = budgetExpenseAmount(t);
      final months = spentByCategory[t.categoryId!] ??= {};
      months[key] = (months[key] ?? 0) + amount;
      if (key == target) spentThisMonth[t.categoryId!] = (spentThisMonth[t.categoryId!] ?? 0) + amount;
    }
    final items = <BudgetProgress>[];
    for (final category in data.categories.where((c) => c.isExpense)) {
      final details = budgetLimit(category, month, data.budgets, data.recurringBudgets, spentByCategory[category.id] ?? const {}, asOf: asOf);
      final spent = spentThisMonth[category.id] ?? 0;
      final item = BudgetProgress(
          category: category,
          limitMinor: details.limitMinor,
          spentMinor: spent > 0 ? spent : 0,
          carriedInMinor: details.carriedInMinor,
          isRecurring: details.isRecurring);
      if (item.limitMinor > 0 || item.spentMinor > 0) items.add(item);
    }
    items.sort((a, b) => a.fraction == b.fraction ? a.category.sortOrder.compareTo(b.category.sortOrder) : b.fraction.compareTo(a.fraction));
    return items;
  }
}
