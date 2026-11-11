import 'dart:convert';
import 'dart:math';

import 'package:cryptography/cryptography.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:uuid/uuid.dart';
import 'cloud_document_validation.dart';

/// Same AES-GCM wire format as CloudCipher.swift. Keys never enter a cloud RPC.
class CloudCipher {
  CloudCipher(this.bytes, this.keyId) {
    if (bytes.length != 32) {
      throw const FormatException('Código de recuperación no válido.');
    }
  }
  final List<int> bytes;
  final String keyId;
  static final algorithm = AesGcm.with256bits();
  String get recoveryCode =>
      'DBL1-${base64UrlEncode(bytes).replaceAll('=', '')}';
  static CloudCipher generate() => CloudCipher(
      List.generate(32, (_) => Random.secure().nextInt(256)),
      const Uuid().v4());
  static CloudCipher recover(String code, String id) {
    final text = code.trim();
    if (!text.startsWith('DBL1-')) {
      throw const FormatException('Código de recuperación no válido.');
    }
    return CloudCipher(
        base64Url.decode(base64Url.normalize(text.substring(5))), id);
  }

  List<int> _aad(String owner, String workspace, String kind, int revision) =>
      utf8.encode(
          'doblon:e2ee:1:${owner.toLowerCase()}:${workspace.toLowerCase()}:$kind:$revision:$keyId');

  Future<Map<String, dynamic>> seal(Map<String, dynamic> document, String owner,
      String workspace, String kind, int revision,
      {List<int>? nonce}) async {
    final box = await algorithm.encrypt(utf8.encode(jsonEncode(document)),
        secretKey: SecretKey(bytes),
        nonce: nonce,
        aad: _aad(owner, workspace, kind, revision));
    return {
      'v': 1,
      'alg': 'A256GCM',
      'key_id': keyId,
      'nonce': base64Encode(box.nonce),
      'ciphertext': base64Encode(box.cipherText),
      'tag': base64Encode(box.mac.bytes)
    };
  }

  Future<Map<String, dynamic>> open(Map<String, dynamic> envelope, String owner,
      String workspace, String kind, int revision) async {
    if (envelope['v'] != 1 ||
        envelope['alg'] != 'A256GCM' ||
        envelope['key_id'] != keyId ||
        envelope.length != 6) {
      throw const FormatException('El formato cifrado no es compatible.');
    }
    final nonce = base64Decode(envelope['nonce'] as String),
        tag = base64Decode(envelope['tag'] as String);
    if (nonce.length != 12 || tag.length != 16) {
      throw const FormatException('Datos cifrados incompletos.');
    }
    final plain = await algorithm.decrypt(
        SecretBox(base64Decode(envelope['ciphertext'] as String),
            nonce: nonce, mac: Mac(tag)),
        secretKey: SecretKey(bytes),
        aad: _aad(owner, workspace, kind, revision));
    return Map<String, dynamic>.from(jsonDecode(utf8.decode(plain)) as Map);
  }
}

/// Per-identity storage and routing. A guest cannot opt out by changing the build or a preference.
class CloudPrivacy {
  CloudPrivacy(this.client, {FlutterSecureStorage? storage})
      : storage = storage ?? const FlutterSecureStorage();
  final SupabaseClient client;
  final FlutterSecureStorage storage;
  static final Map<String, CloudPrivacy> sessions = {};
  static const warning =
      'Guarda este código en tu gestor de contraseñas. No lo compartas. Si pierdes el código y todos tus dispositivos conectados, no podremos recuperar tus datos. Restablecer la contraseña de acceso no recupera este código.';
  late final String _identity = client.auth.currentUser!.id;
  String get owner {
    if (client.auth.currentUser?.id != _identity) {
      throw StateError('La cuenta ha cambiado.');
    }
    return _identity;
  }

  String get _slot => 'doblon-cloud-privacy-v1-$owner';
  Map<String, dynamic>? profile;
  CloudCipher? cipher;
  bool get encrypted => profile?['encryption_required'] == true;
  bool get enrolled => profile?['key_check'] is Map;
  String get workspace => profile!['workspace_id'] as String;

  Future<bool> prepare() async {
    final identity = owner;
    // Network/policy failures stop opening. No silent downgrade to the legacy transport.
    try {
      profile = Map<String, dynamic>.from(
          await client.rpc('finance_privacy_profile') as Map);
    } on PostgrestException {
      rethrow;
    } on AuthException {
      rethrow;
    } catch (_) {
      // Offline opening is allowed only after this identity was provisioned on this device.
      final cached = await storage.read(key: _slot);
      if (cached == null) rethrow;
      profile = Map<String, dynamic>.from(jsonDecode(cached)['profile'] as Map);
    }
    if (profile!['encryption_required'] is! bool ||
        profile!['workspace_id'] is! String) {
      throw const FormatException(
          'No se puede verificar la protección de esta cuenta.');
    }
    if (owner != identity) throw StateError('La cuenta ha cambiado.');
    if (!encrypted) {
      await storage.write(key: _slot, value: jsonEncode({'profile': profile}));
      sessions[owner] = this;
      return true;
    }
    if (!enrolled) return false;
    final cached = await storage.read(key: _slot);
    if (cached == null) return false;
    final code = jsonDecode(cached)['code'];
    if (code is! String) return false;
    await unlock(code);
    return true;
  }

  Future<void> unlock(String code) async {
    final check = Map<String, dynamic>.from(profile!['key_check'] as Map);
    final candidate = CloudCipher.recover(code, check['key_id'] as String);
    final decoded =
        await candidate.open(check, owner, workspace, 'key-check', 0);
    if (decoded['check'] != 'doblon-key-v1') {
      throw const FormatException('El código no corresponde a esta cuenta.');
    }
    cipher = candidate;
    await storage.write(
        key: _slot,
        value:
            jsonEncode({'profile': profile, 'code': candidate.recoveryCode}));
    sessions[owner] = this;
  }

  Future<void> enroll(CloudCipher candidate) async {
    final identity = owner;
    final source = Map<String, dynamic>.from(
        await client.rpc('finance_encryption_source') as Map);
    final finance = Map<String, dynamic>.from(source['finance'] as Map),
        learning = Map<String, dynamic>.from(source['learning'] as Map);
    if (finance['workspace_id'] != workspace ||
        learning['workspace_id'] != workspace ||
        owner != identity) {
      throw StateError('La cuenta ha cambiado.');
    }
    final f = await candidate.seal(
        Map<String, dynamic>.from(finance['document'] as Map),
        owner,
        workspace,
        'finance',
        1);
    final l = await candidate.seal(
        Map<String, dynamic>.from(learning['document'] as Map),
        owner,
        workspace,
        'learning',
        1);
    final check = await candidate
        .seal({'check': 'doblon-key-v1'}, owner, workspace, 'key-check', 0);
    validatePrivateDocument(
        Map<String, dynamic>.from(finance['document'] as Map), 'finance');
    validatePrivateDocument(
        Map<String, dynamic>.from(learning['document'] as Map), 'learning');
    // Verify both locally before the atomic migration can remove the live plaintext rows.
    await candidate.open(f, owner, workspace, 'finance', 1);
    await candidate.open(l, owner, workspace, 'learning', 1);
    // Persist first. A failed RPC can be retried safely with the already saved recovery code.
    await storage.write(
        key: _slot,
        value: jsonEncode({
          'profile': {...profile!, 'key_check': check},
          'code': candidate.recoveryCode
        }));
    await client.rpc('finance_enable_encryption', params: {
      'p_workspace': workspace,
      'p_finance_revision': finance['revision'],
      'p_learning_revision': learning['revision'],
      'p_finance': f,
      'p_learning': l,
      'p_key_check': check
    });
    profile = {...profile!, 'key_check': check};
    await unlock(candidate.recoveryCode);
  }

  Future<Map<String, dynamic>> fetch(String kind) async {
    final raw = Map<String, dynamic>.from(await client.rpc(
        encrypted
            ? 'finance_encrypted_snapshot'
            : kind == 'finance'
                ? 'finance_snapshot'
                : 'finance_learning_snapshot',
        params: encrypted ? {'p_kind': kind} : {}) as Map);
    return _decode(raw, kind);
  }

  Future<Map<String, dynamic>> _decode(
      Map<String, dynamic> raw, String kind) async {
    if (!encrypted) return raw;
    if (raw['workspace_id'] != workspace || cipher == null) {
      throw StateError('Desbloquea tus datos con el código de recuperación.');
    }
    final document = await cipher!.open(
        Map<String, dynamic>.from(raw['document'] as Map),
        owner,
        workspace,
        kind,
        raw['revision'] as int);
    validatePrivateDocument(document, kind);
    return {...raw, 'document': document};
  }

  Future<Map<String, dynamic>> save(String kind, String ws, int revision,
      Map<String, dynamic> document) async {
    if (encrypted && (ws != workspace || cipher == null)) {
      throw StateError('Desbloquea tus datos.');
    }
    if (encrypted) validatePrivateDocument(document, kind);
    final raw = await client.rpc(
        encrypted
            ? 'finance_encrypted_save'
            : kind == 'finance'
                ? 'finance_save_snapshot'
                : 'finance_learning_save',
        params: {
          'p_workspace': ws,
          'p_expected_revision': revision,
          if (encrypted) ...{
            'p_kind': kind,
            'p_envelope':
                await cipher!.seal(document, owner, ws, kind, revision + 1)
          } else ...{
            'p_document': document,
            if (kind == 'finance') 'p_timezone': 'Europe/Madrid'
          },
        });
    return _decode(Map<String, dynamic>.from(raw as Map), kind);
  }
}
