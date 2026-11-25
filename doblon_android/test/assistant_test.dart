// Fictitious data only. Don Bigotes' assistant (25 November 2026, after the first tests on the iPhone): whole
// conversations (a summary and «¿Y qué he comprado?», a fuel station and its category, corrections, a plan of
// 4.378 € in 12 months against an instalment already paid, changes of subject, cancelling and confirming twice),
// variations and misspellings, and the earlier bank of sentences so nothing that worked gets worse.
import 'package:doblon/assistant.dart';
import 'package:doblon/edits.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/installments.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 25, 18); // a Wednesday

final sofa = InstallmentPlan(
    id: 'sofa', name: 'Sofá', kind: InstallmentKind.purchase, totalMinor: 120000, schedule: buildSchedule(120000, 3, DateTime(2026, 11, 5, 12))!, accountId: 'nomina');

Finances data({List<Transaction> transactions = const [], bool comprasCategory = true, List<InstallmentPlan> plans = const []}) => Finances(
      accounts: [
        Account(id: 'nomina', name: 'Bankinter nómina', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 150000),
        Account(id: 'credito', name: 'Bankinter crédito', type: AccountType.creditCard, openingDate: DateTime(2026)),
        Account(id: 'efectivo', name: 'Efectivo', type: AccountType.cash, openingDate: DateTime(2026), openingBalanceMinor: 5000),
        Account(id: 'ahorro', name: 'Ahorro Naranja', type: AccountType.savings, openingDate: DateTime(2026), openingBalanceMinor: 300000),
      ],
      cards: [PaymentCard(id: 'visa', name: 'Visa Oro', type: CardType.credit, lastFour: '4321', linkedAccountId: 'credito')],
      categories: [
        Category(id: 'rest', name: 'Restaurantes', kind: CategoryKind.expense),
        if (comprasCategory) Category(id: 'compras', name: 'Compras', kind: CategoryKind.expense),
        Category(id: 'fuel', name: 'Combustible', kind: CategoryKind.expense),
        Category(id: 'super', name: 'Supermercado', kind: CategoryKind.expense),
        Category(id: 'ocio', name: 'Ocio', kind: CategoryKind.expense),
        Category(id: 'nomina-cat', name: 'Nómina', kind: CategoryKind.income),
      ],
      budgets: [MonthlyBudget(id: 'b', monthStart: DateTime(2026, 11), limitMinor: 15000, categoryId: 'rest')],
      transactions: [...transactions]..sort((a, b) => b.date.compareTo(a.date)),
      installmentPlans: plans,
    );

final month = [
  Transaction(id: 'a', date: DateTime(2026, 11, 3), type: TransactionType.expense, amountMinor: 3000, descriptionText: 'Tienda', sourceAccountId: 'nomina', categoryId: 'compras'),
  Transaction(id: 'b', date: DateTime(2026, 11, 20), type: TransactionType.expense, amountMinor: 1500, descriptionText: 'Cena', sourceAccountId: 'nomina', categoryId: 'rest'),
  Transaction(id: 'c', date: DateTime(2026, 10, 20), type: TransactionType.expense, amountMinor: 900, descriptionText: 'Octubre', sourceAccountId: 'nomina', categoryId: 'compras'),
  Transaction(id: 'e', date: DateTime(2026, 11, 1), type: TransactionType.income, amountMinor: 185000, descriptionText: 'Nómina', sourceAccountId: 'nomina', categoryId: 'nomina-cat'),
];

AssistantSession session({Map<String, String> learnt = const {}}) {
  var n = 0;
  return AssistantSession(newId: () => 'nuevo-${++n}', propose: (text, type) async => learnt[text] == null ? null : (learnt[text]!, 'model'));
}

String line(AssistantPreview p, String label) => p.lines.firstWhere((l) => l.$1 == label).$2;

void main() {
  group('1. consulting is not recording; context is kept', () {
    test('summary → «¿Y qué he comprado este mes?» → «No, qué cosas»', () async {
      final s = session();
      final calc = FinanceCalculator(data(transactions: month, comprasCategory: false));
      final summary = await s.say('¿Cuánto he gastado este mes?', calc, now) as AssistantResult;
      expect(summary.title, 'Resumen de este mes');
      final bought = await s.say('¿Y qué he comprado este mes?', calc, now);
      expect(bought, isA<AssistantResult>(), reason: 'A question about existing movements never starts recording one');
      expect((bought as AssistantResult).transactions.map((t) => t.id), ['b', 'a']);
      expect(s.hasDraft, isFalse);
      final things = await s.say('No, qué cosas', calc, now) as AssistantResult;
      expect(things.title, 'Gastos este mes', reason: 'The period is kept');
      expect(things.transactions.length, 2);
    });

    test('«compras» with a category of that name: asked once, then remembered', () async {
      final s = session();
      final calc = FinanceCalculator(data(transactions: month));
      final q = await s.say('¿Qué he comprado este mes?', calc, now) as AssistantQuestion;
      expect(q.options.map((o) => o.$2), ['scope:all', 'scope:category']);
      final all = await s.choose('scope:all', calc, now) as AssistantResult;
      expect(all.transactions.length, 2);
      final again = await s.say('¿y el mes pasado?', calc, now) as AssistantResult;
      expect(again.title, 'Gastos el mes pasado', reason: 'A continuation keeps the scope and changes the period');
      expect(again.transactions.single.id, 'c');
      final s2 = session();
      await s2.say('muéstrame las compras de este mes', calc, now);
      final only = await s2.say('solo la categoría', calc, now) as AssistantResult;
      expect(only.transactions.single.id, 'a');
    });

    test('a question while a draft waits for an answer is a query; the draft is set aside explicitly and can be resumed', () async {
      final s = session();
      final calc = FinanceCalculator(data(transactions: month, comprasCategory: false));
      expect((await s.say('He gastado algo en la cena', calc, now) as AssistantQuestion).field, PendingField.amount);
      final query = await s.say('¿Y qué he comprado este mes?', calc, now) as AssistantResult;
      expect(query.note, contains('Dejo aparte el gasto'));
      expect(query.transactions.length, 2);
      expect(s.hasParked, isTrue);
      final back = await s.say('retómalo', calc, now) as AssistantQuestion;
      expect(back.field, PendingField.amount);
      final preview = await s.say('24,50', calc, now);
      expect(preview, isA<AssistantQuestion>(), reason: 'Next: the account');
    });

    test('other phrasings of the same questions', () async {
      final calc = FinanceCalculator(data(transactions: month, comprasCategory: false));
      for (final text in [
        'qué he comprado este mes',
        'en qué me he gastado el dinero este mes',
        'dime los gastos de este mes',
        'enséñame lo que he gastado este mes',
        'he comprado cosas este mes?',
        'q he gastado este mes',
        'muestrame las conpras del mes',
      ]) {
        final reply = await session().say(text, calc, now);
        expect(reply, isA<AssistantResult>(), reason: text);
        expect((reply as AssistantResult).transactions.length, 2, reason: text);
      }
      for (final text in ['cuanto e gastado este mes', '¿Cómo voy este mes?', 'resumen del mes', 'cuánto llevo gastado']) {
        expect((await session().say(text, calc, now) as AssistantResult).title, 'Resumen de este mes', reason: text);
      }
      expect((await session().say('¿y los ingresos?', calc, now) as AssistantResult).transactions.single.id, 'e');
    });
  });

  group('2. payments in instalments', () {
    test('4.378 € in 12 months: a plan with its calendar, never a payment today', () async {
      final s = session();
      final calc = FinanceCalculator(data());
      var reply = await s.say('Tengo que pagar 4.378 € repartidos en 12 meses', calc, now);
      expect((reply as AssistantQuestion).field, PendingField.planKind);
      reply = await s.choose('purchase', calc, now);
      expect((reply as AssistantQuestion).field, PendingField.planName);
      reply = await s.say('Sofá nuevo', calc, now);
      expect((reply as AssistantQuestion).field, PendingField.dueDate, reason: 'The first due date is never assumed');
      reply = await s.say('el 5 de diciembre', calc, now);
      expect((reply as AssistantQuestion).field, PendingField.account);
      reply = await s.choose('nomina', calc, now);
      expect((reply as AssistantQuestion).field, PendingField.recorded);
      final preview = await s.choose('no', calc, now) as AssistantPreview;
      expect(preview.kind, PreviewKind.plan);
      expect(preview.plan!.totalMinor, 437800);
      expect(preview.calendar.length, 12);
      expect(preview.calendar.fold(0, (a, c) => a + c.$2), 437800);
      expect(preview.calendar.first.$1, DateTime(2026, 12, 5, 12));
      expect(line(preview, 'Cuotas'), contains('11 ×'));
      expect(preview.effects.first, contains('Hoy no se registra ningún pago'));
      final op = s.confirm(preview, calc.data)!;
      expect(op.kind, 'upsert');
      expect(op.data['entity'], 'installmentPlans');
      final doc = <String, dynamic>{'transactions': <dynamic>[], 'installmentPlans': <dynamic>[]};
      applyOperation(doc, op);
      expect(doc['transactions'], isEmpty, reason: 'Nothing paid today');
    });

    test('other ways of saying it, and an amount per instalment is not the total', () async {
      final calc = FinanceCalculator(data());
      for (final text in ['Pagaré 4.378 euros en doce mensualidades', 'Compra de 4.378 € a pagar en 12 cuotas', 'He financiado 4378 € en 12 meses', '4.378 en 12 meses']) {
        final reply = await session().say(text, calc, now);
        expect(reply, isA<AssistantQuestion>(), reason: text);
        expect((reply as AssistantQuestion).field, isNot(PendingField.amount), reason: '$text: the total is known');
      }
      final s = session();
      await s.say('Préstamo de 300 € al mes durante 12 meses para el coche, primera cuota el 1 de diciembre', calc, now);
      await s.choose('nomina', calc, now);
      final preview = await s.choose('yes', calc, now) as AssistantPreview;
      expect(preview.plan!.kind, InstallmentKind.loan);
      expect(preview.plan!.totalMinor, 360000, reason: '300 € each, 12 times');
      expect(preview.plan!.name, 'Coche');
      expect(preview.calendar.every((c) => c.$2 == 30000), isTrue);
    });

    test('an instalment already paid is a payment of the plan, not a new plan nor a plain expense', () async {
      final s = session();
      final calc = FinanceCalculator(data(plans: [sofa]));
      final preview = await s.say('He pagado la cuota del sofá', calc, now) as AssistantPreview;
      expect(preview.kind, PreviewKind.instalment);
      expect(preview.title, contains('Cuota 1/3'));
      final op = s.confirm(preview, calc.data)!;
      expect(op.data['record']['externalID'], '${installmentMarker}sofa:1');
      expect(op.data['record']['amountMinor'], 40000);
      final status = await session().say('¿Cuánto me queda del sofá?', calc, now) as AssistantResult;
      expect(status.lines.single, contains('quedan 1.200,00'));
      expect(status.planId, 'sofa');
    });

    test('unsupported operations point to their screen and never become an expense', () async {
      final calc = FinanceCalculator(data());
      expect((await session().say('¿Cómo quedaría mi disponible si gasto 600 €?', calc, now) as AssistantPointer).kind, IntentKind.simulation);
      expect((await session().say('Traspasa 100 € a Naranja', calc, now) as AssistantPointer).text, contains('no mueve dinero en el banco'));
    });
  });

  group('3. concept and category', () {
    test('«He gastado 44,53 en la gasolinera»: the concept is kept while asking; fuel is asked, not assumed', () async {
      final s = session();
      final calc = FinanceCalculator(data());
      final account = await s.say('He gastado 44,53 en la gasolinera', calc, now) as AssistantQuestion;
      expect(account.field, PendingField.account);
      final category = await s.choose('nomina', calc, now) as AssistantQuestion;
      expect(category.field, PendingField.category, reason: 'A station sells more than fuel');
      expect(category.options.first, ('Combustible', 'fuel'));
      expect(category.options.last, ('Sin categoría', 'none'));
      final preview = await s.choose('fuel', calc, now) as AssistantPreview;
      expect(line(preview, 'Concepto'), 'Gasolinera');
      expect(line(preview, 'Categoría'), 'Combustible');
      expect(preview.draft!.amountMinor, 4453);
      expect(preview.draft!.validate(calc.data), isNull);
    });

    test('fuel itself is proposed; the personal learning and the person\'s rules come first', () async {
      final calc = FinanceCalculator(data());
      final fuel = await session().say('Gasté 50 € de gasolina con la Visa Oro', calc, now) as AssistantPreview;
      expect(line(fuel, 'Categoría'), 'Combustible (propuesta)');
      expect(fuel.proposal!.source, 'hint');
      final learnt = await session(learnt: {'Gasolinera': 'ocio'}).say('Gasté 30 en la gasolinera en efectivo', calc, now) as AssistantPreview;
      expect(line(learnt, 'Categoría'), 'Ocio (propuesta)', reason: 'What this person usually does wins over a generic hint');
      expect(learnt.proposal!.source, 'model');
      final brand = await session().say('He gastado 12 en el Mercadona en efectivo', calc, now) as AssistantPreview;
      expect(line(brand, 'Concepto'), 'Mercadona');
      expect(line(brand, 'Categoría'), 'Supermercado (propuesta)');
    });
  });

  group('4. corrections without starting again', () {
    test('amount, date and category corrected on the preview; the old card cannot be confirmed', () async {
      final s = session();
      final calc = FinanceCalculator(data());
      final first = await s.say('He gastado 44,53 € en la cena en efectivo', calc, now) as AssistantPreview;
      final amount = await s.say('No, eran 45 €', calc, now) as AssistantPreview;
      expect(amount.draft!.amountMinor, 4500);
      expect(amount.id, first.id, reason: 'Still the same draft');
      expect(line(amount, 'Concepto'), 'Cena', reason: 'Everything else is kept');
      final date = await s.say('fue ayer', calc, now) as AssistantPreview;
      expect(date.draft!.date, DateTime(2026, 11, 24, 12));
      final category = await s.say('categoría ocio', calc, now) as AssistantPreview;
      expect(line(category, 'Categoría'), 'Ocio');
      final account = await s.say('mejor con la de Naranja', calc, now) as AssistantPreview;
      expect(line(account, 'Cuenta'), 'Ahorro Naranja');
      expect(s.confirm(first, calc.data), isNull, reason: 'An earlier card is never applied');
      final op = s.confirm(account, calc.data)!;
      expect((op.data['record']['amountMinor'], op.data['record']['categoryID'], op.data['record']['sourceAccountID']), (4500, 'ocio', 'ahorro'));
    });
  });

  group('5. integrity', () {
    test('cancel leaves nothing; confirming twice gives one operation; a repeated movement is warned', () async {
      final s = session();
      final calc = FinanceCalculator(data());
      await s.say('He gastado 24 € cenando en efectivo', calc, now);
      expect((await s.say('cancela', calc, now) as AssistantMessage).text, contains('no se ha guardado nada'));
      expect(s.hasDraft, isFalse);
      final preview = await s.say('He gastado 24 € cenando en efectivo', calc, now) as AssistantPreview;
      expect(s.confirm(preview, calc.data), isNotNull);
      expect(s.confirm(preview, calc.data), isNull);
      final existing = Transaction(id: 'x', date: now, type: TransactionType.expense, amountMinor: 2400, descriptionText: 'Cena', sourceAccountId: 'efectivo');
      final repeated = await session().say('He gastado 24 € cenando en efectivo', FinanceCalculator(data(transactions: [existing])), now) as AssistantPreview;
      expect(repeated.warnings.single, contains('igual ese día'));
    });

    test('queries change nothing; the preview\'s «disponible» discounts bank holds like Inicio', () async {
      final s = session();
      final calc = FinanceCalculator(data(transactions: month));
      await s.say('¿Cuánto he gastado este mes?', calc, now);
      expect(s.hasDraft, isFalse);
      final preview = await s.say('He gastado 10 € en el super con la de nómina', calc, now, heldMinor: -2000) as AssistantPreview;
      final available = calc.spendableCash() - 2000;
      expect(preview.effects.any((e) => e.contains('Tu disponible') && e.contains(money2(available)) && e.contains(money2(available - 1000))), isTrue);
    });

    test('a new expense while a preview is open is a new subject, said explicitly', () async {
      final s = session();
      final calc = FinanceCalculator(data());
      await s.say('He gastado 24 € cenando en efectivo', calc, now);
      final other = await s.say('Pagué 12,50 en el super con la de nómina', calc, now) as AssistantPreview;
      expect(other.note, contains('Dejo aparte el gasto de 24,00'));
      expect(other.draft!.amountMinor, 1250);
    });
  });

  group('6. the earlier bank of sentences still works (and misspelt versions)', () {
    final cases = <(String, Type)>[
      ('He gastado 24 € cenando con la tarjeta de Bankinter', AssistantQuestion),
      ('he gastado 24€ en la cena en efectivo', AssistantPreview),
      ('Pagué 12,50 en el super en efectivo', AssistantPreview),
      ('e gastado 20 euros en gasolna en efectivo', AssistantPreview),
      ('Cobré la nómina, 1.850 €, en Bankinter nómina', AssistantPreview),
      ('Me han hecho un bizum de 15 euros en efectivo', AssistantPreview),
      ('Reserva 200 € para vacaciones en Naranja', AssistantPreview),
      ('reserba 100 para el viaje en naranja', AssistantPreview),
      ('apunta un ingreso de 30 € en efectivo', AssistantPreview),
      ('24 €', AssistantQuestion),
      ('he gastado en el super', AssistantQuestion),
      ('Hola Don Bigotes', AssistantMessage),
    ];
    for (final (text, type) in cases) {
      test(text, () async {
        final reply = await session().say(text, FinanceCalculator(data()), now);
        expect(reply.runtimeType, type, reason: reply is AssistantMessage ? reply.text : '');
      });
    }

    test('details of a few', () async {
      final calc = FinanceCalculator(data());
      final gas = await session().say('e gastado 20 euros en gasolna en efectivo', calc, now) as AssistantPreview;
      expect(line(gas, 'Concepto'), 'Gasolina');
      final trip = await session().say('reserba 100 para el viaje en naranja', calc, now) as AssistantPreview;
      expect(trip.reserve!.name, 'Viaje');
      final income = await session().say('apunta un ingreso de 30 € en efectivo', calc, now) as AssistantPreview;
      expect(income.title, contains('Ingreso'));
      expect((await session().say('he gastado en el super', calc, now) as AssistantQuestion).field, PendingField.amount);
    });
  });

  test('amounts, counts and dates as written in Spain', () {
    expect(parseAmount('4.378'), 437800);
    expect(parseAmount('4.378,25 €'), 437825);
    expect(parseAmount('44,53'), 4453);
    expect(parseAmount('3.5 euros'), 350);
    expect(parseAmount('pagar 4.378 € en 12 meses'), 437800, reason: 'The count is not the amount');
    expect(parseAmount('la cuota 3'), isNull);
    expect(parseCount('en doce mensualidades'), 12);
    expect(parseCount('12 cuotas de 300 €'), 12);
    expect(amountIsPerInstalment('12 cuotas de 300 €'), isTrue);
    expect(amountIsPerInstalment('300 € al mes'), isTrue);
    expect(amountIsPerInstalment('4.378 € en 12 meses'), isFalse);
    expect(parseDate('ayer', now), DateTime(2026, 11, 24, 12));
    expect(parseDate('el lunes', now), DateTime(2026, 11, 23, 12));
    expect(parseDate('el 30 de diciembre', now), DateTime(2025, 12, 30, 12), reason: 'A movement is never in the future');
    expect(parseDueDate('el 5 de diciembre', now), DateTime(2026, 12, 5, 12), reason: 'A due date can be');
    expect(parseDueDate('el día 5', now), DateTime(2026, 12, 5, 12));
    expect(parseDueDate('el 28', now), DateTime(2026, 11, 28, 12));
    expect(like('conpras', 'compras'), isTrue);
    expect(like('gasolinera', 'gasolina'), isFalse, reason: 'A station is not fuel');
  });

  test('the intent a future model would return is validated: unknown fields or values are refused', () {
    expect(AssistantIntent.fromJson({'kind': 'expense', 'amountMinor': 4453, 'concept': 'Gasolinera'})!.amountMinor, 4453);
    expect(AssistantIntent.fromJson({'kind': 'expense', 'sql': 'drop'}), isNull);
    expect(AssistantIntent.fromJson({'kind': 'payBank'}), isNull);
    expect(AssistantIntent.fromJson({'kind': 'expense', 'amountMinor': -5})!.amountMinor, isNull);
  });
}


String money2(int minor) => '${(minor ~/ 100).toString().replaceAllMapped(RegExp(r'(\d)(?=(\d{3})+$)'), (m) => '${m[1]}.')},${(minor.abs() % 100).toString().padLeft(2, '0')}';
