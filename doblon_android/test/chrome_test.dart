// Fictitious data only. The frame of the tabs (17 November 2026): «+ Añadir» at the bottom in one tap, Don Bigotes
// beside it without covering anything, a header that hides while scrolling down, and room for the last item.
import 'package:doblon/automation.dart' show CompanionNote;
import 'package:doblon/finance.dart';
import 'package:doblon/screens/chrome.dart';
import 'package:doblon/screens/home.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

import 'home_test.dart' show sample;

Widget app(Widget child, {Brightness brightness = Brightness.light, double text = 1, EdgeInsets padding = EdgeInsets.zero}) => MaterialApp(
      theme: doblonTheme(brightness),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: Builder(
        builder: (context) => MediaQuery(
          data: MediaQuery.of(context).copyWith(textScaler: TextScaler.linear(text), padding: padding),
          child: Scaffold(body: child),
        ),
      ),
    );

final notes = [
  CompanionNote(id: 'a', title: 'Aviso ficticio', detail: '', tab: 1),
  CompanionNote(id: 'b', title: 'Otro aviso ficticio', detail: '', tab: 2),
];

void main() {
  setUpAll(() => initializeDateFormatting('es'));

  test('the header follows the finger and is always shown at the top', () {
    expect(nextHeaderShown(1, headerHeight / 2, 200), 0.5);
    expect(nextHeaderShown(0.5, headerHeight, 400), 0, reason: 'Hidden while going down');
    expect(nextHeaderShown(0, -headerHeight / 4, 300), 0.25, reason: 'Comes back while going up');
    expect(nextHeaderShown(0, 10, 0), 1, reason: 'At the top it is shown');
  });

  testWidgets('a hidden header takes no room, cannot be tapped and is not read', (tester) async {
    final shown = AnimationController(vsync: const TestVSync(), value: 1);
    await tester.pumpWidget(app(
        Align(
          alignment: Alignment.topCenter,
          child: ShellHeader(shown: shown, title: const Text('Movimientos'), actions: [IconButton(tooltip: 'Ocultar importes', onPressed: () {}, icon: const Icon(Icons.visibility))]),
        ),
        padding: const EdgeInsets.only(top: 40)));
    expect(tester.getSize(find.byType(ShellHeader)).height, 40 + headerHeight);
    expect(find.byTooltip('Ocultar importes'), findsOneWidget);
    shown.value = 0;
    await tester.pump();
    expect(tester.getSize(find.byType(ShellHeader)).height, 40, reason: 'Only the status bar strip stays');
    expect(find.bySemanticsLabel('Ocultar importes'), findsNothing);
    shown.dispose();
  });

  testWidgets('«+ Añadir» opens the form in one tap and Don Bigotes is a separate button', (tester) async {
    var added = 0, opened = 0, closed = 0;
    await tester.pumpWidget(app(Align(
      alignment: Alignment.bottomRight,
      child: BottomDock(onAdd: () => added++, notes: notes, onCompanion: () => opened++, teaser: true, onCloseTeaser: () => closed++),
    )));
    await tester.tap(find.text('Añadir'));
    expect(added, 1);
    expect(opened, 0);
    await tester.tap(find.byType(CompanionButton));
    expect(opened, 1);
    expect(find.text('Tengo 2 avisos'), findsOneWidget, reason: 'The bubble, beside the buttons');
    await tester.tap(find.byTooltip('Cerrar el aviso'));
    expect(closed, 1);
    final add = tester.getRect(find.text('Añadir'));
    final cat = tester.getRect(find.byType(CompanionButton));
    expect(add.right, lessThan(cat.left), reason: 'They do not overlap');
  });

  testWidgets('the dock fits a small phone with very large text', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(
        Padding(
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Align(alignment: Alignment.bottomRight, child: BottomDock(onAdd: () {}, notes: notes, teaser: true)),
        ),
        text: 2.5));
    expect(tester.takeException(), isNull);
    expect(tester.getRect(find.byType(BottomDock)).left, greaterThanOrEqualTo(16));
  });

  test('the bubble shows once for each new set of notes and can be closed', () {
    var changes = 0;
    final teaser = TeaserTimer(() => changes++);
    teaser.update(notes);
    expect(teaser.visible, isTrue);
    teaser.close();
    expect(teaser.visible, isFalse);
    expect(changes, 1);
    teaser.update(notes);
    expect(teaser.visible, isFalse, reason: 'Not again for the same notes');
    teaser.update([notes.first]);
    expect(teaser.visible, isTrue, reason: 'Again when they change');
    teaser.dispose();
  });

  for (final brightness in Brightness.values) {
    testWidgets('Inicio leaves its last item above the dock, ${brightness.name}', (tester) async {
      tester.view.physicalSize = const Size(375, 667);
      tester.view.devicePixelRatio = 1;
      addTearDown(tester.view.reset);
      final now = DateTime.now();
      const bottom = 80.0, top = 20 + headerHeight;
      await tester.pumpWidget(app(HomeScreen(calc: FinanceCalculator(sample(now)), month: DateTime(now.year, now.month), onMonth: (_) {}),
          brightness: brightness, padding: const EdgeInsets.only(top: top, bottom: bottom)));
      await tester.pumpAndSettle();
      expect(tester.getTopLeft(find.text('Disponible para usar')).dy, greaterThanOrEqualTo(top), reason: 'Below the header');
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      // The end is only known once the items below are laid out.
      for (var i = 0; i < 10 && list.pixels < list.maxScrollExtent; i++) {
        list.jumpTo(list.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      final last = tester.getRect(find.ancestor(of: find.text('Últimos movimientos del mes'), matching: find.byType(Card)).first);
      expect(last.bottom, lessThanOrEqualTo(667 - bottom - dockReserve + 1), reason: 'The last movement scrolls fully above the dock');
    });
  }

  testWidgets('Inicio with very large text on a small phone does not overflow', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    final now = DateTime.now();
    await tester.pumpWidget(app(HomeScreen(calc: FinanceCalculator(sample(now)), month: DateTime(now.year, now.month), onMonth: (_) {}), text: 2));
    await tester.pumpAndSettle();
    expect(tester.takeException(), isNull);
    expect(find.text('Disponible para usar'), findsOneWidget);
  });
}
