// Fictitious data only. The October case (18 November 2026): two bank transfers from a current account to an
// investment account, each reported by both banks, one side turned into a transfer by hand, plus a transfer typed by
// hand for their sum. Same money must never count twice, and different operations must never be joined.
import 'dart:convert';

import 'package:doblon/automation.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/data.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/reconcile.dart';
import 'package:doblon/screens/reconcile_screen.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'banking_test.dart' show emptyDocument, feed, row;

final observed = DateTime.utc(2026, 10, 3, 12);
final current = RemoteAccount(id: 'corriente-ficticia', currency: 'EUR', lastFour: '1111');
final broker = RemoteAccount(id: 'broker-ficticio', currency: 'EUR', lastFour: '2222');

List<AccountFeed> feeds() => [
      feed('Banco ficticio', current, [
        row('ref-600', '2026-10-02', -60000, 'TRANS INM ficticia'),
        row('ref-1000', '2026-10-02', -100000, 'TRANS INM ficticia'),
        row('ref-nomina', '2026-10-02', 175830, 'Nómina ficticia'),
      ]),
      // The broker sends no references: its keys come from date, amount and order.
      feed('Broker ficticio', broker, [row(null, '2026-10-02', 60000, 'Ingreso'), row(null, '2026-10-02', 100000, 'Ingreso')], balances: []),
    ];

Map<String, dynamic> imported() =>
    importFeeds(emptyDocument(), feeds(), observed, accountChoices: {current.id: 'new', broker.id: 'new'}).$1;

Finances fin(Map<String, dynamic> doc) => Finances.fromDocument(doc);
Transaction pick(Finances data, String account, int amount, TransactionType type) =>
    data.transactions.firstWhere((t) => t.sourceAccountId == account && t.amountMinor == amount && t.type == type);

/// The person turns a movement into a transfer to the other account (the form's patch).
void toTransfer(Map<String, dynamic> doc, Transaction t, String from, String to) {
  final draft = TransactionDraft(
      date: t.date, type: TransactionType.transfer, amountMinor: t.amountMinor, description: t.descriptionText, sourceAccountId: from, destinationAccountId: to);
  applyOperation(doc, saveOperation(draft, fin(doc), DateTime.now(), editing: t));
}

int balanceOf(Map<String, dynamic> doc, String account) {
  final data = fin(doc);
  return FinanceCalculator(data).balance(data.account(account)!, DateTime.utc(2026, 10, 10));
}

void main() {
  setUpAll(() => initializeDateFormatting('es'));
  setUp(() => SharedPreferences.setMockInitialValues({}));

  late String nom, brk;
  Map<String, dynamic> october() {
    final doc = imported();
    final data = fin(doc);
    nom = data.accounts.firstWhere((a) => a.bankIdentityKey == accountIdentity(current.id)).id;
    brk = data.accounts.firstWhere((a) => a.bankIdentityKey == accountIdentity(broker.id)).id;
    // What happened on the device: both broker credits and the 1.000 € charge were turned into transfers by hand.
    toTransfer(doc, pick(fin(doc), brk, 60000, TransactionType.income), nom, brk);
    toTransfer(doc, pick(fin(doc), brk, 100000, TransactionType.income), nom, brk);
    toTransfer(doc, pick(fin(doc), nom, 100000, TransactionType.expense), nom, brk);
    return doc;
  }

  test('the cause: each side of the same transfer became its own record, so the money counted twice', () {
    final doc = october();
    final data = fin(doc);
    final out = effects(data.transactions.where((t) => t.date.month == 10 && t.amountMinor != 175830));
    expect(out[nom], -320000, reason: '1.600 € left, but 3.200 € are counted (600 as an expense and as a transfer, 1.000 twice)');
    expect(ownTransferPairs(data), isEmpty, reason: 'The old detection only looked at charge and credit not yet converted');
  });

  test('B: a transfer and the other side of the same money are proposed and joined, counting once', () {
    final doc = october();
    final cases = sameTransferCases(fin(doc));
    expect(cases.length, 2, reason: '600 (transfer + charge) and 1.000 (two transfers)');
    for (final c in cases) {
      final data = fin(doc);
      final planned = joinOperation(MatchCase(c.kind, data.transactions.firstWhere((t) => t.id == c.first.id), data.transactions.firstWhere((t) => t.id == c.second.id)),
          data, doc, DateTime.now())!;
      applyOperation(doc, planned.op);
    }
    final data = fin(doc);
    final left = data.transactions.where((t) => t.amountMinor != 175830).toList();
    expect(left.length, 2);
    expect(left.every((t) => t.type == TransactionType.transfer && t.sourceAccountId == nom && t.destinationAccountId == brk), isTrue);
    expect(effects(left), {nom: -160000, brk: 160000}, reason: 'Each euro once');
    for (final t in left) {
      expect(bankKeys(t.bankEntryKey).length, 2, reason: 'Both bank references kept');
    }
    expect(sameTransferCases(data), isEmpty);
    expect(fin(doc).transactions.where((t) => t.duplicateState == 'possible'), isEmpty);
  });

  test('a later download and a second confirmation create nothing again', () {
    final doc = october();
    for (final c in sameTransferCases(fin(doc))) {
      applyOperation(doc, joinOperation(c, fin(doc), doc, DateTime.now())!.op);
    }
    final count = (doc['transactions'] as List).length;
    final (again, result) = importFeeds(doc, feeds(), observed.add(const Duration(days: 1)));
    expect(result.inserted, 0);
    expect((again['transactions'] as List).length, count, reason: 'Known keys are skipped');
    // Confirming the same join twice: the second time there is nothing left to join.
    final c = MatchCase(MatchKind.transfer, fin(doc).transactions.first, fin(doc).transactions.last);
    expect(sameTransferCases(fin(doc)), isEmpty);
    expect(joinOperation(c, fin(doc), doc, DateTime.now()) == null || classify(c.first, c.second, fin(doc)).kind != null, isTrue);
  });

  test('undo puts both records back with their bank references; a download after it creates nothing', () {
    final doc = october();
    final before = jsonEncode(fin(doc).transactions.map((t) => [t.id, t.type.name, t.bankEntryKey, t.amountMinor]).toList()..sort((a, b) => '$a'.compareTo('$b')));
    final c = sameTransferCases(fin(doc)).first;
    final planned = joinOperation(c, fin(doc), doc, DateTime.now())!;
    applyOperation(doc, planned.op);
    applyOperation(doc, MergeTrace.fromJson(jsonDecode(jsonEncode(planned.trace.toJson())) as Map<String, dynamic>).undo(DateTime.now()));
    final after = jsonEncode(fin(doc).transactions.map((t) => [t.id, t.type.name, t.bankEntryKey, t.amountMinor]).toList()..sort((a, b) => '$a'.compareTo('$b')));
    expect(after, before);
    expect(importFeeds(doc, feeds(), observed.add(const Duration(days: 1))).$2.inserted, 0);
  });

  test('C: different operations with the same amount, or amounts that only add up, are never joined', () {
    final doc = october();
    // A transfer typed by hand for the sum of both.
    applyOperation(
        doc,
        saveOperation(
            TransactionDraft(
                date: DateTime.utc(2026, 10, 2, 12),
                type: TransactionType.transfer,
                amountMinor: 160000,
                description: 'Traspaso ficticio',
                sourceAccountId: nom,
                destinationAccountId: brk),
            fin(doc),
            DateTime.now(),
            newId: '00000000-0000-4000-8000-0000000016a0'));
    final data = fin(doc);
    final typed = data.transactions.firstWhere((t) => t.amountMinor == 160000);
    expect(classify(typed, pick(data, nom, 60000, TransactionType.expense), data).blocked, contains('sumen'));
    expect(sameTransferCases(data).any((c) => c.first.id == typed.id || c.second.id == typed.id), isFalse, reason: 'Never by amount alone');
    // Two charges of the same bank account are two operations.
    final twoCharges = importFeeds(
        emptyDocument(),
        [
          feed('Banco ficticio', current, [row('a', '2026-10-02', -5000, 'Compra'), row('b', '2026-10-02', -5000, 'Compra')])
        ],
        observed,
        accountChoices: {current.id: 'new'}).$1;
    final charges = fin(twoCharges).transactions;
    expect(classify(charges.first, charges.last, fin(twoCharges)).blocked, contains('mismo banco'));
    expect(matchCases(fin(twoCharges)), isEmpty);
  });

  test('A: a movement typed by hand and its bank entry become one, keeping the person\'s words, notes and reserve', () {
    final doc = imported();
    final data = fin(doc);
    final account = data.accounts.firstWhere((a) => a.bankIdentityKey == accountIdentity(current.id)).id;
    doc['reservedFunds'] = [
      {'id': 'r1', 'name': 'Reserva ficticia', 'amountMinor': 100000, 'accountID': account}
    ];
    applyOperation(doc, Operation('insert', {
      'record': {
        'id': '00000000-0000-4000-8000-00000000a600',
        'date': referenceSeconds(DateTime.utc(2026, 10, 2, 9)),
        'typeRaw': 'expense',
        'amountMinor': 60000,
        'descriptionText': 'Pago del máster ficticio',
        'notes': 'Nota ficticia',
        'isReconciled': false,
        'fingerprint': '',
        'duplicateStateRaw': 'possible',
        'sourceAccountID': account,
        'reservedFundID': 'r1',
        'reservedAmountMinor': 60000,
        'bankEntryKey': null,
      }
    }));
    final manual = fin(doc).transactions.firstWhere((t) => t.descriptionText == 'Pago del máster ficticio');
    final other = fin(doc).transactions.firstWhere((t) => t.amountMinor == 60000 && t.id != manual.id && t.sourceAccountId == account);
    expect(classify(manual, other, fin(doc)).kind, MatchKind.duplicate);
    applyOperation(doc, joinOperation(MatchCase(MatchKind.duplicate, manual, other), fin(doc), doc, DateTime.now())!.op);
    final left = fin(doc).transactions.where((t) => t.amountMinor == 60000 && t.sourceAccountId == account).toList();
    expect(left.length, 1);
    expect(left.single.descriptionText, 'Pago del máster ficticio');
    expect(left.single.notes, contains('Nota ficticia'));
    expect(left.single.reservedFundId, 'r1', reason: 'The reserve link stays');
    expect(left.single.reservedAmountMinor, 60000);
    expect(left.single.bankEntryKey, isNotNull, reason: 'The bank reference stays: a download does not bring it back');
    expect(left.single.isReconciled, isTrue);
  });

  test('a regularization of the balance changes the balance only, not income, expenses or budgets', () {
    final doc = imported();
    final data = fin(doc);
    final account = data.accounts.firstWhere((a) => a.bankIdentityKey == accountIdentity(broker.id));
    final before = FinanceCalculator(data);
    final reference = DateTime.utc(2026, 10, 2, 18);
    final computed = before.balance(account, reference);
    (doc['snapshots'] as List).add({
      'id': '00000000-0000-4000-8000-00000000aa01',
      'date': referenceSeconds(reference),
      'balanceMinor': computed - 3921,
      'sourceRaw': 'manual',
      'notes': 'Regularización manual de saldo — diferencia sin conciliar',
      'accountID': account.id,
    });
    final after = FinanceCalculator(fin(doc));
    expect(after.balance(account, reference), computed - 3921);
    expect(after.balance(account, DateTime.utc(2026, 10, 9)), before.balance(account, DateTime.utc(2026, 10, 9)) - 3921, reason: 'Later movements still add');
    final month = DateTime(2026, 10);
    expect(after.monthlySummary(month).incomeMinor, before.monthlySummary(month).incomeMinor);
    expect(after.monthlySummary(month).expenseMinor, before.monthlySummary(month).expenseMinor);
    expect(fin(doc).transactions.length, data.transactions.length, reason: 'No movement is created');
    expect(fin(doc).snapshots.last.notes, contains('Regularización manual'));
  });

  testWidgets('from Don Bigotes, the cases open side by side with their actions, and the preview shows the effect', (tester) async {
    final doc = october();
    final repository = FinanceRepository()
      ..finances = fin(doc)
      ..document = doc;
    tester.view.physicalSize = const Size(430, 2600);
    tester.view.devicePixelRatio = 1;
    addTearDown(tester.view.reset);
    await tester.pumpWidget(MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: ReconcileScreen(repository: repository),
    ));
    await tester.pumpAndSettle();
    expect(find.text('Traspasos entre tus cuentas'), findsOneWidget);
    expect(find.text('Vincular como traspaso'), findsNWidgets(2));
    expect(find.text('Mantener separados'), findsNWidgets(2));
    expect(find.textContaining('Del banco'), findsWidgets, reason: 'The state of each record');
    await tester.tap(find.text('Vincular como traspaso').first);
    await tester.pumpAndSettle();
    expect(find.text('Efecto en los saldos'), findsOneWidget);
    expect(find.text('Resultado: un traspaso'), findsOneWidget);
    expect(find.textContaining('+'), findsWidgets, reason: 'The balance that stops counting twice changes');
  });
}
