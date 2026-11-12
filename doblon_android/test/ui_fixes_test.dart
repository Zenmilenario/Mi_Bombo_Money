// Fictitious data only. What the person saw on the device on 12 November 2026.
import 'dart:io';

import 'package:doblon/automation.dart';
import 'package:doblon/screens/shell.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

Widget app(Widget child) => MaterialApp(theme: doblonTheme(Brightness.light), home: child);

void main() {
  test('Ajustes no longer offers the artificial intelligence page', () {
    expect(File('lib/screens/shell.dart').readAsStringSync(), isNot(contains("'Inteligencia artificial'")));
  });

  testWidgets('Don Bigotes shows his name, awake or asleep', (tester) async {
    var taps = 0;
    await tester.pumpWidget(app(Scaffold(body: CompanionButton(notes: const [], onTap: () => taps++))));
    expect(find.text('Don Bigotes'), findsOneWidget);
    final notes = [
      CompanionNote(id: 'a', title: 'Aviso ficticio', detail: '', tab: 1),
      CompanionNote(id: 'b', title: 'Otro aviso', detail: '', tab: 2),
    ];
    await tester.pumpWidget(app(Scaffold(body: CompanionButton(notes: notes, onTap: () => taps++))));
    expect(find.text('Don Bigotes · tengo 2 avisos'), findsOneWidget);
    await tester.tap(find.byType(CompanionButton));
    expect(taps, 1);
  });

  test('while the protection is checked, «Protege tus finanzas» is not shown', () {
    // shortcut: checks the gate's source; a widget test hangs on the Supabase client inside the test clock.
    final gate = File('lib/screens/cloud_privacy_gate.dart').readAsStringSync();
    final loading = gate.indexOf('if (busy && privacy.profile == null) return const Scaffold(body: Center(child: CircularProgressIndicator()));');
    expect(loading, greaterThan(0));
    expect(loading, lessThan(gate.indexOf("'Protege tus finanzas'")), reason: 'The loading screen comes first');
  });

  test('the category proposal reads the same cleaned concept the model learnt from', () {
    // shortcut: checks the source; the learnt and the queried text must be the same listTitle.
    expect(File('lib/screens/learning.dart').readAsStringSync(), contains('suggestCategory(listTitle(t.descriptionText, isBanking: t.isBanking)'));
    expect(File('lib/learning.dart').readAsStringSync(), contains('final text = listTitle(t.descriptionText, isBanking: t.isBanking);'));
  });
}
