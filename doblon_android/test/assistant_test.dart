// Fictitious data only. Don Bigotes' assistant, phase 1 (25 November 2026): a bank of Spanish sentences with the
// intent each must give, and the preparation against the person's data: it asks only for what is missing, never
// guesses an account among several, validates with the form's rules, and applies a prepared operation once.
import 'package:doblon/assistant.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 25, 18); // a Wednesday

Finances data({List<Transaction> transactions = const [], List<ReservedFund> funds = const []}) => Finances(
      accounts: [
        Account(id: 'nomina', name: 'Bankinter nómina', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 150000),
        Account(id: 'credito', name: 'Bankinter crédito', type: AccountType.creditCard, openingDate: DateTime(2026)),
        Account(id: 'efectivo', name: 'Efectivo', type: AccountType.cash, openingDate: DateTime(2026), openingBalanceMinor: 5000),
        Account(id: 'ahorro', name: 'Ahorro Naranja', type: AccountType.savings, openingDate: DateTime(2026), openingBalanceMinor: 300000),
      ],
      cards: [PaymentCard(id: 'visa', name: 'Visa Oro', type: CardType.credit, lastFour: '4321', linkedAccountId: 'credito')],
      categories: [
        Category(id: 'rest', name: 'Restaurantes', kind: CategoryKind.expense),
        Category(id: 'compras', name: 'Compras', kind: CategoryKind.expense),
        Category(id: 'nomina-cat', name: 'Nómina', kind: CategoryKind.income),
      ],
      budgets: [MonthlyBudget(id: 'b', monthStart: DateTime(2026, 11), limitMinor: 15000, categoryId: 'rest')],
      transactions: [...transactions]..sort((a, b) => b.date.compareTo(a.date)),
      reservedFunds: funds,
    );

AssistantSession session() {
  var n = 0;
  return AssistantSession(newId: () => 'nuevo-${++n}', propose: (text, type) async => text == 'Cena' ? 'rest' : null);
}

void main() {
  group('the bank of sentences: each gives its intent (rules on the device)', () {
    final cases = <(String, IntentKind, int?)>[
      ('He gastado 24 € cenando con la tarjeta de Bankinter', IntentKind.expense, 2400),
      ('he gastado 24€ en la cena', IntentKind.expense, 2400),
      ('Pagué 12,50 en el super', IntentKind.expense, 1250),
      ('Gasté 3.5 euros en un café', IntentKind.expense, 350),
      ('Me ha costado 1.234,56 € el sofá', IntentKind.expense, 123456),
      ('compré ropa por 59,90', IntentKind.expense, 5990),
      ('Ayer pagué 40 de gasolina', IntentKind.expense, 4000),
      ('Taxi 18 euros', IntentKind.expense, 1800),
      ('Cobré la nómina, 1.850 €', IntentKind.income, 185000),
      ('Me han hecho un bizum de 15 euros', IntentKind.income, 1500),
      ('Ingreso de 200 € en efectivo', IntentKind.income, 20000),
      ('He recibido 30 € de devolución', IntentKind.income, 3000),
      ('Reserva 200 € para vacaciones', IntentKind.reserve, 20000),
      ('Aparta 50 euros para el regalo de Ana', IntentKind.reserve, 5000),
      ('Guarda 1.000 € para el seguro del coche', IntentKind.reserve, 100000),
      ('Tengo que pagar 4.378 € repartidos en 12 meses', IntentKind.installments, 437800),
      ('Compra de 600 € a plazos', IntentKind.installments, 60000),
      ('¿Cómo quedaría mi disponible si gasto 600 €?', IntentKind.simulation, 60000),
      ('¿Qué pasaría si pago 300 €?', IntentKind.simulation, 30000),
      ('Muéstrame las compras de este mes', IntentKind.listMovements, null),
      ('Enséñame los gastos de la semana', IntentKind.listMovements, null),
      ('Quiero ver mis ingresos del mes pasado', IntentKind.listMovements, null),
      ('¿Cuánto he gastado este mes?', IntentKind.summary, null),
      ('¿Cuánto llevo gastado en restaurantes?', IntentKind.summary, null),
      ('Resumen del mes pasado', IntentKind.summary, null),
      ('¿Cómo voy este mes?', IntentKind.summary, null),
      ('Traspasa 100 € a la cuenta de ahorro', IntentKind.transfer, 10000),
      ('Transferencia de 50 € a Naranja', IntentKind.transfer, 5000),
      ('24 €', IntentKind.unknown, 2400),
      ('Hola Don Bigotes', IntentKind.unknown, null),
    ];
    for (final (text, kind, amount) in cases) {
      test(text, () {
        final intent = interpret(text, now);
        expect(intent.kind, kind);
        expect(intent.amountMinor, amount);
      });
    }
  });

  test('amounts, dates and periods as written in Spain', () {
    expect(parseAmount('4.378'), 437800, reason: 'A dot before three digits separates thousands');
    expect(parseAmount('4.378,25 €'), 437825);
    expect(parseAmount('el 3 de noviembre pagué 20'), 2000, reason: 'The day is not the amount');
    expect(parseAmount('en 12 meses'), isNull);
    expect(parseAmount('el 5/11 gasté 9,99'), 999);
    expect(parseDate('ayer', now), DateTime(2026, 11, 24, 12));
    expect(parseDate('anteayer', now), DateTime(2026, 11, 23, 12));
    expect(parseDate('el lunes', now), DateTime(2026, 11, 23, 12));
    expect(parseDate('el miércoles', now), DateTime(2026, 11, 18, 12), reason: 'The one before, never today or the future');
    expect(parseDate('el 3 de noviembre', now), DateTime(2026, 11, 3, 12));
    expect(parseDate('el 30 de diciembre', now), DateTime(2025, 12, 30, 12), reason: 'Not in the future: last year');
    expect(parseDate('el 28', now), DateTime(2026, 10, 28, 12));
    expect(parseDate('5/11', now), DateTime(2026, 11, 5, 12));
    expect(parseDate('gasté 24 €', now), isNull);
    expect(interpret('Muéstrame las compras de este mes', now).period, QueryPeriod.thisMonth);
    expect(interpret('ingresos del mes pasado', now).period, QueryPeriod.lastMonth);
    expect(interpret('Reserva 200 € para las vacaciones de verano', now).purpose, 'Vacaciones de verano');
    expect(interpret('He gastado 24 € cenando', now).concept, 'Cena');
  });

  test('the example: an account among two is asked, then a preview with its effect, applied once', () async {
    final s = session();
    final calc = FinanceCalculator(data());
    var reply = await s.say('He gastado 24 € cenando con la de Bankinter', calc, now);
    expect(reply, isA<AssistantQuestion>());
    final question = reply as AssistantQuestion;
    expect(question.field, PendingField.account);
    expect(question.options.map((o) => o.$2), unorderedEquals(['nomina', 'credito']), reason: 'Never guessed between the two');
    reply = await s.choose('credito', calc, now);
    final preview = reply as AssistantPreview;
    expect(preview.title, contains('24,00'));
    expect(preview.lines.map((l) => l.$2), containsAll(['Cena', 'Bankinter crédito']));
    expect(preview.lines.firstWhere((l) => l.$1 == 'Categoría').$2, contains('Restaurantes'));
    expect(preview.effects.any((e) => e.startsWith('Presupuesto de Restaurantes')), isTrue);
    expect(preview.draft!.validate(calc.data), isNull, reason: 'The form\'s own rules');
    // Confirmed: one insert with the preview's id; a second tap gives nothing.
    final op = s.confirm(preview, calc.data)!;
    expect(op.kind, 'insert');
    expect(op.data['record']['id'], preview.id);
    expect(op.data['record']['amountMinor'], 2400);
    expect(op.data['record']['sourceAccountID'], 'credito');
    expect(s.confirm(preview, calc.data), isNull);
    final doc = <String, dynamic>{'transactions': <dynamic>[]};
    applyOperation(doc, op);
    expect((doc['transactions'] as List).length, 1);
    expect(s.undo(preview, Finances.fromDocument({...doc, 'accounts': const []}))!.kind, 'delete');
  });

  test('a card named by its name or its last digits is its account; an answer in words fills the question', () async {
    final s = session();
    final calc = FinanceCalculator(data());
    final byCard = await s.say('Pagué 9,99 con la Visa Oro', calc, now) as AssistantPreview;
    expect(byCard.lines.firstWhere((l) => l.$1 == 'Cuenta').$2, 'Bankinter crédito');
    s.cancel();
    expect(await s.say('Gasté 10 € con la 4321', calc, now), isA<AssistantPreview>());
    s.cancel();
    expect(await s.say('He gastado 30 €', calc, now), isA<AssistantQuestion>());
    final answered = await s.say('con la de efectivo', calc, now) as AssistantPreview;
    expect(answered.lines.firstWhere((l) => l.$1 == 'Cuenta').$2, 'Efectivo');
    // An amount alone: asked whether it is an expense or an income.
    s.cancel();
    final kind = await s.say('35 €', calc, now) as AssistantQuestion;
    expect(kind.field, PendingField.kind);
  });

  test('missing amount or purpose are asked; a reserve shows the free money and nothing moves', () async {
    final s = session();
    final calc = FinanceCalculator(data());
    expect((await s.say('Reserva dinero para vacaciones', calc, now) as AssistantQuestion).field, PendingField.amount);
    final where = await s.say('200 €', calc, now) as AssistantQuestion;
    expect(where.field, PendingField.account);
    expect(where.options.map((o) => o.$2), isNot(contains('credito')), reason: 'Not in a credit card');
    final preview = await s.choose('ahorro', calc, now) as AssistantPreview;
    expect(preview.reserve!.name, 'Vacaciones');
    expect(preview.effects.first, contains('3.000,00'));
    final op = s.confirm(preview, calc.data)!;
    expect(op.kind, 'upsert');
    expect(op.data['entity'], 'reservedFunds');
    expect(op.data['record']['accountID'], 'ahorro');
    s.cancel();
    expect((await s.say('Reserva 50 € en Naranja', calc, now) as AssistantQuestion).field, PendingField.purpose);
  });

  test('cancel leaves nothing; a repeated request is warned as a possible duplicate', () async {
    final s = session();
    final existing = Transaction(
        id: 'previo', date: now, type: TransactionType.expense, amountMinor: 2400, descriptionText: 'Cena', sourceAccountId: 'efectivo');
    final calc = FinanceCalculator(data(transactions: [existing]));
    final preview = await s.say('He gastado 24 € cenando en efectivo', calc, now) as AssistantPreview;
    expect(preview.warnings.single, contains('igual ese día'));
    s.cancel();
    expect(await s.choose('efectivo', calc, now), isA<AssistantNotUnderstood>(), reason: 'Nothing pending after cancelling');
  });

  test('queries run on the device: purchases of the month, a summary, a category', () async {
    final s = session();
    final rows = [
      Transaction(id: 'a', date: DateTime(2026, 11, 3), type: TransactionType.expense, amountMinor: 3000, descriptionText: 'Tienda', sourceAccountId: 'nomina', categoryId: 'compras'),
      Transaction(id: 'b', date: DateTime(2026, 11, 20), type: TransactionType.expense, amountMinor: 1500, descriptionText: 'Tienda 2', sourceAccountId: 'nomina', categoryId: 'compras'),
      Transaction(id: 'c', date: DateTime(2026, 10, 20), type: TransactionType.expense, amountMinor: 900, descriptionText: 'Tienda vieja', sourceAccountId: 'nomina', categoryId: 'compras'),
      Transaction(id: 'd', date: DateTime(2026, 11, 21), type: TransactionType.expense, amountMinor: 2000, descriptionText: 'Cena', sourceAccountId: 'nomina', categoryId: 'rest'),
      Transaction(id: 'e', date: DateTime(2026, 11, 1), type: TransactionType.income, amountMinor: 185000, descriptionText: 'Nómina', sourceAccountId: 'nomina', categoryId: 'nomina-cat'),
    ];
    final calc = FinanceCalculator(data(transactions: rows));
    final list = await s.say('Muéstrame las compras de este mes', calc, now) as AssistantResult;
    expect(list.transactions.map((t) => t.id), ['b', 'a']);
    expect(list.totalMinor, 4500);
    final summary = await s.say('¿Cuánto he gastado este mes?', calc, now) as AssistantResult;
    expect(summary.lines.first, contains('1.850,00'));
    expect(summary.lines[1], contains('65,00'));
    final category = await s.say('¿Cuánto llevo gastado en restaurantes?', calc, now) as AssistantResult;
    expect(category.lines.single, contains('20,00'));
    final last = await s.say('Quiero ver mis ingresos del mes pasado', calc, now) as AssistantResult;
    expect(last.transactions, isEmpty);
  });

  test('plans, simulations and transfers point to their screens; nothing moves money at a bank', () async {
    final s = session();
    final calc = FinanceCalculator(data());
    expect((await s.say('Tengo que pagar 4.378 € repartidos en 12 meses', calc, now) as AssistantPointer).kind, IntentKind.installments);
    expect((await s.say('¿Cómo quedaría mi disponible si gasto 600 €?', calc, now) as AssistantPointer).kind, IntentKind.simulation);
    final transfer = await s.say('Traspasa 100 € a Naranja', calc, now) as AssistantPointer;
    expect(transfer.text, contains('no mueve dinero en el banco'));
    expect(await s.say('Hola', calc, now), isA<AssistantNotUnderstood>());
  });
}
