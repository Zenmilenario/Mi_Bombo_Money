// Fictitious data only. The key vectors were computed independently (Python's hashlib) with the iPhone's
// formulas, so Android and iPhone name every account and movement the same way.
import 'package:doblon/banking.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteConnection connection(String bank, List<RemoteAccount> accounts) =>
    RemoteConnection(id: '00000000-0000-4000-8000-000000000001', bank: bank, validUntil: '2027-01-01', accounts: accounts);

AccountFeed feed(String bank, RemoteAccount account, List<Movement> movements, {List<BankBalance>? balances}) => AccountFeed(
    connection: connection(bank, [account]), account: account, balances: balances ?? [BankBalance(123456, 'EUR', 'CLBD')], movements: movements);

Movement row(String? id, String day, int amount, [String text = 'Compra ficticia']) =>
    Movement(id: id, bookingDate: day, signedAmountMinor: amount, currency: 'EUR', description: text);

Map<String, dynamic> emptyDocument() => {'formatVersion': 2, 'accounts': [], 'transactions': [], 'snapshots': [], 'categories': []};

void main() {
  final observed = DateTime.utc(2026, 11, 10, 12);
  final account = RemoteAccount(id: 'cuenta-ficticia-1', currency: 'EUR', lastFour: '0000');

  test('keys are the iPhone keys (independent SHA-256 vectors)', () {
    expect(sha256Hex(bankingServer), '864850ee3aa84abab4d6ee1f0062e1613f5f2ff422cfc1ffbf1c330336de9322');
    expect(accountIdentity('cuenta-ficticia-1'), 'enable:17186a350964eaad310842ced557bacf7a863757c5ab8717933c6318ef88627c');
    final key = '${entryPrefix('cuenta-ficticia-1')}ref-001';
    expect(key, 'enable-entry:864850ee3aa84abab4d6ee1f0062e1613f5f2ff422cfc1ffbf1c330336de9322:cuenta-ficticia-1:ref-001');
    expect(stableUuid(key), '3b0c469e-f10f-cf09-ab65-11d9da0acad4');
  });

  test('first download creates the account, the movements and the booked balance', () {
    final (document, result) = importFeeds(emptyDocument(), [
      feed('Banco Ficticio', account, [row('ref-001', '2026-11-08', -450, 'GASOLINERA FICTICIA'), row('ref-002', '2026-11-09', 120000, 'NOMINA FICTICIA')]),
    ], observed);
    expect(result.inserted, 2);
    expect(result.newAccounts, 1);
    final finances = Finances.fromDocument(document);
    expect(finances.accounts.single.bankIdentityKey, accountIdentity('cuenta-ficticia-1'));
    expect(finances.accounts.single.name, 'Banco Ficticio •••• 0000');
    final expense = finances.transactions.firstWhere((t) => t.amountMinor == 450);
    expect(expense.type, TransactionType.expense);
    expect(expense.isBanking, isTrue);
    expect(expense.date.toUtc(), DateTime.utc(2026, 11, 8), reason: 'Bank days are stored at UTC midnight, as on the iPhone');
    expect(finances.transactions.firstWhere((t) => t.amountMinor == 120000).type, TransactionType.income);
    expect(finances.snapshots.single.balanceMinor, 123456);
    for (final t in document['transactions'] as List) {
      for (final field in ['notes', 'isReconciled', 'fingerprint', 'duplicateStateRaw', 'createdAt', 'updatedAt', 'sourceAccountID']) {
        expect((t as Map)[field], isNotNull, reason: 'The cloud requires $field');
      }
    }
  });

  test('downloading again adds nothing and keeps what the person edited', () {
    final (first, _) = importFeeds(emptyDocument(), [feed('Banco Ficticio', account, [row('ref-001', '2026-11-08', -450)])], observed);
    ((first['transactions'] as List).single as Map)['descriptionText'] = 'Mi texto';
    ((first['transactions'] as List).single as Map)['amountMinor'] = 999;
    final (second, result) = importFeeds(first, [feed('Banco Ficticio', account, [row('ref-001', '2026-11-08', -450), row('ref-003', '2026-11-10', -100)])],
        observed, server: bankingServer);
    expect(result.inserted, 1);
    expect(result.alreadyImported, 1);
    expect(result.newAccounts, 0, reason: 'The account is found by its bank identity');
    final edited = (second['transactions'] as List).cast<Map>().firstWhere((t) => t['amountMinor'] == 999);
    expect(edited['descriptionText'], 'Mi texto');
    expect((second['snapshots'] as List).length, 1, reason: 'One booked balance per account, updated');
    expect((first['transactions'] as List).length, 1, reason: 'The input document is never modified');
  });

  test('a movement imported by the iPhone (or merged into a transfer) is recognised', () {
    final key = '${entryPrefix('cuenta-ficticia-1')}ref-001';
    final document = emptyDocument()
      ..['accounts'] = [
        {'id': 'local-1', 'name': 'Mi cuenta', 'typeRaw': 'checking', 'bankIdentityKey': accountIdentity('cuenta-ficticia-1'), 'isArchived': false}
      ]
      ..['transactions'] = [
        {'id': 'otro-id', 'bankEntryKey': 'enable-keys:["$key","${entryPrefix('otra')}x"]', 'typeRaw': 'transfer'}
      ];
    final (next, result) = importFeeds(document, [feed('Banco Ficticio', account, [row('ref-001', '2026-11-08', -450)])], observed);
    expect(result.inserted, 0);
    expect(result.newAccounts, 0);
    expect((next['transactions'] as List).length, 1);
  });

  test('Trade Republic rows without reference get the iPhone generated keys, stable across downloads', () {
    final tr = RemoteAccount(id: 'tr-ficticia', currency: 'EUR', lastFour: '1111');
    final rows = [row(null, '2026-11-05', -350), row(null, '2026-11-05', -350), row(null, '2026-11-06', 2000)];
    final (first, result) = importFeeds(emptyDocument(), [feed('Trade Republic', tr, rows)], observed);
    expect(result.inserted, 3, reason: 'Two equal payments on one day are two movements');
    final keys = (first['transactions'] as List).map((t) => (t as Map)['bankEntryKey']).toSet();
    expect(keys, contains('${entryPrefix('tr-ficticia')}local-occurrence:2026-11-05:EUR:-350:2'));
    final (_, again) = importFeeds(first, [feed('Trade Republic', tr, rows)], observed);
    expect(again.inserted, 0);
    expect(again.alreadyImported, 3);
  });

  test('other currencies, future dates, empty texts and ambiguous balances are left out', () {
    final usd = RemoteAccount(id: 'usd', currency: 'USD', lastFour: '2222');
    final (document, result) = importFeeds(emptyDocument(), [
      feed('Banco Ficticio', usd, [row('u1', '2026-11-08', -100)]),
      feed('Banco Ficticio', account, [row('f1', '2026-12-01', -100), row('e1', '2026-11-08', -100, '  '), row('z1', '2026-11-08', 0)],
          balances: [BankBalance(100, 'EUR', 'CLBD'), BankBalance(200, 'EUR', 'CLBD')]),
    ], observed);
    expect(result.skippedAccounts, 1);
    expect(result.inserted, 0);
    expect((document['snapshots'] as List), isEmpty, reason: 'Two different booked balances: none is trusted');
    expect(bookedBalance([BankBalance(5, 'EUR', 'ITBD'), BankBalance(9, 'EUR', 'CLBD')]), 5, reason: 'Intraday booked wins');
  });

  test('error codes are explained as on the iPhone', () {
    expect(BankingError('guest_application_inactive').message, contains('vincular primero'));
    expect(BankingError('codigo-desconocido').message, isNotEmpty);
  });
}
