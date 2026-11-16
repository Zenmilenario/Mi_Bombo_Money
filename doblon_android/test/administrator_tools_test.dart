// The administrator tools (the developer's account, the only one exempt from encrypting) are hidden from guests,
// as the Swift app does with its personal edition, but here by the account instead of by a separate build.
// shortcut: checks the source, because the flag comes from the real Supabase privacy profile; upgrade to a widget
// test when FinanceRepository can be built with a fake Supabase client.
import 'dart:io';

import 'package:doblon/data.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('a new session starts without administrator tools until its profile says so', () {
    expect(FinanceRepository().isAdministrator, isFalse, reason: 'Hidden unless the cloud profile proves it');
  });

  test('the flag comes from the encryption profile and is forgotten on signing out', () {
    final data = File('lib/data.dart').readAsStringSync();
    expect(data, contains('isAdministrator = !session.encrypted;'));
    final signOut = data.substring(data.indexOf('Future<void> signOut()'));
    // Within the first lines of signOut, next to forgetting the privacy session.
    expect(signOut.substring(0, 300), contains('isAdministrator = false;'));
  });

  test('the bank diagnostic and the AI figures are shown only to the administrator', () {
    final banks = File('lib/screens/banks.dart').readAsStringSync();
    final diagnostic = banks.indexOf('_Received(account: account, activity: activity)');
    expect(banks.substring(diagnostic - 200, diagnostic), contains('if (widget.repository.isAdministrator)'));
    final shell = File('lib/screens/shell.dart').readAsStringSync();
    final metrics = shell.indexOf("'Acierto de la IA'");
    expect(shell.substring(metrics - 120, metrics), contains('if (repository.isAdministrator)'));
  });
}
