import 'dart:convert';
import 'dart:io';

import 'package:doblon/data.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/edits.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  test('foreground refresh retries offline edits against the latest cloud copy without overwriting another device', () async {
    final directory = await Directory.systemTemp.createTemp('doblon-cloud-retry');
    addTearDown(() => directory.delete(recursive: true));
    var online = true;
    var revision = 1;
    var document = <String, dynamic>{
      'formatVersion': 2,
      'accounts': [
        {'id': 'account', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': 0}
      ],
      'transactions': [],
      'categories': []
    };
    Map<String, dynamic> snapshot() => {'workspace_id': 'fictitious-workspace', 'revision': revision, 'document': document};
    final transport = MockClient((request) async {
      if (!online) throw http.ClientException('Fictitious offline');
      if (request.url.path.endsWith('/finance_snapshot')) {
        return http.Response(jsonEncode(snapshot()), 200, request: request, headers: {'content-type': 'application/json'});
      }
      if (request.url.path.endsWith('/finance_save_snapshot')) {
        final body = jsonDecode(request.body) as Map;
        expect(body['p_expected_revision'], revision);
        document = Map<String, dynamic>.from(body['p_document'] as Map);
        revision++;
        return http.Response(jsonEncode(snapshot()), 200, request: request, headers: {'content-type': 'application/json'});
      }
      return http.Response('{"message":"Fictitious learning unavailable","code":"42883"}', 404,
          request: request, headers: {'content-type': 'application/json'});
    });
    final client =
        SupabaseClient('https://fictitious.invalid', 'fictitious-key', httpClient: transport, authOptions: const AuthClientOptions(autoRefreshToken: false));
    addTearDown(client.dispose);
    await client.auth.setInitialSession(jsonEncode({
      'access_token': 'fictitious',
      'token_type': 'bearer',
      'user': {'id': 'fictitious-user', 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z', 'app_metadata': {}, 'user_metadata': {}}
    }));
    final repository = FinanceRepository(store: LocalStore(directory), cloudClient: client);
    addTearDown(repository.dispose);
    await repository.refresh();
    expect(repository.error, isNull);
    expect(repository.finances!.accounts.single.name, 'Cuenta ficticia');
    online = false;
    await repository.apply(upsertOperation('accounts', {'id': 'account', 'notes': 'Editado sin conexión'}, create: false));
    expect(repository.pending.length, 1);
    expect((await LocalStore(directory).loadPending('fictitious-user')).length, 1);
    document['categories'] = [
      {'id': 'other-device', 'name': 'Creada en otro dispositivo', 'kindRaw': 'expense'}
    ];
    revision++;
    online = true;
    await repository.refresh();
    expect(repository.pending, isEmpty);
    expect((document['accounts'] as List).single['notes'], 'Editado sin conexión');
    expect((document['categories'] as List).single['id'], 'other-device');
    expect(repository.error, isNull);

    // Refresh while the app remains open also brings another device's later changes back.
    (document['accounts'] as List).single['name'] = 'Actualizada desde la nube';
    revision++;
    await repository.refresh();
    expect(repository.finances!.accounts.single.name, 'Actualizada desde la nube');

    // A received bank preview survives a failed cloud write. Recovery uses the saved preview even
    // while the account is still in its retry delay, without requesting the bank again.
    (document['accounts'] as List).single['bankIdentityKey'] = accountIdentity('fictitious-bank-account');
    revision++;
    await repository.refresh();
    final bank = _ReceivedBank(() => online = false);
    addTearDown(bank.close);
    await repository.synchronizeBanks(manual: true, client: bank);
    expect(bank.downloads, 1);
    expect(repository.finances!.transactions, isEmpty);
    expect((await LocalStore(directory).loadBankState('fictitious-user'))['reviews'], isNotEmpty);
    online = true;
    await repository.synchronizeBanks(client: bank);
    expect(bank.downloads, 1, reason: 'The preview is retried without querying the provider');
    expect(repository.bankResult!.errors, isEmpty);
    expect(repository.finances!.transactions.single.amountMinor, 1250);
    expect((await LocalStore(directory).loadBankState('fictitious-user'))['reviews'], isEmpty);
    await Future<void>.delayed(const Duration(milliseconds: 20));
  });
}

class _ReceivedBank extends BankingClient {
  _ReceivedBank(this.onDownload) : super('fictitious');
  final void Function() onDownload;
  int downloads = 0;
  final account = RemoteAccount(id: 'fictitious-bank-account', currency: 'EUR', lastFour: '0000');
  @override
  Future<List<RemoteConnection>> connections() async => [
        RemoteConnection(id: 'fictitious-connection', bank: 'Banco ficticio', validUntil: '2027-01-01', accounts: [account])
      ];
  @override
  Future<AccountFeed> feed(RemoteConnection connection, RemoteAccount account, DateTime asOf, {bool userInitiated = true}) async {
    downloads++;
    onDownload();
    return AccountFeed(
        connection: connection,
        account: account,
        balances: [BankBalance(98750, 'EUR', 'CLBD')],
        movements: [Movement(id: 'fictitious-row', bookingDate: '2026-01-01', signedAmountMinor: -1250, currency: 'EUR', description: 'Compra ficticia')]);
  }
}
