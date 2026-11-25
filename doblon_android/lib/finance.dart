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
  ReservedEntry({required this.id, required this.date, required this.source, this.destination, required this.amount, this.deposit = false});
  final String id;
  final DateTime date;
  final String source;
  final String? destination;
  final int amount;

  /// Income set aside for the reserve after it existed (for example, the interest the person decides to keep in it):
  /// it adds to the reserve in [source].
  final bool deposit;
  bool get isTransfer => destination != null;
}

/// A reserve's history: payments and moves of its money, and income set aside for it after it was created.
List<ReservedEntry> fundEntries(ReservedFund fund, Iterable<Transaction> transactions) => [
      for (final t in transactions)
        if (t.reservedFundId == fund.id &&
            (t.type.countsAsExpense || t.type == TransactionType.transfer) &&
            t.sourceAccountId != null &&
            t.reservedAmountMinor != null)
          ReservedEntry(
              id: t.id,
              date: t.date,
              source: t.sourceAccountId!,
              destination: t.type == TransactionType.transfer ? t.destinationAccountId : null,
              amount: t.reservedAmountMinor!)
        // Income for the reserve after it was created adds to it; before, it is where its starting amount came
        // from, which is already counted.
        else if (t.reservedFundId == fund.id &&
            t.type.countsAsIncome &&
            t.sourceAccountId != null &&
            FinanceCalculator.reservedIncomeAmount(t) > 0 &&
            fund.createdAt != null &&
            t.date.isAfter(fund.createdAt!))
          ReservedEntry(id: t.id, date: t.date, source: t.sourceAccountId!, amount: FinanceCalculator.reservedIncomeAmount(t), deposit: true),
    ];

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
    for (final entry in group.where((e) => e.deposit)) {
      balances[entry.source] = (balances[entry.source] ?? 0) + entry.amount;
    }
    final pending = group.where((e) => e.isTransfer).toList()..sort((a, b) => a.id.toUpperCase().compareTo(b.id.toUpperCase()));
    // Transfers at the same instant may form a chain, but an unfunded circle never creates money.
    while (pending.isNotEmpty) {
      final index = pending.indexWhere((e) => (balances[e.source] ?? 0) >= e.amount);
      if (index < 0) return null;
      final entry = pending.removeAt(index);
      balances[entry.source] = (balances[entry.source] ?? 0) - entry.amount;
      balances[entry.destination!] = (balances[entry.destination!] ?? 0) + entry.amount;
    }
    for (final entry in group.where((e) => !e.isTransfer && !e.deposit)) {
      if ((balances[entry.source] ?? 0) < entry.amount) return null;
      balances[entry.source] = (balances[entry.source] ?? 0) - entry.amount;
    }
  }
  return balances;
}

/// The month's spending against its budget (Swift «Ritmo del mes» and «Tu margen de hoy»): what an even pace would
/// have spent by today, what this pace reaches at the end of the month, and what is left per remaining day.
class MonthPace {
  MonthPace({required this.limitMinor, required this.spentMinor, required this.day, required this.daysInMonth});
  final int limitMinor, spentMinor, day, daysInMonth;

  int get expectedMinor => limitMinor * day ~/ daysInMonth;

  /// Positive when spending is below the even pace.
  int get differenceMinor => expectedMinor - spentMinor;
  int get projectionMinor => spentMinor * daysInMonth ~/ (day < 1 ? 1 : day);
  int get daysLeft => daysInMonth - day + 1;
  int get dailyMarginMinor => (limitMinor - spentMinor < 0 ? 0 : limitMinor - spentMinor) ~/ daysLeft;

  static MonthPace? of(List<BudgetProgress> budgets, DateTime today) {
    final limit = budgets.fold(0, (sum, b) => sum + b.limitMinor);
    if (limit <= 0) return null;
    return MonthPace(
        limitMinor: limit,
        spentMinor: budgets.fold(0, (sum, b) => sum + b.spentMinor),
        day: today.day,
        daysInMonth: DateTime(today.year, today.month + 1, 0).day);
  }
}

/// A month's income and expenses. The «everyday» figures leave out the money of reserves: income set aside for a
/// reserve and the part of a payment it covered. The full history keeps everything.
class MonthlySummary {
  MonthlySummary(this.incomeMinor, this.expenseMinor, this.reservedExpenseMinor,
      [this.reservedIncomeMinor = 0, this.investmentFeeMinor = 0, this.repaidMinor = 0]);

  /// Instalments repaying a purchase or a loan already recorded: in the full history, not spending again.
  final int repaidMinor;

  /// Fees of investment orders: in the full history, not in the everyday figures.
  final int investmentFeeMinor;
  final int incomeMinor;
  final int expenseMinor;
  final int reservedExpenseMinor;
  final int reservedIncomeMinor;
  int get budgetExpenseMinor => expenseMinor - reservedExpenseMinor - investmentFeeMinor - repaidMinor;
  int get netSavingsMinor => incomeMinor - expenseMinor;
  int get dailyIncomeMinor => incomeMinor - reservedIncomeMinor;
  int get dailyExpenseMinor => budgetExpenseMinor;
  int get dailyNetMinor => dailyIncomeMinor - dailyExpenseMinor;

  /// Whether reserves change the month: then the everyday figures differ from the full ones.
  bool get hasReserves => reservedExpenseMinor != 0 || reservedIncomeMinor != 0;
}

class BudgetLimit {
  BudgetLimit(this.limitMinor, this.carriedInMinor, this.isRecurring);
  final int limitMinor;
  final int carriedInMinor;
  final bool isRecurring;
}

/// A movement as a budget counts it: its whole amount, the part a reserve paid and the part that consumes the budget.
class BudgetContribution {
  BudgetContribution(this.transaction, this.totalMinor, this.reservedMinor, [int? countedMinor]) : countedMinor = countedMinor ?? totalMinor - reservedMinor;
  final Transaction transaction;
  final int totalMinor;
  final int reservedMinor;

  /// What consumes the budget (`FinanceCalculator.budgetExpenseAmount`): without what a reserve paid and without
  /// the repayment of a purchase or a loan already recorded.
  final int countedMinor;
  bool get isPartial => reservedMinor > 0;

  /// The part repaying something recorded before (an instalment of a purchase already recorded).
  int get repaidMinor => totalMinor - reservedMinor - countedMinor;
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

  /// Everyday spending: without what a reserve paid, and without the fees of investment orders (a cost of investing,
  /// shown with the investments).
  static int budgetExpenseAmount(Transaction t) {
    if (!t.type.countsAsExpense || t.isInvestmentFee) return 0;
    // An instalment repaying a purchase or a loan already recorded is not spending again, except its costs.
    final spending = t.installmentSpendingMinor;
    return (spending ?? t.amountMinor.abs()) - reservedExpenseAmount(t).clamp(0, spending ?? t.amountMinor.abs());
  }

  /// The part of an income set aside for a reserve: the amount chosen, or all of it. It is not everyday income.
  static int reservedIncomeAmount(Transaction t) {
    if (!t.type.countsAsIncome || t.reservedFundId == null) return 0;
    final part = t.reservedAmountMinor ?? t.amountMinor;
    return part < 0 ? 0 : (part < t.amountMinor ? part : t.amountMinor);
  }

  /// Income for everyday use: without what went to a reserve.
  static int dailyIncomeAmount(Transaction t) => t.type.countsAsIncome ? t.amountMinor.abs() - reservedIncomeAmount(t) : 0;

  List<ReservedEntry> reserveEntries(ReservedFund fund) => fundEntries(fund, data.transactions);

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

  /// Money set aside in reserves, across the accounts that count (Swift `reservedCash` on Inicio).
  int reservedTotal() =>
      _counted.where((a) => a.type != AccountType.investment && !a.type.isLiability).fold(0, (sum, a) => sum + reservedAmount(a));

  /// What each category cost in the month, from most to least (Swift `spendingByCategory`). Without category, left out.
  List<(Category, int)> spendingByCategory(DateTime month) {
    final totals = <String, int>{};
    for (final t in data.transactions) {
      final local = t.date.toLocal();
      final id = t.categoryId;
      if (!t.type.countsAsExpense || id == null || local.year != month.year || local.month != month.month) continue;
      final amount = budgetExpenseAmount(t);
      if (amount > 0) totals[id] = (totals[id] ?? 0) + amount;
    }
    return [
      for (final MapEntry(key: id, value: amount) in totals.entries)
        if (data.category(id) case final category?) (category, amount)
    ]..sort((a, b) => b.$2.compareTo(a.$2));
  }

  // One calculator per version of the data: what is derived from the whole history can be kept in it.
  final _dailySpending = <int, Map<int, int>>{};

  /// What was spent each day of the month (day of the month → amount), for «Tu mes, día a día».
  Map<int, int> dailySpending(DateTime month) => _dailySpending[month.year * 12 + month.month] ??= _spendingByDay(month);

  Map<int, int> _spendingByDay(DateTime month) {
    final spend = <int, int>{};
    for (final t in data.transactions) {
      final local = t.date.toLocal();
      if (!t.type.countsAsExpense || local.year != month.year || local.month != month.month) continue;
      // Everyday spending: what a reserve paid is not counted again.
      final amount = budgetExpenseAmount(t);
      if (amount > 0) spend[local.day] = (spend[local.day] ?? 0) + amount;
    }
    return spend;
  }

  MonthlySummary monthlySummary(DateTime month) {
    final key = monthKey(month);
    var income = 0, expense = 0, reserved = 0, reservedIncome = 0, investmentFees = 0, repaid = 0;
    for (final t in data.transactions) {
      if (monthKey(t.date) != key) continue;
      if (t.type.countsAsIncome) income += t.amountMinor.abs();
      if (t.type.countsAsExpense) expense += t.amountMinor.abs();
      reserved += reservedExpenseAmount(t);
      reservedIncome += reservedIncomeAmount(t);
      if (t.isInvestmentFee) investmentFees += t.amountMinor.abs();
      if (t.type.countsAsExpense && t.installmentSpendingMinor != null) repaid += t.amountMinor.abs() - t.installmentSpendingMinor!;
    }
    return MonthlySummary(income, expense, reserved, reservedIncome, investmentFees, repaid);
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

  /// Whether a movement counts in its category's budget: spending and fees with a category, never transfers or
  /// income. The budget and its detail use this same rule.
  static bool countsInBudget(Transaction t) => t.type.countsAsExpense && t.categoryId != null;

  /// The movements behind a category's spending in a month, newest first. Their counted amounts add up to that
  /// budget's spending (`budgetProgress(...).spentMinor`).
  List<BudgetContribution> budgetContributions(String categoryId, DateTime month) {
    final target = monthKey(month);
    return [
      for (final t in data.transactions)
        if (countsInBudget(t) && t.categoryId == categoryId && monthKey(t.date) == target) BudgetContribution(t, t.amountMinor.abs(), reservedExpenseAmount(t), budgetExpenseAmount(t))
    ];
  }

  /// Budgets of a month for every expense category, most used first (Swift: `budgetProgress`).
  List<BudgetProgress> budgetProgress(DateTime month, {DateTime? asOf}) {
    final target = monthKey(month);
    final spentByCategory = <String, Map<int, int>>{};
    final spentThisMonth = <String, int>{};
    for (final t in data.transactions) {
      if (!countsInBudget(t)) continue;
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
