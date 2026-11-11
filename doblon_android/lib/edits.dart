// Editing movements with the same rules as the iPhone app (`TransactionFormView`, `DuplicateDetectionService`,
// `TransactionReviewService`, `CategoryRuleService.supports`). Every change is an operation on the raw cloud
// document, so it can wait in a queue while offline and be applied again on top of the latest cloud copy.
import 'dart:convert';

import 'package:crypto/crypto.dart';

import 'banking.dart' show referenceSeconds;
import 'finance.dart' show ReservedEntry, reservedBalances;
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
    this.reservedFundId,
    this.reservedAmountMinor,
  });

  /// Part paid with money set aside (a reserve), as on the iPhone.
  String? reservedFundId;
  int? reservedAmountMinor;
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
    final fundId = reservedFundId;
    if (fundId != null) {
      final reserved = reservedAmountMinor ?? 0;
      if (!type.countsAsExpense) return 'Este movimiento se paga con dinero reservado: debe ser un gasto o una comisión.';
      if (reserved <= 0) return 'Escribe la parte pagada con dinero reservado.';
      if (reserved > amountMinor) return 'El importe no puede ser menor que la parte pagada con dinero reservado.';
      final fund = data.reservedFunds.where((f) => f.id == fundId).firstOrNull;
      if (fund == null || fund.accountId == null) return 'Esa reserva ya no existe.';
      // Swift `reserveHistoryIsValid`: with this payment, every payment and move of the reserve stays covered.
      final entries = [
        for (final t in data.transactions)
          if (t.id != editing?.id &&
              t.reservedFundId == fundId &&
              (t.type.countsAsExpense || t.type == TransactionType.transfer) &&
              t.sourceAccountId != null &&
              t.reservedAmountMinor != null)
            ReservedEntry(
                id: t.id,
                date: t.date,
                source: t.sourceAccountId!,
                destination: t.type == TransactionType.transfer ? t.destinationAccountId : null,
                amount: t.reservedAmountMinor!),
        ReservedEntry(id: editing?.id ?? 'nuevo', date: date, source: sourceAccountId!, amount: reserved),
      ];
      if (reservedBalances(fund.accountId!, fund.amountMinor, entries) == null) {
        return 'No hay suficiente dinero de esa reserva en esta cuenta en esa fecha.';
      }
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
    'reservedFundID': draft.type.countsAsExpense ? draft.reservedFundId : null,
    'reservedAmountMinor': draft.type.countsAsExpense && draft.reservedFundId != null ? draft.reservedAmountMinor : null,
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
      'createdAt': referenceSeconds(now),
      'bankEntryKey': null,
    }
  });
}

/// Applies one operation to a raw cloud document (in place). Returns false when it no longer applies
/// (for example, the movement was deleted on another device), so it can be dropped.
bool applyOperation(Map<String, dynamic> document, Operation op) {
  // Always a general list, as it comes from the cloud, so records of any map type can be replaced.
  List<dynamic> entityList(String entity) => document[entity] = List<dynamic>.from((document[entity] as List?) ?? const []);
  final rows = entityList('transactions');
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
      rows[index] = <String, dynamic>{...Map<String, dynamic>.from(rows[index] as Map), ...Map<String, dynamic>.from(op.data['fields'] as Map)};
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
        rows[index] = <String, dynamic>{
          ...Map<String, dynamic>.from(rows[index] as Map),
          'categoryID': op.data['categoryId'],
          'updatedAt': op.data['updatedAt'],
        };
        applied = true;
      }
      return applied;
    case 'upsert':
      // Any entity: new record, or the given fields of an existing one (other fields are kept).
      final entity = '${op.data['entity']}';
      final list = entityList(entity);
      final record = Map<String, dynamic>.from(op.data['record'] as Map);
      final at = list.indexWhere((r) => r is Map && '${r['id']}'.toLowerCase() == '${record['id']}'.toLowerCase());
      if (at >= 0) {
        list[at] = <String, dynamic>{...Map<String, dynamic>.from(list[at] as Map), ...record};
      } else {
        if (op.data['create'] != true) return false;
        list.add(record);
      }
      return true;
    case 'remove':
      final list = entityList('${op.data['entity']}');
      final before = list.length;
      list.removeWhere((r) => r is Map && '${r['id']}'.toLowerCase() == '${op.data['id']}'.toLowerCase());
      return list.length != before;
    case 'batch':
      var any = false;
      for (final item in (op.data['ops'] as List)) {
        any = applyOperation(document, Operation.fromJson(Map<String, dynamic>.from(item as Map))) || any;
      }
      return any;
    default:
      return false;
  }
}

/// Creates or updates a record of any entity ("accounts", "cards", "budgets"…). `create` is false for an
/// edit: if the record was deleted on another device meanwhile, it is not brought back.
Operation upsertOperation(String entity, Map<String, dynamic> record, {required bool create}) =>
    Operation('upsert', {'entity': entity, 'record': record, 'create': create});

Operation removeOperation(String entity, String id) => Operation('remove', {'entity': entity, 'id': id});

/// Several changes that only make sense together (they are uploaded in the same save).
Operation batchOperation(List<Operation> ops) => Operation('batch', {
      'ops': [for (final op in ops) op.toJson()]
    });

/// The raw record of an entity in a document, to edit it without losing fields this app does not know.
Map<String, dynamic>? rawRecord(Map<String, dynamic>? document, String entity, String? id) {
  if (document == null || id == null) return null;
  for (final r in (document[entity] as List?) ?? const []) {
    if (r is Map && '${r['id']}'.toLowerCase() == id.toLowerCase()) return Map<String, dynamic>.from(r);
  }
  return null;
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
