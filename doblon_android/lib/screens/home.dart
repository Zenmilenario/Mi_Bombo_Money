import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';

import '../finance.dart';
import '../presentation.dart';
import '../theme.dart';
import 'widgets.dart';

/// Inicio: net worth with its 12-month history, what is available, the month's pace, the chosen month
/// and its budgets, and the latest movements.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.calc, required this.month, required this.onMonth, this.onAdd});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  final VoidCallback? onAdd;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final data = calc.data;
    if (data.accounts.where((a) => !a.isArchived).isEmpty) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(24), children: [
        const SizedBox(height: 80),
        const Icon(Icons.account_balance_outlined, size: 48),
        const SizedBox(height: 12),
        const Text('Empieza con tus datos', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        const SizedBox(height: 8),
        const Text('Añade tu primera cuenta o efectivo en Cuentas, o conecta tu banco en Ajustes › Mis bancos.', textAlign: TextAlign.center),
        if (onAdd != null) ...[const SizedBox(height: 16), FilledButton(onPressed: onAdd, child: const Text('Añadir mi primera cuenta'))],
      ]);
    }
    final now = DateTime.now();
    final summary = calc.monthlySummary(month);
    final budgets = calc.budgetProgress(month).where((b) => b.limitMinor > 0).take(4).toList();
    final recent = data.transactions.where((t) => t.date.toLocal().year == month.year && t.date.toLocal().month == month.month).take(5).toList();
    final available = calc.spendableCash();
    final isCurrentMonth = month.year == now.year && month.month == now.month;
    final daysLeft = DateTime(now.year, now.month + 1, 0).day - now.day + 1;
    final history = [
      for (var i = 11; i >= 0; i--)
        () {
          final start = DateTime(now.year, now.month - i);
          final end = i == 0 ? now : DateTime(start.year, start.month + 1, 0, 23, 59, 59);
          return (start, calc.netWorth(end));
        }()
    ];
    final previous = history[history.length - 2].$2;
    final change = history.last.$2 - previous;
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(20),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text('Patrimonio', style: Theme.of(context).textTheme.labelLarge),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(money(calc.netWorth()), style: const TextStyle(fontSize: 34, fontWeight: FontWeight.w800)),
            ),
            Text('${money(change, signed: true)} este mes', style: TextStyle(color: change >= 0 ? pulso.income : pulso.expense, fontWeight: FontWeight.w600)),
            const SizedBox(height: 16),
            SizedBox(height: 120, child: _NetWorthChart(points: history, color: pulso.accent)),
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _Figure(label: 'Disponible', value: money(available), color: pulso.accent)),
              Expanded(child: _Figure(label: 'Invertido', value: money(calc.invested()), color: pulso.investment)),
            ]),
          ]),
        ),
      ),
      if (isCurrentMonth && available > 0) ...[
        const SizedBox(height: 10),
        Card(
          child: ListTile(
            leading: Icon(Icons.speed, color: pulso.accent),
            title: Text('${money(available ~/ daysLeft)} al día'),
            subtitle: Text('Lo disponible repartido entre los $daysLeft días que quedan de mes'),
          ),
        ),
      ],
      const SizedBox(height: 8),
      MonthSelector(month: month, onMonth: onMonth),
      Row(children: [
        Expanded(child: MetricTile(label: 'Ingresos', value: money(summary.incomeMinor), color: pulso.income, icon: Icons.south_west)),
        const SizedBox(width: 10),
        Expanded(child: MetricTile(label: 'Gastos', value: money(summary.expenseMinor), color: pulso.expense, icon: Icons.north_east)),
        const SizedBox(width: 10),
        Expanded(
          child: MetricTile(
              label: 'Ahorro',
              value: money(summary.netSavingsMinor, signed: true),
              color: summary.netSavingsMinor >= 0 ? pulso.savings : pulso.expense,
              icon: Icons.savings_outlined),
        ),
      ]),
      if (budgets.isNotEmpty) ...[
        const SectionTitle('Presupuestos del mes'),
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [for (final b in budgets) BudgetBar(item: b)]))),
      ],
      const SectionTitle('Últimos movimientos del mes'),
      Card(
        child: recent.isEmpty
            ? const Padding(padding: EdgeInsets.all(16), child: Text('Sin movimientos este mes.'))
            : Column(children: [for (final t in recent) TransactionTile(transaction: t, data: data)]),
      ),
    ]);
  }
}

class _NetWorthChart extends StatelessWidget {
  const _NetWorthChart({required this.points, required this.color});
  final List<(DateTime, int)> points;
  final Color color;

  @override
  Widget build(BuildContext context) {
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

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, required this.color});
  final String label, value;
  final Color color;
  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: Theme.of(context).textTheme.labelMedium),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
        ),
      ]);
}
