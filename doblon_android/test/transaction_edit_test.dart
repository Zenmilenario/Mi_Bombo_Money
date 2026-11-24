// Fictitious data only. Editing a movement's category (24 November 2026). The bug seen on the iPhone: saving and
// tapping fast with the category menu open left the menu orphaned on top while the screens below kept closing,
// down to a black screen. The cause: after saving, the form closed «whatever was on top» (Navigator.pop), which was
// the menu; that pop fails (the menu expects another kind of result), the failure was taken for a failed save, the
// button came back and the next tap saved and popped again. These tests repeat the interaction for the developer's
// session and for an encrypted guest, and check what is really saved and how many times.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/data.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/screens/navigation.dart';
import 'package:doblon/screens/transaction_detail.dart';
import 'package:doblon/screens/transaction_form.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'forecast_profiles_test.dart' as profiles show Cloud, finances, seconds;

/// Records every route opened and closed.
class Routes extends NavigatorObserver {
  final pushed = <String>[], popped = <String>[];
  @override
  void didPush(Route route, Route? previousRoute) => pushed.add('${route.runtimeType}');
  @override
  void didPop(Route route, Route? previousRoute) => popped.add('${route.runtimeType}');
}

/// A repository whose next save fails before reaching the cloud (as a full disk would).
class FailingOnce extends FinanceRepository {
  FailingOnce({super.store, super.cloudClient});
  bool fail = true;
  @override
  Future<void> apply(Operation op) async {
    if (fail) {
      fail = false;
      throw StateError('Fictitious failure');
    }
    return super.apply(op);
  }
}

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  setUpAll(() => initializeDateFormatting('es'));
  setUp(() {
    runTraining = <T>(T Function() work) async => work();
    CloudPrivacy.forgetAll();
    SharedPreferences.setMockInitialValues({});
  });

  Map<String, dynamic> document() {
    final doc = profiles.finances(checking: 'Cuenta', savings: 'Ahorro', charge: 'Seguro', reserve: 'Reserva');
    doc['categories'] = [
      {'id': 'compras', 'name': 'Compras', 'kindRaw': 'expense'},
      {'id': 'ocio', 'name': 'Ocio', 'kindRaw': 'expense'},
    ];
    doc['transactions'] = [
      {
        'id': 't',
        'date': profiles.seconds(DateTime(2026, 11, 20, 12)),
        'typeRaw': 'expense',
        'amountMinor': 1234,
        'descriptionText': 'Compra ficticia',
        'notes': 'Nota ficticia',
        'sourceAccountID': 'Cuenta-id',
        'categoryID': 'compras',
      },
    ];
    return doc;
  }

  /// Opens Inicio → the movement's detail → «Editar». Returns the repository, the cloud and the route log.
  Future<(FinanceRepository, profiles.Cloud, Routes)> openEditor(WidgetTester tester,
      {bool encrypted = false, FinanceRepository Function(LocalStore, dynamic)? make}) async {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final cloud = profiles.Cloud(encrypted ? 'fictitious-guest' : 'fictitious-admin', encrypted: encrypted, document: document());
    late FinanceRepository repo;
    await tester.runAsync(() async {
      await cloud.prepare();
      FlutterSecureStorage.setMockInitialValues(cloud.secureStorage);
      final directory = await Directory.systemTemp.createTemp('doblon-edit');
      addTearDown(() async {
        try {
          await directory.delete(recursive: true);
        } on FileSystemException catch (_) {}
      });
      final client = await cloud.client();
      addTearDown(client.dispose);
      final store = LocalStore(directory);
      repo = make == null ? FinanceRepository(store: store, cloudClient: client) : make(store, client);
      await repo.refresh();
    });
    addTearDown(repo.dispose);
    expect(repo.isAdministrator, !encrypted);
    final routes = Routes();
    await tester.pumpWidget(MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      navigatorObservers: [routes],
      home: Builder(
        builder: (context) => Scaffold(
          body: Center(
            child: TextButton(
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: repo, transactionId: 't'))),
              child: const Text('Inicio'),
            ),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Inicio'));
    await tester.pumpAndSettle();
    await tester.tap(find.byTooltip('Editar'));
    await tester.pumpAndSettle();
    expect(find.byType(TransactionFormScreen), findsOneWidget);
    return (repo, cloud, routes);
  }

  Future<void> settle(WidgetTester tester, [int rounds = 60]) async {
    for (var i = 0; i < rounds; i++) {
      await tester.runAsync(() => Future<void>.delayed(const Duration(milliseconds: 20)));
      await tester.pump(const Duration(milliseconds: 100));
    }
  }

  Map<String, dynamic> saved(profiles.Cloud cloud, FinanceRepository repo) =>
      Map<String, dynamic>.from((repo.document!['transactions'] as List).single as Map);

  /// Where the person is afterwards: the detail of the movement, with Inicio underneath, nothing orphaned on top.
  void backOnTheDetail(WidgetTester tester, Routes routes) {
    expect(find.byType(TransactionFormScreen), findsNothing);
    expect(find.byType(TransactionDetailScreen), findsOneWidget);
    expect(find.text('Inicio', skipOffstage: false), findsOneWidget, reason: 'The main screen is never closed');
    expect(routes.popped.where((r) => r.startsWith('MaterialPageRoute')).length, 1, reason: 'Only the form closes');
    expect(routes.popped.where((r) => r.contains('Dropdown')).length, routes.pushed.where((r) => r.contains('Dropdown')).length,
        reason: 'Every category menu opened was closed: none left orphaned');
    expect(tester.takeException(), isNull);
  }

  for (final encrypted in [false, true]) {
    final who = encrypted ? 'guest' : 'developer';

    testWidgets('$who: the fast sequence (save, open the category menu, tap again and again) saves once and closes only the form', (tester) async {
      final (repo, cloud, routes) = await openEditor(tester, encrypted: encrypted);
      cloud.saveDelay = const Duration(milliseconds: 600); // a save that takes a moment, as on the phone
      final save = tester.getCenter(find.text('Guardar cambios'));
      final menu = tester.getCenter(find.text('Compras'));
      await tester.tapAt(save);
      await tester.pump(const Duration(milliseconds: 16));
      await tester.tapAt(menu); // the category menu, while it saves
      await tester.pump(const Duration(milliseconds: 40));
      expect(find.text('Guardando…'), findsOneWidget);
      for (var i = 0; i < 6; i++) {
        await tester.tapAt(save);
        await tester.pump(const Duration(milliseconds: 50));
        await tester.tapAt(menu);
        await tester.pump(const Duration(milliseconds: 50));
      }
      await settle(tester);
      expect(routes.pushed.where((r) => r.contains('Dropdown')), isEmpty, reason: 'No menu opens over a form that is saving');
      backOnTheDetail(tester, routes);
      expect(cloud.financeSaves, 1, reason: 'One save');
      final t = saved(cloud, repo);
      expect((t['categoryID'], t['amountMinor'], t['descriptionText'], t['notes']), ('compras', 1234, 'Compra ficticia', 'Nota ficticia'), reason: 'Nothing lost');
      expect((repo.document!['transactions'] as List).length, 1, reason: 'No duplicate');
      if (encrypted) expect(cloud.plaintextCalls, isEmpty);
    });

    testWidgets('$who: choosing a category and saving changes only the category', (tester) async {
      final (repo, cloud, routes) = await openEditor(tester, encrypted: encrypted);
      await tester.tap(find.text('Compras'));
      await tester.pumpAndSettle();
      await tester.tap(find.text('Ocio').last);
      await tester.pumpAndSettle();
      await tester.tap(find.text('Guardar cambios'));
      await settle(tester);
      backOnTheDetail(tester, routes);
      expect(cloud.financeSaves, 1);
      expect((saved(cloud, repo)['categoryID'], saved(cloud, repo)['notes']), ('ocio', 'Nota ficticia'));
    });
  }

  testWidgets('opening the menu and closing it without choosing keeps the category', (tester) async {
    final (repo, cloud, routes) = await openEditor(tester);
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    expect(find.text('Ocio'), findsOneWidget);
    await tester.tapAt(const Offset(10, 10)); // outside the menu: cancelled
    await tester.pumpAndSettle();
    expect(find.text('Ocio'), findsNothing);
    await tester.tap(find.text('Guardar cambios'));
    await settle(tester);
    backOnTheDetail(tester, routes);
    expect(saved(cloud, repo)['categoryID'], 'compras');
  });

  testWidgets('choosing «Sin categoría» explicitly leaves it without one (allowed for an expense)', (tester) async {
    final (repo, cloud, routes) = await openEditor(tester);
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sin categoría').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar cambios'));
    await settle(tester);
    backOnTheDetail(tester, routes);
    expect(saved(cloud, repo)['categoryID'], isNull);
    expect(cloud.financeSaves, 1);
  });

  testWidgets('going back with the menu open closes only the menu; back again leaves without saving', (tester) async {
    final (repo, cloud, routes) = await openEditor(tester);
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    await tester.binding.handlePopRoute(); // the system's back
    await tester.pumpAndSettle();
    expect(find.text('Ocio'), findsNothing);
    expect(find.byType(TransactionFormScreen), findsOneWidget);
    await tester.binding.handlePopRoute();
    await tester.pumpAndSettle();
    backOnTheDetail(tester, routes);
    expect(cloud.financeSaves, 0);
    expect(saved(cloud, repo)['categoryID'], 'compras');
  });

  testWidgets('a slow save: «Guardando…», nothing can be touched meanwhile, then the form closes', (tester) async {
    final (repo, cloud, routes) = await openEditor(tester);
    cloud.saveDelay = const Duration(seconds: 2);
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ocio').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar cambios'));
    await tester.pump();
    expect(find.text('Guardando…'), findsOneWidget);
    await tester.tap(find.text('Ocio'), warnIfMissed: false);
    await tester.pump(const Duration(milliseconds: 100));
    expect(routes.pushed.where((r) => r.contains('Dropdown')).length, 1, reason: 'Only the one opened before saving');
    await settle(tester, 80);
    backOnTheDetail(tester, routes);
    expect((cloud.financeSaves, saved(cloud, repo)['categoryID']), (1, 'ocio'));
  });

  testWidgets('the cloud refuses the save: the edit is kept on the device and uploaded later, once', (tester) async {
    final (repo, cloud, routes) = await openEditor(tester);
    cloud.failingSaves = 3;
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ocio').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar cambios'));
    await settle(tester);
    backOnTheDetail(tester, routes);
    expect(cloud.financeSaves, 0);
    expect(repo.pending.length, 1, reason: 'Kept, waiting for the connection');
    expect(saved(cloud, repo)['categoryID'], 'ocio', reason: 'Shown with the change');
    cloud.failingSaves = 0;
    // The next opening uploads what was kept (its queue lives in the test's clock, so both clocks are moved on).
    final upload = repo.refresh();
    await settle(tester, 20);
    await upload;
    expect((cloud.financeSaves, repo.pending.length), (1, 0));
    expect(jsonEncode(cloud.document), contains('"categoryID":"ocio"'));
  });

  testWidgets('a save that fails on the device keeps the form with what was typed, and saving again works once', (tester) async {
    final (repo, cloud, routes) = await openEditor(tester, make: (store, client) => FailingOnce(store: store, cloudClient: client));
    await tester.tap(find.text('Compras'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Ocio').last);
    await tester.pumpAndSettle();
    await tester.tap(find.text('Guardar cambios'));
    await settle(tester, 6);
    expect(find.byType(TransactionFormScreen), findsOneWidget);
    expect(find.textContaining('No se ha podido guardar'), findsOneWidget);
    expect(find.text('Ocio'), findsOneWidget, reason: 'The choice is still there');
    expect(cloud.financeSaves, 0);
    await tester.tap(find.text('Guardar cambios'));
    await settle(tester);
    backOnTheDetail(tester, routes);
    expect((cloud.financeSaves, saved(cloud, repo)['categoryID']), (1, 'ocio'));
  });

  testWidgets('closing a screen with a menu still open closes the menu as cancelled, then only that screen', (tester) async {
    final routes = Routes();
    late BuildContext screen;
    String? chosen = 'start';
    Object? result;
    await tester.pumpWidget(MaterialApp(
      navigatorObservers: [routes],
      home: Builder(
        builder: (context) => Scaffold(
          body: TextButton(
            onPressed: () async => result = await Navigator.of(context).push<bool>(MaterialPageRoute(builder: (context) {
              screen = context;
              return Scaffold(
                body: Center(
                  child: DropdownButton<String?>(
                      value: null,
                      items: const [DropdownMenuItem(value: null, child: Text('Sin categoría')), DropdownMenuItem(value: 'a', child: Text('Compras'))],
                      onChanged: (v) => chosen = v),
                ),
              );
            })),
            child: const Text('Inicio'),
          ),
        ),
      ),
    ));
    await tester.tap(find.text('Inicio'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Sin categoría'));
    await tester.pumpAndSettle();
    // What `Navigator.pop(true)` did here: fail on the menu. The shared close does not.
    expect(() => Navigator.of(screen).pop(true), throwsA(anything));
    closeOwnScreen(screen, true);
    await tester.pumpAndSettle();
    expect(routes.popped, ['_DropdownRoute<String?>', 'MaterialPageRoute<bool>']);
    expect(result, true);
    expect(chosen, 'start', reason: 'The menu chose nothing');
    expect(find.text('Inicio'), findsOneWidget);
    expect(find.text('Compras'), findsNothing);
    expect(tester.takeException(), isNull);
  });
}
