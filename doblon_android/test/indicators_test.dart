// Fictitious data only. The same figures on Inicio and Cuentas (24 November 2026): «Disponible» takes the bank's holds
// once and only from the accounts whose money is available; «Invertido» says when it is only part of the portfolios,
// and its breakdown tells where each value comes from (a valuation and its date, plus what was recorded after it),
// keeping the person's net worth choices and never adding a contribution twice over a later valuation.
import 'package:doblon/bank_activity.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/investments.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 24, 18);

Account account(String id, AccountType type, {bool counted = true, String? bank, bool? summary}) =>
    Account(id: id, name: 'Cuenta $id', type: type, openingDate: DateTime(2026, 1, 1), includeInNetWorth: counted, bankIdentityKey: bank, inInvestmentSummary: summary);

BankActivity holding(List<int> holds) => BankActivity(observedAt: now, currency: 'EUR', pendingMovements: [
      for (final (i, h) in holds.indexed) PendingMovement(id: 'h$i', date: '2026-11-24', signedAmountMinor: h, currency: 'EUR', description: 'Retención ficticia', status: 'HOLD'),
    ]);

void main() {
  test('«Disponible» takes the holds once, only from accounts whose money is available', () {
    final data = Finances(accounts: [
      account('corriente', AccountType.checking, bank: 'k1'),
      account('tarjeta', AccountType.creditCard, bank: 'k2'),
      account('fuera', AccountType.checking, counted: false, bank: 'k3'),
    ], snapshots: [
      BalanceSnapshot(id: 's', date: DateTime(2026, 11, 20), balanceMinor: 100000, accountId: 'corriente', source: 'bankAPI'),
    ]);
    final activity = {'k1': holding([-1005]), 'k2': holding([-5000]), 'k3': holding([-700])};
    expect(spendableHolds(data, activity), -1005, reason: 'Not the credit card nor an account left out of net worth');
    final calc = FinanceCalculator(data);
    // Inicio and Cuentas use the same two parts: what is available, plus the holds.
    expect(calc.spendableCash() + spendableHolds(data, activity), 100000 - 1005);
  });

  test('«Invertido»: the portfolios of the summary are chosen apart from net worth, and the breakdown explains each value', () {
    final data = Finances(
      accounts: [
        account('efectivo', AccountType.checking),
        account('valores', AccountType.investment, counted: false),
        account('saveback', AccountType.investment, bank: 'k'),
      ],
      snapshots: [
        BalanceSnapshot(id: 'v', date: DateTime(2026, 11, 3), balanceMinor: 30000, accountId: 'valores', source: 'manual'),
        BalanceSnapshot(id: 'b', date: DateTime(2026, 11, 24, 9), balanceMinor: 1924, accountId: 'saveback', source: 'bankAPI'),
      ],
      transactions: [
        for (final (i, day) in [10, 17, 24].indexed)
          Transaction(
              id: 'o$i',
              date: DateTime(2026, 11, day, 10),
              type: TransactionType.transfer,
              amountMinor: 3999,
              descriptionText: 'Orden ficticia',
              sourceAccountId: 'efectivo',
              destinationAccountId: 'valores'),
        Transaction(
            id: investmentFeeId('o2'),
            date: DateTime(2026, 11, 24, 10),
            type: TransactionType.fee,
            amountMinor: 150,
            descriptionText: 'Comisión',
            sourceAccountId: 'efectivo',
            externalId: '${investmentFeeMarker}o2'),
      ]..sort((a, b) => b.date.compareTo(a.date)),
    );
    final calc = FinanceCalculator(data);
    expect(calc.invested(), 1924, reason: 'Net worth keeps the choice of the person');
    // The investment summary is another choice: by default every portfolio, also one out of net worth.
    expect(investedInSummary(data, calc.balance, now), 30000 + 3 * 3999 + 1924);
    // The person takes the small portfolio out of the summary: only the chosen one, net worth as it was.
    final chosenData = Finances(
        accounts: [for (final a in data.accounts) a.id == 'saveback' ? account('saveback', AccountType.investment, bank: 'k', summary: false) : a],
        snapshots: data.snapshots,
        transactions: data.transactions);
    final chosenCalc = FinanceCalculator(chosenData);
    expect(investedInSummary(chosenData, chosenCalc.balance, now), 30000 + 3 * 3999, reason: 'Only the chosen portfolio');
    expect(summaryPortfolios(chosenData).map((a) => a.id), ['valores']);
    expect(chosenCalc.invested(), 1924, reason: 'Net worth does not depend on the summary');
    final chosen = investmentFlows(data, DateTime(2026, 11), now: now, accounts: {'valores'});
    expect((chosen.contributedMinor, chosen.feesMinor), (3 * 3999, 150), reason: 'The order and its fee belong to the chosen portfolio');
    expect(investmentFlows(data, DateTime(2026, 11), now: now, accounts: {'saveback'}).isEmpty, isTrue);
    expect(data.accounts.firstWhere((a) => a.id == 'valores').includeInNetWorth, isFalse, reason: 'Never changed by the summary');
    final values = {for (final v in portfolioValues(data, calc.balance, now)) v.account.id: v};
    final shares = values['valores']!;
    expect((shares.counted, shares.valueMinor, shares.afterMinor, shares.movementsAfter), (false, 30000 + 3 * 3999, 3 * 3999, 3));
    expect(shares.valuation!.date, DateTime(2026, 11, 3), reason: 'The valuation keeps its date: not a market price of today');
    expect((values['saveback']!.fromBank, values['saveback']!.valueMinor), (true, 1924));
    final flows = investmentFlows(data, DateTime(2026, 11), now: now);
    expect((flows.contributedMinor, flows.feesMinor), (3 * 3999, 150), reason: 'Contributions and fees of the month, apart from the value');
  });

  test('a later valuation that already includes the contributions is not added to them again', () {
    final data = Finances(accounts: [account('efectivo', AccountType.checking), account('valores', AccountType.investment)], snapshots: [
      BalanceSnapshot(id: 'v', date: DateTime(2026, 11, 22), balanceMinor: 12500, accountId: 'valores', source: 'manual'),
    ], transactions: [
      Transaction(
          id: 'o',
          date: DateTime(2026, 11, 20),
          type: TransactionType.transfer,
          amountMinor: 3999,
          descriptionText: 'Orden ficticia',
          sourceAccountId: 'efectivo',
          destinationAccountId: 'valores'),
    ]);
    final calc = FinanceCalculator(data);
    final value = portfolioValues(data, calc.balance, now).single;
    expect((value.valueMinor, value.movementsAfter), (12500, 0));

  });
}
