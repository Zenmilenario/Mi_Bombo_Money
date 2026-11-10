// The same hand-calculated cases as Tests/FinancialLogicCheck.swift (`checkSharedCases`), read from
// Tests/Fixtures/shared_finance_cases.json: Android and iPhone must give exactly the same results.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

DateTime day(String text) {
  final parts = text.split('-').map(int.parse).toList();
  return DateTime(parts[0], parts[1], parts.length > 2 ? parts[2] : 1, 12);
}

void main() {
  final root = jsonDecode(File('../Tests/Fixtures/shared_finance_cases.json').readAsStringSync()) as Map<String, dynamic>;
  List<Map<String, dynamic>> list(String key) => (root[key] as List).cast<Map<String, dynamic>>();
  final expected = root['expected'] as Map<String, dynamic>;
  List<Map<String, dynamic>> want(String key) => (expected[key] as List).cast<Map<String, dynamic>>();

  final accounts = {
    for (final row in list('accounts'))
      row['id'] as String: Account(
          id: row['id'] as String,
          name: row['id'] as String,
          type: AccountType.values.byName(row['type'] as String),
          currencyCode: row['currency'] as String? ?? 'EUR',
          openingBalanceMinor: row['openingBalanceMinor'] as int,
          openingDate: day(row['openingDay'] as String),
          includeInNetWorth: row['includeInNetWorth'] as bool? ?? true),
  };
  final finances = Finances(
    accounts: accounts.values.toList(),
    categories: [for (final row in list('categories')) Category(id: row['id'] as String, name: row['id'] as String, kind: CategoryKind.values.byName(row['kind'] as String))],
    reservedFunds: [
      for (final row in list('funds'))
        ReservedFund(id: row['id'] as String, name: row['id'] as String, amountMinor: row['amountMinor'] as int, accountId: row['account'] as String)
    ],
    transactions: [
      for (final row in list('transactions'))
        Transaction(
            id: row['id'] as String,
            date: day(row['day'] as String),
            type: TransactionType.values.byName(row['type'] as String),
            amountMinor: row['amountMinor'] as int,
            descriptionText: row['id'] as String,
            sourceAccountId: row['source'] as String?,
            destinationAccountId: row['destination'] as String?,
            categoryId: row['category'] as String?,
            reservedFundId: row['fund'] as String?,
            reservedAmountMinor: row['reservedAmountMinor'] as int?)
    ],
    snapshots: [
      for (final row in list('snapshots'))
        BalanceSnapshot(id: row['id'] as String, date: day(row['day'] as String), balanceMinor: row['balanceMinor'] as int, accountId: row['account'] as String)
    ],
    recurringBudgets: [
      for (final row in list('recurringBudgets'))
        RecurringBudget(
            id: row['id'] as String,
            startMonth: day(row['startMonth'] as String),
            baseLimitMinor: row['baseLimitMinor'] as int,
            remainderChoice: RemainderChoice.values.byName(row['remainderChoice'] as String),
            categoryId: row['category'] as String)
    ],
    budgets: [
      for (final row in list('monthlyBudgets'))
        MonthlyBudget(id: row['id'] as String, monthStart: day(row['month'] as String), limitMinor: row['limitMinor'] as int, categoryId: row['category'] as String)
    ],
  );
  final calc = FinanceCalculator(finances);

  test('balances', () {
    for (final row in want('balances')) {
      expect(calc.balance(accounts[row['account']]!, day(row['day'] as String)), row['minor'], reason: '${row['account']} on ${row['day']}');
    }
  });
  test('net worth', () {
    for (final row in want('netWorth')) {
      expect(calc.netWorth(day(row['day'] as String)), row['minor'], reason: '${row['day']}');
    }
  });
  test('reserved money and spendable cash', () {
    for (final row in want('reserved')) {
      expect(calc.reservedAmount(accounts[row['account']]!), row['minor'], reason: '${row['account']}');
    }
    expect(calc.spendableCash(), expected['spendableCash']);
  });
  test('monthly summary', () {
    for (final row in want('monthly')) {
      final summary = calc.monthlySummary(day(row['month'] as String));
      expect([summary.incomeMinor, summary.expenseMinor, summary.reservedExpenseMinor], [row['income'], row['expense'], row['reserved']],
          reason: '${row['month']}');
    }
  });
  test('budgets with carry-forward and a monthly override', () {
    for (final row in want('budgets')) {
      final item = calc.budgetProgress(day(row['month'] as String)).firstWhere((b) => b.category.id == row['category']);
      expect([item.limitMinor, item.carriedInMinor, item.spentMinor], [row['limit'], row['carried'], row['spent']], reason: '${row['month']}');
    }
  });
}
