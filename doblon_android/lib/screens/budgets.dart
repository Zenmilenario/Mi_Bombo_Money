import 'package:flutter/material.dart';

import '../banking.dart' show referenceSeconds;
import '../data.dart';
import '../edits.dart';
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'forms.dart';
import 'widgets.dart';

/// A month as the cloud stores it: the first day at noon UTC.
num monthSeconds(DateTime month) => referenceSeconds(DateTime.utc(month.year, month.month, 1, 12));

/// Presupuestos: the chosen month, what carries over, spending without budget, and the savings goals.
class BudgetsScreen extends StatelessWidget {
  const BudgetsScreen({super.key, required this.calc, required this.month, required this.onMonth, required this.repository});
  final FinanceCalculator calc;
  final DateTime month;
  final ValueChanged<DateTime> onMonth;
  final FinanceRepository repository;

  void _edit(BuildContext context, Category category) =>
      Navigator.of(context).push(MaterialPageRoute(builder: (_) => BudgetEditorScreen(repository: repository, category: category, month: month)));

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final items = calc.budgetProgress(month);
    final budgeted = items.where((i) => i.limitMinor > 0).toList();
    final unbudgeted = items.where((i) => i.limitMinor <= 0).toList();
    final total = budgeted.fold(0, (sum, i) => sum + i.limitMinor);
    final spent = budgeted.fold(0, (sum, i) => sum + i.spentMinor);
    final withoutAny = calc.data.categories.where((c) => c.isExpense && !items.any((i) => i.category.id == c.id)).toList();
    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Añadir presupuesto',
        onPressed: () async {
          final options = [...unbudgeted.map((i) => i.category), ...withoutAny];
          if (options.isEmpty) return;
          final chosen = await showModalBottomSheet<Category>(
            context: context,
            showDragHandle: true,
            builder: (context) => ListView(children: [
              for (final c in options)
                ListTile(
                    leading: CircleAvatar(radius: 8, backgroundColor: colorFromHex(c.colorHex)), title: Text(c.name), onTap: () => Navigator.pop(context, c)),
            ]),
          );
          if (chosen != null && context.mounted) _edit(context, chosen);
        },
        child: const Icon(Icons.add),
      ),
      body: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
        MonthSelector(month: month, onMonth: onMonth),
        Row(children: [
          Expanded(child: MetricTile(label: 'Presupuestado', value: money(total), color: pulso.savings)),
          const SizedBox(width: 10),
          Expanded(child: MetricTile(label: 'Gastado', value: money(spent), color: spent > total ? pulso.expense : pulso.accent)),
          const SizedBox(width: 10),
          Expanded(child: MetricTile(label: 'Disponible', value: money(total - spent), color: total - spent >= 0 ? pulso.income : pulso.expense)),
        ]),
        if (budgeted.isEmpty)
          const Padding(padding: EdgeInsets.all(24), child: Text('No hay presupuestos este mes. Pulsa + para añadir uno.', textAlign: TextAlign.center))
        else ...[
          const SectionTitle('Por categoría'),
          Card(
            child: Padding(
              padding: const EdgeInsets.all(14),
              child: Column(children: [for (final i in budgeted) InkWell(onTap: () => _edit(context, i.category), child: BudgetBar(item: i))]),
            ),
          ),
        ],
        if (unbudgeted.isNotEmpty) ...[
          const SectionTitle('Gasto sin presupuesto'),
          Card(
            child: Column(children: [
              for (final i in unbudgeted) ListTile(title: Text(i.category.name), trailing: Text(money(i.spentMinor)), onTap: () => _edit(context, i.category)),
            ]),
          ),
        ],
        const SectionTitle('Objetivos de ahorro'),
        GoalsList(repository: repository, calc: calc),
        const SizedBox(height: 80),
      ]),
    );
  }
}

/// Edit a category's budget: only this month (an override) or every month from this one (a plan), with
/// what happens to the unspent money (kept as savings or carried to the next month).
class BudgetEditorScreen extends StatefulWidget {
  const BudgetEditorScreen({super.key, required this.repository, required this.category, required this.month});
  final FinanceRepository repository;
  final Category category;
  final DateTime month;
  @override
  State<BudgetEditorScreen> createState() => _BudgetEditorScreenState();
}

class _BudgetEditorScreenState extends State<BudgetEditorScreen> {
  late final Finances data = widget.repository.finances!;
  late final int key = monthKey(widget.month);
  late final MonthlyBudget? monthOverride = data.budgets.where((b) => b.categoryId == widget.category.id && monthKey(b.monthStart) == key).firstOrNull;
  late final RecurringBudget? plan = FinanceCalculator.activeRecurringBudget(widget.category, key, data.recurringBudgets);
  late final _amount = TextEditingController(
      text: monthOverride != null
          ? amountText(monthOverride!.limitMinor)
          : plan != null
              ? amountText(plan!.baseLimitMinor)
              : '');
  late bool _everyMonth = monthOverride == null && plan != null;
  late RemainderChoice _remainder = plan?.remainderChoice ?? RemainderChoice.save;
  String? _message;

  Future<void> _save() async {
    final amount = amountFrom(_amount);
    if (amount == null || amount < 0) return setState(() => _message = 'Escribe el límite del mes.');
    final now = referenceSeconds(DateTime.now());
    final ops = <Operation>[];
    if (_everyMonth) {
      if (monthOverride != null) ops.add(removeOperation('budgets', monthOverride!.id));
      final current = plan;
      if (current != null && monthKey(current.startMonth) == key) {
        ops.add(upsertOperation('recurringBudgets', {'id': current.id, 'baseLimitMinor': amount, 'remainderChoiceRaw': _remainder.name, 'updatedAt': now},
            create: false));
      } else {
        if (current != null) {
          ops.add(upsertOperation('recurringBudgets', {'id': current.id, 'endMonth': monthSeconds(widget.month), 'updatedAt': now}, create: false));
        }
        ops.add(upsertOperation(
            'recurringBudgets',
            {
              'id': widget.repository.newId(),
              'startMonth': monthSeconds(widget.month),
              'endMonth': null,
              'baseLimitMinor': amount,
              'remainderChoiceRaw': _remainder.name,
              'createdAt': now,
              'updatedAt': now,
              'categoryID': widget.category.id,
            },
            create: true));
      }
    } else {
      ops.add(monthOverride != null
          ? upsertOperation('budgets', {'id': monthOverride!.id, 'limitMinor': amount, 'updatedAt': now}, create: false)
          : upsertOperation(
              'budgets',
              {
                'id': widget.repository.newId(),
                'monthStart': monthSeconds(widget.month),
                'limitMinor': amount,
                'notes': '',
                'createdAt': now,
                'updatedAt': now,
                'categoryID': widget.category.id,
              },
              create: true));
    }
    await widget.repository.apply(batchOperation(ops));
    if (mounted) Navigator.of(context).pop();
  }

  Future<void> _remove() async {
    final now = referenceSeconds(DateTime.now());
    final ops = <Operation>[];
    if (monthOverride != null) ops.add(removeOperation('budgets', monthOverride!.id));
    final current = plan;
    if (current != null) {
      ops.add(monthKey(current.startMonth) == key
          ? removeOperation('recurringBudgets', current.id)
          : upsertOperation('recurringBudgets', {'id': current.id, 'endMonth': monthSeconds(widget.month), 'updatedAt': now}, create: false));
    }
    if (ops.isNotEmpty) await widget.repository.apply(batchOperation(ops));
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final label = '${widget.month.month.toString().padLeft(2, '0')}/${widget.month.year}';
    return FormPage(
      title: 'Presupuesto · ${widget.category.name}',
      message: _message,
      onSave: _save,
      actions: [
        if (monthOverride != null || plan != null) IconButton(tooltip: 'Quitar presupuesto', icon: const Icon(Icons.delete_outline), onPressed: _remove),
      ],
      children: [
        AmountInput(controller: _amount, label: 'Límite del mes (€)'),
        SegmentedButton<bool>(
          segments: [ButtonSegment(value: false, label: Text('Solo $label')), const ButtonSegment(value: true, label: Text('Todos los meses'))],
          selected: {_everyMonth},
          onSelectionChanged: (v) => setState(() => _everyMonth = v.first),
        ),
        if (_everyMonth) ...[
          const Text('Lo que no gastes un mes:'),
          RadioGroup<RemainderChoice>(
            groupValue: _remainder,
            onChanged: (v) => setState(() => _remainder = v ?? _remainder),
            child: const Column(children: [
              RadioListTile(contentPadding: EdgeInsets.zero, value: RemainderChoice.save, title: Text('Queda como ahorro')),
              RadioListTile(contentPadding: EdgeInsets.zero, value: RemainderChoice.carryForward, title: Text('Se suma al mes siguiente')),
            ]),
          ),
          Text('Se aplica desde $label en adelante. Los meses anteriores no cambian.', style: Theme.of(context).textTheme.bodySmall),
        ],
      ],
    );
  }
}

/// Savings goals with their progress; tap to edit, + to add.
class GoalsList extends StatelessWidget {
  const GoalsList({super.key, required this.repository, required this.calc});
  final FinanceRepository repository;
  final FinanceCalculator calc;

  /// A goal linked to an account follows that account's balance; otherwise the amount written by hand.
  int saved(SavingsGoal goal) {
    final account = calc.data.account(goal.linkedAccountId);
    return account != null ? calc.balance(account) : goal.currentAmountMinor;
  }

  @override
  Widget build(BuildContext context) {
    final goals = calc.data.goals;
    return Card(
      child: Column(children: [
        for (final goal in goals)
          ListTile(
            leading: CircleAvatar(radius: 8, backgroundColor: colorFromHex(goal.colorHex)),
            title: Text(goal.name),
            subtitle: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
              const SizedBox(height: 6),
              LinearProgressIndicator(
                value: goal.targetAmountMinor <= 0 ? 0 : (saved(goal) / goal.targetAmountMinor).clamp(0, 1).toDouble(),
                color: colorFromHex(goal.colorHex),
                minHeight: 6,
              ),
              const SizedBox(height: 4),
              Text('${money(saved(goal))} de ${money(goal.targetAmountMinor)}${goal.isCompleted ? ' · conseguido' : ''}'),
            ]),
            onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GoalFormScreen(repository: repository, editing: goal))),
          ),
        ListTile(
          leading: const Icon(Icons.add),
          title: const Text('Nuevo objetivo'),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => GoalFormScreen(repository: repository))),
        ),
      ]),
    );
  }
}

class GoalFormScreen extends StatefulWidget {
  const GoalFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final SavingsGoal? editing;
  @override
  State<GoalFormScreen> createState() => _GoalFormScreenState();
}

class _GoalFormScreenState extends State<GoalFormScreen> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late final _target = TextEditingController(text: widget.editing == null ? '' : amountText(widget.editing!.targetAmountMinor));
  late final _current = TextEditingController(text: widget.editing == null ? '' : amountText(widget.editing!.currentAmountMinor));
  late DateTime? _date = widget.editing?.targetDate;
  late String _color = widget.editing?.colorHex ?? '#2F7D66';
  late String? _account = widget.editing?.linkedAccountId;
  late bool _completed = widget.editing?.isCompleted ?? false;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final accounts = widget.repository.finances!.accounts.where((a) => !a.isArchived).toList();
    final editing = widget.editing;
    return FormPage(
      title: editing == null ? 'Nuevo objetivo' : 'Editar objetivo',
      message: _message,
      actions: [
        if (editing != null)
          IconButton(
            tooltip: 'Borrar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (!await confirm(context, 'Borrar objetivo', 'Se borrará de todos tus dispositivos.', action: 'Borrar')) return;
              await widget.repository.apply(removeOperation('goals', editing.id));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
      ],
      onSave: () async {
        final name = _name.text.trim();
        final target = amountFrom(_target);
        final current = _current.text.trim().isEmpty ? 0 : amountFrom(_current);
        if (name.isEmpty) return setState(() => _message = 'Escribe el nombre del objetivo.');
        if (target == null || target <= 0) return setState(() => _message = 'Escribe cuánto quieres reunir.');
        if (current == null || current < 0) return setState(() => _message = 'Lo que llevas ahorrado no es un importe válido.');
        final now = referenceSeconds(DateTime.now());
        final fields = {
          'name': name,
          'targetAmountMinor': target,
          'currentAmountMinor': current,
          'targetDate': _date == null ? null : referenceSeconds(_date!),
          'colorHex': _color,
          'isCompleted': _completed,
          'linkedAccountID': _account,
          'updatedAt': now,
        };
        await widget.repository.apply(editing != null
            ? upsertOperation('goals', {'id': editing.id, ...fields}, create: false)
            : upsertOperation('goals', {'id': widget.repository.newId(), ...fields, 'notes': '', 'createdAt': now}, create: true));
        if (mounted) Navigator.of(this.context).pop();
      },
      children: [
        TextInput(controller: _name, label: 'Nombre'),
        AmountInput(controller: _target, label: 'Objetivo (€)'),
        Choice<String?>(
          label: 'Seguir el saldo de una cuenta',
          value: _account,
          options: {null: 'No, lo escribo yo', for (final a in accounts) a.id: a.name},
          onChanged: (v) => setState(() => _account = v),
        ),
        if (_account == null) AmountInput(controller: _current, label: 'Llevo ahorrado (€)'),
        DateInput(label: 'Fecha objetivo', value: _date, optional: true, onChanged: (v) => setState(() => _date = v)),
        ColorInput(value: _color, onChanged: (v) => setState(() => _color = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Conseguido'), value: _completed, onChanged: (v) => setState(() => _completed = v)),
      ],
    );
  }
}
