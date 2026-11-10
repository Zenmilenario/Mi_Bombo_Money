import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../edits.dart';
import '../models.dart';
import '../theme.dart';

/// Reads "12,50", "1.234,56" or "12.5" as cents. Null when it is not an amount.
int? parseAmount(String text) {
  var value = text.trim().replaceAll('€', '').replaceAll(' ', '');
  if (value.isEmpty) return null;
  if (value.contains(',') && value.contains('.')) {
    value = value.lastIndexOf(',') > value.lastIndexOf('.') ? value.replaceAll('.', '').replaceAll(',', '.') : value.replaceAll(',', '');
  } else {
    value = value.replaceAll(',', '.');
  }
  final number = double.tryParse(value);
  if (number == null || number.isNaN || number.isInfinite || number < 0) return null;
  return (number * 100).round();
}

/// New movement or edition of an existing one, with the iPhone's fields and checks.
class TransactionFormScreen extends StatefulWidget {
  const TransactionFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final Transaction? editing;
  @override
  State<TransactionFormScreen> createState() => _TransactionFormScreenState();
}

class _TransactionFormScreenState extends State<TransactionFormScreen> {
  late TransactionDraft draft;
  final _amount = TextEditingController();
  final _description = TextEditingController();
  final _notes = TextEditingController();
  String? _message;
  bool _saving = false;

  Finances get data => widget.repository.finances!;

  @override
  void initState() {
    super.initState();
    final t = widget.editing;
    final accounts = data.accounts.where((a) => !a.isArchived).toList();
    draft = TransactionDraft(
      date: t?.date ?? DateTime.now(),
      type: t?.type ?? TransactionType.expense,
      amountMinor: t?.amountMinor ?? 0,
      description: t?.descriptionText ?? '',
      sourceAccountId: t?.sourceAccountId ?? (accounts.isEmpty ? null : accounts.first.id),
      destinationAccountId: t?.destinationAccountId,
      categoryId: t?.categoryId,
      notes: t?.notes ?? '',
      isReconciled: t?.isReconciled ?? false,
    );
    if (t != null) _amount.text = (t.amountMinor / 100).toStringAsFixed(2).replaceAll('.', ',');
    _description.text = draft.description;
    _notes.text = draft.notes;
  }

  @override
  void dispose() {
    _amount.dispose();
    _description.dispose();
    _notes.dispose();
    super.dispose();
  }

  Future<void> _save() async {
    draft
      ..amountMinor = parseAmount(_amount.text) ?? 0
      ..description = _description.text
      ..notes = _notes.text;
    final problem = draft.validate(data, editing: widget.editing);
    if (problem != null) {
      setState(() => _message = problem);
      return;
    }
    setState(() => _saving = true);
    final op = saveOperation(draft, data, DateTime.now(), editing: widget.editing, newId: widget.repository.newId());
    await widget.repository.apply(op);
    if (mounted) Navigator.of(context).pop(true);
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final accounts = data.accounts.where((a) => !a.isArchived).toList();
    final categories = data.categories.where((c) => categorySupports(c, draft.type)).toList();
    final isBanking = widget.editing?.isBanking ?? false;
    if (draft.categoryId != null && !categories.any((c) => c.id == draft.categoryId)) draft.categoryId = null;
    return Scaffold(
      appBar: AppBar(title: Text(widget.editing == null ? 'Nuevo movimiento' : 'Editar movimiento', style: const TextStyle(fontWeight: FontWeight.w700))),
      body: accounts.isEmpty
          ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('Primero necesitas una cuenta.', textAlign: TextAlign.center)))
          : ListView(padding: const EdgeInsets.all(16), children: [
              if (isBanking)
                Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: Text('Viene de tu banco: si cambias el importe, la fecha o la cuenta, tu versión se conserva en las próximas descargas.',
                      style: TextStyle(color: pulso.warning, fontSize: 13)),
                ),
              SegmentedButton<TransactionType>(
                segments: const [
                  ButtonSegment(value: TransactionType.expense, label: Text('Gasto')),
                  ButtonSegment(value: TransactionType.income, label: Text('Ingreso')),
                  ButtonSegment(value: TransactionType.transfer, label: Text('Traspaso')),
                ],
                selected: {
                  draft.type == TransactionType.fee
                      ? TransactionType.expense
                      : draft.type == TransactionType.interest
                          ? TransactionType.income
                          : draft.type
                },
                onSelectionChanged: (value) => setState(() => draft.type = value.first),
              ),
              if (draft.type == TransactionType.expense ||
                  draft.type == TransactionType.fee ||
                  draft.type == TransactionType.income ||
                  draft.type == TransactionType.interest)
                Wrap(spacing: 8, children: [
                  if (draft.type == TransactionType.expense || draft.type == TransactionType.fee)
                    ChoiceChip(
                        label: const Text('Comisión'),
                        selected: draft.type == TransactionType.fee,
                        onSelected: (on) => setState(() => draft.type = on ? TransactionType.fee : TransactionType.expense)),
                  if (draft.type == TransactionType.income || draft.type == TransactionType.interest)
                    ChoiceChip(
                        label: const Text('Interés'),
                        selected: draft.type == TransactionType.interest,
                        onSelected: (on) => setState(() => draft.type = on ? TransactionType.interest : TransactionType.income)),
                ]),
              const SizedBox(height: 16),
              TextField(
                controller: _amount,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                inputFormatters: [FilteringTextInputFormatter.allow(RegExp(r'[0-9.,]'))],
                decoration: const InputDecoration(labelText: 'Importe (€)', border: OutlineInputBorder()),
                style: const TextStyle(fontSize: 22, fontWeight: FontWeight.w700),
              ),
              const SizedBox(height: 12),
              TextField(
                controller: _description,
                textCapitalization: TextCapitalization.sentences,
                decoration: const InputDecoration(labelText: 'Concepto', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: draft.sourceAccountId,
                isExpanded: true,
                decoration: InputDecoration(labelText: draft.type == TransactionType.transfer ? 'Desde' : 'Cuenta', border: const OutlineInputBorder()),
                items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis))],
                onChanged: (value) => setState(() => draft.sourceAccountId = value),
              ),
              if (draft.type == TransactionType.transfer) ...[
                const SizedBox(height: 12),
                DropdownButtonFormField<String>(
                  initialValue: draft.destinationAccountId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Hacia', border: OutlineInputBorder()),
                  items: [
                    for (final a in accounts.where((a) => a.id != draft.sourceAccountId))
                      DropdownMenuItem(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis))
                  ],
                  onChanged: (value) => setState(() => draft.destinationAccountId = value),
                ),
              ],
              const SizedBox(height: 12),
              DropdownButtonFormField<String?>(
                initialValue: draft.categoryId,
                isExpanded: true,
                decoration: const InputDecoration(labelText: 'Categoría', border: OutlineInputBorder()),
                items: [
                  const DropdownMenuItem<String?>(value: null, child: Text('Sin categoría')),
                  for (final c in categories)
                    DropdownMenuItem<String?>(
                        value: c.id,
                        child: Row(children: [
                          CircleAvatar(radius: 6, backgroundColor: colorFromHex(c.colorHex)),
                          const SizedBox(width: 8),
                          Expanded(child: Text(c.name, overflow: TextOverflow.ellipsis)),
                        ])),
                ],
                onChanged: (value) => setState(() => draft.categoryId = value),
              ),
              const SizedBox(height: 12),
              ListTile(
                contentPadding: EdgeInsets.zero,
                leading: const Icon(Icons.event),
                title: const Text('Fecha'),
                trailing: Text(DateFormat("d 'de' MMMM yyyy", 'es').format(draft.date)),
                onTap: () async {
                  final picked = await showDatePicker(context: context, initialDate: draft.date, firstDate: DateTime(2000), lastDate: DateTime(2100));
                  if (picked != null) {
                    setState(() => draft.date = DateTime(picked.year, picked.month, picked.day, draft.date.hour, draft.date.minute));
                  }
                },
              ),
              TextField(
                controller: _notes,
                maxLines: 3,
                minLines: 1,
                decoration: const InputDecoration(labelText: 'Notas', border: OutlineInputBorder()),
              ),
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Comprobado con el banco'),
                value: draft.isReconciled,
                onChanged: (value) => setState(() => draft.isReconciled = value),
              ),
              if (_message != null) Padding(padding: const EdgeInsets.only(top: 8), child: Text(_message!, style: TextStyle(color: pulso.expense))),
              const SizedBox(height: 16),
              FilledButton(
                onPressed: _saving ? null : _save,
                style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: const Color(0xFF0F766E)),
                child: Text(widget.editing == null ? 'Guardar movimiento' : 'Guardar cambios'),
              ),
              if (widget.editing == null) ...[
                const SizedBox(height: 8),
                Text('Si se parece mucho a otro movimiento, quedará marcado como posible duplicado para que lo revises.',
                    style: Theme.of(context).textTheme.bodySmall),
              ],
            ]),
    );
  }
}
