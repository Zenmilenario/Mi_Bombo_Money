// Fictitious data only. «Previsión y simulaciones» (23 November 2026): it fits a phone and an iPad, says it is an
// estimate, and a simulation is compared with the forecast without saving anything in the person's finances.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/screens/forecast_screen.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

num seconds(DateTime date) => date.millisecondsSinceEpoch / 1000 - 978307200;

class _Cloud {
  _Cloud() {
    final now = DateTime.now();
    document = {
      'formatVersion': 2,
      'accounts': [
        {'id': 'a', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingDate': seconds(DateTime(2025)), 'currencyCode': 'EUR'},
        {'id': 'b', 'name': 'Ahorro ficticio', 'typeRaw': 'savings', 'openingDate': seconds(DateTime(2025)), 'currencyCode': 'EUR'},
      ],
      'snapshots': [
        {'id': 's1', 'accountID': 'a', 'balanceMinor': 120000, 'date': seconds(now.subtract(const Duration(hours: 1))), 'sourceRaw': 'bankAPI'},
        {'id': 's2', 'accountID': 'b', 'balanceMinor': 300000, 'date': seconds(now.subtract(const Duration(hours: 1))), 'sourceRaw': 'manual'},
      ],
      'reservedFunds': [
        {'id': 'f', 'name': 'Vacaciones', 'amountMinor': 50000, 'accountID': 'b', 'createdAt': seconds(DateTime(2025, 6))},
      ],
      'recurringMovements': [
        {
          'id': 'r',
          'name': 'Alquiler ficticio',
          'typeRaw': 'expense',
          'amountMinor': 90000,
          'descriptionText': 'Alquiler',
          'frequencyRaw': 'monthly',
          'interval': 1,
          'nextDueDate': seconds(now.add(const Duration(days: 5))),
          'isActive': true,
          'sourceAccountID': 'a',
        }
      ],
      'transactions': [],
      'categories': [],
    };
  }

  late Map<String, dynamic> document;
  int saves = 0;
  http.Response json(Object value, http.Request request, [int status = 200]) =>
      http.Response(jsonEncode(value), status, request: request, headers: {'content-type': 'application/json'});
  late final transport = MockClient((request) async {
    final path = request.url.path;
    if (path.endsWith('/finance_privacy_profile')) return json({'encryption_required': false, 'workspace_id': 'w', 'key_check': null}, request);
    if (path.endsWith('/finance_snapshot')) return json({'workspace_id': 'w', 'revision': 1, 'document': document}, request);
    if (path.endsWith('/finance_save_snapshot')) {
      saves++;
      return json({'workspace_id': 'w', 'revision': 2, 'document': document}, request);
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

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  FlutterSecureStorage.setMockInitialValues({});
  setUpAll(() => initializeDateFormatting('es'));
  setUp(() {
    runTraining = <T>(T Function() work) async => work();
    CloudPrivacy.forgetAll();
  });

  Future<(FinanceRepository, _Cloud)> open(WidgetTester tester) async {
    late FinanceRepository repo;
    final cloud = _Cloud();
    await tester.runAsync(() async {
      final directory = await Directory.systemTemp.createTemp('doblon-forecast-screen');
      // The simulation's file may still be held open by a write of the test zone on Windows: a temporary folder.
      addTearDown(() async {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException catch (_) {}
      });
      final client = await cloud.client();
      addTearDown(client.dispose);
      repo = FinanceRepository(store: LocalStore(directory), cloudClient: client);
      await repo.refresh();
    });
    addTearDown(repo.dispose);
    return (repo, cloud);
  }

  Widget app(FinanceRepository repo) => MaterialApp(
        theme: doblonTheme(Brightness.light),
        locale: const Locale('es', 'ES'),
        supportedLocales: const [Locale('es', 'ES')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        home: ForecastScreen(repository: repo),
      );

  for (final (name, size) in [('phone', const Size(375, 812)), ('iPad', const Size(1024, 1366))]) {
    testWidgets('fits a $name and says what it is', (tester) async {
      tester.view.physicalSize = size;
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final (repo, _) = await open(tester);
      await tester.pumpWidget(app(repo));
      await tester.pumpAndSettle();
      expect(find.text('Estimación con tus supuestos, no una garantía.'), findsOneWidget);
      expect(find.text('Mínimo libre previsto'), findsOneWidget);
      expect(find.textContaining('Parte de hoy: 1 saldo del banco, 1 indicados por ti'), findsOneWidget);
      expect(tester.takeException(), isNull);
    });
  }

  testWidgets('a simulation is compared with the forecast and nothing reaches the finances', (tester) async {
    tester.view.physicalSize = const Size(400, 900);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final (repo, cloud) = await open(tester);
    final before = jsonEncode(repo.document);
    await tester.pumpWidget(app(repo));
    await tester.pumpAndSettle();

    await tester.tap(find.text('Simular'));
    await tester.pumpAndSettle();
    expect(find.text('Nueva simulación'), findsOneWidget);
    await tester.enterText(find.widgetWithText(TextField, 'Importe'), '400');
    await tester.tap(find.text('Guardar y comparar'));
    await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 100)));
    await tester.pumpAndSettle();

    expect(find.widgetWithText(ChoiceChip, 'Compra puntual'), findsOneWidget);
    expect(find.text('Tus reservas no se tocan.'), findsOneWidget);
    expect(find.textContaining('frente a la previsión'), findsOneWidget);
    expect(repo.forecast!.scenarios.single.changes.single.amountMinor, 40000);
    expect(cloud.saves, 0, reason: 'A simulation is never saved in the cloud document');
    expect(repo.pending, isEmpty, reason: 'Nor queued as a change');
    expect(jsonEncode(repo.document), before, reason: 'The finances are exactly as they were');
  });
}
