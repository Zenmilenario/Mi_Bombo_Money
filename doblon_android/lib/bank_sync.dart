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

/// How a refresh ended, said in a few words.
enum BankSyncOutcome { updated, noChanges, partial, failed, waiting, nothing }

class BankSyncResult {
  final Map<String, String> errors = {};
  final Map<String, DateTime> waiting = {};
  final List<ImportResult> imports = [];

  /// Banks whose accounts were downloaded and incorporated.
  final Set<String> updatedBanks = {};

  /// How long each phase took (milliseconds), to find where a refresh is slow. Only bank names and times: never
  /// amounts, movements or keys.
  final Map<String, int> timings = {};
  int downloaded = 0;
  DateTime finishedAt = DateTime.now();

  int get inserted => imports.fold(0, (sum, r) => sum + r.inserted);
  int get reviews => imports.fold(0, (sum, r) => sum + r.proposals.length);

  BankSyncOutcome get outcome {
    final failed = errors.keys.where((b) => !updatedBanks.contains(b)).isNotEmpty;
    if (downloaded == 0) return failed ? BankSyncOutcome.failed : (waiting.isNotEmpty ? BankSyncOutcome.waiting : BankSyncOutcome.nothing);
    if (failed) return BankSyncOutcome.partial;
    return inserted + reviews > 0 ? BankSyncOutcome.updated : BankSyncOutcome.noChanges;
  }

  String get summary => '$downloaded cuentas actualizadas · $inserted movimientos nuevos${reviews > 0 ? ' · $reviews por revisar' : ''}';

  /// One line for the person: what happened, never success before it ended.
  String get headline => switch (outcome) {
        BankSyncOutcome.updated => inserted == 1 ? 'Actualizado: 1 movimiento nuevo' : 'Actualizado: $inserted movimientos nuevos',
        BankSyncOutcome.noChanges => 'Sin novedades: tus bancos están al día',
        BankSyncOutcome.partial => 'Actualizado en parte',
        BankSyncOutcome.failed => 'No se ha podido actualizar',
        BankSyncOutcome.waiting => 'Todavía no: el banco pide esperar',
        BankSyncOutcome.nothing => 'No hay cuentas que actualizar',
      };
}

/// What a refresh is doing now, for Don Bigotes: real phases only, no invented percentage.
class BankSyncProgress {
  const BankSyncProgress(this.text, {this.pendingBanks = const {}, this.doneBanks = const {}});
  final String text;
  final Set<String> pendingBanks;
  final Set<String> doneBanks;
}

class _Download {
  _Download(this.order, this.bank, this.key, this.feed, this.date);
  final int order;
  final String bank, key;
  final AccountFeed feed;
  final DateTime date;
}

class BankSynchronizer {
  BankSynchronizer(this.schedule);
  final BankSyncSchedule schedule;
  bool busy = false;

  /// Banks are asked at the same time (each bank's accounts one after another, as its limits expect); all that
  /// arrives is then incorporated in one save to the cloud, instead of one download and one save per account.
  /// Each account is still isolated: a rejection, malformed feed or cloud error for one leaves the rest. A rate
  /// limit stops only further requests to that bank.
  Future<BankSyncResult> run({
    required BankingClient client,
    required List<RemoteConnection> connections,
    required bool Function(RemoteAccount) isLinked,
    required Future<List<Object>> Function(List<(AccountFeed, DateTime)>) incorporateAll,
    required Future<void> Function() persist,
    required bool Function() isCurrent,
    bool manual = false,
    String? onlyBank,
    DateTime Function()? clock,
    void Function(BankSyncProgress)? onProgress,
  }) async {
    final result = BankSyncResult();
    if (busy) return result;
    busy = true;
    final now = clock ?? DateTime.now;
    final watch = Stopwatch()..start();
    try {
      // Which accounts may be asked now, by bank; each attempt is saved before any request.
      final plan = <String, List<(RemoteConnection, RemoteAccount, String, int)>>{};
      var order = 0;
      for (final connection in connections) {
        if (onlyBank != null && connection.bank != onlyBank) continue;
        for (final account in connection.accounts) {
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
          (plan[connection.bank] ??= []).add((connection, account, key, order++));
        }
      }
      if (plan.isEmpty || !isCurrent()) return result;
      await persist();

      final pending = plan.keys.toSet(), done = <String>{};
      void report() => onProgress?.call(BankSyncProgress(
          pending.isEmpty ? 'Incorporando los movimientos…' : 'Descargando de ${pending.join(', ')}…',
          pendingBanks: {...pending},
          doneBanks: {...done}));
      report();
      final downloads = <_Download>[];
      await Future.wait([
        for (final MapEntry(key: bank, value: accounts) in plan.entries)
          () async {
            final started = watch.elapsedMilliseconds;
            for (final (connection, account, key, position) in accounts) {
              if (!isCurrent()) break;
              try {
                final date = now();
                final feed = await client.feed(connection, account, date, userInitiated: manual);
                downloads.add(_Download(position, bank, key, feed, date));
              } catch (error) {
                _fail(result, bank, key, error, now);
                if (error is BankingError && (error.code == 'bank_rate_limited' || error.code == 'rate_limited')) break;
              }
            }
            result.timings['Descarga · $bank'] = watch.elapsedMilliseconds - started;
            pending.remove(bank);
            done.add(bank);
            report();
          }(),
      ]);
      if (!isCurrent()) return result;
      // Incorporated in the usual order of the accounts, whatever bank answered first.
      downloads.sort((a, b) => a.order.compareTo(b.order));

      if (downloads.isNotEmpty) {
        final started = watch.elapsedMilliseconds;
        List<Object> outcomes;
        try {
          outcomes = await incorporateAll([for (final d in downloads) (d.feed, d.date)]);
        } catch (error) {
          outcomes = [for (final _ in downloads) error];
        }
        result.timings['Incorporación'] = watch.elapsedMilliseconds - started;
        if (!isCurrent()) return result;
        for (final (i, d) in downloads.indexed) {
          final outcome = i < outcomes.length ? outcomes[i] : BankingError('cloud_conflict');
          if (outcome is ImportResult) {
            result.imports.add(outcome);
            result.downloaded++;
            result.updatedBanks.add(d.bank);
            schedule.failures.remove(d.key);
            schedule.next[d.key] = now().add(const Duration(hours: 6)).millisecondsSinceEpoch;
          } else {
            _fail(result, d.bank, d.key, outcome, now);
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
      result.timings['Descargas e incorporación'] = watch.elapsedMilliseconds;
      result.finishedAt = now();
      if (isCurrent()) await persist();
    }
    return result;
  }

  void _fail(BankSyncResult result, String bank, String key, Object error, DateTime Function() now) {
    final failure = error is BankingError ? error : BankingError('cloud_conflict');
    result.errors[bank] = failure.message;
    schedule.failures[key] = {'bank': bank, 'message': failure.message};
    if (failure.code == 'bank_rate_limited' || failure.code == 'rate_limited') {
      final fallback = failure.code == 'bank_rate_limited' ? const Duration(hours: 6) : const Duration(minutes: 1);
      final requested = failure.retryAfter ?? fallback;
      final delay = Duration(seconds: requested.inSeconds.clamp(60, 604800));
      schedule.blockedBanks[bank] = now().add(delay).millisecondsSinceEpoch;
    }
  }
}
