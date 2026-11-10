import 'package:flutter/material.dart';

import '../finance.dart';
import '../presentation.dart';
import '../theme.dart';
import 'widgets.dart';

/// Inicio: net worth, what is available, the chosen month and its budgets.
class HomeScreen extends StatelessWidget {
  const HomeScreen({super.key, required this.calc, required this.month, required this.onMonth});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final data = calc.data;
    if (data.accounts.where((a) => !a.isArchived).isEmpty) {
      return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(24), children: const [
        SizedBox(height: 80),
        Icon(Icons.account_balance_outlined, size: 48),
        SizedBox(height: 12),
        Text('Todavía no tienes cuentas', textAlign: TextAlign.center, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
        SizedBox(height: 8),
        Text('Cuando añadas cuentas y movimientos en Doblón aparecerán aquí.', textAlign: TextAlign.center),
      ]);
    }
    final summary = calc.monthlySummary(month);
    final budgets = calc.budgetProgress(month).where((b) => b.limitMinor > 0).take(4).toList();
    final key = DateTime(month.year, month.month);
    final recent = data.transactions.where((t) => t.date.year == key.year && t.date.month == key.month).take(5).toList();
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
            const SizedBox(height: 16),
            Row(children: [
              Expanded(child: _Figure(label: 'Disponible', value: money(calc.spendableCash()), color: pulso.accent)),
              Expanded(child: _Figure(label: 'Invertido', value: money(calc.invested()), color: pulso.investment)),
            ]),
          ]),
        ),
      ),
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
