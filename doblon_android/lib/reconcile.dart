// Reconciling movements that are the same money recorded more than once (18 November 2026).
//
// Three situations, told apart before anything is joined:
//   A. The same bank entry twice: a movement typed by hand and its bank entry, or a bank entry repeated. They are
//      joined into one record that keeps every bank reference, the person's concept, notes, category and links.
//   B. The two sides of a transfer between own accounts: the charge in one bank and the credit in the other. They
//      become one transfer with both bank references (also when one side was already turned into a transfer).
//   C. Different operations with the same amount (two bank entries of the same account, or amounts that only add
//      up): never joined. Amounts that only match by adding several movements are not proposed.
// Keeping every bank reference is what stops a later download from creating the joined entries again (the import
// skips known keys). Each join keeps the original records on this device, so it can be undone.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'automation.dart' show bankKeys, encodedKeys, ownTransferPairs;
import 'banking.dart' show accountIdentity, referenceSeconds;
import 'edits.dart';
import 'finance.dart' show fundEntries, reservedBalances;
import 'models.dart';

/// The local account a bank key comes from (`enable-entry:<server>:<remote account>:<reference>`), if linked.
String? keyAccountId(String key, Finances data) {
  final parts = key.split(':');
  if (parts.length < 4 || parts.first != 'enable-entry') return null;
  final identity = accountIdentity(parts[2]);
  return data.accounts.where((a) => a.bankIdentityKey == identity).firstOrNull?.id;
}

/// The accounts whose bank reported a record (one per bank side it already contains).
Set<String> bankSides(Transaction t, Finances data) => {
      for (final key in bankKeys(t.bankEntryKey))
        if (keyAccountId(key, data) case final id?) id
    };

enum MatchKind { duplicate, transfer }

class MatchCase {
  MatchCase(this.kind, this.first, this.second);
  final MatchKind kind;
  final Transaction first, second;

  /// Stable, whatever the order: used to remember «Mantener separados».
  String get id => 'keep:${([first.id, second.id]..sort()).join('|')}';
}

/// The same bank entry downloaded twice with two references (the bank re-identified it between downloads,
/// 26/11/2026): same account, day, type, amount and concept, arrived in different downloads (at least 30 minutes
/// apart) and with no reference in common. Only proposed, never joined alone: two equal payments on one day exist.
bool rereported(Transaction a, Transaction b) {
  if (a.id == b.id || !a.isBanking || !b.isBanking) return false;
  if (a.sourceAccountId != b.sourceAccountId || a.destinationAccountId != b.destinationAccountId || a.type != b.type || a.amountMinor != b.amountMinor) return false;
  final da = a.date.toUtc(), db = b.date.toUtc();
  if (da.year != db.year || da.month != db.month || da.day != db.day) return false;
  if (normalizeText(a.descriptionText) != normalizeText(b.descriptionText)) return false;
  if (bankKeys(a.bankEntryKey).toSet().intersection(bankKeys(b.bankEntryKey).toSet()).isNotEmpty) return false;
  return a.createdAt.difference(b.createdAt).inMinutes.abs() >= 30;
}

/// Bank entries that may have been downloaded twice (`rereported`), for the person to confirm or keep apart.
List<MatchCase> rereportedCases(Finances data, {Set<String> keptApart = const {}}) {
  // Only records of the same account, day and amount are compared.
  final groups = <String, List<Transaction>>{};
  for (final t in data.transactions.where((t) => t.isBanking)) {
    final d = t.date.toUtc();
    (groups['${t.sourceAccountId}|${d.year}-${d.month}-${d.day}|${t.amountMinor}'] ??= []).add(t);
  }
  final cases = <MatchCase>[];
  for (final bank in groups.values.where((g) => g.length > 1)) {
    for (var i = 0; i < bank.length; i++) {
      for (var j = i + 1; j < bank.length; j++) {
        if (!rereported(bank[i], bank[j])) continue;
        // The older record stays (it may have the person's edits); the later download is the one joined into it.
        final (first, second) = bank[i].createdAt.isBefore(bank[j].createdAt) ? (bank[i], bank[j]) : (bank[j], bank[i]);
        final c = MatchCase(MatchKind.duplicate, first, second);
        if (!keptApart.contains(c.id)) cases.add(c);
      }
    }
  }
  return cases;
}

/// Why two records cannot be joined, or null when they can (with the kind of join).
({MatchKind? kind, String? blocked}) classify(Transaction a, Transaction b, Finances data) {
  if (a.id == b.id) return (kind: null, blocked: 'Es el mismo movimiento.');
  if (a.amountMinor != b.amountMinor) return (kind: null, blocked: 'Los importes no coinciden. No se unen movimientos porque sus importes sumen.');
  final ca = data.account(a.sourceAccountId)?.currencyCode, cb = data.account(b.sourceAccountId)?.currencyCode;
  if (ca != cb) return (kind: null, blocked: 'Las cuentas tienen monedas distintas.');
  if (a.reservedFundId != null && b.reservedFundId != null && a.reservedFundId != b.reservedFundId) {
    return (kind: null, blocked: 'Cada uno usa una reserva distinta: ajústalas antes de unirlos.');
  }
  if (a.recurringMovementId != null && b.recurringMovementId != null && a.recurringMovementId != b.recurringMovementId) {
    return (kind: null, blocked: 'Pertenecen a dos movimientos periódicos distintos.');
  }
  if (a.date.difference(b.date).inDays.abs() > 7) return (kind: null, blocked: 'Hay más de una semana entre ellos.');
  // The same entry the bank reported again with a new reference: joined only because the person confirms it.
  if (rereported(a, b)) return (kind: MatchKind.duplicate, blocked: null);
  // Two entries of the same bank account are two operations the bank reported (C), never the same one.
  final sa = bankSides(a, data), sb = bankSides(b, data);
  if (sa.intersection(sb).isNotEmpty) return (kind: null, blocked: 'Los dos vienen del mismo banco y cuenta: son operaciones distintas.');
  final da = _direction(a), db = _direction(b);
  if (da == null || db == null) return (kind: null, blocked: 'Solo se unen gastos, ingresos y traspasos.');
  // Same account and same direction: the same entry twice (A).
  if (a.type == b.type && a.sourceAccountId == b.sourceAccountId && a.destinationAccountId == b.destinationAccountId) {
    return (kind: a.type == TransactionType.transfer ? MatchKind.transfer : MatchKind.duplicate, blocked: null);
  }
  // A charge and a credit (or transfers) between two own accounts: the two sides of one transfer (B).
  final from = {da.$1, db.$1}..remove(null), to = {da.$2, db.$2}..remove(null);
  if (from.length == 1 && to.length == 1 && from.single != to.single) {
    final source = data.account(from.single), target = data.account(to.single);
    if (source == null || target == null) return (kind: null, blocked: 'Falta una de las cuentas.');
    return (kind: MatchKind.transfer, blocked: null);
  }
  return (kind: null, blocked: 'No son el mismo movimiento ni las dos partes de un traspaso entre tus cuentas.');
}

/// (account the money leaves, account it reaches); null where a side is unknown.
(String?, String?)? _direction(Transaction t) => switch (t.type) {
      TransactionType.expense || TransactionType.fee => (t.sourceAccountId, null),
      TransactionType.income || TransactionType.interest => (null, t.sourceAccountId),
      TransactionType.transfer => (t.sourceAccountId, t.destinationAccountId),
    };

/// Transfers recorded twice: a transfer and the other side of the same money (another transfer reported by the
/// other bank, or the charge or credit still as an expense or income). One candidate on each side only.
List<MatchCase> sameTransferCases(Finances data, {Set<String> keptApart = const {}}) {
  bool near(Transaction a, Transaction b) => a.amountMinor == b.amountMinor && a.date.difference(b.date).inSeconds.abs() <= 2 * 86400;
  final transfers = data.transactions.where((t) => t.type == TransactionType.transfer && t.destinationAccountId != null).toList();
  List<Transaction> others(Transaction t) {
    final sides = bankSides(t, data);
    if (sides.containsAll({t.sourceAccountId, t.destinationAccountId})) return const []; // Already has both sides.
    return data.transactions.where((o) {
      if (o.id == t.id || !near(t, o)) return false;
      final os = bankSides(o, data);
      if (os.isEmpty || os.intersection(sides).isNotEmpty) return false; // The other side must come from the other bank.
      final missing = sides.contains(t.sourceAccountId) ? t.destinationAccountId : t.sourceAccountId;
      if (!os.contains(missing)) return false;
      return switch (o.type) {
        TransactionType.transfer => o.sourceAccountId == t.sourceAccountId && o.destinationAccountId == t.destinationAccountId,
        TransactionType.expense || TransactionType.fee => o.sourceAccountId == t.sourceAccountId && missing == t.sourceAccountId,
        TransactionType.income || TransactionType.interest => o.sourceAccountId == t.destinationAccountId && missing == t.destinationAccountId,
      };
    }).toList();
  }

  final cases = <MatchCase>[];
  final seen = <String>{};
  for (final t in transfers) {
    if (bankSides(t, data).isEmpty) continue; // A transfer typed by hand is matched by hand, never by amount alone.
    final candidates = others(t);
    if (candidates.length != 1) continue;
    final other = candidates.single;
    if (other.type == TransactionType.transfer && others(other).length != 1) continue;
    final c = MatchCase(MatchKind.transfer, t, other);
    if (keptApart.contains(c.id) || !seen.add(c.id)) continue;
    if (classify(t, other, data).kind == null) continue;
    cases.add(c);
  }
  return cases;
}

/// Everything that may be the same money twice: own-transfer charge and credit, transfers recorded twice, and the
/// movements marked as possible duplicates with their most likely match.
List<MatchCase> matchCases(Finances data, {Set<String> keptApart = const {}}) {
  final cases = <MatchCase>[
    for (final p in ownTransferPairs(data))
      if (MatchCase(MatchKind.transfer, p.debit, p.credit) case final c when !keptApart.contains(c.id)) c,
    ...sameTransferCases(data, keptApart: keptApart),
    ...rereportedCases(data, keptApart: keptApart),
  ];
  final fingerprints = {for (final t in data.transactions) t.id: t.fingerprint};
  for (final t in data.transactions.where((t) => t.duplicateState == 'possible')) {
    final candidate = duplicateCandidates(
            date: t.date,
            source: t.sourceAccountId,
            destination: t.destinationAccountId,
            type: t.type,
            amountMinor: t.amountMinor,
            description: t.descriptionText,
            existing: data.transactions,
            fingerprints: fingerprints,
            excluding: t.id)
        .map((c) => c.transaction)
        .where((o) => classify(t, o, data).kind != null)
        .firstOrNull;
    if (candidate == null) continue;
    final c = MatchCase(classify(t, candidate, data).kind!, t, candidate);
    if (!keptApart.contains(c.id) && !cases.any((x) => x.id == c.id)) cases.add(c);
  }
  return cases;
}

/// What each record moves in each account: + money in, − money out.
Map<String, int> effects(Iterable<Transaction> records) {
  final result = <String, int>{};
  void add(String? account, int delta) {
    if (account != null) result[account] = (result[account] ?? 0) + delta;
  }

  for (final t in records) {
    final (from, to) = _direction(t) ?? (null, null);
    add(from, -t.amountMinor);
    add(to, t.amountMinor);
  }
  return result;
}

const _generic = {'movimiento bancario', ''};

/// The joined record: the one to keep (the transfer, otherwise the one with a bank reference, otherwise the older)
/// takes every bank reference, the person's concept, both notes and any category, reserve or periodic link.
({Transaction kept, Transaction removed, Map<String, dynamic> fields}) joined(MatchCase c, Finances data, DateTime now) {
  int rank(Transaction t) => (t.type == TransactionType.transfer ? 4 : 0) + (bankKeys(t.bankEntryKey).isNotEmpty ? 2 : 0);
  final pair = [c.first, c.second]..sort((x, y) => rank(y) != rank(x) ? rank(y) - rank(x) : x.date.compareTo(y.date));
  final kept = pair.first, removed = pair.last;
  final (dk, dr) = (_direction(kept)!, _direction(removed)!);
  final source = c.kind == MatchKind.transfer ? (dk.$1 ?? dr.$1) : kept.sourceAccountId;
  final destination = c.kind == MatchKind.transfer ? (dk.$2 ?? dr.$2) : kept.destinationAccountId;
  // The person's words win over a bank's generic text; the other text stays in the notes.
  final typedFirst = [removed, kept].where((t) => !t.isBanking).followedBy([kept, removed]);
  final text = typedFirst.map((t) => t.descriptionText.trim()).firstWhere((s) => !_generic.contains(s.toLowerCase()), orElse: () => kept.descriptionText);
  final notes = <String>{
    for (final t in [kept, removed])
      if (t.notes.trim().isNotEmpty) t.notes.trim(),
    for (final t in [kept, removed])
      if (t.descriptionText.trim() != text && !_generic.contains(t.descriptionText.trim().toLowerCase()))
        'Concepto del otro apunte: ${t.descriptionText.trim()}',
  };
  final category = data.category(kept.categoryId) ?? data.category(removed.categoryId);
  final type = c.kind == MatchKind.transfer ? TransactionType.transfer : kept.type;
  final keepCategory = category != null && categorySupports(category, type);
  final reserveFrom = kept.reservedFundId != null ? kept : (removed.reservedFundId != null ? removed : null);
  final fields = <String, dynamic>{
    'typeRaw': type.name,
    'sourceAccountID': source,
    'destinationAccountID': type == TransactionType.transfer ? destination : null,
    'bankEntryKey': () {
      final keys = [...bankKeys(kept.bankEntryKey), ...bankKeys(removed.bankEntryKey)];
      return keys.isEmpty ? null : encodedKeys(keys);
    }(),
    'descriptionText': text,
    'notes': notes.join('\n\n'),
    'categoryID': keepCategory ? category.id : null,
    'reservedFundID': reserveFrom?.reservedFundId,
    'reservedAmountMinor': reserveFrom?.reservedAmountMinor,
    'recurringMovementID': kept.recurringMovementId ?? removed.recurringMovementId,
    'externalID': null,
    'isReconciled': kept.isReconciled || removed.isReconciled || kept.isBanking || removed.isBanking,
    'duplicateStateRaw': 'none',
    'fingerprint': fingerprint(
        date: kept.date,
        source: source,
        destination: type == TransactionType.transfer ? destination : null,
        type: type,
        amountMinor: kept.amountMinor,
        description: text),
    'updatedAt': referenceSeconds(now),
  };
  return (kept: kept, removed: removed, fields: fields);
}

/// The join as one change, and what is needed to undo it (the two original records as they were).
({Operation op, MergeTrace trace})? joinOperation(MatchCase c, Finances data, Map<String, dynamic> document, DateTime now) {
  if (classify(c.first, c.second, data).kind == null) return null;
  final j = joined(c, data, now);
  final keptRaw = rawRecord(document, 'transactions', j.kept.id), removedRaw = rawRecord(document, 'transactions', j.removed.id);
  if (keptRaw == null || removedRaw == null) return null;
  return (
    op: batchOperation([
      Operation('patch', {'id': j.kept.id, 'fields': j.fields}),
      deleteOperation(j.removed),
    ]),
    trace: MergeTrace(at: now, kind: c.kind, kept: keptRaw, removed: removedRaw),
  );
}

/// The two records of a join as they were before it.
class MergeTrace {
  MergeTrace({required this.at, required this.kind, required this.kept, required this.removed});
  final DateTime at;
  final MatchKind kind;
  final Map<String, dynamic> kept, removed;

  String get keptId => '${kept['id']}';

  Map<String, dynamic> toJson() => {'at': at.millisecondsSinceEpoch, 'kind': kind.name, 'kept': kept, 'removed': removed};
  static MergeTrace fromJson(Map<String, dynamic> j) => MergeTrace(
      at: DateTime.fromMillisecondsSinceEpoch((j['at'] as num).toInt()),
      kind: MatchKind.values.byName('${j['kind']}'),
      kept: Map<String, dynamic>.from(j['kept'] as Map),
      removed: Map<String, dynamic>.from(j['removed'] as Map));

  /// Puts both records back as they were: the kept one with its original fields and the removed one again, with
  /// its own bank reference, so a later download recognises each one and creates neither.
  Operation undo(DateTime now) => batchOperation([
        Operation('patch', {
          'id': keptId,
          'fields': {
            for (final e in kept.entries)
              if (e.key != 'id' && e.key != 'createdAt') e.key: e.value,
            'updatedAt': referenceSeconds(now),
          }
        }),
        Operation('insert', {
          'record': {...removed, 'updatedAt': referenceSeconds(now)}
        }),
      ]);
}

/// Joins done on this device (to undo them) and the pairs the person said are different (not proposed again).
class ReconcileStore {
  ReconcileStore._();
  static final instance = ReconcileStore._();

  List<MergeTrace> history = [];
  Set<String> keptApart = {};

  Future<void> load() async {
    final prefs = await SharedPreferences.getInstance();
    keptApart = (prefs.getStringList('reconcileKeptApart') ?? const []).toSet();
    try {
      history = [for (final j in jsonDecode(prefs.getString('reconcileHistory') ?? '[]') as List) MergeTrace.fromJson(Map<String, dynamic>.from(j as Map))];
    } catch (_) {
      history = [];
    }
  }

  Future<void> _save() async {
    final prefs = await SharedPreferences.getInstance();
    await prefs.setStringList('reconcileKeptApart', keptApart.toList());
    // The last 50 joins are enough to undo a mistake.
    if (history.length > 50) history = history.sublist(history.length - 50);
    await prefs.setString('reconcileHistory', jsonEncode([for (final t in history) t.toJson()]));
  }

  Future<void> remember(MergeTrace trace) async {
    history = [...history, trace];
    await _save();
  }

  Future<void> forget(MergeTrace trace) async {
    history = history.where((t) => !identical(t, trace)).toList();
    await _save();
  }

  Future<void> keepApart(MatchCase c) => keepApartId(c.id);

  /// Any proposal the person answered «no» to (a pair, or a payment that is not from a reserve).
  Future<void> keepApartId(String id) async {
    keptApart = {...keptApart, id};
    await _save();
  }
}

/// A payment that looks like the earlier ones made with a reserve (the same amount, or the same category and concept):
/// proposed to be paid with it, never linked on its own. Only what the reserve has in that account at that date.
class ReservePaymentCase {
  ReservePaymentCase(this.payment, this.fund, this.amountMinor);
  final Transaction payment;
  final ReservedFund fund;
  final int amountMinor;
  String get id => 'reserve:${payment.id}:${fund.id}';
}

List<ReservePaymentCase> reservePaymentCases(Finances data, {Set<String> keptApart = const {}}) {
  final paidWith = [
    for (final t in data.transactions)
      if (t.type.countsAsExpense && t.reservedFundId != null) t
  ];
  if (paidWith.isEmpty) return const [];
  final cases = <ReservePaymentCase>[];
  for (final t in data.transactions) {
    if (!t.type.countsAsExpense || t.reservedFundId != null || t.sourceAccountId == null) continue;
    for (final fund in data.reservedFunds) {
      if (fund.accountId == null) continue;
      final like = paidWith.any((p) =>
          p.reservedFundId == fund.id &&
          p.id != t.id &&
          (p.amountMinor == t.amountMinor ||
              (p.categoryId != null && p.categoryId == t.categoryId && normalizeText(p.descriptionText) == normalizeText(t.descriptionText))));
      if (!like) continue;
      final c = ReservePaymentCase(t, fund, 0);
      if (keptApart.contains(c.id)) continue;
      final available = reservedBalances(fund.accountId!, fund.amountMinor, fundEntries(fund, data.transactions), through: t.date)?[t.sourceAccountId] ?? 0;
      if (available <= 0) continue;
      cases.add(ReservePaymentCase(t, fund, available < t.amountMinor ? available : t.amountMinor));
      break;
    }
  }
  return cases;
}

/// Pays the movement with the reserve (the covered part; the rest still counts as everyday spending).
Operation payWithReserve(ReservePaymentCase c, DateTime now) => Operation('patch', {
      'id': c.payment.id,
      'fields': {'reservedFundID': c.fund.id, 'reservedAmountMinor': c.amountMinor, 'updatedAt': referenceSeconds(now)}
    });
