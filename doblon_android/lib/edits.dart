// Editing movements with the same rules as the iPhone app (`TransactionFormView`, `DuplicateDetectionService`,
// `TransactionReviewService`, `CategoryRuleService.supports`). Every change is an operation on the raw cloud
// document, so it can wait in a queue while offline and be applied again on top of the latest cloud copy.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'banking.dart' show referenceSeconds;
import 'models.dart';

extension TransactionTypeTitle on TransactionType {
  String get title => switch (this) {
        TransactionType.income => 'Ingreso',
        TransactionType.expense => 'Gasto',
        TransactionType.interest => 'Interés',
        TransactionType.fee => 'Comisión',
        TransactionType.transfer => 'Transferencia',
      };
}

/// Swift `CategoryRuleService.supports`.
bool categorySupports(Category category, TransactionType type) {
  if (category.isArchived) return false;
  return switch (type) {
    TransactionType.income || TransactionType.interest => category.kind == CategoryKind.income || category.kind == CategoryKind.both,
    TransactionType.expense || TransactionType.fee => category.kind == CategoryKind.expense || category.kind == CategoryKind.both,
    TransactionType.transfer => category.kind == CategoryKind.transfer,
  };
}

enum ReviewIssue { possibleDuplicate, missingCategory, incompatibleCategory }

extension ReviewIssueTitle on ReviewIssue {
  String get title => switch (this) {
        ReviewIssue.possibleDuplicate => 'Posible duplicado',
        ReviewIssue.missingCategory => 'Sin categoría',
        ReviewIssue.incompatibleCategory => 'Categoría incompatible',
      };
}

/// Swift `TransactionReviewService.issues`. Archiving a category does not make past movements wrong.
List<ReviewIssue> reviewIssues(Transaction t, Category? category) {
  final issues = <ReviewIssue>[];
  if (t.duplicateState == 'possible') issues.add(ReviewIssue.possibleDuplicate);
  if (category == null) {
    if (t.type != TransactionType.transfer) issues.add(ReviewIssue.missingCategory);
    return issues;
  }
  final compatible = switch (t.type) {
    TransactionType.income || TransactionType.interest => category.kind == CategoryKind.income || category.kind == CategoryKind.both,
    TransactionType.expense || TransactionType.fee => category.kind == CategoryKind.expense || category.kind == CategoryKind.both,
    TransactionType.transfer => category.kind == CategoryKind.transfer,
  };
  if (!compatible) issues.add(ReviewIssue.incompatibleCategory);
  return issues;
}

const _folding = {
  'á': 'a',
  'à': 'a',
  'ä': 'a',
  'â': 'a',
  'ã': 'a',
  'é': 'e',
  'è': 'e',
  'ë': 'e',
  'ê': 'e',
  'í': 'i',
  'ì': 'i',
  'ï': 'i',
  'î': 'i',
  'ó': 'o',
  'ò': 'o',
  'ö': 'o',
  'ô': 'o',
  'õ': 'o',
  'ú': 'u',
  'ù': 'u',
  'ü': 'u',
  'û': 'u',
  'ñ': 'n',
  'ç': 'c',
};

/// Swift `DuplicateDetectionService.normalize`: no accents or case, only letters and digits, words of 2+ characters.
String normalizeText(String value) {
  final folded = value.toLowerCase().split('').map((c) => _folding[c] ?? c).join();
  return folded.replaceAll(RegExp(r'[^a-z0-9]+'), ' ').split(' ').where((w) => w.length > 1).join(' ');
}

/// Swift `DuplicateDetectionService.fingerprint`: UTC day, account IDs in upper case, type, amount, text.
String fingerprint(
    {required DateTime date,
    required String? source,
    required String? destination,
    required TransactionType type,
    required int amountMinor,
    required String description}) {
  final day = date.toUtc().toIso8601String().substring(0, 10);
  final payload =
      [day, source?.toUpperCase() ?? 'none', destination?.toUpperCase() ?? 'none', type.name, '${amountMinor.abs()}', normalizeText(description)].join('|');
  return sha256.convert(utf8.encode(payload)).toString();
}

class DuplicateCandidate {
  DuplicateCandidate(this.transaction, this.score);
  final Transaction transaction;
  final double score;
}

/// Swift `DuplicateDetectionService.candidates`: same accounts and amount, then the same fingerprint or
/// a close day with a similar text.
List<DuplicateCandidate> duplicateCandidates(
    {required DateTime date,
    required String? source,
    required String? destination,
    required TransactionType type,
    required int amountMinor,
    required String description,
    required List<Transaction> existing,
    Map<String, String> fingerprints = const {},
    String? excluding}) {
  final text = normalizeText(description);
  final target = fingerprint(date: date, source: source, destination: destination, type: type, amountMinor: amountMinor, description: description);
  DateTime dayOf(DateTime d) => DateTime(d.year, d.month, d.day);
  double similarity(String a, String b) {
    if (a == b && a.isNotEmpty) return 1;
    final left = a.split(' ').where((w) => w.isNotEmpty).toSet(), right = b.split(' ').where((w) => w.isNotEmpty).toSet();
    final union = left.union(right).length;
    return union == 0 ? 0 : left.intersection(right).length / union;
  }

  final result = <DuplicateCandidate>[];
  for (final t in existing) {
    if (t.id == excluding || t.sourceAccountId != source || t.destinationAccountId != destination || t.amountMinor.abs() != amountMinor.abs()) continue;
    final stored = fingerprints[t.id] ?? '';
    if (stored.isNotEmpty && stored == target) {
      result.add(DuplicateCandidate(t, 1));
      continue;
    }
    final days = dayOf(t.date.toLocal()).difference(dayOf(date.toLocal())).inDays.abs();
    if (days > 1) continue;
    final score =
        (0.45 + (t.type == type ? 0.15 : 0) + (days == 0 ? 0.25 : 0.12) + 0.4 * similarity(text, normalizeText(t.descriptionText))).clamp(0, 1).toDouble();
    if (score >= 0.72) result.add(DuplicateCandidate(t, score));
  }
  result.sort((a, b) => b.score.compareTo(a.score));
  return result;
}

/// Swift `TransactionReviewService.duplicateStateAfterEdit`.
String duplicateStateAfterEdit(String previous, String previousFingerprint, String newFingerprint, bool hasCandidates) =>
    previousFingerprint == newFingerprint ? previous : (hasCandidates ? 'possible' : 'none');

/// What the form collects. Validation follows the cloud's rules, so a saved change is never refused later.
class TransactionDraft {
  TransactionDraft({
    required this.date,
    required this.type,
    required this.amountMinor,
    required this.description,
    required this.sourceAccountId,
    this.destinationAccountId,
    this.categoryId,
    this.notes = '',
    this.isReconciled = false,
  });
  DateTime date;
  TransactionType type;
  int amountMinor;
  String description;
  String? sourceAccountId;
  String? destinationAccountId;
  String? categoryId;
  String notes;
  bool isReconciled;

  /// Returns the reason it cannot be saved, or null.
  String? validate(Finances data, {Transaction? editing}) {
    if (amountMinor <= 0) return 'Escribe un importe mayor que cero.';
    if (description.trim().isEmpty) return 'Escribe un concepto.';
    final source = data.account(sourceAccountId);
    if (source == null || source.isArchived) return 'Elige la cuenta.';
    if (type == TransactionType.transfer) {
      final destination = data.account(destinationAccountId);
      if (destination == null || destination.isArchived) return 'Elige la cuenta de destino.';
      if (destination.id == source.id) return 'La cuenta de origen y la de destino deben ser distintas.';
    }
    final category = data.category(categoryId);
    if (category != null && !categorySupports(category, type)) return 'Esa categoría no corresponde a este tipo de movimiento.';
    final reserved = editing?.reservedAmountMinor;
    if (editing?.reservedFundId != null) {
      if (!type.countsAsExpense) return 'Este movimiento se paga con dinero reservado: debe seguir siendo un gasto o una comisión.';
      if (reserved != null && reserved > amountMinor) return 'El importe no puede ser menor que la parte pagada con dinero reservado.';
      if (sourceAccountId != editing!.sourceAccountId) return 'Este movimiento se paga con dinero reservado: su cuenta no se puede cambiar aquí.';
    }
    return null;
  }
}

/// A change waiting to reach the cloud. Applied with `applyOperation`, also on top of a newer cloud copy.
class Operation {
  Operation(this.kind, this.data);
  final String kind; // insert, patch, delete, categorize
  final Map<String, dynamic> data;
  Map<String, dynamic> toJson() => {'kind': kind, 'data': data};
  static Operation fromJson(Map<String, dynamic> json) => Operation('${json['kind']}', Map<String, dynamic>.from(json['data'] as Map));
}

/// Builds the operation that saves a draft: a new record, or the changed fields of an existing one (so a
/// field changed meanwhile on another device and not touched here is kept).
Operation saveOperation(TransactionDraft draft, Finances data, DateTime now, {Transaction? editing, String? newId}) {
  final source = draft.sourceAccountId;
  final destination = draft.type == TransactionType.transfer ? draft.destinationAccountId : null;
  final text = draft.description.trim();
  final print = fingerprint(date: draft.date, source: source, destination: destination, type: draft.type, amountMinor: draft.amountMinor, description: text);
  final fingerprints = {for (final t in data.transactions) t.id: t.fingerprint};
  final candidates = duplicateCandidates(
      date: draft.date,
      source: source,
      destination: destination,
      type: draft.type,
      amountMinor: draft.amountMinor,
      description: text,
      existing: data.transactions,
      fingerprints: fingerprints,
      excluding: editing?.id);
  final fields = <String, dynamic>{
    'date': referenceSeconds(draft.date),
    'typeRaw': draft.type.name,
    'amountMinor': draft.amountMinor.abs(),
    'descriptionText': text,
    'notes': draft.notes,
    'isReconciled': draft.isReconciled,
    'fingerprint': print,
    'sourceAccountID': source,
    'destinationAccountID': destination,
    'categoryID': draft.categoryId,
    'updatedAt': referenceSeconds(now),
  };
  if (editing != null) {
    final previous = fingerprint(
        date: editing.date,
        source: editing.sourceAccountId,
        destination: editing.destinationAccountId,
        type: editing.type,
        amountMinor: editing.amountMinor,
        description: editing.descriptionText);
    fields['duplicateStateRaw'] = duplicateStateAfterEdit(editing.duplicateState, previous, print, candidates.isNotEmpty);
    return Operation('patch', {'id': editing.id, 'fields': fields});
  }
  return Operation('insert', {
    'record': {
      'id': newId,
      ...fields,
      'duplicateStateRaw': candidates.isEmpty ? 'none' : 'possible',
      'externalID': null,
      'importBatchID': null,
      'recurringMovementID': null,
      'reservedFundID': null,
      'reservedAmountMinor': null,
      'createdAt': referenceSeconds(now),
      'bankEntryKey': null,
    }
  });
}

/// Applies one operation to a raw cloud document (in place). Returns false when it no longer applies
/// (for example, the movement was deleted on another device), so it can be dropped.
bool applyOperation(Map<String, dynamic> document, Operation op) {
  final rows = ((document['transactions'] ??= <dynamic>[]) as List);
  int indexOf(Object? id) => rows.indexWhere((r) => r is Map && '${r['id']}'.toLowerCase() == '$id'.toLowerCase());
  switch (op.kind) {
    case 'insert':
      final record = Map<String, dynamic>.from(op.data['record'] as Map);
      if (indexOf(record['id']) >= 0) return false;
      rows.add(record);
      return true;
    case 'patch':
      final index = indexOf(op.data['id']);
      if (index < 0) return false;
      (rows[index] as Map).addAll(Map<String, dynamic>.from(op.data['fields'] as Map));
      return true;
    case 'delete':
      final index = indexOf(op.data['id']);
      if (index < 0) return false;
      rows.removeAt(index);
      return true;
    case 'categorize':
      var applied = false;
      for (final id in (op.data['ids'] as List)) {
        final index = indexOf(id);
        if (index < 0) continue;
        (rows[index] as Map)
          ..['categoryID'] = op.data['categoryId']
          ..['updatedAt'] = op.data['updatedAt'];
        applied = true;
      }
      return applied;
    default:
      return false;
  }
}

/// The cloud copy with every pending change applied, as a new document.
Map<String, dynamic> withPending(Map<String, dynamic> document, List<Operation> pending) {
  final copy = jsonDecode(jsonEncode(document)) as Map<String, dynamic>;
  for (final op in pending) {
    applyOperation(copy, op);
  }
  return copy;
}

/// Categorizing several movements: only those whose type the category supports.
Operation categorizeOperation(List<Transaction> selected, Category category, DateTime now) => Operation('categorize', {
      'ids': [
        for (final t in selected)
          if (categorySupports(category, t.type)) t.id
      ],
      'categoryId': category.id,
      'updatedAt': referenceSeconds(now),
    });

/// "Keep it: it is not a duplicate" (Swift sets the state back to none).
Operation notDuplicateOperation(Transaction t, DateTime now) => Operation('patch', {
      'id': t.id,
      'fields': {'duplicateStateRaw': 'none', 'updatedAt': referenceSeconds(now)}
    });

Operation deleteOperation(Transaction t) => Operation('delete', {'id': t.id});
