import 'package:doblon/banking.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime.utc(2026, 11, 11, 12);
final remote = RemoteAccount(id: 'fictitious-remote', currency: 'EUR', lastFour: '0000');
final connection = RemoteConnection(id: 'fictitious-connection', bank: 'Banco ficticio', validUntil: '2027-01-01', accounts: [remote]);
AccountFeed download() => AccountFeed(connection: connection, account: remote, balances: [
      BankBalance(100000, 'EUR', 'CLBD')
    ], movements: [
      Movement(id: 'fictitious-charge', bookingDate: '2026-11-10', signedAmountMinor: -1000, currency: 'EUR', description: 'Compra ficticia'),
    ]);
Map<String, dynamic> document() =>
    {'formatVersion': 2, 'accounts': <dynamic>[], 'categories': <dynamic>[], 'transactions': <dynamic>[], 'snapshots': <dynamic>[]};

void main() {
  test('an unassociated bank account remains excluded until the person chooses it', () {
    final (excluded, result) = importFeeds(document(), [download()], now);
    expect(excluded['accounts'], isEmpty);
    expect(excluded['transactions'], isEmpty);
    expect(result.unlinkedAccounts, 1);
    final (linked, _) = importFeeds(document(), [download()], now, accountChoices: {remote.id: 'new'});
    expect((linked['accounts'] as List).length, 1);
    expect((linked['transactions'] as List).length, 1);
  });

  test('archiving an imported account is preserved across automatic and explicit downloads', () {
    final (first, _) = importFeeds(document(), [download()], now, accountChoices: {remote.id: 'new'});
    (first['accounts'] as List).single['isArchived'] = true;
    for (final choice in [
      <String, String>{},
      {remote.id: 'new'}
    ]) {
      final (second, result) = importFeeds(first, [download()], now, accountChoices: choice);
      expect((second['accounts'] as List).length, 1);
      expect((second['accounts'] as List).single['isArchived'], isTrue);
      expect(result.inserted, 0);
    }
  });

  test('linking an existing account preserves its identity, opening balance, institution and reserves', () {
    final doc = document();
    doc['accounts'] = [
      {
        'id': 'existing',
        'name': 'Ahorro ficticio',
        'typeRaw': 'savings',
        'currencyCode': 'EUR',
        'openingBalanceMinor': 40000,
        'openingDate': 0,
        'institutionID': 'institution',
        'bankIdentityKey': null
      }
    ];
    doc['reservedFunds'] = [
      {'id': 'reserve', 'accountID': 'existing', 'amountMinor': 10000}
    ];
    final (linked, result) = importFeeds(doc, [download()], now, accountChoices: {remote.id: 'existing'});
    expect(result.newAccounts, 0);
    final account = (linked['accounts'] as List).single;
    expect(account['name'], 'Ahorro ficticio');
    expect(account['institutionID'], 'institution');
    expect(account['openingBalanceMinor'], 40000);
    expect((linked['transactions'] as List).single['sourceAccountID'], 'existing');
    expect((linked['reservedFunds'] as List).single['accountID'], 'existing');
    expect((doc['accounts'] as List).single['bankIdentityKey'], isNull);
  });

  test('reserved money travels to the destination and its later payment preserves available money and budget', () {
    final paidAt = DateTime.utc(2026, 1, 1);
    final doc = document();
    doc['accounts'] = [
      {'id': 'source', 'name': 'Origen ficticio', 'typeRaw': 'checking', 'openingDate': 0, 'openingBalanceMinor': 200000},
      {'id': 'destination', 'name': 'Destino ficticio', 'typeRaw': 'checking', 'openingDate': 0},
    ];
    doc['reservedFunds'] = [
      {'id': 'reserve', 'accountID': 'source', 'amountMinor': 100000}
    ];
    final transfer = TransactionDraft(
        date: paidAt,
        type: TransactionType.transfer,
        amountMinor: 10000,
        description: 'Traslado ficticio',
        sourceAccountId: 'source',
        destinationAccountId: 'destination',
        reservedFundId: 'reserve',
        reservedAmountMinor: 10000);
    expect(transfer.validate(Finances.fromDocument(doc)), isNull);
    applyOperation(doc, saveOperation(transfer, Finances.fromDocument(doc), now, newId: 'move'));
    var data = Finances.fromDocument(doc);
    expect(data.transactions.single.reservedAmountMinor, 10000);
    expect(FinanceCalculator(data).reservedAmount(data.account('destination')!), 10000);
    final expense = TransactionDraft(
        date: paidAt,
        type: TransactionType.expense,
        amountMinor: 10000,
        description: 'Pago ficticio',
        sourceAccountId: 'destination',
        reservedFundId: 'reserve',
        reservedAmountMinor: 10000);
    expect(expense.validate(data), isNull);
    applyOperation(doc, saveOperation(expense, data, now, newId: 'pay'));
    data = Finances.fromDocument(doc);
    final calc = FinanceCalculator(data);
    expect(calc.reservedAmount(data.account('source')!), 90000);
    expect(calc.reservedAmount(data.account('destination')!), 0);
    expect(calc.balance(data.account('source')!, now) - calc.reservedAmount(data.account('source')!), 100000);
    expect(FinanceCalculator.budgetExpenseAmount(data.transactions.last), 0);
    transfer.reservedAmountMinor = 5000;
    expect(transfer.validate(data, editing: data.transactions.first), isNotNull, reason: 'A later payment cannot lose its funding');
  });
}
