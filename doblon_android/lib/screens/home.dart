import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'chrome.dart' show tabListPadding;
import 'widgets.dart';

/// Inicio: the available money in its own card, the month with its calendar (each day opens its movements below),
/// net worth over time, then the budgets and the goal. Short labels; every amount once.
class HomeScreen extends StatefulWidget {
  const HomeScreen(
      {super.key, required this.calc, required this.month, required this.onMonth, this.onAdd, this.heldMinor = 0, this.onOpenTab, this.onOpenTransaction});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  final VoidCallback? onAdd;
  final ValueChanged<int>? onOpenTab;
  final ValueChanged<Transaction>? onOpenTransaction;

  /// Charges the bank holds and has not booked yet (negative), already taken from what is available.
  final int heldMinor;

  @override
  State<HomeScreen> createState() => _HomeScreenState();
}

class _HomeScreenState extends State<HomeScreen> {
  /// The day whose movements are listed under the calendar: today in the current month, none in another.
  int? day;

  @override
  void initState() {
    super.initState();
    day = _today(widget.month);
  }

  @override
  void didUpdateWidget(HomeScreen old) {
    super.didUpdateWidget(old);
    if (old.month != widget.month) day = _today(widget.month);
  }

  static int? _today(DateTime month) {
    final now = DateTime.now();
    return month.year == now.year && month.month == now.month ? now.day : null;
  }

  @override
  Widget build(BuildContext context) {
    final calc = widget.calc;
    final data = calc.data;
    if (data.accounts.where((a) => !a.isArchived).isEmpty) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: tabListPadding(context, horizontal: 24, top: 48), children: [
        const Icon(Icons.account_balance_outlined, size: 48),
        const SizedBox(height: 12),
        const Text('Empieza con tus datos', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Añade tu primera cuenta o efectivo en Cuentas, o conecta tu banco en Ajustes › Mis bancos.', textAlign: TextAlign.center),
        if (widget.onAdd != null) ...[const SizedBox(height: 16), FilledButton(onPressed: widget.onAdd, child: const Text('Añadir mi primera cuenta'))],
      ]);
    }
    final now = DateTime.now();
    final month = widget.month;
    final isCurrentMonth = month.year == now.year && month.month == now.month;
    final budgets = calc.budgetProgress(month).where((b) => b.limitMinor > 0).toList();
    final pace = isCurrentMonth ? MonthPace.of(budgets, now) : null;
    final goal = _primaryGoal();
    final monthPanel = _MonthPanel(
      calc: calc,
      month: month,
      onMonth: widget.onMonth,
      pace: pace,
      day: day,
      onDay: (d) => setState(() => day = d == day ? null : d),
      onOpenTransaction: widget.onOpenTransaction,
      onAll: widget.onOpenTab == null ? null : () => widget.onOpenTab!(1),
    );
    final side = <Widget>[
      _NetWorthPanel(calc: calc),
      if (budgets.isNotEmpty)
        _SectionCard(
          title: 'Presupuestos',
          action: widget.onOpenTab == null ? null : ('Ver todos', () => widget.onOpenTab!(3)),
          child: Column(children: [for (final b in budgets.take(3)) BudgetBar(item: b)]),
        ),
      if (goal != null) _GoalCard(goal: goal, saved: _saved(goal)),
    ];
    Widget spaced(Widget w) => Padding(padding: const EdgeInsets.only(bottom: 16), child: w);
    return LayoutBuilder(builder: (context, constraints) {
      final wide = constraints.maxWidth >= 720;
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: tabListPadding(context, top: 4), children: [
        spaced(_AvailableCard(calc: calc, heldMinor: widget.heldMinor, onOpen: widget.onOpenTab == null ? null : () => widget.onOpenTab!(2))),
        if (wide)
          // iPad: the month on the left, net worth, budgets and goal on the right.
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Expanded(child: spaced(monthPanel)),
            const SizedBox(width: 16),
            Expanded(child: Column(children: [for (final w in side) spaced(w)])),
          ])
        else ...[
          spaced(monthPanel),
          for (final w in side) spaced(w),
        ],
      ]);
    });
  }

  /// A goal linked to an account follows that account's balance; otherwise the amount written by hand.
  int _saved(SavingsGoal goal) {
    final account = widget.calc.data.account(goal.linkedAccountId);
    final value = account != null ? widget.calc.balance(account) : goal.currentAmountMinor;
    return value < 0 ? 0 : value;
  }

  double _progress(SavingsGoal goal) => goal.targetAmountMinor <= 0 ? 1 : _saved(goal) / goal.targetAmountMinor;

  /// The unfinished goal closest to completion, otherwise the first one (Swift `primaryGoal`).
  SavingsGoal? _primaryGoal() {
    final goals = widget.calc.data.goals;
    final open = goals.where((g) => _progress(g) < 1).toList();
    if (open.isEmpty) return goals.firstOrNull;
    return open.reduce((a, b) => _progress(b) > _progress(a) ? b : a);
  }
}

/// Deep teal of the «Disponible» card, the same in light and dark so the white figure always has contrast.
const _cardTop = Color(0xFF12857C), _cardBottom = Color(0xFF0A4E4A), _cardTopDark = Color(0xFF145F5A), _cardBottomDark = Color(0xFF0B2E31);

/// «Disponible», alone in its card and the largest figure of the app, on a deep teal with the faint rings of a coin
/// (a doblón). Below it, what is not available: reserved, held by the bank and invested. Tapping opens Cuentas.
class _AvailableCard extends StatelessWidget {
  const _AvailableCard({required this.calc, required this.heldMinor, this.onOpen});
  final FinanceCalculator calc;
  final int heldMinor;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final dark = Theme.of(context).brightness == Brightness.dark;
    final available = calc.spendableCash() + heldMinor;
    final reserved = calc.reservedTotal();
    final invested = calc.invested();
    const soft = Color(0xCCFFFFFF);
    final stats = <(String, String, Color?)>[
      if (reserved > 0) ('Reservado', money(reserved), null),
      if (heldMinor != 0) ('Retenido', money(heldMinor.abs()), null),
      if (invested != 0) ('Invertido', money(invested), null),
    ];
    return Material(
      borderRadius: BorderRadius.circular(24),
      clipBehavior: Clip.antiAlias,
      child: Ink(
        decoration: BoxDecoration(
          gradient: LinearGradient(
              begin: Alignment.topLeft, end: Alignment.bottomRight, colors: dark ? const [_cardTopDark, _cardBottomDark] : const [_cardTop, _cardBottom]),
        ),
        child: InkWell(
          onTap: onOpen,
          child: Stack(children: [
            const Positioned(right: -36, top: -40, child: ExcludeSemantics(child: CustomPaint(size: Size.square(170), painter: _CoinRings()))),
            Padding(
              padding: const EdgeInsets.fromLTRB(20, 18, 20, 18),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const Expanded(child: Text('Disponible', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: soft, letterSpacing: 0.2))),
                  if (onOpen != null) const Icon(Icons.chevron_right, color: soft),
                ]),
                const SizedBox(height: 2),
                FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(money(available),
                      style: const TextStyle(
                          fontSize: 48,
                          height: 1.1,
                          fontWeight: FontWeight.w800,
                          letterSpacing: -1.4,
                          color: Colors.white,
                          fontFeatures: [FontFeature.tabularFigures()])),
                ),
                if (stats.isNotEmpty) ...[
                  const SizedBox(height: 16),
                  Container(height: 1, color: const Color(0x33FFFFFF)),
                  const SizedBox(height: 12),
                  LabelValues(
                    gap: 16,
                    labelStyle: const TextStyle(fontSize: 12, color: soft),
                    valueStyle: const TextStyle(fontSize: 15, fontWeight: FontWeight.w700, color: Colors.white),
                    items: stats,
                  ),
                ],
              ]),
            ),
          ]),
        ),
      ),
    );
  }
}

/// The edge of a coin: two faint rings and a ring of dots.
class _CoinRings extends CustomPainter {
  const _CoinRings();

  @override
  void paint(Canvas canvas, Size size) {
    final center = size.center(Offset.zero), r = size.shortestSide / 2;
    final ring = Paint()
      ..style = PaintingStyle.stroke
      ..color = const Color(0x1FFFFFFF);
    canvas.drawCircle(center, r - 2, ring..strokeWidth = 3);
    canvas.drawCircle(center, r * 0.72, ring..strokeWidth = 2);
    final dot = Paint()..color = const Color(0x1AFFFFFF);
    for (var i = 0; i < 28; i++) {
      final a = i * math.pi * 2 / 28;
      canvas.drawCircle(center + Offset(math.cos(a), math.sin(a)) * r * 0.86, 2.2, dot);
    }
  }

  @override
  bool shouldRepaint(_CoinRings old) => false;
}

/// A card with a short title, an optional link to its full screen and its content.
class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, this.action, required this.child});
  final String title;
  final (String, VoidCallback)? action;
  final Widget child;

  @override
  Widget build(BuildContext context) => Card(
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          Padding(
            padding: EdgeInsets.fromLTRB(16, 10, action == null ? 16 : 4, 6),
            child: Row(children: [
              Expanded(
                  child: Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)))),
              if (action case (final label, final onTap)) TextButton(onPressed: onTap, child: Text(label)),
            ]),
          ),
          Padding(padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), child: child),
        ]),
      );
}

/// The month: the selector, spending, income and saving in one line, the budget with its pace, and the calendar of
/// daily spending. A day opens its movements right below.
class _MonthPanel extends StatelessWidget {
  const _MonthPanel(
      {required this.calc,
      required this.month,
      required this.onMonth,
      required this.pace,
      required this.day,
      required this.onDay,
      this.onOpenTransaction,
      this.onAll});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  final MonthPace? pace;
  final int? day;
  final ValueChanged<int> onDay;
  final ValueChanged<Transaction>? onOpenTransaction;
  final VoidCallback? onAll;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final summary = calc.monthlySummary(month);
    final p = pace;
    final selected = day;
    final dayMovements = selected == null
        ? const <Transaction>[]
        : calc.data.transactions.where((t) {
            final d = t.date.toLocal();
            return d.year == month.year && d.month == month.month && d.day == selected;
          }).toList();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(12, 4, 12, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          MonthSelector(month: month, onMonth: onMonth),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 4),
            child: LabelValues(
              labelStyle: TextStyle(fontSize: 12, color: hint),
              valueStyle: const TextStyle(fontSize: 17, fontWeight: FontWeight.w800),
              items: [
                // Everyday figures: money of reserves (set aside or paid with them) is shown apart, below.
                ('Gastos', money(summary.dailyExpenseMinor), null),
                ('Ingresos', money(summary.dailyIncomeMinor), null),
                ('Ahorro', money(summary.dailyNetMinor, signed: true), summary.dailyNetMinor < 0 ? pulso.expense : null),
              ],
            ),
          ),
          if (summary.hasReserves)
            Padding(
              padding: const EdgeInsets.fromLTRB(4, 6, 4, 0),
              child: Text(
                  [
                    if (summary.reservedExpenseMinor > 0) '${money(summary.reservedExpenseMinor)} pagados con reservas',
                    if (summary.reservedIncomeMinor > 0) '${money(summary.reservedIncomeMinor)} a reservas',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: hint)),
            ),
          if (p != null) ...[
            const SizedBox(height: 12),
            _BudgetPace(pace: p),
          ],
          const SizedBox(height: 14),
          _Calendar(calc: calc, month: month, selected: selected, onDay: onDay),
          if (selected != null) ...[
            const SizedBox(height: 10),
            Padding(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              child: Row(children: [
                Expanded(
                  child: Text(_dayTitle(DateTime(month.year, month.month, selected)), style: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700)),
                ),
                if (onAll != null) TextButton(onPressed: onAll, child: const Text('Movimientos')),
              ]),
            ),
            if (dayMovements.isEmpty)
              Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 4), child: Text('Sin movimientos este día.', style: TextStyle(fontSize: 13, color: hint)))
            else
              for (final t in dayMovements)
                InkWell(
                  borderRadius: BorderRadius.circular(Pulso.compactRadius),
                  onTap: onOpenTransaction == null ? null : () => onOpenTransaction!(t),
                  child: IgnorePointer(child: TransactionTile(transaction: t, data: calc.data)),
                ),
          ],
        ]),
      ),
    );
  }

  static String _dayTitle(DateTime d) {
    final text = DateFormat("EEEE d 'de' MMMM", 'es').format(d);
    return '${text[0].toUpperCase()}${text.substring(1)}';
  }
}

/// Budgeted categories against their limit: one line, one thin bar with the mark of an even pace, and the gap to the
/// pace said in words with an arrow (not only with colour). It is not the total spending, which is above.
class _BudgetPace extends StatelessWidget {
  const _BudgetPace({required this.pace});
  final MonthPace pace;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final over = pace.differenceMinor < 0;
    final color = over ? pulso.expense : pulso.accent;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(color: pulso.tertiary, borderRadius: BorderRadius.circular(Pulso.compactRadius)),
      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
        Wrap(spacing: 8, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.center, children: [
          Text.rich(
              TextSpan(children: [
                TextSpan(text: 'Presupuestado ', style: TextStyle(color: hint)),
                TextSpan(text: money(pace.spentMinor), style: const TextStyle(fontWeight: FontWeight.w800)),
                TextSpan(text: ' / ${money(pace.limitMinor)}', style: TextStyle(color: hint)),
              ]),
              style: const TextStyle(fontSize: 13)),
          Row(mainAxisSize: MainAxisSize.min, children: [
            Icon(over ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: color),
            Flexible(
              child: Text('${money(pace.differenceMinor.abs())} ${over ? 'sobre' : 'bajo'} el ritmo',
                  style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        ]),
        const SizedBox(height: 8),
        LayoutBuilder(builder: (context, constraints) {
          final width = constraints.maxWidth;
          final spent = (pace.spentMinor / pace.limitMinor).clamp(0.0, 1.0);
          final expected = (pace.expectedMinor / pace.limitMinor).clamp(0.0, 1.0);
          return ExcludeSemantics(
            child: SizedBox(
              height: 12,
              child: Stack(alignment: Alignment.centerLeft, children: [
                Container(
                    height: 6,
                    decoration: BoxDecoration(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.08), borderRadius: BorderRadius.circular(3))),
                Container(height: 6, width: (width * spent).clamp(3.0, width), decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3))),
                Positioned(
                    left: (width * expected - 1).clamp(0.0, width - 2),
                    child: Container(width: 2, height: 12, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.6))),
              ]),
            ),
          );
        }),
        const SizedBox(height: 6),
        Text(pace.dailyMarginMinor > 0 ? 'Margen de hoy ${money(pace.dailyMarginMinor)} · ${pace.daysLeft} días' : 'Presupuesto agotado',
            style: TextStyle(fontSize: 12, color: hint)),
      ]),
    );
  }
}

/// The days of the month with what was spent on each: the amount written in the day and its tint growing with it.
/// Today has a ring and a dot; the chosen day is filled. Days to come are faded.
class _Calendar extends StatelessWidget {
  const _Calendar({required this.calc, required this.month, required this.selected, required this.onDay});
  final FinanceCalculator calc;
  final DateTime month;
  final int? selected;
  final ValueChanged<int> onDay;

  /// «48», «1,2 mil»: whole euros, short enough for a day cell.
  static String short(int minor) {
    final euros = (minor / 100).round();
    if (euros >= 1000) return '${NumberFormat('#,##0.#', 'es').format(euros / 1000)} mil';
    return '$euros';
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final onSurface = Theme.of(context).colorScheme.onSurface;
    final now = DateTime.now();
    final spend = calc.dailySpending(month);
    final days = DateTime(month.year, month.month + 1, 0).day;
    final leading = DateTime(month.year, month.month, 1).weekday - 1; // Monday first
    final maximum = spend.values.fold(1, (a, b) => b > a ? b : a);
    final isCurrent = month.year == now.year && month.month == now.month;
    final today = isCurrent ? now.day : (DateTime(month.year, month.month).isAfter(now) ? 0 : days + 1);
    final format = DateFormat("EEEE d 'de' MMMM", 'es');
    return Column(children: [
      Row(children: [
        for (final initial in const ['L', 'M', 'X', 'J', 'V', 'S', 'D'])
          Expanded(child: Center(child: Text(initial, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: Theme.of(context).hintColor)))),
      ]),
      const SizedBox(height: 6),
      // The cells keep their size with very large text (each day is read in full by the screen reader).
      MediaQuery.withClampedTextScaling(
        maxScaleFactor: 1.15,
        child: LayoutBuilder(builder: (context, constraints) {
          // Cells only as tall as the day and its amount need at the current text size.
          final width = (constraints.maxWidth - 6 * 4) / 7;
          final needed = 2 * 11 * MediaQuery.textScalerOf(context).scale(1) * 1.45 + 8;
          return GridView.count(
            crossAxisCount: 7,
            shrinkWrap: true,
            padding: EdgeInsets.zero,
            physics: const NeverScrollableScrollPhysics(),
            mainAxisSpacing: 4,
            crossAxisSpacing: 4,
            childAspectRatio: width / math.max(width * 0.82, needed),
            children: [
              for (var i = 0; i < leading; i++) const SizedBox.shrink(),
              for (var d = 1; d <= days; d++)
                () {
                  final amount = spend[d] ?? 0;
                  final level = amount == 0 ? 0.0 : 0.18 + 0.62 * amount / maximum;
                  final isSelected = d == selected, isToday = d == today, future = d > today;
                  final fill = isSelected ? onSurface : (level == 0 ? pulso.tertiary : Color.alphaBlend(pulso.accent.withValues(alpha: level), pulso.card));
                  final ink = isSelected ? pulso.page : (level > 0.5 ? Colors.white : onSurface);
                  final date = format.format(DateTime(month.year, month.month, d));
                  return Semantics(
                    button: true,
                    selected: isSelected,
                    label: '$date${isToday ? ', hoy' : ''}${amountsHidden || future ? '' : ', gastado ${money(amount)}'}',
                    excludeSemantics: true,
                    child: Material(
                      color: fill,
                      shape: RoundedRectangleBorder(
                          borderRadius: BorderRadius.circular(8),
                          side: isToday ? BorderSide(color: isSelected ? pulso.accent : onSurface, width: 2) : BorderSide.none),
                      child: InkWell(
                        borderRadius: BorderRadius.circular(8),
                        onTap: future ? null : () => onDay(d),
                        child: Opacity(
                          opacity: future ? 0.4 : 1,
                          child: Padding(
                            padding: const EdgeInsets.fromLTRB(4, 2, 3, 2),
                            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                              FittedBox(
                                fit: BoxFit.scaleDown,
                                alignment: Alignment.centerLeft,
                                child: Row(mainAxisSize: MainAxisSize.min, children: [
                                  Text('$d', style: TextStyle(fontSize: 11, fontWeight: isToday ? FontWeight.w900 : FontWeight.w600, color: ink)),
                                  if (isToday) ...[
                                    const SizedBox(width: 2),
                                    Container(width: 4, height: 4, decoration: BoxDecoration(color: ink, shape: BoxShape.circle))
                                  ],
                                ]),
                              ),
                              const Spacer(),
                              if (amount > 0 && !amountsHidden)
                                Align(
                                  alignment: Alignment.bottomRight,
                                  child: FittedBox(
                                    fit: BoxFit.scaleDown,
                                    child: Text(short(amount), style: TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: ink)),
                                  ),
                                ),
                            ]),
                          ),
                        ),
                      ),
                    ),
                  );
                }(),
            ],
          );
        }),
      ),
    ]);
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
      title: 'Objetivo',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Icon(fraction >= 1 ? Icons.verified : Icons.flag_outlined, color: color),
          const SizedBox(width: 10),
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(goal.name, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${money(saved)} de ${money(goal.targetAmountMinor)}', style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
            ]),
          ),
          Text(NumberFormat.percentPattern('es').format(fraction), style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        ]),
        const SizedBox(height: 10),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(value: fraction, minHeight: 8, color: color, backgroundColor: Pulso.of(context).tertiary),
        ),
      ]),
    );
  }
}

/// Net worth at the end of each month, from the first month with an account (never zeros before there was history),
/// up to today. At most the last 12 months.
List<(DateTime, int)> netWorthHistory(FinanceCalculator calc, DateTime now) {
  final counted = calc.data.accounts.where((a) => a.includeInNetWorth && !a.isArchived);
  if (counted.isEmpty) return const [];
  final first = counted.map((a) => a.openingDate).reduce((a, b) => a.isBefore(b) ? a : b);
  var start = DateTime(now.year, now.month - 11);
  if (DateTime(first.year, first.month).isAfter(start)) start = DateTime(first.year, first.month);
  return [
    for (var m = start; !m.isAfter(DateTime(now.year, now.month)); m = DateTime(m.year, m.month + 1))
      () {
        final last = m.year == now.year && m.month == now.month;
        final end = last ? now : DateTime(m.year, m.month + 1, 0, 23, 59, 59);
        return (last ? now : DateTime(m.year, m.month + 1, 0), calc.netWorth(end));
      }(),
  ];
}

/// Net worth: its value today, the change this month and the line of the last months, with straight segments between
/// real month-end values. Touching the line shows each month's date and value.
class _NetWorthPanel extends StatelessWidget {
  const _NetWorthPanel({required this.calc});
  final FinanceCalculator calc;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final now = DateTime.now();
    final history = netWorthHistory(calc, now);
    final value = calc.netWorth(now);
    final change = value - calc.netWorth(DateTime(now.year, now.month, 1).subtract(const Duration(seconds: 1)));
    final monthName = DateFormat('MMM yyyy', 'es');
    final period = history.length < 2 ? 'Este mes' : '${monthName.format(history.first.$1)} – hoy';
    return _SectionCard(
      title: 'Patrimonio',
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Wrap(spacing: 10, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.end, children: [
          Text(money(value), style: const TextStyle(fontSize: 24, fontWeight: FontWeight.w800, letterSpacing: -0.5)),
          Padding(
            padding: const EdgeInsets.only(bottom: 3),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              Icon(change >= 0 ? Icons.arrow_upward : Icons.arrow_downward, size: 14, color: change >= 0 ? pulso.income : pulso.expense),
              Text('${money(change, signed: true)} este mes',
                  style: TextStyle(fontSize: 13, fontWeight: FontWeight.w700, color: change >= 0 ? pulso.income : pulso.expense)),
            ]),
          ),
        ]),
        Text(period, style: TextStyle(fontSize: 12, color: hint)),
        const SizedBox(height: 12),
        SizedBox(
          height: 150,
          child: amountsHidden
              ? Center(child: Text('Importes ocultos', style: TextStyle(color: hint)))
              : history.length < 2
                  ? Center(child: Text('La línea aparecerá cuando haya dos meses de historial.', textAlign: TextAlign.center, style: TextStyle(color: hint)))
                  : _NetWorthLine(history: history),
        ),
      ]),
    );
  }
}

class _NetWorthLine extends StatelessWidget {
  const _NetWorthLine({required this.history});
  final List<(DateTime, int)> history;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final color = pulso.accent;
    final values = history.map((p) => p.$2 / 100).toList();
    final min = values.reduce(math.min), max = values.reduce(math.max);
    final margin = math.max((max - min) * 0.15, math.max(max.abs(), min.abs()) * 0.02 + 1);
    final label = DateFormat('MMM', 'es'), full = DateFormat("d 'de' MMMM yyyy", 'es');
    final step = history.length <= 6 ? 1 : 2;
    return Semantics(
      label: 'Patrimonio: ${[for (final p in history) '${label.format(p.$1)} ${money(p.$2)}'].join(', ')}',
      child: LineChart(LineChartData(
        minY: min - margin,
        maxY: max + margin,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        lineTouchData: LineTouchData(
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => Theme.of(context).colorScheme.onSurface,
            getTooltipItems: (spots) => [
              for (final s in spots)
                LineTooltipItem('${full.format(history[s.x.round()].$1)}\n', TextStyle(color: pulso.page, fontSize: 11), children: [
                  TextSpan(text: money(history[s.x.round()].$2), style: TextStyle(color: pulso.page, fontWeight: FontWeight.w800, fontSize: 13)),
                ]),
            ],
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
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                final i = value.round();
                if (i < 0 || i >= history.length || (history.length - 1 - i) % step != 0) return const SizedBox.shrink();
                return Padding(padding: const EdgeInsets.only(top: 4), child: Text(label.format(history[i].$1), style: Theme.of(context).textTheme.bodySmall));
              },
            ),
          ),
        ),
        lineBarsData: [
          LineChartBarData(
            spots: [for (var i = 0; i < values.length; i++) FlSpot(i.toDouble(), values[i])],
            // Straight between real month-end values: a curve would suggest values that never existed.
            isCurved: false,
            color: color,
            barWidth: 3,
            dotData: FlDotData(
                getDotPainter: (spot, percent, bar, index) =>
                    FlDotCirclePainter(radius: index == values.length - 1 ? 4.5 : 2.5, color: color, strokeWidth: 2, strokeColor: pulso.card)),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.22), color.withValues(alpha: 0.0)]),
            ),
          ),
        ],
      )),
    );
  }
}
