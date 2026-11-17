// Fictitious data only. A linked account whose bank never sent a booked balance (as Trade Republic) must not
// show "Al día": its balance is the opening balance plus movements and nobody has checked it against the bank.
import 'package:doblon/banking.dart' show stableUuid;
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/accounts.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  final now = DateTime(2026, 11, 17, 12);
  final linked = Account(
      id: 'cuenta-ficticia',
      name: 'Banco ficticio',
      type: AccountType.checking,
      openingBalanceMinor: 100000,
      openingDate: DateTime(2026, 10, 2),
      bankIdentityKey: 'enable:ficticia',
      lastUpdatedAt: DateTime(2026, 11, 13));
  BalanceSnapshot bank(DateTime date, int minor) =>
      BalanceSnapshot(id: stableUuid('enable:ficticia|booked-balance'), date: date, balanceMinor: minor, accountId: linked.id);

  test('without a bank balance the account is not "Al día"', () {
    expect(bankBalanceLabel(linked, const [], now), 'Sin saldo del banco');
    final manual = BalanceSnapshot(id: 'manual', date: now, balanceMinor: 1, accountId: linked.id);
    expect(bankBalanceLabel(linked, [manual], now), 'Sin saldo del banco', reason: 'A balance typed by hand is not the bank');
  });

  test('a recent bank balance is "Al día", an old one is not', () {
    expect(bankBalanceLabel(linked, [bank(now.subtract(const Duration(hours: 3)), 5000)], now), 'Al día');
    expect(bankBalanceLabel(linked, [bank(DateTime(2026, 11, 13), 5000)], now), 'Saldo sin confirmar');
  });

  test('an account without a bank has no label', () {
    final manual = Account(id: 'm', name: 'Efectivo', type: AccountType.cash, openingDate: DateTime(2026, 10, 1));
    expect(bankBalanceLabel(manual, const [], now), isNull);
  });

  test('without a bank balance, the balance is opening plus movements (how the 39,21 € gap can build up)', () {
    final calc = FinanceCalculator(Finances(accounts: [linked], transactions: [
      Transaction(
          id: 't1',
          date: DateTime(2026, 10, 27),
          type: TransactionType.transfer,
          amountMinor: 4175,
          descriptionText: 'Ajuste ficticio',
          sourceAccountId: 'otra',
          destinationAccountId: linked.id),
    ]));
    expect(calc.balance(linked, now), 104175);
  });
}
