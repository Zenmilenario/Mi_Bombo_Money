// Don Bigotes' assistant, phase 1 (25 November 2026): a sentence becomes an operation Doblón already allows, prepared
// for the person to confirm. Rules on this device only: nothing leaves it, it works offline and costs nothing.
//
// Interpreting and executing are apart. `interpret` turns the sentence into a closed intent (what, amount, date and
// the words that may name an account, a category or a purpose); it never sees the database. `AssistantSession`
// resolves it against the person's own data with the app's rules (`TransactionDraft.validate`, `saveOperation`, the
// reserve form's checks), asks only for what is missing and shows a preview with its effect. Only `confirm` builds
// the operation, once. Queries are answered here from the data already on the device. Moving money at a bank is not
// something Doblón does, and the assistant does not either.
import 'banking.dart' show referenceSeconds;
import 'edits.dart';
import 'finance.dart';
import 'learning.dart' show letterWords;
import 'models.dart';
import 'presentation.dart' show money;

enum IntentKind { expense, income, reserve, listMovements, summary, installments, simulation, transfer, unknown }

enum QueryPeriod { today, yesterday, thisWeek, thisMonth, lastMonth, thisYear }

extension QueryPeriodTitle on QueryPeriod {
  String get title => switch (this) {
        QueryPeriod.today => 'hoy',
        QueryPeriod.yesterday => 'ayer',
        QueryPeriod.thisWeek => 'esta semana',
        QueryPeriod.thisMonth => 'este mes',
        QueryPeriod.lastMonth => 'el mes pasado',
        QueryPeriod.thisYear => 'este año',
      };

  (DateTime, DateTime) range(DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    return switch (this) {
      QueryPeriod.today => (today, today.add(const Duration(days: 1))),
      QueryPeriod.yesterday => (today.subtract(const Duration(days: 1)), today),
      QueryPeriod.thisWeek => (today.subtract(Duration(days: today.weekday - 1)), today.add(const Duration(days: 1))),
      QueryPeriod.thisMonth => (DateTime(now.year, now.month), DateTime(now.year, now.month + 1)),
      QueryPeriod.lastMonth => (DateTime(now.year, now.month - 1), DateTime(now.year, now.month)),
      QueryPeriod.thisYear => (DateTime(now.year), DateTime(now.year + 1)),
    };
  }
}

/// What the sentence asks for. Closed: the only kinds and fields there are. Text fields are the person's words,
/// matched later against their own accounts and categories.
class AssistantIntent {
  AssistantIntent({required this.kind, required this.text, this.amountMinor, this.date, this.period, this.purpose, this.concept});
  IntentKind kind;
  final String text;
  int? amountMinor;
  DateTime? date;
  QueryPeriod? period;

  /// What a reserve is for («vacaciones»).
  String? purpose;

  /// A short concept for the movement («Cena»).
  String? concept;
}

// ---------------------------------------------------------------- interpreting (rules)

String fold(String text) => letterWords(text).join(' ');

/// Lower case without accents, keeping the digits (for dates).
String _plain(String text) {
  const accents = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n'};
  final lower = text.toLowerCase().split('').map((c) => accents[c] ?? c).join();
  return lower.replaceAll(RegExp(r'[^a-z0-9/]+'), ' ').trim();
}

const _months = {
  'enero': 1, 'febrero': 2, 'marzo': 3, 'abril': 4, 'mayo': 5, 'junio': 6, 'julio': 7, 'agosto': 8, //
  'septiembre': 9, 'setiembre': 9, 'octubre': 10, 'noviembre': 11, 'diciembre': 12,
};
const _weekdays = {'lunes': 1, 'martes': 2, 'miercoles': 3, 'jueves': 4, 'viernes': 5, 'sabado': 6, 'domingo': 7};

/// Concepts for everyday words: the movement is called by what it was, not by the whole sentence.
const _concepts = {
  'cena': 'Cena', 'cenando': 'Cena', 'cenar': 'Cena', 'cene': 'Cena', 'comida': 'Comida', 'comiendo': 'Comida', 'comer': 'Comida', //
  'almuerzo': 'Comida', 'desayuno': 'Desayuno', 'desayunando': 'Desayuno', 'cafe': 'Café', 'cafes': 'Café', 'copas': 'Copas', //
  'gasolina': 'Gasolina', 'gasoil': 'Gasolina', 'diesel': 'Gasolina', 'super': 'Supermercado', 'supermercado': 'Supermercado', //
  'compra': 'Compra', 'taxi': 'Taxi', 'parking': 'Aparcamiento', 'aparcamiento': 'Aparcamiento', 'farmacia': 'Farmacia', //
  'cine': 'Cine', 'regalo': 'Regalo', 'ropa': 'Ropa', 'peluqueria': 'Peluquería', 'nomina': 'Nómina', 'sueldo': 'Nómina', //
  'bizum': 'Bizum', 'devolucion': 'Devolución', 'alquiler': 'Alquiler', 'luz': 'Luz', 'agua': 'Agua', 'internet': 'Internet',
};

/// Words that never name an account, a category or a concept.
const _stop = {
  'he', 'ha', 'me', 'mi', 'mis', 'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'de', 'del', 'en', 'con', 'por', 'para', 'a', 'al', 'y', 'o', //
  'que', 'lo', 'le', 'se', 'su', 'es', 'euro', 'euros', 'eur', 'cuenta', 'tarjeta', 'hoy', 'ayer', 'anteayer', 'esta', 'este', 'mes', //
  'gastado', 'gaste', 'gastar', 'gasto', 'pagado', 'pague', 'pagar', 'pago', 'comprado', 'compre', 'costado', 'cobrado', 'cobre', //
  'ingresado', 'ingreso', 'recibido', 'recibi', 'han', 'pagaron', 'ingresaron', 'reserva', 'reservar', 'aparta', 'apartar', 'guarda', //
  'guardar', 'dinero', 'muestrame', 'ensename', 'ver', 'cuanto', 'cuantos', 'cuanta', 'semana', 'ano', 'pasado', 'ultimo', 'ultimas',
};

/// Amount in cents, as written in Spain: «24», «24 €», «24,50», «4.378» (thousands), «1.234,56». A dot followed by
/// one or two digits is read as decimals («24.5»). Numbers that are days, months or a count of instalments are not it.
int? parseAmount(String text) {
  final t = text.toLowerCase();
  final number = RegExp(r'(\d{1,3}(?:\.\d{3})+|\d+)(?:([.,])(\d{1,2}))?(?!\d)');
  int? best;
  var bestScore = -1;
  for (final m in number.allMatches(t)) {
    final after = t.substring(m.end).trimLeft();
    final before = t.substring(0, m.start).trimRight();
    if (RegExp(r'^/\d').hasMatch(t.substring(m.end))) continue; // 3/11
    if (before.endsWith('/')) continue;
    if (RegExp(r'^(de\s+)?(' '${_months.keys.join('|')}' r')\b').hasMatch(after)) continue; // el 3 de noviembre
    if (RegExp(r'^(meses|mes|cuotas|mensualidades|plazos|dias|semanas|años|anos)\b').hasMatch(after)) continue;
    if (RegExp(r'(^|\s)el$').hasMatch(before) && !RegExp(r'^(€|eur|euros?)\b').hasMatch(after)) continue; // el 3
    final whole = int.parse(m.group(1)!.replaceAll('.', ''));
    final cents = m.group(3) == null ? 0 : int.parse(m.group(3)!.padRight(2, '0'));
    final value = whole * 100 + cents;
    final score = RegExp(r'^(€|eur\b|euros?\b)').hasMatch(after) || before.endsWith('€') ? 2 : 1;
    if (value > 0 && score > bestScore) {
      best = value;
      bestScore = score;
    }
  }
  return best;
}

/// The date the sentence names, or null (the preview then says «hoy»). Never in the future: a day of the month that
/// has not come yet is the one of the month before.
DateTime? parseDate(String text, DateTime now) {
  final f = ' ${_plain(text)} ';
  final today = DateTime(now.year, now.month, now.day, 12);
  if (f.contains(' anteayer ') || f.contains(' antes de ayer ')) return today.subtract(const Duration(days: 2));
  if (f.contains(' ayer ')) return today.subtract(const Duration(days: 1));
  for (final e in _weekdays.entries) {
    if (f.contains(' ${e.key} ')) {
      var back = (now.weekday - e.value) % 7;
      if (back == 0) back = 7;
      return today.subtract(Duration(days: back));
    }
  }
  final numeric = RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b').firstMatch(text);
  if (numeric != null) {
    final day = int.parse(numeric.group(1)!), month = int.parse(numeric.group(2)!);
    var year = numeric.group(3) == null ? now.year : int.parse(numeric.group(3)!);
    if (year < 100) year += 2000;
    var d = DateTime(year, month, day, 12);
    if (numeric.group(3) == null && d.isAfter(today)) d = DateTime(year - 1, month, day, 12);
    return d.month == month && d.day == day ? d : null;
  }
  final named = RegExp(r'\bel (\d{1,2}) de (' '${_months.keys.join('|')}' r')\b').firstMatch(f);
  if (named != null) {
    final day = int.parse(named.group(1)!), month = _months[named.group(2)]!;
    var d = DateTime(now.year, month, day, 12);
    if (d.isAfter(today)) d = DateTime(now.year - 1, month, day, 12);
    return d.month == month ? d : null;
  }
  final dayOnly = RegExp(r'\bel (\d{1,2})\b(?! de)').firstMatch(f);
  if (dayOnly != null && !RegExp(r'^\s*(€|euros?)').hasMatch(f.substring(dayOnly.end))) {
    final day = int.parse(dayOnly.group(1)!);
    var d = DateTime(now.year, now.month, day, 12);
    if (d.isAfter(today)) d = DateTime(now.year, now.month - 1, day, 12);
    return day >= 1 && day <= 31 && d.day == day ? d : null;
  }
  if (f.contains(' hoy ')) return today;
  return null;
}

QueryPeriod? parsePeriod(String text) {
  final f = ' ${fold(text)} ';
  if (f.contains(' mes pasado ') || f.contains(' ultimo mes ')) return QueryPeriod.lastMonth;
  if (f.contains(' este mes ') || f.contains(' del mes ') || f.contains(' en el mes ')) return QueryPeriod.thisMonth;
  if (f.contains(' esta semana ')) return QueryPeriod.thisWeek;
  if (f.contains(' este ano ')) return QueryPeriod.thisYear;
  if (f.contains(' anteayer ')) return null;
  if (f.contains(' ayer ')) return QueryPeriod.yesterday;
  if (f.contains(' hoy ')) return QueryPeriod.today;
  return null;
}

bool _has(String f, List<String> stems) => stems.any((s) => RegExp('(^| )$s').hasMatch(f));

IntentKind _kind(String f, int? amount) {
  if (_has(f, ['plazo', 'cuotas', 'mensualidades', 'fraccionad', 'repartid']) || RegExp(r'en \d+ meses').hasMatch(f)) return IntentKind.installments;
  if (RegExp(r'(^| )si (me )?gasto|como quedaria|que pasaria|si pago').hasMatch(f)) return IntentKind.simulation;
  if (_has(f, ['muestrame', 'ensename', 'ensenam', 'lista', 'listado', 'que movimientos', 'mis movimientos', 'ver mis', 'quiero ver', 'dime las', 'dime los'])) {
    return IntentKind.listMovements;
  }
  if (_has(f, ['cuanto he', 'cuanto llevo', 'cuanto me he', 'resumen', 'como voy', 'balance'])) return IntentKind.summary;
  if (_has(f, ['traspas', 'transfier', 'transferencia', 'mueve', 'pasa '])) return IntentKind.transfer;
  if (_has(f, ['reserv', 'apart', 'guarda', 'separa'])) return IntentKind.reserve;
  if (_has(f, ['cobr', 'ingres', 'me han pagado', 'me pagaron', 'me han hecho', 'nomina', 'sueldo', 'recib', 'me devolv', 'devolucion'])) {
    return IntentKind.income;
  }
  if (_has(f, ['gast', 'pag', 'compr', 'cost', 'cena', 'comid', 'comiendo', 'cenando', 'desayun', 'gasolina', 'super', 'taxi', 'cargo'])) {
    return IntentKind.expense;
  }
  return IntentKind.unknown;
}

/// The sentence as a closed intent. Pure: it does not look at the person's data.
AssistantIntent interpret(String text, DateTime now) {
  final f = fold(text);
  final amount = parseAmount(text);
  final kind = _kind(f, amount);
  final purposeMatch = RegExp(r'\bpara (?:las |los |el |la |mis |unas |unos )?(.+?)(?: en | de la | desde |$)').firstMatch(f);
  final words = f.split(' ');
  final concept = words.map((w) => _concepts[w]).whereType<String>().firstOrNull;
  return AssistantIntent(
    kind: kind,
    text: text,
    amountMinor: amount,
    date: parseDate(text, now),
    period: parsePeriod(text),
    purpose: purposeMatch == null ? null : _capital(purposeMatch.group(1)!.trim()),
    concept: concept,
  );
}

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

// ---------------------------------------------------------------- resolving against the person's data

/// Words of a name that tell it apart (not «cuenta», «tarjeta», «de»…), folded.
List<String> _nameWords(String name) => letterWords(name).where((w) => w.length >= 3 && !_stop.contains(w)).toList();

bool _mentions(List<String> phrase, String word) => phrase.any((p) => p == word || (p.length >= 5 && word.length >= 5 && p.substring(0, 5) == word.substring(0, 5)));

/// An account the person can name: its own name, or a card linked to it.
class AccountChoice {
  AccountChoice(this.account, [this.card]);
  final Account account;
  final PaymentCard? card;
  String get label => card == null ? account.name : '${card!.name} · ${account.name}';
}

/// Accounts (and cards) the sentence names, best first. Several with the same score are all returned: the person
/// chooses, it is never guessed.
List<AccountChoice> namedAccounts(String text, Finances data, {bool Function(Account)? allowed}) {
  final phrase = letterWords(text);
  final ok = allowed ?? (Account a) => true;
  final scored = <(AccountChoice, int)>[];
  for (final a in data.accounts.where((a) => !a.isArchived && ok(a))) {
    final score = _nameWords(a.name).where((w) => _mentions(phrase, w)).length + (a.type == AccountType.cash && _has(phrase.join(' '), ['efectivo', 'metalico', 'cash']) ? 2 : 0);
    if (score > 0) scored.add((AccountChoice(a), score));
  }
  for (final c in data.cards.where((c) => !c.isArchived)) {
    final account = data.account(c.linkedAccountId);
    if (account == null || account.isArchived || !ok(account)) continue;
    final score = _nameWords(c.name).where((w) => _mentions(phrase, w)).length + (c.lastFour.isNotEmpty && text.contains(c.lastFour) ? 2 : 0);
    if (score > 0) scored.add((AccountChoice(account, c), score));
  }
  if (scored.isEmpty) return const [];
  final top = scored.map((s) => s.$2).reduce((a, b) => a > b ? a : b);
  final best = scored.where((s) => s.$2 == top).map((s) => s.$1).toList();
  // A card and its own account named alike are the same choice.
  final seen = <String>{};
  return [for (final c in best) if (seen.add('${c.account.id}|${c.card?.id}')) c];
}

/// A category whose name the sentence says («compras», «restaurantes»), of the kind that fits.
Category? namedCategory(String text, Finances data, bool Function(Category) fits) {
  final phrase = letterWords(text);
  final found = [
    for (final c in data.categories.where((c) => !c.isArchived && fits(c)))
      if (_nameWords(c.name).isNotEmpty && _nameWords(c.name).every((w) => _mentions(phrase, w))) c
  ];
  return found.length == 1 ? found.single : null;
}

// ---------------------------------------------------------------- the conversation

enum PendingField { kind, amount, account, purpose }

/// What Don Bigotes answers: a question, a prepared operation, a query result or a pointer to an existing screen.
sealed class AssistantReply {}

class AssistantQuestion extends AssistantReply {
  AssistantQuestion(this.text, this.field, [this.options = const []]);
  final String text;
  final PendingField field;

  /// Choices to tap (label, value). The person can also answer in words.
  final List<(String, String)> options;
}

class AssistantPreview extends AssistantReply {
  AssistantPreview({required this.id, required this.title, required this.lines, required this.effects, required this.operation, this.warnings = const [], this.draft, this.reserve});

  /// The id the new record will have: confirming twice can never create two.
  final String id;
  final String title;
  final List<(String, String)> lines;
  final List<String> effects;
  final List<String> warnings;
  final Operation operation;

  /// What «Corregir» opens the form with.
  final TransactionDraft? draft;
  final ({String name, int amountMinor, String accountId})? reserve;
}

class AssistantResult extends AssistantReply {
  AssistantResult(this.title, this.lines, {this.transactions = const [], this.totalMinor});
  final String title;
  final List<String> lines;
  final List<Transaction> transactions;
  final int? totalMinor;
}

class AssistantPointer extends AssistantReply {
  AssistantPointer(this.text, this.kind);
  final String text;
  final IntentKind kind;
}

class AssistantNotUnderstood extends AssistantReply {
  AssistantNotUnderstood(this.text);
  final String text;
}

/// One conversation. Holds the intent being prepared, so an answer fills what was missing; and the ids already
/// applied, so the same preview is never applied twice.
class AssistantSession {
  AssistantSession({required this.newId, this.propose});
  final String Function() newId;

  /// The category the app's own learning proposes for a concept (`Learning.categoryProposal`), when there is one.
  final Future<String?> Function(String text, TransactionType type)? propose;

  AssistantIntent? _intent;
  PendingField? _pending;
  String? _accountId;
  String? _previewId;
  final applied = <String>{};

  void cancel() {
    _intent = null;
    _pending = null;
    _accountId = null;
    _previewId = null;
  }

  /// What the person wrote (a new request, or the answer to the last question).
  Future<AssistantReply> say(String text, FinanceCalculator calc, DateTime now) {
    final intent = _intent;
    if (intent != null && _pending != null && _fill(intent, _pending!, text, calc.data)) return _next(calc, now);
    cancel();
    _intent = interpret(text, now);
    return _next(calc, now);
  }

  /// A tapped option of the last question.
  Future<AssistantReply> choose(String value, FinanceCalculator calc, DateTime now) {
    final intent = _intent;
    if (intent == null || _pending == null) return Future.value(AssistantNotUnderstood('Empecemos de nuevo: ¿qué quieres apuntar o consultar?'));
    switch (_pending!) {
      case PendingField.kind:
        intent.kind = IntentKind.values.byName(value);
      case PendingField.account:
        _accountId = value;
      case PendingField.amount || PendingField.purpose:
        break;
    }
    _pending = null;
    return _next(calc, now);
  }

  bool _fill(AssistantIntent intent, PendingField field, String text, Finances data) {
    switch (field) {
      case PendingField.amount:
        final amount = parseAmount(text);
        if (amount == null) return false;
        intent.amountMinor = amount;
      case PendingField.purpose:
        if (fold(text).isEmpty) return false;
        intent.purpose = _capital(text.trim());
      case PendingField.kind:
        final f = fold(text);
        if (_has(f, ['gast', 'pag'])) {
          intent.kind = IntentKind.expense;
        } else if (_has(f, ['ingres', 'cobr'])) {
          intent.kind = IntentKind.income;
        } else {
          return false;
        }
      case PendingField.account:
        final named = namedAccounts(text, data, allowed: intent.kind == IntentKind.reserve ? _reservable : null);
        if (named.isEmpty) return false;
        if (named.length > 1) {
          // Still several: the question is asked again with fewer options.
          _narrowed = named;
          return true;
        }
        _accountId = named.single.account.id;
    }
    _pending = null;
    return true;
  }

  List<AccountChoice>? _narrowed;

  static bool _reservable(Account a) => a.type != AccountType.investment && !a.type.isLiability;

  Future<AssistantReply> _next(FinanceCalculator calc, DateTime now) async {
    final intent = _intent!;
    final data = calc.data;
    switch (intent.kind) {
      case IntentKind.unknown:
        if (intent.amountMinor != null) {
          return _ask(PendingField.kind, '¿Es un gasto o un ingreso de ${money(intent.amountMinor!)}?',
              [('Gasto', IntentKind.expense.name), ('Ingreso', IntentKind.income.name)]);
        }
        cancel();
        return AssistantNotUnderstood(
            'No lo he entendido. Puedo apuntar un gasto o un ingreso («He gastado 24 € en la cena»), reservar dinero («Reserva 200 € para vacaciones») '
            'o enseñarte movimientos y resúmenes («Muéstrame las compras de este mes»).');
      case IntentKind.installments:
      case IntentKind.simulation:
      case IntentKind.transfer:
        final kind = intent.kind;
        cancel();
        return AssistantPointer(
            switch (kind) {
              IntentKind.installments => 'Los pagos a plazos se preparan en su pantalla, con el calendario a la vista antes de guardar.',
              IntentKind.simulation => 'Eso se ve en la previsión: ahí puedes simular un gasto sin apuntarlo.',
              _ => 'Los traspasos entre tus cuentas, por ahora, desde el formulario. Apuntarlo no mueve dinero en el banco.',
            },
            kind);
      case IntentKind.listMovements:
        cancel();
        return _list(intent, calc, now);
      case IntentKind.summary:
        cancel();
        return _summary(intent, calc, now);
      case IntentKind.expense:
      case IntentKind.income:
      case IntentKind.reserve:
        return _prepare(intent, calc, now, data);
    }
  }

  AssistantQuestion _ask(PendingField field, String text, [List<(String, String)> options = const []]) {
    _pending = field;
    return AssistantQuestion(text, field, options);
  }

  Future<AssistantReply> _prepare(AssistantIntent intent, FinanceCalculator calc, DateTime now, Finances data) async {
    final reserve = intent.kind == IntentKind.reserve;
    if (intent.amountMinor == null) {
      return _ask(PendingField.amount, reserve ? '¿Cuánto quieres reservar?' : '¿De cuánto ha sido el ${intent.kind == IntentKind.income ? 'ingreso' : 'gasto'}?');
    }
    if (reserve && (intent.purpose == null || intent.purpose!.isEmpty)) return _ask(PendingField.purpose, '¿Para qué es la reserva?');
    // The account: named in the sentence, chosen, or asked. Never guessed among several.
    final allowed = reserve ? _reservable : (Account a) => !a.isArchived;
    if (_accountId == null) {
      final narrowed = _narrowed;
      _narrowed = null;
      final named = narrowed ?? namedAccounts(intent.text, data, allowed: allowed);
      final active = data.accounts.where((a) => !a.isArchived && allowed(a)).toList();
      if (named.length == 1) {
        _accountId = named.single.account.id;
      } else if (named.isEmpty && active.length == 1) {
        _accountId = active.single.id;
      } else {
        final options = named.isNotEmpty ? named : [for (final a in active) AccountChoice(a)];
        if (options.isEmpty) {
          cancel();
          return AssistantNotUnderstood('Primero necesitas una cuenta. Créala en Cuentas › «Añadir cuenta».');
        }
        return _ask(
            PendingField.account,
            named.length > 1
                ? 'Tienes ${named.length} que encajan. ¿Cuál es?'
                : reserve
                    ? '¿En qué cuenta lo reservo?'
                    : '¿Con qué cuenta o tarjeta?',
            [for (final c in options.take(8)) (c.label, c.account.id)]);
      }
    }
    final account = data.account(_accountId)!;
    final id = _previewId ??= newId();
    if (reserve) return _reservePreview(intent, calc, account, id, now);
    return _movementPreview(intent, calc, account, id, now);
  }

  AssistantReply _reservePreview(AssistantIntent intent, FinanceCalculator calc, Account account, String id, DateTime now) {
    final amount = intent.amountMinor!;
    final free = calc.balance(account) - calc.reservedAmount(account);
    final counted = account.includeInNetWorth;
    final stamp = referenceSeconds(now);
    return AssistantPreview(
      id: id,
      title: 'Reserva · ${money(amount)}',
      lines: [('Para', intent.purpose!), ('Cuenta', account.name), ('Importe', money(amount))],
      effects: [
        'Libre en ${account.name}: ${money(free)} → ${money(free - amount)}',
        if (counted) 'Tu disponible: ${money(calc.spendableCash())} → ${money(calc.spendableCash() - amount)}',
        'El dinero no se mueve: queda apartado en la misma cuenta.',
      ],
      warnings: [if (amount > free) 'Es más de lo que tienes libre en esa cuenta.'],
      operation: upsertOperation(
          'reservedFunds',
          {'id': id, 'name': intent.purpose!, 'amountMinor': amount, 'notes': '', 'createdAt': stamp, 'updatedAt': stamp, 'accountID': account.id},
          create: true),
      reserve: (name: intent.purpose!, amountMinor: amount, accountId: account.id),
    );
  }

  Future<AssistantReply> _movementPreview(AssistantIntent intent, FinanceCalculator calc, Account account, String id, DateTime now) async {
    final data = calc.data;
    final type = intent.kind == IntentKind.income ? TransactionType.income : TransactionType.expense;
    final concept = intent.concept ?? (type == TransactionType.income ? 'Ingreso' : 'Gasto');
    final named = namedCategory(intent.text, data, (c) => categorySupports(c, type));
    final proposed = named?.id ?? (intent.concept == null || propose == null ? null : await propose!(intent.concept!, type));
    final category = data.category(proposed);
    final date = intent.date ?? now;
    final draft = TransactionDraft(date: date, type: type, amountMinor: intent.amountMinor!, description: concept, sourceAccountId: account.id, categoryId: category?.id);
    final problem = draft.validate(data);
    if (problem != null) {
      cancel();
      return AssistantNotUnderstood('No puedo prepararlo: $problem');
    }
    final amount = intent.amountMinor!;
    final sign = type == TransactionType.income ? 1 : -1;
    final balance = calc.balance(account);
    final spendable = account.includeInNetWorth && account.type != AccountType.investment && !account.type.isLiability;
    final budget = category == null ? null : calc.budgetProgress(DateTime(date.year, date.month)).where((b) => b.category.id == category.id && b.limitMinor > 0).firstOrNull;
    final duplicates = duplicateCandidates(
        date: date,
        source: account.id,
        destination: null,
        type: type,
        amountMinor: amount,
        description: concept,
        existing: data.transactions,
        fingerprints: {for (final t in data.transactions) t.id: t.fingerprint});
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    final when = day == today
        ? 'hoy, ${date.day}/${date.month}'
        : day == today.subtract(const Duration(days: 1))
            ? 'ayer, ${date.day}/${date.month}'
            : '${date.day}/${date.month}/${date.year}';
    return AssistantPreview(
      id: id,
      title: '${type == TransactionType.income ? 'Ingreso' : 'Gasto'} · ${money(amount)}',
      lines: [
        ('Concepto', concept),
        ('Cuenta', account.name),
        ('Categoría', category == null ? 'Sin categoría' : '${category.name}${named == null ? ' (propuesta por tu historial)' : ''}'),
        ('Fecha', when),
      ],
      effects: [
        'Saldo de ${account.name}: ${money(balance)} → ${money(balance + sign * amount)}',
        if (spendable && day.isBefore(today.add(const Duration(days: 1))))
          'Tu disponible: ${money(calc.spendableCash())} → ${money(calc.spendableCash() + sign * amount)}',
        if (budget != null && type == TransactionType.expense)
          'Presupuesto de ${category!.name}: ${money(budget.spentMinor)} → ${money(budget.spentMinor + amount)} de ${money(budget.limitMinor)}',
      ],
      warnings: [if (duplicates.isNotEmpty) 'Ya hay un movimiento igual ese día: comprueba que no lo hayas apuntado ya.'],
      operation: saveOperation(draft, data, now, newId: id),
      draft: draft,
    );
  }

  /// Applies a preview once. Null when it was already applied (a second tap, a repeated request).
  Operation? confirm(AssistantPreview preview, Finances data) {
    if (!applied.add(preview.id)) return null;
    if (data.transactions.any((t) => t.id == preview.id) || data.reservedFunds.any((f) => f.id == preview.id)) return null;
    cancel();
    return preview.operation;
  }

  /// Undoes what a confirmed preview did: the movement or the reserve is removed (only if nothing uses the reserve).
  Operation? undo(AssistantPreview preview, Finances data) {
    if (preview.reserve != null) {
      if (data.transactions.any((t) => t.reservedFundId == preview.id)) return null;
      return removeOperation('reservedFunds', preview.id);
    }
    return data.transactions.any((t) => t.id == preview.id) ? Operation('delete', {'id': preview.id}) : null;
  }

  AssistantReply _list(AssistantIntent intent, FinanceCalculator calc, DateTime now) {
    final data = calc.data;
    final f = fold(intent.text);
    final income = _has(f, ['ingres', 'cobr']);
    final type = income ? TransactionType.income : TransactionType.expense;
    final category = namedCategory(intent.text, data, (c) => categorySupports(c, type));
    final accounts = namedAccounts(intent.text, data);
    final account = accounts.length == 1 ? accounts.single.account : null;
    final period = intent.period ?? QueryPeriod.thisMonth;
    final (from, to) = period.range(now);
    final rows = [
      for (final t in data.transactions)
        if (!t.date.isBefore(from) &&
            t.date.isBefore(to) &&
            (income ? t.type.countsAsIncome : t.type.countsAsExpense) &&
            (category == null || t.categoryId == category.id) &&
            (account == null || t.sourceAccountId == account.id))
          t
    ];
    final total = rows.fold(0, (s, t) => s + t.amountMinor.abs());
    final what = category?.name.toLowerCase() ?? (income ? 'ingresos' : 'gastos');
    return AssistantResult(
      '${_capital(what)} ${period.title}${account == null ? '' : ' en ${account.name}'}',
      [rows.isEmpty ? 'No hay ninguno.' : '${rows.length} ${rows.length == 1 ? 'movimiento' : 'movimientos'} · ${money(total)} en total'],
      transactions: rows.take(30).toList(),
      totalMinor: total,
    );
  }

  AssistantReply _summary(AssistantIntent intent, FinanceCalculator calc, DateTime now) {
    final period = intent.period == QueryPeriod.lastMonth ? QueryPeriod.lastMonth : QueryPeriod.thisMonth;
    final month = period == QueryPeriod.lastMonth ? DateTime(now.year, now.month - 1) : DateTime(now.year, now.month);
    final s = calc.monthlySummary(month);
    final category = namedCategory(intent.text, calc.data, (c) => categorySupports(c, TransactionType.expense));
    if (category != null) {
      final (from, to) = period.range(now);
      final spent = calc.data.transactions
          .where((t) => t.categoryId == category.id && !t.date.isBefore(from) && t.date.isBefore(to))
          .fold(0, (sum, t) => sum + FinanceCalculator.budgetExpenseAmount(t));
      return AssistantResult('${category.name} ${period.title}', ['Has gastado ${money(spent)}.']);
    }
    return AssistantResult('Resumen de ${period.title}', [
      'Ingresos: ${money(s.dailyIncomeMinor)}',
      'Gastos: ${money(s.dailyExpenseMinor)}',
      'Resultado: ${money(s.dailyNetMinor, signed: true)}',
      if (s.hasReserves) 'Sin contar lo pagado con reservas ni lo destinado a ellas, como en Inicio.',
    ]);
  }
}
