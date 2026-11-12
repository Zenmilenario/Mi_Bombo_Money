// Fictitious data only. The app's learning (categories, investment operations, corrections) and the bank
// report (holds and what the bank sent), with the iPhone's formulas and thresholds.
import 'dart:convert';
import 'dart:io';

import 'package:doblon/bank_activity.dart';
import 'package:doblon/brand_catalogue.dart';
import 'package:doblon/banking.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/learning.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

const bank = 'aaaaaaaa-0000-4000-8000-000000000001';
const fund = 'bbbbbbbb-0000-4000-8000-000000000002';
const linked = 'enable:ficticia';

Map<String, dynamic> base({List<Map<String, dynamic>> transactions = const []}) => {
      'formatVersion': 2,
      'accounts': [
        {'id': bank, 'name': 'Banco ficticio', 'typeRaw': 'checking', 'openingDate': 0, 'bankIdentityKey': linked},
        {'id': fund, 'name': 'Cartera ficticia', 'typeRaw': 'investment', 'openingDate': 0},
      ],
      'categories': [
        {'id': 'super', 'name': 'Supermercado', 'kindRaw': 'expense'},
        {'id': 'rest', 'name': 'Restaurantes', 'kindRaw': 'expense'},
        {'id': 'trans', 'name': 'Transporte', 'kindRaw': 'expense'},
        {'id': 'nomina', 'name': 'Nómina', 'kindRaw': 'income'},
        {'id': 'traspaso', 'name': 'Traspaso', 'kindRaw': 'transfer'},
      ],
      'transactions': transactions,
      'categoryRules': <dynamic>[],
    };

Map<String, dynamic> movement(String id, DateTime date, String text, int amount,
        {String type = 'expense', String? category, String? destination, bool fromBank = true, DateTime? created}) =>
    {
      'id': id,
      'date': referenceSeconds(date),
      'typeRaw': type,
      'amountMinor': amount,
      'descriptionText': text,
      'sourceAccountID': bank,
      'destinationAccountID': destination,
      'categoryID': category,
      'duplicateStateRaw': 'none',
      'fingerprint': 'f-$id',
      'bankEntryKey': fromBank ? 'enable-entry:ficticio:$id' : null,
      'createdAt': referenceSeconds(created ?? date),
      'updatedAt': referenceSeconds(created ?? date),
    };

Transaction tx(Finances data, String id) => data.transactions.firstWhere((t) => t.id == id);

void main() {
  // Training runs in this isolate during the tests.
  setUp(() => runTraining = <T>(T Function() work) async => work());

  group('categories', () {
    test('the model learns the starter vocabulary and only answers when it is clear', () {
      final model = CategoryModel.train([
        for (final (name, texts) in CategoryModel.syntheticExamples)
          for (final text in texts) CategoryExample(text, name, 1)
      ])!;
      final all = {for (final (name, _) in CategoryModel.syntheticExamples) name};
      expect(model.predict('Supermercado La Cesta', all)?.categoryId, 'Supermercado');
      expect(model.predict('Farmacia Plaza', all)?.categoryId, 'Farmacia');
      expect(model.predict('xq', all), isNull, reason: 'Too few known features');
      expect(CategoryModel.tokens('Cafetería Ñandú, 2 cafés'), ['cafeteria', 'nandu', 'cafes']);
    });

    test('earlier movements and confirmed choices teach; confirmed ones weigh more', () async {
      final since = DateTime(2026, 6, 1);
      final data = Finances.fromDocument(base(transactions: [
        movement('m1', DateTime(2026, 3, 2), 'Mercado del barrio Lunes', 2300, category: 'super'),
        movement('m2', DateTime(2026, 3, 9), 'Mercado del barrio Martes', 2100, category: 'super'),
        movement('m3', DateTime(2026, 7, 3), 'Bocadillos Pepe', 900, category: 'rest', created: DateTime(2026, 7, 3)),
      ]));
      final learning = Learning(since: since);
      var examples = learning.categoryExamples(TransactionType.expense, data, data.transactions);
      expect(examples.where((e) => e.text.startsWith('Mercado del barrio')).map((e) => e.weight), [0.55, 0.55]);
      expect(examples.any((e) => e.text == 'Bocadillos Pepe'), isFalse, reason: 'Changed after the learning started and not confirmed');
      await learning.confirmCategories([tx(data, 'm3')], data);
      examples = learning.categoryExamples(TransactionType.expense, data, data.transactions);
      expect(examples.firstWhere((e) => e.text == 'Bocadillos Pepe').weight, 5);
      expect(examples.any((e) => e.categoryId == 'super' && e.weight == 1), isTrue, reason: 'Starter examples of a category that exists');
      expect(await learning.suggestCategory('Supermercado La Cesta compra', TransactionType.expense, data), 'super');
      expect(await learning.suggestCategory('Nómina', TransactionType.transfer, data), isNull);
    });

    test('what was taught survives closing the app', () async {
      final directory = await Directory.systemTemp.createTemp('doblon-learning');
      addTearDown(() => directory.delete(recursive: true));
      final data = Finances.fromDocument(base(transactions: [movement('m1', DateTime(2026, 3, 2), 'Compra ficticia', 500, category: 'super')]));
      final first = await Learning.open(directory, 'usuario-ficticio');
      await first.confirmCategories([tx(data, 'm1')], data);
      await first.confirmKind(OperationKind.ordinary, tx(data, 'm1'), data);
      await first.setAutomationEnabled(false);
      final again = await Learning.open(directory, 'usuario-ficticio');
      expect(again.confirmations.keys, ['m1']);
      expect(again.identifiedOperations, 1);
      expect(again.automationEnabled, isFalse);
      expect(again.since, first.since);
    });
  });

  group('investment operations', () {
    test('the concept is enough for a proposal; amount and date alone are not', () {
      final model = OperationModel.train(const []);
      OperationInput input(String text) =>
          OperationInput(text: text, amountMinor: 1500, isCredit: false, day: 4, weekday: 3, month: '2026-5', accountKey: 'cuenta');
      expect(model.predict(input('Saveback recompensa'))?.kind, OperationKind.saveback);
      expect(model.predict(input('Round up inversión'))?.kind, OperationKind.roundUp);
      expect(model.predict(input('Supermercado compra tarjeta')), isNull, reason: 'An ordinary movement is not proposed');
      expect(model.predict(input('Movimiento bancario')), isNull, reason: 'Without a concept, confirmed examples of the account are needed');
    });

    test('only bank movements of current accounts are reviewed, and a confirmation is kept', () async {
      final data = Finances.fromDocument(base(transactions: [
        movement('b1', DateTime(2026, 5, 4), 'Saveback recompensa', 150, type: 'income'),
        movement('h1', DateTime(2026, 5, 4), 'Saveback recompensa', 150, type: 'income', fromBank: false),
      ]));
      final learning = Learning();
      expect(learning.supports(tx(data, 'h1'), data), isFalse, reason: 'Recorded by hand');
      expect((await learning.review(tx(data, 'b1'), data)).prediction?.kind, OperationKind.saveback);
      await learning.confirmKind(OperationKind.saveback, tx(data, 'b1'), data);
      expect((await learning.review(tx(data, 'b1'), data)).confirmed, OperationKind.saveback);
      expect(learning.specializedIds(data), {'b1'}, reason: 'Benefits do not teach categories');
      await learning.saveTerms(CardTerms(1, 2, DateTime(2026, 1, 1)), tx(data, 'b1'), data);
      expect(learning.terms(tx(data, 'b1'))?.roundUpMultiplier, 2);
      expect(() => learning.saveTerms(CardTerms(0, 2, DateTime(2026, 1, 1)), tx(data, 'b1'), data), throwsStateError);
    });
  });

  group('corrections', () {
    OperationInput input(String text, int month, int amount) =>
        OperationInput(text: text, amountMinor: amount, isCredit: false, day: 5, weekday: 2, month: '2026-$month', accountKey: 'cuenta');
    const invest = CorrectionAction('transfer', fund, null);
    const groceries = CorrectionAction('expense', null, 'super');

    test('an action is repeated only after it was right on later months', () {
      final examples = [
        for (var month = 1; month <= 4; month++) ...[
          CorrectionExample(input('Plan inversion mensual', month, 10000), invest),
          CorrectionExample(input('Plan inversion mensual', month, 10100), invest),
          CorrectionExample(input('Compra mercado barrio', month, 4000), groceries),
          CorrectionExample(input('Compra mercado barrio', month, 4100), groceries),
        ]
      ];
      final model = CorrectionModel.train(examples)!;
      final decision = model.automaticDecision(input('Plan inversion mensual', 5, 10000));
      expect(decision?.action, invest);
      expect(decision!.validatedPredictions, greaterThanOrEqualTo(3));
      expect(model.automaticDecision(input('Plan inversion mensual', 2, 10000)), isNull, reason: 'Older than the newest example');
      expect(CorrectionModel.train(examples.take(8).toList()), isNull, reason: 'Too few examples');
      final early = CorrectionModel.train(examples.take(12).toList())!;
      expect(early.automaticDecision(input('Plan inversion mensual', 5, 10000)), isNull, reason: 'Only two months were checked');
    });

    test('corrections taught by hand are repeated on new bank movements and can be undone', () async {
      final rows = <Map<String, dynamic>>[];
      for (var month = 1; month <= 4; month++) {
        rows.add(movement('i$month', DateTime.utc(2026, month, 5, 12), 'Plan inversion mensual', 10000 + month));
        rows.add(movement('g$month', DateTime.utc(2026, month, 5, 12), 'Compra mercado barrio', 4000 + month));
        rows.add(movement('j$month', DateTime.utc(2026, month, 6, 12), 'Plan inversion mensual', 10050 + month));
        rows.add(movement('h$month', DateTime.utc(2026, month, 6, 12), 'Compra mercado barrio', 4050 + month));
      }
      var document = base(transactions: rows);
      var data = Finances.fromDocument(document);
      final learning = Learning();
      // The person corrects each one: the investment as a transfer to the portfolio, the rest as groceries.
      for (final t in [...data.transactions]) {
        final before = learning.captureEdit(t, data);
        final change = t.descriptionText.startsWith('Plan')
            ? {'typeRaw': 'transfer', 'destinationAccountID': fund}
            : {'categoryID': 'super'};
        applyOperation(document, Operation('patch', {'id': t.id, 'fields': change}));
        data = Finances.fromDocument(document);
        expect(await learning.rememberEdit(before, tx(data, t.id), data), isTrue);
      }
      expect(learning.savedCorrections, 16);
      // A new bank movement arrives, after the learning was enabled.
      final now = DateTime.now();
      final fresh = movement('nuevo', DateTime.utc(2026, 5, 5, 12), 'Plan inversion mensual', 10007, created: now.add(const Duration(seconds: 1)));
      applyOperation(document, Operation('insert', {'record': fresh}));
      data = Finances.fromDocument(document);
      final op = await learning.learnedCorrections(data, now.add(const Duration(days: 400)));
      expect(op, isNotNull);
      applyOperation(document, op!);
      data = Finances.fromDocument(document);
      expect(tx(data, 'nuevo').type, TransactionType.transfer);
      expect(tx(data, 'nuevo').destinationAccountId, fund);
      expect(learning.automationStatus(tx(data, 'nuevo'), data).automaticallyApplied, isTrue);
      expect(await learning.learnedCorrections(data, now), isNull, reason: 'Applied once');
      final undo = await learning.undoAutomatic(tx(data, 'nuevo'), data, now);
      applyOperation(document, undo!);
      data = Finances.fromDocument(document);
      expect(tx(data, 'nuevo').type, TransactionType.expense);
      expect(tx(data, 'nuevo').destinationAccountId, isNull);
      expect(tx(data, 'nuevo').fingerprint, 'f-nuevo');
      expect(learning.savedCorrections, 17, reason: 'Undoing teaches the model');
    });

    test('nothing is applied while the automation is off', () async {
      final learning = Learning()..enabledAt = DateTime(2020);
      await learning.setAutomationEnabled(false);
      final data = Finances.fromDocument(base(transactions: [movement('x', DateTime(2026, 5, 5), 'Plan inversion mensual', 100)]));
      expect(await learning.learnedCorrections(data, DateTime.now()), isNull);
    });
  });

  group('bank report', () {
    final observed = DateTime(2026, 11, 10, 9);
    BankActivity activity({List<PendingMovement>? pending}) => BankActivity.fromFeed(
          accountCurrency: 'EUR',
          balances: [
            (amountMinor: 120000, currency: 'EUR', type: 'CLBD'),
            (amountMinor: 115000, currency: 'EUR', type: 'ITAV'),
            (amountMinor: 999, currency: 'USD', type: 'ITBD'),
          ],
          movements: [
            for (var i = 1; i <= 10; i++)
              BookedMovement(id: 'b$i', bookingDate: '2026-11-${i.toString().padLeft(2, '0')}', signedAmountMinor: -100 * i, currency: 'EUR', description: 'Compra $i'),
          ],
          pending: pending,
          ignored: {'CNCL': 2},
          observedAt: observed,
        );

    test('balances, holds and what the bank sent', () {
      final a = activity(pending: const [
        PendingMovement(id: 'p1', date: '2026-11-09', signedAmountMinor: -2500, currency: 'EUR', description: 'Gasolinera ficticia', status: 'HOLD'),
        PendingMovement(id: 'b3', date: '2026-11-03', signedAmountMinor: -300, currency: 'EUR', description: 'Ya contabilizado', status: 'PDNG'),
        PendingMovement(date: '2026-11-08', signedAmountMinor: 4000, currency: 'EUR', description: 'Abono pendiente', status: 'PDNG'),
        PendingMovement(id: 'p4', signedAmountMinor: -100, currency: 'USD', description: 'Otra divisa', status: 'HOLD'),
        PendingMovement(id: 'p5', signedAmountMinor: -100, currency: 'EUR', description: 'Cancelado', status: 'CNCL'),
      ]);
      expect(a.bookedBalance, 120000, reason: 'CLBD when there is no ITBD in the account currency');
      expect(a.availableBalance, 115000);
      expect(a.pendingMovements!.map((m) => m.description), ['Gasolinera ficticia', 'Abono pendiente'], reason: 'Newest first, without booked or foreign ones');
      expect(a.pendingTotal, 1500);
      expect(a.recentMovements.length, 8);
      expect(a.recentMovements.first.bookingDate, '2026-11-10');
      expect(a.receivedCount, 10);
      expect(bankStatusName('CNCL'), 'cancelados');
      final copy = BankActivity.fromJson(a.toJson());
      expect(copy.pendingMovements!.length, 2);
      expect(copy.ignoredStatuses, {'CNCL': 2});
      expect(activity().pendingMovements, isNull, reason: 'Not reported is not the same as none');
    });

    test('a hold already recorded as a payment waiting for the bank is not counted twice', () {
      final document = base(transactions: [
        {
          ...movement('ap', DateTime(2026, 11, 8, 13), 'Gasolinera', 2500, fromBank: false),
          'externalID': 'applepay:ficticio',
        }
      ]);
      final data = Finances.fromDocument(document);
      final a = activity(pending: const [
        PendingMovement(id: 'p1', date: '2026-11-09', signedAmountMinor: -2500, currency: 'EUR', description: 'Gasolinera ficticia', status: 'HOLD'),
        PendingMovement(id: 'p2', date: '2026-11-09', signedAmountMinor: -700, currency: 'EUR', description: 'Cafetería ficticia', status: 'HOLD'),
      ]);
      final holds = bankHolds(data, {linked: a});
      expect(holds.map((h) => h.movement.description), ['Cafetería ficticia']);
      expect(heldMinor(a, data.account(bank)!, data), -700);
      expect(uncoveredHolds(a.pendingMovements!, [(amountMinor: 2500, date: DateTime(2026, 10, 20))]).length, 2, reason: 'Paid too long before');
    });

    test('reports older than a week are not shown again', () async {
      final directory = await Directory.systemTemp.createTemp('doblon-activity');
      addTearDown(() => directory.delete(recursive: true));
      final store = BankActivityStore(directory);
      await store.save('usuario', {linked: activity(pending: const [])});
      expect((await store.load('usuario', now: observed.add(const Duration(days: 2)))).keys, [linked]);
      expect(await store.load('usuario', now: observed.add(const Duration(days: 8))), isEmpty);
      await store.clear('usuario');
      expect(await store.load('usuario', now: observed), isEmpty);
    });
  });
  group('brand catalogue (OpenStreetMap)', () {
    const names = ['Supermercado', 'Restaurantes', 'Transporte', 'Coche', 'Farmacia', 'Salud', 'Ropa', 'Compras', 'Mascotas', 'Ocio', 'Viajes',
      'Internet y móvil', 'Servicios del hogar', 'Suscripciones', 'Impuestos y comisiones', 'Vivienda', 'Seguros', 'Educación'];
    final data = Finances.fromDocument({
      'accounts': [],
      'categories': [for (final n in names) {'id': n, 'name': n, 'kindRaw': 'expense'}],
      'transactions': [],
    });

    test('the same lookup as the iPhone', () {
      expect(brandCatalogue.keys.toSet().difference(names.toSet()), isEmpty, reason: 'Every brand goes to a starter category');
      final cases = (jsonDecode(File('../Tests/Fixtures/brand_lookup_cases.json').readAsStringSync())['lookup'] as List).cast<Map<String, dynamic>>();
      for (final c in cases) {
        expect(brandCategory(c['text'] as String), c['category'], reason: '${c['text']}');
      }
    });

    test('a brand fills in only where the model has nothing to propose', () async {
      final learning = Learning();
      final (model, _) = await learning.categoryModels(data);
      expect(model!.predict('ZARA ESPANA SA', names.toSet()), isNull, reason: 'The model alone does not know it');
      expect(await learning.suggestCategory('ZARA ESPANA SA', TransactionType.expense, data), 'Ropa');
      expect(await learning.suggestCategory('Farmacia Plaza medicamentos', TransactionType.expense, data), 'Farmacia', reason: 'Unchanged');
      expect(await learning.suggestCategory('BIZUM DE MERCADONA COMPAÑERO', TransactionType.expense, data), isNull);
      expect(await learning.suggestCategory('DEVOLUCION ZARA', TransactionType.income, data), isNull, reason: 'Only for expenses');
      // Every proposal the model makes on its own stays exactly the same.
      for (final c in (jsonDecode(File('../Tests/Fixtures/brand_lookup_cases.json').readAsStringSync())['lookup'] as List)) {
        final text = c['text'] as String;
        final own = model.predict(text, names.toSet())?.categoryId;
        if (own != null) expect(await learning.suggestCategory(text, TransactionType.expense, data), own, reason: text);
      }
    });
  });
}
