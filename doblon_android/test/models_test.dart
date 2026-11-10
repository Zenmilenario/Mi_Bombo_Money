import 'package:doblon/models.dart';
import 'package:doblon/presentation.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('reads the cloud document the iPhone syncs, with Apple reference dates', () {
    // 2026-11-01 00:00:00 UTC is 815184000 seconds after 2001-01-01.
    final finances = Finances.fromDocument({
      'formatVersion': 2,
      'accounts': [
        {'id': 'a1', 'name': 'Cuenta ficticia', 'typeRaw': 'checking', 'openingBalanceMinor': 12345, 'openingDate': 815184000,
         'includeInNetWorth': true, 'isArchived': false, 'sortOrder': 2},
        {'id': 'a0', 'name': 'Efectivo', 'typeRaw': 'cash', 'currencyCode': 'USD', 'openingBalanceMinor': 0, 'openingDate': 815184000, 'sortOrder': 1},
      ],
      'transactions': [
        {'id': 't1', 'date': 815184000, 'typeRaw': 'expense', 'amountMinor': 450, 'descriptionText': 'Gasolinera ficticia',
         'sourceAccountID': 'a1', 'externalID': 'applepay:abc', 'bankEntryKey': null},
        {'id': 't2', 'date': 815270400, 'typeRaw': 'income', 'amountMinor': 1000, 'descriptionText': 'Nómina ficticia',
         'sourceAccountID': 'a1', 'bankEntryKey': 'enable-entry:x'},
      ],
      'categories': [],
      'unknownEntity': [{'id': 'x'}],
    });
    expect(finances.accounts.map((a) => a.id), ['a0', 'a1'], reason: 'Sorted as on the iPhone');
    expect(finances.accounts.map((a) => a.currencyCode), ['USD', 'EUR'], reason: 'Missing currency means euros');
    expect(finances.accounts[1].openingDate.toUtc(), DateTime.utc(2026, 11, 1));
    expect(finances.transactions.first.id, 't2', reason: 'Newest first');
    expect(finances.transactions.last.awaitsBank, isTrue);
    expect(finances.transactions.first.isBanking, isTrue);
    expect(finances.budgets, isEmpty);
  });

  test('bank concepts are shown as on the iPhone', () {
    expect(listTitle('/TXT/D|PAGO CON TARJETA//COMERCIO DEL NORTE, S.L.', isBanking: true), 'Comercio del Norte, S.L.');
    expect(listTitle('TRANSFERENCIA INMEDIATA A AHORRO', isBanking: true), 'Transferencia inmediata · A AHORRO');
    expect(listTitle('/TXT/SUPERMERCADO FICTICIO 08/11/26|123456789', isBanking: true), 'Supermercado Ficticio');
    expect(listTitle('Cena con amigos', isBanking: false), 'Cena con amigos');
    expect(readableCase('ABC'), 'ABC', reason: 'Too short to be a shouting concept');
    expect(money(123456), anyOf(contains('1.234,56'), contains('1234,56')));
    expect(money(-450), contains('4,50'));
    expect(money(450), contains('€'));
    expect(money(450, currency: 'USD'), allOf(contains('4,50'), isNot(contains('€'))), reason: 'A USD account is never shown in euros');
  });

  test('the daily quote changes with the day and never fails', () {
    expect(quoteOfTheDay(DateTime(2026, 11, 10)), isNot(quoteOfTheDay(DateTime(2026, 11, 11))));
    expect(quoteOfTheDay(DateTime(1999, 1, 1)), isNotEmpty);
  });
}
