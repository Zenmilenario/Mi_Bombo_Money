// Fictitious data only. The forecast, the simulations and Don Bigotes' forecast notices (24 November 2026) for the
// two kinds of session, through the real app screens: the developer's account (exempt from encryption, plaintext
// cloud API) and a guest (encrypted cloud API only, key from the device's secure storage). Same experience; each
// person only sees their own accounts, reserves and simulations; nothing of the forecast reaches the cloud.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/forecast_store.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/preferences.dart';
import 'package:doblon/screens/forecast_screen.dart';
import 'package:doblon/screens/shell.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

num seconds(DateTime date) => date.millisecondsSinceEpoch / 1000 - 978307200;
const keyId = '00000000-0000-4000-8000-000000000077';

/// Someone's finances: a current account short for a charge in three days, savings with money, and a reserve.
Map<String, dynamic> finances({required String checking, required String savings, required String charge, required String reserve}) {
  final now = DateTime.now();
  return {
    'formatVersion': 2,
    for (final key in ['institutions', 'categories', 'cards', 'categoryRules', 'recurringBudgets', 'budgets', 'goals', 'importBatches', 'transactions'])
      key: <dynamic>[],
    'accounts': [
      {'id': '$checking-id', 'name': checking, 'typeRaw': 'checking', 'openingDate': seconds(DateTime(2025)), 'currencyCode': 'EUR'},
      {'id': '$savings-id', 'name': savings, 'typeRaw': 'savings', 'openingDate': seconds(DateTime(2025)), 'currencyCode': 'EUR'},
    ],
    'snapshots': [
      {'id': '$checking-s', 'accountID': '$checking-id', 'balanceMinor': 5000, 'date': seconds(now.subtract(const Duration(hours: 2))), 'sourceRaw': 'bankAPI'},
      {'id': '$savings-s', 'accountID': '$savings-id', 'balanceMinor': 200000, 'date': seconds(now.subtract(const Duration(hours: 2))), 'sourceRaw': 'manual'},
    ],
    'reservedFunds': [
      {'id': '$reserve-id', 'name': reserve, 'amountMinor': 40000, 'accountID': '$savings-id', 'createdAt': seconds(DateTime(2025, 6))},
    ],
    'recurringMovements': [
      {
        'id': '$charge-id',
        'name': charge,
        'typeRaw': 'expense',
        'amountMinor': 30000,
        'descriptionText': charge,
        'frequencyRaw': 'monthly',
        'interval': 1,
        'nextDueDate': seconds(DateTime(now.year, now.month, now.day + 3, 10)),
        'isActive': true,
        'postsAutomatically': false,
        'sourceAccountID': '$checking-id',
      }
    ],
  };
}

/// A fictitious cloud for one person: plaintext for the developer, sealed envelopes for a guest.
class Cloud {
  Cloud(this.user, {required this.encrypted, required this.document});
  final String user;
  final bool encrypted;
  Map<String, dynamic> document;
  late final workspace = 'workspace-$user';
  late final cipher = CloudCipher(List.generate(32, (i) => (i * 7 + user.length) % 256), keyId);
  final envelopes = <String, Map<String, dynamic>>{};
  final revisions = {'finance': 1, 'learning': 1};
  Map<String, dynamic>? keyCheck;
  final requests = <String>[];
  final plaintextCalls = <String>[];
  int financeSaves = 0;

  Future<void> prepare() async {
    if (!encrypted) return;
    keyCheck = await cipher.seal({'check': 'doblon-key-v1'}, user, workspace, 'key-check', 0);
    envelopes['finance'] = await cipher.seal(document, user, workspace, 'finance', 1);
    envelopes['learning'] = await cipher.seal({'version': 1, 'events': []}, user, workspace, 'learning', 1);
  }

  /// What the device's secure storage holds for a guest who already unlocked on it.
  Map<String, String> get secureStorage => encrypted
      ? {
          'doblon-cloud-privacy-v1-$user': jsonEncode({
            'profile': {'encryption_required': true, 'workspace_id': workspace, 'key_check': keyCheck},
            'code': cipher.recoveryCode
          })
        }
      : {};

  http.Response _json(Object? value, http.Request request, [int status = 200]) =>
      http.Response(jsonEncode(value), status, request: request, headers: {'content-type': 'application/json'});

  late final transport = MockClient((request) async {
    requests.add('${request.url.path} ${request.body}');
    final name = request.url.pathSegments.last;
    final decoded = request.body.isEmpty ? null : jsonDecode(request.body);
    final body = decoded is Map ? Map<String, dynamic>.from(decoded) : <String, dynamic>{};
    if (name == 'finance_privacy_profile') {
      return _json({'encryption_required': encrypted, 'workspace_id': workspace, 'key_check': keyCheck}, request);
    }
    if (encrypted) {
      switch (name) {
        case 'finance_encrypted_snapshot':
          final kind = body['p_kind'] as String;
          return _json({'workspace_id': workspace, 'revision': revisions[kind], 'document': envelopes[kind]}, request);
        case 'finance_encrypted_save':
          final kind = body['p_kind'] as String;
          if (kind == 'finance') financeSaves++;
          envelopes[kind] = Map<String, dynamic>.from(body['p_envelope'] as Map);
          revisions[kind] = revisions[kind]! + 1;
          return _json({'workspace_id': workspace, 'revision': revisions[kind], 'document': envelopes[kind]}, request);
      }
      plaintextCalls.add(name);
      return _json({'message': 'not for guests', 'code': '42501'}, request, 403);
    }
    switch (name) {
      case 'finance_snapshot':
        return _json({'workspace_id': workspace, 'revision': revisions['finance'], 'document': document}, request);
      case 'finance_save_snapshot':
        financeSaves++;
        document = Map<String, dynamic>.from(body['p_document'] as Map);
        revisions['finance'] = revisions['finance']! + 1;
        return _json({'workspace_id': workspace, 'revision': revisions['finance'], 'document': document}, request);
    }
    return _json({'message': 'Fictitious learning unavailable', 'code': '42883'}, request, 404);
  });

  Future<SupabaseClient> client() async {
    final client = SupabaseClient('https://fictitious.invalid', 'fictitious-key',
        httpClient: transport, authOptions: const AuthClientOptions(autoRefreshToken: false));
    await client.auth.setInitialSession(jsonEncode({
      'access_token': 'fictitious-$user',
      'token_type': 'bearer',
      'user': {'id': user, 'aud': 'authenticated', 'created_at': '2026-01-01T00:00:00Z', 'app_metadata': {}, 'user_metadata': {}}
    }));
    return client;
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es'));
  late Directory device;
  setUp(() async {
    runTraining = <T>(T Function() work) async => work();
    CloudPrivacy.forgetAll();
    SharedPreferences.setMockInitialValues({});
  });
  setUpAll(() async => device = await Directory.systemTemp.createTemp('doblon-profiles'));
  tearDownAll(() async {
    try {
      await device.delete(recursive: true);
    } on FileSystemException catch (_) {}
  });

  final admin = Cloud('fictitious-admin',
      encrypted: false, document: finances(checking: 'Cuenta Alfa', savings: 'Ahorro Alfa', charge: 'Seguro Alfa', reserve: 'Reserva Alfa'));
  final guest = Cloud('fictitious-guest',
      encrypted: true, document: finances(checking: 'Cuenta Beta', savings: 'Ahorro Beta', charge: 'Recibo Beta', reserve: 'Reserva Beta'));

  Future<void> settle(WidgetTester tester, [int rounds = 8]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 40)));
      await tester.pump(const Duration(milliseconds: 300));
    }
  }

  /// Opens the app as [cloud]'s person on the same device, goes from Don Bigotes' notice to the forecast and saves a
  /// simulation there. Returns the repository.
  Future<FinanceRepository> session(WidgetTester tester, Cloud cloud, {required String checking, required String other, required String scenario}) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    late FinanceRepository repo;
    await tester.runAsync(() async {
      await cloud.prepare();
      FlutterSecureStorage.setMockInitialValues({...admin.secureStorage, ...guest.secureStorage});
      final client = await cloud.client();
      addTearDown(client.dispose);
      repo = FinanceRepository(store: LocalStore(device), cloudClient: client);
      await repo.refresh();
    });
    addTearDown(repo.dispose);
    expect(repo.error, isNull);
    expect(repo.isAdministrator, !cloud.encrypted, reason: 'The profile comes from the server, not from the app');
    final before = jsonEncode(repo.document);

    await tester.pumpWidget(MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: MediaQuery(data: const MediaQueryData(size: Size(400, 900), disableAnimations: true), child: Shell(preferences: AppPreferences(), repository: repo)),
    ));
    await settle(tester);

    // Inicio: the way to the forecast, in the Disponible card.
    expect(find.text('Ver previsión'), findsOneWidget);
    // Don Bigotes: the notice about this person's own account, and «Ver» opens that day and account.
    await tester.tap(find.byType(CompanionButton));
    await settle(tester, 3);
    final notice = find.textContaining('«$checking» podría quedarse sin saldo');
    expect(notice, findsOneWidget);
    expect(find.textContaining(other), findsNothing, reason: 'Never another person\'s accounts');
    final card = find.ancestor(of: notice, matching: find.byType(Card));
    await tester.tap(find.descendant(of: card, matching: find.text('Ver')));
    await settle(tester, 4);
    expect(find.byType(ForecastScreen), findsOneWidget);
    expect(find.text('Libre para gastar'), findsOneWidget);
    expect(find.widgetWithText(DropdownButton<String?>, checking), findsOneWidget, reason: 'Opened on the account of the notice');
    expect(find.textContaining('Descubierto ·'), findsOneWidget, reason: 'Don Bigotes points out the date inside the forecast');

    // A simulation, saved on this device only.
    await tester.scrollUntilVisible(find.text('Nueva simulación'), 300, scrollable: find.byType(Scrollable).last);
    await tester.ensureVisible(find.text('Nueva simulación'));
    await tester.pumpAndSettle(const Duration(milliseconds: 100), EnginePhase.sendSemanticsUpdate, const Duration(seconds: 2));
    await tester.tap(find.text('Nueva simulación'));
    await settle(tester, 2);
    await tester.enterText(find.widgetWithText(TextField, 'Nombre'), scenario);
    await tester.enterText(find.widgetWithText(TextField, 'Importe'), '150');
    await tester.tap(find.text('Guardar y comparar'));
    await settle(tester, 3);
    await tester.scrollUntilVisible(find.widgetWithText(ChoiceChip, scenario), 300, scrollable: find.byType(Scrollable).last);
    expect(find.widgetWithText(ChoiceChip, scenario), findsOneWidget);
    await tester.scrollUntilVisible(find.text('Tus reservas no se tocan.'), -300, scrollable: find.byType(Scrollable).last);
    expect(tester.takeException(), isNull);
    await settle(tester, 6); // lets the simulation's file finish writing

    expect(cloud.financeSaves, 0, reason: 'The forecast and the simulation never save the finances');
    expect(repo.pending, isEmpty);
    expect(jsonEncode(repo.document), before);
    expect(cloud.requests.any((r) => r.contains(scenario)), isFalse, reason: 'The simulation never travels to the cloud');
    await tester.pumpWidget(const SizedBox());
    return repo;
  }

  testWidgets('developer\'s session: forecast, simulation and Don Bigotes, without encryption', (tester) async {
    final repo = await session(tester, admin, checking: 'Cuenta Alfa', other: 'Beta', scenario: 'Simulación Alfa');
    expect(repo.forecast!.scenarios.map((s) => s.name), ['Simulación Alfa']);
  });

  testWidgets('guest\'s session: the same, with encrypted cloud only and nothing in plaintext', (tester) async {
    final repo = await session(tester, guest, checking: 'Cuenta Beta', other: 'Alfa', scenario: 'Simulación Beta');
    expect(repo.forecast!.scenarios.map((s) => s.name), ['Simulación Beta'], reason: 'The developer\'s simulation, saved on this device, is not here');
    expect(guest.plaintextCalls, isEmpty, reason: 'A guest never uses the plaintext API');
    for (final secret in ['Cuenta Beta', 'Reserva Beta', 'Recibo Beta']) {
      expect(guest.requests.any((r) => r.contains(secret)), isFalse, reason: 'Only sealed envelopes leave the device');
    }
  });

  test('on the device each person has their own file, and signing out deletes it', () async {
    final files = device.listSync().map((f) => f.uri.pathSegments.last).where((n) => n.startsWith('forecast-')).toList()..sort();
    expect(files, ['forecast-fictitious-admin.json', 'forecast-fictitious-guest.json']);
    final adminFile = jsonDecode(await ForecastStore.fileFor(device, 'fictitious-admin').readAsString()).toString();
    final guestFile = jsonDecode(await ForecastStore.fileFor(device, 'fictitious-guest').readAsString()).toString();
    expect(adminFile, contains('Simulación Alfa'));
    expect(adminFile, isNot(contains('Beta')));
    expect(guestFile, contains('Simulación Beta'));
    expect(guestFile, isNot(contains('Alfa')));

    FlutterSecureStorage.setMockInitialValues(guest.secureStorage);
    final client = await guest.client();
    addTearDown(client.dispose);
    final repo = FinanceRepository(store: LocalStore(device), cloudClient: client);
    addTearDown(repo.dispose);
    await repo.signOut();
    expect(ForecastStore.fileFor(device, 'fictitious-guest').existsSync(), isFalse);
    expect(ForecastStore.fileFor(device, 'fictitious-admin').existsSync(), isTrue);
  });
}
