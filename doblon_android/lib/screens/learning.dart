import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../automation.dart' show matchRule;
import '../data.dart';
import '../learning.dart';
import '../models.dart';
import '../theme.dart';

/// Ajustes → Inteligencia artificial: what the app has learnt from the person, and the automation switch.
class LearningScreen extends StatelessWidget {
  const LearningScreen({super.key, required this.repository});
  final FinanceRepository repository;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    return ListenableBuilder(
      listenable: repository,
      builder: (context, _) {
        final learning = repository.learning;
        return Scaffold(
          appBar: AppBar(title: const Text('Inteligencia artificial', style: TextStyle(fontWeight: FontWeight.w700))),
          body: learning == null
              ? const Center(child: Text('Abre tus finanzas para ver lo aprendido.'))
              : ListView(padding: const EdgeInsets.all(16), children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(16),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                        Row(children: [
                          Icon(Icons.auto_awesome, color: pulso.accent),
                          const SizedBox(width: 10),
                          const Expanded(child: Text('Aprende de lo que confirmas', style: TextStyle(fontWeight: FontWeight.w700, fontSize: 16))),
                        ]),
                        const SizedBox(height: 10),
                        const Text('Doblón aprende de tus decisiones:\n'
                            '• La categoría que eliges para cada movimiento.\n'
                            '• Si un movimiento del banco es una aportación a inversión, un Round up o un Saveback.\n'
                            '• Las correcciones que haces en movimientos del banco (tipo, categoría y cuenta de destino).\n\n'
                            'Con ello propone categorías y reconoce operaciones. Solo repite una corrección por su cuenta cuando la has hecho varias veces y ha acertado al comprobarla con meses posteriores.\n\n'
                            'Lo aprendido se comparte entre tus dispositivos (iPhone y Android) a través de tu nube privada: solo lo ves tú y no se usa para entrenar ningún modelo ajeno.'),
                      ]),
                    ),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: Column(children: [
                      ListTile(title: const Text('Categorías confirmadas'), trailing: Text('${learning.confirmations.length}')),
                      ListTile(title: const Text('Operaciones identificadas'), trailing: Text('${learning.identifiedOperations}')),
                      ListTile(title: const Text('Correcciones guardadas'), trailing: Text('${learning.savedCorrections}')),
                      ListTile(title: const Text('Correcciones aplicadas por la IA'), trailing: Text('${learning.automaticCorrections}')),
                    ]),
                  ),
                  const SizedBox(height: 12),
                  Card(
                    child: SwitchListTile(
                      title: const Text('Aplicar correcciones aprendidas'),
                      subtitle: const Text('En los movimientos nuevos del banco. Siempre puedes deshacerlas desde el movimiento.'),
                      value: learning.automationEnabled,
                      onChanged: (v) async {
                        await learning.setAutomationEnabled(v);
                        repository.changed();
                        if (v) await repository.applyLearnedCorrections();
                      },
                    ),
                  ),
                ]),
        );
      },
    );
  }
}

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
    final id = await learning.suggestCategory(t.descriptionText, t.type, data);
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
        onPressed: () => widget.repository.categorize([widget.transaction], proposal),
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

/// For the form: the category the model proposes for a concept.
Future<Category?> proposeCategory(FinanceRepository repository, String text, TransactionType type) async {
  final learning = repository.learning, data = repository.finances;
  if (learning == null || data == null || type == TransactionType.transfer) return null;
  return data.category(await learning.suggestCategory(text, type, data));
}
