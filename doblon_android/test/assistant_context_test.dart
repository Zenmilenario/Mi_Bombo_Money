// Fictitious data only. Don Bigotes keeps the draft coherent across a whole conversation (25 November 2026, after a
// conversation on the iPhone turned a loan of 4.378 € into one of 5 €). The draft is checked after every turn through
// the context the session would send to the model. Cases: the reported conversation with rules only and with the
// model's real answers before the fix (createPlan of 5 € per instalment) and after it; corrections («te he dicho que
// un préstamo», an explicit new total); rough dates; numbers that are days; a real change of subject, cancelling and
// resuming; and expenses and queries, so nothing that worked gets worse.
import 'package:doblon/assistant.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:flutter_test/flutter_test.dart';

final now = DateTime(2026, 11, 25, 18);
final calc = FinanceCalculator(Finances(
  accounts: [
    Account(id: 'nomina', name: 'Cuenta ficticia', type: AccountType.checking, openingDate: DateTime(2026), openingBalanceMinor: 150000),
    Account(id: 'ahorro', name: 'Ahorro ficticio', type: AccountType.savings, openingDate: DateTime(2026)),
  ],
  categories: [Category(id: 'fuel', name: 'Combustible', kind: CategoryKind.expense)],
  transactions: [
    Transaction(id: 'g', date: DateTime(2026, 11, 10), type: TransactionType.expense, amountMinor: 2500, descriptionText: 'Gasolina', sourceAccountId: 'nomina', categoryId: 'fuel'),
  ],
));

/// A model that answers in order (what the real one answered, measured on 25/11 with fictitious data).
class Model {
  Model(this.answers);
  final List<Map<String, Object?>> answers;
  int calls = 0;
  Future<RemoteInterpretation> call(Map<String, Object?> context) async {
    calls++;
    return answers.isEmpty ? (intent: null, error: 'assistant_unavailable') : (intent: AssistantIntent.fromJson(answers.removeAt(0)), error: null);
  }
}

AssistantSession session([Model? model]) {
  var n = 0;
  return AssistantSession(newId: () => 'nuevo-${++n}', remote: model?.call);
}

/// The open draft in words, as the model would receive it.
String draft(AssistantSession s) => '${s.contextFor('·', calc.data, now)['draft'] ?? ''}';

Future<AssistantQuestion> ask(AssistantSession s, String text, PendingField field) async {
  final reply = await s.say(text, calc, now);
  expect(reply, isA<AssistantQuestion>(), reason: '«$text» → ${reply.runtimeType}${reply is AssistantMessage ? ': ${reply.text}' : ''}');
  expect((reply as AssistantQuestion).field, field, reason: text);
  expect(reply.note, isNull, reason: '«$text» must not set the draft aside');
  return reply;
}

/// The rest of the plan, from the month question to the preview; checks what was kept.
Future<AssistantPreview> finish(AssistantSession s, {required DateTime first}) async {
  var reply = await s.choose('due:${first.toIso8601String().substring(0, 10)}', calc, now);
  expect((reply as AssistantQuestion).field, PendingField.account);
  reply = await s.choose('nomina', calc, now);
  expect((reply as AssistantQuestion).field, PendingField.recorded);
  return await s.choose('no', calc, now) as AssistantPreview;
}

void expectLoan(AssistantPreview p, {DateTime? first}) {
  expect(p.plan!.totalMinor, 437800, reason: 'The 4.378 € never become 5 €');
  expect(p.plan!.count, 12);
  expect(p.plan!.kind, InstallmentKind.loan);
  expect(p.calendar.fold(0, (a, c) => a + c.$2), 437800);
  if (first != null) expect(p.calendar.first.$1, first);
}

void main() {
  group('the reported conversation: «A primeros de me si pon 5 de cada mes»', () {
    for (final (who, model) in [
      ('rules only', null),
      // What the model answered before the fix: a new plan of 5 € per instalment. The draft must survive it.
      ('the model\'s answer before the fix', Model([
        {'kind': 'createPlan', 'amountMinor': 437800, 'count': 12},
        {'kind': 'createPlan', 'amountMinor': 500, 'perInstalment': true, 'count': 12},
      ])),
      // What it answers now: a correction with the day.
      ('the model\'s answer now', Model([
        {'kind': 'createPlan', 'amountMinor': 437800, 'count': 12},
        {'kind': 'correction', 'dueDay': 5},
      ])),
    ]) {
      test(who, () async {
        final s = session(model);
        await ask(s, 'Quiero dejar grabado una deuda de 4378 € a pagar en 12 meses', PendingField.planKind);
        expect(draft(s), contains('4.378,00'));
        var reply = await s.choose('loan', calc, now) as AssistantQuestion;
        expect(reply.field, PendingField.planName);
        await ask(s, 'Préstamo del coche', PendingField.dueDate);
        expect(draft(s), allOf(contains('Préstamo'), contains('4.378,00'), contains('12 cuotas')));
        reply = await ask(s, 'A primeros de me si pon 5 de cada mes', PendingField.dueMonth);
        expect(reply.text, contains('el día 5 de cada mes'));
        expect(reply.options.first, ('5 de diciembre de 2026', 'due:2026-12-05'));
        expect(draft(s), allOf(contains('4.378,00'), contains('12 cuotas'), contains('día 5')), reason: 'Amount, count and kind kept');
        expectLoan(await finish(s, first: DateTime(2026, 12, 5)), first: DateTime(2026, 12, 5, 12));
      });
    }
  });

  test('«Te he dicho que un préstamo» corrects the kind and keeps everything else', () async {
    final s = session();
    await ask(s, 'Tengo que pagar 4.378 € en 12 meses', PendingField.planKind);
    await s.choose('purchase', calc, now); // tapped by mistake
    final reply = await ask(s, 'Te he dicho que un préstamo', PendingField.planName);
    expect(reply.text, startsWith('¿Cómo lo llamo?'), reason: 'Not taken as the name');
    expect(draft(s), allOf(startsWith('Préstamo'), contains('4.378,00'), contains('12 cuotas')));
    await ask(s, 'Coche', PendingField.dueDate);
    await ask(s, 'el día 5', PendingField.dueMonth);
    expectLoan(await finish(s, first: DateTime(2026, 12, 5)));
  });

  test('a rough date is proposed, not assumed; a coloquial or frustrated answer keeps the conversation', () async {
    final s = session();
    await ask(s, 'Préstamo de 4.378 € a devolver en 12 meses', PendingField.planName);
    await ask(s, 'el del coche', PendingField.dueDate);
    final rough = await ask(s, 'A principios de mes pon el día que más rabo te dé', PendingField.dueDate);
    expect(rough.text, contains('¿Te vale que la primera cuota sea el 1 de diciembre de 2026?'));
    expect(rough.options.last, ('Otro día', 'due:other'));
    expect(draft(s), contains('4.378,00'));
    // Not understood at all: the same question again, with everything kept (no generic list, nothing set aside).
    final lost = await ask(s, 'ufff no se tio', PendingField.dueDate);
    expect(lost.text, startsWith('No te he entendido.'));
    expect(draft(s), contains('4.378,00'));
    expectLoan(await finish(s, first: DateTime(2026, 12, 1)), first: DateTime(2026, 12, 1, 12));
  });

  test('numbers in a date never touch the amount or the count; an explicit new total does', () async {
    final s = session();
    await ask(s, 'Préstamo de 4.378 € en 12 meses', PendingField.planName);
    await ask(s, 'Coche', PendingField.dueDate);
    for (final text in ['los dias 10', 'pon el 10 de cada mes porfa', 'el diez... digo el 10']) {
      final reply = await s.say(text, calc, now);
      expect(reply, isA<AssistantQuestion>(), reason: text);
      expect(draft(s), allOf(contains('4.378,00'), contains('12 cuotas')), reason: text);
    }
    var reply = await s.say('pues a partir del 3 del que viene', calc, now);
    expect((reply as AssistantQuestion).field, PendingField.account, reason: 'A full date: no month to ask');
    reply = await s.choose('nomina', calc, now) as AssistantQuestion;
    var preview = await s.choose('no', calc, now) as AssistantPreview;
    expectLoan(preview, first: DateTime(2026, 12, 3, 12));
    // Corrections on the preview: a date changes only the date; the total changes only when said as money.
    preview = await s.say('no, la primera es el 12 de enero', calc, now) as AssistantPreview;
    expectLoan(preview, first: DateTime(2027, 1, 12, 12));
    preview = await s.say('no, el total son 4.500 €', calc, now) as AssistantPreview;
    expect((preview.plan!.totalMinor, preview.plan!.count, preview.calendar.first.$1), (450000, 12, DateTime(2027, 1, 12, 12)));
  });

  test('with the model: the day without month, then the month in words', () async {
    final model = Model([
      {'kind': 'createPlan', 'amountMinor': 437800, 'count': 12, 'planKind': 'loan', 'purpose': 'Coche'},
      {'kind': 'correction', 'dueDay': 5, 'dueDate': '2027-01-05'},
    ]);
    final s = session(model);
    await ask(s, 'tengo un prestamo del coche de 4378 pavos a pagar en 12 meses', PendingField.dueDate);
    // «el cinco de enero»: the rules cannot read «cinco»; the model gives the date, accepted because the month is said.
    final reply = await s.say('el cinco de enero', calc, now);
    expect((reply as AssistantQuestion).field, PendingField.account);
    await s.choose('nomina', calc, now);
    expectLoan(await s.choose('no', calc, now) as AssistantPreview, first: DateTime(2027, 1, 5, 12));
  });

  test('a real change of subject sets the draft aside explicitly; it comes back without exact words; cancel and confirm', () async {
    final s = session();
    await ask(s, 'Préstamo de 4.378 € en 12 meses', PendingField.planName);
    final query = await s.say('oye, ¿cuánto llevo gastado este mes?', calc, now) as AssistantResult;
    expect(query.title, 'Resumen de este mes');
    expect(query.note, contains('Dejo aparte el pago a plazos de 4.378,00'));
    expect(query.canResume, isTrue, reason: 'The card offers to go back, no exact words needed');
    final back = await s.resume(calc, now) as AssistantQuestion;
    expect(back.field, PendingField.planName);
    expect(draft(s), contains('4.378,00'));
    // Another operation with its own amount is another subject too.
    final expense = await s.say('he gastado 20 euros en gasolina con la de ahorro', calc, now) as AssistantPreview;
    expect(expense.note, contains('Dejo aparte'));
    expect(s.confirm(expense, calc.data), isNotNull);
    expect(s.confirm(expense, calc.data), isNull, reason: 'Never applied twice');
    // And cancelling leaves nothing.
    await s.resume(calc, now);
    expect((await s.say('cancela', calc, now) as AssistantMessage).text, contains('no se ha guardado nada'));
    expect(s.hasDraft, isFalse);
  });

  test('expenses and queries still work; an expense correction without € is still the amount', () async {
    final s = session();
    await s.say('He gastado 44,53 en la gasolinera', calc, now);
    await s.choose('nomina', calc, now);
    final preview = await s.choose('fuel', calc, now) as AssistantPreview;
    final fixed = await s.say('no, eran 45', calc, now) as AssistantPreview;
    expect((fixed.draft!.amountMinor, fixed.id), (4500, preview.id));
    final day = await s.say('fue el lunes', calc, now) as AssistantPreview;
    expect((day.draft!.amountMinor, day.draft!.date), (4500, DateTime(2026, 11, 23, 12)), reason: 'A date does not change the amount');
    final list = await session().say('¿qué he gastado este mes?', calc, now) as AssistantResult;
    expect(list.transactions.single.id, 'g');
  });
}
