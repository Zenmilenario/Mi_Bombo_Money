import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';

/// Previous / next month, as on the iPhone.
class MonthSelector extends StatelessWidget {
  const MonthSelector({super.key, required this.month, required this.onMonth});
  final DateTime month;
  final ValueChanged<DateTime> onMonth;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent = month.year == now.year && month.month == now.month;
    final label = DateFormat('MMMM yyyy', 'es').format(month);
    return Row(children: [
      IconButton(onPressed: () => onMonth(DateTime(month.year, month.month - 1)), icon: const Icon(Icons.chevron_left)),
      Expanded(
        child: Text('${label[0].toUpperCase()}${label.substring(1)}',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      IconButton(onPressed: isCurrent ? null : () => onMonth(DateTime(month.year, month.month + 1)), icon: const Icon(Icons.chevron_right)),
    ]);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
      );
}

class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.label, required this.value, required this.color, this.icon});
  final String label;
  final String value;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 16, color: color), const SizedBox(width: 6)],
              Expanded(child: Text(label, style: Theme.of(context).textTheme.labelMedium, overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        ),
      );
}

/// One movement in a list: title, account and category, signed amount.
class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.transaction, required this.data});
  final Transaction transaction;
  final Finances data;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final t = transaction;
    final category = data.category(t.categoryId);
    final source = data.account(t.sourceAccountId);
    final destination = data.account(t.destinationAccountId);
    final signed = switch (t.type) {
      TransactionType.income || TransactionType.interest => t.amountMinor,
      TransactionType.expense || TransactionType.fee => -t.amountMinor,
      TransactionType.transfer => 0,
    };
    final color = signed > 0 ? pulso.income : (signed < 0 ? pulso.expense : pulso.savings);
    final accountText = t.type == TransactionType.transfer
        ? '${source?.name ?? 'Cuenta'} → ${destination?.name ?? 'Cuenta'}'
        : (source?.name ?? 'Cuenta');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      leading: CircleAvatar(
        backgroundColor: (category == null ? color : colorFromHex(category.colorHex)).withValues(alpha: 0.16),
        child: Icon(
          t.type == TransactionType.transfer ? Icons.swap_horiz : (signed > 0 ? Icons.south_west : Icons.north_east),
          size: 18,
          color: category == null ? color : colorFromHex(category.colorHex),
        ),
      ),
      title: Text(listTitle(t.descriptionText, isBanking: t.isBanking), maxLines: 1, overflow: TextOverflow.ellipsis,
          style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Text(accountText, maxLines: 1, overflow: TextOverflow.ellipsis),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(t.type == TransactionType.transfer ? money(t.amountMinor) : money(signed, signed: true),
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        Text(
          t.awaitsBank ? 'Pendiente del banco' : (t.type == TransactionType.transfer ? 'Transferencia' : (category?.name ?? 'Sin categoría')),
          style: TextStyle(fontSize: 11, color: t.awaitsBank ? pulso.warning : Theme.of(context).hintColor),
        ),
      ]),
    );
  }
}

class BudgetBar extends StatelessWidget {
  const BudgetBar({super.key, required this.item});
  final BudgetProgress item;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final color = item.spentMinor > item.limitMinor ? pulso.expense : (item.fraction >= 0.85 ? pulso.warning : pulso.income);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(item.category.name, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(item.limitMinor > 0 ? '${money(item.spentMinor)} de ${money(item.limitMinor)}' : money(item.spentMinor),
              style: Theme.of(context).textTheme.bodySmall),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: item.limitMinor > 0 ? item.fraction.clamp(0, 1).toDouble() : 0,
            minHeight: 8,
            color: color,
            backgroundColor: pulso.tertiary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          item.limitMinor <= 0
              ? 'Sin presupuesto'
              : item.availableMinor >= 0
                  ? 'Quedan ${money(item.availableMinor)}${item.carriedInMinor > 0 ? ' · incluye ${money(item.carriedInMinor)} del mes anterior' : ''}'
                  : 'Superado en ${money(-item.availableMinor)}',
          style: TextStyle(fontSize: 12, color: color),
        ),
      ]),
    );
  }
}
