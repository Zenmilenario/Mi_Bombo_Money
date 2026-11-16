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
    final items = calc.budgetProgress(month);
    final budgeted = items.where((i) => i.limitMinor > 0).toList();
    final unbudgeted = items.where((i) => i.limitMinor <= 0).toList();
    final total = budgeted.fold(0, (sum, i) => sum + i.limitMinor);
    final spent = budgeted.fold(0, (sum, i) => sum + i.spentMinor);
    final withoutAny = calc.data.categories.where((c) => c.isExpense && !items.any((i) => i.category.id == c.id)).toList();
    final attention = budgeted.where((i) => i.fraction >= 0.85).toList()..sort((a, b) => b.fraction.compareTo(a.fraction));
    final healthy = budgeted.where((i) => i.fraction < 0.85).toList()..sort((a, b) => b.fraction.compareTo(a.fraction));
    final reservedPaid = calc.monthlySummary(month).reservedExpenseMinor;
    final hint = Theme.of(context).hintColor;
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
      body: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: EdgeInsets.fromLTRB(16, 16, 16, 88 + MediaQuery.paddingOf(context).bottom), children: [
        MonthSelector(month: month, onMonth: onMonth),
        const SizedBox(height: 8),
        BudgetOverview(
            limitMinor: total,
            spentMinor: spent,
            unbudgetedSpentMinor: unbudgeted.fold(0, (sum, i) => sum + i.spentMinor),
            month: month),
        if (budgeted.isNotEmpty) ...[const SizedBox(height: 14), _ComparisonCard(items: budgeted)],
        if (reservedPaid > 0) ...[
          const SizedBox(height: 14),
          Card(
            child: ListTile(
              leading: const Icon(Icons.lock_open),
              title: const Text('Pagado con reservas'),
              subtitle: const Text('Ya estaba apartado: queda fuera del presupuesto y no genera avisos de exceso.'),
              trailing: Text(money(reservedPaid), style: const TextStyle(fontWeight: FontWeight.w600)),
            ),
          ),
        ],
        if (attention.isNotEmpty) ...[
          const SectionTitle('Necesitan atención'),
          Card(child: Column(children: [for (final i in attention) _BudgetRow(item: i, onTap: () => _edit(context, i.category))])),
        ],
        if (healthy.isNotEmpty) ...[
          const SectionTitle('Dentro del presupuesto'),
          Card(child: Column(children: [for (final i in healthy) _BudgetRow(item: i, onTap: () => _edit(context, i.category))])),
        ],
        if (unbudgeted.isNotEmpty || withoutAny.isNotEmpty) ...[
          const SizedBox(height: 14),
          _AddToBudgetCard(
            categories: [...unbudgeted.map((i) => i.category), ...withoutAny],
            withSpending: {for (final i in unbudgeted) if (i.spentMinor > 0) i.category.id},
            onTap: (c) => _edit(context, c),
          ),
        ],
        Padding(
          padding: const EdgeInsets.fromLTRB(4, 12, 4, 0),
          child: Text('Las transferencias entre tus propias cuentas no consumen presupuesto. Los gastos y las comisiones sí se incluyen en su categoría.',
              style: TextStyle(fontSize: 12, color: hint)),
        ),
        const SectionTitle('Objetivos de ahorro'),
        GoalsList(repository: repository, calc: calc),
        const SizedBox(height: 80),
      ]),
    );
  }
}

/// The sentence under the overall bar (Swift `budgetPacingText`): against an even pace this month, how the past
/// month closed, or that a future month is ready.
String budgetPacingText(int limitMinor, int spentMinor, DateTime month, DateTime now) {
  if (limitMinor <= 0) return 'Define límites para empezar a controlar el mes';
  final current = DateTime(now.year, now.month), chosen = DateTime(month.year, month.month);
  if (chosen.isAfter(current)) return 'Presupuesto preparado para un mes futuro';
  if (chosen.isBefore(current)) {
    return limitMinor - spentMinor >= 0 ? 'Cerraste el mes por debajo del presupuesto' : 'Cerraste el mes por encima del presupuesto';
  }
  final difference = MonthPace(limitMinor: limitMinor, spentMinor: spentMinor, day: now.day, daysInMonth: DateTime(now.year, now.month + 1, 0).day)
      .differenceMinor;
  return difference >= 0
      ? 'Vas ${money(difference)} por debajo del ritmo previsto'
      : 'Vas ${money(-difference)} por encima del ritmo previsto';
}

/// A small coloured label with the state of a budget (Swift `StatusPill`).
class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.text, required this.color, this.icon});
  final String text;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Container(
        padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
        decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(20)),
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          if (icon != null) ...[Icon(icon, size: 13, color: color), const SizedBox(width: 4)],
          Text(text, style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: color)),
        ]),
      );
}

/// «Vista general»: budgeted, spent, available, the overall bar with its pace and the spending without budget.
class BudgetOverview extends StatelessWidget {
  const BudgetOverview({super.key, required this.limitMinor, required this.spentMinor, required this.unbudgetedSpentMinor, required this.month});
  final int limitMinor, spentMinor, unbudgetedSpentMinor;
  final DateTime month;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final fraction = limitMinor > 0 ? spentMinor / limitMinor : 0.0;
    final tint = fraction > 1 ? pulso.expense : (fraction >= 0.85 ? pulso.warning : pulso.accent);
    final (status, icon) = limitMinor <= 0
        ? ('Sin configurar', Icons.add_circle_outline)
        : fraction > 1
            ? ('Superado', Icons.warning_rounded)
            : fraction >= 0.85
                ? ('Cerca del límite', Icons.error)
                : ('En control', Icons.check_circle);
    final available = limitMinor - spentMinor;
    Widget figure(String label, int value, Color? color) => Expanded(
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: TextStyle(fontSize: 13, color: hint)),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(money(value), style: TextStyle(fontSize: 22, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        );
    return Card(
      shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(Pulso.heroRadius), side: BorderSide(color: pulso.outline)),
      child: Padding(
        padding: const EdgeInsets.all(18),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            const Expanded(child: Text('Vista general', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700))),
            _StatusPill(text: status, color: limitMinor <= 0 ? hint : tint, icon: icon),
          ]),
          const SizedBox(height: 14),
          if (limitMinor <= 0) ...[
            Icon(Icons.pie_chart_outline, color: pulso.accent, size: 30),
            const SizedBox(height: 8),
            const Text('Aún no has definido límites para este mes.', style: TextStyle(fontWeight: FontWeight.w600)),
            Text('Toca una categoría de «Añadir al presupuesto» o el botón +.', style: TextStyle(fontSize: 12, color: hint)),
          ] else ...[
            Row(children: [
              figure('Presupuestado', limitMinor, null),
              figure('Gastado', spentMinor, fraction > 1 ? pulso.expense : null),
            ]),
            const SizedBox(height: 12),
            Divider(height: 1, color: pulso.outline),
            const SizedBox(height: 12),
            Row(children: [
              const Expanded(child: Text('Disponible', style: TextStyle(fontWeight: FontWeight.w600))),
              Text(money(available, signed: true),
                  style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700, color: available >= 0 ? pulso.income : pulso.expense)),
            ]),
            const SizedBox(height: 12),
            ClipRRect(
              borderRadius: BorderRadius.circular(6),
              child: LinearProgressIndicator(value: fraction.clamp(0.0, 1.0), minHeight: 10, color: tint, backgroundColor: pulso.tertiary),
            ),
            const SizedBox(height: 8),
            Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
              Expanded(child: Text(budgetPacingText(limitMinor, spentMinor, month, DateTime.now()), style: TextStyle(fontSize: 12, color: hint))),
              Text('${(fraction * 100).round()} %', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: tint)),
            ]),
          ],
          if (unbudgetedSpentMinor > 0) ...[
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.error_outline, size: 15, color: pulso.warning),
              const SizedBox(width: 5),
              Text('Gasto sin presupuesto: ${money(unbudgetedSpentMinor)}', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: pulso.warning)),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// «Gasto frente a límite»: the six categories using most of their budget, spent over the limit.
class _ComparisonCard extends StatelessWidget {
  const _ComparisonCard({required this.items});
  final List<BudgetProgress> items;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final shown = ([...items]..sort((a, b) => b.fraction.compareTo(a.fraction))).take(6).toList();
    final scale = shown.fold(1, (m, i) => [m, i.limitMinor, i.spentMinor].reduce((a, b) => a > b ? a : b));
    Widget bar(int value, Color color) => LayoutBuilder(
          builder: (context, c) => Container(
            height: 9,
            width: (c.maxWidth * value / scale).clamp(3.0, c.maxWidth),
            decoration: BoxDecoration(color: color, borderRadius: BorderRadius.circular(3)),
          ),
        );
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Gasto frente a límite', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text('Primero, las categorías con mayor uso del presupuesto', style: TextStyle(fontSize: 13, color: hint)),
          const SizedBox(height: 14),
          if (amountsHidden)
            Padding(padding: const EdgeInsets.symmetric(vertical: 24), child: Center(child: Text('Gráfico oculto por privacidad', style: TextStyle(color: hint))))
          else
            for (final item in shown)
              Padding(
                padding: const EdgeInsets.only(bottom: 12),
                child: Row(children: [
                  SizedBox(width: 96, child: Text(item.category.name, maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13))),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      bar(item.limitMinor, hint.withValues(alpha: 0.25)),
                      const SizedBox(height: 3),
                      bar(item.spentMinor, item.spentMinor > item.limitMinor ? pulso.expense : pulso.accent),
                    ]),
                  ),
                ]),
              ),
          Row(children: [
            Container(width: 10, height: 10, decoration: BoxDecoration(color: hint.withValues(alpha: 0.25), borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 5),
            Text('Límite', style: TextStyle(fontSize: 12, color: hint)),
            const SizedBox(width: 14),
            Container(width: 10, height: 10, decoration: BoxDecoration(color: pulso.accent, borderRadius: BorderRadius.circular(2))),
            const SizedBox(width: 5),
            Text('Gastado', style: TextStyle(fontSize: 12, color: hint)),
          ]),
          if (items.length > shown.length)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text('Se muestran ${shown.length} de ${items.length} presupuestos.', style: TextStyle(fontSize: 12, color: hint)),
            ),
        ]),
      ),
    );
  }
}

/// One budget: the category's icon, its state, the bar and what is spent and left (Swift `BudgetRow`).
class _BudgetRow extends StatelessWidget {
  const _BudgetRow({required this.item, required this.onTap});
  final BudgetProgress item;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final own = colorFromHex(item.category.colorHex);
    final color = item.spentMinor > item.limitMinor ? pulso.expense : (item.fraction >= 0.85 ? pulso.warning : own);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Container(
              width: 34,
              height: 34,
              decoration: BoxDecoration(color: own.withValues(alpha: 0.12), shape: BoxShape.circle),
              child: Icon(symbolIcon(item.category.systemImage), size: 18, color: own),
            ),
            const SizedBox(width: 10),
            Flexible(child: Text(item.category.name, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
            if (item.isRecurring) ...[const SizedBox(width: 6), Icon(Icons.repeat, size: 14, color: hint)],
            const Spacer(),
            _StatusPill(text: item.statusText, color: color),
          ]),
          const SizedBox(height: 10),
          ClipRRect(
            borderRadius: BorderRadius.circular(5),
            child: LinearProgressIndicator(value: item.fraction.clamp(0.0, 1.0), minHeight: 8, color: color, backgroundColor: pulso.tertiary),
          ),
          const SizedBox(height: 6),
          Row(children: [
            Expanded(child: Text('Gastado: ${money(item.spentMinor)}', style: TextStyle(fontSize: 12, color: hint))),
            Text('Disponible: ${money(item.availableMinor)}', style: TextStyle(fontSize: 12, color: hint)),
          ]),
          if (item.carriedInMinor > 0)
            Text('Incluye ${money(item.carriedInMinor)} del mes anterior', style: TextStyle(fontSize: 12, color: hint)),
        ]),
      ),
    );
  }
}

/// «Añadir al presupuesto»: the categories without a limit as icons; an orange dot marks spending without budget.
class _AddToBudgetCard extends StatelessWidget {
  const _AddToBudgetCard({required this.categories, required this.withSpending, required this.onTap});
  final List<Category> categories;
  final Set<String> withSpending;
  final ValueChanged<Category> onTap;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          const Text('Añadir al presupuesto', style: TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
          Text('${categories.length} categorías sin límite · toca un icono', style: TextStyle(fontSize: 13, color: hint)),
          const SizedBox(height: 12),
          Wrap(spacing: 10, runSpacing: 10, children: [
            for (final c in categories)
              Tooltip(
                message: c.name,
                child: Semantics(
                  button: true,
                  label: 'Crear un presupuesto para ${c.name}',
                  child: InkWell(
                    onTap: () => onTap(c),
                    borderRadius: BorderRadius.circular(12),
                    child: Stack(children: [
                      Container(
                        width: 48,
                        height: 48,
                        decoration: BoxDecoration(color: colorFromHex(c.colorHex).withValues(alpha: 0.10), borderRadius: BorderRadius.circular(12)),
                        child: Icon(symbolIcon(c.systemImage), color: colorFromHex(c.colorHex)),
                      ),
                      if (withSpending.contains(c.id))
                        Positioned(
                            top: 4, right: 4, child: Container(width: 7, height: 7, decoration: BoxDecoration(color: pulso.warning, shape: BoxShape.circle))),
                    ]),
                  ),
                ),
              ),
          ]),
          if (withSpending.isNotEmpty) ...[
            const SizedBox(height: 10),
            Row(children: [
              Icon(Icons.circle, size: 8, color: pulso.warning),
              const SizedBox(width: 6),
              Text('El punto naranja indica gasto sin presupuesto.', style: TextStyle(fontSize: 12, color: pulso.warning)),
            ]),
          ],
        ]),
      ),
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
