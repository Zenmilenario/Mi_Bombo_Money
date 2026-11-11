// Fictitious data only. Editing rules must match the iPhone (TransactionFormView, DuplicateDetectionService,
// TransactionReviewService); the fingerprint vector was computed separately with Python and Swift's formula.
import 'dart:io';

import 'package:doblon/data.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/transaction_form.dart' show parseAmount;
import 'package:flutter_test/flutter_test.dart';

const accountA = 'aaaaaaaa-0000-4000-8000-000000000001';
const accountB = 'bbbbbbbb-0000-4000-8000-000000000002';

Map<String, dynamic> document() => {
      'formatVersion': 2,
      'accounts': [
        {'id': accountA, 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'isArchived': false},
        {'id': accountB, 'name': 'Ahorro ficticio', 'typeRaw': 'savings', 'openingDate': 0, 'isArchived': false},
      ],
      'categories': [
        {'id': 'gasto', 'name': 'Comida', 'kindRaw': 'expense'},
        {'id': 'ingreso', 'name': 'Nómina', 'kindRaw': 'income'},
        {'id': 'traspaso', 'name': 'Ahorro', 'kindRaw': 'transfer'},
        {'id': 'vieja', 'name': 'Archivada', 'kindRaw': 'expense', 'isArchived': true},
      ],
      'transactions': <dynamic>[],
    };

TransactionDraft draft(
        {int amount = 450,
        String text = 'Gasolinera ficticia norte',
        TransactionType type = TransactionType.expense,
        String? destination,
        String? category,
        DateTime? date}) =>
    TransactionDraft(
        date: date ?? DateTime.utc(2026, 11, 8, 10),
        type: type,
        amountMinor: amount,
        description: text,
        sourceAccountId: accountA,
        destinationAccountId: destination,
        categoryId: category);

void main() {
  final now = DateTime.utc(2026, 11, 10, 12);

  test('fingerprint matches the iPhone formula (independent vector)', () {
    expect(
        fingerprint(
            date: DateTime.utc(2026, 11, 8, 10),
            source: accountA,
            destination: null,
            type: TransactionType.expense,
            amountMinor: -450,
            description: 'GASOLINERA Fícticia, Norte!'),
        '4fa567e6fcf5e4543e020e117a8e840a4734382b10959c8d11e7d956782b1362');
    expect(normalizeText('Pago Ñandú a  Café-Bar'), 'pago nandu cafe bar', reason: 'Accents, case, symbols and 1-letter words');
  });

  test('categories follow the type, as on the iPhone', () {
    final data = Finances.fromDocument(document());
    final expense = data.category('gasto')!, income = data.category('ingreso')!, transfer = data.category('traspaso')!;
    expect(categorySupports(expense, TransactionType.fee), isTrue);
    expect(categorySupports(expense, TransactionType.income), isFalse);
    expect(categorySupports(income, TransactionType.interest), isTrue);
    expect(categorySupports(transfer, TransactionType.transfer), isTrue);
    expect(categorySupports(data.category('vieja')!, TransactionType.expense), isFalse, reason: 'Archived categories are not offered');
  });

  test('the form refuses what the cloud would refuse', () {
    final data = Finances.fromDocument(document());
    expect(draft(amount: 0).validate(data), isNotNull);
    expect(draft(text: '   ').validate(data), isNotNull);
    expect(draft(type: TransactionType.transfer).validate(data), contains('destino'));
    expect(draft(type: TransactionType.transfer, destination: accountA).validate(data), contains('distintas'));
    expect(draft(category: 'ingreso').validate(data), contains('categoría'));
    expect(draft(category: 'gasto').validate(data), isNull);
    final withFund = Finances.fromDocument({
      ...document(),
      'reservedFunds': [
        {'id': 'fondo', 'name': 'Viaje', 'amountMinor': 4000, 'accountID': accountA}
      ],
    });
    TransactionDraft reservedDraft({int amount = 5000, int reserved = 3000, TransactionType type = TransactionType.expense}) =>
        draft(amount: amount, type: type)
          ..reservedFundId = 'fondo'
          ..reservedAmountMinor = reserved;
    expect(reservedDraft().validate(withFund), isNull);
    expect(reservedDraft(amount: 2000).validate(withFund), contains('reservado'), reason: 'Never below the reserved part');
    expect(reservedDraft(type: TransactionType.income).validate(withFund), contains('gasto'));
    expect(reservedDraft(reserved: 4500).validate(withFund), contains('suficiente'), reason: 'More than the reserve holds');
  });

  test('a new movement goes to the cloud with every required field, and twins are flagged', () {
    final doc = document();
    final first = saveOperation(draft(category: 'gasto'), Finances.fromDocument(doc), now, newId: 'n1');
    expect(applyOperation(doc, first), isTrue);
    final record = (doc['transactions'] as List).single as Map;
    for (final field in [
      'id',
      'date',
      'typeRaw',
      'amountMinor',
      'descriptionText',
      'notes',
      'isReconciled',
      'fingerprint',
      'duplicateStateRaw',
      'sourceAccountID',
      'createdAt',
      'updatedAt'
    ]) {
      expect(record[field], isNotNull, reason: 'The cloud requires $field');
    }
    expect(record['duplicateStateRaw'], 'none');
    final twin = saveOperation(draft(category: 'gasto'), Finances.fromDocument(doc), now, newId: 'n2');
    expect(twin.data['record']['duplicateStateRaw'], 'possible', reason: 'Same day, account, amount and text');
    final different = saveOperation(draft(amount: 999), Finances.fromDocument(doc), now, newId: 'n3');
    expect(different.data['record']['duplicateStateRaw'], 'none');
    expect(applyOperation(doc, first), isFalse, reason: 'Inserting twice does nothing');
  });

  test('editing keeps untouched fields and recomputes the duplicate state only when it changes', () {
    final doc = document();
    applyOperation(doc, saveOperation(draft(), Finances.fromDocument(doc), now, newId: 'n1'));
    ((doc['transactions'] as List).single as Map)
      ..['bankEntryKey'] = 'enable-entry:x'
      ..['duplicateStateRaw'] = 'possible';
    final stored = Finances.fromDocument(doc).transactions.single;
    final sameMovement = saveOperation(draft(category: 'gasto'), Finances.fromDocument(doc), now, editing: stored);
    expect(sameMovement.data['fields']['duplicateStateRaw'], 'possible', reason: 'Only the category changed');
    applyOperation(doc, saveOperation(draft(amount: 500), Finances.fromDocument(doc), now, editing: stored));
    final edited = (doc['transactions'] as List).single as Map;
    expect(edited['amountMinor'], 500);
    expect(edited['duplicateStateRaw'], 'none', reason: 'Changed and no longer similar to anything');
    expect(edited['bankEntryKey'], 'enable-entry:x', reason: 'Fields the form does not touch are kept');
  });

  test('review issues, categorizing several and "not a duplicate"', () {
    final doc = document();
    final data0 = Finances.fromDocument(doc);
    applyOperation(doc, saveOperation(draft(), data0, now, newId: 'g1'));
    applyOperation(
        doc, saveOperation(draft(amount: 1000, text: 'Nómina ficticia', type: TransactionType.income), Finances.fromDocument(doc), now, newId: 'i1'));
    applyOperation(doc, saveOperation(draft(amount: 200, type: TransactionType.transfer, destination: accountB), Finances.fromDocument(doc), now, newId: 't1'));
    var data = Finances.fromDocument(doc);
    List<ReviewIssue> issuesOf(String id) {
      final t = data.transactions.firstWhere((t) => t.id == id);
      return reviewIssues(t, data.category(t.categoryId));
    }

    expect(issuesOf('g1'), [ReviewIssue.missingCategory]);
    expect(issuesOf('t1'), isEmpty, reason: 'A transfer needs no category');
    final op = categorizeOperation(data.transactions, data.category('gasto')!, now);
    expect(op.data['ids'], ['g1'], reason: 'Only the movements that admit it');
    applyOperation(doc, op);
    data = Finances.fromDocument(doc);
    expect(issuesOf('g1'), isEmpty);
    expect(issuesOf('i1'), [ReviewIssue.missingCategory]);
    ((doc['transactions'] as List).firstWhere((t) => t['id'] == 'g1') as Map)['duplicateStateRaw'] = 'possible';
    data = Finances.fromDocument(doc);
    expect(issuesOf('g1'), [ReviewIssue.possibleDuplicate]);
    applyOperation(doc, notDuplicateOperation(data.transactions.firstWhere((t) => t.id == 'g1'), now));
    data = Finances.fromDocument(doc);
    expect(issuesOf('g1'), isEmpty);
  });

  test('pending changes apply again on a newer cloud copy without losing what another device saved', () {
    final doc = document();
    applyOperation(doc, saveOperation(draft(), Finances.fromDocument(doc), now, newId: 'mio'));
    final pending = [
      saveOperation(draft(amount: 777, text: 'Apuntado sin conexión'), Finances.fromDocument(doc), now, newId: 'offline'),
      deleteOperation(Finances.fromDocument(doc).transactions.single),
    ];
    // Meanwhile another device added a movement and the cloud copy changed.
    final newer = document();
    (newer['transactions'] as List).addAll([
      ...(doc['transactions'] as List),
      {'id': 'otro-dispositivo', 'date': 0, 'typeRaw': 'income', 'amountMinor': 50, 'descriptionText': 'De otro dispositivo', 'sourceAccountID': accountA},
    ]);
    final merged = withPending(newer, pending);
    final ids = (merged['transactions'] as List).map((t) => t['id']).toSet();
    expect(ids, {'offline', 'otro-dispositivo'}, reason: 'Mine added and deleted, theirs kept');
    expect((newer['transactions'] as List).length, 2, reason: 'The cloud copy itself is not modified');
    final again = withPending(merged, pending);
    expect((again['transactions'] as List).length, 2, reason: 'Applying twice changes nothing');
  });

  test('the device copy and the queue survive closing the app', () async {
    final folder = await Directory.systemTemp.createTemp('doblon-test');
    addTearDown(() => folder.delete(recursive: true));
    final store = LocalStore(folder);
    await store.saveCopy('usuario', CloudCopy('ws', 7, document()));
    await store.savePending('usuario', [deleteOperation(Transaction(id: 'x', date: now, type: TransactionType.expense, amountMinor: 1, descriptionText: 'x'))]);
    final copy = await store.loadCopy('usuario');
    expect(copy?.revision, 7);
    expect((await store.loadPending('usuario')).single.kind, 'delete');
    expect(await store.loadCopy('otra-persona'), isNull, reason: 'Each person has their own copy');
    await store.clear('usuario');
    expect(await store.loadCopy('usuario'), isNull);
  });

  test('amounts are read as written in Spain', () {
    expect(parseAmount('12,50'), 1250);
    expect(parseAmount('1.234,56'), 123456);
    expect(parseAmount('12.5'), 1250);
    expect(parseAmount('3 €'), 300);
    expect(parseAmount(''), isNull);
    expect(parseAmount('abc'), isNull);
  });
}
