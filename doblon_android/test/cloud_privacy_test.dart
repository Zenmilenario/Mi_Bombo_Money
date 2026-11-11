import 'dart:convert';
import 'package:doblon/cloud_privacy.dart';
import 'package:doblon/learning.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_secure_storage/flutter_secure_storage.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:doblon/cloud_document_validation.dart';

const owner = '00000000-0000-0000-0000-000000000001';
const workspace = '00000000-0000-0000-0000-000000000011';
const keyId = '00000000-0000-4000-8000-000000000099';
// Independent Node/OpenSSL AES-GCM vector, also consumed by Swift's CryptoKit check.
final vector = <String, dynamic>{
  'v': 1,
  'alg': 'A256GCM',
  'key_id': keyId,
  'nonce': 'AAECAwQFBgcICQoL',
  'ciphertext': 'PCC1c6CGqTm3Y/Pk04UXA6694k3dDW5eRQ==',
  'tag': 'nUBs5LlHRGvnzd1azH+qVw=='
};

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();
  final cipher = CloudCipher(List.generate(32, (i) => i), keyId);
  test('enrollment, encrypted finance and learning, and recovery on a second device', () async {
    FlutterSecureStorage.setMockInitialValues({});
    CloudPrivacy.sessions.clear();
    final doc = <String,dynamic>{'formatVersion':2, for (final key in ['institutions','accounts','categories','cards','reservedFunds','categoryRules',
      'recurringBudgets','budgets','goals','recurringMovements','importBatches','snapshots','transactions']) key: <dynamic>[]};
    doc['categories'] = [{'id': workspace, 'name': 'Comercio ficticio', 'kindRaw': 'expense'}];
    Map<String,dynamic>? check;
    final documents = <String,dynamic>{}, revisions = <String,int>{};
    final writes = <Map<String,dynamic>>[];
    final client = SupabaseClient('https://fictional.invalid', 'fictional', authOptions: const AuthClientOptions(autoRefreshToken:false), httpClient: MockClient((request) async {
      final value = request.body.isEmpty ? null : jsonDecode(request.body);
      final body = value is Map ? Map<String,dynamic>.from(value) : <String,dynamic>{};
      dynamic response;
      switch (request.url.pathSegments.last) {
        case 'finance_privacy_profile': response = {'encryption_required':true,'workspace_id':workspace,'key_check':check};
        case 'finance_encryption_source': response = {'finance':{'workspace_id':workspace,'revision':20,'document':doc},
          'learning':{'workspace_id':workspace,'revision':7,'document':{'version':1}}};
        case 'finance_enable_encryption':
          writes.add(body); check = Map<String,dynamic>.from(body['p_key_check']);
          for (final kind in ['finance','learning']) { documents[kind] = body['p_$kind']; revisions[kind] = 1; }
          response = null;
        case 'finance_encrypted_save':
          writes.add(body); final kind = body['p_kind'] as String;
          expect(body['p_expected_revision'], revisions[kind]); documents[kind] = body['p_envelope']; revisions[kind] = revisions[kind]! + 1;
          response = {'workspace_id':workspace,'revision':revisions[kind],'document':documents[kind]};
        case 'finance_encrypted_snapshot': final kind = body['p_kind']; response = {'workspace_id':workspace,'revision':revisions[kind],'document':documents[kind]};
        default: fail('An encrypted guest called the plaintext API: ${request.url.path}');
      }
      return http.Response(jsonEncode(response), 200, request:request, headers:{'content-type':'application/json'});
    }));
    addTearDown(client.dispose);
    await client.auth.setInitialSession(jsonEncode({'access_token':'fictional','token_type':'bearer',
      'user':{'id':owner,'aud':'authenticated','created_at':'2026-01-01T00:00:00Z','app_metadata':{},'user_metadata':{}}}));
    final first = CloudPrivacy(client);
    expect(await first.prepare(), isFalse);
    final key = CloudCipher.generate();
    await first.enroll(key);
    expect((await first.fetch('finance'))['document'], doc);
    await first.save('finance', workspace, 1, doc);
    await first.save('learning', workspace, 1, {'version':1,'events':[]});
    expect(jsonEncode(writes), isNot(contains('Comercio ficticio')));
    expect(jsonEncode(writes), isNot(contains(key.recoveryCode)));
    // A new phone knows only the account session; its secure key storage starts empty.
    FlutterSecureStorage.setMockInitialValues({});
    CloudPrivacy.sessions.clear();
    final second = CloudPrivacy(client);
    expect(await second.prepare(), isFalse);
    expect(second.enrolled, isTrue);
    final count = writes.length;
    await expectLater(second.unlock(CloudCipher.generate().recoveryCode), throwsA(anything));
    expect(writes.length, count);
    await second.unlock(key.recoveryCode);
    expect((await second.fetch('finance'))['document'], doc);
    expect((await second.fetch('learning'))['document'], {'version':1,'events':[]});
  });
  test('private documents reject dangling references and overspending a reserve', () {
    final doc = <String,dynamic>{'formatVersion':2, for (final key in ['institutions','accounts','categories','cards','reservedFunds','categoryRules',
      'recurringBudgets','budgets','goals','recurringMovements','importBatches','snapshots','transactions']) key: <dynamic>[]};
    doc['accounts'] = [{'id':'a','typeRaw':'checking'}];
    doc['reservedFunds'] = [{'id':'r','accountID':'a','amountMinor':100}];
    doc['transactions'] = [{'id':'t','date':0,'typeRaw':'expense','amountMinor':150,'sourceAccountID':'a','reservedFundID':'r','reservedAmountMinor':150}];
    expect(() => validatePrivateDocument(doc,'finance'), throwsFormatException);
    (doc['transactions'] as List).single['reservedAmountMinor'] = 100;
    expect(() => validatePrivateDocument(doc,'finance'), returnsNormally);
    (doc['transactions'] as List).single['sourceAccountID'] = 'missing';
    expect(() => validatePrivateDocument(doc,'finance'), throwsFormatException);
  });
  test('Swift/Dart share an independent AES-GCM vector and recovery code',
      () async {
    expect(await cipher.open(vector, owner, workspace, 'key-check', 0),
        {'check': 'doblon-key-v1'});
    expect(
        await cipher.seal(
            {'check': 'doblon-key-v1'}, owner, workspace, 'key-check', 0,
            nonce: List.generate(12, (i) => i)),
        vector);
    expect(CloudCipher.recover(cipher.recoveryCode, keyId).bytes, cipher.bytes);
    expect(() => CloudCipher.recover('short', keyId), throwsFormatException);
  });
  test(
      'wrong key, identity, workspace, kind, revision or tampering never decrypt',
      () async {
    for (final args in [
      ['00000000-0000-0000-0000-000000000002', workspace, 'key-check', 0],
      [owner, '00000000-0000-0000-0000-000000000012', 'key-check', 0],
      [owner, workspace, 'learning', 0],
      [owner, workspace, 'key-check', 1],
    ]) {
      await expectLater(
          cipher.open(vector, args[0] as String, args[1] as String,
              args[2] as String, args[3] as int),
          throwsA(anything));
    }
    await expectLater(
        CloudCipher(List.filled(32, 255), keyId)
            .open(vector, owner, workspace, 'key-check', 0),
        throwsA(anything));
    await expectLater(
        cipher.open({...vector, 'tag': base64Encode(List.filled(16, 0))}, owner,
            workspace, 'key-check', 0),
        throwsA(anything));
  });
  test(
      'financial cents and learning survive encryption without changing model results',
      () async {
    final examples = [
      for (final (name, texts) in CategoryModel.syntheticExamples)
        for (final text in texts) {'text': text, 'category': name}
    ];
    final doc = {
      'version': 1,
      'amountMinor': 9876543210123,
      'examples': examples
    };
    final a = await cipher.seal(doc, owner, workspace, 'learning', 7);
    final b = await cipher.seal(doc, owner, workspace, 'learning', 7);
    expect(a['nonce'], isNot(b['nonce']));
    expect(jsonEncode(a), isNot(contains('Supermercado')));
    final plain = await cipher.open(a, owner, workspace, 'learning', 7);
    expect(plain, doc);
    CategoryModel train(Map<String, dynamic> data) => CategoryModel.train([
          for (final e in data['examples'] as List)
            CategoryExample(e['text'], e['category'], 1)
        ])!;
    final categories = {
      for (final (name, _) in CategoryModel.syntheticExamples) name
    };
    expect(
        train(plain).predict('Supermercado La Cesta', categories)?.categoryId,
        train(doc).predict('Supermercado La Cesta', categories)?.categoryId);
  });
}
