import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../automation.dart' show CompanionNote;
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'chrome.dart' show tabListPadding;
import 'widgets.dart';

/// Inicio answers three questions, in this order: how much can I use, how is the month going, and is there anything
/// to do. Each answer is a short summary; its detail opens in place (the split of the money, the month day by day) or
/// one tap away (budgets, movements, Don Bigotes' list). Every amount is shown once.
class HomeScreen extends StatelessWidget {
  const HomeScreen(
      {super.key,
      required this.calc,
      required this.month,
      required this.onMonth,
      this.onAdd,
      this.heldMinor = 0,
      this.onOpenTab,
      this.notes = const [],
      this.reviewed = 0,
      this.onNotes});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  final VoidCallback? onAdd;
  final ValueChanged<int>? onOpenTab;

  /// What is pending (Don Bigotes' notes): the same list his button opens, never repeated elsewhere.
  final List<CompanionNote> notes;

  /// Notes the person already marked as seen («Ahora no»), still true but no longer pending.
  final int reviewed;
  final VoidCallback? onNotes;

  /// Charges the bank holds and has not booked yet (negative), already taken from what is available.
  final int heldMinor;

  @override
  Widget build(BuildContext context) {
    final data = calc.data;
    if (data.accounts.where((a) => !a.isArchived).isEmpty) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: tabListPadding(context, horizontal: 24, top: 48), children: [
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
    final recent = data.transactions.where((t) => t.date.toLocal().year == month.year && t.date.toLocal().month == month.month).take(5).toList();
    final cards = <Widget>[
      _MonthCard(calc: calc, month: month, onMonth: onMonth, pace: pace, hasBudgets: budgets.isNotEmpty),
      if (budgets.isNotEmpty)
        _SectionCard(
          title: 'Presupuestos del mes',
          action: onOpenTab == null ? null : ('Ver todos', () => onOpenTab!(3)),
          child: Column(children: [for (final b in budgets.take(3)) BudgetBar(item: b)]),
        ),
      if (goal != null) _GoalCard(goal: goal, saved: _saved(goal)),
      _SectionCard(
        title: 'Últimos movimientos del mes',
        action: onOpenTab == null ? null : ('Ver todos', () => onOpenTab!(1)),
        padding: EdgeInsets.zero,
        child: recent.isEmpty
            ? const Padding(padding: EdgeInsets.all(16), child: Text('Sin movimientos este mes.'))
            : Column(children: [for (final t in recent) TransactionTile(transaction: t, data: data)]),
      ),
    ];
    return LayoutBuilder(builder: (context, constraints) {
      // On a wide screen (iPad), two columns that fill one after the other, as on the iPhone app.
      final columns = constraints.maxWidth >= 720 ? 2 : 1;
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: tabListPadding(context, top: 4), children: [
        _Hero(calc: calc, heldMinor: heldMinor),
        const SizedBox(height: 12),
        _PendingCard(notes: notes, reviewed: reviewed, onOpen: onNotes),
        const SizedBox(height: 18),
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

/// ¿Cuánto tengo disponible? One figure, what it means, and the split of the money and the net worth on request.
class _Hero extends StatelessWidget {
  const _Hero({required this.calc, required this.heldMinor});
  final FinanceCalculator calc;
  final int heldMinor;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final available = calc.spendableCash() + heldMinor;
    final reserved = calc.reservedTotal();
    final invested = calc.invested();
    final now = DateTime.now();
    final netWorth = calc.netWorth(now);
    final change = netWorth - calc.netWorth(DateTime(now.year, now.month, 1).subtract(const Duration(seconds: 1)));
    final parts = <(String, int, Color)>[
      ('Disponible', available < 0 ? 0 : available, pulso.accent),
      ('Reservado', reserved < 0 ? 0 : reserved, pulso.savings),
      ('Retenido por el banco', heldMinor.abs(), pulso.warning),
      ('Inversión', invested < 0 ? 0 : invested, pulso.investment),
    ];
    final total = parts.fold(0, (sum, p) => sum + p.$2);
    Widget line(String label, String value, String meaning) => Padding(
          padding: const EdgeInsets.only(top: 10),
          child: MergeSemantics(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Row(children: [
                Expanded(child: Text(label, style: const TextStyle(fontSize: 14))),
                Text(value, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
              ]),
              Text(meaning, style: TextStyle(fontSize: 12, color: hint)),
            ]),
          ),
        );
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 4),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text('Disponible para usar', style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: hint)),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(money(available),
              style: TextStyle(
                  fontSize: 46,
                  height: 1.1,
                  fontWeight: FontWeight.w800,
                  letterSpacing: -1.2,
                  fontFeatures: const [FontFeature.tabularFigures()],
                  color: available < 0 ? pulso.expense : null)),
        ),
        Text(
            heldMinor == 0
                ? 'Lo que hay en tus cuentas corrientes, de ahorro y efectivo, sin contar lo reservado.'
                : 'Lo que hay en tus cuentas corrientes, de ahorro y efectivo, sin contar lo reservado ni ${money(heldMinor.abs())} retenidos por el banco.',
            style: TextStyle(fontSize: 12, color: hint)),
        const SizedBox(height: 4),
        Disclosure(
          title: 'Ver reparto y patrimonio',
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            if (total > 0) ...[
              const SizedBox(height: 4),
              ExcludeSemantics(
                child: ClipRRect(
                  borderRadius: BorderRadius.circular(6),
                  child: SizedBox(
                    height: 10,
                    // Stretched: an empty coloured box would otherwise be zero pixels high and the bar would not show.
                    child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                      for (final (index, part) in parts.where((p) => p.$2 > 0).indexed) ...[
                        if (index > 0) const SizedBox(width: 3),
                        Expanded(flex: (part.$2 * 1000 ~/ total).clamp(12, 1000), child: ColoredBox(color: part.$3)),
                      ],
                    ]),
                  ),
                ),
              ),
            ],
            // The available amount is already above: the legend only names its colour.
            for (final part in parts)
              if (part.$1 == 'Disponible' || part.$2 > 0)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: MergeSemantics(
                    child: Row(children: [
                      Container(width: 10, height: 10, decoration: BoxDecoration(color: part.$3, borderRadius: BorderRadius.circular(2))),
                      const SizedBox(width: 8),
                      Expanded(child: Text(part.$1 == 'Disponible' ? 'Disponible (la cifra de arriba)' : part.$1, style: const TextStyle(fontSize: 13))),
                      if (part.$1 != 'Disponible') Text(money(part.$2), style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                ),
            const Divider(height: 24),
            line('Patrimonio total', money(netWorth), 'Todas tus cuentas incluidas en el patrimonio, inversión incluida; las deudas restan.'),
            line('Variación del patrimonio este mes', money(change, signed: true),
                'Patrimonio de hoy frente al del último día del mes pasado. No es lo mismo que el ahorro del mes.'),
            const SizedBox(height: 12),
            SizedBox(height: 120, child: _NetWorthChart(calc: calc)),
            const SizedBox(height: 4),
          ]),
        ),
      ]),
    );
  }
}

/// ¿Necesito hacer algo? The same list Don Bigotes keeps, summed up here once: nothing, or how many things and the
/// first of them. Highlighted only when something is urgent, and always with words, not only a colour.
class _PendingCard extends StatelessWidget {
  const _PendingCard({required this.notes, required this.reviewed, this.onOpen});
  final List<CompanionNote> notes;
  final int reviewed;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final urgent = notes.any((n) => n.urgent);
    final seen = reviewed == 0 ? '' : (reviewed == 1 ? ' · 1 aviso revisado' : ' · $reviewed avisos revisados');
    final title = notes.isEmpty ? 'Nada pendiente' : (notes.length == 1 ? '1 cosa pendiente' : '${notes.length} cosas pendientes');
    final detail = notes.isEmpty ? 'Don Bigotes te avisará si algo necesita tu atención$seen.' : '${notes.first.title}${notes.length > 1 ? ' y más' : ''}$seen';
    final color = urgent ? pulso.warning : pulso.accent;
    return Material(
      color: urgent ? pulso.warning.withValues(alpha: 0.12) : pulso.card,
      shape:
          RoundedRectangleBorder(borderRadius: BorderRadius.circular(Pulso.cardRadius), side: BorderSide(color: urgent ? Colors.transparent : pulso.outline)),
      child: InkWell(
        borderRadius: BorderRadius.circular(Pulso.cardRadius),
        onTap: onOpen,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(14, 12, 8, 12),
          child: Row(children: [
            Icon(notes.isEmpty ? Icons.check_circle_outline : (urgent ? Icons.error_outline : Icons.inbox_outlined), color: notes.isEmpty ? hint : color),
            const SizedBox(width: 12),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(urgent ? '$title · urgente' : title, style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                Text(detail, style: TextStyle(fontSize: 12, color: hint)),
              ]),
            ),
            if (onOpen != null) Icon(Icons.chevron_right, color: hint),
          ]),
        ),
      ),
    );
  }
}

/// A card with a title, an optional subtitle, an optional link to its full screen and its content.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, this.subtitle, this.action, required this.child, this.padding = const EdgeInsets.fromLTRB(16, 0, 16, 16)});
  final String title;
  final String? subtitle;
  final (String, VoidCallback)? action;
  final Widget child;
  final EdgeInsets padding;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 12, action == null ? 16 : 4, 8),
            child: Row(children: [
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
                  if (subtitle != null) Text(subtitle!, style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
                ]),
              ),
              if (action case (final label, final onTap)) TextButton(onPressed: onTap, child: Text(label)),
            ]),
          ),
          Padding(padding: padding, child: child),
        ]),
      );
}

/// ¿Cómo voy este mes? Spending against the budget in words and one bar, the daily margin, and income, expenses and
/// the month's saving (income minus expenses); the month day by day on request.
class _MonthCard extends StatelessWidget {
  const _MonthCard({required this.calc, required this.month, required this.onMonth, required this.pace, required this.hasBudgets});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  final MonthPace? pace;
  final bool hasBudgets;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final summary = calc.monthlySummary(month);
    Widget figure(String label, String value) => Expanded(
          child: MergeSemantics(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(label, style: TextStyle(fontSize: 12, color: hint), maxLines: 2),
              FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
              ),
            ]),
          ),
        );
    final p = pace;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          MonthSelector(month: month, onMonth: onMonth),
          if (p != null) ...[
            Text.rich(TextSpan(children: [
              TextSpan(text: money(p.spentMinor), style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w800)),
              TextSpan(text: ' de ${money(p.limitMinor)} en las categorías con presupuesto', style: TextStyle(fontSize: 14, color: hint)),
            ])),
            const SizedBox(height: 8),
            LayoutBuilder(builder: (context, constraints) {
              final width = constraints.maxWidth;
              final spent = (p.spentMinor / p.limitMinor).clamp(0.0, 1.0);
              final expected = (p.expectedMinor / p.limitMinor).clamp(0.0, 1.0);
              return ExcludeSemantics(
                child: SizedBox(
                  height: 16,
                  child: Stack(alignment: Alignment.centerLeft, children: [
                    Container(height: 8, decoration: BoxDecoration(color: pulso.tertiary, borderRadius: BorderRadius.circular(4))),
                    Container(
                        height: 8,
                        width: (width * spent).clamp(4.0, width),
                        decoration: BoxDecoration(color: p.differenceMinor >= 0 ? pulso.accent : pulso.expense, borderRadius: BorderRadius.circular(4))),
                    Positioned(
                      left: (width * expected - 1).clamp(0.0, width - 2),
                      child: Container(width: 2, height: 16, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6)),
                    ),
                  ]),
                ),
              );
            }),
            const SizedBox(height: 8),
            Text(
              p.differenceMinor >= 0
                  ? 'Vas ${money(p.differenceMinor)} por debajo del ritmo de hoy (la marca).'
                  : 'Vas ${money(-p.differenceMinor)} por encima del ritmo de hoy (la marca).',
              style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: p.differenceMinor >= 0 ? null : pulso.expense),
            ),
            Text(
              p.dailyMarginMinor > 0
                  ? 'Tu margen de hoy: ${money(p.dailyMarginMinor)} al día ${p.daysLeft == 1 ? 'hasta mañana' : 'durante ${p.daysLeft} días'} para no pasarte.'
                  : 'Ya has usado todo el presupuesto del mes.',
              style: TextStyle(fontSize: 12, color: hint),
            ),
            const Divider(height: 24),
          ] else if (!hasBudgets) ...[
            Text('Sin presupuesto este mes. Puedes crearlo en Presupuestos.', style: TextStyle(fontSize: 12, color: hint)),
            const Divider(height: 24),
          ],
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            figure('Ingresos', money(summary.incomeMinor)),
            figure('Gastos (todos)', money(summary.expenseMinor)),
            figure('Ahorro del mes', money(summary.netSavingsMinor, signed: true)),
          ]),
          const SizedBox(height: 4),
          Text('Ahorro del mes = ingresos − gastos de este mes.', style: TextStyle(fontSize: 11, color: hint)),
          Disclosure(title: 'Ver el mes día a día', child: _MonthDays(calc: calc, month: month)),
        ]),
      ),
    );
  }
}

/// The month day by day: each day tinted by what was spent on it, today outlined.
class _MonthDays extends StatelessWidget {
  const _MonthDays({required this.calc, required this.month});
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
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        GridView.count(
          crossAxisCount: 7,
          shrinkWrap: true,
          padding: EdgeInsets.zero,
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
          Text('El día con más gasto fue el ${busiest.key}: ${money(busiest.value)}.', style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
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
