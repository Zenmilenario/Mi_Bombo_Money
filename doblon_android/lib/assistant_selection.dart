// Which movements a request is about (26 November 2026). Before this, a query kept only its period, a type
// (expenses, income or all) and one category, and a follow-up rebuilt them from the words of the new sentence: «los
// que no tienen categoría» could not be said at all and a correction lost what it did not repeat (all movements
// became expenses). A selection is a set of explicit conditions; a correction changes only the ones it states.
// It is always ordered from the most recent, with a stable order for the same day, and may keep only the first
// [limit] («los últimos 4», «los tres más recientes», «no, solo dos»): the limit applies after the conditions.
import 'assistant.dart' show QueryPeriod, QueryPeriodTitle, QueryScope;
import 'models.dart';

class MovementSelection {
  const MovementSelection({this.period, this.from, this.to, this.scope, this.uncategorized, this.categoryId, this.accountId, this.limit});

  /// How many, the most recent first; null: all that meet the conditions.
  final int? limit;

  /// A period said in words, or an explicit range [from, to) (day precision). Neither: no period was said.
  final QueryPeriod? period;
  final DateTime? from, to;

  /// Expenses, income or all; null when not said.
  final QueryScope? scope;

  /// true: only without category; false: only with one; null: both.
  final bool? uncategorized;
  final String? categoryId, accountId;

  bool get hasPeriod => period != null || from != null || to != null;

  /// [change] applied over this one: only what [change] states is replaced.
  MovementSelection refinedBy(MovementSelection change) => MovementSelection(
        period: change.hasPeriod ? change.period : period,
        from: change.hasPeriod ? change.from : from,
        to: change.hasPeriod ? change.to : to,
        scope: change.scope ?? scope,
        uncategorized: change.uncategorized ?? (change.categoryId != null ? null : uncategorized),
        categoryId: change.categoryId ?? (change.uncategorized == true ? null : categoryId),
        accountId: change.accountId ?? accountId,
        limit: change.limit ?? limit,
      );

  MovementSelection withoutAccount() =>
      MovementSelection(period: period, from: from, to: to, scope: scope, uncategorized: uncategorized, categoryId: categoryId, limit: limit);

  MovementSelection withoutLimit() =>
      MovementSelection(period: period, from: from, to: to, scope: scope, uncategorized: uncategorized, categoryId: categoryId, accountId: accountId);

  MovementSelection withoutCategory() =>
      MovementSelection(period: period, from: from, to: to, scope: scope, uncategorized: uncategorized, accountId: accountId, limit: limit);

  MovementSelection withDefaultPeriod(QueryPeriod fallback) => hasPeriod ? this : refinedBy(MovementSelection(period: fallback));

  (DateTime?, DateTime?) range(DateTime now) {
    if (period != null) return period!.range(now);
    return (from == null ? null : DateTime(from!.year, from!.month, from!.day), to == null ? null : DateTime(to!.year, to!.month, to!.day + 1));
  }

  bool matches(Transaction t, DateTime now) {
    final (start, end) = range(now);
    if (start != null && t.date.isBefore(start)) return false;
    if (end != null && !t.date.isBefore(end)) return false;
    switch (scope ?? QueryScope.all) {
      case QueryScope.expenses:
        if (!t.type.countsAsExpense) return false;
      case QueryScope.income:
        if (!t.type.countsAsIncome) return false;
      case QueryScope.all:
        break;
    }
    // Only movements that take a category can lack one (transfers between own accounts do not).
    if (uncategorized == true && (t.categoryId != null || !(t.type.countsAsExpense || t.type.countsAsIncome))) return false;
    if (uncategorized == false && t.categoryId == null) return false;
    if (categoryId != null && t.categoryId != categoryId) return false;
    if (accountId != null && t.sourceAccountId != accountId && t.destinationAccountId != accountId) return false;
    return true;
  }

  /// The movements, most recent first (same day: the one recorded later first, then by id), up to [limit].
  List<Transaction> select(Finances data, DateTime now) {
    final all = [for (final t in data.transactions) if (matches(t, now)) t]..sort(newestFirst);
    return limit == null ? all : all.take(limit!).toList();
  }

  static int newestFirst(Transaction a, Transaction b) {
    final byDate = b.date.compareTo(a.date);
    if (byDate != 0) return byDate;
    final byCreation = b.createdAt.compareTo(a.createdAt);
    return byCreation != 0 ? byCreation : b.id.compareTo(a.id);
  }

  String periodTitle() {
    if (period != null) return period!.title;
    String day(DateTime d) => '${d.day}/${d.month}/${d.year}';
    if (from != null && to != null) return 'del ${day(from!)} al ${day(to!)}';
    if (from != null) return 'desde el ${day(from!)}';
    if (to != null) return 'hasta el ${day(to!)}';
    return 'de cualquier fecha';
  }

  /// In words, for titles and for the interpreter's context: «Gastos sin categoría de este mes en Nómina».
  String describe(Finances data) {
    final category = data.category(categoryId);
    final account = data.account(accountId);
    final what = switch (scope ?? QueryScope.all) {
      QueryScope.expenses => 'Gastos',
      QueryScope.income => 'Ingresos',
      QueryScope.all => 'Movimientos',
    };
    return [
      what,
      if (uncategorized == true) 'sin categoría',
      if (uncategorized == false) 'con categoría',
      if (category != null) 'de la categoría ${category.name}',
      periodTitle(),
      if (account != null) 'en ${account.name}',
      if (limit != null) '(${limit == 1 ? 'el más reciente' : 'los $limit más recientes'})',
    ].join(' ');
  }
}
