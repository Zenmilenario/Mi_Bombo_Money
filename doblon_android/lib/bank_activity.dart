// What the bank reported in the last query of each linked account, besides the booked movements:
// balances, holds and pending entries, and a diagnostic of what it sent (Swift `BankingAccountActivity`).
// Kept on this device only, outside accounting, the cloud and backups. Holds stay visible after reopening
// the app until the next download replaces them, for up to 7 days.

import 'dart:convert';
import 'dart:io';

import 'models.dart';

class PendingMovement {
  const PendingMovement({this.id, this.date, required this.signedAmountMinor, required this.currency, required this.description, required this.status});
  final String? id;

  /// "yyyy-MM-dd" as the bank sends it, or null.
  final String? date;
  final int signedAmountMinor;
  final String currency;
  final String description;

  /// HOLD (retained) or PDNG (pending).
  final String status;

  bool get isHold => status == 'HOLD';

  static PendingMovement fromJson(Map<String, dynamic> j) => PendingMovement(
      id: j['id'] as String?,
      date: j['date'] as String?,
      signedAmountMinor: (j['signedAmountMinor'] as num?)?.toInt() ?? 0,
      currency: '${j['currency'] ?? ''}',
      description: '${j['description'] ?? ''}',
      status: '${j['status'] ?? ''}');
  Map<String, dynamic> toJson() =>
      {'id': id, 'date': date, 'signedAmountMinor': signedAmountMinor, 'currency': currency, 'description': description, 'status': status};
}

class RecentMovement {
  const RecentMovement(this.bookingDate, this.signedAmountMinor, this.currency, this.description);
  final String bookingDate;
  final int signedAmountMinor;
  final String currency;
  final String description;
  static RecentMovement fromJson(Map<String, dynamic> j) =>
      RecentMovement('${j['bookingDate']}', (j['signedAmountMinor'] as num?)?.toInt() ?? 0, '${j['currency']}', '${j['description']}');
  Map<String, dynamic> toJson() => {'bookingDate': bookingDate, 'signedAmountMinor': signedAmountMinor, 'currency': currency, 'description': description};
}

/// A downloaded movement, as needed here (the bank feed keeps more fields).
class BookedMovement {
  const BookedMovement({this.id, required this.bookingDate, required this.signedAmountMinor, required this.currency, required this.description});
  final String? id;
  final String bookingDate;
  final int signedAmountMinor;
  final String currency;
  final String description;
}

class BankActivity {
  BankActivity(
      {required this.observedAt,
      required this.currency,
      this.bookedBalance,
      this.availableBalance,
      this.pendingMovements,
      this.recentMovements = const [],
      this.receivedCount = 0,
      this.ignoredStatuses = const {}});
  final DateTime observedAt;
  final String currency;
  final int? bookedBalance;
  final int? availableBalance;

  /// Null when the bank did not report holds in this query (the detail is then unknown, not empty).
  final List<PendingMovement>? pendingMovements;

  /// The latest booked entries the bank sent, newest first: "did the bank send it?".
  final List<RecentMovement> recentMovements;

  /// How many booked entries the bank sent.
  final int receivedCount;

  /// Entries with a status the app does not import (cancelled, informative…), counted by status.
  final Map<String, int> ignoredStatuses;

  /// Sum of the provisional amounts (holds are negative). They are not in the accounts yet.
  int get pendingTotal => (pendingMovements ?? const []).fold(0, (sum, m) => sum + m.signedAmountMinor);

  /// Swift `BankingAccountActivity.init(feed:)`.
  factory BankActivity.fromFeed(
      {required String accountCurrency,
      required List<({int amountMinor, String currency, String type})> balances,
      required List<BookedMovement> movements,
      List<PendingMovement>? pending,
      Map<String, int>? ignored,
      required DateTime observedAt}) {
    final own = balances.where((b) => b.currency == accountCurrency).toList();
    int? balance(String preferred, String fallback) {
      final preferredRows = own.where((b) => b.type == preferred).toList();
      final rows = preferredRows.isEmpty ? own.where((b) => b.type == fallback).toList() : preferredRows;
      final amounts = rows.map((b) => b.amountMinor).toSet();
      return amounts.length == 1 ? amounts.first : null;
    }

    final sorted = [...movements]..sort((a, b) => a.bookingDate == b.bookingDate ? (b.id ?? '').compareTo(a.id ?? '') : b.bookingDate.compareTo(a.bookingDate));
    List<PendingMovement>? held;
    if (pending != null) {
      final seen = movements.map((m) => m.id).whereType<String>().toSet();
      held = pending
          .where((row) => row.currency == accountCurrency && (row.status == 'HOLD' || row.status == 'PDNG') && (row.id == null || seen.add(row.id!)))
          .toList()
        ..sort((a, b) => (b.date ?? '').compareTo(a.date ?? ''));
    }
    return BankActivity(
        observedAt: observedAt,
        currency: accountCurrency,
        bookedBalance: balance('ITBD', 'CLBD'),
        availableBalance: balance('ITAV', 'CLAV'),
        pendingMovements: held,
        recentMovements: [for (final m in sorted.take(8)) RecentMovement(m.bookingDate, m.signedAmountMinor, m.currency, m.description)],
        receivedCount: movements.length,
        ignoredStatuses: ignored ?? const {});
  }

  Map<String, dynamic> toJson() => {
        'observedAt': observedAt.millisecondsSinceEpoch,
        'currency': currency,
        'bookedBalance': bookedBalance,
        'availableBalance': availableBalance,
        'pendingMovements': pendingMovements == null ? null : [for (final m in pendingMovements!) m.toJson()],
        'recentMovements': [for (final m in recentMovements) m.toJson()],
        'receivedCount': receivedCount,
        'ignoredStatuses': ignoredStatuses,
      };

  static BankActivity fromJson(Map<String, dynamic> j) => BankActivity(
        observedAt: DateTime.fromMillisecondsSinceEpoch((j['observedAt'] as num).toInt()),
        currency: '${j['currency']}',
        bookedBalance: (j['bookedBalance'] as num?)?.toInt(),
        availableBalance: (j['availableBalance'] as num?)?.toInt(),
        pendingMovements: j['pendingMovements'] is List
            ? [for (final m in j['pendingMovements'] as List) PendingMovement.fromJson(Map<String, dynamic>.from(m as Map))]
            : null,
        recentMovements: [for (final m in (j['recentMovements'] as List?) ?? const []) RecentMovement.fromJson(Map<String, dynamic>.from(m as Map))],
        receivedCount: (j['receivedCount'] as num?)?.toInt() ?? 0,
        ignoredStatuses: (j['ignoredStatuses'] as Map?)?.map((k, v) => MapEntry('$k', (v as num).toInt())) ?? const {},
      );
}

/// Swift `PersonalBankConnectionsView.statusName`.
String bankStatusName(String code) => switch (code) {
      'CNCL' => 'cancelados',
      'RJCT' => 'rechazados',
      'INFO' => 'informativos',
      'SCHD' => 'programados',
      'NONE' => 'sin estado',
      _ => 'con estado $code',
    };

/// Saved per user, keyed by the account's bank identity (`enable:…`).
class BankActivityStore {
  BankActivityStore(this.directory);
  final Directory directory;
  static const maximumAge = Duration(days: 7);

  File _file(String user) => File('${directory.path}${Platform.pathSeparator}bank-activity-$user.json');

  Future<Map<String, BankActivity>> load(String user, {DateTime? now}) async {
    try {
      final raw = jsonDecode(await _file(user).readAsString()) as Map;
      final limit = (now ?? DateTime.now()).subtract(maximumAge);
      return {
        for (final entry in raw.entries)
          if (BankActivity.fromJson(Map<String, dynamic>.from(entry.value as Map)) case final a when a.observedAt.isAfter(limit)) '${entry.key}': a
      };
    } catch (_) {
      return {};
    }
  }

  Future<void> save(String user, Map<String, BankActivity> activity) async {
    final file = _file(user);
    try {
      if (activity.isEmpty) {
        if (await file.exists()) await file.delete();
        return;
      }
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(activity.map((k, v) => MapEntry(k, v.toJson()))), flush: true);
      await temporary.rename(file.path);
    } catch (_) {
      // Losing this copy only hides holds until the next download; the accounts are unaffected.
    }
  }

  Future<void> clear(String user) async {
    final file = _file(user);
    if (await file.exists()) await file.delete();
  }
}

/// Holds not already counted as a payment recorded with Apple Pay and still waiting for the bank. Each such
/// payment covers at most one hold of the same amount from the day before the payment up to 7 days later;
/// an undated hold matches by amount alone (Swift `CardPaymentInbox.uncoveredHolds`).
List<PendingMovement> uncoveredHolds(List<PendingMovement> holds, List<({int amountMinor, DateTime date})> awaiting) {
  final open = [...awaiting];
  return holds.where((hold) {
    if (hold.signedAmountMinor >= 0) return true;
    final day = hold.date == null ? null : DateTime.tryParse(hold.date!);
    final index = open.indexWhere((payment) {
      if (payment.amountMinor != -hold.signedAmountMinor) return false;
      if (day == null) return true;
      final delay = day.difference(payment.date).inSeconds;
      return delay >= -86400 && delay <= 7 * 86400;
    });
    if (index < 0) return true;
    open.removeAt(index);
    return false;
  }).toList();
}

class BankHold {
  const BankHold(this.id, this.account, this.movement, this.observedAt);
  final String id;
  final Account account;
  final PendingMovement movement;
  final DateTime observedAt;
}

List<PendingMovement> _uncovered(BankActivity entry, Account account, Finances data) {
  final pending = entry.pendingMovements;
  if (pending == null || pending.isEmpty) return const [];
  final awaiting = [
    for (final t in data.transactions)
      if (t.sourceAccountId == account.id && t.awaitsBank) (amountMinor: t.amountMinor, date: t.date)
  ];
  return uncoveredHolds(pending, awaiting);
}

/// Holds and pending entries of active linked accounts, newest first (Swift `BankHold.all`).
List<BankHold> bankHolds(Finances data, Map<String, BankActivity> activity) {
  final holds = <BankHold>[];
  for (final account in data.accounts.where((a) => !a.isArchived)) {
    final key = account.bankIdentityKey;
    final entry = key == null ? null : activity[key];
    if (entry == null) continue;
    final list = _uncovered(entry, account, data);
    for (var i = 0; i < list.length; i++) {
      holds.add(BankHold('$key#$i', account, list[i], entry.observedAt));
    }
  }
  holds.sort((a, b) {
    final left = a.movement.date ?? '', right = b.movement.date ?? '';
    return left == right ? a.id.compareTo(b.id) : right.compareTo(left);
  });
  return holds;
}

/// Charges held for an account and not yet counted as a recorded payment (zero or negative).
int heldMinor(BankActivity? entry, Account account, Finances data) =>
    entry == null ? 0 : _uncovered(entry, account, data).fold(0, (sum, m) => sum + (m.signedAmountMinor < 0 ? m.signedAmountMinor : 0));
