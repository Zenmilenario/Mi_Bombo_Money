import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'budgets.dart' show BudgetEditorScreen;
import 'transaction_detail.dart';

/// One budget in the month being looked at: its limit (with what an earlier month carried over), what was spent
/// and what is left or exceeded, and the movements behind that spending, by day. It follows the repository, so an
/// edited movement (category, date or reserve) changes this detail and the budget at once.
class BudgetDetailScreen extends StatefulWidget {
  const BudgetDetailScreen({super.key, required this.repository, required this.categoryId, required this.month});
  final FinanceRepository repository;
  final String categoryId;
  final DateTime month;

  @override
  State<BudgetDetailScreen> createState() => _BudgetDetailScreenState();
}

class _BudgetDetailScreenState extends State<BudgetDetailScreen> {
  Object? _from;
  FinanceCalculator? _calc;

  FinanceCalculator? get calc {
    final data = widget.repository.finances;
    if (data == null) return null;
    if (!identical(data, _from)) {
      _calc = FinanceCalculator(data);
      _from = data;
    }
    return _calc;
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: widget.repository,
        builder: (context, _) {
          final calc = this.calc;
          final category = calc?.data.category(widget.categoryId);
          final monthName = toBeginningOfSentenceCase(DateFormat('MMMM yyyy', 'es').format(widget.month));
          return Scaffold(
            appBar: AppBar(
              title: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(category?.name ?? 'Presupuesto', overflow: TextOverflow.ellipsis),
                Text(monthName, style: Theme.of(context).textTheme.bodySmall),
              ]),
              actions: [
                if (category != null)
                  IconButton(
                    tooltip: 'Editar presupuesto',
                    icon: const Icon(Icons.tune),
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => BudgetEditorScreen(repository: widget.repository, category: category, month: widget.month))),
                  ),
              ],
            ),
            body: calc == null || category == null
                ? const Center(child: Text('Este presupuesto ya no existe.'))
                : _content(context, calc, category, monthName),
          );
        },
      );

  Widget _content(BuildContext context, FinanceCalculator calc, Category category, String monthName) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final item = calc.budgetProgress(widget.month).where((b) => b.category.id == category.id).firstOrNull ??
        BudgetProgress(category: category, limitMinor: 0, spentMinor: 0);
    final contributions = calc.budgetContributions(category.id, widget.month);
    final counted = contributions.fold(0, (sum, c) => sum + c.countedMinor);
    final covered = contributions.fold(0, (sum, c) => sum + c.reservedMinor);
    final days = <DateTime, List<BudgetContribution>>{};
    for (final c in contributions) {
      final local = c.transaction.date.toLocal();
      (days[DateTime(local.year, local.month, local.day)] ??= []).add(c);
    }
    final over = item.limitMinor > 0 && item.spentMinor > item.limitMinor;
    final color = over ? pulso.expense : (item.fraction >= 0.85 ? pulso.warning : colorFromHex(category.colorHex));
    final dayTitle = DateFormat("EEEE d 'de' MMMM", 'es');

    return ListView(padding: const EdgeInsets.fromLTRB(16, 8, 16, 32), children: [
      Card(
        child: Padding(
          padding: const EdgeInsets.all(16),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Expanded(child: _Figure(label: 'Límite', value: item.limitMinor > 0 ? money(item.limitMinor) : 'Sin límite')),
              Expanded(child: _Figure(label: 'Consumido', value: money(item.spentMinor))),
              Expanded(
                child: _Figure(
                  label: over ? 'Exceso' : 'Restante',
                  value: item.limitMinor > 0 ? money(item.availableMinor.abs()) : '—',
                  color: over ? pulso.expense : null,
                ),
              ),
            ]),
            if (item.limitMinor > 0) ...[
              const SizedBox(height: 12),
              ClipRRect(
                borderRadius: BorderRadius.circular(5),
                child: LinearProgressIndicator(value: item.fraction.clamp(0.0, 1.0), minHeight: 8, color: color, backgroundColor: pulso.tertiary),
              ),
            ],
            // What changes the limit is not spending of this month: said apart.
            if (item.carriedInMinor > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('El límite incluye ${money(item.carriedInMinor)} que sobraron del mes anterior (límite del mes: ${money(item.limitMinor - item.carriedInMinor)}).',
                    style: TextStyle(fontSize: 12, color: hint)),
              ),
            if (covered > 0)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: Text('Pagado con reservas: ${money(covered)}. Ya estaba apartado y no consume este presupuesto.', style: TextStyle(fontSize: 12, color: hint)),
              ),
          ]),
        ),
      ),
      if (contributions.isEmpty)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 40, horizontal: 16),
          child: Column(children: [
            Icon(Icons.receipt_long_outlined, size: 40, color: hint),
            const SizedBox(height: 10),
            Text('Sin gastos de ${category.name} en ${monthName.toLowerCase()}', textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w600)),
            const SizedBox(height: 4),
            Text('Aquí aparecerán los gastos de esta categoría de este mes, de cualquiera de tus cuentas.', textAlign: TextAlign.center, style: TextStyle(color: hint)),
          ]),
        )
      else ...[
        for (final MapEntry(key: day, value: items) in days.entries) ...[
          Padding(
            padding: const EdgeInsets.fromLTRB(4, 16, 4, 6),
            child: Row(children: [
              Expanded(
                child: Semantics(
                  header: true,
                  child: Text(toBeginningOfSentenceCase(dayTitle.format(day)), style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
                ),
              ),
              Text(money(items.fold(0, (sum, c) => sum + c.countedMinor)), style: TextStyle(fontSize: 13, color: hint, fontWeight: FontWeight.w600)),
            ]),
          ),
          Card(
            child: Column(children: [
              for (final c in items) _ContributionRow(contribution: c, data: calc.data, repository: widget.repository),
            ]),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 16, 4, 0),
          child: Row(children: [
            Expanded(
                child: Text(contributions.length == 1 ? '1 movimiento' : '${contributions.length} movimientos',
                    style: TextStyle(color: hint, fontWeight: FontWeight.w600))),
            Text('Suma: ${money(counted)}', style: const TextStyle(fontWeight: FontWeight.w700)),
          ]),
        ),
      ],
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
        child: Text('Cuentan los gastos y comisiones de esta categoría con fecha en este mes, de todas tus cuentas. Las transferencias entre tus cuentas no consumen presupuesto.',
            style: TextStyle(fontSize: 12, color: hint)),
      ),
    ]);
  }
}

class _Figure extends StatelessWidget {
  const _Figure({required this.label, required this.value, this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
        FittedBox(
          fit: BoxFit.scaleDown,
          alignment: Alignment.centerLeft,
          child: Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w800, color: color)),
        ),
      ]);
}

/// A movement in the budget: concept, account and what it consumes; a payment partly made with a reserve also shows
/// its whole amount. Tapping opens the movement's detail.
class _ContributionRow extends StatelessWidget {
  const _ContributionRow({required this.contribution, required this.data, required this.repository});
  final BudgetContribution contribution;
  final Finances data;
  final FinanceRepository repository;

  @override
  Widget build(BuildContext context) {
    final t = contribution.transaction;
    final hint = Theme.of(context).hintColor;
    final fund = data.reservedFunds.where((f) => f.id == t.reservedFundId).firstOrNull;
    final account = data.account(t.sourceAccountId)?.name ?? 'Sin cuenta';
    return ListTile(
      onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: repository, transactionId: t.id))),
      title: Text(bankTitle(t.descriptionText, isBanking: t.isBanking), maxLines: 2, overflow: TextOverflow.ellipsis),
      subtitle: Text([
        account,
        if (contribution.isPartial)
          contribution.countedMinor == 0
              ? 'Total ${money(contribution.totalMinor)}, pagado con «${fund?.name ?? 'una reserva'}»'
              : 'Total ${money(contribution.totalMinor)}, ${money(contribution.reservedMinor)} con «${fund?.name ?? 'una reserva'}»',
      ].join(' · ')),
      trailing: Text(money(contribution.countedMinor),
          style: TextStyle(fontWeight: FontWeight.w700, color: contribution.countedMinor == 0 ? hint : Pulso.of(context).expense)),
    );
  }
}
