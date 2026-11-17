// Fictitious data only. A backup protected with a password, in the iPhone app's format: it opens with its password,
// a wrong one is told apart from a broken file, and the shared copy (Tests/Fixtures/encrypted_backup.json, also
// opened by Tests/BackupRoundTripCheck.swift) opens here.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/backup_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final document = {
    'formatVersion': 2,
    'accounts': [
      {'id': 'a1', 'name': 'Cuenta ficticia'},
    ],
    'transactions': [],
  };

  test('a copy opens with its password and not with another', () async {
    final text = await sealBackup(document, 'ContraseñaFicticia123!', iterations: 100000);
    expect(isEncryptedBackup(text), isTrue);
    expect(text, isNot(contains('Cuenta ficticia')), reason: 'Nothing readable without the password');
    expect(jsonDecode(text)['iterations'], 100000);
    expect((await openBackup(text, 'ContraseñaFicticia123!'))['accounts'][0]['name'], 'Cuenta ficticia');
    await expectLater(openBackup(text, 'otra-contraseña-ficticia'), throwsA(isA<BackupPasswordError>()));
  });

  test('a broken or unknown file is not taken for a wrong password', () async {
    final text = await sealBackup(document, 'ContraseñaFicticia123!', iterations: 100000);
    final unknown = Map<String, dynamic>.from(jsonDecode(text) as Map)..['format'] = 'otro-formato';
    await expectLater(openBackup(jsonEncode(unknown), 'ContraseñaFicticia123!'), throwsA(isA<FormatException>()));
    final weak = Map<String, dynamic>.from(jsonDecode(text) as Map)..['iterations'] = 10;
    await expectLater(openBackup(jsonEncode(weak), 'ContraseñaFicticia123!'), throwsA(isA<FormatException>()));
    await expectLater(openBackup('no es una copia', 'x'), throwsA(isA<FormatException>()));
    expect(isEncryptedBackup(jsonEncode(document)), isFalse, reason: 'A plain copy is not taken for an encrypted one');
  });

  test('a short password is refused, as on the iPhone', () async {
    await expectLater(sealBackup(document, 'corta'), throwsArgumentError);
  });

  test('the shared copy opens here too', () async {
    final text = File('../Tests/Fixtures/encrypted_backup.json').readAsStringSync();
    final opened = await openBackup(text, 'ContraseñaFicticia123!');
    expect(opened['formatVersion'], 2);
    expect(opened['accounts'], isEmpty);
  }, timeout: const Timeout(Duration(minutes: 2)));
}
