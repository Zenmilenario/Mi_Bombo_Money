// Setting a category's budget, shared by the form (Presupuestos › a category) and Don Bigotes («ponme 200 € para
// restaurantes cada mes»): only this month (an override) or every month from this one (a plan), with what happens to
// the unspent money. Returns the operation and the one that puts everything back as it was.
import 'banking.dart' show referenceSeconds;
import 'edits.dart';
import 'finance.dart';
import 'models.dart';

/// A month as the cloud stores it: the first day at noon UTC.
num monthSeconds(DateTime month) => referenceSeconds(DateTime.utc(month.year, month.month, 1, 12));

({Operation operation, Operation undo}) budgetOperations({
  required Finances data,
  required Category category,
  required DateTime month,
  required int amountMinor,
  required bool everyMonth,
  RemainderChoice? remainder,
  required String Function() newId,
  required DateTime now,
}) {
  final key = monthKey(month);
  final stamp = referenceSeconds(now);
  final monthOverride = data.budgets.where((b) => b.categoryId == category.id && monthKey(b.monthStart) == key).firstOrNull;
  final plan = FinanceCalculator.activeRecurringBudget(category, key, data.recurringBudgets);
  final choice = remainder ?? plan?.remainderChoice ?? RemainderChoice.save;
  final ops = <Operation>[], undo = <Operation>[];
  Operation restoreOverride(MonthlyBudget b) => upsertOperation(
      'budgets',
      {'id': b.id, 'monthStart': monthSeconds(b.monthStart), 'limitMinor': b.limitMinor, 'notes': '', 'createdAt': stamp, 'updatedAt': stamp, 'categoryID': b.categoryId},
      create: true);
  if (everyMonth) {
    if (monthOverride != null) {
      ops.add(removeOperation('budgets', monthOverride.id));
      undo.add(restoreOverride(monthOverride));
    }
    if (plan != null && monthKey(plan.startMonth) == key) {
      ops.add(upsertOperation('recurringBudgets', {'id': plan.id, 'baseLimitMinor': amountMinor, 'remainderChoiceRaw': choice.name, 'updatedAt': stamp}, create: false));
      undo.add(upsertOperation('recurringBudgets', {'id': plan.id, 'baseLimitMinor': plan.baseLimitMinor, 'remainderChoiceRaw': plan.remainderChoice.name, 'updatedAt': stamp},
          create: false));
    } else {
      if (plan != null) {
        ops.add(upsertOperation('recurringBudgets', {'id': plan.id, 'endMonth': monthSeconds(month), 'updatedAt': stamp}, create: false));
        undo.add(upsertOperation('recurringBudgets', {'id': plan.id, 'endMonth': plan.endMonth == null ? null : monthSeconds(plan.endMonth!), 'updatedAt': stamp},
            create: false));
      }
      final id = newId();
      ops.add(upsertOperation(
          'recurringBudgets',
          {
            'id': id,
            'startMonth': monthSeconds(month),
            'endMonth': null,
            'baseLimitMinor': amountMinor,
            'remainderChoiceRaw': choice.name,
            'createdAt': stamp,
            'updatedAt': stamp,
            'categoryID': category.id,
          },
          create: true));
      undo.add(removeOperation('recurringBudgets', id));
    }
  } else if (monthOverride != null) {
    ops.add(upsertOperation('budgets', {'id': monthOverride.id, 'limitMinor': amountMinor, 'updatedAt': stamp}, create: false));
    undo.add(upsertOperation('budgets', {'id': monthOverride.id, 'limitMinor': monthOverride.limitMinor, 'updatedAt': stamp}, create: false));
  } else {
    final id = newId();
    ops.add(upsertOperation(
        'budgets',
        {'id': id, 'monthStart': monthSeconds(month), 'limitMinor': amountMinor, 'notes': '', 'createdAt': stamp, 'updatedAt': stamp, 'categoryID': category.id},
        create: true));
    undo.add(removeOperation('budgets', id));
  }
  return (operation: batchOperation(ops), undo: batchOperation(undo.reversed.toList()));
}
