import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../automation.dart' show matchRule;
import '../data.dart';
import '../learning.dart';
import '../models.dart';
import '../presentation.dart' show listTitle;
import '../theme.dart';

/// "Usar propuesta de IA: …" for a movement without category (Swift review card and form).
class LearnedCategoryButton extends StatefulWidget {
  const LearnedCategoryButton({super.key, required this.repository, required this.transaction});
  final FinanceRepository repository;
  final Transaction transaction;
  @override
  State<LearnedCategoryButton> createState() => _LearnedCategoryButtonState();
}

class _LearnedCategoryButtonState extends State<LearnedCategoryButton> {
  Category? _proposal;
  String? _for;

  Future<void> _load() async {
    final t = widget.transaction;
    final key = '${t.id}|${t.updatedAt.millisecondsSinceEpoch}|${t.categoryId}';
    if (_for == key) return;
    _for = key;
    _proposal = null;
    final learning = widget.repository.learning;
    final data = widget.repository.finances;
    if (learning == null || data == null || t.categoryId != null || t.type == TransactionType.transfer) return;
    if (matchRule(t.descriptionText, t.type, data) != null) return;
    // A movement identified as Round up, Saveback or investment is not given an expense category.
    if (learning.supports(t, data)) {
      final review = await learning.review(t, data);
      final kind = review.confirmed ?? review.prediction?.kind;
      if (kind != null && kind != OperationKind.ordinary) return;
    }
    // The same cleaned concept the model learnt from (as on the iPhone), not the raw bank text.
    final id = await learning.suggestCategory(listTitle(t.descriptionText, isBanking: t.isBanking), t.type, data);
    if (!mounted || _for != key) return;
    setState(() => _proposal = data.category(id));
  }

  @override
  Widget build(BuildContext context) {
    _load();
    final proposal = _proposal;
    if (proposal == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: FilledButton.tonalIcon(
        onPressed: () async {
          await recordChoice(widget.repository, widget.transaction, proposal);
          await widget.repository.categorize([widget.transaction], proposal);
        },
        icon: const Icon(Icons.auto_awesome),
        label: Text('Usar propuesta de IA: ${proposal.name}'),
      ),
    );
  }
}

/// «Reconocimiento de inversión» in a bank movement (Swift `TransactionOperationReviewCard`).
class OperationReviewCard extends StatefulWidget {
  const OperationReviewCard({super.key, required this.repository, required this.transaction});
  final FinanceRepository repository;
  final Transaction transaction;
  @override
  State<OperationReviewCard> createState() => _OperationReviewCardState();
}

class _OperationReviewCardState extends State<OperationReviewCard> {
  OperationReview? _review;
  String? _for;
  String? _error;
  String? _termsMessage;
  final _percent = TextEditingController(text: '1');
  int _multiplier = 1;
  DateTime _from = DateTime.now();
  bool _termsLoaded = false;

  Learning? get learning => widget.repository.learning;
  Finances? get data => widget.repository.finances;

  @override
  void dispose() {
    _percent.dispose();
    super.dispose();
  }

  Future<void> _load({bool force = false}) async {
    final t = widget.transaction;
    final key = '${t.id}|${t.updatedAt.millisecondsSinceEpoch}|${t.type.name}|${t.categoryId}|${t.destinationAccountId}';
    if (!force && _for == key) return;
    _for = key;
    final learning = this.learning, data = this.data;
    if (learning == null || data == null) return;
    if (!_termsLoaded) {
      _termsLoaded = true;
      final terms = learning.terms(t);
      if (terms != null) {
        _percent.text = '${terms.savebackPercent}'.replaceAll('.', ',');
        _multiplier = terms.roundUpMultiplier;
        _from = terms.validFrom;
      } else {
        _from = t.date.isAfter(DateTime.now()) ? DateTime.now() : t.date;
      }
    }
    try {
      final review = await learning.review(t, data);
      if (mounted && _for == key) setState(() => _review = review);
    } catch (_) {
      if (mounted) setState(() => _error = 'No se pudo leer el aprendizaje de este perfil. Tus movimientos se conservan.');
    }
  }

  Future<void> _confirm(OperationKind? kind) async {
    try {
      await learning!.confirmKind(kind, widget.transaction, data!);
      _error = null;
      widget.repository.changed();
      await _load(force: true);
    } catch (_) {
      setState(() => _error = 'No se pudo guardar la identificación.');
    }
  }

  Future<void> _saveTerms() async {
    final percent = double.tryParse(_percent.text.replaceAll(',', '.').trim());
    if (percent == null) {
      setState(() => _error = 'Introduce un porcentaje válido.');
      return;
    }
    final terms = CardTerms(percent, _multiplier, DateTime(_from.year, _from.month, _from.day));
    if (!terms.valid) {
      setState(() => _error = 'El porcentaje debe ser mayor que cero y no superar el 100 %.');
      return;
    }
    try {
      await learning!.saveTerms(terms, widget.transaction, data!);
      setState(() {
        _error = null;
        _termsMessage = 'Condiciones guardadas para esta cuenta.';
      });
      await _load(force: true);
    } catch (_) {
      setState(() => _error = 'No se pudieron guardar las condiciones.');
    }
  }

  Future<void> _undo() async {
    final op = await learning!.undoAutomatic(widget.transaction, data!, DateTime.now());
    if (op == null) {
      setState(() => _error = 'No se pudo deshacer: el movimiento puede haber cambiado. Revísalo a mano.');
      return;
    }
    await widget.repository.apply(op);
  }

  @override
  Widget build(BuildContext context) {
    final learning = this.learning, data = this.data;
    if (learning == null || data == null || !learning.supports(widget.transaction, data)) return const SizedBox.shrink();
    _load();
    final pulso = Pulso.of(context);
    final status = learning.automationStatus(widget.transaction, data);
    final review = _review;
    final confirmed = review?.confirmed;
    final prediction = review?.prediction;
    const caption = TextStyle(fontSize: 12);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(Icons.auto_awesome, color: pulso.accent),
            const SizedBox(width: 8),
            const Expanded(child: Text('Reconocimiento de inversión', style: TextStyle(fontWeight: FontWeight.w700))),
          ]),
          const Text('La IA aprende de lo que confirmas', style: caption),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Aplicar correcciones aprendidas'),
            value: status.enabled,
            onChanged: (v) async {
              await learning.setAutomationEnabled(v);
              widget.repository.changed();
            },
          ),
          Text(
              '${status.savedExamples} ejemplos de correcciones guardados en este perfil. La aplicación automática requiere ejemplos suficientes y aciertos al comprobar periodos posteriores.',
              style: caption),
          if (status.automaticallyApplied) ...[
            const SizedBox(height: 10),
            const Row(children: [
              Icon(Icons.auto_awesome, size: 18),
              SizedBox(width: 6),
              Text('Corregido automáticamente por la IA', style: TextStyle(fontWeight: FontWeight.w600)),
            ]),
            Text('Esta acción había acertado ${status.validatedPredictions} comprobaciones temporales. Revisa el tipo, la categoría y la cuenta de destino.',
                style: caption),
            OutlinedButton(onPressed: _undo, child: const Text('Deshacer corrección y enseñar a la IA')),
          ],
          const SizedBox(height: 10),
          if (confirmed != null) ...[
            Row(children: [
              const Icon(Icons.verified_outlined, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text('Identificado: ${confirmed.title}', style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            Text(confirmed.explanation, style: caption),
          ] else if (prediction != null) ...[
            Row(children: [
              const Icon(Icons.auto_awesome, size: 18),
              const SizedBox(width: 6),
              Expanded(child: Text('Propuesta de IA: ${prediction.kind.title}', style: const TextStyle(fontWeight: FontWeight.w600))),
            ]),
            Text(
                prediction.usesContext
                    ? 'Propuesta por contexto de tus ejemplos confirmados. La fecha y el importe no demuestran por sí solos el tipo de operación.'
                    : 'Propuesta aprendida del concepto. Revisa la información del banco antes de confirmar.',
                style: caption),
            OutlinedButton(onPressed: () => _confirm(prediction.kind), child: const Text('Confirmar identificación')),
          ] else
            const Text('No hay evidencia suficiente para proponer un tipo. Puedes identificarlo consultando el detalle del banco; esa decisión ayuda a aprender.',
                style: caption),
          PopupMenuButton<OperationKind?>(
            onSelected: _confirm,
            itemBuilder: (context) => [
              for (final kind in OperationKind.values) PopupMenuItem(value: kind, child: Text(kind.title)),
              if (confirmed != null) const PopupMenuItem(value: null, child: Text('Retirar esta identificación')),
            ],
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(children: [
                Icon(Icons.sell_outlined, color: pulso.accent),
                const SizedBox(width: 8),
                Text(confirmed == null ? 'Identificar operación' : 'Corregir identificación', style: TextStyle(color: pulso.accent, fontWeight: FontWeight.w600)),
              ]),
            ),
          ),
          const Text(
              'Identificar el beneficio guarda su etiqueta. Corregir el tipo, la categoría o el destino del movimiento también enseña la acción que deseas para futuros apuntes. El aprendizaje se comparte con tus otros dispositivos.',
              style: caption),
          if (confirmed == OperationKind.saveback)
            const Padding(
              padding: EdgeInsets.only(top: 6),
              child: Text('Comprueba el abono de la recompensa, la retención y la inversión neta. Esta etiqueta no crea un ingreso en efectivo ni elimina un cargo bancario.',
                  style: caption),
            ),
          ExpansionTile(
            tilePadding: EdgeInsets.zero,
            title: const Text('Condiciones de los beneficios de esta cuenta'),
            children: [
              TextField(
                controller: _percent,
                keyboardType: const TextInputType.numberWithOptions(decimal: true),
                decoration: const InputDecoration(labelText: 'Saveback bruto (%)', border: OutlineInputBorder()),
              ),
              const SizedBox(height: 8),
              DropdownButtonFormField<int>(
                initialValue: _multiplier,
                decoration: const InputDecoration(labelText: 'Multiplicador de Round up', border: OutlineInputBorder()),
                items: [for (final m in CardTerms.multipliers) DropdownMenuItem(value: m, child: Text('$m×'))],
                onChanged: (v) => setState(() => _multiplier = v ?? 1),
              ),
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Aplicar desde'),
                trailing: Text(DateFormat("d 'de' MMMM yyyy", 'es').format(_from)),
                onTap: () async {
                  final picked = await showDatePicker(context: context, initialDate: _from, firstDate: DateTime(2000), lastDate: DateTime.now());
                  if (picked != null) setState(() => _from = picked);
                },
              ),
              Align(alignment: Alignment.centerLeft, child: OutlinedButton(onPressed: _saveTerms, child: const Text('Guardar condiciones'))),
              const Text(
                  'Indica desde cuándo conoces estas condiciones. El porcentaje es sobre la recompensa bruta; la IA no deduce la retención ni atribuye un cargo solo por coincidir con una fórmula.',
                  style: caption),
              if (_termsMessage != null) Text(_termsMessage!, style: caption),
            ],
          ),
          if (_error != null) Text(_error!, style: TextStyle(color: pulso.expense, fontSize: 13)),
        ]),
      ),
    );
  }
}

/// Swift `rememberEdit` after a form save or a category review: snapshot before, learn after.
Future<void> learnFromEdit(FinanceRepository repository, EditSnapshot? before, String transactionId, {bool categoryConfirmed = false}) async {
  final learning = repository.learning, data = repository.finances;
  if (learning == null || data == null) return;
  final after = data.transactions.where((t) => t.id == transactionId).firstOrNull;
  if (after == null) return;
  if (before != null) await learning.rememberEdit(before, after, data);
  if (categoryConfirmed && after.categoryId != null) await learning.confirmCategories([after], data, recordCorrection: false);
}

/// For the form and the CSV import: the category proposed for a concept and its source ("model" or "brand").
Future<({Category category, String source})?> proposeCategory(FinanceRepository repository, String text, TransactionType type) async {
  final learning = repository.learning, data = repository.finances;
  if (learning == null || data == null || type == TransactionType.transfer) return null;
  final proposal = await learning.categoryProposal(text, type, data);
  final category = data.category(proposal?.categoryId);
  return proposal == null || category == null ? null : (category: category, source: proposal.source);
}

/// Counts a category chosen for a movement without one, against what would have been proposed. Call it before
/// saving the choice: once saved, the model learns it and would always «agree».
Future<void> recordChoice(FinanceRepository repository, Transaction t, Category chosen) async {
  final learning = repository.learning;
  if (learning == null || t.categoryId != null || t.type == TransactionType.transfer) return;
  final proposal = await proposeCategory(repository, listTitle(t.descriptionText, isBanking: t.isBanking), t.type);
  await learning.recordCategoryOutcome(proposedName: proposal?.category.name, source: proposal?.source, chosenName: chosen.name);
}

/// Ajustes → Tus datos → Acierto de la IA: how often the category proposal is accepted, on all the person's devices.
class AiMetricsScreen extends StatelessWidget {
  const AiMetricsScreen({super.key, required this.repository});
  final FinanceRepository repository;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: repository,
        builder: (context, _) {
          final m = repository.learning?.categoryMetrics;
          String share(int part, int whole) => whole == 0 ? '—' : '${(100 * part / whole).round()} %';
          return Scaffold(
            appBar: AppBar(title: const Text('Acierto de la IA', style: TextStyle(fontWeight: FontWeight.w700))),
            body: m == null
                ? const Center(child: Text('Abre tus finanzas para ver las métricas.'))
                : ListView(padding: const EdgeInsets.all(16), children: [
                    const Text('Cuántas veces aceptas la categoría que propone la IA, en todos tus dispositivos. '
                        'Solo se cuentan totales: ningún concepto ni importe.'),
                    const SizedBox(height: 12),
                    Card(
                      child: Column(children: [
                        ListTile(title: const Text('Propuestas aceptadas'), trailing: Text('${m.acceptedTotal} de ${m.proposals} · ${share(m.acceptedTotal, m.proposals)}')),
                        for (final (source, label) in [('model', 'Del modelo'), ('brand', 'Del catálogo de marcas')])
                          ListTile(
                              dense: true,
                              title: Text(label),
                              trailing: Text('${m.accepted[source] ?? 0} aceptadas · ${m.corrected[source] ?? 0} corregidas')),
                        ListTile(title: const Text('Elegidas sin propuesta'), trailing: Text('${m.manual}')),
                      ]),
                    ),
                    if (m.categories.isNotEmpty) ...[
                      const SizedBox(height: 12),
                      Card(
                        child: Column(children: [
                          for (final entry in (m.categories.entries.toList()..sort((a, b) => a.key.compareTo(b.key))))
                            ListTile(
                                dense: true,
                                title: Text(entry.key),
                                trailing: Text('${entry.value.$1} aceptadas · ${entry.value.$2} corregidas')),
                        ]),
                      ),
                    ],
                    const SizedBox(height: 12),
                    OutlinedButton.icon(
                      onPressed: () => FilePicker.saveFile(
                          fileName: 'acierto-ia.csv', bytes: Uint8List.fromList(utf8.encode(m.toCsv())), mimeType: 'text/csv'),
                      icon: const Icon(Icons.download),
                      label: const Text('Exportar en CSV'),
                    ),
                  ]),
          );
        },
      );
}

/// The movements without category that the IA can categorise, with its proposal: the same conditions as the button
/// in the detail (no rule decides it, not a transfer, not an investment operation).
Future<List<({Transaction transaction, Category category, String source})>> reviewProposals(FinanceRepository repository) async {
  final learning = repository.learning, data = repository.finances;
  if (learning == null || data == null) return const [];
  final result = <({Transaction transaction, Category category, String source})>[];
  for (final t in data.transactions) {
    if (t.categoryId != null || t.type == TransactionType.transfer || matchRule(t.descriptionText, t.type, data) != null) continue;
    if (learning.supports(t, data)) {
      final review = await learning.review(t, data);
      final kind = review.confirmed ?? review.prediction?.kind;
      if (kind != null && kind != OperationKind.ordinary) continue;
    }
    final proposal = await proposeCategory(repository, listTitle(t.descriptionText, isBanking: t.isBanking), t.type);
    if (proposal != null) result.add((transaction: t, category: proposal.category, source: proposal.source));
  }
  return result;
}

/// «Por revisar» → Aplicar las propuestas de la IA: check the list and apply the chosen ones at once. Each one also
/// teaches the IA and counts as accepted.
class ReviewProposalsScreen extends StatefulWidget {
  const ReviewProposalsScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  State<ReviewProposalsScreen> createState() => _ReviewProposalsScreenState();
}

class _ReviewProposalsScreenState extends State<ReviewProposalsScreen> {
  List<({Transaction transaction, Category category, String source})>? proposals;
  final selected = <String>{};
  bool busy = false;

  @override
  void initState() {
    super.initState();
    reviewProposals(widget.repository).then((list) {
      if (!mounted) return;
      setState(() {
        proposals = list;
        selected.addAll(list.map((p) => p.transaction.id));
      });
    });
  }

  Future<void> _apply() async {
    final chosen = proposals!.where((p) => selected.contains(p.transaction.id)).toList();
    setState(() => busy = true);
    final learning = widget.repository.learning;
    for (final p in chosen) {
      await learning?.recordCategoryOutcome(proposedName: p.category.name, source: p.source, chosenName: p.category.name);
    }
    final byCategory = <String, List<Transaction>>{};
    for (final p in chosen) {
      byCategory.putIfAbsent(p.category.id, () => []).add(p.transaction);
    }
    for (final entry in byCategory.entries) {
      await widget.repository.categorize(entry.value, chosen.firstWhere((p) => p.category.id == entry.key).category);
    }
    if (mounted) Navigator.of(context).pop(chosen.length);
  }

  @override
  Widget build(BuildContext context) {
    final list = proposals;
    return Scaffold(
      appBar: AppBar(title: const Text('Propuestas de la IA', style: TextStyle(fontWeight: FontWeight.w700))),
      body: list == null
          ? const Center(child: CircularProgressIndicator())
          : list.isEmpty
              ? const Center(child: Padding(padding: EdgeInsets.all(24), child: Text('La IA no tiene propuestas para lo que está por revisar.')))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  const Text('Revisa la lista y quita lo que no quieras. Al aplicarlas, la IA aprende de cada una.'),
                  const SizedBox(height: 8),
                  Card(
                    child: Column(children: [
                      for (final p in list)
                        CheckboxListTile(
                          value: selected.contains(p.transaction.id),
                          onChanged: busy ? null : (v) => setState(() => v == true ? selected.add(p.transaction.id) : selected.remove(p.transaction.id)),
                          title: Text(listTitle(p.transaction.descriptionText, isBanking: p.transaction.isBanking), maxLines: 1, overflow: TextOverflow.ellipsis),
                          subtitle: Text('${p.category.name}${p.source == 'brand' ? ' · por la marca' : ''}'),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  FilledButton(
                    onPressed: busy || selected.isEmpty ? null : _apply,
                    style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
                    child: Text('Aplicar ${selected.length}'),
                  ),
                ]),
    );
  }
}
