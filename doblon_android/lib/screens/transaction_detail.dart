import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../edits.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'learning.dart';
import 'transaction_form.dart';
import 'widgets.dart';

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
        content: Text(t.isBanking
            ? 'Viene de tu banco: si lo borras, volverá a aparecer en la próxima descarga. Si está repetido, es mejor conservarlo y borrar el otro.'
            : 'Se borrará de todos tus dispositivos.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Borrar')),
        ],
      ),
    );
    if (confirmed != true) return;
    await repository.apply(deleteOperation(t));
    if (context.mounted) Navigator.of(context).pop();
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
        Card(
          child: Padding(
            padding: const EdgeInsets.all(18),
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(listTitle(t.descriptionText, isBanking: t.isBanking), style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
              const SizedBox(height: 8),
              Text(
                  t.type == TransactionType.transfer
                      ? money(t.amountMinor, currency: source?.currencyCode ?? 'EUR')
                      : money(t.type.countsAsIncome ? t.amountMinor : -t.amountMinor, signed: true, currency: source?.currencyCode ?? 'EUR'),
                  style: TextStyle(
                      fontSize: 28,
                      fontWeight: FontWeight.w800,
                      color: t.type.countsAsIncome ? pulso.income : (t.type == TransactionType.transfer ? pulso.savings : pulso.expense))),
              const SizedBox(height: 4),
              Text('${t.type.title} · ${DateFormat("d 'de' MMMM yyyy", 'es').format(t.date)}'),
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
                      if (chosen != null) await repository.categorize([t], chosen);
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
        const SectionTitle('Detalles'),
        Card(
          child: Column(children: [
            ListTile(title: const Text('Cuenta'), trailing: Text(source?.name ?? '—')),
            if (destination != null) ListTile(title: const Text('Hacia'), trailing: Text(destination.name)),
            ListTile(
              title: const Text('Categoría'),
              trailing: Text(category?.name ?? 'Sin categoría'),
              onTap: t.type == TransactionType.transfer
                  ? null
                  : () async {
                      final chosen = await pickCategory(context, data, [t]);
                      if (chosen != null) await repository.categorize([t], chosen);
                    },
            ),
            if (t.notes.isNotEmpty) ListTile(title: const Text('Notas'), subtitle: Text(t.notes)),
            if (t.awaitsBank) ListTile(title: const Text('Estado'), trailing: Text('Pendiente del banco', style: TextStyle(color: pulso.warning))),
            if (t.isBanking) ListTile(title: const Text('Concepto del banco'), subtitle: Text(t.descriptionText)),
            if (t.reservedFundId != null) ListTile(title: const Text('Pagado con dinero reservado'), trailing: Text(money(t.reservedAmountMinor ?? 0))),
          ]),
        ),
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
                  leading: CircleAvatar(radius: 8, backgroundColor: colorFromHex(c.colorHex)),
                  title: Text(c.name),
                  onTap: () => Navigator.pop(context, c),
                ),
            ]),
    ),
  );
}
