// Fictitious data only. How big the cloud document grows with years of bank movements, against the 15 MB limit of
// `finance_encrypted_save` (the sealed copy is base64, a third bigger). It decides when the monthly sync of
// phase 3 is needed (Obsidian, «Escalabilidad y experiencia sencilla — propuesta»).
import 'dart:convert';

import 'package:doblon/banking.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('how many movements fit in the sealed copy, and the format does not grow unnoticed', () {
    final bank = RemoteConnection(id: 'conexion-ficticia', bank: 'Banco Ficticio', validUntil: '2036-01-01', accounts: []);
    final account = RemoteAccount(id: 'cuenta-ficticia', currency: 'EUR', lastFour: '0000');
    const perYear = 3000, years = 10;
    final start = DateTime.utc(2026, 1, 1);
    final movements = [
      for (var i = 0; i < perYear * years; i++)
        Movement(
            id: 'referencia-bancaria-ficticia-${i.toString().padLeft(8, '0')}',
            bookingDate: start.add(Duration(hours: i * 365 * 24 ~/ perYear)).toIso8601String().substring(0, 10),
            signedAmountMinor: -(1000 + i % 9000),
            currency: 'EUR',
            description: 'COMPRA TARJ. 5402XXXXXXXX1234 SUPERMERCADO FICTICIO MADRID ES ${i % 97}'),
    ];
    final (document, result) = importFeeds({'accounts': [], 'transactions': [], 'snapshots': []},
        [AccountFeed(connection: bank, account: account, balances: [], movements: movements)], DateTime.utc(2036, 6, 1),
        accountChoices: {account.id: 'new'});
    expect(result.inserted, perYear * years);

    final plain = utf8.encode(jsonEncode(document)).length;
    final perMovement = plain / (perYear * years);
    final sealedPerMovement = perMovement * 4 / 3; // base64 of the encrypted copy
    final capacity = (15 * 1024 * 1024 / sealedPerMovement).floor();
    // Measured on 14/11/2026: ~680 B per movement, ~17.000 movements in an encrypted copy. With the usual
    // few hundred to a thousand movements a year that is well over a decade; a guard against the format growing.
    expect(perMovement, lessThan(750), reason: 'Bytes per movement: ${perMovement.round()}');
    expect(capacity, greaterThan(15000), reason: 'Movements that fit sealed: $capacity');
    // ignore: avoid_print
    print('Movimiento: ${perMovement.round()} B · caben unos $capacity movimientos en la copia cifrada de 15 MB');
  });
}
