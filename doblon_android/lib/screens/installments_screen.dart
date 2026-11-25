// Pagos a plazos (25 November 2026): the list, the simple sign-up with the calendar seen before saving, and each
// plan's detail (summary, what it counts as, calendar, payments, bank charges to confirm and calendar adjustments).
// Nothing is assumed: the first due date, the interest and whether the purchase is recorded come from the person.
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../banking.dart' show referenceSeconds;
import '../data.dart';
import '../edits.dart';
import '../installments.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'forms.dart';
import 'navigation.dart';
import 'widgets.dart';

final _day = DateFormat("d MMM yyyy", 'es');

void _open(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

IconData _kindIcon(InstallmentKind kind) => switch (kind) {
      InstallmentKind.purchase => Icons.shopping_bag_outlined,
      InstallmentKind.loan => Icons.account_balance_outlined,
      InstallmentKind.other => Icons.splitscreen_outlined,
    };

InstallmentPlan _copy(InstallmentPlan p, {List<Installment>? schedule, bool? isArchived}) => InstallmentPlan(
      id: p.id,
      name: p.name,
      kind: p.kind,
      totalMinor: p.totalMinor,
      schedule: schedule ?? p.schedule,
      accountId: p.accountId,
      agreedInstallmentMinor: p.agreedInstallmentMinor,
      costsMinor: p.costsMinor,
      alreadyRecorded: p.alreadyRecorded,
      paidBeforeCount: p.paidBeforeCount,
      paidBeforeMinor: p.paidBeforeMinor,
      isArchived: isArchived ?? p.isArchived,
      notes: p.notes,
    );

/// What a plan counts as, in words: separate the calendar from its effect on spending and budgets.
String installmentEffect(InstallmentPlan p) {
  final what = switch (p.kind) {
    InstallmentKind.purchase => 'la compra',
    InstallmentKind.loan => 'el dinero del préstamo',
    InstallmentKind.other => 'el gasto',
  };
  final spending = p.alreadyRecorded
      ? (p.costsMinor > 0
          ? 'Ya tenías apuntado $what: las cuotas lo devuelven y solo cuentan como gasto los intereses y comisiones (${money(p.costsMinor)} repartidos entre las cuotas).'
          : 'Ya tenías apuntado $what: las cuotas lo devuelven y no cuentan otra vez como gasto ni en presupuestos.')
      : 'Cada cuota cuenta como gasto del mes en que la pagas.';
  return '$spending Las cuotas futuras solo aparecen en la previsión: no mueven el saldo hasta pagarlas. No se crea ningún presupuesto.';
}

class InstallmentsScreen extends StatelessWidget {
  const InstallmentsScreen({super.key, required this.repository});
  final FinanceRepository repository;

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: repository,
        builder: (context, _) {
          final data = repository.finances;
          final now = DateTime.now();
          final pulso = Pulso.of(context);
          Widget tile(InstallmentPlan p) {
            final progress = installmentProgress(p, data!, now);
            final next = progress.next;
            final overdue = progress.states.where((s) => s.status == InstallmentStatus.overdue).length;
            return Card(
              child: ListTile(
                leading: RowGlyph(icon: _kindIcon(p.kind), tint: overdue > 0 ? pulso.warning : pulso.accent),
                title: Text(p.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                subtitle: Text([
                  '${progress.paidCount}/${p.count} pagadas',
                  if (next != null) 'próxima ${_day.format(next.installment.dueDate)}' else 'terminado',
                  if (overdue > 0) '$overdue vencida${overdue == 1 ? '' : 's'}',
                ].join(' · ')),
                trailing: Text(money(progress.pendingMinor), style: const TextStyle(fontWeight: FontWeight.w700)),
                onTap: () => _open(context, InstallmentDetailScreen(repository: repository, planId: p.id)),
              ),
            );
          }

          final active = data?.installmentPlans.where((p) => !p.isArchived).toList() ?? const <InstallmentPlan>[];
          final archived = data?.installmentPlans.where((p) => p.isArchived).toList() ?? const <InstallmentPlan>[];
          return Scaffold(
            appBar: AppBar(title: const Text('Pagos a plazos', style: TextStyle(fontWeight: FontWeight.w700))),
            floatingActionButton: data == null
                ? null
                : FloatingActionButton(
                    tooltip: 'Añadir pago a plazos',
                    onPressed: () => _open(context, InstallmentFormScreen(repository: repository)),
                    child: const Icon(Icons.add)),
            body: data == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(padding: const EdgeInsets.all(16), children: [
                    if (active.isEmpty)
                      const Text('Apunta aquí una compra a plazos, un préstamo u otro pago fraccionado: el total, las cuotas y su calendario. '
                          'Cada cuota pagada es un movimiento normal; las futuras solo se prevén.'),
                    for (final p in active) tile(p),
                    if (archived.isNotEmpty) ExpansionTile(title: Text('Archivados (${archived.length})'), children: [for (final p in archived) tile(p)]),
                    const SizedBox(height: 80),
                  ]),
          );
        },
      );
}

// ---------------------------------------------------------------- sign-up and edit

class InstallmentFormScreen extends StatefulWidget {
  const InstallmentFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final InstallmentPlan? editing;
  @override
  State<InstallmentFormScreen> createState() => _InstallmentFormScreenState();
}

class _InstallmentFormScreenState extends State<InstallmentFormScreen> {
  late final InstallmentPlan? e = widget.editing;
  late InstallmentKind? _kind = e?.kind;
  late final _name = TextEditingController(text: e?.name ?? '');
  late final _total = TextEditingController(text: e == null ? '' : amountText(e!.totalMinor));
  late final _count = TextEditingController(text: e == null ? '' : '${e!.count}');
  late final _agreed = TextEditingController(text: e?.agreedInstallmentMinor == null ? '' : amountText(e!.agreedInstallmentMinor!));
  late final _costs = TextEditingController(text: (e?.costsMinor ?? 0) == 0 ? '' : amountText(e!.costsMinor));
  late final _paidBefore = TextEditingController(text: (e?.paidBeforeCount ?? 0) == 0 ? '' : '${e!.paidBeforeCount}');
  late DateTime? _first = e?.schedule.firstOrNull?.dueDate;
  late String? _account = e?.accountId;
  late bool _hasCosts = (e?.costsMinor ?? 0) > 0;
  late bool? _recorded = e?.alreadyRecorded;
  late bool _startedBefore = (e?.paidBeforeCount ?? 0) > 0;
  final _pause = <String>{};
  String? _message;
  bool _saving = false;

  int? get _countValue => int.tryParse(_count.text.trim());

  /// The calendar the fields give, or null while they are incomplete or do not add up.
  List<Installment>? get _schedule {
    final total = amountFrom(_total), count = _countValue, first = _first;
    if (total == null || count == null || first == null) return null;
    final agreed = _agreed.text.trim().isEmpty ? null : amountFrom(_agreed);
    // Editing a plan whose calendar was adjusted, with the same terms: keep that calendar.
    if (e != null && total == e!.totalMinor && count == e!.count && agreed == e!.agreedInstallmentMinor && first == e!.schedule.first.dueDate) {
      return e!.schedule;
    }
    return buildSchedule(total, count, first, agreedMinor: agreed);
  }

  InstallmentPlan? _plan(List<Installment> schedule) {
    final paidBefore = _startedBefore ? (int.tryParse(_paidBefore.text.trim()) ?? 0) : 0;
    return InstallmentPlan(
      id: e?.id ?? widget.repository.newId(),
      name: _name.text.trim(),
      kind: _kind!,
      totalMinor: amountFrom(_total)!,
      schedule: schedule,
      accountId: _account,
      agreedInstallmentMinor: _agreed.text.trim().isEmpty ? null : amountFrom(_agreed),
      costsMinor: _hasCosts ? (amountFrom(_costs) ?? 0) : 0,
      alreadyRecorded: _recorded ?? false,
      paidBeforeCount: paidBefore,
      paidBeforeMinor: schedule.take(paidBefore).fold(0, (sum, i) => sum + i.amountMinor),
      isArchived: e?.isArchived ?? false,
      notes: e?.notes ?? '',
    );
  }

  Future<void> _save() async {
    if (_saving) return;
    final total = amountFrom(_total), count = _countValue;
    String? problem;
    if (_kind == null) {
      problem = 'Elige qué es: compra a plazos, préstamo u otro pago fraccionado.';
    } else if (_name.text.trim().isEmpty) {
      problem = 'Escribe un nombre o concepto.';
    } else if (total == null || total <= 0) {
      problem = 'Escribe el importe total pendiente.';
    } else if (count == null || count < 1 || count > 600) {
      problem = 'Escribe el número de cuotas (de 1 a 600).';
    } else if (_first == null) {
      problem = 'Elige la fecha del primer vencimiento.';
    } else if (_account == null) {
      problem = 'Elige la cuenta desde la que se paga.';
    } else if (_agreed.text.trim().isNotEmpty && (amountFrom(_agreed) ?? 0) <= 0) {
      problem = 'La cuota acordada no es un importe válido.';
    } else if (_schedule == null) {
      problem = 'Con esa cuota acordada las cuotas superarían el total.';
    } else if (_hasCosts && ((amountFrom(_costs) ?? -1) < 0 || amountFrom(_costs)! >= total)) {
      problem = 'Los intereses y comisiones deben ser menores que el total.';
    } else if (_recorded == null) {
      problem = 'Indica si ya está apuntado en Doblón.';
    } else if (_startedBefore && ((int.tryParse(_paidBefore.text.trim()) ?? -1) < 1 || int.parse(_paidBefore.text.trim()) >= count)) {
      problem = 'Las cuotas ya pagadas deben ser al menos 1 y menos que el total de cuotas.';
    }
    if (problem != null) return setState(() => _message = problem);
    final plan = _plan(_schedule!)!;
    setState(() => _saving = true);
    final now = DateTime.now();
    final data = widget.repository.finances!;
    final save = savePlanOperation(plan: plan, create: e == null, data: data, now: now);
    final pauses = [
      for (final id in _pause) upsertOperation('recurringMovements', {'id': id, 'isActive': false, 'updatedAt': referenceSeconds(now)}, create: false)
    ];
    try {
      await widget.repository.apply(pauses.isEmpty ? save : batchOperation([save, ...pauses]));
      if (mounted) closeOwnScreen(context);
    } catch (error) {
      if (mounted) setState(() => _message = 'No se ha podido guardar: $error');
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final data = widget.repository.finances!;
    final pulso = Pulso.of(context);
    final accounts = data.accounts.where((a) => !a.isArchived && !a.type.isLiability || a.id == _account).toList();
    final schedule = _schedule;
    final preview = schedule == null || _kind == null || _account == null ? null : _plan(schedule);
    final overlapping = preview == null ? const <RecurringMovement>[] : overlappingRecurring(preview, data);
    final recordedQuestion = switch (_kind) {
      InstallmentKind.loan => '¿Ya apuntaste en Doblón el dinero del préstamo que recibiste?',
      InstallmentKind.other => '¿Ya apuntaste en Doblón el gasto completo?',
      _ => '¿Ya apuntaste en Doblón la compra completa?',
    };
    return AbsorbPointer(
      absorbing: _saving,
      child: FormPage(
        title: e == null ? 'Nuevo pago a plazos' : 'Editar pago a plazos',
        message: _message,
        saveLabel: _saving ? 'Guardando…' : 'Guardar',
        onSave: _saving ? null : _save,
        children: [
          const Text('¿Qué es?', style: TextStyle(fontWeight: FontWeight.w700)),
          Wrap(spacing: 8, runSpacing: 8, children: [
            for (final k in InstallmentKind.values)
              ChoiceChip(avatar: Icon(_kindIcon(k), size: 17), label: Text(k.title), selected: _kind == k, onSelected: (_) => setState(() => _kind = k)),
          ]),
          if (_kind != null) ...[
            TextInput(controller: _name, label: 'Nombre o concepto'),
            _Live(controller: _total, onChanged: () => setState(() {}), child: AmountInput(controller: _total, label: 'Importe total pendiente (€)')),
            _Live(
                controller: _count,
                onChanged: () => setState(() {}),
                child: TextField(
                    controller: _count,
                    keyboardType: TextInputType.number,
                    decoration: const InputDecoration(labelText: 'Número de cuotas', border: OutlineInputBorder()))),
            DateInput(label: 'Primer vencimiento', value: _first, onChanged: (v) => setState(() => _first = v ?? _first)),
            Choice<String?>(
                label: 'Cuenta desde la que se paga',
                value: _account,
                options: {null: 'Elige una', for (final a in accounts) a.id: a.name},
                onChanged: (v) => setState(() => _account = v)),
            _Live(controller: _agreed, onChanged: () => setState(() {}), child: AmountInput(controller: _agreed, label: 'Cuota acordada (opcional, €)')),
            Text('Sin cuota acordada, el total se reparte en cuotas iguales y la última lleva los céntimos que sobren.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Incluye intereses o comisiones'),
                subtitle: const Text('Solo si el total que has escrito ya los incluye: no se suman otra vez.'),
                value: _hasCosts,
                onChanged: (v) => setState(() => _hasCosts = v)),
            if (_hasCosts) AmountInput(controller: _costs, label: 'Parte del total que son intereses y comisiones (€)'),
            Text(recordedQuestion, style: const TextStyle(fontWeight: FontWeight.w600)),
            SegmentedButton<bool>(
              emptySelectionAllowed: true,
              segments: const [ButtonSegment(value: true, label: Text('Sí, ya está')), ButtonSegment(value: false, label: Text('No'))],
              selected: {if (_recorded != null) _recorded!},
              onSelectionChanged: (s) => setState(() => _recorded = s.firstOrNull),
            ),
            if (_recorded != null)
              Text(
                  _recorded!
                      ? 'Las cuotas devolverán lo apuntado: no contarán otra vez como gasto${_hasCosts ? ', salvo su parte de intereses y comisiones' : ''}.'
                      : 'Cada cuota contará como gasto cuando la pagues.',
                  style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: const Text('Empezó antes de usar Doblón'),
                subtitle: const Text('Marca las primeras cuotas como pagadas sin inventar sus movimientos.'),
                value: _startedBefore,
                onChanged: (v) => setState(() => _startedBefore = v)),
            if (_startedBefore)
              _Live(
                  controller: _paidBefore,
                  onChanged: () => setState(() {}),
                  child: TextField(
                      controller: _paidBefore,
                      keyboardType: TextInputType.number,
                      decoration: const InputDecoration(labelText: 'Cuotas ya pagadas', border: OutlineInputBorder()))),
            for (final r in overlapping)
              Material(
                color: pulso.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Pulso.compactRadius),
                child: CheckboxListTile(
                  value: _pause.contains(r.id),
                  onChanged: (v) => setState(() => v == true ? _pause.add(r.id) : _pause.remove(r.id)),
                  title: Text('«${r.name}» parece este mismo pago'),
                  subtitle: Text('${money(r.amountMinor)} · ${r.frequency.title}. Páusalo para no contarlo dos veces en la previsión.'),
                ),
              ),
            if (preview != null) _Calendar(plan: preview),
          ],
        ],
      ),
    );
  }
}

/// Rebuilds the form while a field is typed (the calendar is shown before saving).
class _Live extends StatefulWidget {
  const _Live({required this.controller, required this.onChanged, required this.child});
  final TextEditingController controller;
  final VoidCallback onChanged;
  final Widget child;
  @override
  State<_Live> createState() => _LiveState();
}

class _LiveState extends State<_Live> {
  @override
  void initState() {
    super.initState();
    widget.controller.addListener(widget.onChanged);
  }

  @override
  void dispose() {
    widget.controller.removeListener(widget.onChanged);
    super.dispose();
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

/// The calendar a plan will have, reviewed before saving.
class _Calendar extends StatelessWidget {
  const _Calendar({required this.plan});
  final InstallmentPlan plan;
  @override
  Widget build(BuildContext context) {
    final rows = plan.schedule;
    final shown = rows.length <= 24 ? rows : [...rows.take(12), ...rows.skip(rows.length - 3)];
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
          const Text('Calendario', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
          Text('${rows.length} cuotas · suman ${money(rows.fold(0, (s, i) => s + i.amountMinor))} · última ${_day.format(rows.last.dueDate)}',
              style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
          const SizedBox(height: 8),
          for (final (i, row) in shown.indexed) ...[
            if (rows.length > 24 && i == 12) const Text('…'),
            Row(children: [
              SizedBox(width: 44, child: Text('${rows.indexOf(row) + 1}.')),
              Expanded(child: Text(_day.format(row.dueDate))),
              Text(money(row.amountMinor), style: const TextStyle(fontWeight: FontWeight.w600)),
              if (rows.indexOf(row) < plan.paidBeforeCount) const Padding(padding: EdgeInsets.only(left: 6), child: Icon(Icons.check, size: 16)),
            ]),
          ],
        ]),
      ),
    );
  }
}

// ---------------------------------------------------------------- detail

class InstallmentDetailScreen extends StatelessWidget {
  const InstallmentDetailScreen({super.key, required this.repository, required this.planId, this.number});
  final FinanceRepository repository;
  final String planId;

  /// An instalment to open on arrival (from a note of Don Bigotes).
  final int? number;

  Future<void> _adjust(BuildContext context, InstallmentProgress progress) async {
    final proposal = rescheduled(progress);
    if (proposal == null) return;
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Ajustar el calendario'),
        content: SizedBox(
          width: 360,
          child: ListView(shrinkWrap: true, children: [
            Text('Pendiente: ${money(progress.pendingMinor)}. Así quedarían las cuotas que faltan (mismas fechas):'),
            const SizedBox(height: 8),
            for (final (i, s) in progress.states.indexed)
              if (s.isOpen)
                Row(children: [
                  Expanded(child: Text('${s.number}. ${_day.format(s.installment.dueDate)}')),
                  Text('${money(s.installment.amountMinor)} → ${money(proposal[i].amountMinor)}'),
                ]),
          ]),
        ),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Dejarlo como está')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Aplicar')),
        ],
      ),
    );
    if (ok != true) return;
    await repository.apply(savePlanOperation(plan: _copy(progress.plan, schedule: proposal), create: false, data: repository.finances!, now: DateTime.now()));
  }

  Future<void> _instalment(BuildContext context, InstallmentState s, List<(InstallmentState, Transaction)> charges) async {
    final plan = (repository.finances!.installmentPlans.where((p) => p.id == planId)).first;
    final mine = charges.where((c) => c.$1.number == s.number).toList();
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (sheet) => SafeArea(
        child: ListView(shrinkWrap: true, children: [
          ListTile(
            title: Text('Cuota ${s.number} de ${plan.count}', style: const TextStyle(fontWeight: FontWeight.w700)),
            subtitle: Text('${_day.format(s.installment.dueDate)} · ${money(s.installment.amountMinor)} · ${s.status.title}'),
          ),
          if (s.status == InstallmentStatus.paid) ...[
            ListTile(
              leading: const Icon(Icons.receipt_long_outlined),
              title: Text('Pagada ${_day.format(s.payment!.date)} · ${money(s.payment!.amountMinor)}'),
              subtitle: Text(s.payment!.bankEntryKey != null ? 'Cargo del banco' : 'Apuntada a mano'),
            ),
            ListTile(
              leading: const Icon(Icons.undo),
              title: const Text('Deshacer el pago'),
              subtitle: Text(
                  s.payment!.bankEntryKey != null ? 'El cargo del banco se conserva, solo deja de ser esta cuota.' : 'Se borra el movimiento apuntado a mano.'),
              onTap: () async {
                Navigator.pop(sheet);
                await repository.apply(undoPaymentOperation(s.payment!, DateTime.now()));
              },
            ),
          ],
          if (s.isOpen) ...[
            for (final (_, t) in mine)
              ListTile(
                leading: const Icon(Icons.account_balance_outlined),
                title: Text('Es este cargo del banco: ${money(t.amountMinor)}'),
                subtitle: Text('${_day.format(t.date)} · ${t.descriptionText}'),
                trailing: const Icon(Icons.link),
                onTap: () async {
                  Navigator.pop(sheet);
                  await repository.apply(linkOperation(plan, s.number, t, DateTime.now()));
                },
              ),
            ListTile(
              leading: const Icon(Icons.payments_outlined),
              title: const Text('Registrar el pago'),
              subtitle: const Text('Si después llega el cargo del banco, se propone como este mismo pago.'),
              onTap: () {
                Navigator.pop(sheet);
                _open(context, _PaymentForm(repository: repository, plan: plan, state: s));
              },
            ),
          ],
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: repository,
        builder: (context, _) {
          final data = repository.finances;
          final plan = data?.installmentPlans.where((p) => p.id == planId).firstOrNull;
          if (data == null || plan == null) {
            return Scaffold(appBar: AppBar(), body: const Center(child: Text('Este pago a plazos ya no existe.')));
          }
          final pulso = Pulso.of(context);
          final progress = installmentProgress(plan, data, DateTime.now());
          final charges = compatibleCharges(progress, data);
          final next = progress.next;
          final opening = number == null ? null : progress.states.where((s) => s.number == number && s.status != InstallmentStatus.paidBefore).firstOrNull;
          Widget figure(String label, String value, {Color? color}) => Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                  FittedBox(fit: BoxFit.scaleDown, child: Text(value, style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: color))),
                ]),
              );
          return _OpenOnce(
              onOpen: opening == null ? null : () => _instalment(context, opening, charges),
              child: Scaffold(
                appBar: AppBar(
                  title: Text(plan.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  actions: [
                    IconButton(
                        tooltip: 'Editar',
                        icon: const Icon(Icons.edit_outlined),
                        onPressed: () => _open(context, InstallmentFormScreen(repository: repository, editing: plan))),
                    PopupMenuButton<String>(
                      onSelected: (v) async {
                        if (v == 'archive') {
                          await repository
                              .apply(savePlanOperation(plan: _copy(plan, isArchived: !plan.isArchived), create: false, data: data, now: DateTime.now()));
                        } else if (v == 'delete' &&
                            await confirm(context, 'Borrar pago a plazos', 'Los pagos ya hechos se conservan como movimientos normales.', action: 'Borrar')) {
                          await repository.apply(removePlanOperation(plan, data, DateTime.now()));
                          if (context.mounted) closeOwnScreen(context);
                        }
                      },
                      itemBuilder: (_) => [
                        PopupMenuItem(value: 'archive', child: Text(plan.isArchived ? 'Recuperar' : 'Archivar')),
                        const PopupMenuItem(value: 'delete', child: Text('Borrar')),
                      ],
                    ),
                  ],
                ),
                body: ListView(padding: const EdgeInsets.all(16), children: [
                  Card(
                    child: Padding(
                      padding: const EdgeInsets.all(14),
                      child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                        Text('${plan.kind.title} · ${data.account(plan.accountId)?.name ?? 'sin cuenta'}',
                            style: TextStyle(color: Theme.of(context).hintColor)),
                        const SizedBox(height: 10),
                        Row(children: [
                          figure('Total', money(plan.totalMinor)),
                          figure('Pagado', money(progress.paidMinor), color: pulso.income),
                          figure('Pendiente', money(progress.pendingMinor), color: pulso.expense),
                        ]),
                        const SizedBox(height: 10),
                        ClipRRect(
                          borderRadius: BorderRadius.circular(6),
                          child: LinearProgressIndicator(
                              value: plan.count == 0 ? 0 : progress.paidCount / plan.count, minHeight: 8, color: pulso.accent, backgroundColor: pulso.tertiary),
                        ),
                        const SizedBox(height: 8),
                        Text([
                          '${progress.paidCount}/${plan.count} cuotas pagadas',
                          if (next != null) 'próxima: ${money(next.installment.amountMinor)} el ${_day.format(next.installment.dueDate)}' else 'terminado',
                        ].join(' · ')),
                      ]),
                    ),
                  ),
                  if (progress.scheduleOutOfStep)
                    Card(
                      color: pulso.warning.withValues(alpha: 0.12),
                      child: ListTile(
                        leading: Icon(Icons.tune, color: pulso.warning),
                        title: const Text('Lo pendiente no coincide con las cuotas que quedan'),
                        subtitle: const Text('Hay un pago de otro importe. Revisa cómo quedaría el calendario antes de cambiarlo.'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => _adjust(context, progress),
                      ),
                    ),
                  for (final (s, t) in charges)
                    Card(
                      color: pulso.accent.withValues(alpha: 0.08),
                      child: ListTile(
                        leading: Icon(Icons.link, color: pulso.accent),
                        title: Text('¿El cargo de ${money(t.amountMinor)} del ${_day.format(t.date)} es la cuota ${s.number}?'),
                        subtitle: Text(t.descriptionText),
                        trailing:
                            TextButton(onPressed: () => repository.apply(linkOperation(plan, s.number, t, DateTime.now())), child: const Text('Sí, es esta')),
                      ),
                    ),
                  const SectionTitle('Cómo cuenta'),
                  Text(installmentEffect(plan), style: TextStyle(fontSize: 13, color: Theme.of(context).hintColor)),
                  const SectionTitle('Calendario'),
                  Card(
                    child: Column(children: [
                      for (final s in progress.states)
                        ListTile(
                          dense: true,
                          leading: Icon(
                              switch (s.status) {
                                InstallmentStatus.paid || InstallmentStatus.paidBefore => Icons.check_circle,
                                InstallmentStatus.overdue => Icons.error_outline,
                                InstallmentStatus.upcoming => Icons.radio_button_unchecked,
                              },
                              color: switch (s.status) {
                                InstallmentStatus.paid || InstallmentStatus.paidBefore => pulso.income,
                                InstallmentStatus.overdue => pulso.warning,
                                InstallmentStatus.upcoming => Theme.of(context).hintColor,
                              }),
                          title: Text('${s.number}. ${_day.format(s.installment.dueDate)}'),
                          subtitle: Text([
                            s.status.title,
                            if (s.payment != null) 'pagada ${_day.format(s.payment!.date)}',
                            if (s.differenceMinor != 0) '${s.differenceMinor > 0 ? '+' : ''}${money(s.differenceMinor)} sobre lo previsto',
                          ].join(' · ')),
                          trailing: Text(money(s.payment?.amountMinor ?? s.installment.amountMinor), style: const TextStyle(fontWeight: FontWeight.w600)),
                          onTap: s.status == InstallmentStatus.paidBefore ? null : () => _instalment(context, s, charges),
                        ),
                    ]),
                  ),
                  const SizedBox(height: 40),
                ]),
              ));
        },
      );
}

/// Runs [onOpen] once, after the first frame (an instalment opened from a note of Don Bigotes).
class _OpenOnce extends StatefulWidget {
  const _OpenOnce({required this.onOpen, required this.child});
  final VoidCallback? onOpen;
  final Widget child;
  @override
  State<_OpenOnce> createState() => _OpenOnceState();
}

class _OpenOnceState extends State<_OpenOnce> {
  @override
  void initState() {
    super.initState();
    if (widget.onOpen != null) WidgetsBinding.instance.addPostFrameCallback((_) => mounted ? widget.onOpen!() : null);
  }

  @override
  Widget build(BuildContext context) => widget.child;
}

class _PaymentForm extends StatefulWidget {
  const _PaymentForm({required this.repository, required this.plan, required this.state});
  final FinanceRepository repository;
  final InstallmentPlan plan;
  final InstallmentState state;
  @override
  State<_PaymentForm> createState() => _PaymentFormState();
}

class _PaymentFormState extends State<_PaymentForm> {
  late final _amount = TextEditingController(text: amountText(widget.state.installment.amountMinor));
  DateTime _date = DateTime.now();
  String? _message;
  bool _saving = false;

  @override
  Widget build(BuildContext context) => AbsorbPointer(
        absorbing: _saving,
        child: FormPage(
          title: 'Pago de la cuota ${widget.state.number}',
          message: _message,
          onSave: _saving
              ? null
              : () async {
                  final amount = amountFrom(_amount);
                  if (amount == null || amount <= 0) return setState(() => _message = 'Escribe el importe pagado.');
                  setState(() => _saving = true);
                  try {
                    await widget.repository.apply(paymentOperation(widget.plan, widget.state.number, amount, _date, DateTime.now(), widget.repository.newId()));
                    if (mounted) closeOwnScreen(this.context);
                  } catch (error) {
                    if (mounted) setState(() => _message = 'No se ha podido guardar: $error');
                  } finally {
                    if (mounted) setState(() => _saving = false);
                  }
                },
          children: [
            AmountInput(controller: _amount, label: 'Importe pagado (€)'),
            Text('Si pagas otro importe, el calendario no se cambia solo: verás el efecto y podrás ajustarlo.',
                style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            DateInput(label: 'Fecha del pago', value: _date, onChanged: (v) => setState(() => _date = v ?? _date)),
          ],
        ),
      );
}
