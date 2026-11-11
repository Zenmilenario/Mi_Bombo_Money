// Bank connection for Android: the same server (Cloudflare Worker) and the same keys as the iPhone app
// (`BankingConnectionClient.swift`, `PersonalBankingPlan.swift`, `PersonalBankingImporter.swift`), so a
// movement downloaded on either device is the same record and is never imported twice.
import 'dart:convert';

import 'package:crypto/crypto.dart';
import 'package:http/http.dart' as http;

import 'bank_activity.dart';

/// The personal bank server. Its address is part of every account and movement key: it must not change.
const bankingServer = 'https://mi-bombo-banking-personal.albertor7722.workers.dev';

String sha256Hex(String text) => sha256.convert(utf8.encode(text)).toString();

/// Swift `StableDigest.uuid`: the first 16 bytes of the SHA-256 as a UUID (lower case here; Postgres
/// compares UUIDs without case).
String stableUuid(String text) {
  final hex = sha256Hex(text).substring(0, 32);
  return '${hex.substring(0, 8)}-${hex.substring(8, 12)}-${hex.substring(12, 16)}-${hex.substring(16, 20)}-${hex.substring(20)}';
}

/// Swift `PersonalBankingImporter.identity(server:accountID:)`.
String accountIdentity(String remoteAccountId, {String server = bankingServer}) => 'enable:${sha256Hex('$server|$remoteAccountId')}';

/// Prefix of every movement key of one remote account (Swift: `enable-entry:<namespace>:<account>:`).
String entryPrefix(String remoteAccountId, {String server = bankingServer}) => 'enable-entry:${sha256Hex(server)}:$remoteAccountId:';

class BankingError implements Exception {
  BankingError(this.code);
  final String code;

  /// The same wording as the iPhone app for the codes a person can act on.
  String get message => switch (code) {
        'owner_required' => 'Tu cuenta no tiene acceso a la conexión bancaria. Pide al responsable de Doblón que te invite.',
        'guest_banking_not_configured' => 'La conexión bancaria para personas invitadas aún no está preparada. Avisa al responsable de Doblón.',
        'guest_application_inactive' =>
          'La conexión bancaria para personas invitadas aún no está activa: el responsable de Doblón tiene que vincular primero tus cuentas en Enable Banking.',
        'no_linked_accounts' =>
          'El banco no ha compartido ninguna cuenta que Doblón pueda leer. Comprueba con el responsable de Doblón que tu cuenta está vinculada.',
        'connection_limit' => 'Has llegado al máximo de bancos conectados.',
        'rate_limited' => 'Se han hecho demasiadas solicitudes. Espera un minuto antes de reintentar.',
        'bank_rate_limited' => 'El banco ha limitado las consultas. Espera antes de volver a actualizar; no necesitas desconectar la cuenta.',
        'bank_session_expired' ||
        'bank_action_required' =>
          'El banco pide que renueves la autorización: vuelve a conectar este banco. Tus movimientos se conservan.',
        'bank_unavailable' || 'bank_timeout' => 'El banco no ha podido responder. Vuelve a intentarlo más tarde.',
        'unauthorized' || 'identity_unavailable' => 'No se ha podido verificar tu sesión. Sal y vuelve a entrar.',
        'connection_not_found' => 'La conexión ha caducado o ya se ha desconectado.',
        'cloud_conflict' => 'Tus datos han cambiado en otro dispositivo mientras se guardaban. Vuelve a actualizar.',
        'network' => 'No hay conexión con el servidor. Comprueba internet y vuelve a intentarlo.',
        _ => 'No se ha podido completar la operación con el banco. Inténtalo de nuevo más tarde.',
      };
  @override
  String toString() => message;
}

class RemoteAccount {
  RemoteAccount({required this.id, required this.currency, required this.lastFour, this.ownershipKey});
  final String id;
  final String currency;
  final String lastFour;
  final String? ownershipKey;
  factory RemoteAccount.fromJson(Map<String, dynamic> json) => RemoteAccount(
      id: json['id'] as String? ?? '',
      currency: json['currency'] as String? ?? '',
      lastFour: json['lastFour'] as String? ?? '',
      ownershipKey: json['ownershipKey'] as String?);
}

class RemoteConnection {
  RemoteConnection({required this.id, required this.bank, required this.validUntil, required this.accounts});
  final String id;
  final String bank;
  final String validUntil;
  final List<RemoteAccount> accounts;
  factory RemoteConnection.fromJson(Map<String, dynamic> json) => RemoteConnection(
      id: json['id'] as String? ?? '',
      bank: json['bank'] as String? ?? '',
      validUntil: json['validUntil'] as String? ?? '',
      accounts: ((json['accounts'] as List?) ?? const []).whereType<Map>().map((a) => RemoteAccount.fromJson(Map<String, dynamic>.from(a))).toList());
}

class Movement {
  Movement(
      {this.id,
      required this.bookingDate,
      required this.signedAmountMinor,
      required this.currency,
      required this.description,
      this.counterpartyKey,
      this.transferKey});
  final String? id;
  final String bookingDate;
  final int signedAmountMinor;
  final String currency;
  final String description;
  final String? counterpartyKey;
  final String? transferKey;
  factory Movement.fromJson(Map<String, dynamic> json) => Movement(
      id: json['id'] as String?,
      bookingDate: json['bookingDate'] as String? ?? '',
      signedAmountMinor: (json['signedAmountMinor'] as num?)?.toInt() ?? 0,
      currency: json['currency'] as String? ?? '',
      description: json['description'] as String? ?? '',
      counterpartyKey: json['counterpartyKey'] as String?,
      transferKey: json['transferKey'] as String?);
}

class BankBalance {
  BankBalance(this.amountMinor, this.currency, this.type);
  final int amountMinor;
  final String currency;
  final String type;
}

/// Everything downloaded for one remote account.
class AccountFeed {
  AccountFeed({required this.connection, required this.account, required this.balances, required this.movements, this.pending, this.ignoredStatuses});
  final RemoteConnection connection;
  final RemoteAccount account;
  final List<BankBalance> balances;
  final List<Movement> movements;

  /// Holds and pending entries; null when the server did not report them.
  final List<PendingMovement>? pending;

  /// Entries with a status that is not imported, counted by status (diagnostic only).
  final Map<String, int>? ignoredStatuses;

  /// What this query reported besides the booked movements, kept on the device.
  BankActivity activity(DateTime observedAt) => BankActivity.fromFeed(
      accountCurrency: account.currency,
      balances: [for (final b in balances) (amountMinor: b.amountMinor, currency: b.currency, type: b.type)],
      movements: [
        for (final m in movements)
          BookedMovement(id: m.id, bookingDate: m.bookingDate, signedAmountMinor: m.signedAmountMinor, currency: m.currency, description: m.description)
      ],
      pending: pending,
      ignored: ignoredStatuses,
      observedAt: observedAt);
}

class BankingClient {
  BankingClient(this.accessToken, {http.Client? client, this.server = bankingServer}) : _http = client ?? http.Client();
  final String accessToken;
  final String server;
  final http.Client _http;

  Future<dynamic> _send(String method, String path, {Map<String, String>? query, Object? body, bool userInitiated = false}) async {
    final uri = Uri.parse(server).replace(path: path, queryParameters: query);
    final request = http.Request(method, uri)..headers['Authorization'] = 'Bearer $accessToken';
    if (userInitiated) {
      // The bank may only be queried on the person's request with this header (PSD2 «PSU present»).
      request.headers['X-Banking-User-Initiated'] = '1';
      request.headers['User-Agent'] = 'Doblon-Android';
    }
    if (body != null) {
      request.headers['Content-Type'] = 'application/json';
      request.body = jsonEncode(body);
    }
    final http.StreamedResponse streamed;
    try {
      streamed = await _http.send(request).timeout(const Duration(seconds: 45));
    } catch (_) {
      throw BankingError('network');
    }
    final response = await http.Response.fromStream(streamed);
    if (response.statusCode == 204) return null;
    dynamic decoded;
    try {
      decoded = jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      throw BankingError('invalid_response');
    }
    if (response.statusCode >= 400) throw BankingError(decoded is Map ? '${decoded['error']}' : 'service_unavailable');
    return decoded;
  }

  Future<List<String>> banks() async {
    final data = await _send('GET', '/v1/banks') as Map;
    return ((data['banks'] as List?) ?? const []).whereType<Map>().map((b) => '${b['name']}').toList();
  }

  Future<List<RemoteConnection>> connections() async {
    final data = await _send('GET', '/v1/connections') as Map;
    return ((data['connections'] as List?) ?? const []).whereType<Map>().map((c) => RemoteConnection.fromJson(Map<String, dynamic>.from(c))).toList();
  }

  /// Returns the bank authorization page. Only Enable Banking's own addresses are accepted.
  Future<Uri> startAuthorization(String bank) async {
    final data = await _send('POST', '/v1/authorizations', body: {'bank': bank}) as Map;
    final url = Uri.tryParse('${data['authorizationURL']}');
    const hosts = {'auth.enablebanking.com', 'tilisy.enablebanking.com'};
    if (url == null || url.scheme != 'https' || !hosts.contains(url.host) || url.userInfo.isNotEmpty || url.hasPort) {
      throw BankingError('authorization_destination_rejected');
    }
    return url;
  }

  Future<void> disconnect(String connectionId) => _send('DELETE', '/v1/connections/$connectionId');

  /// Downloads the last 90 days of one account, page by page (as the iPhone does).
  Future<AccountFeed> feed(RemoteConnection connection, RemoteAccount account, DateTime asOf, {bool userInitiated = true}) async {
    String day(DateTime d) => d.toUtc().toIso8601String().substring(0, 10);
    final movements = <Movement>[];
    final balances = <BankBalance>[];
    List<PendingMovement>? pending;
    Map<String, int>? ignored;
    String? cursor;
    final visited = <String>{};
    for (var page = 0; page < 50; page++) {
      final data = await _send('GET', '/v1/connections/${connection.id}/accounts/${account.id}',
          query: {
            'from': day(asOf.subtract(const Duration(days: 89))),
            'to': day(asOf),
            // Holds and pending entries; the server only adds them with a real bank (as on the iPhone).
            'include_pending': '1',
            if (cursor != null) 'continuation': cursor,
          },
          userInitiated: userInitiated) as Map;
      if (page == 0) {
        for (final b in ((data['balances'] as List?) ?? const []).whereType<Map>()) {
          balances.add(BankBalance((b['amountMinor'] as num?)?.toInt() ?? 0, '${b['currency']}', '${b['type']}'));
        }
      }
      movements.addAll(((data['transactions'] as List?) ?? const []).whereType<Map>().map((m) => Movement.fromJson(Map<String, dynamic>.from(m))));
      if (data['pendingTransactions'] is List) {
        (pending ??= []).addAll((data['pendingTransactions'] as List).whereType<Map>().map((m) => PendingMovement.fromJson(Map<String, dynamic>.from(m))));
      }
      if (data['ignoredStatuses'] is Map) {
        final counts = ignored ??= {};
        (data['ignoredStatuses'] as Map).forEach((k, v) => counts['$k'] = (counts['$k'] ?? 0) + ((v as num?)?.toInt() ?? 0));
      }
      if (movements.length > 20000 || (pending?.length ?? 0) > 20000) throw BankingError('incomplete_history');
      final next = data['continuation'] as String?;
      if (next == null) {
        return AccountFeed(connection: connection, account: account, balances: balances, movements: movements, pending: pending, ignoredStatuses: ignored);
      }
      if (!visited.add(next)) break;
      cursor = next;
    }
    throw BankingError('incomplete_history');
  }
}

/// A downloaded movement that may be one already recorded by hand: the person decides.
class BankProposal {
  BankProposal({required this.key, required this.bank, required this.date, required this.amountMinor, required this.description, required this.candidateIds});
  final String key;
  final String bank;
  final DateTime date;
  final int amountMinor;
  final String description;
  final List<String> candidateIds;
}

class ImportResult {
  ImportResult({this.inserted = 0, this.alreadyImported = 0, this.newAccounts = 0, this.skippedAccounts = 0, this.matched = 0});
  int inserted;
  int alreadyImported;
  int newAccounts;
  int skippedAccounts;
  int matched;
  final List<BankProposal> proposals = [];
  String get summary => [
        inserted == 1 ? '1 movimiento nuevo' : '$inserted movimientos nuevos',
        if (matched > 0) matched == 1 ? '1 unido a lo que ya tenías' : '$matched unidos a lo que ya tenías',
        if (proposals.isNotEmpty) proposals.length == 1 ? '1 por revisar' : '${proposals.length} por revisar',
        if (alreadyImported > 0) '$alreadyImported ya estaban',
        if (newAccounts > 0) newAccounts == 1 ? '1 cuenta añadida' : '$newAccounts cuentas añadidas',
        if (skippedAccounts > 0) '$skippedAccounts en otra moneda sin incorporar',
      ].join(' · ');
}

/// Seconds since 1 January 2001, the date format of the cloud document.
num referenceSeconds(DateTime date) => date.toUtc().millisecondsSinceEpoch / 1000 - 978307200;

/// Booked balance as the iPhone reads it: intraday booked (ITBD) if present, otherwise closing booked (CLBD),
/// in euros and only when it is unambiguous.
int? bookedBalance(List<BankBalance> balances) {
  final eur = balances.where((b) => b.currency == 'EUR').toList();
  final intraday = eur.where((b) => b.type == 'ITBD').toList();
  final preferred = intraday.isNotEmpty ? intraday : eur.where((b) => b.type == 'CLBD').toList();
  final amounts = preferred.map((b) => b.amountMinor).toSet();
  return amounts.length == 1 ? amounts.first : null;
}

/// Adds the downloaded movements and balances to the cloud document (the raw `finance_snapshot` document,
/// so every field the iPhone stores is kept as it is). Pure: returns a new document.
///
/// - Each remote account is matched by its bank identity; the first time, a new account is created.
/// - A movement whose key is already stored is skipped (it may have been edited by the person).
/// - Movements without a bank reference (Trade Republic) get the iPhone's generated key: date, amount and
///   order of appearance.
/// - Accounts in another currency are left out, as on the iPhone.
/// `decisions` answers earlier proposals: movement key → "new" or the ID of the record it is.
(Map<String, dynamic>, ImportResult) importFeeds(Map<String, dynamic> document, List<AccountFeed> feeds, DateTime observedAt,
    {String server = bankingServer, Map<String, String> decisions = const {}}) {
  final next = jsonDecode(jsonEncode(document)) as Map<String, dynamic>;
  List<Map<String, dynamic>> rows(String key) => ((next[key] ??= <dynamic>[]) as List).cast<Map<String, dynamic>>();
  final accounts = rows('accounts');
  final transactions = rows('transactions');
  final snapshots = rows('snapshots');
  final result = ImportResult();
  final now = referenceSeconds(observedAt);

  final knownKeys = <String>{};
  for (final t in transactions) {
    final key = t['bankEntryKey'];
    if (key is! String) continue;
    if (key.startsWith('enable-keys:')) {
      try {
        knownKeys.addAll((jsonDecode(key.substring('enable-keys:'.length)) as List).cast<String>());
      } catch (_) {}
    } else {
      knownKeys.add(key);
    }
  }
  final knownIds = transactions.map((t) => '${t['id']}'.toLowerCase()).toSet();

  for (final feed in feeds) {
    if (feed.account.currency != 'EUR' || feed.account.id.isEmpty) {
      result.skippedAccounts++;
      continue;
    }
    final identity = accountIdentity(feed.account.id, server: server);
    var account = accounts.where((a) => a['bankIdentityKey'] == identity && a['isArchived'] != true).firstOrNull;
    if (account == null) {
      account = {
        'id': stableUuid('$identity|account'),
        'name': '${feed.connection.bank} •••• ${feed.account.lastFour}',
        'typeRaw': 'checking',
        'currencyCode': 'EUR',
        'openingBalanceMinor': 0,
        'openingDate': referenceSeconds(observedAt.subtract(const Duration(days: 90))),
        'annualInterestRate': 0,
        'targetBalanceMinor': 0,
        'creditLimitMinor': null,
        'includeInNetWorth': true,
        'isArchived': false,
        'sortOrder': accounts.length,
        'notes': '',
        'lastUpdatedAt': now,
        'createdAt': now,
        'updatedAt': now,
        'institutionID': null,
        'bankIdentityKey': identity,
      };
      accounts.add(account);
      result.newAccounts++;
    }
    final localId = '${account['id']}';
    final prefix = entryPrefix(feed.account.id, server: server);
    final occurrences = <String, int>{};
    for (final row in feed.movements) {
      if (row.currency != 'EUR' || row.signedAmountMinor == 0 || row.description.trim().isEmpty) continue;
      final booking = DateTime.tryParse('${row.bookingDate}T00:00:00Z');
      if (booking == null || booking.isAfter(observedAt.toUtc())) continue;
      final String reference;
      if (row.id != null && row.id!.isNotEmpty) {
        reference = row.id!;
      } else {
        final group = '${row.bookingDate}:${row.currency}:${row.signedAmountMinor}';
        final occurrence = (occurrences[group] ?? 0) + 1;
        occurrences[group] = occurrence;
        reference = 'local-occurrence:$group:$occurrence';
      }
      final key = prefix + reference;
      final id = stableUuid(key);
      if (knownKeys.contains(key) || knownIds.contains(id)) {
        result.alreadyImported++;
        continue;
      }
      // A record of this account, same kind and amount, without bank key, on nearby days (an Apple Pay
      // payment from the iPhone may arrive up to 7 days later): the same movement recorded by hand.
      final kind = row.signedAmountMinor < 0 ? 'expense' : 'income';
      bool sameKind(Object? raw) => kind == 'expense' ? (raw == 'expense' || raw == 'fee') : (raw == 'income' || raw == 'interest');
      final candidates = transactions.where((t) {
        if (t['bankEntryKey'] != null || '${t['sourceAccountID']}'.toLowerCase() != localId.toLowerCase()) return false;
        if (t['destinationAccountID'] != null || !sameKind(t['typeRaw']) || (t['amountMinor'] as num?)?.toInt() != row.signedAmountMinor.abs()) return false;
        final seconds = (t['date'] as num?) ?? 0;
        final delay = referenceSeconds(booking) - seconds;
        final awaiting = '${t['externalID'] ?? ''}'.startsWith('applepay:');
        return awaiting ? delay >= -86400 && delay <= 7 * 86400 : delay.abs() <= 3 * 86400;
      }).toList();
      final decision = decisions[key];
      String? matchId;
      if (decision != null && decision != 'new') {
        if (candidates.any((t) => '${t['id']}' == decision)) matchId = decision;
      } else if (decision == null && candidates.isNotEmpty) {
        final awaiting = candidates.where((t) => '${t['externalID'] ?? ''}'.startsWith('applepay:')).toList();
        if (candidates.length == 1 && awaiting.length == 1) {
          matchId = '${awaiting.single['id']}';
        } else {
          result.proposals.add(BankProposal(
              key: key,
              bank: feed.connection.bank,
              date: booking,
              amountMinor: row.signedAmountMinor,
              description: row.description.trim(),
              candidateIds: [for (final t in candidates) '${t['id']}']));
          continue;
        }
      }
      knownKeys.add(key);
      knownIds.add(id);
      if (matchId != null) {
        final record = candidates.firstWhere((t) => '${t['id']}' == matchId);
        record['bankEntryKey'] = key;
        record['isReconciled'] = true;
        record['updatedAt'] = now;
        if ('${record['externalID'] ?? ''}'.startsWith('applepay:')) record['externalID'] = null;
        result.matched++;
        continue;
      }
      transactions.add({
        'id': id,
        'date': referenceSeconds(booking),
        'typeRaw': row.signedAmountMinor < 0 ? 'expense' : 'income',
        'amountMinor': row.signedAmountMinor.abs(),
        'descriptionText': row.description.trim(),
        'notes': '',
        'isReconciled': true,
        'fingerprint': '',
        'duplicateStateRaw': 'none',
        'externalID': null,
        'importBatchID': null,
        'recurringMovementID': null,
        'reservedFundID': null,
        'reservedAmountMinor': null,
        'createdAt': now,
        'updatedAt': now,
        'sourceAccountID': localId,
        'destinationAccountID': null,
        'categoryID': null,
        'bankEntryKey': key,
      });
      result.inserted++;
    }
    final balance = bookedBalance(feed.balances);
    if (balance != null) {
      // One "booked balance" record per account, updated on each download (Swift: identity + "|booked-balance").
      final snapshotId = stableUuid('$identity|booked-balance');
      snapshots.removeWhere((s) => '${s['id']}'.toLowerCase() == snapshotId);
      snapshots.add({
        'id': snapshotId,
        'date': now,
        'balanceMinor': balance,
        'sourceRaw': 'bankAPI',
        'notes': 'Saldo contable de Enable Banking',
        'createdAt': now,
        'accountID': localId,
      });
      account['lastUpdatedAt'] = now;
      account['updatedAt'] = now;
    }
  }
  return (next, result);
}
