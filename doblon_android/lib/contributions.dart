import 'banking.dart';
import 'edits.dart';
import 'models.dart';

/// The same period and exact-sum recognition as RecurringMovementService and ContributionRecognition
/// in Swift. Amounts, number of fragments, accounts and calendar intervals come from the person's rule.
(DateTime, DateTime) contributionPeriod(RecurringMovement rule, DateTime date) {
  final step = rule.interval *
      (rule.frequency == Frequency.yearly
          ? 12
          : rule.frequency == Frequency.quarterly
              ? 3
              : 1);
  if (rule.frequency == Frequency.weekly) {
    DateTime monday(DateTime d) => DateTime(d.year, d.month, d.day - d.weekday + 1);
    final anchor = monday(rule.nextDueDate), current = monday(date);
    final weeks = DateTime.utc(current.year, current.month, current.day).difference(DateTime.utc(anchor.year, anchor.month, anchor.day)).inDays ~/ 7;
    final offset = weeks - weeks % step;
    final start = DateTime(anchor.year, anchor.month, anchor.day + offset * 7);
    return (start, DateTime(start.year, start.month, start.day + step * 7));
  }
  final distance = monthKey(date) - monthKey(rule.nextDueDate);
  final start = DateTime(rule.nextDueDate.year, rule.nextDueDate.month + distance - distance % step);
  return (start, DateTime(start.year, start.month + step));
}

class ContributionProposal {
  ContributionProposal(this.rule, this.start, this.end, this.remaining, this.candidates, this.planned, this.suggested);
  final RecurringMovement rule;
  final DateTime start, end;
  final int remaining;
  final List<Transaction> candidates, planned;
  final Set<String>? suggested;
  String get id => '${rule.id}|${start.millisecondsSinceEpoch}';
  String get signature => [
        id,
        '${rule.amountMinor}',
        rule.sourceAccountId,
        rule.destinationAccountId,
        '$remaining',
        for (final t in [...candidates, ...planned])
          '${t.id}|${t.updatedAt.millisecondsSinceEpoch}|${t.date.millisecondsSinceEpoch}|${t.amountMinor}|${t.type.name}|${t.sourceAccountId}|${t.destinationAccountId}|${t.bankEntryKey}|${t.notes}|${t.categoryId}|${t.reservedFundId}|${t.reservedAmountMinor}'
      ].join('\n');
}

/// null means more than one combination or a bounded search requiring the person's selection.
Set<String>? contributionCombination(List<Transaction> rows, int remaining) {
  final sums = <int, List<Set<String>>>{
    0: [<String>{}]
  };
  if (rows.length > 60) return null;
  for (final row in rows) {
    final previous = {for (final entry in sums.entries) entry.key: List<Set<String>>.from(entry.value)};
    for (final entry in previous.entries) {
      final sum = entry.key + row.amountMinor;
      if (sum > remaining) continue;
      final alternatives = sums.putIfAbsent(sum, () => []);
      for (final group in entry.value) {
        if (alternatives.length < 2) alternatives.add({...group, row.id});
      }
    }
    if (sums.length > 5000) return null;
  }
  final matches = sums[remaining];
  if (matches == null) return <String>{};
  return matches.length == 1 ? matches.single : null;
}

List<ContributionProposal> contributionProposals(Finances data, DateTime now) {
  final proposals = <ContributionProposal>[];
  for (final rule in data.recurringMovements) {
    final source = data.account(rule.sourceAccountId), destination = data.account(rule.destinationAccountId);
    if (!rule.isActive ||
        rule.type != TransactionType.transfer ||
        rule.amountMinor <= 0 ||
        rule.interval > 120 ||
        source == null ||
        destination == null ||
        source.id == destination.id ||
        source.isArchived ||
        destination.isArchived ||
        source.type == AccountType.investment ||
        source.type.isLiability ||
        destination.type != AccountType.investment ||
        source.currencyCode != destination.currencyCode) {
      continue;
    }
    final groups = <DateTime, List<Transaction>>{};
    for (final row in data.transactions) {
      if (row.type != TransactionType.expense ||
          row.sourceAccountId != source.id ||
          row.destinationAccountId != null ||
          row.bankEntryKey == null ||
          row.recurringMovementId != null ||
          row.reservedFundId != null ||
          row.reservedAmountMinor != null ||
          row.duplicateState == 'possible' ||
          row.amountMinor <= 0 ||
          row.amountMinor > rule.amountMinor ||
          row.date.isAfter(now) ||
          row.date.isBefore(source.openingDate) ||
          row.date.isBefore(destination.openingDate) ||
          (rule.endDate != null && DateTime(row.date.year, row.date.month, row.date.day).isAfter(rule.endDate!))) {
        continue;
      }
      final (start, _) = contributionPeriod(rule, row.date);
      (groups[start] ??= []).add(row);
    }
    for (final group in groups.entries) {
      final (start, end) = contributionPeriod(rule, group.key);
      final existing = data.transactions
          .where((t) =>
              t.type == TransactionType.transfer &&
              t.sourceAccountId == source.id &&
              t.destinationAccountId == destination.id &&
              !t.date.isBefore(start) &&
              t.date.isBefore(end))
          .toList();
      final planned = existing
          .where((t) =>
              t.recurringMovementId == rule.id && t.bankEntryKey == null && t.externalId == null && t.reservedFundId == null && t.reservedAmountMinor == null)
          .toList();
      final plannedIds = planned.map((t) => t.id).toSet();
      final actual = existing.where((t) => !plannedIds.contains(t.id)).fold(0, (sum, t) => sum + t.amountMinor);
      final remaining = rule.amountMinor - actual;
      if (remaining <= 0) continue;
      final plannedAmount = planned.fold(0, (sum, t) => sum + t.amountMinor);
      if (planned.isNotEmpty && plannedAmount != remaining && plannedAmount != rule.amountMinor) continue;
      final rows = group.value..sort((a, b) => a.id.compareTo(b.id));
      final selected = contributionCombination(rows, remaining);
      if (selected != null && selected.isEmpty) continue;
      proposals.add(ContributionProposal(rule, start, end, remaining, rows, planned, selected));
    }
  }
  return proposals..sort((a, b) => b.start.compareTo(a.start));
}

/// Revalidated against the current cloud copy before converting the bank postings and removing the
/// unconfirmed scheduled entries together. Their bank keys survive repeated downloads.
Operation confirmContribution(ContributionProposal proposal, Set<String> ids, Finances data, DateTime now) {
  final current = contributionProposals(data, now).where((p) => p.id == proposal.id).firstOrNull;
  if (current == null || current.signature != proposal.signature || ids.isEmpty || !ids.every((id) => current.candidates.any((t) => t.id == id))) {
    throw BankingError('cloud_conflict');
  }
  final selected = current.candidates.where((t) => ids.contains(t.id)).toList();
  if (selected.fold(0, (sum, t) => sum + t.amountMinor) != current.remaining) throw BankingError('cloud_conflict');
  if (selected.any((debit) => data.transactions.any((t) =>
      t.type == TransactionType.income &&
      t.sourceAccountId == current.rule.destinationAccountId &&
      t.amountMinor == debit.amountMinor &&
      t.date.year == debit.date.year &&
      t.date.month == debit.date.month &&
      t.date.day == debit.date.day))) {
    throw BankingError('contribution_transfer_review');
  }
  final notes = current.planned.map((t) => t.notes).where((n) => n.isNotEmpty).join('\n\n');
  return batchOperation([
    for (final t in selected)
      Operation('patch', {
        'id': t.id,
        'fields': {
          'typeRaw': 'transfer',
          'destinationAccountID': current.rule.destinationAccountId,
          'recurringMovementID': current.rule.id,
          'updatedAt': referenceSeconds(now),
          'categoryID': data.category(t.categoryId)?.kind == CategoryKind.transfer ? t.categoryId : null,
          'notes': [t.notes, notes].where((n) => n.isNotEmpty).join('\n\n'),
          'fingerprint': fingerprint(
              date: t.date,
              source: t.sourceAccountId,
              destination: current.rule.destinationAccountId,
              type: TransactionType.transfer,
              amountMinor: t.amountMinor,
              description: t.descriptionText),
        }
      }),
    for (final t in current.planned) deleteOperation(t),
  ]);
}
