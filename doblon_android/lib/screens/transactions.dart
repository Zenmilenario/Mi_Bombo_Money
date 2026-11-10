import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import 'widgets.dart';

/// Movimientos: every movement grouped by day, with a search box.
class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, required this.calc});
  final FinanceCalculator calc;
  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  String query = '';

  bool _matches(Transaction t, Finances data) {
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return [
      t.descriptionText,
      listTitle(t.descriptionText, isBanking: t.isBanking),
      t.notes,
      data.account(t.sourceAccountId)?.name ?? '',
      data.account(t.destinationAccountId)?.name ?? '',
      data.category(t.categoryId)?.name ?? '',
    ].any((text) => text.toLowerCase().contains(q));
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.calc.data;
    final visible = data.transactions.where((t) => _matches(t, data)).toList();
    final days = <DateTime, List<Transaction>>{};
    for (final t in visible) {
      (days[DateTime(t.date.year, t.date.month, t.date.day)] ??= []).add(t);
    }
    final ordered = days.keys.toList()..sort((a, b) => b.compareTo(a));
    final format = DateFormat("EEEE d 'de' MMMM yyyy", 'es');
    return CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
      SliverPadding(
        padding: const EdgeInsets.fromLTRB(16, 8, 16, 8),
        sliver: SliverToBoxAdapter(
          child: TextField(
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar concepto, cuenta o categoría', border: OutlineInputBorder()),
            onChanged: (value) => setState(() => query = value.trim()),
          ),
        ),
      ),
      if (ordered.isEmpty)
        const SliverFillRemaining(hasScrollBody: false, child: Center(child: Text('Sin resultados')))
      else
        SliverList.builder(
          itemCount: ordered.length,
          itemBuilder: (context, index) {
            final day = ordered[index];
            final label = format.format(day);
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
                  child: Text('${label[0].toUpperCase()}${label.substring(1)}', style: Theme.of(context).textTheme.labelLarge),
                ),
                Card(child: Column(children: [for (final t in days[day]!) TransactionTile(transaction: t, data: data)])),
              ]),
            );
          },
        ),
      const SliverToBoxAdapter(child: SizedBox(height: 24)),
    ]);
  }
}
