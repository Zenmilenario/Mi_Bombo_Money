// Fictitious data only. Card payments recorded with the Shortcuts action of the iPhone are filed as the Swift app
// does (`CardPaymentFiler`), and the bank import pairs them with the bank's movement instead of adding it twice.
import 'package:doblon/banking.dart';
import 'package:doblon/card_payments.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

Map<String, dynamic> document() => {
      'accounts': [
        {'id': 'corriente', 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': accountIdentity('cuenta-banco')},
        {'id': 'ahorro', 'name': 'Ahorro ficticio', 'typeRaw': 'savings', 'openingDate': 0},
        {'id': 'archivada', 'name': 'Archivada', 'typeRaw': 'checking', 'openingDate': 0, 'isArchived': true},
      ],
      'categories': [
        {'id': 'super', 'name': 'Supermercado', 'kindRaw': 'expense'},
      ],
      'categoryRules': [
        {'id': 'r1', 'phrase': 'Mercado Ficticio', 'transactionTypeRaw': 'expense', 'categoryID': 'super'},
      ],
      'transactions': [],
      'snapshots': [],
    };

CardPayment payment(String id, String card, {int amount = 450, String merchant = 'Mercado Ficticio'}) => CardPayment(
    id: id, date: DateTime.utc(2026, 11, 14, 10), amountMinor: amount, merchant: merchant, card: card);

const a = '00000000-0000-4000-8000-00000000000a', b = '00000000-0000-4000-8000-00000000000b', c = '00000000-0000-4000-8000-00000000000c';

void main() {
  final now = DateTime.utc(2026, 11, 14, 12);

  test('each card goes to its account, the rest to the default one, and a card without account waits', () {
    final data = Finances.fromDocument(document());
    final result = fileCardPayments([payment(a, 'Visa Ficticia'), payment(b, 'Otra tarjeta'), payment(c, 'Archivo')], data,
        cardAccounts: {'visa ficticia': 'corriente', 'archivo': 'archivada'}, now: now);
    expect(result.filed, {a}, reason: 'Without a default account the unknown card waits; an archived account is never used');

    final withDefault = fileCardPayments([payment(a, ' VISA FICTICIA '), payment(b, 'Otra tarjeta')], data,
        cardAccounts: {'visa ficticia': 'corriente'}, defaultAccount: 'ahorro', now: now);
    expect(withDefault.filed, {a, b});
    final doc = document();
    applyOperation(doc, withDefault.operation!);
    final rows = {for (final r in doc['transactions'] as List) r['id']: r};
    expect(rows[a]['sourceAccountID'], 'corriente');
    expect(rows[b]['sourceAccountID'], 'ahorro');
    expect(rows[a]['externalID'], 'applepay:$a', reason: 'Marked as waiting for the bank');
    expect(rows[a]['categoryID'], 'super', reason: 'The category rules apply, as on the iPhone');
    expect(rows[a]['typeRaw'], 'expense');
    expect(rows[a]['amountMinor'], 450);
  });

  test('a payment filed on an earlier opening only leaves the inbox, without a second movement', () {
    final doc = document();
    final first = fileCardPayments([payment(a, 'Visa')], Finances.fromDocument(doc), cardAccounts: {}, defaultAccount: 'corriente', now: now);
    applyOperation(doc, first.operation!);
    final again = fileCardPayments([payment(a, 'Visa')], Finances.fromDocument(doc), cardAccounts: {}, defaultAccount: 'corriente', now: now);
    expect(again.filed, {a});
    expect(again.operation, isNull);
  });

  test('the bank movement of the payment is paired with it, not added twice', () {
    final doc = document();
    applyOperation(doc,
        fileCardPayments([payment(a, 'Visa')], Finances.fromDocument(doc), cardAccounts: {}, defaultAccount: 'corriente', now: now).operation!);
    final bank = RemoteConnection(id: 'conexion', bank: 'Banco Ficticio', validUntil: '2027-01-01', accounts: []);
    final account = RemoteAccount(id: 'cuenta-banco', currency: 'EUR', lastFour: '0000');
    final (next, result) = importFeeds(
        doc,
        [
          AccountFeed(connection: bank, account: account, balances: [], movements: [
            Movement(id: 'mov-1', bookingDate: '2026-11-16', signedAmountMinor: -450, currency: 'EUR', description: 'COMPRA MERCADO FICTICIO'),
          ])
        ],
        DateTime.utc(2026, 11, 16, 12));
    expect(result.matched, 1);
    expect(result.inserted, 0);
    final row = (next['transactions'] as List).single as Map;
    expect(row['externalID'], isNull, reason: 'No longer waiting for the bank');
    expect(row['bankEntryKey'], isNotNull);
  });

  test('what the action writes is read safely', () {
    expect(CardPayment.tryParse('{"id":"$a","date":"2026-11-14T10:00:00Z","amountMinor":450,"merchant":" Bar ","card":"Visa"}')?.merchant, 'Bar');
    expect(CardPayment.tryParse('{"id":"no-es-un-id","date":"2026-11-14T10:00:00Z","amountMinor":450}'), isNull);
    expect(CardPayment.tryParse('{"id":"$a","date":"2026-11-14T10:00:00Z","amountMinor":0}'), isNull);
    expect(CardPayment.tryParse('roto'), isNull);
  });
}
