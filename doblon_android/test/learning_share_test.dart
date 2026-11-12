// Fictitious data only. The shared learning (CloudBackend/learning-contract.md) with the same cases the iPhone
// checks (Tests/Fixtures/shared_learning_cases.json): both apps must write and combine it identically.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/banking.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> obj(Object? v) => Map<String, dynamic>.from(v as Map);

void main() {
  final root = jsonDecode(File('../Tests/Fixtures/shared_learning_cases.json').readAsStringSync()) as Map<String, dynamic>;
  setUp(() => runTraining = <T>(T Function() work) async => work());

  test('the metrics of every device add up to the same CSV as the iPhone', () {
    for (final raw in root['metricsSummaries'] as List) {
      final item = obj(raw);
      expect(CategoryMetrics.of(obj(item['metrics']).values.cast<Map>()).toCsv(), item['csv'], reason: '${item['name']}');
    }
  });

  test('canonical signatures are the shared ones', () async {
    for (final raw in root['signatures'] as List) {
      final tx = obj(obj(raw)['transaction']);
      final expected = obj(obj(raw)['expected']);
      final document = {
        'accounts': [
          {'id': tx['sourceAccountID'], 'name': 'Origen ficticio', 'typeRaw': 'checking', 'openingDate': 0, 'currencyCode': tx['sourceCurrency']},
          if (tx['destinationAccountID'] != null)
            {'id': tx['destinationAccountID'], 'name': 'Cartera ficticia', 'typeRaw': 'investment', 'openingDate': 0, 'currencyCode': tx['destinationCurrency']},
        ],
        'categories': [
          if (tx['categoryID'] != null) {'id': tx['categoryID'], 'name': 'Compra', 'kindRaw': 'expense'},
        ],
        'transactions': [
          {
            'id': tx['id'],
            'date': tx['date'],
            'typeRaw': tx['typeRaw'],
            'amountMinor': tx['amountMinor'],
            'descriptionText': tx['descriptionText'],
            'sourceAccountID': tx['sourceAccountID'],
            'destinationAccountID': tx['destinationAccountID'],
            'categoryID': tx['categoryID'],
            'bankEntryKey': tx['bankEntryKey'],
          }
        ],
      };
      final data = Finances.fromDocument(document);
      final t = data.transactions.single;
      expect(t.date.millisecondsSinceEpoch, expected['dateMs']);
      expect(learningAccountKey('${tx['sourceAccountID']}', '${tx['sourceCurrency']}'), expected['accountKey']);
      if (expected['categorySignature'] != null) {
        expect(learningCategorySignature(t.type.name, t.categoryId!, t.descriptionText), expected['categorySignature']);
        final learning = Learning();
        await learning.confirmCategories([t], data, recordCorrection: false);
        expect(obj(obj(learning.toShared()['categories'])[t.id])['signature'], expected['categorySignature']);
      }
      final learning = Learning();
      await learning.confirmKind(OperationKind.investment, t, data);
      expect(obj(obj(learning.toShared()['operations'])[t.id])['signature'], expected['identity'], reason: 'Same identity as the iPhone');
    }
  });

  test('combining follows the shared rules', () {
    for (final raw in root['merges'] as List) {
      final c = obj(raw);
      final merged = mergeLearning(obj(c['local']), obj(c['remote']));
      expect(canonicalLearningJson(merged), canonicalLearningJson(c['expected']), reason: '${c['name']}');
      // What this app reads and writes back is the same document.
      // (A device always has a start date and an automation setting; the cases without them leave them aside.)
      final written = (Learning()..adopt(obj(c['expected']))).toShared();
      for (final key in ['since', 'automation']) {
        if (!obj(c['expected']).containsKey(key)) written.remove(key);
      }
      expect(canonicalLearningJson(written), canonicalLearningJson(c['expected']), reason: '${c['name']}');
    }
  });

  test('what one device teaches reaches the other, removals included', () async {
    final document = {
      'accounts': [
        {'id': 'cuenta', 'name': 'Banco ficticio', 'typeRaw': 'checking', 'openingDate': 0},
      ],
      'categories': [
        {'id': 'super', 'name': 'Supermercado', 'kindRaw': 'expense'},
      ],
      'transactions': [
        {
          'id': 'mov',
          'date': referenceSeconds(DateTime(2026, 5, 4)),
          'typeRaw': 'expense',
          'amountMinor': 1200,
          'descriptionText': 'Compra ficticia',
          'sourceAccountID': 'cuenta',
          'categoryID': 'super',
          'bankEntryKey': 'enable-entry:x:1'
        },
      ],
    };
    final data = Finances.fromDocument(document);
    final t = data.transactions.single;
    final phone = Learning(), tablet = Learning();
    var cloud = <String, dynamic>{'version': 1};
    Future<void> sync(Learning device) async {
      final merged = mergeLearning(device.toShared(), cloud);
      await device.store(merged);
      cloud = merged;
    }

    await phone.confirmCategories([t], data, recordCorrection: false);
    await phone.confirmKind(OperationKind.roundUp, t, data);
    await sync(phone);
    await sync(tablet);
    expect(tablet.confirmations.keys, ['mov']);
    expect((await tablet.review(t, data)).confirmed, OperationKind.roundUp);

    await Future<void>.delayed(const Duration(milliseconds: 5));
    await tablet.confirmKind(null, t, data);
    await sync(tablet);
    await sync(phone);
    expect((await phone.review(t, data)).confirmed, isNull, reason: 'The removal reaches the other device');
    expect(phone.confirmations.keys, ['mov'], reason: 'The category is kept');

    final notified = <int>[];
    phone.onChange = () => notified.add(1);
    await phone.setAutomationEnabled(false);
    await phone.store(cloud);
    expect(notified, [1], reason: 'Only a change made here is announced');
  });
}
