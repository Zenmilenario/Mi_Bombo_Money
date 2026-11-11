// Automatic help, with the same rules as the iPhone app: periodic movements (`RecurringMovementService`),
// category rules (`CategoryRuleService`), own-transfer pairing (`PersonalBankingImporter.ownTransferPairs`)
// and Don Bigotes' notes (`CompanionView`). Everything returns operations for the shared queue.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'bank_activity.dart';
import 'banking.dart' show referenceSeconds;
import 'edits.dart';
import 'contributions.dart' show contributionPeriod;
import 'models.dart';
import 'presentation.dart' show money;

// ---------------------------------------------------------------- periodic movements

/// Adds months like a calendar does: 31 January + 1 month is the last day of February.
DateTime addMonths(DateTime date, int months) {
  final target = DateTime(date.year, date.month + months);
  final lastDay = DateTime(target.year, target.month + 1, 0).day;
  return DateTime(target.year, target.month, date.day > lastDay ? lastDay : date.day, date.hour, date.minute, date.second);
}

/// Swift `RecurringMovementService.nextDate`.
DateTime nextDueDate(DateTime date, Frequency frequency, int interval) {
  final step = interval < 1 ? 1 : interval;
  return switch (frequency) {
    Frequency.weekly => DateTime(date.year, date.month, date.day + 7 * step, date.hour, date.minute, date.second),
    Frequency.monthly => addMonths(date, step),
    Frequency.quarterly => addMonths(date, 3 * step),
    Frequency.yearly => addMonths(date, 12 * step),
  };
}

/// Swift `RecurringMovementService.occurrenceID`: the same scheduled payment gets the same ID on every
/// device, so the iPhone and Android never post it twice.
String occurrenceId(String ruleId, DateTime scheduledDate) {
  final day = scheduledDate.toUtc().toIso8601String().substring(0, 10);
  final bytes = sha256.convert(utf8.encode('recurring-v1:${ruleId.toLowerCase()}:$day')).bytes.sublist(0, 16);
  bytes[6] = (bytes[6] & 0x0f) | 0x50;
  bytes[8] = (bytes[8] & 0x3f) | 0x80;
  final hex = bytes.map((b) => b.toRadixString(16).padLeft(2, '0')).join();
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

bool _sameDay(DateTime a, DateTime b) {
  final x = a.toLocal(), y = b.toLocal();
  return x.year == y.year && x.month == y.month && x.day == y.day;
}

DateTime _startOfDay(DateTime d) {
  final l = d.toLocal();
  return DateTime(l.year, l.month, l.day);
}

/// Posts the periodic movements that are due and set to post automatically (Swift `postDueMovements`).
/// Linked bank accounts are skipped (the bank sends the real posting); at most 120 occurrences per rule.
Operation? postDueMovements(Finances data, DateTime now) {
  final today = _startOfDay(now);
  final ops = <Operation>[];
  final posted = <Transaction>[...data.transactions];
  for (final rule in data.recurringMovements) {
    if (!rule.isActive || rule.postsAutomatically != true || rule.amountMinor <= 0) continue;
    final source = data.account(rule.sourceAccountId);
    if (source == null || source.isArchived) continue;
    final destination = rule.type == TransactionType.transfer ? data.account(rule.destinationAccountId) : null;
    if (source.bankIdentityKey != null || destination?.bankIdentityKey != null) continue;
    if (rule.type == TransactionType.transfer) {
      if (destination == null || destination.isArchived || destination.id == source.id) continue;
    } else {
      final category = data.category(rule.categoryId);
      if (category == null || !categorySupports(category, rule.type)) continue;
    }
    final firstAccountDate = destination != null && destination.openingDate.isAfter(source.openingDate) ? destination.openingDate : source.openingDate;
    var next = rule.nextDueDate;
    var active = true;
    var changed = false;
    for (var i = 0; i < 120 && !_startOfDay(next).isAfter(today); i++) {
      if (rule.endDate != null && _startOfDay(next).isAfter(_startOfDay(rule.endDate!))) {
        active = false;
        changed = true;
        break;
      }
      final scheduled = next;
      next = nextDueDate(scheduled, rule.frequency, rule.interval);
      changed = true;
      if (_startOfDay(scheduled).isBefore(_startOfDay(firstAccountDate))) continue;
      final id = occurrenceId(rule.id, scheduled);
      if (posted.any((t) => t.id == id || (t.recurringMovementId == rule.id && _sameDay(t.date, scheduled)))) continue;
      if (rule.type == TransactionType.transfer && destination?.type == AccountType.investment) {
        final (start, end) = contributionPeriod(rule, scheduled);
        final confirmed = posted
            .where((t) =>
                t.type == TransactionType.transfer &&
                t.recurringMovementId == rule.id &&
                t.bankEntryKey != null &&
                t.sourceAccountId == source.id &&
                t.destinationAccountId == destination!.id &&
                !t.date.isBefore(start) &&
                t.date.isBefore(end))
            .fold(0, (sum, t) => sum + t.amountMinor);
        if (confirmed >= rule.amountMinor) continue;
      }
      final date = _startOfDay(scheduled).isBefore(firstAccountDate) ? firstAccountDate : _startOfDay(scheduled);
      final record = {
        'id': id,
        'date': referenceSeconds(date),
        'typeRaw': rule.type.name,
        'amountMinor': rule.amountMinor,
        'descriptionText': rule.descriptionText.trim().isEmpty ? rule.name : rule.descriptionText,
        'notes': rule.notes,
        'isReconciled': false,
        'fingerprint': fingerprint(
            date: date, source: source.id, destination: destination?.id, type: rule.type, amountMinor: rule.amountMinor, description: rule.descriptionText),
        'duplicateStateRaw': 'none',
        'externalID': null,
        'importBatchID': null,
        'recurringMovementID': rule.id,
        'reservedFundID': null,
        'reservedAmountMinor': null,
        'createdAt': referenceSeconds(now),
        'updatedAt': referenceSeconds(now),
        'sourceAccountID': source.id,
        'destinationAccountID': destination?.id,
        'categoryID': rule.type == TransactionType.transfer ? null : rule.categoryId,
        'bankEntryKey': null,
      };
      ops.add(Operation('insert', {'record': record}));
      posted.add(Transaction.fromJson(record));
    }
    if (changed) {
      ops.add(upsertOperation(
          'recurringMovements',
          {
            'id': rule.id,
            'nextDueDate': referenceSeconds(next),
            'isActive': active,
            'updatedAt': referenceSeconds(now),
          },
          create: false));
    }
  }
  return ops.isEmpty ? null : batchOperation(ops);
}

// ---------------------------------------------------------------- category rules

/// Swift `CategoryRuleService.normalized` (keeps one-letter words, unlike the duplicate check).
String ruleText(String text) {
  const folding = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n', 'à': 'a', 'è': 'e', 'ò': 'o', 'ç': 'c'};
  final folded = text.toLowerCase().split('').map((c) => folding[c] ?? c).join();
  return folded.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

/// The category a rule gives to a concept: the longest matching phrase, then the most recent rule.
Category? matchRule(String description, TransactionType type, Finances data) {
  final text = ruleText(description);
  if (text.isEmpty) return null;
  final matches = data.categoryRules.where((rule) {
    final phrase = ruleText(rule.phrase);
    final category = data.category(rule.categoryId);
    return rule.isActive && rule.transactionType == type && phrase.length >= 3 && text.contains(phrase) && category != null && categorySupports(category, type);
  }).toList()
    ..sort((a, b) {
      final la = ruleText(a.phrase).length, lb = ruleText(b.phrase).length;
      return la == lb ? b.updatedAt.compareTo(a.updatedAt) : lb.compareTo(la);
    });
  return matches.isEmpty ? null : data.category(matches.first.categoryId);
}

/// Swift `CategoryRuleService.remember`: updates the rule with the same phrase and type, or creates one.
Operation? rememberRule(String phrase, TransactionType type, Category category, Finances data, DateTime now, String newId) {
  final clean = phrase.trim();
  if (ruleText(clean).length < 3) return null;
  final existing = data.categoryRules.where((r) => r.transactionType == type && ruleText(r.phrase) == ruleText(clean)).firstOrNull;
  if (existing != null) {
    return upsertOperation('categoryRules', {'id': existing.id, 'categoryID': category.id, 'isActive': true, 'updatedAt': referenceSeconds(now)},
        create: false);
  }
  return upsertOperation(
      'categoryRules',
      {
        'id': newId,
        'phrase': clean,
        'transactionTypeRaw': type.name,
        'isActive': true,
        'createdAt': referenceSeconds(now),
        'updatedAt': referenceSeconds(now),
        'categoryID': category.id,
      },
      create: true);
}

// ---------------------------------------------------------------- own transfers

class OwnTransferPair {
  OwnTransferPair(this.debit, this.credit);
  final Transaction debit;
  final Transaction credit;
}

List<String> bankKeys(String? value) {
  if (value == null) return const [];
  if (value.startsWith('enable-entry:')) return [value];
  if (!value.startsWith('enable-keys:')) return const [];
  try {
    return (jsonDecode(value.substring('enable-keys:'.length)) as List).cast<String>();
  } catch (_) {
    return const [];
  }
}

/// Swift `PersonalBankingPlan.encodedKeys`: one key as it is, two as a sorted JSON list.
String encodedKeys(List<String> keys) {
  final unique = keys.toSet().toList()..sort();
  return unique.length == 1 ? unique.single : 'enable-keys:${jsonEncode(unique)}';
}

/// Swift `ownTransferPairs`: a charge in one linked account and the same amount credited in another one,
/// at most two days apart, with exactly one candidate on each side, and no transfer already recorded.
List<OwnTransferPair> ownTransferPairs(Finances data) {
  bool leg(Transaction t) {
    final account = data.account(t.sourceAccountId);
    final category = data.category(t.categoryId);
    return (t.type == TransactionType.expense || t.type == TransactionType.income) &&
        t.destinationAccountId == null &&
        t.amountMinor > 0 &&
        account != null &&
        account.bankIdentityKey != null &&
        !account.isArchived &&
        t.reservedFundId == null &&
        t.reservedAmountMinor == null &&
        t.recurringMovementId == null &&
        t.externalId == null &&
        t.duplicateState == 'none' &&
        (category == null || category.kind == CategoryKind.transfer) &&
        bankKeys(t.bankEntryKey).length == 1;
  }

  final legs = data.transactions.where(leg).toList();
  final debits = legs.where((t) => t.type == TransactionType.expense).toList();
  final credits = legs.where((t) => t.type == TransactionType.income).toList();
  bool near(Transaction d, Transaction c) =>
      d.amountMinor == c.amountMinor &&
      d.sourceAccountId != c.sourceAccountId &&
      data.account(d.sourceAccountId)?.currencyCode == data.account(c.sourceAccountId)?.currencyCode &&
      d.date.difference(c.date).inSeconds.abs() <= 2 * 86400;
  final pairs = <OwnTransferPair>[];
  for (final debit in debits) {
    final options = credits.where((c) => near(debit, c)).toList();
    if (options.length != 1 || debits.where((d) => near(d, options.single)).length != 1) continue;
    final credit = options.single;
    final recorded = data.transactions.any((t) =>
        t.type == TransactionType.transfer &&
        t.amountMinor == debit.amountMinor &&
        t.sourceAccountId == debit.sourceAccountId &&
        t.destinationAccountId == credit.sourceAccountId &&
        t.date.difference(debit.date).inSeconds.abs() <= 2 * 86400);
    if (!recorded) pairs.add(OwnTransferPair(debit, credit));
  }
  pairs.sort((a, b) => a.debit.date.compareTo(b.debit.date));
  return pairs;
}

/// Swift `join`: the charge becomes the transfer (with both bank keys) and the credit leg is removed.
Operation joinOwnTransfer(OwnTransferPair pair, Finances data, DateTime now) {
  final debit = pair.debit, credit = pair.credit;
  final concept = credit.descriptionText.trim();
  var text = debit.descriptionText;
  final notes = [debit.notes, credit.notes].where((n) => n.isNotEmpty).toList();
  if (text == 'Movimiento bancario' && concept.isNotEmpty && concept != 'Movimiento bancario') {
    text = concept;
  } else if (concept.isNotEmpty && concept != text && concept != 'Movimiento bancario') {
    notes.add('Concepto bancario del otro apunte: $concept');
  }
  final category = data.category(debit.categoryId);
  return batchOperation([
    Operation('patch', {
      'id': debit.id,
      'fields': {
        'typeRaw': 'transfer',
        'destinationAccountID': credit.sourceAccountId,
        'bankEntryKey': encodedKeys([...bankKeys(debit.bankEntryKey), ...bankKeys(credit.bankEntryKey)]),
        'descriptionText': text,
        'notes': notes.join('\n\n'),
        'categoryID': category?.kind == CategoryKind.transfer ? category!.id : null,
        'isReconciled': debit.isReconciled && credit.isReconciled,
        'fingerprint': fingerprint(
            date: debit.date,
            source: debit.sourceAccountId,
            destination: credit.sourceAccountId,
            type: TransactionType.transfer,
            amountMinor: debit.amountMinor,
            description: text),
        'updatedAt': referenceSeconds(now),
      }
    }),
    deleteOperation(credit),
  ]);
}

// ---------------------------------------------------------------- Don Bigotes

class CompanionNote {
  CompanionNote({required this.id, required this.title, required this.detail, required this.tab, this.urgent = false});
  final String id;
  final String title;
  final String detail;

  /// 0 Inicio, 1 Movimientos, 2 Cuentas, 3 Presupuestos, 4 Ajustes.
  final int tab;
  final bool urgent;
}

/// What Don Bigotes points out. Never advice: only facts about the person's own data.
List<CompanionNote> companionNotes(Finances data, DateTime now, {int pendingBankReview = 0, List<BankHold> holds = const []}) {
  final notes = <CompanionNote>[];
  if (pendingBankReview > 0) {
    notes.add(CompanionNote(
        id: 'bankReview', title: 'Descarga del banco por revisar', detail: '$pendingBankReview movimientos esperan tu confirmación', tab: 4, urgent: true));
  }
  // Charges the bank holds and has not booked yet (Swift «cargos en camino»).
  final charges = holds.where((h) => h.movement.signedAmountMinor < 0).toList();
  if (charges.isNotEmpty) {
    final total = charges.fold(0, (sum, h) => sum + h.movement.signedAmountMinor);
    notes.add(CompanionNote(
        id: 'holds:${(charges.map((h) => h.id).toList()..sort()).join(',')}',
        title: charges.length == 1 ? '1 cargo en camino' : '${charges.length} cargos en camino',
        detail: 'Retenidos por el banco · ${money(total)}',
        tab: 1,
        urgent: true));
  }
  final review = data.transactions.where((t) => reviewIssues(t, data.category(t.categoryId)).isNotEmpty).length;
  if (review > 0) {
    notes.add(CompanionNote(
        id: 'review:$review',
        title: review == 1 ? '1 movimiento por revisar' : '$review movimientos por revisar',
        detail: 'Posibles duplicados o sin categoría',
        tab: 1));
  }
  final pairs = ownTransferPairs(data).length;
  if (pairs > 0) {
    notes.add(CompanionNote(
        id: 'pairs:$pairs',
        title: pairs == 1 ? '1 posible traspaso entre tus cuentas' : '$pairs posibles traspasos entre tus cuentas',
        detail: 'Un cargo y un abono del mismo importe',
        tab: 1));
  }
  final soon = now.add(const Duration(days: 3));
  final next = data.recurringMovements.where((r) => r.isActive && !r.nextDueDate.isBefore(_startOfDay(now)) && !r.nextDueDate.isAfter(soon)).firstOrNull;
  if (next != null) {
    notes.add(CompanionNote(
        id: 'recurring:${next.id}:${next.nextDueDate.millisecondsSinceEpoch}',
        title: 'Cargo previsto: ${next.name}',
        detail: '${next.nextDueDate.day}/${next.nextDueDate.month}',
        tab: 2,
        urgent: next.nextDueDate.isBefore(now.add(const Duration(days: 1)))));
  }
  final limit = now.subtract(const Duration(days: 30));
  final stale = data.accounts.where((a) => !a.isArchived && a.bankIdentityKey == null && a.lastUpdatedAt.isBefore(limit)).length;
  if (stale > 0) {
    notes.add(CompanionNote(
        id: 'stale:$stale',
        title: stale == 1 ? '1 cuenta sin actualizar' : '$stale cuentas sin actualizar',
        detail: 'Más de 30 días con el mismo saldo',
        tab: 2));
  }
  final overdue = data.transactions.where((t) => t.awaitsBank && t.date.isBefore(now.subtract(const Duration(days: 5)))).length;
  if (overdue > 0) {
    notes.add(CompanionNote(
        id: 'awaiting:$overdue',
        title: overdue == 1 ? '1 pago sigue sin llegar del banco' : '$overdue pagos siguen sin llegar del banco',
        detail: 'Apuntados al pagar hace más de 5 días',
        tab: 1));
  }
  return notes;
}
