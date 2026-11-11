// Fictitious data only. Automatic help with the iPhone's rules; the occurrence ID vector was computed
// separately with Python and Swift's `RecurringMovementService.occurrenceID` formula.
import 'package:doblon/automation.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/csv_import.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

const a1 = 'aaaaaaaa-0000-4000-8000-000000000001';
const a2 = 'bbbbbbbb-0000-4000-8000-000000000002';

Map<String, dynamic> base() => {
      'formatVersion': 2,
      'accounts': [
        {'id': a1, 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'isArchived': false, 'lastUpdatedAt': 0},
        {'id': a2, 'name': 'Ahorro ficticio', 'typeRaw': 'savings', 'openingDate': 0, 'isArchived': false},
      ],
      'categories': [
        {'id': 'casa', 'name': 'Casa', 'kindRaw': 'expense'},
        {'id': 'super', 'name': 'Supermercado', 'kindRaw': 'expense'},
        {'id': 'nomina', 'name': 'Nómina', 'kindRaw': 'income'},
      ],
      'transactions': <dynamic>[],
      'recurringMovements': <dynamic>[],
      'categoryRules': <dynamic>[],
    };

void main() {
  test('periodic dates and IDs are the iPhone ones', () {
    expect(occurrenceId('11111111-2222-4333-8444-555555555555', DateTime.utc(2026, 11, 15, 10)), '0d99d9af-942d-573c-9ca9-05436f6bf6ce');
    expect(nextDueDate(DateTime(2026, 1, 31), Frequency.monthly, 1), DateTime(2026, 2, 28), reason: 'Month end is kept, like a calendar');
    expect(nextDueDate(DateTime(2026, 11, 30), Frequency.quarterly, 1), DateTime(2027, 2, 28));
    expect(nextDueDate(DateTime(2024, 2, 29), Frequency.yearly, 1), DateTime(2025, 2, 28));
    expect(nextDueDate(DateTime(2026, 11, 10), Frequency.weekly, 2), DateTime(2026, 11, 24));
  });

  test('due periodic movements are posted once, with the shared ID, and the rule moves on', () {
    final doc = base()
      ..['recurringMovements'] = [
        {
          'id': 'alquiler',
          'name': 'Alquiler',
          'typeRaw': 'expense',
          'amountMinor': 70000,
          'descriptionText': 'Alquiler ficticio',
          'frequencyRaw': 'monthly',
          'interval': 1,
          'nextDueDate': referenceSeconds(DateTime(2026, 9, 5, 12)),
          'isActive': true,
          'postsAutomatically': true,
          'sourceAccountID': a1,
          'categoryID': 'casa'
        },
        {
          'id': 'manual',
          'name': 'Sin apunte solo',
          'typeRaw': 'expense',
          'amountMinor': 100,
          'descriptionText': 'x',
          'frequencyRaw': 'monthly',
          'nextDueDate': referenceSeconds(DateTime(2026, 9, 5)),
          'isActive': true,
          'postsAutomatically': false,
          'sourceAccountID': a1,
          'categoryID': 'casa'
        },
      ];
    final now = DateTime(2026, 11, 10, 9);
    final op = postDueMovements(Finances.fromDocument(doc), now)!;
    applyOperation(doc, op);
    final posted = (doc['transactions'] as List).cast<Map>();
    expect(posted.length, 3, reason: 'September, October and November');
    expect(posted.map((t) => t['id']).toSet().length, 3);
    expect(posted.every((t) => t['recurringMovementID'] == 'alquiler' && t['categoryID'] == 'casa'), isTrue);
    final rule = Finances.fromDocument(doc).recurringMovements.firstWhere((r) => r.id == 'alquiler');
    expect(rule.nextDueDate.month, 12);
    expect(postDueMovements(Finances.fromDocument(doc), now)?.data['ops'].where((o) => o['kind'] == 'insert'), anyOf(isNull, isEmpty),
        reason: 'Opening the app again posts nothing twice');
  });

  test('linked bank accounts and rules without category are not posted', () {
    final doc = base();
    (doc['accounts'] as List)[0]['bankIdentityKey'] = 'enable:${'0' * 64}';
    doc['recurringMovements'] = [
      {
        'id': 'r',
        'name': 'Recibo',
        'typeRaw': 'expense',
        'amountMinor': 100,
        'descriptionText': 'x',
        'frequencyRaw': 'monthly',
        'nextDueDate': referenceSeconds(DateTime(2026, 11, 1)),
        'isActive': true,
        'postsAutomatically': true,
        'sourceAccountID': a1,
        'categoryID': 'casa'
      },
      {
        'id': 's',
        'name': 'Sin categoría',
        'typeRaw': 'expense',
        'amountMinor': 100,
        'descriptionText': 'x',
        'frequencyRaw': 'monthly',
        'nextDueDate': referenceSeconds(DateTime(2026, 11, 1)),
        'isActive': true,
        'postsAutomatically': true,
        'sourceAccountID': a2
      },
    ];
    expect(postDueMovements(Finances.fromDocument(doc), DateTime(2026, 11, 10)), isNull);
  });

  test('category rules: longest phrase wins; remembering updates the same rule', () {
    final doc = base()
      ..['categoryRules'] = [
        {'id': 'r1', 'phrase': 'mercadona', 'transactionTypeRaw': 'expense', 'isActive': true, 'categoryID': 'super', 'updatedAt': 0},
        {'id': 'r2', 'phrase': 'mercadona hogar', 'transactionTypeRaw': 'expense', 'isActive': true, 'categoryID': 'casa', 'updatedAt': 0},
        {'id': 'r3', 'phrase': 'nomina', 'transactionTypeRaw': 'income', 'isActive': false, 'categoryID': 'nomina', 'updatedAt': 0},
      ];
    final data = Finances.fromDocument(doc);
    expect(matchRule('COMPRA MERCADONA 123', TransactionType.expense, data)?.id, 'super');
    expect(matchRule('Mercadona Hogar Ficticio', TransactionType.expense, data)?.id, 'casa');
    expect(matchRule('Nómina octubre', TransactionType.income, data), isNull, reason: 'Inactive rule');
    expect(matchRule('Mercadona', TransactionType.income, data), isNull, reason: 'Other type');
    final update = rememberRule('MERCADONA', TransactionType.expense, data.category('casa')!, data, DateTime(2026, 11, 10), 'nuevo')!;
    expect(update.data['record']['id'], 'r1');
    expect(rememberRule('ab', TransactionType.expense, data.category('casa')!, data, DateTime(2026, 11, 10), 'x'), isNull, reason: 'Too short');
  });

  test('own transfers between linked accounts are paired and joined with both bank keys', () {
    final doc = base();
    (doc['accounts'] as List)[0]['bankIdentityKey'] = 'enable:${'1' * 64}';
    (doc['accounts'] as List)[1]['bankIdentityKey'] = 'enable:${'2' * 64}';
    doc['transactions'] = [
      {
        'id': 'cargo',
        'date': referenceSeconds(DateTime(2026, 11, 3)),
        'typeRaw': 'expense',
        'amountMinor': 20000,
        'descriptionText': 'TRANSFERENCIA A AHORRO',
        'sourceAccountID': a1,
        'bankEntryKey': 'enable-entry:x:a:1',
        'duplicateStateRaw': 'none',
        'notes': ''
      },
      {
        'id': 'abono',
        'date': referenceSeconds(DateTime(2026, 11, 4)),
        'typeRaw': 'income',
        'amountMinor': 20000,
        'descriptionText': 'Movimiento bancario',
        'sourceAccountID': a2,
        'bankEntryKey': 'enable-entry:x:b:1',
        'duplicateStateRaw': 'none',
        'notes': ''
      },
    ];
    final data = Finances.fromDocument(doc);
    final pairs = ownTransferPairs(data);
    expect(pairs.single.debit.id, 'cargo');
    applyOperation(doc, joinOwnTransfer(pairs.single, data, DateTime(2026, 11, 10)));
    final joined = (doc['transactions'] as List).single as Map;
    expect(joined['typeRaw'], 'transfer');
    expect(joined['destinationAccountID'], a2);
    expect(bankKeys(joined['bankEntryKey'] as String), ['enable-entry:x:a:1', 'enable-entry:x:b:1']);
    expect(ownTransferPairs(Finances.fromDocument(doc)), isEmpty);
  });

  test('Don Bigotes points out facts, never advice', () {
    final doc = base()
      ..['transactions'] = [
        {
          'id': 't',
          'date': referenceSeconds(DateTime(2026, 11, 1)),
          'typeRaw': 'expense',
          'amountMinor': 100,
          'descriptionText': 'Sin categoría',
          'sourceAccountID': a1
        },
      ];
    final notes = companionNotes(Finances.fromDocument(doc), DateTime(2026, 11, 10));
    expect(notes.map((n) => n.title), contains('1 movimiento por revisar'));
    expect(notes.map((n) => n.title), contains('2 cuentas sin actualizar'), reason: 'Updated long ago, without bank');
    expect(notes.any((n) => RegExp(r'deberías|te recomiendo|ahorra', caseSensitive: false).hasMatch('${n.title} ${n.detail}')), isFalse);
  });

  test('a bank posting that may be a manual record waits for the person; Apple Pay ones pair alone', () {
    final account = RemoteAccount(id: 'remota', currency: 'EUR', lastFour: '0000');
    final connection = RemoteConnection(id: '00000000-0000-4000-8000-000000000001', bank: 'Banco Ficticio', validUntil: '2027-01-01', accounts: [account]);
    final identity = accountIdentity('remota');
    final doc = base();
    (doc['accounts'] as List)[0]['bankIdentityKey'] = identity;
    doc['transactions'] = [
      {
        'id': 'manual',
        'date': referenceSeconds(DateTime.utc(2026, 11, 7, 10)),
        'typeRaw': 'expense',
        'amountMinor': 1250,
        'descriptionText': 'Cena',
        'sourceAccountID': a1
      },
      {
        'id': 'applepay',
        'date': referenceSeconds(DateTime.utc(2026, 11, 2, 10)),
        'typeRaw': 'expense',
        'amountMinor': 450,
        'descriptionText': 'Gasolinera',
        'sourceAccountID': a1,
        'externalID': 'applepay:x'
      },
    ];
    final feed = AccountFeed(connection: connection, account: account, balances: [], movements: [
      Movement(id: 'b1', bookingDate: '2026-11-08', signedAmountMinor: -1250, currency: 'EUR', description: 'RESTAURANTE'),
      Movement(id: 'b2', bookingDate: '2026-11-06', signedAmountMinor: -450, currency: 'EUR', description: 'PAGO TARJETA'),
    ]);
    final now = DateTime.utc(2026, 11, 10, 12);
    final (first, result) = importFeeds(doc, [feed], now);
    expect(result.matched, 1, reason: 'The Apple Pay payment pairs alone');
    expect(result.proposals.single.candidateIds, ['manual']);
    expect((first['transactions'] as List).length, 2, reason: 'Nothing duplicated while waiting');
    final applePay = (first['transactions'] as List).cast<Map>().firstWhere((t) => t['id'] == 'applepay');
    expect(applePay['externalID'], isNull);
    expect(applePay['bankEntryKey'], isNotNull);
    final key = result.proposals.single.key;
    final (asSame, _) = importFeeds(doc, [feed], now, decisions: {key: 'manual'});
    expect((asSame['transactions'] as List).length, 2);
    expect((asSame['transactions'] as List).cast<Map>().firstWhere((t) => t['id'] == 'manual')['bankEntryKey'], key);
    final (asNew, _) = importFeeds(doc, [feed], now, decisions: {key: 'new'});
    expect((asNew['transactions'] as List).length, 3);
  });

  test('CSV: Spanish bank export, duplicates and invalid rows', () {
    const text = 'Fecha;Concepto;Importe;Categoría\n'
        '08/11/2026;"COMPRA; SUPER FICTICIO";-45,30;Supermercado\n'
        '09/11/2026;NOMINA FICTICIA;1.500,00;\n'
        'no-fecha;X;1;\n'
        '10/11/2026;CERO;0,00;\n';
    final parsed = parseCsv(text);
    expect(parsed.drafts.length, 2);
    expect(parsed.warnings.length, 2);
    expect(parsed.drafts.first.description, 'COMPRA; SUPER FICTICIO');
    expect(parsed.drafts.first.signedAmountMinor, -4530);
    expect(parsed.drafts.first.type, TransactionType.expense);
    expect(parsed.drafts.last.signedAmountMinor, 150000);
    final doc = base();
    final plan = planCsv(parsed, Finances.fromDocument(doc), a1);
    expect(plan.map((p) => p.status), ['new', 'new']);
    expect(plan.first.categoryId, 'super');
    var n = 0;
    applyOperation(doc, importCsvOperation(plan, DateTime(2026, 11, 10), () => 'csv-${n++}'));
    expect((doc['transactions'] as List).length, 2);
    final again = planCsv(parsed, Finances.fromDocument(doc), a1);
    expect(again.map((p) => p.status), ['duplicate', 'duplicate'], reason: 'Importing the same file twice adds nothing');
    expect(() => parseCsv('a;b\n1;2'), throwsA(isA<CsvError>()));
    expect(parseCsvDate('2026-11-08'), DateTime(2026, 11, 8, 12));
    expect(parseCsvDate('12/31/2026'), DateTime(2026, 12, 31, 12), reason: 'Month first only when day first is impossible');
    expect(signedAmount('(12,50)'), -1250);
    expect(exportCsv(Finances.fromDocument(doc).transactions, Finances.fromDocument(doc)).split('\n').first, startsWith('Fecha;Tipo;Importe'));
  });

  test('any entity: create, edit only the given fields, remove, and batches', () {
    final doc = base();
    expect(applyOperation(doc, upsertOperation('goals', {'id': 'g', 'name': 'Viaje', 'targetAmountMinor': 1000}, create: true)), isTrue);
    expect(applyOperation(doc, upsertOperation('goals', {'id': 'g', 'targetAmountMinor': 2000}, create: false)), isTrue);
    expect((doc['goals'] as List).single, {'id': 'g', 'name': 'Viaje', 'targetAmountMinor': 2000});
    expect(applyOperation(doc, upsertOperation('goals', {'id': 'otro', 'name': 'X'}, create: false)), isFalse,
        reason: 'An edit never brings back something deleted elsewhere');
    expect(rawRecord(doc, 'goals', 'G')?['name'], 'Viaje');
    applyOperation(
        doc,
        batchOperation([
          removeOperation('goals', 'g'),
          upsertOperation('cards', {'id': 'c', 'name': 'Tarjeta'}, create: true)
        ]));
    expect(doc['goals'], isEmpty);
    expect((doc['cards'] as List).length, 1);
  });
}
