import 'banking.dart';

/// Per-profile schedule. A manual refresh can bypass the six-hour success interval, but never a bank's
/// Retry-After or the minimum delay between attempts. Persisted before every request, including failures.
class BankSyncSchedule {
  final Map<String, int> next = {};
  final Map<String, int> attempted = {};
  final Map<String, int> blockedBanks = {};
  final Map<String, Map<String, String>> failures = {};

  void load(Map<String, dynamic> json) {
    void read(String name, Map<String, int> target) {
      target.clear();
      final values = json[name];
      if (values is Map) {
        for (final entry in values.entries) {
          if (entry.value is num) target['${entry.key}'] = (entry.value as num).toInt();
        }
      }
    }

    read('next', next);
    read('attempted', attempted);
    read('blockedBanks', blockedBanks);
    failures.clear();
    final savedFailures = json['failures'];
    if (savedFailures is Map) {
      for (final entry in savedFailures.entries) {
        if (entry.value is Map) failures['${entry.key}'] = Map<String, String>.from(entry.value as Map);
      }
    }
  }

  Map<String, dynamic> toJson() => {'next': next, 'attempted': attempted, 'blockedBanks': blockedBanks, 'failures': failures};

  DateTime? waitUntil(String bank, String account, {required bool manual}) {
    final limits = [blockedBanks[bank] ?? 0, (attempted[account] ?? 0) + 60000, if (!manual) next[account] ?? 0];
    final latest = limits.reduce((a, b) => a > b ? a : b);
    return latest == 0 ? null : DateTime.fromMillisecondsSinceEpoch(latest);
  }
}

class BankSyncResult {
  final Map<String, String> errors = {};
  final Map<String, DateTime> waiting = {};
  final List<ImportResult> imports = [];
  int downloaded = 0;
  String get summary {
    final inserted = imports.fold(0, (sum, r) => sum + r.inserted);
    final reviews = imports.fold(0, (sum, r) => sum + r.proposals.length);
    return '$downloaded cuentas actualizadas · $inserted movimientos nuevos${reviews > 0 ? ' · $reviews por revisar' : ''}';
  }
}

class BankSynchronizer {
  BankSynchronizer(this.schedule);
  final BankSyncSchedule schedule;
  bool busy = false;

  /// Account downloads and commits are isolated. A rejection, malformed feed or cloud error for one
  /// account leaves the rest eligible. A rate limit stops only further requests to that bank.
  Future<BankSyncResult> run({
    required BankingClient client,
    required List<RemoteConnection> connections,
    required bool Function(RemoteAccount) isLinked,
    required Future<ImportResult> Function(AccountFeed, DateTime) incorporate,
    required Future<void> Function() persist,
    required bool Function() isCurrent,
    bool manual = false,
    String? onlyBank,
    DateTime Function()? clock,
  }) async {
    final result = BankSyncResult();
    if (busy) return result;
    busy = true;
    final now = clock ?? DateTime.now;
    try {
      for (final connection in connections) {
        if (onlyBank != null && connection.bank != onlyBank) continue;
        for (final account in connection.accounts) {
          if (!isCurrent()) return result;
          if (!isLinked(account)) continue;
          final key = accountIdentity(account.id, server: client.server);
          final date = now();
          final until = schedule.waitUntil(connection.bank, key, manual: manual);
          if (until != null && date.isBefore(until)) {
            result.waiting[connection.bank] = until;
            continue;
          }
          schedule.attempted[key] = date.millisecondsSinceEpoch;
          schedule.next[key] = date.add(const Duration(minutes: 10)).millisecondsSinceEpoch;
          try {
            await persist();
            final feed = await client.feed(connection, account, date, userInitiated: manual);
            if (!isCurrent()) return result;
            result.imports.add(await incorporate(feed, date));
            result.downloaded++;
            schedule.failures.remove(key);
            schedule.next[key] = now().add(const Duration(hours: 6)).millisecondsSinceEpoch;
          } catch (error) {
            final failure = error is BankingError ? error : BankingError('cloud_conflict');
            result.errors[connection.bank] = failure.message;
            schedule.failures[key] = {'bank': connection.bank, 'message': failure.message};
            if (failure.code == 'bank_rate_limited' || failure.code == 'rate_limited') {
              final fallback = failure.code == 'bank_rate_limited' ? const Duration(hours: 6) : const Duration(minutes: 1);
              final requested = failure.retryAfter ?? fallback;
              final delay = Duration(seconds: requested.inSeconds.clamp(60, 604800));
              schedule.blockedBanks[connection.bank] = now().add(delay).millisecondsSinceEpoch;
            }
          } finally {
            if (isCurrent()) await persist();
          }
        }
      }
      for (final connection in connections) {
        for (final account in connection.accounts.where(isLinked)) {
          final failure = schedule.failures[accountIdentity(account.id, server: client.server)];
          if (failure != null) result.errors[connection.bank] = failure['message']!;
        }
      }
    } finally {
      busy = false;
    }
    return result;
  }
}
