// Don Bigotes' assistant (phase 1, rules on this device; 25 November 2026, reworked the same day after the first
// tests on the iPhone). A sentence becomes an operation Doblón already allows, prepared for the person to confirm,
// or a query answered from the data already on the device. Nothing leaves the device and nothing costs money.
//
// Interpreting and executing are apart:
//  1. `Signals` reads the sentence: amount, count of instalments, dates and periods, and cues (a question or a
//     request to see, verbs of spending, earning, reserving, paying in instalments, corrections, continuations).
//     Keywords are compared by stem and with an edit distance, so misspellings still match.
//  2. `AssistantSession` decides with those cues and the conversation's context (the last query, the draft being
//     prepared): consulting existing data or recording something new, a continuation («No, qué cosas»), a
//     correction («No, eran 45 €») or a change of subject (the draft is set aside explicitly, never answered with
//     the new sentence).
//  3. It resolves the draft against the person's own data with the app's rules (`TransactionDraft.validate`,
//     `saveOperation`, `savePlanOperation`, `paymentOperation`, the reserve form's checks), asks only for what is
//     missing and shows a preview with the same figures as the rest of the app (reserves and bank holds included).
//     Only `confirm` returns the operation, once.
//
// The limit of rules: they understand the phrasings they were built for and close variations, not any sentence. A
// model (phase 2, Cloudflare Workers AI, decided on 25/11 and not active) would fill the same `AssistantIntent`
// (`assistantIntentSchema`), so everything after step 1 stays the same.
import 'dart:math' as math;

import 'automation.dart' show matchRule;
import 'banking.dart' show referenceSeconds;
import 'edits.dart';
import 'finance.dart';
import 'installments.dart';
import 'models.dart';
import 'presentation.dart' show money;

enum IntentKind { expense, income, reserve, listMovements, summary, createPlan, payInstalment, planStatus, simulation, transfer, unknown }

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

enum QueryScope { expenses, income, all }

// ---------------------------------------------------------------- text

/// Lower case, without accents, keeping digits and the signs that matter for amounts and dates.
String plainText(String text) {
  const accents = {'á': 'a', 'à': 'a', 'é': 'e', 'è': 'e', 'í': 'i', 'ó': 'o', 'ò': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n', 'ç': 'c'};
  return text.toLowerCase().split('').map((c) => accents[c] ?? c).join();
}

List<String> wordsOf(String text) => plainText(text).split(RegExp(r'[^a-z0-9]+')).where((w) => w.isNotEmpty).toList();

int _distance(String a, String b) {
  if ((a.length - b.length).abs() > 2) return 3;
  var previous = List<int>.generate(b.length + 1, (i) => i);
  for (var i = 1; i <= a.length; i++) {
    final current = [i, ...List<int>.filled(b.length, 0)];
    for (var j = 1; j <= b.length; j++) {
      current[j] = math.min(math.min(current[j - 1] + 1, previous[j] + 1), previous[j - 1] + (a[i - 1] == b[j - 1] ? 0 : 1));
    }
    previous = current;
  }
  return previous[b.length];
}

/// Whether [word] is [key], allowing a slip. A key ending in `*` is a stem («compr*» is «compras», «comprado»…).
bool like(String word, String key) {
  if (key.endsWith('*')) {
    final stem = key.substring(0, key.length - 1);
    if (word.startsWith(stem)) return true;
    return stem.length >= 5 && word.length >= stem.length && _distance(word.substring(0, stem.length), stem) <= 1;
  }
  if (word == key) return true;
  if (key.length < 5) return false;
  return _distance(word, key) <= (key.length >= 9 ? 2 : 1);
}

bool _any(List<String> words, List<String> keys) => words.any((w) => keys.any((k) => like(w, k)));

bool _phrase(String plain, List<String> phrases) {
  final padded = ' ${plain.replaceAll(RegExp(r'[^a-z0-9/]+'), ' ').trim()} ';
  return phrases.any((p) => padded.contains(' $p '));
}

String _capital(String s) => s.isEmpty ? s : s[0].toUpperCase() + s.substring(1);

const _months = {
  'enero': 1, 'febrero': 2, 'marzo': 3, 'abril': 4, 'mayo': 5, 'junio': 6, 'julio': 7, 'agosto': 8, //
  'septiembre': 9, 'setiembre': 9, 'octubre': 10, 'noviembre': 11, 'diciembre': 12,
};
const _weekdays = {'lunes': 1, 'martes': 2, 'miercoles': 3, 'jueves': 4, 'viernes': 5, 'sabado': 6, 'domingo': 7};
const _countWords = {
  'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5, 'seis': 6, 'siete': 7, 'ocho': 8, 'nueve': 9, 'diez': 10, 'once': 11, 'doce': 12, //
  'dieciocho': 18, 'veinte': 20, 'veinticuatro': 24, 'treinta': 30, 'treinta y seis': 36, 'cuarenta y ocho': 48, 'sesenta': 60,
};
const _countUnits = r'(meses|mes|cuotas|cuota|mensualidades|mensualidad|plazos|pagos)';

// ---------------------------------------------------------------- numbers and dates

/// Amount in cents, as written in Spain: «24», «24 €», «24,50», «4.378» (thousands), «1.234,56»; «24.5» is decimals.
/// Numbers that are days, months, counts of instalments or an instalment's number are not it.
int? parseAmount(String text) {
  final t = plainText(text);
  final number = RegExp(r'(\d{1,3}(?:\.\d{3})+|\d+)(?:([.,])(\d{1,2}))?(?!\d)');
  int? best;
  var bestScore = -1;
  for (final m in number.allMatches(t)) {
    final after = t.substring(m.end).trimLeft();
    final before = t.substring(0, m.start).trimRight();
    if (t.substring(m.end).startsWith('/') || before.endsWith('/')) continue; // 3/11
    if (RegExp(r'^(de\s+)?(' '${_months.keys.join('|')}' r')\b').hasMatch(after)) continue; // 3 de noviembre
    if (RegExp('^$_countUnits\\b').hasMatch(after) || RegExp(r'^(dias|semanas|anos)\b').hasMatch(after)) continue;
    if (RegExp(r'(^|\s)(cuota|plazo|mensualidad|numero|n\.?)$').hasMatch(before)) continue; // la cuota 3, n. 3
    if (RegExp(r'(^|\s)(el|dia)$').hasMatch(before) && !RegExp(r'^(€|eur\b|euros?\b)').hasMatch(after)) continue; // el 3
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

/// How many instalments: «12 meses», «doce cuotas», «en 24 mensualidades».
int? parseCount(String text) {
  final t = plainText(text);
  final digits = RegExp('(\\d{1,3})\\s*$_countUnits\\b').firstMatch(t);
  if (digits != null) return int.parse(digits.group(1)!);
  final sorted = _countWords.keys.toList()..sort((a, b) => b.length.compareTo(a.length));
  for (final w in sorted) {
    if (RegExp('\\b$w\\s+$_countUnits\\b').hasMatch(t)) return _countWords[w];
  }
  return null;
}

/// The number of an instalment named in the sentence («la cuota 3»).
int? parseInstalmentNumber(String text) {
  final m = RegExp(r'(cuota|plazo|mensualidad)\s+(numero\s+|n\.?\s*)?(\d{1,3})\b').firstMatch(plainText(text));
  return m == null ? null : int.parse(m.group(3)!);
}

/// The amount is each instalment, not the total: «cuotas de 300 €», «300 € al mes», «300 € mensuales».
bool amountIsPerInstalment(String text) {
  final t = plainText(text);
  return RegExp(r'cuotas? de \d').hasMatch(t) || RegExp(r'\d[\d.,]*\s*(€|euros?)?\s*(al mes|cada mes|por mes|mensuales|de cuota|/mes)\b').hasMatch(t);
}

/// The day a movement happened, or null («hoy» is then shown). Never in the future.
DateTime? parseDate(String text, DateTime now) {
  final f = ' ${plainText(text).replaceAll(RegExp(r'[^a-z0-9/]+'), ' ')} ';
  final today = DateTime(now.year, now.month, now.day, 12);
  if (f.contains(' anteayer ') || f.contains(' antes de ayer ')) return today.subtract(const Duration(days: 2));
  if (f.contains(' ayer ')) return today.subtract(const Duration(days: 1));
  for (final e in _weekdays.entries) {
    if (f.contains(' ${e.key} ') && !f.contains(' que viene ') && !f.contains(' proximo ')) {
      var back = (now.weekday - e.value) % 7;
      if (back == 0) back = 7;
      return today.subtract(Duration(days: back));
    }
  }
  final numeric = RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b').firstMatch(f);
  if (numeric != null) {
    final day = int.parse(numeric.group(1)!), month = int.parse(numeric.group(2)!);
    var year = numeric.group(3) == null ? now.year : int.parse(numeric.group(3)!);
    if (year < 100) year += 2000;
    var d = DateTime(year, month, day, 12);
    if (numeric.group(3) == null && d.isAfter(today)) d = DateTime(year - 1, month, day, 12);
    return d.month == month && d.day == day ? d : null;
  }
  final named = RegExp(r'\b(?:el )?(\d{1,2}) de (' '${_months.keys.join('|')}' r')\b').firstMatch(f);
  if (named != null) {
    final day = int.parse(named.group(1)!), month = _months[named.group(2)]!;
    var d = DateTime(now.year, month, day, 12);
    if (d.isAfter(today)) d = DateTime(now.year - 1, month, day, 12);
    return d.month == month ? d : null;
  }
  final dayOnly = RegExp(r'\b(?:el|dia) (\d{1,2})\b(?! de)').firstMatch(f);
  if (dayOnly != null && !RegExp(r'^\s*(€|euros?)').hasMatch(f.substring(dayOnly.end))) {
    final day = int.parse(dayOnly.group(1)!);
    var d = DateTime(now.year, now.month, day, 12);
    if (d.isAfter(today)) d = DateTime(now.year, now.month - 1, day, 12);
    return day >= 1 && day <= 31 && d.day == day ? d : null;
  }
  if (f.contains(' hoy ')) return today;
  return null;
}

/// The first due date of a plan: it may be in the past (a plan started before the app) or the future. «el 5» and
/// «el día 5» are the next 5th (shown in the preview, never hidden).
DateTime? parseDueDate(String text, DateTime now) {
  final f = ' ${plainText(text).replaceAll(RegExp(r'[^a-z0-9/]+'), ' ')} ';
  final today = DateTime(now.year, now.month, now.day, 12);
  if (f.contains(' hoy ')) return today;
  if (f.contains(' manana ')) return today.add(const Duration(days: 1));
  final numeric = RegExp(r'\b(\d{1,2})/(\d{1,2})(?:/(\d{2,4}))?\b').firstMatch(f);
  if (numeric != null) {
    final day = int.parse(numeric.group(1)!), month = int.parse(numeric.group(2)!);
    var year = numeric.group(3) == null ? now.year : int.parse(numeric.group(3)!);
    if (year < 100) year += 2000;
    final d = DateTime(year, month, day, 12);
    return d.month == month ? d : null;
  }
  final named = RegExp(r'\b(?:el )?(\d{1,2}) de (' '${_months.keys.join('|')}' r')(?: de (\d{4}))?\b').firstMatch(f);
  if (named != null) {
    final day = int.parse(named.group(1)!), month = _months[named.group(2)]!;
    final year = named.group(3) == null ? now.year : int.parse(named.group(3)!);
    final d = DateTime(year, month, day, 12);
    return d.month == month ? d : null;
  }
  final dayOnly = RegExp(r'\b(?:el|dia|los dias|cada) (\d{1,2})\b').firstMatch(f);
  if (dayOnly != null) {
    final day = int.parse(dayOnly.group(1)!);
    if (day < 1 || day > 31) return null;
    final nextMonth = f.contains(' mes que viene ') || f.contains(' proximo mes ') || f.contains(' siguiente mes ');
    var d = DateTime(now.year, now.month + (nextMonth ? 1 : 0), day, 12);
    if (!nextMonth && d.isBefore(today)) d = DateTime(now.year, now.month + 1, day, 12);
    return d.day == day ? d : null;
  }
  return null;
}

QueryPeriod? parsePeriod(String text) {
  final f = ' ${plainText(text).replaceAll(RegExp(r'[^a-z0-9]+'), ' ')} ';
  if (f.contains(' mes pasado ') || f.contains(' ultimo mes ') || f.contains(' mes anterior ')) return QueryPeriod.lastMonth;
  if (f.contains(' este mes ') || f.contains(' del mes ') || f.contains(' en el mes ') || f.contains(' lo que va de mes ')) return QueryPeriod.thisMonth;
  if (f.contains(' esta semana ') || f.contains(' la semana ')) return QueryPeriod.thisWeek;
  if (f.contains(' este ano ') || f.contains(' del ano ')) return QueryPeriod.thisYear;
  if (f.contains(' anteayer ')) return null;
  if (f.contains(' ayer ')) return QueryPeriod.yesterday;
  if (f.contains(' hoy ')) return QueryPeriod.today;
  return null;
}

// ---------------------------------------------------------------- cues

const _spend = ['gast*', 'pag*', 'compr*', 'cost*', 'cena*', 'cene', 'comid*', 'comiendo', 'desayun*', 'repost*', 'cargo', 'cargaron'];
const _earn = ['cobr*', 'ingres*', 'recib*', 'nomina', 'sueldo', 'salario', 'devolv*', 'devolucion', 'reembols*', 'bizum'];
const _reserveWords = ['reserv*', 'apart*', 'guard*', 'separ*'];
const _transferWords = ['traspas*', 'transfer*'];
const _planWords = ['plazo*', 'cuota*', 'mensualidad*', 'fraccion*', 'financ*', 'aplaz*', 'repart*', 'prestamo*'];
const _consultVerbs = ['muestra*', 'ensena*', 'dime', 'lista*', 'listado', 'busca*', 'mira*', 'saca*', 'ver', 'revisa*', 'consulta*', 'enumera*'];
const _registerVerbs = ['apunta*', 'anota*', 'registra*', 'anade*', 'mete*', 'introduce*'];
const _listNouns = ['compras', 'gastos', 'ingresos', 'movimientos', 'cosas', 'pagos', 'cargos', 'recibos', 'operaciones', 'transacciones', 'cobros'];
const _questionWords = ['que', 'cuanto', 'cuanta', 'cuantos', 'cuantas', 'cuales', 'cual', 'cuando', 'donde', 'como', 'hay'];
const _continuations = ['y', 'pero', 'no', 'solo', 'tambien', 'entonces', 'vale', 'ahora', 'e', 'o'];
const _cancelWords = ['cancela*', 'olvidalo', 'olvida', 'dejalo', 'descarta*', 'anula*'];
const _resumeWords = ['retoma*', 'sigue', 'seguir', 'continua*', 'vuelve'];

/// What the sentence says, before deciding anything.
class Signals {
  Signals(this.raw, DateTime now)
      : plain = plainText(raw),
        words = wordsOf(raw),
        amountMinor = parseAmount(raw),
        count = parseCount(raw),
        instalmentNumber = parseInstalmentNumber(raw),
        date = parseDate(raw, now),
        dueDate = parseDueDate(raw, now),
        period = parsePeriod(raw) {
    final first = words.isEmpty ? '' : words.first;
    final lead = words.skipWhile((w) => _continuations.contains(w)).firstOrNull ?? '';
    question = raw.contains('?') || raw.contains('¿') || _questionWords.contains(lead) || _phrase(plain, ['en que', 'a cuanto']);
    consult = _any(words, _consultVerbs) || _phrase(plain, ['quiero ver', 'dejame ver', 'que hay', 'que tengo']);
    register = _any(words, _registerVerbs);
    summary = _any(words, ['cuanto', 'cuanta', 'total', 'resumen', 'balance']) || _phrase(plain, ['como voy', 'que tal voy', 'como llevo', 'cuanto llevo']);
    listNoun = _any(words, _listNouns) || _phrase(plain, ['que he comprado', 'que he gastado', 'que he pagado', 'en que he gastado', 'que me he gastado', 'que cosas']);
    spend = _any(words, _spend);
    earn = _any(words, _earn) || _phrase(plain, ['me han pagado', 'me pagaron', 'me han hecho', 'me han devuelto', 'me han ingresado']);
    reserve = _any(words, _reserveWords) && !_phrase(plain, ['mis reservas', 'las reservas']);
    transfer = _any(words, _transferWords) || _phrase(plain, ['mover dinero', 'pasa dinero', 'pasar dinero']);
    plan = _any(words, _planWords) || count != null;
    pending = _phrase(plain, ['me queda', 'me quedan', 'queda por pagar', 'quedan por pagar', 'falta por pagar', 'cuanto debo', 'proxima cuota', 'cuotas pendientes', 'que debo']) ||
        _any(words, ['pendiente*']);
    paidPast = _phrase(plain, ['he pagado', 'pague', 'pagada', 'pagado', 'he abonado', 'abone', 'ya pague', 'ya he pagado']);
    simulate = _phrase(plain, ['si gasto', 'si me gasto', 'si pago', 'si compro', 'si me compro', 'como quedaria', 'que pasaria', 'puedo permitirme', 'me puedo permitir']);
    continuation = _continuations.contains(first) || plain.trimLeft().startsWith('¿y');
    correction = _phrase(plain, ['no eran', 'no era', 'no es', 'eran', 'era', 'en realidad', 'me he equivocado', 'perdona', 'mejor', 'fue', 'la fecha', 'el importe', 'la cuenta']) ||
        _any(words, ['cambia*', 'corrige*', 'categoria', 'concepto', 'llamalo', 'ponlo', 'ponla']);
    cancel = _any(words, _cancelWords) || plain.trim() == 'no' || plain.trim() == 'nada';
    resume = _any(words, _resumeWords);
  }

  final String raw, plain;
  final List<String> words;
  final int? amountMinor, count, instalmentNumber;
  final DateTime? date, dueDate;
  final QueryPeriod? period;
  late final bool question, consult, register, summary, listNoun, spend, earn, reserve, transfer, plan, pending, paidPast, simulate, continuation, correction, cancel, resume;

  /// Says something to record or to look up (not only a detail).
  bool get mainIntent => spend || earn || reserve || transfer || plan || consult || listNoun || summary || simulate || register || question;
}

// ---------------------------------------------------------------- accounts, categories, concepts

const _stop = {
  'he', 'ha', 'me', 'mi', 'mis', 'el', 'la', 'los', 'las', 'un', 'una', 'unos', 'unas', 'de', 'del', 'en', 'con', 'por', 'para', 'a', 'al', 'y', //
  'o', 'que', 'lo', 'le', 'se', 'su', 'es', 'euro', 'euros', 'eur', 'cuenta', 'tarjeta', 'hoy', 'ayer', 'anteayer', 'esta', 'este', 'mes', //
  'semana', 'ano', 'pasado', 'dinero', 'cosas', 'algo', 'banco',
};

/// Words of a name that tell it apart (not «cuenta», «tarjeta», «de»…).
List<String> _nameWords(String name) => wordsOf(name).where((w) => w.length >= 3 && !_stop.contains(w)).toList();

bool _mentions(List<String> phrase, String word) =>
    phrase.any((p) => p == word || (p.length >= 5 && word.length >= 5 && (like(p, word) || p.substring(0, 5) == word.substring(0, 5))));

class AccountChoice {
  AccountChoice(this.account, [this.card]);
  final Account account;
  final PaymentCard? card;
  String get label => card == null ? account.name : '${card!.name} · ${account.name}';
}

/// Accounts (and cards) the sentence names, best first; several with the same score are all returned (asked).
List<AccountChoice> namedAccounts(String text, Finances data, {bool Function(Account)? allowed}) {
  final phrase = wordsOf(text);
  final ok = allowed ?? (Account a) => true;
  final scored = <(AccountChoice, int)>[];
  for (final a in data.accounts.where((a) => !a.isArchived && ok(a))) {
    final score = _nameWords(a.name).where((w) => _mentions(phrase, w)).length + (a.type == AccountType.cash && _any(phrase, ['efectivo', 'metalico', 'cash']) ? 2 : 0);
    if (score > 0) scored.add((AccountChoice(a), score));
  }
  for (final c in data.cards.where((c) => !c.isArchived)) {
    final account = data.account(c.linkedAccountId);
    if (account == null || account.isArchived || !ok(account)) continue;
    final score = _nameWords(c.name).where((w) => _mentions(phrase, w)).length + (c.lastFour.isNotEmpty && text.contains(c.lastFour) ? 2 : 0);
    if (score > 0) scored.add((AccountChoice(account, c), score));
  }
  if (scored.isEmpty) return const [];
  final top = scored.map((s) => s.$2).reduce(math.max);
  final seen = <String>{};
  return [
    for (final (c, score) in scored)
      if (score == top && seen.add('${c.account.id}|${c.card?.id}')) c
  ];
}

/// A category whose name the sentence says, of the kind that fits.
Category? namedCategory(String text, Finances data, bool Function(Category) fits) {
  final phrase = wordsOf(text);
  final found = [
    for (final c in data.categories.where((c) => !c.isArchived && fits(c)))
      if (_nameWords(c.name).isNotEmpty && _nameWords(c.name).every((w) => _mentions(phrase, w))) c
  ];
  return found.length == 1 ? found.single : null;
}

/// Everyday words and the concept they give.
const _concepts = {
  'cena': 'Cena', 'cenando': 'Cena', 'cenar': 'Cena', 'cene': 'Cena', 'comida': 'Comida', 'comiendo': 'Comida', 'comer': 'Comida', //
  'almuerzo': 'Comida', 'desayuno': 'Desayuno', 'desayunando': 'Desayuno', 'cafe': 'Café', 'cafes': 'Café', 'copas': 'Copas', //
  'gasolina': 'Gasolina', 'gasoil': 'Gasolina', 'diesel': 'Gasolina', 'repostar': 'Gasolina', 'repostado': 'Gasolina', //
  'gasolinera': 'Gasolinera', 'supermercado': 'Supermercado', 'super': 'Supermercado', 'taxi': 'Taxi', 'parking': 'Aparcamiento', //
  'aparcamiento': 'Aparcamiento', 'farmacia': 'Farmacia', 'cine': 'Cine', 'regalo': 'Regalo', 'ropa': 'Ropa', 'peluqueria': 'Peluquería', //
  'nomina': 'Nómina', 'sueldo': 'Nómina', 'salario': 'Nómina', 'bizum': 'Bizum', 'devolucion': 'Devolución', 'alquiler': 'Alquiler', //
  'luz': 'Luz', 'agua': 'Agua', 'internet': 'Internet', 'gimnasio': 'Gimnasio', 'seguro': 'Seguro',
};

/// Category hints: words of a concept, the stems of category names they suggest, and whether the suggestion is
/// clear enough to propose (a fuel station sells more than fuel: it is asked, not assumed).
const _hints = <(List<String>, List<String>, bool)>[
  (['gasolina', 'gasoil', 'diesel', 'combustible', 'repost*'], ['combust', 'gasolin', 'carbur'], true),
  (['gasolinera', 'repsol', 'cepsa', 'galp', 'shell', 'petronor'], ['combust', 'gasolin', 'carbur'], false),
  (['cena', 'comida', 'restaurante', 'almuerzo', 'tapas', 'desayuno', 'cafe', 'copas'], ['restaur', 'hostel', 'comer fuera', 'bares'], true),
  (['supermercado', 'super', 'mercadona', 'carrefour', 'lidl', 'alcampo', 'eroski', 'aldi'], ['supermerc', 'alimenta', 'comestib'], true),
  (['farmacia'], ['farmac', 'salud'], true),
  (['taxi', 'uber', 'cabify', 'metro', 'autobus', 'tren', 'renfe'], ['transport', 'taxi', 'movilidad'], true),
  (['parking', 'aparcamiento'], ['aparc', 'parking', 'vehicul', 'coche'], true),
  (['ropa', 'zapatos', 'zapatillas'], ['ropa', 'moda', 'vestim'], true),
  (['cine', 'teatro', 'concierto'], ['ocio', 'cine', 'entreten'], true),
  (['nomina', 'sueldo', 'salario'], ['nomina', 'salario', 'sueldo'], true),
];

/// The concept of a movement: a known everyday word, or what follows «en», «de» or «para» (not an account, a date
/// or a number): «en la gasolinera» → «Gasolinera».
String? extractConcept(String text, Finances data) {
  final words = wordsOf(text);
  // Exact words first («gasolinera» is not «gasolina»), then with a slip.
  for (final w in words) {
    if (_concepts[w] != null) return _concepts[w];
  }
  for (final w in words) {
    for (final e in _concepts.entries) {
      if (e.key.length >= 5 && like(w, e.key)) return e.value;
    }
  }
  final accountWords = {for (final a in data.accounts) ..._nameWords(a.name), for (final c in data.cards) ..._nameWords(c.name)};
  const cut = {'con', 'en', 'de', 'del', 'desde', 'ayer', 'hoy', 'anteayer', 'esta', 'este', 'por', 'tarjeta', 'cuenta', 'el', 'la', 'y', 'que', 'para', 'al', 'a'};
  final plain = plainText(text).replaceAll(RegExp(r'[^a-z0-9 ]+'), ' ');
  for (final m in RegExp(r'\b(?:en|de|del|para|al)\s+(?:(?:la|el|los|las|un|una|unos|unas)\s+)?([a-z][a-z0-9]*(?:\s+[a-z][a-z0-9]*){0,2})').allMatches(plain)) {
    final picked = <String>[];
    for (final w in m.group(1)!.split(' ')) {
      if (cut.contains(w) || _months.containsKey(w) || _weekdays.containsKey(w)) break;
      picked.add(w);
    }
    if (picked.isEmpty || picked.any((w) => accountWords.contains(w) || _stop.contains(w) || ['euro', 'euros', 'mes', 'meses', 'cuotas'].contains(w))) continue;
    final original = text.split(RegExp(r'\s+')).where((w) => picked.contains(plainText(w).replaceAll(RegExp(r'[^a-z0-9]'), ''))).join(' ');
    return _capital(original.isEmpty ? picked.join(' ') : original);
  }
  return null;
}

/// Categories a concept suggests among the person's own (never invented), and whether it is clear.
(List<Category>, bool) hintedCategories(String concept, Finances data, bool Function(Category) fits) {
  final words = wordsOf(concept);
  bool exact(List<String> keys) => words.any((w) => keys.any((k) => k.endsWith('*') ? w.startsWith(k.substring(0, k.length - 1)) : w == k));
  final hint = _hints.where((h) => exact(h.$1)).firstOrNull ?? _hints.where((h) => _any(words, h.$1)).firstOrNull;
  for (final (_, stems, clear) in [if (hint != null) hint]) {
    final found = data.categories.where((c) => !c.isArchived && fits(c) && stems.any((s) => plainText(c.name).contains(s))).toList();
    if (found.isNotEmpty) return (found, clear && found.length == 1);
  }
  return (const [], false);
}

// ---------------------------------------------------------------- the intent (shared with a future model)

/// What a sentence asks for, closed. A model in phase 2 would return exactly this, validated by `fromJson` against
/// `assistantIntentSchema`: it never sees the database and never writes.
class AssistantIntent {
  AssistantIntent({required this.kind, this.amountMinor, this.count, this.date, this.period, this.concept, this.purpose, this.accountText, this.categoryText});
  final IntentKind kind;
  final int? amountMinor, count;
  final DateTime? date;
  final QueryPeriod? period;
  final String? concept, purpose, accountText, categoryText;

  static AssistantIntent? fromJson(Object? json) {
    if (json is! Map) return null;
    final allowed = (assistantIntentSchema['properties'] as Map).keys.toSet();
    if (json.keys.any((k) => !allowed.contains(k))) return null;
    final kind = IntentKind.values.where((k) => k.name == json['kind']).firstOrNull;
    if (kind == null) return null;
    int? cents(Object? v) => v is int && v > 0 && v < 100000000000 ? v : null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty && v.length <= 120 ? v.trim() : null;
    final count = json['count'];
    return AssistantIntent(
      kind: kind,
      amountMinor: cents(json['amountMinor']),
      count: count is int && count >= 1 && count <= 600 ? count : null,
      date: json['date'] is String ? DateTime.tryParse(json['date'] as String) : null,
      period: QueryPeriod.values.where((p) => p.name == json['period']).firstOrNull,
      concept: text(json['concept']),
      purpose: text(json['purpose']),
      accountText: text(json['accountText']),
      categoryText: text(json['categoryText']),
    );
  }
}

/// The JSON schema a model must fill (phase 2): only these fields, only these values.
const assistantIntentSchema = <String, Object>{
  'type': 'object',
  'additionalProperties': false,
  'required': ['kind'],
  'properties': {
    'kind': {
      'type': 'string',
      'enum': ['expense', 'income', 'reserve', 'listMovements', 'summary', 'createPlan', 'payInstalment', 'planStatus', 'simulation', 'transfer', 'unknown']
    },
    'amountMinor': {'type': 'integer', 'minimum': 1},
    'count': {'type': 'integer', 'minimum': 1, 'maximum': 600},
    'date': {'type': 'string', 'description': 'YYYY-MM-DD'},
    'period': {
      'type': 'string',
      'enum': ['today', 'yesterday', 'thisWeek', 'thisMonth', 'lastMonth', 'thisYear']
    },
    'concept': {'type': 'string', 'maxLength': 120},
    'purpose': {'type': 'string', 'maxLength': 120},
    'accountText': {'type': 'string', 'maxLength': 120},
    'categoryText': {'type': 'string', 'maxLength': 120},
  },
};

// ---------------------------------------------------------------- replies

enum PendingField { kind, amount, account, purpose, category, count, planKind, planName, dueDate, recorded, plan }

sealed class AssistantReply {
  /// Said before the reply: a draft set aside, so nothing is lost or answered silently.
  String? note;
}

class AssistantQuestion extends AssistantReply {
  AssistantQuestion(this.text, this.field, [this.options = const []]);
  final String text;

  /// The draft field asked for, or null for a question about a query.
  final PendingField? field;
  final List<(String, String)> options;
}

enum PreviewKind { movement, reserve, plan, instalment }

class AssistantPreview extends AssistantReply {
  AssistantPreview({
    required this.id,
    required this.kind,
    required this.title,
    required this.lines,
    required this.effects,
    required this.operation,
    this.warnings = const [],
    this.calendar = const [],
    this.draft,
    this.reserve,
    this.plan,
    this.proposal,
  });

  /// The id of the new record: confirming twice can never create two. A corrected preview keeps it.
  final String id;
  final PreviewKind kind;
  final String title;
  final List<(String, String)> lines;
  final List<String> effects;
  final List<String> warnings;

  /// A plan's instalments (date, amount), shown before saving.
  final List<(DateTime, int)> calendar;
  final Operation operation;

  /// What «Corregir» opens the form with.
  final TransactionDraft? draft;
  final ({String name, int amountMinor, String accountId})? reserve;
  final InstallmentPlan? plan;

  /// The category proposed and its source, so a confirmed choice teaches the personal learning.
  final ({String categoryName, String source})? proposal;
}

class AssistantResult extends AssistantReply {
  AssistantResult(this.title, this.lines, {this.transactions = const [], this.totalMinor, this.planId});
  final String title;
  final List<String> lines;
  final List<Transaction> transactions;
  final int? totalMinor;

  /// A plan to open from the result.
  final String? planId;
}

class AssistantPointer extends AssistantReply {
  AssistantPointer(this.text, this.kind);
  final String text;
  final IntentKind kind;
}

class AssistantMessage extends AssistantReply {
  AssistantMessage(this.text);
  final String text;
}

// ---------------------------------------------------------------- the conversation

class _Draft {
  _Draft(this.kind);
  IntentKind kind;
  int? amountMinor, count, instalmentNumber;
  bool perInstalment = false;
  DateTime? date, dueDate;
  String? concept, purpose, accountId, categoryId, planName, planId;
  InstallmentKind? planKind;
  bool? recorded;
  bool categoryDecided = false;
  ({String categoryName, String source})? proposal;
  List<AccountChoice>? accountOptions;
  PendingField? pending;
  String? previewId;
  AssistantPreview? preview;

  String describe() => switch (kind) {
        IntentKind.reserve => 'la reserva${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
        IntentKind.createPlan => 'el pago a plazos${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
        IntentKind.payInstalment => 'el pago de la cuota',
        IntentKind.income => 'el ingreso${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
        _ => 'el gasto${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
      };
}

typedef _LastQuery = ({IntentKind kind, QueryPeriod period, QueryScope scope, String? categoryId, String? accountId});

/// One conversation: the draft being prepared, a draft set aside, the last query (for continuations) and the ids
/// already applied (a preview is applied once).
class AssistantSession {
  AssistantSession({required this.newId, this.propose});
  final String Function() newId;

  /// The category the personal learning proposes for a concept (`Learning.categoryProposal`): (id, source).
  final Future<(String, String)?> Function(String text, TransactionType type)? propose;

  _Draft? _draft;
  _Draft? _parked;
  _LastQuery? _last;
  bool? _comprasIsCategory;
  ({QueryPeriod period, String? accountId})? _scopeWaiting;
  final applied = <String>{};

  bool get hasDraft => _draft != null;
  bool get hasParked => _parked != null;

  void cancel() => _draft = null;

  /// What the person wrote: an answer, a correction, a continuation or a new request.
  Future<AssistantReply> say(String text, FinanceCalculator calc, DateTime now, {int heldMinor = 0}) async {
    final s = Signals(text, now);
    final data = calc.data;
    final draft = _draft;
    if (draft != null && s.cancel && !s.mainIntent) {
      _draft = null;
      return AssistantMessage('Cancelado: no se ha guardado nada.');
    }
    // The answer to the question asked, or a correction of the draft; a new subject is never taken as either.
    if (draft != null) {
      final newSubject = s.mainIntent && !s.correction;
      // A question or a request to see is never the answer to «¿Con qué cuenta?».
      final asking = s.question || s.consult || s.summary || s.listNoun || s.simulate || s.transfer || s.reserve != (draft.kind == IntentKind.reserve) && s.reserve ||
          (s.plan && draft.kind != IntentKind.createPlan && draft.kind != IntentKind.payInstalment);
      if (draft.pending != null && !asking && _fill(draft, draft.pending!, s, data, now)) return _next(calc, now, heldMinor);
      if (!newSubject && _correct(draft, s, data, now)) return _next(calc, now, heldMinor);
    }
    if (_scopeWaiting != null) {
      final choice = _any(s.words, ['categoria', 'solo']) ? true : (_any(s.words, ['todos', 'todo', 'todas']) ? false : null);
      if (choice != null) return _scopeChosen(choice, calc, now);
    }
    if (s.resume && _parked != null && !s.mainIntent) {
      _draft = _parked
        ?..pending = null
        ..preview = null;
      _parked = null;
      return _next(calc, now, heldMinor);
    }
    final kind = _decide(s, data);
    String? note;
    if (draft != null) {
      _parked = draft;
      _draft = null;
      note = 'Dejo aparte ${draft.describe()} sin guardar. Escribe «retómalo» para seguir con él.';
    }
    final reply = await _start(kind, s, calc, now, heldMinor);
    reply.note ??= note;
    return reply;
  }

  /// A tapped option of the last question.
  Future<AssistantReply> choose(String value, FinanceCalculator calc, DateTime now, {int heldMinor = 0}) async {
    if (_scopeWaiting != null && value.startsWith('scope:')) return _scopeChosen(value == 'scope:category', calc, now);
    final draft = _draft;
    if (draft == null || draft.pending == null) return AssistantMessage('Eso ya no está pendiente. ¿Qué quieres apuntar o consultar?');
    switch (draft.pending!) {
      case PendingField.kind:
        draft.kind = IntentKind.values.byName(value);
      case PendingField.account:
        draft.accountId = value;
      case PendingField.category:
        draft.categoryId = value == 'none' ? null : value;
        draft.categoryDecided = true;
        draft.proposal = null;
      case PendingField.planKind:
        draft.planKind = InstallmentKind.values.byName(value);
      case PendingField.recorded:
        draft.recorded = value == 'yes';
      case PendingField.plan:
        draft.planId = value;
      case PendingField.amount || PendingField.purpose || PendingField.count || PendingField.planName || PendingField.dueDate:
        break;
    }
    draft.pending = null;
    return _next(calc, now, heldMinor);
  }

  Future<AssistantReply> _scopeChosen(bool category, FinanceCalculator calc, DateTime now) async {
    _comprasIsCategory = category;
    final w = _scopeWaiting!;
    _scopeWaiting = null;
    return _list(calc, now, period: w.period, income: false, accountId: w.accountId, compras: true);
  }

  IntentKind _decide(Signals s, Finances data) {
    final plans = data.installmentPlans.where((p) => !p.isArchived).toList();
    if (s.plan || (s.pending && plans.isNotEmpty)) {
      if (s.pending || (s.question && s.amountMinor == null && s.count == null)) return IntentKind.planStatus;
      if (s.paidPast && s.count == null && _any(s.words, ['cuota*', 'plazo*', 'mensualidad*'])) return IntentKind.payInstalment;
      return IntentKind.createPlan;
    }
    if (s.simulate) return IntentKind.simulation;
    if (s.transfer) return IntentKind.transfer;
    final query = (s.question || s.consult || s.summary) && !s.register && !(s.amountMinor != null && !s.question && !s.consult);
    if (query) return s.summary && !s.consult && !_phrase(s.plain, ['que cosas', 'que he', 'en que']) ? IntentKind.summary : IntentKind.listMovements;
    if (s.reserve) return IntentKind.reserve;
    // A statement in the past without amount and with a period asks about it («he comprado cosas este mes»).
    if (s.amountMinor == null && s.period != null && (s.spend || s.earn || s.listNoun) && !s.register) return IntentKind.listMovements;
    if (s.earn && !s.spend) return IntentKind.income;
    if (s.spend) return IntentKind.expense;
    if (s.earn) return IntentKind.income;
    if (s.listNoun && _last != null) return IntentKind.listMovements;
    if (_last != null && (s.continuation || s.period != null || namedCategory(s.raw, data, (_) => true) != null)) return _last!.kind;
    return IntentKind.unknown;
  }

  Future<AssistantReply> _start(IntentKind kind, Signals s, FinanceCalculator calc, DateTime now, int heldMinor) async {
    final data = calc.data;
    switch (kind) {
      case IntentKind.unknown:
        if (s.amountMinor != null) {
          _draft = _Draft(IntentKind.unknown)
            ..amountMinor = s.amountMinor
            ..date = s.date
            ..concept = extractConcept(s.raw, data);
          return _next(calc, now, heldMinor);
        }
        return AssistantMessage('No lo he entendido. Puedo apuntar gastos e ingresos («He gastado 24 € en la gasolinera»), reservar dinero '
            '(«Reserva 200 € para vacaciones»), preparar un pago a plazos («4.378 € en 12 meses»), apuntar una cuota pagada o enseñarte '
            'movimientos y resúmenes («¿Qué he comprado este mes?»).');
      case IntentKind.simulation:
        return AssistantPointer('Las simulaciones aún no se hacen desde el chat. En la previsión puedes simular un gasto sin apuntarlo.', kind);
      case IntentKind.transfer:
        return AssistantPointer('Los traspasos aún no se preparan desde el chat: ábrelo en su formulario. Apuntarlo no mueve dinero en el banco.', kind);
      case IntentKind.listMovements:
      case IntentKind.summary:
        return _query(kind, s, calc, now);
      case IntentKind.planStatus:
        return _planStatus(s, data, now);
      case IntentKind.expense:
      case IntentKind.income:
      case IntentKind.reserve:
      case IntentKind.createPlan:
      case IntentKind.payInstalment:
        final d = _draft = _Draft(kind)
          ..amountMinor = s.amountMinor
          ..date = s.date
          ..concept = extractConcept(s.raw, data);
        if (kind == IntentKind.reserve) d.purpose = _purpose(s.raw);
        if (kind == IntentKind.createPlan) {
          d.count = s.count;
          d.perInstalment = amountIsPerInstalment(s.raw);
          d.dueDate = _planDueDate(s);
          d.planKind = _planKind(s);
          d.planName = _purpose(s.raw);
          d.date = null;
        }
        if (kind == IntentKind.payInstalment) {
          d.instalmentNumber = s.instalmentNumber;
          d.planId = _namedPlan(s.raw, data)?.id;
          if (d.amountMinor == null || !RegExp(r'(€|euros?)').hasMatch(s.plain)) d.amountMinor = null;
        }
        final named = namedAccounts(s.raw, data, allowed: kind == IntentKind.reserve ? _reservable : null);
        if (named.length == 1) d.accountId = named.single.account.id;
        if (named.length > 1) d.accountOptions = named;
        if (kind == IntentKind.expense || kind == IntentKind.income) {
          final type = kind == IntentKind.income ? TransactionType.income : TransactionType.expense;
          final category = namedCategory(s.raw, data, (c) => categorySupports(c, type));
          if (category != null) {
            d.categoryId = category.id;
            d.categoryDecided = true;
          }
        }
        return _next(calc, now, heldMinor);
    }
  }

  static bool _reservable(Account a) => a.type != AccountType.investment && !a.type.isLiability;

  String? _purpose(String raw) {
    final cleaned = plainText(raw).replaceAll(RegExp(r'[^a-z ,.;]+'), ' ').replaceAll(RegExp(r' +'), ' ').trim();
    final m = RegExp(r'\bpara (?:las |los |el |la |mis |unas |unos |un |una )?([a-z][a-z ]*?)(?:[,.;]| en | de la | desde | con | primera | que | y |$)')
        .firstMatch(cleaned);
    final value = m?.group(1)?.trim();
    return value == null || value.isEmpty ? null : _capital(value);
  }

  DateTime? _planDueDate(Signals s) {
    // Only a date said for the first instalment, never one inferred from «12 meses».
    if (!RegExp(r'(primera|empieza|empezando|desde|a partir|vence|el dia|el \d|\d/\d|\d de (' '${_months.keys.join('|')}' r'))').hasMatch(s.plain)) return null;
    return s.dueDate;
  }

  InstallmentKind? _planKind(Signals s) {
    if (_any(s.words, ['prestamo*', 'credito', 'financiacion'])) return InstallmentKind.loan;
    if (_phrase(s.plain, ['compra a plazos', 'compra fraccionada', 'he comprado', 'compre', 'una compra'])) return InstallmentKind.purchase;
    return null;
  }

  InstallmentPlan? _namedPlan(String raw, Finances data) {
    final phrase = wordsOf(raw);
    final found = [
      for (final p in data.installmentPlans.where((p) => !p.isArchived))
        if (_nameWords(p.name).any((w) => _mentions(phrase, w))) p
    ];
    return found.length == 1 ? found.single : null;
  }

  bool _fill(_Draft d, PendingField field, Signals s, Finances data, DateTime now) {
    switch (field) {
      case PendingField.amount:
        if (s.amountMinor == null) return false;
        d.amountMinor = s.amountMinor;
        if (d.kind == IntentKind.createPlan) {
          d.perInstalment = amountIsPerInstalment(s.raw);
          d.count ??= s.count;
        }
      case PendingField.count:
        final n = s.count ?? int.tryParse(s.plain.trim());
        if (n == null || n < 1 || n > 600) return false;
        d.count = n;
      case PendingField.purpose:
        if (s.words.isEmpty || s.question) return false;
        d.purpose = _purpose(s.raw) ?? _capital(s.raw.trim());
      case PendingField.planName:
        if (s.words.isEmpty || s.question) return false;
        d.planName = _capital(s.raw.trim());
      case PendingField.dueDate:
        if (s.dueDate == null) return false;
        d.dueDate = s.dueDate;
      case PendingField.kind:
        if (s.spend) {
          d.kind = IntentKind.expense;
        } else if (s.earn) {
          d.kind = IntentKind.income;
        } else {
          return false;
        }
      case PendingField.planKind:
        if (_any(s.words, ['prestamo*'])) {
          d.planKind = InstallmentKind.loan;
        } else if (_any(s.words, ['compra*'])) {
          d.planKind = InstallmentKind.purchase;
        } else if (_any(s.words, ['otro', 'otra'])) {
          d.planKind = InstallmentKind.other;
        } else {
          return false;
        }
      case PendingField.recorded:
        if (_any(s.words, ['si', 'ya', 'apuntada', 'apuntado'])) {
          d.recorded = true;
        } else if (_any(s.words, ['no', 'todavia', 'aun'])) {
          d.recorded = false;
        } else {
          return false;
        }
      case PendingField.account:
        final named = namedAccounts(s.raw, data, allowed: d.kind == IntentKind.reserve ? _reservable : null);
        if (named.isEmpty) return false;
        if (named.length > 1) {
          d.accountOptions = named;
        } else {
          d.accountId = named.single.account.id;
          d.accountOptions = null;
        }
      case PendingField.category:
        if (_phrase(s.plain, ['sin categoria', 'ninguna', 'ninguno'])) {
          d.categoryId = null;
        } else {
          final type = d.kind == IntentKind.income ? TransactionType.income : TransactionType.expense;
          final c = namedCategory(s.raw, data, (c) => categorySupports(c, type));
          if (c == null) return false;
          d.categoryId = c.id;
        }
        d.categoryDecided = true;
        d.proposal = null;
      case PendingField.plan:
        final p = _namedPlan(s.raw, data);
        if (p == null) return false;
        d.planId = p.id;
    }
    d.pending = null;
    return true;
  }

  /// A change to a draft already shown or being prepared: amount, date, account, category, concept, count.
  bool _correct(_Draft d, Signals s, Finances data, DateTime now) {
    var changed = false;
    if (s.amountMinor != null && s.amountMinor != d.amountMinor) {
      d.amountMinor = s.amountMinor;
      if (d.kind == IntentKind.createPlan) d.perInstalment = amountIsPerInstalment(s.raw);
      changed = true;
    }
    if (d.kind == IntentKind.createPlan) {
      if (s.count != null && s.count != d.count) {
        d.count = s.count;
        changed = true;
      }
      if (s.dueDate != null && s.dueDate != d.dueDate) {
        d.dueDate = s.dueDate;
        changed = true;
      }
      final kind = _planKind(s);
      if (kind != null && kind != d.planKind) {
        d.planKind = kind;
        changed = true;
      }
    } else if (s.date != null && s.date != d.date) {
      d.date = s.date;
      changed = true;
    }
    final named = namedAccounts(s.raw, data, allowed: d.kind == IntentKind.reserve ? _reservable : null);
    if (named.length == 1 && named.single.account.id != d.accountId) {
      d.accountId = named.single.account.id;
      changed = true;
    } else if (named.length > 1) {
      d.accountId = null;
      d.accountOptions = named;
      changed = true;
    }
    if (d.kind == IntentKind.expense || d.kind == IntentKind.income) {
      final type = d.kind == IntentKind.income ? TransactionType.income : TransactionType.expense;
      if (_phrase(s.plain, ['sin categoria'])) {
        d.categoryId = null;
        d.categoryDecided = true;
        d.proposal = null;
        changed = true;
      } else {
        final c = namedCategory(s.raw, data, (c) => categorySupports(c, type));
        if (c != null && c.id != d.categoryId) {
          d.categoryId = c.id;
          d.categoryDecided = true;
          d.proposal = null;
          changed = true;
        }
      }
      final concept = RegExp(r'(?:concepto|llamalo|ponle)\s*:?\s*(.+)$').firstMatch(plainText(s.raw));
      if (concept != null) {
        d.concept = _capital(s.raw.substring(s.raw.length - concept.group(1)!.length).trim());
        changed = true;
      }
    }
    if (changed) d.pending = null;
    return changed;
  }

  AssistantQuestion _ask(_Draft d, PendingField field, String text, [List<(String, String)> options = const []]) {
    d.pending = field;
    return AssistantQuestion(text, field, options);
  }

  Future<AssistantReply> _next(FinanceCalculator calc, DateTime now, int heldMinor) async {
    final d = _draft!;
    final data = calc.data;
    switch (d.kind) {
      case IntentKind.unknown:
        return _ask(d, PendingField.kind, '¿Es un gasto o un ingreso de ${money(d.amountMinor!)}?',
            [('Gasto', IntentKind.expense.name), ('Ingreso', IntentKind.income.name)]);
      case IntentKind.createPlan:
        return _nextPlan(d, calc, now);
      case IntentKind.payInstalment:
        return _nextInstalment(d, calc, now);
      default:
        break;
    }
    final reserve = d.kind == IntentKind.reserve;
    if (d.amountMinor == null) {
      return _ask(d, PendingField.amount, reserve ? '¿Cuánto quieres reservar?' : '¿De cuánto ha sido el ${d.kind == IntentKind.income ? 'ingreso' : 'gasto'}?');
    }
    if (reserve && (d.purpose == null || d.purpose!.isEmpty)) return _ask(d, PendingField.purpose, '¿Para qué es la reserva?');
    final account = _account(d, data, reserve ? _reservable : (Account a) => true, reserve ? '¿En qué cuenta lo reservo?' : '¿Con qué cuenta o tarjeta?');
    if (account is AssistantReply) return account;
    if (reserve) return _reservePreview(d, calc, now, heldMinor);
    // The category: named, a rule of the person's, the personal learning, a clear hint; asked when it is not clear.
    final type = d.kind == IntentKind.income ? TransactionType.income : TransactionType.expense;
    if (!d.categoryDecided) {
      d.categoryDecided = true;
      final concept = d.concept;
      if (concept != null) {
        final rule = matchRule(concept, type, data);
        final learnt = rule == null && propose != null ? await propose!(concept, type) : null;
        if (rule != null) {
          d.categoryId = rule.id;
          d.proposal = (categoryName: rule.name, source: 'rule');
        } else if (learnt != null && data.category(learnt.$1) != null) {
          d.categoryId = learnt.$1;
          d.proposal = (categoryName: data.category(learnt.$1)!.name, source: learnt.$2);
        } else {
          final (found, clear) = hintedCategories(concept, data, (c) => categorySupports(c, type));
          if (clear) {
            d.categoryId = found.single.id;
            d.proposal = (categoryName: found.single.name, source: 'hint');
          } else if (found.isNotEmpty) {
            return _ask(d, PendingField.category, '¿En qué categoría lo pongo?', [
              for (final c in found.take(4)) (c.name, c.id),
              for (final c in data.categories.where((c) => !c.isArchived && categorySupports(c, type) && !found.contains(c)).take(4)) (c.name, c.id),
              ('Sin categoría', 'none'),
            ]);
          }
        }
      }
    }
    return _movementPreview(d, calc, now, heldMinor);
  }

  /// The account of the draft, or the question for it. Never guessed among several.
  Object _account(_Draft d, Finances data, bool Function(Account) allowed, String question) {
    if (d.accountId != null && data.account(d.accountId) != null) return data.account(d.accountId)!;
    final options = d.accountOptions;
    final active = data.accounts.where((a) => !a.isArchived && allowed(a)).toList();
    if (options == null && active.length == 1) {
      d.accountId = active.single.id;
      return active.single;
    }
    if (active.isEmpty) {
      _draft = null;
      return AssistantMessage('Primero necesitas una cuenta. Créala en Cuentas › «Añadir cuenta».');
    }
    final choices = options ?? [for (final a in active) AccountChoice(a)];
    d.accountOptions = null;
    return _ask(d, PendingField.account, options != null ? 'Tienes ${options.length} que encajan. ¿Cuál es?' : question,
        [for (final c in choices.take(8)) (c.label, c.account.id)]);
  }

  String _when(DateTime date, DateTime now) {
    final today = DateTime(now.year, now.month, now.day);
    final day = DateTime(date.year, date.month, date.day);
    if (day == today) return 'hoy, ${date.day}/${date.month}';
    if (day == today.subtract(const Duration(days: 1))) return 'ayer, ${date.day}/${date.month}';
    return '${date.day}/${date.month}/${date.year}';
  }

  AssistantReply _reservePreview(_Draft d, FinanceCalculator calc, DateTime now, int heldMinor) {
    final account = calc.data.account(d.accountId)!;
    final amount = d.amountMinor!;
    final free = calc.balance(account) - calc.reservedAmount(account);
    final id = d.previewId ??= newId();
    final stamp = referenceSeconds(now);
    // «Disponible» as on Inicio and Cuentas: what can be spent, minus what the bank holds.
    final available = calc.spendableCash() + heldMinor;
    return d.preview = AssistantPreview(
      id: id,
      kind: PreviewKind.reserve,
      title: 'Reserva · ${money(amount)}',
      lines: [('Para', d.purpose!), ('Cuenta', account.name), ('Importe', money(amount))],
      effects: [
        'Libre en ${account.name}: ${money(free)} → ${money(free - amount)}',
        if (account.includeInNetWorth) 'Tu disponible: ${money(available)} → ${money(available - amount)}',
        'El dinero no se mueve: queda apartado en la misma cuenta.',
      ],
      warnings: [if (amount > free) 'Es más de lo que tienes libre en esa cuenta.'],
      operation: upsertOperation(
          'reservedFunds', {'id': id, 'name': d.purpose!, 'amountMinor': amount, 'notes': '', 'createdAt': stamp, 'updatedAt': stamp, 'accountID': account.id},
          create: true),
      reserve: (name: d.purpose!, amountMinor: amount, accountId: account.id),
    );
  }

  AssistantReply _movementPreview(_Draft d, FinanceCalculator calc, DateTime now, int heldMinor) {
    final data = calc.data;
    final account = data.account(d.accountId)!;
    final type = d.kind == IntentKind.income ? TransactionType.income : TransactionType.expense;
    final concept = d.concept ?? (type == TransactionType.income ? 'Ingreso' : 'Gasto');
    final category = data.category(d.categoryId);
    final date = d.date ?? now;
    final draft = TransactionDraft(date: date, type: type, amountMinor: d.amountMinor!, description: concept, sourceAccountId: account.id, categoryId: category?.id);
    final problem = draft.validate(data);
    if (problem != null) {
      _draft = null;
      return AssistantMessage('No puedo prepararlo: $problem');
    }
    final amount = d.amountMinor!;
    final sign = type == TransactionType.income ? 1 : -1;
    final balance = calc.balance(account);
    final counts = account.includeInNetWorth && account.type != AccountType.investment && !account.type.isLiability;
    final today = DateTime(now.year, now.month, now.day);
    final budget =
        category == null ? null : calc.budgetProgress(DateTime(date.year, date.month)).where((b) => b.category.id == category.id && b.limitMinor > 0).firstOrNull;
    final duplicates = duplicateCandidates(
        date: date,
        source: account.id,
        destination: null,
        type: type,
        amountMinor: amount,
        description: concept,
        existing: data.transactions,
        fingerprints: {for (final t in data.transactions) t.id: t.fingerprint});
    final id = d.previewId ??= newId();
    final available = calc.spendableCash() + heldMinor;
    return d.preview = AssistantPreview(
      id: id,
      kind: PreviewKind.movement,
      title: '${type == TransactionType.income ? 'Ingreso' : 'Gasto'} · ${money(amount)}',
      lines: [
        ('Concepto', concept),
        ('Cuenta', account.name),
        ('Categoría', category == null ? 'Sin categoría' : '${category.name}${d.proposal == null ? '' : ' (propuesta)'}'),
        ('Fecha', _when(date, now)),
      ],
      effects: [
        'Saldo de ${account.name}: ${money(balance)} → ${money(balance + sign * amount)}',
        if (counts && !DateTime(date.year, date.month, date.day).isAfter(today)) 'Tu disponible: ${money(available)} → ${money(available + sign * amount)}',
        if (budget != null && type == TransactionType.expense)
          'Presupuesto de ${category!.name}: ${money(budget.spentMinor)} → ${money(budget.spentMinor + amount)} de ${money(budget.limitMinor)}',
        'Para corregir un dato, escríbelo: «eran 45 €», «fue ayer», «categoría Ocio».',
      ],
      warnings: [if (duplicates.isNotEmpty) 'Ya hay un movimiento igual ese día: comprueba que no lo hayas apuntado ya.'],
      operation: saveOperation(draft, data, now, newId: id),
      draft: draft,
      proposal: d.proposal,
    );
  }

  Future<AssistantReply> _nextPlan(_Draft d, FinanceCalculator calc, DateTime now) async {
    final data = calc.data;
    if (d.amountMinor == null) return _ask(d, PendingField.amount, '¿Cuánto es el total que vas a pagar (con intereses y comisiones si los hay)?');
    if (d.count == null) return _ask(d, PendingField.count, '¿En cuántas cuotas mensuales?');
    if (d.planKind == null) return _ask(d, PendingField.planKind, '¿Qué es?', [for (final k in InstallmentKind.values) (k.title, k.name)]);
    if (d.planName == null || d.planName!.isEmpty) return _ask(d, PendingField.planName, '¿Cómo lo llamo? (por ejemplo, «Sofá» o «Préstamo del coche»)');
    if (d.dueDate == null) return _ask(d, PendingField.dueDate, '¿Cuándo vence la primera cuota? (por ejemplo, «el 5 de diciembre»)');
    final account = _account(d, data, (a) => true, '¿Desde qué cuenta se pagan las cuotas?');
    if (account is AssistantReply) return account;
    if (d.recorded == null) {
      final what = switch (d.planKind!) {
        InstallmentKind.loan => '¿Ya apuntaste en Doblón el dinero del préstamo que recibiste?',
        InstallmentKind.other => '¿Ya apuntaste en Doblón el gasto completo?',
        InstallmentKind.purchase => '¿Ya apuntaste en Doblón la compra completa?',
      };
      return _ask(d, PendingField.recorded, what, [('Sí, ya está', 'yes'), ('No', 'no')]);
    }
    final total = d.perInstalment ? d.amountMinor! * d.count! : d.amountMinor!;
    final schedule = buildSchedule(total, d.count!, d.dueDate!, agreedMinor: d.perInstalment ? d.amountMinor : null);
    if (schedule == null) {
      d.amountMinor = null;
      return _ask(d, PendingField.amount, 'Con esas cifras las cuotas no cuadran. ¿Cuál es el total?');
    }
    final id = d.previewId ??= newId();
    final plan = InstallmentPlan(
      id: id,
      name: d.planName!,
      kind: d.planKind!,
      totalMinor: total,
      schedule: schedule,
      accountId: (account as Account).id,
      agreedInstallmentMinor: d.perInstalment ? d.amountMinor : null,
      alreadyRecorded: d.recorded!,
    );
    final amounts = schedule.map((i) => i.amountMinor).toList();
    final split = amounts.length == 1
        ? money(amounts.single)
        : amounts.last != amounts.first
            ? '${amounts.length - 1} × ${money(amounts.first)} y la última de ${money(amounts.last)}'
            : '${amounts.length} × ${money(amounts.first)}';
    return d.preview = AssistantPreview(
      id: id,
      kind: PreviewKind.plan,
      title: '${d.planKind!.title} · ${money(total)}',
      lines: [
        ('Nombre', d.planName!),
        ('Total', '${money(total)}${d.perInstalment ? ' (${d.count} cuotas de ${money(d.amountMinor!)})' : ''}'),
        ('Cuotas', split),
        ('Primera', _when(schedule.first.dueDate, now)),
        ('Última', _when(schedule.last.dueDate, now)),
        ('Cuenta', account.name),
      ],
      effects: ['Hoy no se registra ningún pago: cada cuota se apunta cuando la pagas.', installmentEffect(plan)],
      calendar: [for (final i in schedule) (i.dueDate, i.amountMinor)],
      operation: savePlanOperation(plan: plan, create: true, data: data, now: now),
      plan: plan,
    );
  }

  Future<AssistantReply> _nextInstalment(_Draft d, FinanceCalculator calc, DateTime now) async {
    final data = calc.data;
    final plans = data.installmentPlans.where((p) => !p.isArchived).toList();
    if (plans.isEmpty) {
      _draft = null;
      return AssistantPointer('No tienes ningún pago a plazos. Puedes crearlo diciendo el total y las cuotas, o desde su pantalla.', IntentKind.createPlan);
    }
    if (d.planId == null && plans.length == 1) d.planId = plans.single.id;
    if (d.planId == null) return _ask(d, PendingField.plan, '¿De qué pago a plazos es la cuota?', [for (final p in plans) (p.name, p.id)]);
    final plan = plans.firstWhere((p) => p.id == d.planId);
    final progress = installmentProgress(plan, data, now);
    final state = d.instalmentNumber == null ? progress.next : progress.states.where((s) => s.number == d.instalmentNumber && s.isOpen).firstOrNull;
    if (state == null) {
      _draft = null;
      return AssistantMessage(d.instalmentNumber == null ? '«${plan.name}» ya está pagado entero.' : 'La cuota ${d.instalmentNumber} de «${plan.name}» no está pendiente.');
    }
    final amount = d.amountMinor ?? state.installment.amountMinor;
    final date = d.date ?? now;
    final account = data.account(plan.accountId);
    if (account == null) {
      _draft = null;
      return AssistantMessage('Ese pago a plazos no tiene cuenta: complétalo en su pantalla.');
    }
    final id = d.previewId ??= newId();
    final balance = calc.balance(account);
    return d.preview = AssistantPreview(
      id: id,
      kind: PreviewKind.instalment,
      title: 'Cuota ${state.number}/${plan.count} · ${money(amount)}',
      lines: [
        ('Plan', plan.name),
        ('Cuota', '${state.number} de ${plan.count}, vence ${_when(state.installment.dueDate, now)}'),
        ('Importe', money(amount)),
        ('Fecha', _when(date, now)),
        ('Cuenta', account.name),
      ],
      effects: [
        'Pendiente del plan: ${money(progress.pendingMinor)} → ${money(math.max(0, progress.pendingMinor - amount))}',
        'Saldo de ${account.name}: ${money(balance)} → ${money(balance - amount)}',
        if (plan.alreadyRecorded) 'La compra ya estaba apuntada: esta cuota no cuenta otra vez como gasto.',
      ],
      warnings: [
        if (amount != state.installment.amountMinor)
          'Es distinto de la cuota prevista (${money(state.installment.amountMinor)}): luego podrás ajustar el calendario del plan.'
      ],
      operation: paymentOperation(plan, state.number, amount, date, now, id),
    );
  }

  AssistantReply _planStatus(Signals s, Finances data, DateTime now) {
    final plans = data.installmentPlans.where((p) => !p.isArchived).toList();
    if (plans.isEmpty) return AssistantPointer('No tienes pagos a plazos. Puedes crearlo diciendo el total y las cuotas, o desde su pantalla.', IntentKind.createPlan);
    final named = _namedPlan(s.raw, data);
    final shown = named == null ? plans : [named];
    final lines = <String>[];
    var pending = 0;
    for (final p in shown) {
      final progress = installmentProgress(p, data, now);
      pending += progress.pendingMinor;
      final next = progress.next;
      lines.add('${p.name}: quedan ${money(progress.pendingMinor)} · ${progress.paidCount}/${p.count} pagadas'
          '${next == null ? ' · terminado' : ' · próxima ${money(next.installment.amountMinor)} el ${next.installment.dueDate.day}/${next.installment.dueDate.month}'}');
    }
    return AssistantResult(named == null ? 'Pagos a plazos · quedan ${money(pending)}' : named.name, lines, planId: named?.id);
  }

  Future<AssistantReply> _query(IntentKind kind, Signals s, FinanceCalculator calc, DateTime now) async {
    final data = calc.data;
    final follows = s.continuation || s.period == null;
    final last = follows ? _last : null;
    final period = s.period ?? last?.period ?? QueryPeriod.thisMonth;
    final saysIncome = _any(s.words, ['ingresos', 'cobros', 'ingres*', 'cobr*']);
    final saysExpense = _any(s.words, ['gast*', 'compr*', 'pag*']);
    final income = saysIncome && !saysExpense ? true : (saysExpense ? false : last?.scope == QueryScope.income);
    final accounts = namedAccounts(s.raw, data);
    final accountId = accounts.length == 1 ? accounts.single.account.id : last?.accountId;
    if (kind == IntentKind.summary) return _summary(calc, now, s, period);
    // «compras»: a category of that name, or every expense? From the context, or asked once.
    final compras = !income && _any(s.words, ['compr*']);
    final comprasCategory = _comprasCategory(data);
    if (compras && comprasCategory != null && _comprasIsCategory == null) {
      _scopeWaiting = (period: period, accountId: accountId);
      return AssistantQuestion('¿Todos los gastos de ${period.title} o solo la categoría «${comprasCategory.name}»?', null,
          [('Todos los gastos', 'scope:all'), ('Solo «${comprasCategory.name}»', 'scope:category')]);
    }
    final named = compras ? null : namedCategory(s.raw, data, (c) => categorySupports(c, income ? TransactionType.income : TransactionType.expense));
    return _list(calc, now,
        period: period,
        income: income,
        accountId: accountId,
        categoryId: named?.id ?? (s.continuation && !compras && !saysIncome ? last?.categoryId : null),
        compras: compras,
        all: _any(s.words, ['movimientos', 'operaciones', 'transacciones']));
  }

  Category? _comprasCategory(Finances data) =>
      data.categories.where((c) => !c.isArchived && plainText(c.name).startsWith('compra') && categorySupports(c, TransactionType.expense)).firstOrNull;

  AssistantReply _list(FinanceCalculator calc, DateTime now,
      {required QueryPeriod period, required bool income, String? accountId, String? categoryId, bool compras = false, bool all = false}) {
    final data = calc.data;
    final category = data.category(categoryId ?? (compras && _comprasIsCategory == true ? _comprasCategory(data)?.id : null));
    final (from, to) = period.range(now);
    final rows = [
      for (final t in data.transactions)
        if (!t.date.isBefore(from) &&
            t.date.isBefore(to) &&
            (all || (income ? t.type.countsAsIncome : t.type.countsAsExpense)) &&
            (category == null || t.categoryId == category.id) &&
            (accountId == null || t.sourceAccountId == accountId || t.destinationAccountId == accountId))
          t
    ];
    final total = all ? null : rows.fold(0, (s, t) => s + t.amountMinor.abs());
    _last = (
      kind: IntentKind.listMovements,
      period: period,
      scope: all ? QueryScope.all : (income ? QueryScope.income : QueryScope.expenses),
      categoryId: category?.id,
      accountId: accountId
    );
    final what = category?.name ?? (all ? 'Movimientos' : (income ? 'Ingresos' : 'Gastos'));
    final account = data.account(accountId);
    return AssistantResult(
      '$what ${period.title}${account == null ? '' : ' en ${account.name}'}',
      [rows.isEmpty ? 'No hay ninguno.' : '${rows.length} ${rows.length == 1 ? 'movimiento' : 'movimientos'}${total == null ? '' : ' · ${money(total)} en total'}. Tócalos para abrirlos.'],
      transactions: rows.take(30).toList(),
      totalMinor: total,
    );
  }

  AssistantReply _summary(FinanceCalculator calc, DateTime now, Signals s, QueryPeriod period) {
    final usable = period == QueryPeriod.lastMonth ? QueryPeriod.lastMonth : QueryPeriod.thisMonth;
    final month = usable == QueryPeriod.lastMonth ? DateTime(now.year, now.month - 1) : DateTime(now.year, now.month);
    final category = namedCategory(s.raw, calc.data, (c) => categorySupports(c, TransactionType.expense));
    _last = (kind: IntentKind.summary, period: usable, scope: QueryScope.expenses, categoryId: category?.id, accountId: null);
    if (category != null) {
      final (from, to) = usable.range(now);
      final spent = calc.data.transactions
          .where((t) => t.categoryId == category.id && !t.date.isBefore(from) && t.date.isBefore(to))
          .fold(0, (sum, t) => sum + FinanceCalculator.budgetExpenseAmount(t));
      return AssistantResult('${category.name} ${usable.title}', ['Has gastado ${money(spent)}.']);
    }
    final summary = calc.monthlySummary(month);
    return AssistantResult('Resumen de ${usable.title}', [
      'Ingresos: ${money(summary.dailyIncomeMinor)}',
      'Gastos: ${money(summary.dailyExpenseMinor)}',
      'Resultado: ${money(summary.dailyNetMinor, signed: true)}',
      if (summary.hasReserves) 'Sin contar lo pagado con reservas ni lo destinado a ellas, como en Inicio.',
    ]);
  }

  /// Applies the current preview once. Null for a card that is no longer current (corrected, set aside, cancelled)
  /// or already applied.
  Operation? confirm(AssistantPreview preview, Finances data) {
    if (!identical(_draft?.preview, preview)) return null;
    if (!applied.add(preview.id)) return null;
    if (data.transactions.any((t) => t.id == preview.id) ||
        data.reservedFunds.any((f) => f.id == preview.id) ||
        data.installmentPlans.any((p) => p.id == preview.id)) {
      return null;
    }
    _draft = null;
    return preview.operation;
  }

  /// Whether a card is the one that can still be confirmed.
  bool isCurrent(AssistantPreview preview) => identical(_draft?.preview, preview);

  /// Undoes a confirmed preview: the movement, the reserve (if nothing uses it) or the plan (its payments stay).
  Operation? undo(AssistantPreview preview, Finances data, DateTime now) {
    switch (preview.kind) {
      case PreviewKind.reserve:
        if (data.transactions.any((t) => t.reservedFundId == preview.id)) return null;
        return removeOperation('reservedFunds', preview.id);
      case PreviewKind.plan:
        final plan = data.installmentPlans.where((p) => p.id == preview.id).firstOrNull;
        return plan == null ? null : removePlanOperation(plan, data, now);
      case PreviewKind.movement || PreviewKind.instalment:
        return data.transactions.any((t) => t.id == preview.id) ? Operation('delete', {'id': preview.id}) : null;
    }
  }
}
