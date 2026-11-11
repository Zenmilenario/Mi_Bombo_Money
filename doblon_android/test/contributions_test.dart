import 'dart:convert';
import 'dart:io';

import 'package:doblon/automation.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/contributions.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 11);
Map<String, dynamic> document({List<int> charges = const [20000, 20000]}) => {
      'formatVersion': 2,
      'accounts': [
        {'id': 'cash', 'name': 'Efectivo ficticio', 'typeRaw': 'checking', 'currencyCode': 'EUR', 'openingDate': 0, 'openingBalanceMinor': 100000},
        {'id': 'investment', 'name': 'Valores ficticios', 'typeRaw': 'investment', 'currencyCode': 'EUR', 'openingDate': 0},
      ],
      'recurringMovements': [
        {
          'id': 'monthly',
          'name': 'Plan ficticio',
          'typeRaw': 'transfer',
          'amountMinor': 40000,
          'frequencyRaw': 'monthly',
          'interval': 1,
          'isActive': true,
          'postsAutomatically': true,
          'sourceAccountID': 'cash',
          'destinationAccountID': 'investment',
          'nextDueDate': referenceSeconds(DateTime(2026, 11, 2))
        }
      ],
      'transactions': [
        {
          'id': 'scheduled',
          'date': referenceSeconds(DateTime(2026, 11, 2)),
          'typeRaw': 'transfer',
          'amountMinor': 40000,
          'descriptionText': 'Aportación ficticia',
          'sourceAccountID': 'cash',
          'destinationAccountID': 'investment',
          'recurringMovementID': 'monthly'
        },
        for (final (i, amount) in charges.indexed)
          {
            'id': 'bank-$i',
            'date': referenceSeconds(DateTime(2026, 11, 3)),
            'typeRaw': 'expense',
            'amountMinor': amount,
            'descriptionText': 'Plan ficticio $i',
            'sourceAccountID': 'cash',
            'bankEntryKey': 'enable-entry:fictitious:account:ref-$i'
          }
      ],
    };

void main() {
  test('exact-sum combinations are general and never silently choose between alternatives', () {
    final cases = jsonDecode(File('../Tests/Fixtures/contribution_recognition_cases.json').readAsStringSync()) as List;
    for (final entry in cases) {
      final rows = [
        for (final (i, amount) in (entry['amounts'] as List).indexed)
          Transaction(id: '$i', date: now, type: TransactionType.expense, amountMinor: amount as int, descriptionText: 'Ficticio')
      ];
      final expected = entry['selected'] == null ? null : {for (final i in entry['selected'] as List) '$i'};
      expect(contributionCombination(rows, entry['remaining'] as int), expected);
    }
  });

  test('two bank fragments replace the scheduled contribution atomically, once, without expense', () {
    final doc = document();
    final initial = Finances.fromDocument(doc);
    final proposal = contributionProposals(initial, now).single;
    expect(proposal.suggested, {'bank-0', 'bank-1'});
    final operation = confirmContribution(proposal, proposal.suggested!, initial, now);
    final updated = withPending(doc, [operation]);
    final data = Finances.fromDocument(updated);
    expect(data.transactions.length, 2);
    expect(data.transactions.every((t) => t.type == TransactionType.transfer && t.recurringMovementId == 'monthly'), isTrue);
    expect(data.transactions.fold(0, (sum, t) => sum + FinanceCalculator.budgetExpenseAmount(t)), 0);
    expect(FinanceCalculator(data).balance(data.account('investment')!, now), 40000);
    expect(data.transactions.every((t) => t.bankEntryKey != null), isTrue);
    expect(contributionProposals(data, now), isEmpty);
    final repost = postDueMovements(data, now);
    if (repost != null) applyOperation(updated, repost);
    expect((updated['transactions'] as List).length, 2, reason: 'Another device with an older due date must not create the scheduled 400 again');
    expect((doc['transactions'] as List).length, 3, reason: 'Planning is pure');
  });

  test('partial confirmation, edited candidates and opposite destination credits require a fresh review', () {
    final doc = document();
    final proposal = contributionProposals(Finances.fromDocument(doc), now).single;
    expect(() => confirmContribution(proposal, {'bank-0'}, Finances.fromDocument(doc), now), throwsA(isA<BankingError>()));
    (doc['transactions'] as List).last['notes'] = 'Cambio desde otro dispositivo';
    expect(() => confirmContribution(proposal, proposal.suggested!, Finances.fromDocument(doc), now), throwsA(isA<BankingError>()));
    final paired = document();
    (paired['transactions'] as List).add({
      'id': 'credit',
      'date': referenceSeconds(DateTime(2026, 11, 3)),
      'typeRaw': 'income',
      'amountMinor': 20000,
      'sourceAccountID': 'investment',
      'descriptionText': 'Abono ficticio'
    });
    final fresh = contributionProposals(Finances.fromDocument(paired), now).single;
    expect(() => confirmContribution(fresh, fresh.suggested!, Finances.fromDocument(paired), now), throwsA(isA<BankingError>()));
  });

  test('ambiguous charges stay selectable and confirmed contributions reduce the remaining target', () {
    final doc = document(charges: [20000, 20000, 40000]);
    expect(contributionProposals(Finances.fromDocument(doc), now).single.suggested, isNull);
    final partial = document(charges: [20000]);
    final transactions = partial['transactions'] as List;
    transactions[0]['amountMinor'] = 20000;
    transactions.add({
      'id': 'confirmed',
      'date': referenceSeconds(DateTime(2026, 11, 3)),
      'typeRaw': 'transfer',
      'amountMinor': 20000,
      'sourceAccountID': 'cash',
      'destinationAccountID': 'investment',
      'bankEntryKey': 'fictitious-confirmed',
      'recurringMovementID': 'monthly'
    });
    final proposal = contributionProposals(Finances.fromDocument(partial), now).single;
    expect(proposal.remaining, 20000);
    expect(proposal.suggested, {'bank-0'});
  });
}
