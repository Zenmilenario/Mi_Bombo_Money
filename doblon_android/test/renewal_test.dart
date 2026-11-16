// Fictitious data only. The bank permission: days left, the warning from a week before, and the old permission a
// renewal replaces (disconnected so the bank is not asked twice for the same accounts).
import 'package:doblon/automation.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

RemoteConnection permission(String id, String bank, String until, List<String> accounts) => RemoteConnection(
    id: id, bank: bank, validUntil: until, accounts: [for (final a in accounts) RemoteAccount(id: a, currency: 'EUR', lastFour: '0000')]);

void main() {
  final now = DateTime.utc(2026, 11, 16, 12);

  test('days left and the warning only in the last week', () {
    expect(permissionDaysLeft(permission('p', 'Banco Ficticio', '2027-02-10T00:00:00Z', ['a']), now), 86);
    expect(permissionExpiresSoon(permission('p', 'Banco Ficticio', '2027-02-10T00:00:00Z', ['a']), now), isFalse);
    expect(permissionDaysLeft(permission('p', 'Banco Ficticio', '2026-11-23T08:00:00Z', ['a']), now), 7);
    expect(permissionExpiresSoon(permission('p', 'Banco Ficticio', '2026-11-23T08:00:00Z', ['a']), now), isTrue);
    expect(permissionDaysLeft(permission('p', 'Banco Ficticio', '2026-11-16T23:00:00Z', ['a']), now), 0, reason: 'Its last day');
    expect(permissionDaysLeft(permission('p', 'Banco Ficticio', '2026-11-10T00:00:00Z', ['a']), now), -6);
    expect(permissionDaysLeft(permission('p', 'Banco Ficticio', 'sin fecha', ['a']), now), isNull);
    expect(permissionExpiresSoon(permission('p', 'Banco Ficticio', 'sin fecha', ['a']), now), isFalse, reason: 'Nothing is guessed');
  });

  test('a renewal replaces the old permission only when it covers all its accounts', () {
    final old = permission('viejo', 'Banco Ficticio', '2026-11-20T00:00:00Z', ['a', 'b']);
    final renewed = permission('nuevo', 'Banco Ficticio', '2027-02-18T00:00:00Z', ['a', 'b', 'c']);
    final partial = permission('parcial', 'Otro Banco', '2027-02-18T00:00:00Z', ['x']);
    final otherOld = permission('otro-viejo', 'Otro Banco', '2026-11-20T00:00:00Z', ['x', 'y']);
    final unrelated = permission('aparte', 'Banco Tercero', '2026-11-20T00:00:00Z', ['z']);
    expect(supersededConnections([old, renewed, partial, otherOld, unrelated]).map((c) => c.id), ['viejo'],
        reason: 'Another bank, or a newer one missing an account, keeps the old permission');
    expect(supersededConnections([renewed, old]).map((c) => c.id), ['viejo'], reason: 'The order does not matter');
    expect(supersededConnections([renewed]), isEmpty);
  });

  test('Don Bigotes points out the permission about to expire, and the expired one', () {
    final data = Finances.fromDocument({'accounts': [], 'transactions': []});
    final notes = companionNotes(data, now, renewals: [(bank: 'Banco Ficticio', days: 3), (bank: 'Otro Banco', days: -1)]);
    expect(notes.map((n) => n.title), containsAll(['Renueva el acceso a Banco Ficticio', 'El acceso a Otro Banco ha caducado']));
    expect(notes.firstWhere((n) => n.title.contains('Banco Ficticio')).detail, contains('Caduca en 3 días'));
    expect(notes.any((n) => RegExp(r'deberías|te recomiendo', caseSensitive: false).hasMatch('${n.title} ${n.detail}')), isFalse);
  });
}
