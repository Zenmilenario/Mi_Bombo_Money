// Fictitious data only. The sealed envelope of Don Bigotes' interpreter, across languages (26 November 2026): what
// this app seals is opened by the Worker's own code (BankingBackend/src/assistant.mjs, run with Node), and the
// Worker's sealed answer is opened here. A change on one side that breaks the other fails here. Skipped where Node
// or the Worker's code is not available.
import 'dart:convert';
import 'dart:io';

import 'package:cryptography/cryptography.dart';
import 'package:doblon/assistant_crypto.dart';
import 'package:flutter_test/flutter_test.dart';

String _b64url(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

void main() {
  final worker = File('../BankingBackend/src/assistant.mjs');
  final node = Process.runSync('node', ['--version'], runInShell: true).exitCode == 0;

  test('the app seals, the Worker opens and answers sealed, the app opens', () async {
    final seed = List<int>.generate(32, (i) => 200 - i);
    final pair = await X25519().newKeyPairFromSeed(seed);
    final public = (await pair.extractPublicKey()).bytes;
    final jwk = {'kty': 'OKP', 'crv': 'X25519', 'd': _b64url(seed), 'x': _b64url(public)};
    final context = {'sentence': 'pagué [N1] con la [CUENTA_1]', 'today': '2026-11-26'};
    final (body, envelope) = await AssistantEnvelope.seal(context, serverKey: base64.encode(public));
    expect(jsonEncode(body).contains('pagué'), isFalse);

    final dir = await Directory.systemTemp.createTemp('doblon-envelope');
    addTearDown(() => dir.delete(recursive: true));
    final script = File('${dir.path}/open.mjs')
      ..writeAsStringSync('''
import { openSealed, seal } from '${worker.absolute.uri}';
const [body, jwk] = [JSON.parse(process.argv[2]), JSON.parse(process.argv[3])];
const { context, key } = await openSealed(body.sealed, jwk);
console.log(JSON.stringify({ sealed: await seal({ intent: { kind: 'expense', amount: 'N1' }, echo: context }, key) }));
''');
    final run = await Process.run('node', [script.path, jsonEncode(body), jsonEncode(jwk)]);
    expect(run.exitCode, 0, reason: '${run.stderr}');
    final answer = await envelope.open(jsonDecode(run.stdout as String));
    expect(answer['echo'], context, reason: 'The Worker opened exactly what was sealed');
    expect(answer['intent'], {'kind': 'expense', 'amount': 'N1'});
  }, skip: !node || !worker.existsSync() ? 'Node or the Worker\'s code is not available here' : false);
}
