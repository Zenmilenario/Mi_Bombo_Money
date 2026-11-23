// Fictitious data only. Refreshing the banks from Don Bigotes (23 November 2026): visible at once, one refresh at a
// time however many presses, the real state after closing and reopening the panel, and a clear end (updated, no
// news, partly, failed) that never shows success before it ends nor leaves him thinking forever.
import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:doblon/bank_sync.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/screens/bank_refresh.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

class _Cloud {
  Map<String, dynamic> document = {
    'formatVersion': 2,
    'accounts': [
      {'id': 'a', 'name': 'Cuenta A', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': accountIdentity('remota-a')},
      {'id': 'b', 'name': 'Cuenta B', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': accountIdentity('remota-b')},
    ],
    'transactions': [],
    'categories': []
  };
  int revision = 1, saves = 0;
  http.Response json(Object value, http.Request request, [int status = 200]) =>
      http.Response(jsonEncode(value), status, request: request, headers: {'content-type': 'application/json'});
  late final transport = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/finance_privacy_profile')) {
      return json({'encryption_required': false, 'workspace_id': 'w', 'key_check': null}, request);
    }
    if (path.endsWith('/finance_snapshot')) return json({'workspace_id': 'w', 'revision': revision, 'document': document}, request);
    if (path.endsWith('/finance_save_snapshot')) {
      saves++;
      document = Map<String, dynamic>.from((jsonDecode(request.body) as Map)['p_document'] as Map);
      revision++;
      return json({'workspace_id': 'w', 'revision': revision, 'document': document}, request);
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

/// Two banks; the download can be held back, return nothing new, or fail for one bank.
class _Bank extends BankingClient {
  _Bank() : super('fictitious');
  Completer<void>? gate;
  bool offline = false, empty = false;
  String? failing;
  int downloads = 0;
  final a = RemoteAccount(id: 'remota-a', currency: 'EUR', lastFour: '1111');
  final b = RemoteAccount(id: 'remota-b', currency: 'EUR', lastFour: '2222');
  @override
  Future<List<RemoteConnection>> connections() async {
    if (offline) throw BankingError('network');
    return [
      RemoteConnection(id: '00000000-0000-4000-8000-00000000000a', bank: 'Banco A', validUntil: '2027-01-01', accounts: [a]),
      RemoteConnection(id: '00000000-0000-4000-8000-00000000000b', bank: 'Banco B', validUntil: '2027-01-01', accounts: [b]),
    ];
  }

  @override
  Future<AccountFeed> feed(RemoteConnection connection, RemoteAccount account, DateTime asOf, {bool userInitiated = true}) async {
    downloads++;
    await gate?.future;
    if (failing == connection.bank) throw BankingError('bank_unavailable');
    return AccountFeed(
        connection: connection,
        account: account,
        balances: [BankBalance(10000, 'EUR', 'CLBD')],
        movements: [
          if (!empty) Movement(id: 'mov-${account.id}', bookingDate: '2026-11-20', signedAmountMinor: -1250, currency: 'EUR', description: 'Compra ficticia')
        ]);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  setUpAll(() => initializeDateFormatting('es'));
  setUp(() {
    runTraining = <T>(T Function() work) async => work();
    CloudPrivacy.forgetAll(); // Each test is a different person's cloud.
  });

  Future<(FinanceRepository, _Cloud)> repository() async {
    final directory = await Directory.systemTemp.createTemp('doblon-bank-refresh');
    addTearDown(() => directory.delete(recursive: true));
    final cloud = _Cloud();
    final client = await cloud.client();
    addTearDown(client.dispose);
    final repository = FinanceRepository(store: LocalStore(directory), cloudClient: client);
    addTearDown(repository.dispose);
    await repository.refresh();
    return (repository, cloud);
  }

  test('pressing shows activity at once, presses again join the same refresh, and the state ends cleanly', () async {
    final (repo, cloud) = await repository();
    final bank = _Bank()..gate = Completer<void>();
    addTearDown(bank.close);
    final first = repo.synchronizeBanks(manual: true, client: bank);
    expect(repo.bankProgress.value?.text, 'Consultando tus bancos…', reason: 'Immediately, before any answer');
    final again = repo.synchronizeBanks(manual: true, client: bank);
    expect(identical(first, again), isTrue, reason: 'No second refresh');
    await Future<void>.delayed(const Duration(milliseconds: 50));
    expect(repo.bankProgress.value?.text, contains('Descargando de'), reason: 'A real phase: which banks are being asked');
    expect(bank.downloads, 2, reason: 'Both banks at the same time, once each');
    bank.gate!.complete();
    final result = (await first)!;
    expect(repo.bankProgress.value, isNull, reason: 'Never thinking forever');
    expect(result.outcome, BankSyncOutcome.updated);
    expect(result.headline, 'Actualizado: 2 movimientos nuevos');
    expect(result.updatedBanks, {'Banco A', 'Banco B'});
    expect(cloud.saves, 1, reason: 'One save to the cloud for every account');
    expect(result.timings.keys, containsAll(['Conexiones', 'Descarga · Banco A', 'Incorporación', 'Total']));
    expect(result.timings.keys.any((k) => RegExp(r'\d').hasMatch(k)), isFalse, reason: 'Only phases and banks, never amounts');
  });

  test('no news, partly updated, and a lost connection are told apart', () async {
    final (repo, _) = await repository();
    final bank = _Bank()..empty = true;
    addTearDown(bank.close);
    var result = (await repo.synchronizeBanks(manual: true, client: bank))!;
    expect(result.outcome, BankSyncOutcome.noChanges);

    final (repo2, _) = await repository();
    final partial = _Bank()..failing = 'Banco B';
    addTearDown(partial.close);
    result = (await repo2.synchronizeBanks(manual: true, client: partial))!;
    expect(result.outcome, BankSyncOutcome.partial);
    expect(result.updatedBanks, {'Banco A'});
    expect(result.errors.keys, ['Banco B'], reason: 'The bank that failed, apart from the one that worked');
    expect(repo2.finances!.transactions.length, 1, reason: 'What arrived is kept');

    final (repo3, _) = await repository();
    final offline = _Bank()..offline = true;
    addTearDown(offline.close);
    result = (await repo3.synchronizeBanks(manual: true, client: offline))!;
    expect(result.outcome, BankSyncOutcome.failed);
    expect(repo3.bankProgress.value, isNull);
  });

  testWidgets('closing and opening the panel again shows the real state; the dots stay still with fewer animations', (tester) async {
    late FinanceRepository repo;
    final bank = _Bank()..gate = Completer<void>();
    await tester.runAsync(() async {
      (repo, _) = await repository();
    });
    addTearDown(bank.close);
    Widget panel({bool still = false}) => MaterialApp(
          theme: doblonTheme(Brightness.light),
          locale: const Locale('es', 'ES'),
          supportedLocales: const [Locale('es', 'ES')],
          localizationsDelegates: GlobalMaterialLocalizations.delegates,
          home: Builder(
              builder: (context) => MediaQuery(
                  data: MediaQuery.of(context).copyWith(disableAnimations: still), child: Scaffold(body: BankRefreshPanel(repository: repo)))),
        );
    await tester.runAsync(() async {
      unawaited(repo.synchronizeBanks(manual: true, client: bank));
      await Future<void>.delayed(const Duration(milliseconds: 50));
    });
    // «Reopened»: a new panel reads the refresh in progress.
    await tester.pumpWidget(panel(still: true));
    await tester.pumpAndSettle();
    expect(find.text('Consultando tus bancos…'), findsOneWidget);
    expect(tester.widget<FilledButton>(find.byType(FilledButton)).onPressed, isNull, reason: 'No second refresh from the panel');
    expect(find.textContaining('Descargando de'), findsOneWidget);
    await tester.runAsync(() async {
      bank.gate!.complete();
      while (repo.bankProgress.value != null) {
        await Future<void>.delayed(const Duration(milliseconds: 20));
      }
    });
    await tester.pumpWidget(panel());
    await tester.pump();
    expect(find.text('Actualizado: 2 movimientos nuevos'), findsOneWidget);
    expect(find.text('Actualizar mis bancos'), findsOneWidget);
    expect(find.byType(ThinkingDots), findsNothing);
  });
}
