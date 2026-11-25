// «Pídeme algo»: Don Bigotes' conversation (phase 1, rules on this device). Each answer is a card: a question with
// options, a prepared operation (Confirmar · Corregir · Cancelar), a query result or a pointer to the screen that
// does it. The forms stay where they were; «Corregir» opens them already filled in.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../assistant.dart';
import '../data.dart';
import '../finance.dart';
import '../presentation.dart';
import '../theme.dart';
import 'accounts.dart' show ReserveFormScreen;
import 'forecast_screen.dart';
import 'installments_screen.dart';
import 'learning.dart' show proposeCategory;
import 'shell.dart' show DonBigotesMark;
import 'transaction_detail.dart';
import 'transaction_form.dart';

class _Entry {
  _Entry.person(this.text) : reply = null;
  _Entry.reply(this.reply) : text = null;
  final String? text;
  final AssistantReply? reply;
  bool confirmed = false, cancelled = false, undone = false, busy = false;
}

class AssistantScreen extends StatefulWidget {
  const AssistantScreen({super.key, required this.repository, this.clock});
  final FinanceRepository repository;

  /// For tests: the moment taken as «now».
  final DateTime Function()? clock;
  @override
  State<AssistantScreen> createState() => _AssistantScreenState();
}

class _AssistantScreenState extends State<AssistantScreen> {
  late final session = AssistantSession(
    newId: widget.repository.newId,
    propose: (text, type) async => (await proposeCategory(widget.repository, text, type))?.category.id,
  );
  final _input = TextEditingController();
  final _scroll = ScrollController();
  final _entries = <_Entry>[];
  bool _thinking = false;

  DateTime get _now => widget.clock?.call() ?? DateTime.now();
  FinanceCalculator get _calc => FinanceCalculator(widget.repository.finances!);

  @override
  void dispose() {
    _input.dispose();
    _scroll.dispose();
    super.dispose();
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
      _entries.add(_Entry.reply(reply));
      _thinking = false;
    });
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (_scroll.hasClients) _scroll.animateTo(_scroll.position.maxScrollExtent, duration: const Duration(milliseconds: 200), curve: Curves.easeOut);
    });
  }

  void _send() {
    final text = _input.text.trim();
    if (text.isEmpty || widget.repository.finances == null) return;
    _input.clear();
    _run(text, () => session.say(text, _calc, _now));
  }

  Future<void> _confirm(_Entry entry, AssistantPreview preview) async {
    if (entry.confirmed || entry.busy) return;
    final op = session.confirm(preview, widget.repository.finances!);
    setState(() => entry.busy = true);
    try {
      if (op != null) await widget.repository.apply(op);
      if (mounted) setState(() => entry.confirmed = true);
    } catch (error) {
      if (mounted) setState(() => _entries.add(_Entry.reply(AssistantNotUnderstood('No se ha podido guardar: $error. No se ha apuntado nada.'))));
    } finally {
      if (mounted) setState(() => entry.busy = false);
    }
  }

  Future<void> _undo(_Entry entry, AssistantPreview preview) async {
    final op = session.undo(preview, widget.repository.finances!);
    if (op == null) {
      setState(() => _entries.add(_Entry.reply(AssistantNotUnderstood('Ya no se puede deshacer desde aquí: hay pagos hechos con esa reserva.'))));
      return;
    }
    await widget.repository.apply(op);
    if (mounted) setState(() => entry.undone = true);
  }

  void _correct(_Entry entry, AssistantPreview preview) {
    session.cancel();
    setState(() => entry.cancelled = true);
    final page = preview.reserve != null
        ? ReserveFormScreen(
            repository: widget.repository, accountId: preview.reserve!.accountId, name: preview.reserve!.name, amountMinor: preview.reserve!.amountMinor)
        : TransactionFormScreen(repository: widget.repository, prefill: preview.draft);
    Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));
  }

  void _open(IntentKind kind) {
    final page = switch (kind) {
      IntentKind.installments => InstallmentFormScreen(repository: widget.repository) as Widget,
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
        constraints: const BoxConstraints(maxWidth: 520),
        margin: const EdgeInsets.only(bottom: 10),
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: mine ? pulso.accent.withValues(alpha: 0.14) : Theme.of(context).cardColor,
          borderRadius: BorderRadius.circular(Pulso.cardRadius),
        ),
        child: child,
      ),
    );
  }

  Widget _reply(BuildContext context, _Entry entry) {
    final reply = entry.reply!;
    final hint = Theme.of(context).hintColor;
    final pulso = Pulso.of(context);
    final latest = identical(entry, _entries.last);
    switch (reply) {
      case AssistantQuestion():
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(reply.text),
              if (reply.options.isNotEmpty) const SizedBox(height: 8),
              Wrap(spacing: 8, runSpacing: 8, children: [
                for (final (label, value) in reply.options)
                  ActionChip(
                    label: Text(label),
                    onPressed: latest && !_thinking ? () => _run(label, () => session.choose(value, _calc, _now)) : null,
                  ),
              ]),
            ]));
      case AssistantPreview():
        final done = entry.confirmed;
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(done ? (entry.undone ? 'Deshecho' : 'Apuntado') : 'Esto es lo que voy a apuntar:', style: TextStyle(color: hint, fontSize: 12)),
              Text(reply.title, style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
              const SizedBox(height: 6),
              for (final (label, value) in reply.lines)
                Padding(
                  padding: const EdgeInsets.only(bottom: 2),
                  child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    SizedBox(width: 84, child: Text(label, style: TextStyle(color: hint, fontSize: 13))),
                    Expanded(child: Text(value, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w600))),
                  ]),
                ),
              const SizedBox(height: 6),
              for (final e in reply.effects) Text(e, style: TextStyle(fontSize: 12, color: hint)),
              for (final w in reply.warnings)
                Padding(
                  padding: const EdgeInsets.only(top: 4),
                  child: Row(children: [
                    Icon(Icons.warning_amber_rounded, size: 16, color: pulso.warning),
                    const SizedBox(width: 6),
                    Expanded(child: Text(w, style: TextStyle(fontSize: 12, color: pulso.warning))),
                  ]),
                ),
              const SizedBox(height: 8),
              if (entry.cancelled && !done)
                Text('Cancelado: no se ha apuntado nada.', style: TextStyle(color: hint, fontSize: 12))
              else if (!done)
                Wrap(spacing: 8, runSpacing: 8, children: [
                  FilledButton(onPressed: entry.busy ? null : () => _confirm(entry, reply), child: const Text('Confirmar')),
                  OutlinedButton(onPressed: entry.busy ? null : () => _correct(entry, reply), child: const Text('Corregir')),
                  TextButton(
                      onPressed: entry.busy
                          ? null
                          : () {
                              session.cancel();
                              setState(() => entry.cancelled = true);
                            },
                      child: const Text('Cancelar')),
                ])
              else if (!entry.undone)
                Wrap(spacing: 8, children: [
                  if (reply.draft != null)
                    OutlinedButton(
                      onPressed: () {
                        final t = widget.repository.finances!.transactions.where((t) => t.id == reply.id).firstOrNull;
                        if (t != null) {
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: t.id)));
                        }
                      },
                      child: const Text('Ver movimiento'),
                    ),
                  TextButton(onPressed: () => _undo(entry, reply), child: const Text('Deshacer')),
                ]),
            ]));
      case AssistantResult():
        final format = DateFormat('d MMM', 'es');
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              Text(reply.title, style: const TextStyle(fontWeight: FontWeight.w700)),
              for (final l in reply.lines) Text(l),
              for (final t in reply.transactions)
                ListTile(
                  dense: true,
                  contentPadding: EdgeInsets.zero,
                  title: Text(listTitle(t.descriptionText, isBanking: t.isBanking), maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${format.format(t.date)} · ${widget.repository.finances!.account(t.sourceAccountId)?.name ?? ''}'),
                  trailing: Text(money(t.amountMinor)),
                  onTap: () =>
                      Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: t.id))),
                ),
              if (reply.totalMinor != null && reply.transactions.length >= 30) Text('Se muestran los 30 más recientes.', style: TextStyle(fontSize: 12, color: hint)),
            ]));
      case AssistantPointer():
        return _bubble(
            context,
            Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Text(reply.text),
              const SizedBox(height: 8),
              FilledButton.tonal(
                onPressed: () => _open(reply.kind),
                child: Text(switch (reply.kind) {
                  IntentKind.installments => 'Abrir pagos a plazos',
                  IntentKind.simulation => 'Abrir la previsión',
                  _ => 'Abrir el formulario',
                }),
              ),
            ]));
      case AssistantNotUnderstood():
        return _bubble(context, Text(reply.text));
    }
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Scaffold(
      appBar: AppBar(
        title: Row(children: [
          ValueListenableBuilder(
              valueListenable: widget.repository.companionMood, builder: (context, mood, _) => DonBigotesMark(awake: true, mood: mood, size: 32)),
          const SizedBox(width: 10),
          const Text('Pídeme algo', style: TextStyle(fontWeight: FontWeight.w700)),
        ]),
      ),
      body: Column(children: [
        Expanded(
          child: ListView(controller: _scroll, padding: const EdgeInsets.all(16), children: [
            _bubble(
                context,
                Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  const Text('Dime qué quieres apuntar o consultar. Te enseño lo que voy a hacer antes de guardarlo.'),
                  const SizedBox(height: 6),
                  Text('«He gastado 24 € cenando con la tarjeta» · «Reserva 200 € para vacaciones» · «Muéstrame las compras de este mes» · «¿Cuánto he gastado este mes?»',
                      style: TextStyle(fontSize: 12, color: hint)),
                  const SizedBox(height: 6),
                  Text('Lo entiendo en este dispositivo: lo que escribes no sale de él.', style: TextStyle(fontSize: 12, color: hint)),
                ])),
            for (final e in _entries)
              if (e.text != null) _bubble(context, Text(e.text!), mine: true) else _reply(context, e),
            if (_thinking) const Padding(padding: EdgeInsets.all(8), child: LinearProgressIndicator()),
          ]),
        ),
        SafeArea(
          top: false,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(12, 4, 12, 8),
            child: Row(children: [
              Expanded(
                child: TextField(
                  controller: _input,
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
