import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../auto_category.dart';
import '../data.dart';
import '../edits.dart';
import '../finance.dart';
import '../investments.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'learning.dart';
import 'transaction_form.dart';
import 'widgets.dart';
import 'navigation.dart';

/// One movement: what it is, what needs review, and edit or delete.
class TransactionDetailScreen extends StatelessWidget {
  const TransactionDetailScreen({super.key, required this.repository, required this.transactionId});
  final FinanceRepository repository;
  final String transactionId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repository,
      builder: (context, _) {
        final data = repository.finances;
        final t = data?.transactions.where((t) => t.id == transactionId).firstOrNull;
        if (data == null || t == null) {
          return Scaffold(appBar: AppBar(), body: const Center(child: Text('Este movimiento ya no existe.')));
        }
        return _Detail(repository: repository, data: data, t: t);
      },
    );
  }
}

class _Detail extends StatelessWidget {
  const _Detail({required this.repository, required this.data, required this.t});
  final FinanceRepository repository;
  final Finances data;
  final Transaction t;

  Future<void> _delete(BuildContext context) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Borrar movimiento'),
        content: Text([
          t.isBanking
              ? 'Viene de tu banco: si lo borras, volverá a aparecer en la próxima descarga. Si está repetido, es mejor conservarlo y borrar el otro.'
              : 'Se borrará de todos tus dispositivos.',
          if (linkedFee(data, t.id) case final fee?) 'También se borra su comisión de ${money(fee.amountMinor)}.',
        ].join(' ')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (confirmed != true) return;
    // An order goes with its fee: deleting one never leaves the other behind.
    final fee = linkedFee(data, t.id);
    await repository.apply(fee == null ? deleteOperation(t) : batchOperation([deleteOperation(t), deleteOperation(fee)]));
    if (context.mounted) closeOwnScreen(context);
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final category = data.category(t.categoryId);
    final issues = reviewIssues(t, category);
    final source = data.account(t.sourceAccountId);
    final destination = data.account(t.destinationAccountId);
    final similar = issues.contains(ReviewIssue.possibleDuplicate)
        ? duplicateCandidates(
                date: t.date,
                source: t.sourceAccountId,
                destination: t.destinationAccountId,
                type: t.type,
                amountMinor: t.amountMinor,
                description: t.descriptionText,
                existing: data.transactions,
                fingerprints: {for (final x in data.transactions) x.id: x.fingerprint},
                excluding: t.id)
            .take(3)
            .toList()
        : const <DuplicateCandidate>[];
    final tint = category != null ? colorFromHex(category.colorHex) : pulso.accent;
    Widget row(IconData icon, String title, String value) => ListTile(
          leading: Icon(icon, color: tint),
          title: Text(title, style: TextStyle(color: Theme.of(context).hintColor)),
          trailing: ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 200),
            child: Text(value, textAlign: TextAlign.right, style: const TextStyle(fontWeight: FontWeight.w500)),
          ),
        );
    return Scaffold(
      appBar: AppBar(
        title: const Text('Movimiento', style: TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          IconButton(
            tooltip: 'Editar',
            icon: const Icon(Icons.edit_outlined),
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionFormScreen(repository: repository, editing: t))),
          ),
          IconButton(tooltip: 'Borrar', icon: const Icon(Icons.delete_outline), onPressed: () => _delete(context)),
        ],
      ),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        // As on the iPhone: the category's icon, the title, the amount and the kind of movement, centred.
        Card(
          shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Pulso.heroRadius), side: BorderSide(color: pulso.outline)),
          child: Padding(
            padding: const EdgeInsets.all(20),
            child: Column(children: [
              Container(
                width: 56,
                height: 56,
                decoration: BoxDecoration(color: tint.withValues(alpha: 0.12), shape: BoxShape.circle),
                child: Icon(category != null ? symbolIcon(category.systemImage) : (t.type.countsAsIncome ? Icons.south_west : Icons.north_east),
                    color: tint, size: 28),
              ),
              const SizedBox(height: 12),
              Text(listTitle(t.descriptionText, isBanking: t.isBanking),
                  textAlign: TextAlign.center, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              FittedBox(
                fit: BoxFit.scaleDown,
                child: Text(
                    t.type == TransactionType.transfer
                        ? money(t.amountMinor, currency: source?.currencyCode ?? 'EUR')
                        : money(t.type.countsAsIncome ? t.amountMinor : -t.amountMinor, signed: true, currency: source?.currencyCode ?? 'EUR'),
                    style: TextStyle(
                        fontSize: 32,
                        fontWeight: FontWeight.w800,
                        color: t.type.countsAsIncome ? pulso.income : (t.type == TransactionType.transfer ? pulso.savings : pulso.expense))),
              ),
              const SizedBox(height: 8),
              Container(
                padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
                decoration: BoxDecoration(color: Theme.of(context).hintColor.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(20)),
                child: Text(t.type.title, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: Theme.of(context).hintColor)),
              ),
            ]),
          ),
        ),
        if (issues.isNotEmpty) ...[
          const SectionTitle('Por revisar'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final issue in issues)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 6),
                    child: Row(children: [
                      Icon(Icons.error_outline, size: 18, color: pulso.warning),
                      const SizedBox(width: 8),
                      Text(issue.title, style: TextStyle(color: pulso.warning, fontWeight: FontWeight.w600)),
                    ]),
                  ),
                if (issues.contains(ReviewIssue.possibleDuplicate)) ...[
                  const SizedBox(height: 6),
                  Text(similar.isEmpty ? 'Ahora no se encuentra una coincidencia clara con otros movimientos.' : 'Se parece a:'),
                  for (final c in similar) TransactionTile(transaction: c.transaction, data: data),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () => repository.apply(notDuplicateOperation(t, DateTime.now())),
                    icon: const Icon(Icons.check_circle_outline),
                    label: const Text('Conservar: no es un duplicado'),
                  ),
                ],
                if (issues.contains(ReviewIssue.missingCategory) || issues.contains(ReviewIssue.incompatibleCategory)) ...[
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: () async {
                      final chosen = await pickCategory(context, data, [t]);
                      if (chosen == null) return;
                      await recordChoice(repository, t, chosen);
                      await repository.categorize([t], chosen);
                    },
                    icon: const Icon(Icons.sell_outlined),
                    label: const Text('Elegir categoría'),
                  ),
                  LearnedCategoryButton(repository: repository, transaction: t),
                ],
              ]),
            ),
          ),
        ],
        const SectionTitle('Información'),
        Card(
          child: Column(children: [
            row(Icons.calendar_today_outlined, 'Fecha', DateFormat("d 'de' MMMM yyyy, HH:mm", 'es').format(t.date.toLocal())),
            if (destination != null) ...[
              row(Icons.north_east, 'Cuenta de origen', source?.name ?? 'Sin cuenta'),
              row(Icons.south_west, 'Cuenta de destino', destination.name),
              // An order to a portfolio: what is invested, its fee and the total that left the cash, apart.
              if (isContribution(t, data)) ...[
                row(Icons.trending_up, 'Aportado a la inversión', money(t.amountMinor)),
                if (linkedFee(data, t.id) case final fee?) ...[
                  row(Icons.receipt_long_outlined, 'Comisión de la orden', money(fee.amountMinor)),
                  row(Icons.payments_outlined, 'Salida total del efectivo', money(t.amountMinor + fee.amountMinor)),
                ],
              ],
            ] else
              row(Icons.account_balance_outlined, 'Cuenta', source?.name ?? 'Sin cuenta'),
            ListTile(
              leading: Icon(category != null ? symbolIcon(category.systemImage) : Icons.sell_outlined, color: tint),
              title: const Text('Categoría'),
              trailing: Text(category?.name ?? 'Sin categoría', style: const TextStyle(fontWeight: FontWeight.w500)),
              onTap: t.type == TransactionType.transfer
                  ? null
                  : () async {
                      final chosen = await pickCategory(context, data, [t]);
                      if (chosen == null) return;
                      await recordChoice(repository, t, chosen);
                      await repository.categorize([t], chosen);
                    },
            ),
            // An automatic category says where it came from, and can be taken back (it is not assigned again).
            if (AutoCategoryStore.instance.current(t) case final auto?)
              ListTile(
                dense: true,
                leading: const Icon(Icons.auto_awesome_outlined, size: 20),
                title: Text('Asignada automáticamente por ${auto['detail']}'),
                subtitle: const Text('Si no es correcta, elige otra o quítala.'),
                trailing: TextButton(onPressed: () => repository.rejectAutoCategory(t), child: const Text('Quitar')),
              ),
            if (t.isLoanDisbursement)
              row(Icons.account_balance_outlined, 'Tratamiento', 'Dinero de un préstamo: no cuenta como ingreso del día a día'),
            if (t.awaitsBank) row(Icons.hourglass_bottom, 'Estado', 'Pendiente del banco'),
            if (t.isInvestmentFee)
              if (data.transactions.where((o) => o.id.toLowerCase() == t.investmentOperationId?.toLowerCase()).firstOrNull case final order?)
                ListTile(
                  leading: Icon(Icons.trending_up, color: tint),
                  title: const Text('Comisión de la orden'),
                  subtitle: Text('${bankTitle(order.descriptionText, isBanking: order.isBanking)} · ${money(order.amountMinor)} invertidos. No cuenta como gasto del día a día.'),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: repository, transactionId: order.id))),
                ),
            if (t.reservedFundId != null) ...[
              row(Icons.lock_open, 'Pagado con reserva', data.reservedFunds.where((f) => f.id == t.reservedFundId).firstOrNull?.name ?? 'Reserva eliminada'),
              row(Icons.payments_outlined, 'Importe de la reserva', money(t.reservedAmountMinor ?? 0)),
              row(Icons.pie_chart_outline, 'Cuenta para el presupuesto', money(FinanceCalculator.budgetExpenseAmount(t))),
            ],
          ]),
        ),
        if (listTitle(t.descriptionText, isBanking: t.isBanking) != t.descriptionText) ...[
          const SectionTitle('Concepto guardado'),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: SelectableText(t.descriptionText))),
        ],
        if (t.notes.trim().isNotEmpty) ...[
          const SectionTitle('Notas'),
          Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(t.notes))),
        ],
        const SizedBox(height: 12),
        OperationReviewCard(repository: repository, transaction: t),
      ]),
    );
  }
}

/// Category picker for one or several movements: only categories valid for all of them.
Future<Category?> pickCategory(BuildContext context, Finances data, List<Transaction> selected) {
  final options = data.categories.where((c) => !c.isArchived && selected.any((t) => categorySupports(c, t.type))).toList();
  return showModalBottomSheet<Category>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) => SizedBox(
      height: MediaQuery.of(context).size.height * 0.7,
      child: options.isEmpty
          ? const Center(child: Text('No hay categorías para este tipo de movimiento.'))
          : ListView(children: [
              for (final c in options)
                ListTile(
                  leading: RowGlyph(icon: symbolIcon(c.systemImage), tint: colorFromHex(c.colorHex)),
                  title: Text(c.name),
                  onTap: () => Navigator.pop(context, c),
                ),
            ]),
    ),
  );
}
