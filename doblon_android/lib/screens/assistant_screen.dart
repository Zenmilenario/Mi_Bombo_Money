// «Pídeme algo»: Don Bigotes' conversation (rules on this device). Each answer is a card: a question with options, a
// prepared operation (Confirmar · Corregir · Cancelar), a query result or a pointer to the screen that does it. The
// forms stay where they were; «Corregir» opens them already filled in. Tapping an empty part of the conversation or
// scrolling it hides the keyboard (the text written stays); the field and the last card stay visible above it.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../assistant.dart';
import '../automation.dart' show matchRule;
import '../bank_activity.dart' show spendableHolds;
import '../data.dart';
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

class _Entry {
  _Entry.person(this.text) : reply = null;
  _Entry.reply(this.reply) : text = null;
  final String? text;
  final AssistantReply? reply;
  bool confirmed = false, undone = false, busy = false;

  /// Why a card can no longer be confirmed: cancelled, corrected or set aside.
  String? retired;
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
  void _retireOld(String reason) {
    for (final e in _entries) {
      final r = e.reply;
      if (r is AssistantPreview && !e.confirmed && e.retired == null && !session.isCurrent(r)) e.retired = reason;
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
      _retireOld(reply.note != null ? 'Apartado sin guardar.' : (reply is AssistantPreview ? 'Sustituido por la versión corregida.' : 'Ya no está pendiente.'));
      _entries.add(_Entry.reply(reply));
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
      setState(() => entry.retired = 'Ya no está pendiente.');
      return;
    }
    setState(() => entry.busy = true);
    try {
      await widget.repository.apply(op);
      if (mounted) setState(() => entry.confirmed = true);
      // Only what was confirmed teaches the personal learning (never a draft or a cancelled card), as the form does.
      final draft = preview.draft;
      final category = data.category(draft?.categoryId);
      if (draft != null && category != null && matchRule(draft.description, draft.type, data) == null) {
        await widget.repository.learning?.recordCategoryOutcome(proposedName: preview.proposal?.categoryName, source: preview.proposal?.source, chosenName: category.name);
        await learnFromEdit(widget.repository, null, preview.id, categoryConfirmed: true);
      }
    } catch (error) {
      session.applied.remove(preview.id);
      if (mounted) setState(() => _entries.add(_Entry.reply(AssistantMessage('No se ha podido guardar: $error. No se ha apuntado nada.'))));
    } finally {
      if (mounted) setState(() => entry.busy = false);
    }
  }

  Future<void> _undo(_Entry entry, AssistantPreview preview) async {
    final op = session.undo(preview, widget.repository.finances!, _now);
    if (op == null) {
      setState(() => _entries.add(_Entry.reply(AssistantMessage('Ya no se puede deshacer desde aquí: hay pagos hechos con esa reserva.'))));
      return;
    }
    await widget.repository.apply(op);
    if (mounted) setState(() => entry.undone = true);
  }

  void _cancel(_Entry entry) {
    session.cancel();
    setState(() => entry.retired = 'Cancelado: no se ha guardado nada.');
  }

  void _correct(_Entry entry, AssistantPreview preview) {
    session.cancel();
    setState(() => entry.retired = 'Abierto en el formulario: guárdalo allí.');
    final Widget page = switch (preview.kind) {
      PreviewKind.reserve => ReserveFormScreen(
          repository: widget.repository, accountId: preview.reserve!.accountId, name: preview.reserve!.name, amountMinor: preview.reserve!.amountMinor),
      PreviewKind.plan => InstallmentFormScreen(repository: widget.repository, prefill: preview.plan),
      PreviewKind.movement => TransactionFormScreen(repository: widget.repository, prefill: preview.draft),
      PreviewKind.instalment => InstallmentsScreen(repository: widget.repository),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _open(IntentKind kind) {
    final Widget page = switch (kind) {
      IntentKind.createPlan => InstallmentFormScreen(repository: widget.repository),
      IntentKind.simulation => ForecastScreen(repository: widget.repository),
      _ => TransactionFormScreen(repository: widget.repository),
    };
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  Widget _bubble(BuildContext context, Widget child, {bool mine = false}) {
    final pulso = Pulso.of(context);
    return Align(
      alignment: mine ? Alignment.centerRight : Alignment.centerLeft,
      child: Container(
        constraints: const BoxConstraints(maxWidth: 560),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration:
            BoxDecoration(color: mine ? pulso.accent.withValues(alpha: 0.14) : Theme.of(context).cardColor, borderRadius: BorderRadius.circular(Pulso.cardRadius)),
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
      case AssistantPreview():
        final done = entry.confirmed;
        final format = DateFormat('d MMM yyyy', 'es');
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              ...note,
              Text(done ? (entry.undone ? 'Deshecho' : 'Guardado') : 'Esto es lo que voy a guardar:', style: TextStyle(color: hint, fontSize: 12)),
              Text(reply.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final (label, value) in reply.lines) _line(context, label, value),
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
                  FilledButton(onPressed: entry.busy ? null : () => _confirm(entry, reply), child: const Text('Confirmar')),
                  OutlinedButton(onPressed: entry.busy ? null : () => _correct(entry, reply), child: const Text('Corregir')),
                  TextButton(onPressed: entry.busy ? null : () => _cancel(entry), child: const Text('Cancelar')),
                ])
              else if (!entry.undone)
                Wrap(spacing: 8, children: [
                  if (reply.kind == PreviewKind.movement || reply.kind == PreviewKind.instalment)
                    OutlinedButton(
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: reply.id))),
                      child: const Text('Ver movimiento'),
                    ),
                  if (reply.kind == PreviewKind.plan)
                    OutlinedButton(
                      onPressed: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => InstallmentDetailScreen(repository: widget.repository, planId: reply.id))),
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
              for (final t in reply.transactions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(listTitle(t.descriptionText, isBanking: t.isBanking), maxLines: 2, overflow: TextOverflow.ellipsis),
                  subtitle: Text([format.format(t.date), data.account(t.sourceAccountId)?.name ?? '', if (data.category(t.categoryId) case final c?) c.name].join(' · ')),
                  trailing: Text(money(t.amountMinor)),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: t.id))),
                ),
              if (reply.transactions.length >= 30) Text('Se muestran los 30 más recientes.', style: TextStyle(fontSize: 12, color: hint)),
              if (reply.planId != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () =>
                        Navigator.of(context).push(MaterialPageRoute(builder: (_) => InstallmentDetailScreen(repository: widget.repository, planId: reply.planId!))),
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

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      resizeToAvoidBottomInset: true,
      appBar: AppBar(
        title: Row(children: [
          ValueListenableBuilder(valueListenable: widget.repository.companionMood, builder: (context, mood, _) => DonBigotesMark(awake: true, mood: mood, size: 32)),
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
                          '«He gastado 44,53 en la gasolinera» · «Reserva 200 € para vacaciones» · «4.378 € en 12 meses» · «¿Qué he comprado este mes?» · «¿Cuánto me queda del préstamo?»',
                          style: TextStyle(fontSize: 12, color: hint)),
                      const SizedBox(height: 6),
                      Text(
                          widget.remote == null
                              ? 'Lo entiendo en este dispositivo: lo que escribes no sale de él. Para frases más libres, activa el intérprete en Ajustes.'
                              : 'Con el intérprete activado, la frase y los nombres de tus cuentas, categorías y pagos a plazos se envían a Cloudflare para entenderla; nunca saldos ni movimientos. Nada se guarda sin tu confirmación.',
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
