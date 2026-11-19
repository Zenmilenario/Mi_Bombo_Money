// What may be the same money twice, opened straight from Don Bigotes: each case with both records side by side and
// clear actions (join, keep apart, edit), the result and its effect on the balances before confirming, and the
// recent joins to undo them.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../edits.dart';
import '../models.dart';
import '../presentation.dart';
import '../reconcile.dart';
import '../theme.dart';
import 'transaction_detail.dart';

String _accounts(Transaction t, Finances data) {
  final from = data.account(t.sourceAccountId)?.name ?? 'Cuenta borrada';
  if (t.type != TransactionType.transfer) return from;
  return '$from → ${data.account(t.destinationAccountId)?.name ?? 'Cuenta borrada'}';
}

String _status(Transaction t, Finances data) {
  final sides = bankSides(t, data).map((id) => data.account(id)?.name ?? '').where((n) => n.isNotEmpty).toList();
  return [
    sides.isEmpty ? (t.isBanking ? 'Del banco' : 'Apuntado a mano') : 'Del banco: ${sides.join(' y ')}',
    if (t.isReconciled) 'Conciliado',
    if (t.duplicateState == 'possible') 'Posible duplicado',
    t.type == TransactionType.transfer ? 'Traspaso' : (data.category(t.categoryId)?.name ?? 'Sin categoría'),
  ].join(' · ');
}

int _signed(Transaction t) => switch (t.type) {
      TransactionType.expense || TransactionType.fee => -t.amountMinor,
      TransactionType.income || TransactionType.interest => t.amountMinor,
      TransactionType.transfer => t.amountMinor,
    };

/// One record with what is needed to decide: date, accounts, amount, concept and state.
class RecordRow extends StatelessWidget {
  const RecordRow({super.key, required this.transaction, required this.data, this.onEdit});
  final Transaction transaction;
  final Finances data;
  final VoidCallback? onEdit;

  @override
  Widget build(BuildContext context) {
    final t = transaction;
    final hint = Theme.of(context).hintColor;
    return MergeSemantics(
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Expanded(
            child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(t.descriptionText.isEmpty ? 'Sin concepto' : t.descriptionText, style: const TextStyle(fontWeight: FontWeight.w700)),
              Text('${DateFormat('d MMM yyyy', 'es').format(t.date.toLocal())} · ${_accounts(t, data)}', style: TextStyle(fontSize: 12, color: hint)),
              Text(_status(t, data), style: TextStyle(fontSize: 12, color: hint)),
            ]),
          ),
          const SizedBox(width: 8),
          Column(crossAxisAlignment: CrossAxisAlignment.end, children: [
            Text(money(_signed(t), signed: t.type != TransactionType.transfer), style: const TextStyle(fontWeight: FontWeight.w700)),
            if (onEdit != null) TextButton(onPressed: onEdit, child: const Text('Editar')),
          ]),
        ]),
      ),
    );
  }
}

class ReconcileScreen extends StatelessWidget {
  const ReconcileScreen({super.key, required this.repository, this.duplicatesFirst = false});
  final FinanceRepository repository;

  /// Opened from «movimientos por revisar»: duplicates and categories first; from «traspasos»: transfers first.
  final bool duplicatesFirst;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: repository,
        builder: (context, _) {
          final data = repository.finances;
          if (data == null) return Scaffold(appBar: AppBar(), body: const Center(child: CircularProgressIndicator()));
          final store = ReconcileStore.instance;
          final cases = matchCases(data, keptApart: store.keptApart);
          final transfers =
              cases.where((c) => c.kind == MatchKind.transfer && c.first.duplicateState != 'possible' && c.second.duplicateState != 'possible').toList();
          final duplicates = cases.where((c) => !transfers.contains(c)).toList();
          final wrongCategory =
              data.transactions.where((t) => reviewIssues(t, data.category(t.categoryId)).contains(ReviewIssue.incompatibleCategory)).toList();
          void edit(Transaction t) =>
              Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: repository, transactionId: t.id)));
          Widget section(String title, String help, List<Widget> children) => Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                Padding(
                  padding: const EdgeInsets.fromLTRB(4, 16, 4, 2),
                  child: Semantics(header: true, child: Text(title, style: Theme.of(context).textTheme.titleMedium)),
                ),
                Padding(padding: const EdgeInsets.fromLTRB(4, 0, 4, 8), child: Text(help, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor))),
                ...children,
              ]);
          final transferSection = section('Traspasos entre tus cuentas', 'El cargo de un banco y el abono del otro son un solo traspaso.', [
            for (final c in transfers) _CaseCard(repository: repository, data: data, match: c, onEdit: edit),
          ]);
          final duplicateSection = section('Posibles duplicados', 'Dos registros del mismo apunte: se unen en uno, sin sumar el importe dos veces.', [
            for (final c in duplicates) _CaseCard(repository: repository, data: data, match: c, onEdit: edit),
          ]);
          final categorySection = section('Categoría que no encaja', 'El tipo del movimiento y el de su categoría no coinciden.', [
            for (final t in wrongCategory)
              Card(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: RecordRow(transaction: t, data: data, onEdit: () => edit(t)))),
          ]);
          final payments = reservePaymentCases(data, keptApart: store.keptApart);
          final paymentSection = section('Pagos que pueden salir de una reserva', 'Se parecen a pagos anteriores hechos con esa reserva. Confírmalo o descártalo.', [
            for (final p in payments)
              Card(
                child: Padding(
                  padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    RecordRow(transaction: p.payment, data: data, onEdit: () => edit(p.payment)),
                    Text(
                        p.amountMinor < p.payment.amountMinor
                            ? 'La reserva «${p.fund.name}» cubriría ${money(p.amountMinor)}; el resto seguiría contando como gasto del día a día.'
                            : 'La reserva «${p.fund.name}» lo cubriría entero: dejaría de contar como gasto del día a día.',
                        style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                    Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
                      TextButton(
                        onPressed: () async {
                          await store.keepApartId(p.id);
                          repository.notifyListeners();
                        },
                        child: const Text('No es de la reserva'),
                      ),
                      FilledButton(onPressed: () => repository.apply(payWithReserve(p, DateTime.now())), child: Text('Pagar con «${p.fund.name}»')),
                    ]),
                  ]),
                ),
              ),
          ]);
          final nothing = transfers.isEmpty && duplicates.isEmpty && wrongCategory.isEmpty && payments.isEmpty;
          return Scaffold(
            appBar: AppBar(title: const Text('Revisar y unir', style: TextStyle(fontWeight: FontWeight.w700))),
            body: ListView(padding: EdgeInsets.fromLTRB(16, 0, 16, 24 + MediaQuery.paddingOf(context).bottom), children: [
              if (nothing) const Padding(padding: EdgeInsets.symmetric(vertical: 32), child: Center(child: Text('Nada pendiente: ya está todo resuelto.'))),
              if (duplicatesFirst) ...[
                if (duplicates.isNotEmpty) duplicateSection,
                if (wrongCategory.isNotEmpty) categorySection,
                if (transfers.isNotEmpty) transferSection,
              ] else ...[
                if (transfers.isNotEmpty) transferSection,
                if (duplicates.isNotEmpty) duplicateSection,
                if (wrongCategory.isNotEmpty) categorySection,
              ],
              if (payments.isNotEmpty) paymentSection,
              if (store.history.isNotEmpty) _History(repository: repository, data: data),
            ]),
          );
        },
      );
}

class _CaseCard extends StatelessWidget {
  const _CaseCard({required this.repository, required this.data, required this.match, required this.onEdit});
  final FinanceRepository repository;
  final Finances data;
  final MatchCase match;
  final ValueChanged<Transaction> onEdit;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 6, 12, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            RecordRow(transaction: match.first, data: data, onEdit: () => onEdit(match.first)),
            const Divider(height: 8),
            RecordRow(transaction: match.second, data: data, onEdit: () => onEdit(match.second)),
            Wrap(alignment: WrapAlignment.end, spacing: 8, children: [
              TextButton(
                onPressed: () async {
                  // Different: not proposed again; a possible duplicate stops being one.
                  await ReconcileStore.instance.keepApart(match);
                  final flagged = [match.first, match.second].where((t) => t.duplicateState == 'possible').toList();
                  if (flagged.isNotEmpty) {
                    await repository.apply(batchOperation([for (final t in flagged) notDuplicateOperation(t, DateTime.now())]));
                  } else {
                    repository.notifyListeners();
                  }
                },
                child: const Text('Mantener separados'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context)
                    .push(MaterialPageRoute(builder: (_) => MergePreviewScreen(repository: repository, firstId: match.first.id, secondId: match.second.id))),
                child: Text(match.kind == MatchKind.transfer ? 'Vincular como traspaso' : 'Unir duplicados'),
              ),
            ]),
          ]),
        ),
      );
}

/// Before confirming: the two records, the result and what changes in the balance of each account.
class MergePreviewScreen extends StatefulWidget {
  const MergePreviewScreen({super.key, required this.repository, required this.firstId, required this.secondId});
  final FinanceRepository repository;
  final String firstId, secondId;

  @override
  State<MergePreviewScreen> createState() => _MergePreviewScreenState();
}

class _MergePreviewScreenState extends State<MergePreviewScreen> {
  bool busy = false;

  @override
  Widget build(BuildContext context) {
    final data = widget.repository.finances;
    final a = data?.transactions.where((t) => t.id == widget.firstId).firstOrNull, b = data?.transactions.where((t) => t.id == widget.secondId).firstOrNull;
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    Widget page(List<Widget> children, {Widget? action}) => Scaffold(
          appBar: AppBar(title: const Text('Unir o conciliar', style: TextStyle(fontWeight: FontWeight.w700))),
          body:
              ListView(padding: EdgeInsets.fromLTRB(16, 8, 16, 24 + MediaQuery.paddingOf(context).bottom), children: [...children, if (action != null) action]),
        );
    if (data == null || a == null || b == null) {
      return page(
          [const Padding(padding: EdgeInsets.all(24), child: Text('Uno de los movimientos ya no existe: puede que se haya resuelto en otro dispositivo.'))]);
    }
    final verdict = classify(a, b, data);
    final originals = [
      Text('Registros originales', style: Theme.of(context).textTheme.titleMedium),
      Card(
          child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 12),
              child: Column(children: [RecordRow(transaction: a, data: data), const Divider(height: 8), RecordRow(transaction: b, data: data)]))),
    ];
    if (verdict.kind == null) {
      return page([
        ...originals,
        const SizedBox(height: 8),
        Row(children: [
          Icon(Icons.block, color: pulso.warning),
          const SizedBox(width: 8),
          Expanded(child: Text(verdict.blocked!, style: const TextStyle(fontWeight: FontWeight.w600))),
        ]),
      ]);
    }
    final match = MatchCase(verdict.kind!, a, b);
    final result = joined(match, data, DateTime.now());
    final resultTx = Transaction.fromJson({...?rawFor(result.kept.id), ...result.fields, 'id': result.kept.id});
    final before = effects([a, b]), after = effects([resultTx]);
    final accounts = {...before.keys, ...after.keys};
    return page([
      ...originals,
      const SizedBox(height: 12),
      Text(verdict.kind == MatchKind.transfer ? 'Resultado: un traspaso' : 'Resultado: un solo movimiento', style: Theme.of(context).textTheme.titleMedium),
      Card(child: Padding(padding: const EdgeInsets.symmetric(horizontal: 12), child: RecordRow(transaction: resultTx, data: data))),
      Text('Se conservan las referencias del banco, las notas y los vínculos con reservas y periódicos. Se puede deshacer.',
          style: TextStyle(fontSize: 12, color: hint)),
      const SizedBox(height: 12),
      Text('Efecto en los saldos', style: Theme.of(context).textTheme.titleMedium),
      for (final id in accounts)
        ListTile(
          contentPadding: EdgeInsets.zero,
          dense: true,
          title: Text(data.account(id)?.name ?? 'Cuenta'),
          trailing: Text(() {
            final delta = (after[id] ?? 0) - (before[id] ?? 0);
            return delta == 0 ? 'Sin cambio' : money(delta, signed: true);
          }(), style: const TextStyle(fontWeight: FontWeight.w700)),
        ),
      Text('En las cuentas con saldo comunicado por el banco, ese saldo manda: solo cambian los movimientos posteriores a él.',
          style: TextStyle(fontSize: 12, color: hint)),
    ],
        action: Padding(
          padding: const EdgeInsets.only(top: 16),
          child: FilledButton(
            onPressed: busy
                ? null
                : () async {
                    final document = widget.repository.document;
                    final planned = document == null ? null : joinOperation(match, data, document, DateTime.now());
                    if (planned == null) {
                      setState(() {});
                      return;
                    }
                    setState(() => busy = true);
                    await ReconcileStore.instance.remember(planned.trace);
                    await widget.repository.apply(planned.op);
                    if (context.mounted) Navigator.of(context).pop(true);
                  },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(50)),
            child: Text(verdict.kind == MatchKind.transfer ? 'Vincular como traspaso' : 'Unir'),
          ),
        ));
  }

  Map<String, dynamic>? rawFor(String id) => rawRecord(widget.repository.document, 'transactions', id);
}

/// The joins made on this device, newest first, each with «Deshacer».
class _History extends StatelessWidget {
  const _History({required this.repository, required this.data});
  final FinanceRepository repository;
  final Finances data;

  @override
  Widget build(BuildContext context) {
    final store = ReconcileStore.instance;
    final format = DateFormat("d MMM, HH:mm", 'es');
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Semantics(header: true, child: Text('Uniones recientes en este dispositivo', style: Theme.of(context).textTheme.titleMedium)),
      ),
      for (final trace in store.history.reversed.take(10))
        Card(
          child: ListTile(
            title: Text('${trace.kept['descriptionText'] ?? ''} + ${trace.removed['descriptionText'] ?? ''}', maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text('${trace.kind == MatchKind.transfer ? 'Traspaso' : 'Duplicado'} · ${format.format(trace.at)}'),
            trailing: TextButton(
              onPressed: () async {
                final exists = data.transactions.any((t) => t.id == trace.keptId);
                final back = data.transactions.any((t) => t.id == '${trace.removed['id']}');
                final messenger = ScaffoldMessenger.of(context);
                if (!exists || back) {
                  await store.forget(trace);
                  repository.notifyListeners();
                  messenger.showSnackBar(const SnackBar(content: Text('Ya no se puede deshacer: ese movimiento ha cambiado o se ha borrado.')));
                  return;
                }
                await store.forget(trace);
                await repository.apply(trace.undo(DateTime.now()));
                messenger.showSnackBar(const SnackBar(content: Text('Unión deshecha: los dos movimientos vuelven a estar como antes.')));
              },
              child: const Text('Deshacer'),
            ),
          ),
        ),
    ]);
  }
}
