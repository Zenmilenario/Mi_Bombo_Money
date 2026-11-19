// Fictitious data only. Money set aside (18 November 2026): a fund received before using the app, moved to an
// account with interest, paid in instalments; a 2.000 € cushion; interest whose destination the person decides.
// Reserving, moving, paying, editing, joining and downloading again never adds money or counts a payment twice.
import 'package:doblon/banking.dart';
import 'package:doblon/cloud_document_validation.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/reconcile.dart';
import 'package:flutter_test/flutter_test.dart';

import 'banking_test.dart' show emptyDocument, feed, row;

double s(DateTime d) => referenceSeconds(d).toDouble();

/// A current account with the fund, an account with interest, the money received before the app (two incomes),
/// most of it moved to the second account, and one instalment paid with the reserve.
Map<String, dynamic> base() => {
      'formatVersion': 2,
      'accounts': [
        {'id': 'cur', 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': s(DateTime(2026, 10, 2)), 'openingBalanceMinor': 100000},
        {'id': 'int', 'name': 'Remunerada ficticia', 'typeRaw': 'checking', 'openingDate': s(DateTime(2026, 10, 2)), 'openingBalanceMinor': 878100},
      ],
      'categories': [
        {'id': 'edu', 'name': 'Educación', 'kindRaw': 'expense'},
        {'id': 'food', 'name': 'Comida', 'kindRaw': 'expense'},
      ],
      'budgets': [
        {'id': 'b1', 'categoryID': 'edu', 'monthStart': s(DateTime(2026, 10)), 'limitMinor': 10000},
      ],
      // Created when the person started with the app, with the money that had arrived before.
      'reservedFunds': [
        {'id': 'f', 'name': 'Curso ficticio', 'amountMinor': 977500, 'accountID': 'cur', 'createdAt': s(DateTime(2026, 10, 3))},
      ],
      'transactions': [
        // Arrived before the app: where the reserve came from, set aside for it.
        {'id': 'in1', 'date': s(DateTime(2026, 9, 23)), 'typeRaw': 'income', 'amountMinor': 400000, 'descriptionText': 'Ingreso ficticio 1', 'sourceAccountID': 'cur', 'reservedFundID': 'f'},
        {'id': 'in2', 'date': s(DateTime(2026, 9, 30)), 'typeRaw': 'income', 'amountMinor': 577500, 'descriptionText': 'Ingreso ficticio 2', 'sourceAccountID': 'cur', 'reservedFundID': 'f'},
        // Most of it moved to the account with interest, carrying the reserve.
        {
          'id': 'mv',
          'date': s(DateTime(2026, 10, 4)),
          'typeRaw': 'transfer',
          'amountMinor': 878100,
          'descriptionText': 'Traslado ficticio',
          'sourceAccountID': 'cur',
          'destinationAccountID': 'int',
          'reservedFundID': 'f',
          'reservedAmountMinor': 878100
        },
        // An instalment of the course, paid with the reserve.
        {
          'id': 'p1',
          'date': s(DateTime(2026, 10, 28)),
          'typeRaw': 'expense',
          'amountMinor': 97750,
          'descriptionText': 'Plazo ficticio',
          'sourceAccountID': 'cur',
          'categoryID': 'edu',
          'reservedFundID': 'f',
          'reservedAmountMinor': 97750
        },
        // Everyday life.
        {'id': 'n1', 'date': s(DateTime(2026, 10, 30)), 'typeRaw': 'income', 'amountMinor': 150000, 'descriptionText': 'Nómina ficticia', 'sourceAccountID': 'cur'},
        {'id': 'e1', 'date': s(DateTime(2026, 10, 30)), 'typeRaw': 'expense', 'amountMinor': 5000, 'descriptionText': 'Compra ficticia', 'sourceAccountID': 'cur', 'categoryID': 'food'},
      ],
    };

FinanceCalculator calc(Map<String, dynamic> doc) => FinanceCalculator(Finances.fromDocument(doc));
Account acc(FinanceCalculator c, String id) => c.data.account(id)!;

void main() {
  test('the money received before the app is the reserve\'s origin: not everyday income, and not added twice', () {
    final c = calc(base());
    final fund = c.data.reservedFunds.single;
    final where = reservedBalances('cur', fund.amountMinor, c.reserveEntries(fund))!;
    expect(where['cur']! + where['int']!, 977500 - 97750, reason: 'Received, minus the instalment paid; the incomes are not added again');
    final sept = c.monthlySummary(DateTime(2026, 9));
    expect(sept.incomeMinor, 977500, reason: 'The full history keeps it');
    expect(sept.dailyIncomeMinor, 0, reason: 'Not everyday income');
  });

  test('moving it between accounts only changes where it is', () {
    final c = calc(base());
    final fund = c.data.reservedFunds.single;
    final where = reservedBalances('cur', fund.amountMinor, c.reserveEntries(fund))!;
    expect(where['int'], 878100, reason: 'In the account with interest');
    expect(where['cur'], 977500 - 878100 - 97750);
    final oct = c.monthlySummary(DateTime(2026, 10));
    expect(oct.dailyIncomeMinor, 150000, reason: 'Only the salary');
    expect(oct.dailyExpenseMinor, 5000, reason: 'The move is no expense and the instalment is paid by the reserve');
    expect(oct.dailyNetMinor, 145000);
    expect(oct.expenseMinor, 102750, reason: 'The full history keeps the instalment');
    expect(c.reservedAmount(acc(c, 'int')), 878100, reason: 'Still separated while it earns interest');
    expect(c.spendableCash(), c.balance(acc(c, 'cur')) + c.balance(acc(c, 'int')) - c.reservedTotal(), reason: 'Out of the free money');
  });

  test('a payment covered by the reserve does not count in budgets, calendar or analysis; the excess does', () {
    final doc = base();
    // A later instalment larger than what is left in the current account's part of the reserve.
    (doc['transactions'] as List).add({
      'id': 'p2',
      'date': s(DateTime(2026, 10, 29)),
      'typeRaw': 'expense',
      'amountMinor': 10000,
      'descriptionText': 'Plazo ficticio extra',
      'sourceAccountID': 'cur',
      'categoryID': 'edu',
      'reservedFundID': 'f',
      'reservedAmountMinor': 1650
    });
    final c = calc(doc);
    final month = DateTime(2026, 10);
    expect(c.dailySpending(month)[28], isNull, reason: 'The covered instalment is not everyday spending');
    expect(c.dailySpending(month)[29], 10000 - 1650, reason: 'The excess is');
    expect(c.spendingByCategory(month).firstWhere((e) => e.$1.id == 'edu').$2, 10000 - 1650);
    expect(c.budgetProgress(month).firstWhere((b) => b.category.id == 'edu').spentMinor, 10000 - 1650);
    final fund = c.data.reservedFunds.single;
    expect(reservedBalances('cur', fund.amountMinor, c.reserveEntries(fund))!['cur'], 0, reason: 'The reserve in that account is used up, never below zero');
  });

  test('interest: everyday income unless the person sets it aside, then it adds to the reserve', () {
    final doc = base();
    (doc['transactions'] as List).add({'id': 'i1', 'date': s(DateTime(2026, 11, 1)), 'typeRaw': 'interest', 'amountMinor': 2597, 'descriptionText': 'Intereses ficticios', 'sourceAccountID': 'int'});
    var c = calc(doc);
    expect(c.monthlySummary(DateTime(2026, 11)).dailyIncomeMinor, 2597);
    expect(c.reservedAmount(acc(c, 'int')), 878100, reason: 'Not assumed reserved');
    final interest = (doc['transactions'] as List).last as Map<String, dynamic>;
    interest['reservedFundID'] = 'f';
    c = calc(doc);
    expect(c.monthlySummary(DateTime(2026, 11)).dailyIncomeMinor, 0);
    expect(c.reservedAmount(acc(c, 'int')), 878100 + 2597, reason: 'After the reserve existed, it adds to it');
  });

  test('a 2.000 € cushion in a savings account is kept out of the free money, without any income or expense', () {
    final doc = base();
    (doc['accounts'] as List).add({'id': 'sav', 'name': 'Ahorro ficticio', 'typeRaw': 'savings', 'openingDate': s(DateTime(2026, 10, 2)), 'openingBalanceMinor': 500000});
    final before = calc(doc);
    (doc['reservedFunds'] as List).add({'id': 'cushion', 'name': 'Colchón ficticio', 'amountMinor': 200000, 'accountID': 'sav', 'createdAt': s(DateTime(2026, 11, 1))});
    final after = calc(doc);
    expect(after.spendableCash(), before.spendableCash() - 200000);
    expect(after.netWorth(), before.netWorth(), reason: 'The money still exists');
    expect(after.monthlySummary(DateTime(2026, 11)).dailyNetMinor, before.monthlySummary(DateTime(2026, 11)).dailyNetMinor);
  });

  test('a new instalment like the earlier ones is proposed (never linked alone), capped at what is left', () {
    final doc = base();
    (doc['transactions'] as List).add(
        {'id': 'p3', 'date': s(DateTime(2026, 11, 2)), 'typeRaw': 'expense', 'amountMinor': 97750, 'descriptionText': 'Adeudo ficticio', 'sourceAccountID': 'cur'});
    var data = Finances.fromDocument(doc);
    expect(data.transactions.firstWhere((t) => t.id == 'p3').reservedFundId, isNull, reason: 'Nothing changes on its own');
    var cases = reservePaymentCases(data);
    expect(cases.single.payment.id, 'p3');
    expect(cases.single.amountMinor, 0 + (977500 - 878100 - 97750), reason: 'Only what is left in that account');
    applyOperation(doc, payWithReserve(cases.single, DateTime.now()));
    applyOperation(doc, payWithReserve(cases.single, DateTime.now()));
    data = Finances.fromDocument(doc);
    expect(data.transactions.where((t) => t.id == 'p3').length, 1, reason: 'Confirming twice changes nothing more');
    expect(reservePaymentCases(data), isEmpty);
    expect(calc(doc).monthlySummary(DateTime(2026, 11)).dailyExpenseMinor, 97750 - 1650, reason: 'The excess counts');
    // «No es de la reserva» is remembered.
    final fresh = base()
      ..['transactions'] = [
        ...(base()['transactions'] as List),
        {'id': 'p4', 'date': s(DateTime(2026, 11, 2)), 'typeRaw': 'expense', 'amountMinor': 97750, 'descriptionText': 'Otro', 'sourceAccountID': 'cur'}
      ];
    cases = reservePaymentCases(Finances.fromDocument(fresh));
    expect(reservePaymentCases(Finances.fromDocument(fresh), keptApart: {cases.single.id}), isEmpty);
  });

  test('a bank payment linked to the reserve keeps the link after another download', () {
    final account = RemoteAccount(id: 'banco-ficticio', currency: 'EUR', lastFour: '0000');
    var (doc, _) = importFeeds(emptyDocument(), [feed('Banco ficticio', account, [row('ref-1', '2026-11-02', -97750, 'Adeudo')])], DateTime.utc(2026, 11, 3),
        accountChoices: {account.id: 'new'});
    final id = Finances.fromDocument(doc).accounts.single.id;
    doc['reservedFunds'] = [
      {'id': 'f', 'name': 'Curso ficticio', 'amountMinor': 100000, 'accountID': id, 'createdAt': s(DateTime(2026, 10, 3))}
    ];
    final payment = Finances.fromDocument(doc).transactions.single;
    applyOperation(doc, Operation('patch', {
      'id': payment.id,
      'fields': {'reservedFundID': 'f', 'reservedAmountMinor': 97750}
    }));
    final (again, result) = importFeeds(doc, [feed('Banco ficticio', account, [row('ref-1', '2026-11-02', -97750, 'Adeudo')])], DateTime.utc(2026, 11, 4));
    expect(result.inserted, 0);
    final data = Finances.fromDocument(again);
    expect(data.transactions.single.reservedFundId, 'f');
    expect(FinanceCalculator(data).monthlySummary(DateTime(2026, 11)).dailyExpenseMinor, 0);
  });

  test('editing a payment of the reserve keeps the reserve consistent; asking more than it has is refused', () {
    final data = Finances.fromDocument(base());
    final p = data.transactions.firstWhere((t) => t.id == 'p1');
    final draft = TransactionDraft(
        date: p.date,
        type: p.type,
        amountMinor: 200000,
        description: p.descriptionText,
        sourceAccountId: 'cur',
        categoryId: 'edu',
        reservedFundId: 'f',
        reservedAmountMinor: 200000);
    expect(draft.validate(data, editing: p), contains('No hay suficiente'), reason: 'Only 1.000 € of the reserve are in that account');
    draft.reservedAmountMinor = 97750;
    expect(draft.validate(data, editing: p), isNull, reason: 'Partly covered: the rest counts as everyday spending');
  });

  test('encrypted copies of guests accept the same as the cloud: origin before the reserve, more money after it', () {
    Map<String, dynamic> full(Map<String, dynamic> doc) => {
          for (final k in ['institutions', 'cards', 'categoryRules', 'recurringBudgets', 'goals', 'recurringMovements', 'importBatches', 'snapshots']) k: [],
          ...doc,
        };
    final doc = full(base());
    doc['transactions'] = <dynamic>[for (final t in doc['transactions'] as List) Map<String, dynamic>.from(t as Map)];
    // The origin incomes need the part, as the cloud does.
    for (final t in (doc['transactions'] as List).cast<Map<String, dynamic>>()) {
      if (t['typeRaw'] == 'income' && t['reservedFundID'] != null) t['reservedAmountMinor'] = t['amountMinor'];
    }
    expect(() => validatePrivateDocument(doc, 'finance'), returnsNormally);
    // Interest added later lets a later payment use it; without it, that payment is refused.
    (doc['transactions'] as List).addAll([
      {'id': 'i1', 'date': s(DateTime(2026, 11, 1)), 'typeRaw': 'interest', 'amountMinor': 5000, 'descriptionText': 'Intereses', 'sourceAccountID': 'cur',
        'reservedFundID': 'f', 'reservedAmountMinor': 5000},
      {'id': 'p9', 'date': s(DateTime(2026, 11, 2)), 'typeRaw': 'expense', 'amountMinor': 5000, 'descriptionText': 'Pago', 'sourceAccountID': 'cur',
        'reservedFundID': 'f', 'reservedAmountMinor': 1650 + 5000},
    ]);
    ((doc['transactions'] as List).last as Map)['amountMinor'] = 1650 + 5000;
    expect(() => validatePrivateDocument(doc, 'finance'), returnsNormally);
    ((doc['transactions'] as List).firstWhere((t) => t['id'] == 'i1') as Map)
      ..remove('reservedFundID')
      ..remove('reservedAmountMinor');
    expect(() => validatePrivateDocument(doc, 'finance'), throwsFormatException);
  });
}
