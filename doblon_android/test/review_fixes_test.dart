// Fictitious data only. Regression tests for the code review of 12 November 2026.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/banking.dart';
import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/banks.dart';
import 'package:doblon/screens/login.dart';
import 'package:doblon/screens/shell.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

/// A cloud with one account linked to a bank, reachable or not.
class _Cloud {
  bool online = true;
  int revision = 1;
  Map<String, dynamic> document = {
    'formatVersion': 2,
    'accounts': [
      {'id': 'account', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': accountIdentity('fictitious-bank-account')}
    ],
    'transactions': [],
    'categories': []
  };
  Map<String, dynamic> snapshot() => {'workspace_id': 'fictitious-workspace', 'revision': revision, 'document': document};
  http.Response json(Object value, http.Request request, [int status = 200]) =>
      http.Response(jsonEncode(value), status, request: request, headers: {'content-type': 'application/json'});

  late final transport = MockClient((request) async {
    if (!online) throw http.ClientException('Fictitious offline');
    final path = request.url.path;
    if (path.endsWith('/finance_privacy_profile')) {
      return json({'encryption_required': false, 'workspace_id': 'fictitious-workspace', 'key_check': null}, request);
    }
    if (path.endsWith('/finance_snapshot')) return json(snapshot(), request);
    if (path.endsWith('/finance_save_snapshot')) {
      document = Map<String, dynamic>.from((jsonDecode(request.body) as Map)['p_document'] as Map);
      revision++;
      return json(snapshot(), request);
    }
    return json({'message': 'Fictitious learning unavailable', 'code': '42883'}, request, 404);
  });

  Future<SupabaseClient> client() async {
    final client = SupabaseClient('https://fictitious.invalid', 'fictitious-key',
        httpClient: transport, authOptions: const AuthClientOptions(autoRefreshToken: false));
    await client.auth.setInitialSession(jsonEncode({
      'access_token': 'fictitious',
      'token_type': 'bearer',
      'user': {'id': 'fictitious-user', 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z', 'app_metadata': {}, 'user_metadata': {}}
    }));
    return client;
  }
}

class _Bank extends BankingClient {
  _Bank() : super('fictitious');
  bool fail = false;
  int downloads = 0;
  final account = RemoteAccount(id: 'fictitious-bank-account', currency: 'EUR', lastFour: '0000');
  @override
  Future<List<RemoteConnection>> connections() async {
    if (fail) throw BankingError('guest_application_inactive');
    return [RemoteConnection(id: 'fictitious-connection', bank: 'Banco ficticio', validUntil: '2027-01-01', accounts: [account])];
  }

  @override
  Future<AccountFeed> feed(RemoteConnection connection, RemoteAccount account, DateTime asOf, {bool userInitiated = true}) async {
    downloads++;
    return AccountFeed(
        connection: connection,
        account: account,
        balances: [BankBalance(98750, 'EUR', 'CLBD')],
        movements: [Movement(id: 'fictitious-row', bookingDate: '2026-01-01', signedAmountMinor: -1250, currency: 'EUR', description: 'Compra ficticia')]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  setUp(() => runTraining = <T>(T Function() work) async => work());

  test('the confirmation e-mail returns to the app with the address the iPhone already uses', () {
    final project = jsonDecode(File('../CloudBackend/project.json').readAsStringSync());
    expect(jsonEncode(project), contains('"$authRedirect"'), reason: 'Already allowed in Supabase for the iPhone');
    final manifest = File('android/app/src/main/AndroidManifest.xml').readAsStringSync();
    expect(manifest, contains('android:scheme="mibombomoney-cloud" android:host="auth"'));
    expect(File('lib/screens/login.dart').readAsStringSync(), contains('emailRedirectTo: authRedirect'));
  });

  test('the same connection error is shown once', () {
    const text = 'Tu cuenta no tiene acceso a la conexión bancaria.';
    expect(separateConnectionError(text, text), isNull);
    expect(separateConnectionError(text, null), text);
    expect(separateConnectionError(null, 'Otro aviso'), isNull);
  });

  test('a failed bank synchronization does not block the next ones, and an import empties the queue it saved', () async {
    final directory = await Directory.systemTemp.createTemp('doblon-review-fixes');
    addTearDown(() => directory.delete(recursive: true));
    final cloud = _Cloud();
    final client = await cloud.client();
    addTearDown(client.dispose);
    final repository = FinanceRepository(store: LocalStore(directory), cloudClient: client);
    addTearDown(repository.dispose);
    await repository.refresh();
    final bank = _Bank()..fail = true;
    addTearDown(bank.close);

    final failed = await repository.synchronizeBanks(manual: true, client: bank);
    expect(failed!.errors['Conexión'], isNotNull);
    bank.fail = false;

    // An edit made without connection is still queued when the bank download is saved.
    cloud.online = false;
    await repository.apply(upsertOperation('accounts', {'id': 'account', 'notes': 'Editado sin conexión'}, create: false));
    expect(repository.pending, hasLength(1));
    cloud.online = true;
    await repository.synchronizeBanks(manual: true, client: bank);
    expect(bank.downloads, 1, reason: 'The earlier failure did not leave the synchronization blocked');
    expect(repository.finances!.transactions.single.amountMinor, 1250);
    expect((cloud.document['accounts'] as List).single['notes'], 'Editado sin conexión');
    expect(repository.pending, isEmpty, reason: 'What the import saved leaves the queue');
    expect(await LocalStore(directory).loadPending('fictitious-user'), isEmpty);

    // Proposals and contributions are computed once per version of the data.
    expect(identical(repository.bankProposals, repository.bankProposals), isTrue);
    expect(identical(repository.contributions, repository.contributions), isTrue);
  });

  test('reconciling a contribution teaches the correction although the charge carries the rule', () async {
    Map<String, dynamic> row({String? recurring, String type = 'expense', String? destination}) => {
          'id': 'cargo',
          'date': referenceSeconds(DateTime.utc(2026, 5, 5, 12)),
          'typeRaw': type,
          'amountMinor': 10000,
          'descriptionText': 'Plan ficticio',
          'sourceAccountID': 'cuenta',
          'destinationAccountID': destination,
          'recurringMovementID': recurring,
          'bankEntryKey': 'enable-entry:x:1',
        };
    Finances data(Map<String, dynamic> transaction) => Finances.fromDocument({
          'accounts': [
            {'id': 'cuenta', 'name': 'Banco ficticio', 'typeRaw': 'checking', 'openingDate': 0},
            {'id': 'cartera', 'name': 'Cartera ficticia', 'typeRaw': 'investment', 'openingDate': 0},
          ],
          'transactions': [transaction],
        });
    final before = data(row());
    final after = data(row(recurring: 'regla', type: 'transfer', destination: 'cartera'));
    final plain = Learning(), contribution = Learning();
    await plain.rememberEdit(plain.captureEdit(before.transactions.single, before), after.transactions.single, after, explicitlyReviewed: true);
    await contribution.rememberEdit(contribution.captureEdit(before.transactions.single, before), after.transactions.single, after,
        explicitlyReviewed: true, contribution: true);
    expect(plain.savedCorrections, 0, reason: 'An ordinary periodic movement does not teach');
    expect(contribution.savedCorrections, 1);
  });

  test('"create a new account" links again the account Doblón created for that bank account', () {
    final feed = AccountFeed(
        connection: RemoteConnection(id: 'c', bank: 'Banco ficticio', validUntil: '2027-01-01', accounts: const []),
        account: RemoteAccount(id: 'remota', currency: 'EUR', lastFour: '1234'),
        balances: const [],
        movements: const []);
    final previous = stableUuid('${accountIdentity('remota')}|account');
    final document = {
      'formatVersion': 2,
      'accounts': [
        {'id': previous, 'name': 'Creada antes', 'typeRaw': 'checking', 'openingDate': 0, 'currencyCode': 'EUR', 'isArchived': false}
      ],
      'transactions': [],
    };
    final (next, _) = importFeeds(document, [feed], DateTime(2026, 11, 12), accountChoices: {'remota': 'new'});
    final accounts = next['accounts'] as List;
    expect(accounts, hasLength(1), reason: 'No duplicate account');
    expect(accounts.single['bankIdentityKey'], accountIdentity('remota'));
    (document['accounts'] as List).single['isArchived'] = true;
    expect(() => importFeeds(document, [feed], DateTime(2026, 11, 12), accountChoices: {'remota': 'new'}), throwsA(isA<BankingError>()));
  });

  test('signing out leaves no unlocked key and refreshes are not every few seconds', () {
    final session = CloudPrivacy(SupabaseClient('https://fictitious.invalid', 'fictitious-key'))..cipher = CloudCipher.generate();
    CloudPrivacy.sessions['fictitious-user'] = session;
    CloudPrivacy.forgetAll();
    expect(CloudPrivacy.sessions, isEmpty);
    expect(session.cipher, isNull);
    expect(foregroundRefresh, greaterThanOrEqualTo(const Duration(minutes: 5)));
  });
}
