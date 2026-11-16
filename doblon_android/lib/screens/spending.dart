import 'package:flutter/material.dart';

import '../finance.dart';
import '../presentation.dart';
import '../theme.dart';
import 'widgets.dart';

/// Movimientos → Análisis de gastos, as on the iPhone (`SpendingAnalysisView`): the month's spending by category,
/// as bars in each category's colour and as a list with its icon.
class SpendingAnalysisScreen extends StatefulWidget {
  const SpendingAnalysisScreen({super.key, required this.calc});
  final FinanceCalculator calc;
  @override
  State<SpendingAnalysisScreen> createState() => _SpendingAnalysisScreenState();
}

class _SpendingAnalysisScreenState extends State<SpendingAnalysisScreen> {
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final spending = widget.calc.spendingByCategory(month);
    final total = widget.calc.monthlySummary(month).expenseMinor;
    final top = spending.isEmpty ? 1 : spending.first.$2;
    Widget metric(String label, String value, IconData icon, Color color) => Expanded(
          child: Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [Icon(icon, size: 16, color: color), const SizedBox(width: 6), Text(label, style: TextStyle(fontSize: 13, color: hint))]),
                const SizedBox(height: 6),
                Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w700, color: color)),
              ]),
            ),
          ),
        );
    return Scaffold(
      appBar: AppBar(title: const Text('Análisis de gastos', style: TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom), children: [
        MonthSelector(month: month, onMonth: (m) => setState(() => month = m)),
        Row(children: [
          metric('Gastos', money(total), Icons.north_east, pulso.expense),
          const SizedBox(width: 10),
          metric('Categorías activas', '${spending.length}', Icons.sell_outlined, pulso.savings),
        ]),
        const SizedBox(height: 14),
        Card(
          child: Padding(
            padding: const EdgeInsets.all(16),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const Text('Gastos por categoría', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              Text('Ordenados de mayor a menor', style: TextStyle(fontSize: 13, color: hint)),
              const SizedBox(height: 14),
              if (amountsHidden)
                Padding(padding: const EdgeInsets.symmetric(vertical: 30), child: Center(child: Text('Gráfico oculto por privacidad', style: TextStyle(color: hint))))
              else if (spending.isEmpty)
                Padding(padding: const EdgeInsets.symmetric(vertical: 30), child: Center(child: Text('No hay gastos en el mes seleccionado.', style: TextStyle(color: hint))))
              else
                for (final (category, amount) in spending.take(8))
                  Padding(
                    padding: const EdgeInsets.only(bottom: 10),
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Row(children: [
                        Expanded(child: Text(category.name, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                        Text(money(amount), style: TextStyle(fontSize: 13, color: hint)),
                      ]),
                      const SizedBox(height: 4),
                      LayoutBuilder(
                        builder: (context, c) => Container(
                          height: 14,
                          width: (c.maxWidth * amount / top).clamp(4.0, c.maxWidth),
                          decoration: BoxDecoration(color: colorFromHex(category.colorHex), borderRadius: BorderRadius.circular(5)),
                        ),
                      ),
                    ]),
                  ),
            ]),
          ),
        ),
        if (spending.isNotEmpty) ...[
          const SectionTitle('Detalle'),
          Card(
            child: Column(children: [
              for (final (category, amount) in spending)
                ListTile(
                  leading: Container(
                    width: 34,
                    height: 34,
                    decoration: BoxDecoration(color: colorFromHex(category.colorHex).withValues(alpha: 0.12), shape: BoxShape.circle),
                    child: Icon(symbolIcon(category.systemImage), size: 18, color: colorFromHex(category.colorHex)),
                  ),
                  title: Text(category.name, style: const TextStyle(fontWeight: FontWeight.w500)),
                  trailing: Text(money(amount), style: const TextStyle(fontWeight: FontWeight.w600)),
                ),
            ]),
          ),
        ],
      ]),
    );
  }
}
