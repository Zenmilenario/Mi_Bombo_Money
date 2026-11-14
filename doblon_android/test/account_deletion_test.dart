// Deleting the account (supabase/migrations/20261114000100_delete_account.sql): the bank permissions are revoked
// before the cloud copy is deleted, and the app sends the confirmation word the server requires.
// shortcut: checks the source order, because the repository uses the real Supabase client; upgrade to a fake
// client when FinanceRepository receives it injected.
import 'dart:io';

import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the banks are disconnected first, then the account is deleted with the server word', () {
    final source = File('lib/data.dart').readAsStringSync();
    final body = source.substring(source.indexOf('Future<void> deleteAccount()'));
    final revoke = body.indexOf('api.disconnect('), delete = body.indexOf("rpc('finance_delete_account'");
    expect(revoke, greaterThan(0));
    expect(delete, greaterThan(revoke), reason: 'If revoking fails, nothing is deleted');
    expect(body.indexOf('signOut()'), greaterThan(delete));

    final word = RegExp(r"'confirmation': '([A-Z]+)'").firstMatch(body)!.group(1);
    final migration = File('../supabase/migrations/20261114000100_delete_account.sql').readAsStringSync();
    expect(migration, contains("confirmation IS DISTINCT FROM '$word'"));
  });
}
