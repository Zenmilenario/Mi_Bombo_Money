// A backup file protected with a password, in the same format as the iPhone app (`EncryptedFinanceBackup` in
// BackupService.swift): AES-256-GCM with a key from PBKDF2-HMAC-SHA256, the format name as authenticated data, and
// `combinedCiphertextBase64` = nonce (12) + ciphertext + tag (16), as CryptoKit's `combined`. A copy made on one app
// opens on the other (Tests/Fixtures/encrypted_backup.json, checked by both).
import 'dart:convert';
import 'dart:isolate';
import 'dart:math';

import 'package:cryptography/cryptography.dart';

const backupMagic = 'MiPatrimonioEncryptedBackupV1';
const backupFormat = 'AES-256-GCM-PBKDF2-SHA256';
const backupIterations = 600000;
const backupMinPasswordLength = 10;

class BackupPasswordError implements Exception {
  const BackupPasswordError();
}

bool isEncryptedBackup(String text) {
  try {
    return (jsonDecode(text) as Map)['magic'] == backupMagic;
  } catch (_) {
    return false;
  }
}

/// PBKDF2 is slow on purpose: off the main isolate, so the screen does not freeze.
Future<List<int>> _deriveKey(String password, List<int> salt, int iterations) => Isolate.run(() async {
      final key = await Pbkdf2(macAlgorithm: Hmac.sha256(), iterations: iterations, bits: 256)
          .deriveKeyFromPassword(password: password, nonce: salt);
      return key.extractBytes();
    });

/// The document encrypted with the password. `salt` and `nonce` are only fixed by the tests.
Future<String> sealBackup(Map<String, dynamic> document, String password,
    {int iterations = backupIterations, List<int>? salt, List<int>? nonce}) async {
  if (password.length < backupMinPasswordLength) throw ArgumentError('password');
  final random = Random.secure();
  final saltBytes = salt ?? List<int>.generate(16, (_) => random.nextInt(256));
  final key = SecretKey(await _deriveKey(password, saltBytes, iterations));
  final box = await AesGcm.with256bits().encrypt(utf8.encode(jsonEncode(document)),
      secretKey: key, nonce: nonce ?? AesGcm.with256bits().newNonce(), aad: utf8.encode(backupFormat));
  return const JsonEncoder.withIndent('  ').convert({
    'magic': backupMagic,
    'format': backupFormat,
    'saltBase64': base64.encode(saltBytes),
    'combinedCiphertextBase64': base64.encode([...box.nonce, ...box.cipherText, ...box.mac.bytes]),
    'iterations': iterations,
  });
}

/// The document inside an encrypted backup. A wrong password throws [BackupPasswordError]; anything else that is
/// not a valid backup throws [FormatException].
Future<Map<String, dynamic>> openBackup(String text, String password) async {
  final Map container;
  try {
    container = jsonDecode(text) as Map;
  } catch (_) {
    throw const FormatException('backup');
  }
  final iterations = container['iterations'];
  if (container['magic'] != backupMagic || container['format'] != backupFormat || iterations is! int || iterations < 100000 || iterations > 1000000) {
    throw const FormatException('backup');
  }
  final List<int> salt, combined;
  try {
    salt = base64.decode('${container['saltBase64']}');
    combined = base64.decode('${container['combinedCiphertextBase64']}');
  } catch (_) {
    throw const FormatException('backup');
  }
  if (salt.length < 16 || salt.length > 64 || combined.length < 28) throw const FormatException('backup');
  final key = SecretKey(await _deriveKey(password, salt, iterations));
  final List<int> plain;
  try {
    plain = await AesGcm.with256bits().decrypt(
        SecretBox(combined.sublist(12, combined.length - 16), nonce: combined.sublist(0, 12), mac: Mac(combined.sublist(combined.length - 16))),
        secretKey: key,
        aad: utf8.encode(backupFormat));
  } on SecretBoxAuthenticationError {
    throw const BackupPasswordError();
  }
  return Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
}
