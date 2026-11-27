// «Pídeme algo»: Don Bigotes' conversation (rules on this device). Each answer is a card: a question with options, a
// prepared operation (Confirmar · Corregir · Cancelar), a query result or a pointer to the screen that does it. The
// forms stay where they were; «Corregir» opens them already filled in. Tapping an empty part of the conversation or
// scrolling it hides the keyboard (the text written stays); the field and the last card stay visible above it.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../assistant.dart';
import '../auto_category.dart' show AutoCategoryStore;
import '../automation.dart' show matchRule;
import '../bank_activity.dart' show spendableHolds;
import '../data.dart';
import '../edits.dart' show categorySupports, rawRecord;
import '../models.dart';
import '../finance.dart';
import '../presentation.dart';
import '../theme.dart';
import 'accounts.dart' show ReserveFormScreen;
import 'forecast_screen.dart';
import 'installments_screen.dart';
import 'learning.dart' show learnFromEdit, proposeCategory;
import 'shell.dart' show DonBigotesMark;
import 'transaction_detail.dart';
import 'transaction_form.dart';

/// Where a prepared operation's card stands, shown on it: only a prepared one can be confirmed.
enum CardState { prepared, parked, cancelled, replaced, outdated, saved }

class _Entry {
  _Entry.person(this.text) : reply = null;
  _Entry.reply(this.reply) : text = null;
  final String? text;
  final AssistantReply? reply;
  bool confirmed = false, undone = false, busy = false;

  /// Why a card can no longer be confirmed (cancelled, corrected, set aside, saved in its form), said on it.
  String? retired;
  CardState state = CardState.prepared;

  /// Open in its form right now: its buttons wait for the person to come back.
  bool inForm = false;

  void retire(CardState why, String text) {
    state = why;
    retired = text;
  }
}

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.repository, this.clock, this.remote});
  final FinanceRepository repository;

  /// Don Bigotes' interpreter on the server, when the person turned it on in Ajustes (null: rules on this device).
  final Future<RemoteInterpretation> Function(Map<String, Object?> context)? remote;

  /// For tests: the moment taken as «now».
  final DateTime Function()? clock;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  late final session = AssistantSession(
    newId: widget.repository.newId,
    propose: (text, type) async {
      final p = await proposeCategory(widget.repository, text, type);
      return p == null ? null : (p.category.id, p.source);
    },
    remote: widget.remote,
    applyEvidence: (ids) => widget.repository.applyAutoCategories(only: ids),
    record: (entity, id) => rawRecord(widget.repository.document, entity, id),
  );
  final _input = TextEditingController();
  final _focus = FocusNode();
  final _scroll = ScrollController();
  final _entries = <_Entry>[];
  bool _thinking = false;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  FinanceCalculator get _calc => FinanceCalculator(widget.repository.finances!);

  /// What the bank holds and has not booked (negative): «Disponible» discounts it, as on Inicio and Cuentas.
  int get _held => spendableHolds(widget.repository.finances!, widget.repository.bankActivity);

  @override
  void initState() {
    super.initState();
    // When the keyboard opens, the last card stays in view.
    _focus.addListener(() {
      if (_focus.hasFocus) Future<void>.delayed(const Duration(milliseconds: 350), _toEnd);
    });
  }

  @override
  void dispose() {
    _input.dispose();
    _focus.dispose();
    _scroll.dispose();
    super.dispose();
  }

  void _toEnd() {
    if (!mounted || !_scroll.hasClients) return;
    _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
  }

  void _hideKeyboard() => FocusScope.of(context).unfocus();

  /// Older cards of a draft that changed (corrected, set aside or cancelled) can no longer be confirmed.
  void _retireOld(CardState why, String reason) {
    for (final e in _entries) {
      final r = e.reply;
      if (r is AssistantPreview && !e.confirmed && e.retired == null && !session.isCurrent(r)) e.retire(why, reason);
    }
  }

  Future<void> _run(String? said, Future<AssistantReply> Function() work) async {
    if (_thinking) return;
    setState(() {
      if (said != null) _entries.add(_Entry.person(said));
      _thinking = true;
    });
    final reply = await work();
    if (!mounted) return;
    setState(() {
      if (reply.note != null) {
        _retireOld(CardState.parked, 'Apartado sin guardar: «Seguir con lo apartado» lo recupera tal cual.');
      } else if (reply is AssistantPreview) {
        _retireOld(CardState.replaced, 'Sustituido por la versión de abajo.');
      } else {
        _retireOld(CardState.outdated, 'Ya no está pendiente.');
      }
      _entries.add(_Entry.reply(reply));
      for (final more in reply.followUps) {
        _entries.add(_Entry.reply(more));
      }
      _thinking = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || widget.repository.finances == null) return;
    _input.clear();
    _run(text, () => session.say(text, _calc, _now, heldMinor: _held));
  }

  Future<void> _confirm(_Entry entry, AssistantPreview preview) async {
    if (entry.confirmed || entry.busy) return;
    final data = widget.repository.finances!;
    final op = session.confirm(preview, data);
    if (op == null) {
      setState(() => entry.retire(CardState.outdated, 'Ya no está pendiente: no se ha guardado otra vez.'));
      return;
    }
    setState(() => entry.busy = true);
    try {
      await widget.repository.apply(op);
      if (mounted) {
        setState(() {
          entry.confirmed = true;
          entry.state = CardState.saved;
        });
      }
      if (preview.kind == PreviewKind.categories) {
        // What really happened to the movements shown: saved now or on their own, and still pending.
        final saved = (op.data['ops'] as List).length + preview.automatic.length;
        final pending = preview.items.length - saved;
        if (mounted) {
          setState(() => _entries.add(_Entry.reply(AssistantMessage(
              'Clasificados: $saved de ${preview.items.length}.${pending > 0 ? ' Siguen pendientes $pending de esta selección.' : ''}'))));
        }
      }
    } catch (error) {
      session.applied.remove(preview.id);
      if (mounted) {
        setState(() {
          entry.busy = false;
          _entries.add(_Entry.reply(AssistantMessage('No se ha podido guardar: $error. No se ha apuntado nada.')));
        });
      }
      return;
    }
    // Saved. What follows only teaches the learning: if it fails, the operation stays saved and is said so.
    try {
      // Confirmed categories count as the person's choices (metrics and learning), as choosing them one by one would.
      final confirmed = {for (final (id, _, _) in preview.assignments) id};
      for (final item in preview.items.where((i) => confirmed.contains(i.transaction.id))) {
        final chosen = data.category(item.categoryId)?.name;
        if (chosen == null) continue;
        await widget.repository.learning
            ?.recordCategoryOutcome(proposedName: data.category(item.proposedId)?.name, source: item.proposedSource, chosenName: chosen);
        await learnFromEdit(widget.repository, null, item.transaction.id, categoryConfirmed: true);
      }
      // Only what was confirmed teaches the personal learning (never a draft or a cancelled card), as the form does.
      final draft = preview.draft;
      final category = data.category(draft?.categoryId);
      if (draft != null && category != null && matchRule(draft.description, draft.type, data) == null) {
        await widget.repository.learning
            ?.recordCategoryOutcome(proposedName: preview.proposal?.categoryName, source: preview.proposal?.source, chosenName: category.name);
        await learnFromEdit(widget.repository, null, preview.targetId ?? preview.id, categoryConfirmed: true);
      }
    } catch (_) {
      // The learning file could not be written now: the operation is saved all the same.
    } finally {
      if (mounted) setState(() => entry.busy = false);
    }
  }

  Future<void> _undo(_Entry entry, AssistantPreview preview) async {
    final op = session.undo(preview, widget.repository.finances!, _now);
    if (op == null) {
      setState(() => _entries.add(_Entry.reply(AssistantMessage('Ya no se puede deshacer desde aquí: algo depende de ello (por ejemplo, pagos hechos con esa reserva).'))));
      return;
    }
    await widget.repository.apply(op);
    if (mounted) setState(() => entry.undone = true);
  }

  /// Takes back the categories assigned from the person's evidence: those movements stay without one and are not
  /// assigned again (as «Quitar» in their detail).
  Future<void> _undoAutomatic(_Entry entry, List<String> ids) async {
    for (final id in ids) {
      final t = widget.repository.finances?.transactions.where((t) => t.id == id).firstOrNull;
      if (t != null && AutoCategoryStore.instance.current(t) != null) await widget.repository.rejectAutoCategory(t);
    }
    if (mounted) setState(() => entry.undone = true);
  }

  void _cancel(_Entry entry, AssistantPreview preview) {
    if (preview.kind == PreviewKind.categories) {
      session.cancelProposals();
    } else {
      session.cancel();
    }
    setState(() => entry.retire(CardState.cancelled, 'Cancelado: no se ha guardado nada.'));
  }

  /// «Corregir»: the same draft opens in its form (same id, so it can never be saved twice). What happened there is
  /// said on return: saved (with the data saved), or closed without saving (the card is still pending here).
  Future<void> _correct(_Entry entry, AssistantPreview preview) async {
    final Widget? page = switch (preview.kind) {
      PreviewKind.reserve => ReserveFormScreen(
          repository: widget.repository,
          accountId: preview.reserve!.accountId,
          name: preview.reserve!.name,
          amountMinor: preview.reserve!.amountMinor,
          newId: preview.id),
      PreviewKind.plan => InstallmentFormScreen(repository: widget.repository, prefill: preview.plan),
      PreviewKind.movement => TransactionFormScreen(repository: widget.repository, prefill: preview.draft, newId: preview.id),
      PreviewKind.instalment => InstallmentsScreen(repository: widget.repository),
      PreviewKind.existing => TransactionDetailScreen(repository: widget.repository, transactionId: preview.targetId!),
      PreviewKind.categories || PreviewKind.delete || PreviewKind.setting || PreviewKind.batch => null,
    };
    if (page == null || entry.inForm) return;
    final target = preview.targetId;
    final before = target == null ? null : widget.repository.finances?.transactions.where((t) => t.id == target).firstOrNull?.updatedAt;
    setState(() => entry.inForm = true);
    await Navigator.of(context).push<Object?>(MaterialPageRoute(builder: (_) => page));
    if (!mounted) return;
    final data = widget.repository.finances!;
    // Saved there: the record with the draft's id exists now (or the movement shown was changed in its detail).
    final saved = switch (preview.kind) {
      PreviewKind.existing => data.transactions.where((t) => t.id == target).firstOrNull?.updatedAt != before,
      PreviewKind.reserve => data.reservedFunds.any((f) => f.id == preview.id),
      PreviewKind.plan => data.installmentPlans.any((p) => p.id == preview.id),
      _ => data.transactions.any((t) => t.id == preview.id),
    };
    setState(() {
      entry.inForm = false;
      if (!saved) {
        _entries.add(_Entry.reply(AssistantMessage(session.isCurrent(preview)
            ? 'Has cerrado el formulario sin guardar: no se ha apuntado nada y la tarjeta sigue pendiente aquí.'
            : 'Has cerrado el formulario sin guardar: no se ha apuntado nada.')));
        return;
      }
      session.savedElsewhere(preview);
      entry.retire(CardState.saved, 'Guardado desde el formulario.');
      final record = data.transactions.where((t) => t.id == (preview.kind == PreviewKind.existing ? target : preview.id)).firstOrNull;
      _entries.add(_Entry.reply(record == null
          ? AssistantMessage('Guardado desde el formulario.')
          : AssistantResult('Guardado desde el formulario', [
              [
                record.type.countsAsIncome ? 'Ingreso' : (record.type == TransactionType.transfer ? 'Traspaso' : 'Gasto'),
                money(record.amountMinor),
                data.account(record.sourceAccountId)?.name ?? '',
                data.category(record.categoryId)?.name ?? 'Sin categoría',
              ].where((p) => p.isNotEmpty).join(' · '),
            ], transactions: [record])));
    });
    WidgetsBinding.instance.addPostFrameCallback((_) => _toEnd());
  }

  void _open(IntentKind kind) {
    final Widget page = switch (kind) {
      IntentKind.createPlan => InstallmentFormScreen(repository: widget.repository),
      IntentKind.simulation => ForecastScreen(repository: widget.repository),
      _ => TransactionFormScreen(repository: widget.repository),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  /// Prepared, in the form, set aside, cancelled, replaced or saved: said on the card, never inferred from its place.
  Widget _stateLabel(BuildContext context, _Entry entry) {
    final pulso = Pulso.of(context);
    final (IconData icon, String text, Color color) = entry.undone
        ? (Icons.undo, 'Deshecho', Theme.of(context).hintColor)
        : entry.confirmed || entry.state == CardState.saved
            ? (Icons.check_circle_outline, 'Guardado', pulso.income)
            : entry.inForm
                ? (Icons.edit_note, 'En el formulario', pulso.accent)
                : switch (entry.state) {
                    CardState.prepared => (Icons.pending_outlined, 'Preparado · sin guardar', pulso.accent),
                    CardState.parked => (Icons.pause_circle_outline, 'Apartado', Theme.of(context).hintColor),
                    CardState.cancelled => (Icons.cancel_outlined, 'Cancelado', Theme.of(context).hintColor),
                    CardState.replaced => (Icons.swap_vert, 'Sustituido', Theme.of(context).hintColor),
                    CardState.outdated => (Icons.block, 'Ya no aplica', Theme.of(context).hintColor),
                    CardState.saved => (Icons.check_circle_outline, 'Guardado', pulso.income),
                  };
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Row(children: [
        Icon(icon, size: 14, color: color),
        const SizedBox(width: 4),
        Flexible(child: Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color))),
      ]),
    );
  }

  Widget _bubble(BuildContext context, Widget child, {bool mine = false, bool dimmed = false}) {
    final pulso = Pulso.of(context);
    if (dimmed) child = Opacity(opacity: 0.6, child: child);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
            color: mine ? pulso.accent.withValues(alpha: 0.14) : Theme.of(context).cardColor, borderRadius: BorderRadius.circular(Pulso.cardRadius)),
        child: child,
      ),
    );
  }

  /// «Label: value», wrapping as one text (readable with a large text size).
  Widget _line(BuildContext context, String label, String value) => Padding(
        padding: const EdgeInsets.only(bottom: 2),
        child: Text.rich(TextSpan(children: [
          TextSpan(text: '$label: ', style: TextStyle(color: Theme.of(context).hintColor)),
          TextSpan(text: value, style: const TextStyle(fontWeight: FontWeight.w600)),
        ])),
      );

  Widget _reply(BuildContext context, _Entry entry) {
    final reply = entry.reply!;
    final hint = Theme.of(context).hintColor;
    final pulso = Pulso.of(context);
    final latest = identical(entry, _entries.last);
    final note = <Widget>[
      if (reply.note != null) Padding(padding: const EdgeInsets.only(bottom: 6), child: Text(reply.note!, style: TextStyle(fontSize: 12, color: hint))),
      // What was set aside comes back with a tap (or by saying so), with everything it had.
      if (reply.canResume && latest && session.hasParked)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            onPressed: _thinking ? null : () => _run('Seguir con lo apartado', () => session.resume(_calc, _now, heldMinor: _held)),
            icon: const Icon(Icons.undo, size: 18),
            label: const Text('Seguir con lo apartado'),
          ),
        ),
    ];
    switch (reply) {
      case AssistantQuestion():
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ...note,
              Text(reply.text),
              if (reply.options.isNotEmpty) const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, value) in reply.options)
                  ActionChip(
                    label: Text(label),
                    onPressed: latest && !_thinking ? () => _run(label, () => session.choose(value, _calc, _now, heldMinor: _held)) : null,
                  ),
              ]),
            ]));
      case AssistantPreview() when reply.kind == PreviewKind.categories:
        return _categoriesCard(context, entry, reply, note);
      case AssistantPreview():
        final done = entry.confirmed;
        final format = DateFormat('d MMM yyyy', 'es');
        return _bubble(
            context,
            dimmed: entry.retired != null && !done || entry.undone,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ...note,
              _stateLabel(context, entry),
              Text(
                  done
                      ? (entry.undone ? 'Deshecho' : (reply.kind == PreviewKind.delete ? 'Borrado' : 'Guardado'))
                      : entry.retired != null
                          ? 'Lo que estaba preparado:'
                          : (reply.kind == PreviewKind.delete ? 'Esto es lo que voy a borrar:' : 'Esto es lo que voy a guardar:'),
                  style: TextStyle(color: hint, fontSize: 12)),
              Text(reply.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final (label, value) in reply.lines) _line(context, label, value),
              for (final part in reply.parts) ...[
                const SizedBox(height: 8),
                Text(part.title, style: const TextStyle(fontWeight: FontWeight.w700)),
                for (final (label, value) in part.lines) _line(context, label, value),
              ],
              if (reply.calendar.isNotEmpty)
                ExpansionTile(
                  tilePadding: EdgeInsets.zero,
                  title: Text('Calendario (${reply.calendar.length} cuotas)', style: const TextStyle(fontSize: 14)),
                  children: [
                    for (final (i, (date, amount)) in reply.calendar.indexed)
                      Row(children: [
                        SizedBox(width: 36, child: Text('${i + 1}.')),
                        Expanded(child: Text(format.format(date))),
                        Text(money(amount)),
                      ]),
                  ],
                ),
              const SizedBox(height: 6),
              for (final e in reply.effects) Text(e, style: TextStyle(fontSize: 12, color: hint)),
              for (final w in reply.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Icon(Icons.warning_amber_rounded, size: 16, color: pulso.warning),
                    const SizedBox(width: 6),
                    Expanded(child: Text(w, style: TextStyle(fontSize: 12, color: pulso.warning))),
                  ]),
                ),
              const SizedBox(height: 8),
              if (entry.retired != null && !done)
                Text(entry.retired!, style: TextStyle(color: hint, fontSize: 12))
              else if (!done)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton(onPressed: entry.busy || entry.inForm ? null : () => _confirm(entry, reply), child: const Text('Confirmar')),
                  if (reply.kind != PreviewKind.categories && reply.kind != PreviewKind.batch && reply.kind != PreviewKind.setting && reply.kind != PreviewKind.delete)
                    OutlinedButton(onPressed: entry.busy || entry.inForm ? null : () => _correct(entry, reply), child: const Text('Corregir')),
                  TextButton(onPressed: entry.busy || entry.inForm ? null : () => _cancel(entry, reply), child: const Text('Cancelar')),
                ])
              else if (!entry.undone)
                Wrap(spacing: 8, children: [
                  if (reply.kind == PreviewKind.movement || reply.kind == PreviewKind.instalment || reply.kind == PreviewKind.existing)
                    OutlinedButton(
                      onPressed: () => Navigator.of(context).push(
                          MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: reply.targetId ?? reply.id))),
                      child: const Text('Ver movimiento'),
                    ),
                  if (reply.kind == PreviewKind.plan)
                    OutlinedButton(
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => InstallmentDetailScreen(repository: widget.repository, planId: reply.id))),
                      child: const Text('Ver el plan'),
                    ),
                  TextButton(onPressed: () => _undo(entry, reply), child: const Text('Deshacer')),
                ]),
            ]));
      case AssistantResult():
        final format = DateFormat('d MMM', 'es');
        final data = widget.repository.finances!;
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ...note,
              Text(reply.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              for (final l in reply.lines) Text(l),
              // Its own Material: the tap's ink shows over the card's colour.
              for (final t in reply.transactions)
                Material(
                  type: MaterialType.transparency,
                  child: ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(listTitle(t.descriptionText, isBanking: t.isBanking), maxLines: 2, overflow: TextOverflow.ellipsis),
                    subtitle: Text([format.format(t.date), data.account(t.sourceAccountId)?.name ?? '', if (data.category(t.categoryId) case final c?) c.name]
                        .join(' · ')),
                    trailing: Text(money(t.amountMinor)),
                    onTap: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: t.id))),
                  ),
                ),
              if (reply.transactions.length >= 30) Text('Se muestran los 30 más recientes.', style: TextStyle(fontSize: 12, color: hint)),
              if (reply.automatic.isNotEmpty)
                Align(
                  alignment: Alignment.centerLeft,
                  child: entry.undone
                      ? Text('Categorías automáticas deshechas.', style: TextStyle(fontSize: 12, color: hint))
                      : TextButton(onPressed: () => _undoAutomatic(entry, reply.automatic), child: Text('Deshacer las ${reply.automatic.length} automáticas')),
                ),
              if (reply.planId != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () => Navigator.of(context)
                        .push(MaterialPageRoute(builder: (_) => InstallmentDetailScreen(repository: widget.repository, planId: reply.planId!))),
                    child: const Text('Ver el plan'),
                  ),
                ),
            ]));
      case AssistantPointer():
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              ...note,
              Text(reply.text),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => _open(reply.kind),
                child: Text(switch (reply.kind) {
                  IntentKind.createPlan => 'Abrir pagos a plazos',
                  IntentKind.simulation => 'Abrir la previsión',
                  _ => 'Abrir el formulario',
                }),
              ),
            ]));
      case AssistantMessage():
        return _bubble(context, Column(crossAxisAlignment: CrossAxisAlignment.start, children: [...note, Text(reply.text)]));
    }
  }

  /// A categorisation: a short line and one compact card per selected movement (concept, date and account, signed
  /// amount, its category, editable, and its state). The bank's full text stays in the movement's detail.
  Widget _categoriesCard(BuildContext context, _Entry entry, AssistantPreview reply, List<Widget> note) {
    final hint = Theme.of(context).hintColor;
    final pulso = Pulso.of(context);
    final data = widget.repository.finances!;
    final format = DateFormat('d MMM', 'es');
    final open = !entry.confirmed && entry.retired == null && session.isCurrent(reply);
    final toSave = reply.assignments.length;
    String state(CategoryItem i) => switch (i.source) {
          'rule' => 'Puesta con tu regla',
          'history' => 'Puesta como la sueles poner',
          'model' || 'brand' => 'Propuesta',
          'person' => 'Elegida por ti',
          _ => 'Dime qué es',
        };
    Widget card(CategoryItem item) {
      final t = item.transaction;
      final income = t.type.countsAsIncome;
      final category = data.category(item.categoryId);
      final editable = open && !item.applied;
      return Container(
        margin: const EdgeInsets.only(top: 8),
        decoration: BoxDecoration(
          color: pulso.tertiary,
          borderRadius: BorderRadius.circular(Pulso.compactRadius),
          border: Border.all(color: pulso.outline),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(Pulso.compactRadius),
            onTap: () => Navigator.of(context)
                .push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: t.id))),
            child: Padding(
              padding: const EdgeInsets.fromLTRB(10, 8, 10, 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Expanded(
                    child: Text(shortConcept(t), maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                  ),
                  const SizedBox(width: 8),
                  Text('${income ? '+' : '−'}${money(t.amountMinor)}',
                      style: TextStyle(fontWeight: FontWeight.w600, color: income ? pulso.income : null)),
                ]),
                Text([format.format(t.date), data.account(t.sourceAccountId)?.name ?? ''].where((p) => p.isNotEmpty).join(' · '),
                    style: TextStyle(fontSize: 12, color: hint)),
                const SizedBox(height: 4),
                Wrap(spacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
                  ActionChip(
                    avatar: Icon(category == null ? Icons.add : Icons.sell_outlined, size: 16),
                    label: Text(category?.name ?? 'Elegir categoría'),
                    onPressed: editable ? () => _pickCategory(reply, item) : null,
                  ),
                  Text(state(item), style: TextStyle(fontSize: 12, color: item.categoryId == null ? pulso.warning : hint)),
                ]),
              ]),
            ),
          ),
        ),
      );
    }

    return _bubble(
        context,
        Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          ...note,
          Text(reply.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          for (final e in reply.effects) Text(e, style: TextStyle(fontSize: 12, color: hint)),
          for (final item in reply.items) card(item),
          const SizedBox(height: 10),
          if (entry.retired != null && !entry.confirmed)
            Text(entry.retired!, style: TextStyle(color: hint, fontSize: 12))
          else if (!entry.confirmed)
            Wrap(spacing: 8, runSpacing: 8, crossAxisAlignment: WrapCrossAlignment.center, children: [
              FilledButton(
                onPressed: entry.busy || toSave == 0 ? null : () => _confirm(entry, reply),
                child: Text(toSave == 0 ? 'Nada que guardar' : 'Guardar $toSave'),
              ),
              TextButton(onPressed: entry.busy ? null : () => _cancel(entry, reply), child: const Text('Cancelar')),
              if (reply.automatic.isNotEmpty && !entry.undone)
                TextButton(onPressed: () => _undoAutomatic(entry, reply.automatic), child: Text('Deshacer ${reply.automatic.length} automática${reply.automatic.length == 1 ? '' : 's'}')),
            ])
          else if (!entry.undone)
            Align(alignment: Alignment.centerLeft, child: TextButton(onPressed: () => _undo(entry, reply), child: const Text('Deshacer'))),
        ]));
  }

  /// The person's categories that fit the movement, to choose one on its card.
  Future<void> _pickCategory(AssistantPreview preview, CategoryItem item) async {
    final data = widget.repository.finances!;
    final options = data.categories.where((c) => !c.isArchived && categorySupports(c, item.transaction.type)).toList()
      ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
    final chosen = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ConstrainedBox(
          constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.7),
          child: ListView(shrinkWrap: true, children: [
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text('Categoría de «${shortConcept(item.transaction)}»', style: const TextStyle(fontWeight: FontWeight.w700)),
            ),
            for (final c in options)
              ListTile(
                title: Text(c.name),
                trailing: c.id == item.categoryId ? const Icon(Icons.check) : null,
                onTap: () => Navigator.of(context).pop(c.id),
              ),
          ]),
        ),
      ),
    );
    if (chosen != null && mounted) setState(() => session.chooseCategory(preview, item.transaction.id, chosen));
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Row(children: [
          ValueListenableBuilder(
              valueListenable: widget.repository.companionMood, builder: (context, mood, _) => DonBigotesMark(awake: true, mood: mood, size: 32)),
          const SizedBox(width: 10),
          const Flexible(child: Text('Pídeme algo', style: TextStyle(fontWeight: FontWeight.w700), overflow: TextOverflow.ellipsis)),
        ]),
      ),
      body: Column(children: [
        Expanded(
          // An empty part of the conversation hides the keyboard; buttons and chips keep their own taps.
          child: GestureDetector(
            behavior: HitTestBehavior.translucent,
            onTap: _hideKeyboard,
            child: ListView(
              controller: _scroll,
              keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
              padding: const EdgeInsets.all(16),
              children: [
                _bubble(
                    context,
                    Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      const Text('Dime qué quieres apuntar o consultar. Antes de guardar nada te enseño lo que voy a hacer.'),
                      const SizedBox(height: 6),
                      Text(
                          '«Ayer pagué la cena, unos 62, y me devolvieron 20 del cine» · «Pasa 300 a la de ahorro» · «Ponme 200 al mes para restaurantes» · «El segundo era de 15» · «¿Qué tengo sin categoría?»',
                          style: TextStyle(fontSize: 12, color: hint)),
                      const SizedBox(height: 6),
                      Text(
                          widget.remote == null
                              ? 'Lo entiendo en este dispositivo: lo que escribes no sale de él. Para frases más libres, activa el intérprete en Ajustes.'
                              : 'Escribe como hablas. Para entenderte, tu frase sale cifrada y sin importes ni nombres de tus cuentas, categorías o movimientos (se cambian por marcadores en el móvil). Nada se guarda sin tu confirmación.',
                          style: TextStyle(fontSize: 12, color: hint)),
                    ])),
                for (final e in _entries)
                  if (e.text != null) _bubble(context, Text(e.text!), mine: true) else _reply(context, e),
                if (_thinking) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
              ],
            ),
          ),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: TextField(
                  controller: _input,
                  focusNode: _focus,
                  minLines: 1,
                  maxLines: 4,
                  textCapitalization: TextCapitalization.sentences,
                  textInputAction: TextInputAction.send,
                  onSubmitted: (_) => _send(),
                  decoration: const InputDecoration(hintText: 'Escribe aquí', border: OutlineInputBorder(), isDense: true),
                ),
              ),
              const SizedBox(width: 8),
              IconButton.filled(tooltip: 'Enviar', onPressed: _send, icon: const Icon(Icons.send)),
            ]),
          ),
        ),
      ]),
    );
  }
}
