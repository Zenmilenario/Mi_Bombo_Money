import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'widgets.dart';

/// Inicio, as on the iPhone (`DashboardView`): greeting, what is available and how the money splits, the month, its
/// pace against the budget, the month day by day, the budgets, net worth over a year and the closest goal.
/// One notice of «Necesita tu atención» (Swift `DashboardAlertItem`): it opens its tab and can be hidden until it
/// changes (its id carries what it counts).
typedef HomeAlert = ({String id, String title, String detail, IconData icon, Color color, int tab});

/// Budgets over their limit, possible duplicates, accounts not updated for 30 days and recurring movements due this
/// month, in that order, as on the iPhone.
List<HomeAlert> homeAlerts(FinanceCalculator calc, DateTime month, DateTime now, Pulso pulso) {
  final data = calc.data;
  final over = calc.budgetProgress(month).where((b) => b.limitMinor > 0 && b.spentMinor > b.limitMinor).toList();
  final duplicates = data.transactions.where((t) => t.duplicateState == 'possible').length;
  final limit = now.subtract(const Duration(days: 30));
  final stale = data.accounts.where((a) => !a.isArchived && a.bankIdentityKey == null && a.lastUpdatedAt.isBefore(limit)).length;
  final monthEnd = DateTime(now.year, now.month + 1, 0, 23, 59, 59);
  final due = data.recurringMovements
      .where((m) => m.isActive && !m.nextDueDate.isAfter(monthEnd) && (m.endDate == null || !m.endDate!.isBefore(now)))
      .length;
  return [
    if (over.isNotEmpty)
      (
        id: 'budgets:${month.year}-${month.month}:${over.map((b) => '${b.category.id}${b.spentMinor}').join()}',
        title: over.length == 1 ? 'Has superado 1 presupuesto' : 'Has superado ${over.length} presupuestos',
        detail: 'Revisa las categorías que necesitan atención.',
        icon: Icons.warning_rounded,
        color: pulso.expense,
        tab: 3,
      ),
    if (duplicates > 0)
      (
        id: 'duplicates:$duplicates',
        title: duplicates == 1 ? 'Hay 1 posible movimiento duplicado' : 'Hay $duplicates posibles movimientos duplicados',
        detail: 'Comprueba los registros antes de conservarlos.',
        icon: Icons.content_copy,
        color: pulso.warning,
        tab: 1,
      ),
    if (stale > 0)
      (
        id: 'staleAccounts:$stale',
        title: stale == 1 ? '1 cuenta lleva más de 30 días sin actualizarse' : '$stale cuentas llevan más de 30 días sin actualizarse',
        detail: 'Actualiza el saldo para mantener fiable el patrimonio.',
        icon: Icons.update,
        color: pulso.warning,
        tab: 2,
      ),
    if (due > 0)
      (
        id: 'recurring:${now.year}-${now.month}:$due',
        title: due == 1 ? 'Tienes 1 movimiento recurrente próximo' : 'Tienes $due movimientos recurrentes próximos',
        detail: 'Consulta las próximas suscripciones y cargos.',
        icon: Icons.event_repeat,
        color: pulso.savings,
        tab: 4,
      ),
  ];
}

class HomeScreen extends StatelessWidget {
  const HomeScreen(
      {super.key,
      required this.calc,
      required this.month,
      required this.onMonth,
      this.onAdd,
      this.heldMinor = 0,
      this.onOpenTab,
      this.hiddenAlerts = const {},
      this.onHideAlert});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  final VoidCallback? onAdd;
  final ValueChanged<int>? onOpenTab;
  final Set<String> hiddenAlerts;
  final ValueChanged<String>? onHideAlert;

  /// Charges the bank holds and has not booked yet (negative), already taken from what is available.
  final int heldMinor;

  @override
  Widget build(BuildContext context) {
    final data = calc.data;
    if (data.accounts.where((a) => !a.isArchived).isEmpty) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(24), children: [
        const _Greeting(),
        const SizedBox(height: 60),
        const Icon(Icons.account_balance_outlined, size: 48),
        const SizedBox(height: 12),
        const Text('Empieza con tus datos', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Añade tu primera cuenta o efectivo en Cuentas, o conecta tu banco en Ajustes › Mis bancos.', textAlign: TextAlign.center),
        if (onAdd != null) ...[const SizedBox(height: 16), FilledButton(onPressed: onAdd, child: const Text('Añadir mi primera cuenta'))],
      ]);
    }
    final now = DateTime.now();
    final isCurrentMonth = month.year == now.year && month.month == now.month;
    final budgets = calc.budgetProgress(month).where((b) => b.limitMinor > 0).toList();
    final pace = isCurrentMonth ? MonthPace.of(budgets, now) : null;
    final goal = _primaryGoal();
    final alerts = homeAlerts(calc, month, now, Pulso.of(context)).where((a) => !hiddenAlerts.contains(a.id)).toList();
    final recent = data.transactions.where((t) => t.date.toLocal().year == month.year && t.date.toLocal().month == month.month).take(5).toList();
    final cards = <Widget>[
      _MainCard(calc: calc, heldMinor: heldMinor, pace: pace),
      _MonthCard(calc: calc, month: month, onMonth: onMonth),
      if (pace != null) _PaceCard(pace: pace),
      _CalendarCard(calc: calc, month: month),
      if (budgets.isNotEmpty)
        _SectionCard(
          title: 'Presupuestos del mes',
          child: Column(children: [for (final b in budgets.take(4)) BudgetBar(item: b)]),
        ),
      _SectionCard(title: 'Patrimonio', subtitle: 'Los últimos doce meses', child: SizedBox(height: 140, child: _NetWorthChart(calc: calc))),
      if (goal != null) _GoalCard(goal: goal, saved: _saved(goal)),
      _SectionCard(
        title: 'Últimos movimientos del mes',
        padding: EdgeInsets.zero,
        child: recent.isEmpty
            ? const Padding(padding: EdgeInsets.all(16), child: Text('Sin movimientos este mes.'))
            : Column(children: [for (final t in recent) TransactionTile(transaction: t, data: data)]),
      ),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      // On a wide screen (iPad), two columns that fill one after the other, as on the iPhone app.
      final columns = constraints.maxWidth >= 720 ? 2 : 1;
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom), children: [
        const _Greeting(),
        const SizedBox(height: 18),
        if (alerts.isNotEmpty) ...[_AlertsCard(alerts: alerts, onOpenTab: onOpenTab, onHide: onHideAlert), const SizedBox(height: 18)],
        if (columns == 1)
          for (final card in cards) Padding(padding: const EdgeInsets.only(bottom: 18), child: card)
        else
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            for (var column = 0; column < columns; column++) ...[
              if (column > 0) const SizedBox(width: 18),
              Expanded(
                child: Column(children: [
                  for (var i = column; i < cards.length; i += columns) Padding(padding: const EdgeInsets.only(bottom: 18), child: cards[i]),
                ]),
              ),
            ],
          ]),
      ]);
    });
  }

  /// A goal linked to an account follows that account's balance; otherwise the amount written by hand.
  int _saved(SavingsGoal goal) {
    final account = calc.data.account(goal.linkedAccountId);
    final value = account != null ? calc.balance(account) : goal.currentAmountMinor;
    return value < 0 ? 0 : value;
  }

  double _progress(SavingsGoal goal) => goal.targetAmountMinor <= 0 ? 1 : _saved(goal) / goal.targetAmountMinor;

  /// The unfinished goal closest to completion, otherwise the first one (Swift `primaryGoal`).
  SavingsGoal? _primaryGoal() {
    final goals = calc.data.goals;
    final open = goals.where((g) => _progress(g) < 1).toList();
    if (open.isEmpty) return goals.firstOrNull;
    return open.reduce((a, b) => _progress(b) > _progress(a) ? b : a);
  }
}

/// «Necesita tu atención»: each notice opens its tab; «Revisado» hides it until what it counts changes.
class _AlertsCard extends StatelessWidget {
  const _AlertsCard({required this.alerts, this.onOpenTab, this.onHide});
  final List<HomeAlert> alerts;
  final ValueChanged<int>? onOpenTab;
  final ValueChanged<String>? onHide;

  @override
  Widget build(BuildContext context) => _SectionCard(
        title: 'Necesita tu atención',
        padding: const EdgeInsets.fromLTRB(4, 0, 4, 8),
        child: Column(children: [
          for (final alert in alerts)
            ListTile(
              leading: Container(
                width: 36,
                height: 36,
                decoration: BoxDecoration(color: alert.color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(Pulso.compactRadius)),
                child: Icon(alert.icon, size: 19, color: alert.color),
              ),
              title: Text(alert.title, style: const TextStyle(fontWeight: FontWeight.w600, fontSize: 14)),
              subtitle: Text(alert.detail, style: const TextStyle(fontSize: 12)),
              onTap: onOpenTab == null ? null : () => onOpenTab!(alert.tab),
              trailing: onHide == null
                  ? const Icon(Icons.chevron_right)
                  : TextButton(onPressed: () => onHide!(alert.id), child: const Text('Revisado', style: TextStyle(fontSize: 12))),
            ),
        ]),
      );
}

class _Greeting extends StatelessWidget {
  const _Greeting();

  @override
  Widget build(BuildContext context) {
    final hour = DateTime.now().hour;
    final greeting = hour >= 6 && hour < 12 ? 'Buenos días' : (hour >= 12 && hour < 21 ? 'Buenas tardes' : 'Buenas noches');
    return Text(greeting, style: Theme.of(context).textTheme.headlineMedium?.copyWith(fontWeight: FontWeight.w800));
  }
}

/// A card with a title, an optional subtitle and its content (Swift `SectionCard`).
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, this.subtitle, required this.child, this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16)});
  final String title;
  final String? subtitle;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 12),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
              if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            ]),
          ),
          Padding(padding: padding, child: child),
        ]),
      );
}

/// What can be spent now, today's margin, how the money splits and the total net worth.
class _MainCard extends StatelessWidget {
  const _MainCard({required this.calc, required this.heldMinor, required this.pace});
  final FinanceCalculator calc;
  final int heldMinor;
  final MonthPace? pace;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final available = calc.spendableCash() + heldMinor;
    final reserved = calc.reservedTotal();
    final invested = calc.invested();
    final now = DateTime.now();
    final change = calc.netWorth(now) - calc.netWorth(DateTime(now.year, now.month, 1).subtract(const Duration(seconds: 1)));
    final parts = <(String, int, Color)>[
      ('Disponible', available < 0 ? 0 : available, pulso.accent),
      ('Reservado', reserved < 0 ? 0 : reserved, pulso.savings),
      ('Retenido', heldMinor.abs(), pulso.warning),
      ('Inversión', invested < 0 ? 0 : invested, pulso.investment),
    ];
    final total = parts.fold(0, (sum, p) => sum + p.$2);
    final hint = Theme.of(context).hintColor;
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Pulso.heroRadius), side: BorderSide(color: pulso.outline)),
      child: Padding(
        padding: const EdgeInsets.all(20),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Wrap(spacing: 16, runSpacing: 12, crossAxisAlignment: WrapCrossAlignment.end, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text(heldMinor == 0 ? 'Disponible para usar' : 'Disponible tras retenciones',
                  style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: hint)),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(money(available),
                    style: TextStyle(
                        fontSize: 42,
                        fontWeight: FontWeight.w800,
                        letterSpacing: -0.5,
                        fontFeatures: const [FontFeature.tabularFigures()],
                        color: available < 0 ? pulso.expense : null)),
              ),
              if (heldMinor != 0)
                Row(mainAxisSize: MainAxisSize.min, children: [
                  Icon(Icons.hourglass_bottom, size: 14, color: pulso.warning),
                  const SizedBox(width: 4),
                  Text('${money(heldMinor, signed: true)} ya retenido por el banco',
                      style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: pulso.warning)),
                ]),
            ]),
            if (pace case final pace?)
              Container(
                constraints: const BoxConstraints(minWidth: 160),
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(color: pulso.accent.withValues(alpha: 0.11), borderRadius: BorderRadius.circular(Pulso.compactRadius + 4)),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
                  Text('Tu margen de hoy', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: pulso.accent)),
                  Text(money(pace.dailyMarginMinor), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
                  Text(pace.daysLeft == 1 ? 'Último día del presupuesto' : 'Para ${pace.daysLeft} días de presupuesto',
                      style: TextStyle(fontSize: 11, color: hint)),
                ]),
              ),
          ]),
          const SizedBox(height: 16),
          if (total > 0)
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: SizedBox(
                height: 12,
                child: Row(children: [
                  for (final (index, part) in parts.where((p) => p.$2 > 0).indexed) ...[
                    if (index > 0) const SizedBox(width: 3),
                    Expanded(flex: (part.$2 * 1000 ~/ total).clamp(12, 1000), child: ColoredBox(color: part.$3)),
                  ],
                ]),
              ),
            ),
          const SizedBox(height: 12),
          LayoutBuilder(builder: (context, constraints) {
            final perRow = constraints.maxWidth >= 480 ? 4 : 2;
            final width = (constraints.maxWidth - (perRow - 1) * 10) / perRow;
            return Wrap(spacing: 10, runSpacing: 10, children: [
              for (final part in parts)
                SizedBox(
                  width: width,
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Row(children: [
                      Container(width: 8, height: 8, decoration: BoxDecoration(color: part.$3, borderRadius: BorderRadius.circular(2))),
                      const SizedBox(width: 6),
                      Text(part.$1, style: TextStyle(fontSize: 12, color: hint)),
                    ]),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(money(part.$2), style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w600)),
                    ),
                  ]),
                ),
            ]);
          }),
          const SizedBox(height: 14),
          Divider(height: 1, color: pulso.outline),
          const SizedBox(height: 12),
          Wrap(alignment: WrapAlignment.spaceBetween, spacing: 12, runSpacing: 6, children: [
            Text.rich(TextSpan(children: [
              TextSpan(text: 'Patrimonio total ', style: TextStyle(color: hint)),
              TextSpan(text: money(calc.netWorth()), style: const TextStyle(fontWeight: FontWeight.w600)),
            ]), style: const TextStyle(fontSize: 13)),
            Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(change >= 0 ? Icons.north_east : Icons.south_east, size: 14, color: change >= 0 ? pulso.income : pulso.expense),
              const SizedBox(width: 4),
              Text('${money(change, signed: true)} este mes',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: change >= 0 ? pulso.income : pulso.expense)),
            ]),
          ]),
        ]),
      ),
    );
  }
}

/// The chosen month: income, expenses and savings.
class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.calc, required this.month, required this.onMonth});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final summary = calc.monthlySummary(month);
    Widget figure(String label, int value, Color color, IconData icon, {bool signed = false}) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: color.withValues(alpha: 0.09), borderRadius: BorderRadius.circular(Pulso.compactRadius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Icon(icon, size: 14, color: color),
                const SizedBox(width: 4),
                Expanded(child: Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor), overflow: TextOverflow.ellipsis)),
              ]),
              const SizedBox(height: 4),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(money(value, signed: signed), style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700, color: color)),
              ),
            ]),
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 8, 8, 14),
        child: Column(children: [
          MonthSelector(month: month, onMonth: onMonth),
          const SizedBox(height: 6),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 8),
            child: Row(children: [
              figure('Ingresos', summary.incomeMinor, pulso.income, Icons.south_west),
              const SizedBox(width: 8),
              figure('Gastos', summary.expenseMinor, pulso.expense, Icons.north_east),
              const SizedBox(width: 8),
              figure('Ahorro', summary.netSavingsMinor, summary.netSavingsMinor >= 0 ? pulso.savings : pulso.expense, Icons.savings_outlined,
                  signed: true),
            ]),
          ),
        ]),
      ),
    );
  }
}

/// Spending against the month's budget, with the mark of an even pace and the projection to the end of the month.
class _PaceCard extends StatelessWidget {
  const _PaceCard({required this.pace});
  final MonthPace pace;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final below = pace.differenceMinor >= 0;
    final spent = (pace.spentMinor / pace.limitMinor).clamp(0.0, 1.0);
    final expected = (pace.expectedMinor / pace.limitMinor).clamp(0.0, 1.0);
    final hint = Theme.of(context).hintColor;
    Widget chip(String label, String value, Color background, Color labelColor) => Expanded(
          child: Container(
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(color: background, borderRadius: BorderRadius.circular(Pulso.compactRadius)),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: labelColor)),
              Text(value, style: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
            ]),
          ),
        );
    return _SectionCard(
      title: 'Ritmo del mes',
      subtitle: 'Día ${pace.day} de ${pace.daysInMonth}',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text.rich(TextSpan(children: [
          TextSpan(text: money(pace.spentMinor), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700)),
          TextSpan(text: '  de ${money(pace.limitMinor)}', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: hint)),
        ])),
        const SizedBox(height: 10),
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          return SizedBox(
            height: 18,
            child: Stack(alignment: Alignment.centerLeft, children: [
              Container(height: 12, decoration: BoxDecoration(color: pulso.tertiary, borderRadius: BorderRadius.circular(6))),
              Container(
                  height: 12,
                  width: (width * spent).clamp(6.0, width),
                  decoration: BoxDecoration(color: below ? pulso.accent : pulso.expense, borderRadius: BorderRadius.circular(6))),
              Positioned(
                left: (width * expected - 1).clamp(0.0, width - 2),
                child: Container(width: 2, height: 18, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.55)),
              ),
            ]),
          );
        }),
        const SizedBox(height: 12),
        Row(children: [
          chip(below ? 'Por debajo del ritmo' : 'Por encima del ritmo', money(pace.differenceMinor.abs()),
              (below ? pulso.income : pulso.expense).withValues(alpha: 0.10), below ? pulso.income : pulso.expense),
          const SizedBox(width: 10),
          chip('A este paso, a fin de mes', money(pace.projectionMinor), pulso.tertiary, hint),
        ]),
        const SizedBox(height: 8),
        Text('La marca indica lo que correspondería gastar hasta hoy si el presupuesto se repartiera por igual.',
            style: TextStyle(fontSize: 11, color: hint)),
      ]),
    );
  }
}

/// «Tu mes, día a día»: each day tinted by what was spent on it, today outlined.
class _CalendarCard extends StatelessWidget {
  const _CalendarCard({required this.calc, required this.month});
  final FinanceCalculator calc;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final now = DateTime.now();
    final spend = calc.dailySpending(month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final leading = DateTime(month.year, month.month, 1).weekday - 1; // Monday first
    final maximum = spend.values.fold(1, (a, b) => b > a ? b : a);
    final isCurrent = month.year == now.year && month.month == now.month;
    final today = isCurrent ? now.day : (DateTime(month.year, month.month).isAfter(now) ? 0 : days + 1);
    final busiest = spend.entries.fold<MapEntry<int, int>?>(null, (best, e) => best == null || e.value > best.value ? e : best);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    return _SectionCard(
      title: 'Tu mes, día a día',
      subtitle: 'Gasto de cada día',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          physics: const NeverScrollableScrollPhysics(),
          mainAxisSpacing: 5,
          crossAxisSpacing: 5,
          childAspectRatio: 1.15,
          children: [
            for (final initial in const ['L', 'M', 'X', 'J', 'V', 'S', 'D'])
              Center(child: Text(initial, style: TextStyle(fontSize: 11, color: Theme.of(context).hintColor))),
            for (var i = 0; i < leading; i++) const SizedBox.shrink(),
            for (var day = 1; day <= days; day++)
              () {
                final amount = spend[day] ?? 0;
                final level = amount == 0 ? 0.0 : 0.22 + 0.78 * amount / maximum;
                return Semantics(
                  label: amountsHidden ? 'Día $day' : 'Día $day: ${money(amount)}',
                  child: Container(
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: level == 0 ? pulso.tertiary : pulso.accent.withValues(alpha: level),
                      borderRadius: BorderRadius.circular(7),
                      border: day == today ? Border.all(color: pulso.accent, width: 2) : null,
                    ),
                    child: Text('$day',
                        style: TextStyle(
                            fontSize: 11,
                            fontWeight: FontWeight.w600,
                            color: level > 0.6 ? Colors.white : (day > today ? onSurface.withValues(alpha: 0.4) : onSurface))),
                  ),
                );
              }(),
          ],
        ),
        if (busiest != null && !amountsHidden) ...[
          const SizedBox(height: 8),
          Text('El día con más gasto fue el ${busiest.key}: ${money(busiest.value)}.',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        ],
      ]),
    );
  }
}

class _GoalCard extends StatelessWidget {
  const _GoalCard({required this.goal, required this.saved});
  final SavingsGoal goal;
  final int saved;

  @override
  Widget build(BuildContext context) {
    final color = colorFromHex(goal.colorHex);
    final fraction = goal.targetAmountMinor <= 0 ? 1.0 : (saved / goal.targetAmountMinor).clamp(0.0, 1.0);
    return _SectionCard(
      title: 'Objetivo destacado',
      subtitle: 'Tu próximo hito financiero',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Container(
            width: 40,
            height: 40,
            decoration: BoxDecoration(color: color.withValues(alpha: 0.15), borderRadius: BorderRadius.circular(Pulso.compactRadius)),
            child: Icon(fraction >= 1 ? Icons.verified : Icons.flag_outlined, color: color),
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(goal.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${money(saved)} de ${money(goal.targetAmountMinor)}', style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            ]),
          ),
          Text(NumberFormat.percentPattern('es').format(fraction), style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        ]),
        const SizedBox(height: 12),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(value: fraction, minHeight: 8, color: color, backgroundColor: Pulso.of(context).tertiary),
        ),
      ]),
    );
  }
}

class _NetWorthChart extends StatelessWidget {
  const _NetWorthChart({required this.calc});
  final FinanceCalculator calc;

  @override
  Widget build(BuildContext context) {
    final color = Pulso.of(context).accent;
    final now = DateTime.now();
    final points = [
      for (var i = 11; i >= 0; i--)
        () {
          final start = DateTime(now.year, now.month - i);
          final end = i == 0 ? now : DateTime(start.year, start.month + 1, 0, 23, 59, 59);
          return (start, calc.netWorth(end));
        }()
    ];
    final values = points.map((p) => p.$2 / 100).toList();
    final min = values.reduce((a, b) => a < b ? a : b), max = values.reduce((a, b) => a > b ? a : b);
    final margin = (max - min).abs() < 1 ? 1.0 : (max - min) * 0.1;
    const months = ['E', 'F', 'M', 'A', 'M', 'J', 'J', 'A', 'S', 'O', 'N', 'D'];
    return LineChart(LineChartData(
      minY: min - margin,
      maxY: max + margin,
      gridData: const FlGridData(show: false),
      borderData: FlBorderData(show: false),
      lineTouchData: LineTouchData(
        touchTooltipData: LineTouchTooltipData(
          getTooltipItems: (spots) => [for (final s in spots) LineTooltipItem(money((s.y * 100).round()), const TextStyle(color: Colors.white))],
        ),
      ),
      titlesData: FlTitlesData(
        leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
        bottomTitles: AxisTitles(
          sideTitles: SideTitles(
            showTitles: true,
            interval: 1,
            getTitlesWidget: (value, meta) {
              final i = value.round();
              if (i < 0 || i >= points.length) return const SizedBox.shrink();
              return Text(months[points[i].$1.month - 1], style: Theme.of(context).textTheme.bodySmall);
            },
          ),
        ),
      ),
      lineBarsData: [
        LineChartBarData(
          spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])],
          isCurved: true,
          preventCurveOverShooting: true,
          color: color,
          barWidth: 3,
          dotData: const FlDotData(show: false),
          belowBarData: BarAreaData(show: true, color: color.withValues(alpha: 0.12)),
        ),
      ],
    ));
  }
}
