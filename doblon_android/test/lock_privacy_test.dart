// Fictitious data only. Locking and privacy (18 November 2026): nothing of the finances is seen before unlocking,
// also while switching apps; Face ID can be tried again; the account password unlocks too; cancelling never signs
// out; and after unlocking the person is where they were, also on a screen opened on top.
import 'package:doblon/main.dart';
import 'package:doblon/preferences.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

/// A tab with a counter, and a detail screen opened on top, both with an amount that must stay hidden.
class _Finances extends StatefulWidget {
  const _Finances();
  @override
  State<_Finances> createState() => _FinancesState();
}

/// How many times the finances were built from scratch (loading and computing them is what is costly).
int starts = 0;

class _FinancesState extends State<_Finances> {
  int tab = 0;

  @override
  void initState() {
    super.initState();
    starts++;
  }

  @override
  Widget build(BuildContext context) => Scaffold(
        body: Column(children: [
          Text('Saldo ficticio 1.234,56 € · pestaña $tab'),
          TextButton(onPressed: () => setState(() => tab++), child: const Text('Otra pestaña')),
          TextButton(
            onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => const Scaffold(body: Text('Detalle ficticio 99,00 €')))),
            child: const Text('Abrir detalle'),
          ),
        ]),
      );
}

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  late int asked;
  late bool face;
  late List<(String, String)> passwords;

  Widget app(AppPreferences preferences) => MaterialApp(
        theme: doblonTheme(Brightness.light),
        locale: const Locale('es', 'ES'),
        supportedLocales: const [Locale('es', 'ES')],
        localizationsDelegates: GlobalMaterialLocalizations.delegates,
        builder: (context, child) => LockGate(
          preferences: preferences,
          authenticator: (_) async {
            asked++;
            return face;
          },
          passwordCheck: (email, password) async {
            passwords.add((email, password));
            return password == 'contraseña-ficticia' ? null : 'Correo o contraseña incorrectos.';
          },
          child: child!,
        ),
        home: const _Finances(),
      );

  setUp(() {
    starts = 0;
    asked = 0;
    face = false;
    passwords = [];
  });

  void lifecycle(WidgetTester tester, List<AppLifecycleState> states) {
    for (final s in states) {
      tester.binding.handleAppLifecycleStateChanged(s);
    }
  }

  void tall(WidgetTester tester) {
    tester.view.physicalSize = const Size(400, 1400);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
  }

  testWidgets('on opening, nothing is shown until unlocked; a failed Face ID can be tried again', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(AppPreferences()..lockEnabled = true));
    await tester.pumpAndSettle();
    expect(asked, 1, reason: 'Face ID is tried at once');
    expect(find.textContaining('1.234,56'), findsNothing, reason: 'Not painted, not read');
    expect(find.text('Volver a intentar con Face ID o huella'), findsOneWidget, reason: 'After a failure or a cancel');
    expect(find.text('Entrar con correo y contraseña'), findsOneWidget);
    face = true;
    await tester.tap(find.text('Volver a intentar con Face ID o huella'));
    await tester.pumpAndSettle();
    expect(asked, 2);
    expect(find.textContaining('1.234,56'), findsOneWidget);
  });

  testWidgets('the password unlocks without signing out; a wrong one keeps it locked and says why', (tester) async {
    tall(tester);
    await tester.pumpWidget(app(AppPreferences()..lockEnabled = true));
    await tester.pumpAndSettle();
    await tester.enterText(find.widgetWithText(TextField, 'Correo'), 'persona@ejemplo.test');
    await tester.enterText(find.widgetWithText(TextField, 'Contraseña'), 'otra');
    await tester.tap(find.text('Entrar con correo y contraseña'));
    await tester.pumpAndSettle();
    expect(find.text('Correo o contraseña incorrectos.'), findsOneWidget);
    expect(find.textContaining('1.234,56'), findsNothing);
    await tester.enterText(find.widgetWithText(TextField, 'Contraseña'), 'contraseña-ficticia');
    await tester.tap(find.text('Entrar con correo y contraseña'));
    await tester.pumpAndSettle();
    expect(passwords.last, ('persona@ejemplo.test', 'contraseña-ficticia'), reason: 'Through the existing sign-in');
    expect(find.textContaining('1.234,56'), findsOneWidget);
  });

  testWidgets('switching apps hides everything at once; the Face ID sheet never asks again in a loop', (tester) async {
    face = true;
    await tester.pumpWidget(app(AppPreferences()..lockEnabled = true));
    await tester.pumpAndSettle();
    expect(find.textContaining('1.234,56'), findsOneWidget);
    lifecycle(tester, [AppLifecycleState.inactive]);
    await tester.pump();
    expect(find.textContaining('1.234,56'), findsNothing, reason: 'Covered as soon as it is not in front (recent apps)');
    expect(find.byType(PrivacyCover), findsOneWidget);
    lifecycle(tester, [AppLifecycleState.resumed]);
    await tester.pump();
    expect(find.textContaining('1.234,56'), findsOneWidget, reason: 'A notification pulled down is not the background');
    expect(asked, 1);
  });

  testWidgets('after the background it stays hidden until unlocked, and returns to the same tab and screen', (tester) async {
    tall(tester);
    face = true;
    await tester.pumpWidget(app(AppPreferences()..lockEnabled = true));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Otra pestaña'));
    await tester.tap(find.text('Abrir detalle'));
    await tester.pumpAndSettle();
    expect(find.text('Detalle ficticio 99,00 €'), findsOneWidget);
    face = false;
    lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.pump();
    lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pump();
    expect(find.textContaining('99,00'), findsNothing, reason: 'The screen opened on top is covered too');
    await tester.pumpAndSettle();
    expect(asked, 2);
    expect(find.textContaining('99,00'), findsNothing, reason: 'Cancelled: still locked, session kept');
    expect(passwords, isEmpty);
    face = true;
    await tester.tap(find.text('Volver a intentar con Face ID o huella'));
    await tester.pumpAndSettle();
    expect(find.text('Detalle ficticio 99,00 €'), findsOneWidget, reason: 'Back on the same screen');
    Navigator.of(tester.element(find.text('Detalle ficticio 99,00 €'))).pop();
    await tester.pumpAndSettle();
    expect(find.textContaining('pestaña 1'), findsOneWidget, reason: 'And the same tab');
  });

  testWidgets('without the lock, nothing is covered or asked', (tester) async {
    await tester.pumpWidget(app(AppPreferences()..lockEnabled = false));
    await tester.pumpAndSettle();
    lifecycle(tester, [AppLifecycleState.inactive]);
    await tester.pump();
    expect(find.textContaining('1.234,56'), findsOneWidget);
    expect(asked, 0);
  });

  testWidgets('the finances are not loaded under the lock on opening (it delayed Face ID), and are kept afterwards', (tester) async {
    await tester.pumpWidget(app(AppPreferences()..lockEnabled = true));
    await tester.pump();
    expect(starts, 0, reason: 'Nothing is loaded while Face ID is asked on opening');
    expect(appLocked.value, isTrue);
    face = true;
    await tester.tap(find.text('Volver a intentar con Face ID o huella'));
    await tester.pumpAndSettle();
    expect(starts, 1);
    expect(appLocked.value, isFalse, reason: 'Work waiting for the unlock can start');
    lifecycle(tester, [AppLifecycleState.inactive, AppLifecycleState.hidden, AppLifecycleState.paused]);
    await tester.pump();
    lifecycle(tester, [AppLifecycleState.hidden, AppLifecycleState.inactive, AppLifecycleState.resumed]);
    await tester.pumpAndSettle();
    expect(starts, 1, reason: 'Kept alive under later locks: back where it was, without loading again');
  });
}
