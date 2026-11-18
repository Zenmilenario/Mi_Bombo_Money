// Fictitious data only. The frame of the tabs (17 November 2026): «+ Añadir» at the bottom in one tap, Don Bigotes
// beside it without covering anything, a header that hides while scrolling down, and room for the last item.
import 'dart:io';

import 'package:doblon/automation.dart' show CompanionNote;
import 'package:doblon/finance.dart';
import 'package:doblon/screens/chrome.dart';
import 'package:doblon/screens/home.dart';
import 'package:doblon/screens/widgets.dart' show LabelValues;
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
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

/// The real Roboto of the Flutter SDK, so text widths are measured as on Android (the test font draws squares).
Future<void> loadRoboto() async {
  final root = '${File(Platform.resolvedExecutable).parent.parent.parent.path}/material_fonts';
  final roboto = FontLoader('Roboto');
  for (final f in ['roboto-regular.ttf', 'roboto-medium.ttf', 'roboto-bold.ttf', 'roboto-black.ttf']) {
    roboto.addFont(Future.value(ByteData.sublistView(File('$root/$f').readAsBytesSync())));
  }
  await roboto.load();
}

void main() {
  setUpAll(() async {
    await initializeDateFormatting('es');
    await loadRoboto();
  });

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
          child: ShellHeader(
              shown: shown,
              title: const Text('Movimientos'),
              actions: [IconButton(tooltip: 'Ocultar importes', onPressed: () {}, icon: const Icon(Icons.visibility))]),
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

  testWidgets('«+ Añadir» and Don Bigotes float apart, small, with a full touch area and no band behind', (tester) async {
    var added = 0, opened = 0;
    await tester.pumpWidget(app(Align(
      alignment: Alignment.bottomCenter,
      child: FloatingActions(onAdd: () => added++, notes: notes, onCompanion: () => opened++),
    )));
    await tester.tap(find.text('Añadir'));
    expect(added, 1);
    expect(opened, 0);
    await tester.tap(find.byType(CompanionButton));
    expect(opened, 1, reason: 'The notices open from the cat');
    expect(find.text('2'), findsOneWidget, reason: 'Only a counter, no long capsule');
    expect(find.text('Aviso ficticio'), findsNothing);
    final cat = tester.getRect(find.byType(CompanionButton)), add = tester.getRect(find.byType(AddButton));
    expect(cat.right, lessThan(add.left), reason: 'Apart');
    expect(cat.height, greaterThanOrEqualTo(48));
    expect(tester.getSize(find.byType(FilledButton)).height, greaterThanOrEqualTo(48), reason: 'Touch area of «Añadir»');
    expect(find.byType(ColoredBox).evaluate().where((e) => (e.widget as ColoredBox).color.a == 1), isEmpty, reason: 'No band');
  });

  testWidgets('without Don Bigotes the notices stay one tap away; very large text fits', (tester) async {
    tester.view.physicalSize = const Size(320, 640);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(app(Align(alignment: Alignment.bottomCenter, child: FloatingActions(onAdd: () {}, notes: notes, companion: false)), text: 2.5));
    expect(tester.takeException(), isNull);
    expect(find.byType(CompanionButton), findsNothing);
    expect(find.bySemanticsLabel('2 avisos pendientes'), findsOneWidget);
  });

  test('tab labels are shown only where the longest fits whole at the text size', () {
    const style = TextStyle(fontFamily: 'Roboto', fontSize: 12, fontWeight: FontWeight.w600, letterSpacing: 0);
    expect(DoblonNavigationBar.labelsFit(390, TextScaler.noScaling, style), isTrue, reason: 'A usual phone');
    expect(DoblonNavigationBar.labelsFit(390, const TextScaler.linear(1.4), style), isFalse, reason: 'Large text: icons, names read aloud');
    expect(DoblonNavigationBar.labelsFit(320, TextScaler.noScaling, style), isFalse, reason: 'A small phone');
    expect(DoblonNavigationBar.labelsFit(768, const TextScaler.linear(1.6), style), isTrue, reason: 'A tablet');
  });

  testWidgets('the tab bar never breaks a label: whole names or only icons', (tester) async {
    for (final (width, scale, labels) in [(390.0, 1.0, true), (320.0, 1.0, false), (390.0, 1.6, false)]) {
      tester.view.physicalSize = Size(width, 700);
      tester.view.devicePixelRatio = 1;
      await tester
          .pumpWidget(app(Align(alignment: Alignment.bottomCenter, child: DoblonNavigationBar(selectedIndex: 3, onDestinationSelected: (_) {})), text: scale));
      await tester.pumpAndSettle();
      expect(tester.takeException(), isNull);
      final label = find.text('Presupuestos');
      if (labels) {
        expect(tester.getSize(label).height, lessThan(12 * 1.6 * scale), reason: 'One line at $width');
      } else {
        expect(tester.widget<NavigationBar>(find.byType(NavigationBar)).labelBehavior, NavigationDestinationLabelBehavior.alwaysHide);
        expect(find.byTooltip('Presupuestos'), findsOneWidget, reason: 'Still named');
      }
    }
    tester.view.reset();
  });

  testWidgets('the month figures go one under another when they do not fit side by side', (tester) async {
    Widget values(double text) => app(
        const SizedBox(
            width: 330,
            child: LabelValues(
              labelStyle: TextStyle(fontSize: 12),
              valueStyle: TextStyle(fontSize: 17),
              items: [('Gastos', '1.472,38 €', null), ('Ingresos', '138,47 €', null), ('Ahorro', '-1.333,91 €', null)],
            )),
        text: text);
    await tester.pumpWidget(values(1));
    final side = tester.getTopLeft(find.text('Ingresos')).dy == tester.getTopLeft(find.text('Gastos')).dy;
    await tester.pumpWidget(values(2));
    expect(tester.takeException(), isNull);
    expect(tester.getTopLeft(find.text('Ingresos')).dy, greaterThan(tester.getTopLeft(find.text('Gastos')).dy), reason: 'Stacked with large text');
    expect(find.text('-1.333,91 €'), findsOneWidget, reason: 'The amount whole, not changed');
    expect(side, isTrue, reason: 'Side by side at the usual size');
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
      expect(tester.getTopLeft(find.text('Disponible')).dy, greaterThanOrEqualTo(top), reason: 'Below the header');
      final list = tester.state<ScrollableState>(find.byType(Scrollable).first).position;
      // The end is only known once the items below are laid out.
      for (var i = 0; i < 10 && list.pixels < list.maxScrollExtent; i++) {
        list.jumpTo(list.maxScrollExtent);
        await tester.pumpAndSettle();
      }
      final last = tester.getRect(find.ancestor(of: find.text('Viaje ficticio'), matching: find.byType(Card)).first);
      expect(last.bottom, lessThanOrEqualTo(667 - bottom - dockReserve + 1), reason: 'The last card scrolls fully above Don Bigotes, «+ Añadir» and the tabs');
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
    expect(find.text('Disponible'), findsOneWidget);
  });
}
