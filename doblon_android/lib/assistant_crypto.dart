// The sealed envelope of Don Bigotes' interpreter (26 November 2026). On top of HTTPS, what the app sends (already
// masked: `assistant_privacy.dart`) is sealed for the Worker alone: a fresh X25519 key per request, HKDF-SHA256 and
// AES-256-GCM. Only the Worker, with its private key (a secret outside the repository), can open it; the answer
// comes back sealed with the same key. The same scheme is in BankingBackend/src/assistant.mjs.
import 'dart:convert';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';

/// The Worker's public key (BankingBackend/tools/assistant-key.mjs). Public by design.
const assistantServerKey = 'nnyoqHxy3gk/CO2FqXL8zZoX1Cztk7ey03c/udyDMUA=';

final _info = utf8.encode('doblon-assistant-v1');

class AssistantEnvelope {
  AssistantEnvelope._(this._key);
  final SecretKey _key;

  /// Seals [value] for the Worker whose public key is [serverKey]. Returns the body to send and the envelope that
  /// opens the answer.
  static Future<(Map<String, Object?>, AssistantEnvelope)> seal(Object? value, {String serverKey = assistantServerKey}) async {
    final x25519 = X25519();
    final own = await x25519.newKeyPair();
    final epk = Uint8List.fromList((await own.extractPublicKey()).bytes);
    final shared = await x25519.sharedSecretKey(keyPair: own, remotePublicKey: SimplePublicKey(base64.decode(serverKey), type: KeyPairType.x25519));
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: shared, nonce: epk, info: _info);
    final aes = AesGcm.with256bits();
    final box = await aes.encrypt(utf8.encode(jsonEncode(value)), secretKey: key, nonce: aes.newNonce(), aad: utf8.encode('request'));
    return (
      <String, Object?>{
        'sealed': {'epk': base64.encode(epk), 'nonce': base64.encode(box.nonce), 'data': base64.encode([...box.cipherText, ...box.mac.bytes])},
      },
      AssistantEnvelope._(key),
    );
  }

  /// Opens the Worker's sealed answer; throws if it was not sealed with this request's key.
  Future<Map<String, dynamic>> open(Object? answer) async {
    final sealed = (answer as Map)['sealed'] as Map;
    final data = base64.decode(sealed['data'] as String);
    if (data.length < 16) throw const FormatException('sealed');
    final box = SecretBox(data.sublist(0, data.length - 16), nonce: base64.decode(sealed['nonce'] as String), mac: Mac(data.sublist(data.length - 16)));
    final plain = await AesGcm.with256bits().decrypt(box, secretKey: _key, aad: utf8.encode('response'));
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
  }

  /// For tests: what the Worker does with its private key (seed of 32 bytes), to check both ends agree.
  static Future<(Object?, Future<Map<String, Object?>> Function(Object?))> openAsServer(Map<String, Object?> body, List<int> privateSeed) async {
    final sealed = body['sealed'] as Map;
    final epk = base64.decode(sealed['epk'] as String);
    final x25519 = X25519();
    final own = await x25519.newKeyPairFromSeed(privateSeed);
    final shared = await x25519.sharedSecretKey(keyPair: own, remotePublicKey: SimplePublicKey(epk, type: KeyPairType.x25519));
    final key = await Hkdf(hmac: Hmac.sha256(), outputLength: 32).deriveKey(secretKey: shared, nonce: epk, info: _info);
    final aes = AesGcm.with256bits();
    final data = base64.decode(sealed['data'] as String);
    final plain = await aes.decrypt(SecretBox(data.sublist(0, data.length - 16), nonce: base64.decode(sealed['nonce'] as String), mac: Mac(data.sublist(data.length - 16))),
        secretKey: key, aad: utf8.encode('request'));
    Future<Map<String, Object?>> reply(Object? value) async {
      final box = await aes.encrypt(utf8.encode(jsonEncode(value)), secretKey: key, nonce: aes.newNonce(), aad: utf8.encode('response'));
      return {
        'sealed': {'nonce': base64.encode(box.nonce), 'data': base64.encode([...box.cipherText, ...box.mac.bytes])}
      };
    }

    return (jsonDecode(utf8.decode(plain)), reply);
  }
}
