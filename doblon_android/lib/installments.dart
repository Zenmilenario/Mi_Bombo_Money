// Payments in instalments (25 November 2026): a purchase, a loan or another split payment, followed on its own.
//
// A plan keeps its calendar (`schedule`), the account it is paid from and what the person said about it: the total
// to pay (with interest and fees if any, never added again), the agreed instalment if there is one, and whether the
// purchase or the money of the loan is already recorded. Each paid instalment is an ordinary movement linked to it by
// its `externalID` (`installment:<plan>:<number>[:<spending part>]`): one payment per instalment, so the bank import
// and the cloud keep it once. Future instalments are only planned: they never move a balance before being paid.
import 'dart:math' as math;

import 'automation.dart' show CompanionNote, addMonths;
import 'banking.dart' show referenceSeconds;
import 'edits.dart';
import 'models.dart';
import 'presentation.dart' show money;

/// Splits [totalMinor] in [count] instalments, in cents, adding exactly to the total. With an agreed instalment, all
/// but the last are that amount and the last is what is left. Null when it cannot be split that way.
List<int>? splitTotal(int totalMinor, int count, {int? agreedMinor}) {
  if (totalMinor <= 0 || count < 1 || count > 600) return null;
  if (agreedMinor != null) {
    final last = totalMinor - agreedMinor * (count - 1);
    if (agreedMinor <= 0 || last <= 0) return null;
    return [for (var i = 0; i < count - 1; i++) agreedMinor, last];
  }
  final base = totalMinor ~/ count;
  if (base <= 0) return null;
  // Equal instalments; the last one takes the cents left by the rounding.
  return [for (var i = 0; i < count - 1; i++) base, totalMinor - base * (count - 1)];
}

/// The calendar: one instalment a month from the first due date.
List<Installment>? buildSchedule(int totalMinor, int count, DateTime firstDue, {int? agreedMinor}) {
  final amounts = splitTotal(totalMinor, count, agreedMinor: agreedMinor);
  if (amounts == null) return null;
  return [for (final (i, amount) in amounts.indexed) Installment(addMonths(firstDue, i), amount)];
}

enum InstallmentStatus { paidBefore, paid, overdue, upcoming }

extension InstallmentStatusTitle on InstallmentStatus {
  String get title => switch (this) {
        InstallmentStatus.paidBefore => 'Pagada antes',
        InstallmentStatus.paid => 'Pagada',
        InstallmentStatus.overdue => 'Vencida',
        InstallmentStatus.upcoming => 'Pendiente',
      };
}

class InstallmentState {
  InstallmentState(this.number, this.installment, this.status, this.payment);
  final int number;
  final Installment installment;
  final InstallmentStatus status;

  /// The movement that paid it (null for the ones paid before using the app, or not paid yet).
  final Transaction? payment;
  bool get isOpen => status == InstallmentStatus.overdue || status == InstallmentStatus.upcoming;

  /// A payment of another amount than the planned one.
  int get differenceMinor => payment == null ? 0 : payment!.amountMinor - installment.amountMinor;
}

/// Where a plan stands: what is paid and pending, each instalment's state and the next one.
class InstallmentProgress {
  InstallmentProgress(this.plan, this.states);
  final InstallmentPlan plan;
  final List<InstallmentState> states;

  int get paidMinor => plan.paidBeforeMinor + states.where((s) => s.status == InstallmentStatus.paid).fold(0, (sum, s) => sum + s.payment!.amountMinor);
  int get pendingMinor => math.max(0, plan.totalMinor - paidMinor);
  int get paidCount => states.where((s) => !s.isOpen).length;
  InstallmentState? get next => states.where((s) => s.isOpen).firstOrNull;
  DateTime? get endDate => plan.schedule.lastOrNull?.dueDate;
  bool get finished => next == null;

  /// Pending instalments do not add up to what is pending (a payment of another amount): the calendar could be
  /// adjusted, never silently.
  bool get scheduleOutOfStep => !finished && states.where((s) => s.isOpen).fold(0, (sum, s) => sum + s.installment.amountMinor) != pendingMinor;
}

InstallmentProgress installmentProgress(InstallmentPlan plan, Finances data, DateTime now) {
  final today = DateTime(now.year, now.month, now.day);
  final payments = {
    for (final t in data.transactions)
      if (t.installmentPlanId?.toLowerCase() == plan.id.toLowerCase() && t.installmentNumber != null) t.installmentNumber!: t
  };
  return InstallmentProgress(plan, [
    for (final (i, installment) in plan.schedule.indexed)
      InstallmentState(
        i + 1,
        installment,
        i < plan.paidBeforeCount
            ? InstallmentStatus.paidBefore
            : payments.containsKey(i + 1)
                ? InstallmentStatus.paid
                : installment.dueDate.isBefore(today)
                    ? InstallmentStatus.overdue
                    : InstallmentStatus.upcoming,
        payments[i + 1],
      ),
  ]);
}

/// The `externalID` that links a payment to its instalment. When the purchase or the loan was already recorded, only
/// the instalment's share of the costs (interest and fees) is spending, and it is written in the link.
String installmentLink(InstallmentPlan plan, int number, int amountMinor) {
  final base = '$installmentMarker${plan.id}:$number';
  if (!plan.alreadyRecorded) return base;
  final share = plan.totalMinor <= 0 ? 0 : (plan.costsMinor * amountMinor / plan.totalMinor).round();
  return '$base:${share.clamp(0, amountMinor)}';
}

/// Records the payment of an instalment that the bank does not send (or not yet): an ordinary payment from the
/// plan's account. When the bank's charge arrives later, the import proposes it as this same payment.
Operation paymentOperation(InstallmentPlan plan, int number, int amountMinor, DateTime date, DateTime now, String id) {
  final description = 'Cuota $number/${plan.count} · ${plan.name}';
  return Operation('insert', {
    'record': {
      'id': id,
      'date': referenceSeconds(date),
      'typeRaw': TransactionType.expense.name,
      'amountMinor': amountMinor,
      'descriptionText': description,
      'notes': '',
      'isReconciled': false,
      'fingerprint':
          fingerprint(date: date, source: plan.accountId, destination: null, type: TransactionType.expense, amountMinor: amountMinor, description: description),
      'duplicateStateRaw': 'none',
      'externalID': installmentLink(plan, number, amountMinor),
      'importBatchID': null,
      'recurringMovementID': null,
      'reservedFundID': null,
      'reservedAmountMinor': null,
      'createdAt': referenceSeconds(now),
      'updatedAt': referenceSeconds(now),
      'sourceAccountID': plan.accountId,
      'destinationAccountID': null,
      'categoryID': null,
      'bankEntryKey': null,
    }
  });
}

/// A bank charge confirmed as the payment of an instalment: the same movement, now linked (one effect on balance).
Operation linkOperation(InstallmentPlan plan, int number, Transaction charge, DateTime now) => Operation('patch', {
      'id': charge.id,
      'fields': {'externalID': installmentLink(plan, number, charge.amountMinor), 'updatedAt': referenceSeconds(now)}
    });

/// Undoes a payment: one recorded by hand is deleted; a bank charge stays, only unlinked from the instalment.
Operation undoPaymentOperation(Transaction payment, DateTime now) => payment.bankEntryKey != null
    ? Operation('patch', {
        'id': payment.id,
        'fields': {'externalID': null, 'updatedAt': referenceSeconds(now)}
      })
    : deleteOperation(payment);

/// Bank charges that could be an open instalment: from the plan's account, not linked to anything, of a similar
/// amount (within 10 %) and near its due date (10 days). Never linked on their own: the person confirms.
List<(InstallmentState, Transaction)> compatibleCharges(InstallmentProgress progress, Finances data) {
  final plan = progress.plan;
  final open = progress.states.where((s) => s.isOpen).toList();
  if (open.isEmpty || plan.accountId == null) return const [];
  final found = <(InstallmentState, Transaction)>[];
  for (final t in data.transactions) {
    if (t.bankEntryKey == null || t.type != TransactionType.expense || t.sourceAccountId != plan.accountId || t.externalId != null) continue;
    InstallmentState? best;
    var bestGap = 1 << 30;
    for (final s in open) {
      final gap = t.date.difference(s.installment.dueDate).inDays.abs();
      if (gap <= 10 && (t.amountMinor - s.installment.amountMinor).abs() <= (s.installment.amountMinor * 0.10).round() && gap < bestGap) {
        best = s;
        bestGap = gap;
      }
    }
    if (best != null) found.add((best, t));
  }
  return found;
}

/// The calendar with what is still pending spread again over the open instalments (same dates), after a payment of
/// another amount. Only proposed: the person sees it and confirms.
List<Installment>? rescheduled(InstallmentProgress progress) {
  final open = progress.states.where((s) => s.isOpen).toList();
  if (open.isEmpty) return null;
  final amounts = splitTotal(progress.pendingMinor, open.length);
  if (amounts == null) return null;
  var k = 0;
  return [
    for (final s in progress.states)
      if (s.isOpen)
        Installment(s.installment.dueDate, amounts[k++])
      else
        Installment(s.installment.dueDate, s.payment?.amountMinor ?? s.installment.amountMinor),
  ];
}

List<Map<String, dynamic>> scheduleJson(List<Installment> schedule) => [
      for (final i in schedule) {'dueDate': referenceSeconds(i.dueDate), 'amountMinor': i.amountMinor}
    ];

/// Creates or changes a plan. When what counts as spending changes (already recorded, costs), the links of its
/// payments are rewritten so that spending and budgets follow, without touching the payments themselves.
Operation savePlanOperation({required InstallmentPlan plan, required bool create, required Finances data, required DateTime now}) {
  final fields = <String, dynamic>{
    'id': plan.id,
    'name': plan.name.trim(),
    'kindRaw': plan.kind.name,
    'totalMinor': plan.totalMinor,
    'installmentCount': plan.count,
    'firstDueDate': referenceSeconds(plan.schedule.first.dueDate),
    'accountID': plan.accountId,
    'agreedInstallmentMinor': plan.agreedInstallmentMinor,
    'costsMinor': plan.costsMinor,
    'alreadyRecorded': plan.alreadyRecorded,
    'paidBeforeCount': plan.paidBeforeCount,
    'paidBeforeMinor': plan.paidBeforeMinor,
    'schedule': scheduleJson(plan.schedule),
    'isArchived': plan.isArchived,
    'notes': plan.notes,
    'updatedAt': referenceSeconds(now),
    if (create) 'createdAt': referenceSeconds(now),
  };
  final relinks = [
    for (final t in data.transactions)
      if (!create && t.installmentPlanId?.toLowerCase() == plan.id.toLowerCase() && t.installmentNumber != null)
        if (installmentLink(plan, t.installmentNumber!, t.amountMinor) != t.externalId)
          Operation('patch', {
            'id': t.id,
            'fields': {'externalID': installmentLink(plan, t.installmentNumber!, t.amountMinor), 'updatedAt': referenceSeconds(now)}
          })
  ];
  final upsert = upsertOperation('installmentPlans', fields, create: create);
  return relinks.isEmpty ? upsert : batchOperation([upsert, ...relinks]);
}

/// Incomes that may be the money of [plan] (a loan whose money is «already recorded» and not linked yet): of exactly
/// its total, not linked to anything, from the last three months. Only proposed: the person confirms.
List<Transaction> loanIncomeCandidates(InstallmentPlan plan, Finances data, DateTime now) {
  if (plan.kind != InstallmentKind.loan || !plan.alreadyRecorded || data.transactions.any((t) => t.loanPlanId == plan.id)) return const [];
  return [
    for (final t in data.transactions)
      if (t.type.countsAsIncome && t.amountMinor == plan.totalMinor && t.externalId == null && t.date.isAfter(now.subtract(const Duration(days: 92)))) t
  ];
}

/// Links an existing income as the money of a loan received for [plan]: the same movement, now borrowed money.
Operation loanReceivedOperation(InstallmentPlan plan, Transaction income, DateTime now) => Operation('patch', {
      'id': income.id,
      'fields': {'externalID': '$loanReceivedMarker${plan.id}', 'updatedAt': referenceSeconds(now)}
    });

/// Removes a plan. Its payments and the loan's money stay as ordinary movements (they were real), only unlinked.
Operation removePlanOperation(InstallmentPlan plan, Finances data, DateTime now) => batchOperation([
      removeOperation('installmentPlans', plan.id),
      for (final t in data.transactions)
        if (t.installmentPlanId?.toLowerCase() == plan.id.toLowerCase() || t.loanPlanId?.toLowerCase() == plan.id.toLowerCase())
          Operation('patch', {
            'id': t.id,
            'fields': {'externalID': null, 'updatedAt': referenceSeconds(now)}
          }),
    ]);

/// Active periodic movements of the same account and a similar amount: they would count the same payment twice in
/// the forecast. Shown when creating the plan, with the option to pause them.
List<RecurringMovement> overlappingRecurring(InstallmentPlan plan, Finances data) {
  if (plan.schedule.isEmpty) return const [];
  final typical = plan.schedule.first.amountMinor;
  return [
    for (final r in data.recurringMovements)
      if (r.isActive &&
          r.sourceAccountId == plan.accountId &&
          r.type.countsAsExpense &&
          (r.amountMinor - typical).abs() <= math.max(100, (typical * 0.02).round()))
        r
  ];
}

/// What Don Bigotes points out about the plans: an overdue instalment, a bank charge that may be one (to confirm) and
/// a calendar that no longer adds up. Only incidents, so Inicio stays clear. The id opens the plan (and instalment).
List<CompanionNote> installmentNotes(Finances data, DateTime now) {
  final notes = <CompanionNote>[];
  for (final plan in data.installmentPlans) {
    if (plan.isArchived) continue;
    final progress = installmentProgress(plan, data, now);
    final charges = compatibleCharges(progress, data);
    final borrowed = loanIncomeCandidates(plan, data, now);
    if (borrowed.isNotEmpty) {
      notes.add(CompanionNote(
          id: 'installment:${plan.id}:money:${borrowed.length}',
          title: '¿Es este el dinero de «${plan.name}»?',
          detail: borrowed.length == 1 ? 'Hay un ingreso del mismo importe sin vincular' : 'Hay ${borrowed.length} ingresos del mismo importe sin vincular',
          tab: 2));
    }
    for (final (s, t) in charges) {
      notes.add(CompanionNote(
          id: 'installment:${plan.id}:${s.number}:charge:${t.id}',
          title: '¿Es la cuota ${s.number} de ${plan.name}?',
          detail: 'Un cargo del banco de ${money(t.amountMinor)} el ${t.date.day}/${t.date.month}',
          tab: 2));
    }
    final waiting = {for (final (s, _) in charges) s.number};
    final overdue = progress.states.where((s) => s.status == InstallmentStatus.overdue && !waiting.contains(s.number)).toList();
    if (overdue.isNotEmpty) {
      final first = overdue.first;
      notes.add(CompanionNote(
          id: 'installment:${plan.id}:${first.number}:overdue:${overdue.length}',
          title: overdue.length == 1 ? 'Cuota vencida: ${plan.name}' : '${overdue.length} cuotas vencidas: ${plan.name}',
          detail:
              'La ${first.number}/${plan.count}, de ${money(first.installment.amountMinor)}, vencía el ${first.installment.dueDate.day}/${first.installment.dueDate.month}',
          tab: 2,
          urgent: true));
    }
    if (progress.scheduleOutOfStep) {
      notes.add(CompanionNote(
          id: 'installment:${plan.id}:schedule:${progress.pendingMinor}',
          title: 'Revisa el calendario de ${plan.name}',
          detail: 'Un pago de otro importe: las cuotas que quedan ya no suman lo pendiente',
          tab: 2));
    }
  }
  return notes;
}

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
