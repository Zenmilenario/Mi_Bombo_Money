import 'package:flutter/material.dart';

import '../finance.dart';
import '../presentation.dart';
import '../theme.dart';
import 'widgets.dart';

/// Presupuestos: the chosen month, with what carries over from earlier months.
class BudgetsScreen extends StatelessWidget {
  const BudgetsScreen({super.key, required this.calc, required this.month, required this.onMonth});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final items = calc.budgetProgress(month);
    final budgeted = items.where((i) => i.limitMinor > 0).toList();
    final unbudgeted = items.where((i) => i.limitMinor <= 0).toList();
    final total = budgeted.fold(0, (sum, i) => sum + i.limitMinor);
    final spent = budgeted.fold(0, (sum, i) => sum + i.spentMinor);
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
      MonthSelector(month: month, onMonth: onMonth),
      Row(children: [
        Expanded(child: MetricTile(label: 'Presupuestado', value: money(total), color: pulso.savings)),
        const SizedBox(width: 10),
        Expanded(child: MetricTile(label: 'Gastado', value: money(spent), color: spent > total ? pulso.expense : pulso.accent)),
        const SizedBox(width: 10),
        Expanded(child: MetricTile(label: 'Disponible', value: money(total - spent), color: total - spent >= 0 ? pulso.income : pulso.expense)),
      ]),
      if (budgeted.isEmpty)
        const Padding(padding: EdgeInsets.all(24), child: Text('No hay presupuestos este mes.', textAlign: TextAlign.center))
      else ...[
        const SectionTitle('Por categoría'),
        Card(child: Padding(padding: const EdgeInsets.all(14), child: Column(children: [for (final i in budgeted) BudgetBar(item: i)]))),
      ],
      if (unbudgeted.isNotEmpty) ...[
        const SectionTitle('Gasto sin presupuesto'),
        Card(
          child: Column(children: [
            for (final i in unbudgeted) ListTile(title: Text(i.category.name), trailing: Text(money(i.spentMinor))),
          ]),
        ),
      ],
    ]);
  }
}
