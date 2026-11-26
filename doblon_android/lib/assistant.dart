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
// The limit of rules: they understand the phrasings they were built for and close variations, not any sentence. The
// interpreter on the server (phase 2, Cloudflare Workers AI, `BankingBackend/src/assistant.mjs`) fills the same
// `AssistantIntent` (`assistantIntentSchema`) when the person turns it on, so everything after step 1 is shared.
//
// Capabilities (26 November 2026). The model does not answer: it chooses calls to Doblón's capabilities (`kind`) with
// their arguments, up to three in order (`also`). The app validates them, applies its own rules and data, and answers
// from the real result. A request about existing movements is an action (list, summary, categorise) on a
// `MovementSelection` (period or range, type, without category, category, account) that the session keeps: a
// follow-up («no, los que no tienen categoría», `refine`) changes only what it states. No period said means none is
// imposed (a list of the month says so). An action the app lacks is `unsupported` and said, never replaced by another.
import 'dart:math' as math;

import 'assistant_privacy.dart';
import 'assistant_selection.dart';
import 'auto_category.dart' show AutoCategory, usefulConcept;
import 'automation.dart' show matchRule, rememberRule, ruleText;
import 'banking.dart' show referenceSeconds;
import 'budget_edit.dart';
import 'investments.dart' show linkedFee;
import 'edits.dart';
import 'finance.dart';
import 'installments.dart';
import 'models.dart';
import 'presentation.dart' show listTitle, money;

/// The capabilities Don Bigotes can use. `categorize` assigns categories to existing movements; `unsupported` is
/// an action the person asked for that the chat cannot do (said, never replaced by another one).
enum IntentKind {
  expense, income, reserve, transfer, listMovements, summary, categorize, describeExisting, editMovement, deleteMovement, setBudget, createGoal, //
  addToGoal, createRule, createPlan, payInstalment, planStatus, simulation, correction, cancel, courtesy, unsupported, unknown,
}

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

const _quantityWords = {
  'un': 1, 'uno': 1, 'una': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5, 'seis': 6, 'siete': 7, 'ocho': 8, 'nueve': 9, 'diez': 10, //
  'once': 11, 'doce': 12, 'quince': 15, 'veinte': 20,
};

/// How many movements a request is about: «los últimos 4», «los tres más recientes», «solo estos dos», «no, solo
/// cuatro», «el último». A number with money («4 €») or with instalments («4 cuotas») is not it.
int? selectionLimit(String text) {
  final t = ' ${plainText(text).replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim()} ';
  if (RegExp(r' (el|la) (ultimo|ultima|mas reciente) ').hasMatch(t) && !RegExp(r' (ultimos|ultimas) ').hasMatch(t)) return 1;
  const number = r'(\d{1,3}|un|uno|una|dos|tres|cuatro|cinco|seis|siete|ocho|nueve|diez|once|doce|quince|veinte)';
  const things = r'(movimientos?|gastos?|ingresos?|cargos?|cobros?|compras?|operaciones?|ultimos|ultimas|mas recientes|recientes)';
  final patterns = [
    RegExp(' (ultimos|ultimas|recientes|solo|estos|estas|esos|esas|primeros|primeras) $number (?!(eur|euros|cuotas?|meses|mes|plazos)\\b)'),
    RegExp(' $number $things '),
  ];
  for (final p in patterns) {
    final m = p.firstMatch(t);
    if (m == null) continue;
    final word = m.groups([1, 2]).firstWhere((g) => g != null && RegExp('^$number\$').hasMatch(g), orElse: () => null);
    if (word == null) continue;
    final n = int.tryParse(word) ?? _quantityWords[word];
    if (n != null && n >= 1 && n <= 100) return n;
  }
  return null;
}

/// The amount, unless the only number is a quantity of movements («los últimos 4 movimientos» is not 4 €).
int? _amountOutsideQuantity(String text) {
  final amount = parseAmount(text);
  if (amount == null || selectionLimit(text) == null) return amount;
  return RegExp(r'(€|\beur\b|\beuros?\b)').hasMatch(plainText(text)) ? amount : null;
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
    var year = named.group(3) == null ? now.year : int.parse(named.group(3)!);
    // Without a year, a month already well past is the next one («el 12 de enero» said in November).
    if (named.group(3) == null && DateTime(year, month, day).isBefore(DateTime(now.year, now.month - 1, now.day))) year++;
    final d = DateTime(year, month, day, 12);
    return d.month == month ? d : null;
  }
  // A day with «este mes» or «el mes que viene»; a day alone is not a date (the month is asked, never invented).
  final day = dueDay(text);
  final offset = _monthOffset(f);
  if (day != null && offset != null) {
    final d = DateTime(now.year, now.month + offset, day, 12);
    return d.day == day ? d : null;
  }
  return null;
}

int? _monthOffset(String padded) {
  if (RegExp(r' (mes que viene|del que viene|proximo mes|siguiente mes|mes siguiente|el otro mes) ').hasMatch(padded)) return 1;
  if (padded.contains(' este mes ') || padded.contains(' de este mes ')) return 0;
  return null;
}

/// The day of the month in an answer about a due date: «5 de cada mes», «los días 5», «pon el 5», even with a slip of
/// the autocorrector around it. A number followed by money or by a count of instalments is not a day.
int? dueDay(String text) {
  final t = plainText(text);
  for (final m in RegExp(r'(?<![\d.,])(\d{1,2})(?![\d.,])').allMatches(t)) {
    final after = t.substring(m.end).trimLeft();
    if (RegExp(r'^(€|eur\b|euros?\b)').hasMatch(after) || RegExp('^$_countUnits\\b').hasMatch(after) && !RegExp(r'^mes\b').hasMatch(after)) continue;
    if (t.substring(0, m.start).trimRight().endsWith('€')) continue;
    final day = int.parse(m.group(1)!);
    if (day >= 1 && day <= 31) return day;
  }
  if (RegExp(r'\b(dia uno|el uno|primero de (cada )?mes|dia primero)\b').hasMatch(t)) return 1;
  return null;
}

/// A due date said only roughly («a primeros de mes», «a mediados», «el día que quieras»): a day is proposed, never
/// set without confirmation. Null when the sentence is not about the time of the month.
int? roughDueDay(String text) {
  final t = ' ${plainText(text).replaceAll(RegExp(r'[^a-z ]+'), ' ')} ';
  if (RegExp(r' (primeros|principios|principio|inicio|inicios|comienzo|comienzos) ').hasMatch(t)) return 1;
  if (RegExp(r' (mediados|mitad) ').hasMatch(t)) return 15;
  if (RegExp(r' (finales|final) ').hasMatch(t)) return 28;
  if (RegExp(r' (quieras|prefieras|te de|da igual|cualquier dia|cualquiera) ').hasMatch(t)) return 1;
  return null;
}

const _monthNames = ['enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'octubre', 'noviembre', 'diciembre'];
String _longDate(DateTime d) => '${d.day} de ${_monthNames[d.month - 1]} de ${d.year}';

/// Speaks of money: only then may an open draft's amount change (or when the amount is what was asked).
bool moneyCue(Signals s) =>
    RegExp(r'(€|\beur\b|\beuros?\b|\bimporte\b|\btotal\b|\bcantidad\b|\bprecio\b|\bcuesta\b|\bpavos\b|\bpelas\b)').hasMatch(s.plain);

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
const _transferWords = ['traspas*', 'transfer*', 'transfie*', 'transfir*'];
const _planWords = ['plazo*', 'cuota*', 'mensualidad*', 'fraccion*', 'financ*', 'aplaz*', 'repart*', 'prestamo*'];
const _consultVerbs = ['muestra*', 'ensena*', 'dime', 'lista*', 'listado', 'busca*', 'mira*', 'saca*', 'ver', 'revisa*', 'consulta*', 'enumera*'];
const _registerVerbs = ['apunta*', 'anota*', 'registra*', 'anade*', 'mete*', 'introduce*'];
const _listNouns = ['compras', 'gastos', 'ingresos', 'movimientos', 'cosas', 'pagos', 'cargos', 'recibos', 'operaciones', 'transacciones', 'cobros'];
const _questionWords = ['que', 'cuanto', 'cuanta', 'cuantos', 'cuantas', 'cuales', 'cual', 'cuando', 'donde', 'como', 'hay'];
const _continuations = ['y', 'pero', 'no', 'solo', 'tambien', 'entonces', 'vale', 'ahora', 'e', 'o'];
const _cancelWords = ['cancela*', 'olvidalo', 'olvida', 'dejalo', 'descarta*', 'anula*'];
const _resumeWords = ['retoma*', 'sigue', 'seguir', 'continua*', 'vuelve'];

/// «sin categoría», «no tienen categoría», «les falta la categoría», «sin clasificar»: a category word with a
/// negation shortly before it (a condition on the movements, not a category).
bool negatedCategory(List<String> words) {
  for (var i = 0; i < words.length; i++) {
    if (!_any([words[i]], ['categor*', 'clasific*', 'etiquet*'])) continue;
    if (words.sublist(math.max(0, i - 3), i).any((w) => const {'sin', 'no', 'ninguna', 'ningun', 'falta', 'faltan', 'carecen'}.contains(w))) return true;
  }
  return false;
}

/// What the sentence says, before deciding anything.
class Signals {
  Signals(this.raw, DateTime now)
      : plain = plainText(raw),
        words = wordsOf(raw),
        amountMinor = _amountOutsideQuantity(raw),
        limit = selectionLimit(raw),
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
    correction = _phrase(plain, ['no eran', 'no era', 'no es', 'eran', 'era', 'fue', 'fueron', 'que fueron', 'en realidad', 'me he equivocado', 'perdona', 'mejor', 'la fecha',
          'el importe', 'la cuenta', 'te he dicho', 'ya te he dicho', 'te dije', 'he dicho', 'no te he dicho', 'que no', 'digo']) ||
        _any(words, ['cambia*', 'corrige*', 'concepto', 'llamalo', 'ponlo', 'ponla']) ||
        // «categoría» changes a draft's category, unless it is a condition («sin categoría»).
        _any(words, ['categoria']) && !negatedCategory(words);
    cancel = _any(words, _cancelWords) || plain.trim() == 'no' || plain.trim() == 'nada';
    resume = _any(words, _resumeWords);
    // «El ingreso de 4.378 € es el préstamo», «el cargo de 44,53 era gasolina»: what an existing movement is.
    final refers = _phrase(plain, ['el ingreso de', 'el cargo de', 'el gasto de', 'el movimiento de', 'el pago de', 'el abono de', 'la entrada de',
          'ese ingreso', 'ese cargo', 'ese gasto', 'ese movimiento', 'ese pago', 'ese abono', 'lo de']) ||
        _any(words, ['clasifica*', 'vincula*', 'asocia*', 'etiqueta*']);
    final says = _phrase(plain, ['es', 'era', 'fue', 'son', 'eran', 'corresponde', 'corresponden', 'viene de', 'es de', 'era de', 'lo use', 'lo he usado']) ||
        _any(words, ['clasifica*', 'vincula*', 'asocia*', 'etiqueta*']);
    existing = refers && says && amountMinor != null && !register;
    // A condition on which movements («sin categoría», «no tienen categoría», «les falta la categoría»): a category
    // word with a negation shortly before it. And the action of assigning categories to existing movements.
    uncategorized = negatedCategory(words);
    categorize = amountMinor == null &&
        (_any(words, ['categoriza*', 'clasifica*', 'etiqueta*', 'organiza*']) ||
            _any(words, ['pon*', 'asigna*', 'mete*', 'anade*', 'rellena*', 'completa*', 'arregla*']) && _any(words, ['categor*']));
    unsupported = _any(words, ['borra*', 'elimina*', 'suprime*']);
    // «Gracias», «vale, perfecto», «nada más»: a courtesy, not a request.
    final courtesyWords = {'gracias', 'muchas', 'mil', 'vale', 'ok', 'okay', 'perfecto', 'genial', 'estupendo', 'guay', 'bien', 'muy', 'de', 'acuerdo',
      'listo', 'nada', 'mas', 'eso', 'es', 'todo', 'hasta', 'luego', 'adios', 'chao', 'buenas', 'noches', 'gracia', 'grasias', 'thanks', 'top', 'crack', 'dale'};
    courtesy = words.isNotEmpty && words.every(courtesyWords.contains) && amountMinor == null && words.length <= 6;
  }

  final String raw, plain;
  final List<String> words;
  final int? amountMinor, count, instalmentNumber;

  /// How many movements («los últimos 4»), not an amount.
  final int? limit;
  final DateTime? date, dueDate;
  final QueryPeriod? period;
  late final bool question, consult, register, summary, listNoun, spend, earn, reserve, transfer, plan, pending, paidPast, simulate, continuation, correction, cancel, resume, existing, courtesy, uncategorized, categorize, unsupported;

  /// Says something to record or to look up (not only a detail).
  bool get mainIntent => spend || earn || reserve || transfer || plan || consult || listNoun || summary || simulate || register || question || existing || categorize;
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

// ---------------------------------------------------------------- the intent (shared with the model)

/// What a sentence asks for, closed. The interpreter on the server (phase 2, `BankingBackend/src/assistant.mjs`)
/// returns exactly this and it is validated again here: unknown fields or values are refused. It never sees the
/// database and never writes; the session resolves it with the app's rules and asks for confirmation.
class AssistantIntent {
  AssistantIntent({
    required this.kind,
    this.amountMinor,
    this.count,
    this.instalmentNumber,
    this.dueDay,
    this.perInstalment,
    this.date,
    this.dueDate,
    this.period,
    this.scope,
    this.planKind,
    this.concept,
    this.purpose,
    this.accountText,
    this.categoryText,
    this.planText,
    this.uncategorized,
    this.from,
    this.to,
    this.refine,
    this.limit,
    this.also = const [],
  });
  IntentKind kind;

  /// How many movements, the most recent first («los últimos 4»).
  int? limit;

  /// The selection of existing movements: only those without category, an explicit range.
  bool? uncategorized;
  DateTime? from, to;

  /// The sentence corrects or narrows the previous request: only what it states changes.
  bool? refine;

  /// Further steps of a combined request, run in order after this one (at most two).
  List<AssistantIntent> also;
  int? amountMinor, count, instalmentNumber, dueDay;
  bool? perInstalment;
  DateTime? date, dueDate;
  QueryPeriod? period;
  QueryScope? scope;
  InstallmentKind? planKind;
  String? concept, purpose, accountText, categoryText, planText;

  /// What an existing movement is (`describeExisting`): loanReceived, loanUse, instalment or category.
  String? role;

  /// Resolved on this device from the interpreter's markers (`AssistantMasker`): the person's own records.
  String? accountId, toAccountId, planId, goalId, targetId, categoryId;

  /// An existing movement to find by its amount and day (when it is not on screen).
  int? findAmountMinor;
  DateTime? findDate;
  bool? recurring, recorded, clearCategory;

  // The markers as the interpreter wrote them, until resolved.
  Object? _amountRef, _countRef, _limitRef, _instalmentRef, _findAmountRef;
  String? _accountRef, _toAccountRef, _planRef, _goalRef, _targetRef, _categoryRaw, _conceptRaw, _purposeRaw;

  /// Puts back what the interpreter answered with markers: amounts, the person's accounts, categories, plans, goals
  /// and the movements on screen. A marker it did not receive resolves to nothing (never to a guess).
  void resolve(AssistantMasker masker) {
    amountMinor ??= masker.amountOf(_amountRef);
    findAmountMinor ??= masker.amountOf(_findAmountRef);
    int? small(Object? ref, int max) {
      final n = masker.intOf(ref);
      return n != null && n >= 1 && n <= max ? n : null;
    }

    count ??= small(_countRef, 600);
    limit ??= small(_limitRef, 100);
    instalmentNumber ??= small(_instalmentRef, 600);
    final account = masker.accountOf(_accountRef), toAccount = masker.accountOf(_toAccountRef);
    accountId ??= account?.id;
    accountText ??= account?.name;
    toAccountId ??= toAccount?.id;
    final plan = masker.planOf(_planRef);
    planId ??= plan?.id;
    planText ??= plan?.name;
    goalId ??= masker.goalOf(_goalRef)?.id;
    targetId ??= masker.movementOf(_targetRef)?.id;
    categoryId ??= masker.categoryOf(_categoryRaw)?.id;
    categoryText ??= masker.unmask(_categoryRaw);
    concept = _conceptRaw == null ? concept : masker.unmask(_conceptRaw);
    purpose = _purposeRaw == null ? purpose : masker.unmask(_purposeRaw);
    for (final step in also) {
      step.resolve(masker);
    }
  }

  static AssistantIntent? fromJson(Object? json, {bool nested = false}) {
    if (json is! Map) return null;
    if (nested && json.containsKey('also')) return null;
    final allowed = (assistantIntentSchema['properties'] as Map).keys.toSet();
    if (json.keys.any((k) => !allowed.contains(k))) return null;
    final kind = IntentKind.values.where((k) => k.name == json['kind']).firstOrNull;
    if (kind == null) return null;
    int? cents(Object? v) => v is int && v > 0 && v < 100000000000 ? v : null;
    int? small(Object? v) => v is int && v >= 1 && v <= 600 ? v : null;
    String? text(Object? v) => v is String && v.trim().isNotEmpty && v.length <= 120 ? v.trim() : null;
    bool? flag(Object? v) => v is bool ? v : null;
    DateTime? day(Object? v) {
      final m = v is String ? RegExp(r'^(\d{4})-(\d{2})-(\d{2})$').firstMatch(v) : null;
      if (m == null) return null;
      final d = DateTime(int.parse(m.group(1)!), int.parse(m.group(2)!), int.parse(m.group(3)!), 12);
      return d.month == int.parse(m.group(2)!) ? d : null;
    }

    final intent = AssistantIntent(
      kind: kind,
      amountMinor: cents(json['amountMinor']),
      count: small(json['count']),
      instalmentNumber: small(json['instalmentNumber']),
      dueDay: json['dueDay'] is int && (json['dueDay'] as int) >= 1 && (json['dueDay'] as int) <= 31 ? json['dueDay'] as int : null,
      perInstalment: flag(json['perInstalment']),
      date: day(json['date']),
      dueDate: day(json['dueDate']),
      period: QueryPeriod.values.where((p) => p.name == json['period']).firstOrNull,
      scope: const {'expenses': QueryScope.expenses, 'income': QueryScope.income, 'all': QueryScope.all}[json['scope']],
      planKind: InstallmentKind.values.where((k) => k.name == json['planKind']).firstOrNull,
      concept: text(json['concept']),
      purpose: text(json['purpose']),
      accountText: text(json['accountText']),
      categoryText: text(json['categoryText']),
      planText: text(json['planText']),
      uncategorized: flag(json['uncategorized']),
      from: day(json['from']),
      to: day(json['to']),
      refine: flag(json['refine']),
      limit: json['limit'] is int && (json['limit'] as int) >= 1 && (json['limit'] as int) <= 100 ? json['limit'] as int : null,
      also: nested || json['also'] is! List
          ? const []
          : (json['also'] as List).take(2).map((step) => AssistantIntent.fromJson(step, nested: true)).whereType<AssistantIntent>().toList(),
    )
      ..role = const ['loanReceived', 'loanUse', 'instalment', 'category'].contains(json['role']) ? json['role'] as String : null
      ..findDate = day(json['findDate'])
      ..recurring = flag(json['recurring'])
      ..recorded = flag(json['recorded'])
      ..clearCategory = flag(json['clearCategory'])
      .._amountRef = json['amount']
      .._findAmountRef = json['findAmount']
      .._countRef = json['count'] is String ? json['count'] : null
      .._limitRef = json['limit'] is String ? json['limit'] : null
      .._instalmentRef = json['instalmentNumber'] is String ? json['instalmentNumber'] : null
      .._accountRef = text(json['account'])
      .._toAccountRef = text(json['toAccount'])
      .._planRef = text(json['plan'])
      .._goalRef = text(json['goal'])
      .._targetRef = text(json['target'])
      .._categoryRaw = text(json['category'])
      .._conceptRaw = text(json['concept'])
      .._purposeRaw = text(json['purpose']);
    return intent;
  }
}

/// The JSON schema the model fills (the same as the server's, `BankingBackend/src/assistant.mjs`): markers for what
/// is masked on this device. The older plain fields (`amountMinor`, `accountText`…) are still read, for tests.
final assistantIntentSchema = <String, Object>{
  'type': 'object',
  'additionalProperties': false,
  'required': ['kind'],
  'properties': {
    'kind': {'type': 'string', 'enum': assistantKinds},
    for (final k in ['amount', 'findAmount', 'account', 'toAccount', 'plan', 'goal', 'target', 'category', 'concept', 'purpose']) k: {'type': 'string'},
    for (final k in ['date', 'dueDate', 'from', 'to', 'findDate']) k: {'type': 'string', 'description': 'YYYY-MM-DD'},
    for (final k in ['perInstalment', 'uncategorized', 'refine', 'recurring', 'recorded', 'clearCategory']) k: {'type': 'boolean'},
    'count': {},
    'limit': {},
    'instalmentNumber': {},
    'dueDay': {'type': 'integer', 'minimum': 1, 'maximum': 31},
    'period': {'type': 'string'},
    'scope': {'type': 'string'},
    'planKind': {'type': 'string'},
    'role': {'type': 'string'},
    'also': {'type': 'array', 'maxItems': 2},
    // Plain values (tests and the rules).
    'amountMinor': {'type': 'integer'},
    'accountText': {'type': 'string'},
    'categoryText': {'type': 'string'},
    'planText': {'type': 'string'},
  },
};

const assistantKinds = [
  'expense', 'income', 'reserve', 'transfer', 'listMovements', 'summary', 'categorize', 'describeExisting', 'editMovement', 'deleteMovement', //
  'setBudget', 'createGoal', 'addToGoal', 'createRule', 'createPlan', 'payInstalment', 'planStatus', 'simulation', 'correction', 'cancel', //
  'courtesy', 'unsupported', 'unknown',
];

/// What the model answered, or why it could not (the session then goes on with its own rules).
typedef RemoteInterpretation = ({AssistantIntent? intent, String? error});

// ---------------------------------------------------------------- replies

enum PendingField { kind, amount, account, purpose, category, count, planKind, planName, dueDate, dueMonth, recorded, plan, target, role, loanTotal, loanCategory, toAccount, goal, change }

sealed class AssistantReply {
  /// Said before the reply: a draft set aside, so nothing is lost or answered silently.
  String? note;

  /// A draft was set aside with this reply: the card offers to go back to it (no exact words needed).
  bool canResume = false;

  /// Shown after this one: the other parts of the answer (proposals to confirm, the next step of a combined request).
  final followUps = <AssistantReply>[];
}

class AssistantQuestion extends AssistantReply {
  AssistantQuestion(this.text, this.field, [this.options = const []]);
  final String text;

  /// The draft field asked for, or null for a question about a query.
  final PendingField? field;
  final List<(String, String)> options;
}

enum PreviewKind { movement, reserve, plan, instalment, existing, categories, delete, setting, batch }

/// One movement of a categorisation: its category and where it comes from. `rule` and `history` were applied on
/// their own (the person's evidence); `model` and `brand` are proposed; `person` was chosen here; no category: it
/// needs the person to say what it is.
class CategoryItem {
  CategoryItem(this.transaction, {this.categoryId, this.source}) : proposedId = categoryId, proposedSource = source;
  final Transaction transaction;
  String? categoryId, source;

  /// What was proposed first (to count whether the proposal was accepted).
  final String? proposedId, proposedSource;
  bool get applied => source == 'rule' || source == 'history';
}

/// The concept as a person reads it, short: the first part of a bank text, at most 42 characters.
String shortConcept(Transaction t) {
  final title = listTitle(t.descriptionText, isBanking: t.isBanking).split('//').first.trim();
  final text = title.isEmpty ? 'Movimiento' : title;
  return text.length > 42 ? '${text.substring(0, 41).trimRight()}…' : text;
}

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
    this.targetId,
    this.undoOperation,
    this.items = const [],
    this.parts = const [],
  });

  /// Several operations told in one go, confirmed together (each part is a movement or a reserve).
  final List<AssistantPreview> parts;

  /// The movements of a categorisation, exactly those selected (never others), each with its category.
  final List<CategoryItem> items;

  /// What confirming applies (movement id, category id, why): only to those still without one when confirmed.
  List<(String, String, String)> get assignments => [
        for (final i in items)
          if (!i.applied && i.categoryId != null) (i.transaction.id, i.categoryId!, i.source ?? 'person')
      ];

  /// Applied on their own from the person's evidence: undoable from the card.
  List<String> get automatic => [for (final i in items) if (i.applied) i.transaction.id];

  /// The existing movement a preview changes (never a new one), and how to put it back.
  final String? targetId;
  final Operation? undoOperation;

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
  AssistantResult(this.title, this.lines, {this.transactions = const [], this.totalMinor, this.planId, this.automatic = const []});

  /// Movements that got a category just now from the person's own evidence (rules, history): undoable.
  final List<String> automatic;
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

  /// An existing movement being described: which one, what it is, whether it is money in.
  String? targetId, role;
  bool? incoming;

  /// The income that is the money of the loan this plan repays (linked when the plan is saved).
  String? linkIncomeId;

  /// A transfer's destination, a goal, a budget for every month, an existing movement to find by amount and day.
  String? toAccountId, goalId;
  bool recurring = true;
  int? findAmountMinor;
  DateTime? findDate;

  /// The account was not said: the one the person usually uses (said on the card, easy to change).
  bool accountGuessed = false;
  bool incomeLookedFor = false;
  String? newCategoryId;

  /// The category for a loan's money: an existing one's id, «new» (create «Préstamo recibido») or «none».
  String? loanCategory;
  bool categoryDecided = false;
  ({String categoryName, String source})? proposal;
  List<AccountChoice>? accountOptions;
  PendingField? pending;

  /// The question asked for [pending], for the model's context and to ask it again.
  String? question;
  List<(String, String)> questionOptions = const [];
  int? dueDay;

  /// The day was only said roughly («a primeros»): it is proposed, not assumed.
  bool roughDay = false;
  String? previewId;
  AssistantPreview? preview;

  String describe() => switch (kind) {
        IntentKind.reserve => 'la reserva${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
        IntentKind.transfer => 'el traspaso${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
        IntentKind.editMovement => 'el cambio del movimiento',
        IntentKind.deleteMovement => 'el borrado del movimiento',
        IntentKind.setBudget => 'el presupuesto',
        IntentKind.createGoal => 'el objetivo',
        IntentKind.addToGoal => 'la aportación al objetivo',
        IntentKind.createRule => 'la regla',
        IntentKind.createPlan => 'el pago a plazos${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
        IntentKind.payInstalment => 'el pago de la cuota',
        IntentKind.income => 'el ingreso${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
        _ => 'el gasto${amountMinor == null ? '' : ' de ${money(amountMinor!)}'}',
      };
}

/// The last request about existing movements: what was done and which movements. A follow-up changes only what it states.
typedef _LastQuery = ({IntentKind kind, MovementSelection selection});

/// One conversation: the draft being prepared, a draft set aside, the last query (for continuations) and the ids
/// already applied (a preview is applied once).
class AssistantSession {
  AssistantSession({required this.newId, this.propose, this.remote, this.applyEvidence, this.record});

  /// Assigns, among [ids], the categories the person's own evidence gives (rules, history) with their provenance
  /// (`FinanceRepository.applyAutoCategories`); returns what each one got.
  final Future<List<AutoCategory>> Function(Set<String> ids)? applyEvidence;

  /// The card of category proposals that can still be confirmed.
  AssistantPreview? _proposals;

  /// The raw record of an entity (to undo a deletion exactly as it was): `rawRecord` over the repository's document.
  final Map<String, dynamic>? Function(String entity, String id)? record;

  /// The other things told in the same story, prepared one after another and confirmed together.
  final _queue = <AssistantIntent>[];
  final _ready = <AssistantPreview>[];
  AssistantPreview? _batch;

  /// The amounts written in the sentence being understood: a correction may only set one of these (the interpreter
  /// never turns a day or a count into money).
  Set<int>? _amountsSaid;

  /// The last turns, for the interpreter (masked when sent), and the movements on screen («el segundo», «ese»).
  final _turns = <String>[];
  var _shownMovements = <Transaction>[];
  final String Function() newId;

  /// The interpreter on the server (phase 2), only when the person turned it on in Ajustes. It receives
  /// `contextFor`'s minimal context and returns an intent or why it could not; null means rules only.
  final Future<RemoteInterpretation> Function(Map<String, Object?> context)? remote;

  /// The category the personal learning proposes for a concept (`Learning.categoryProposal`): (id, source).
  final Future<(String, String)?> Function(String text, TransactionType type)? propose;

  _Draft? _draft;
  _Draft? _parked;
  _LastQuery? _last;
  bool? _comprasIsCategory;
  ({QueryPeriod? period, String? accountId})? _scopeWaiting;
  final applied = <String>{};

  bool get hasDraft => _draft != null;
  bool get hasParked => _parked != null;

  void cancel() {
    _draft = null;
    _queue.clear();
    _ready.clear();
    _batch = null;
  }

  /// What the person wrote: an answer to the question asked, a change to the open draft, a new request, or something
  /// not understood. With a draft open, the sentence updates it unless it clearly opens another subject; what is not
  /// understood never resets or sets aside the draft: the missing data is asked again.
  /// What the person wrote. With the interpreter on, it understands the sentence (whatever the wording, a story with
  /// several things in it, an answer, a correction) and this session only checks and acts: the person's own data, the
  /// preview before saving, nothing outside what is on screen. Without it (off, offline, out of quota), the rules on
  /// this device understand simple sentences, and say so.
  Future<AssistantReply> say(String text, FinanceCalculator calc, DateTime now, {int heldMinor = 0}) async {
    _remember('Persona', text);
    var reply = await _say(text, calc, now, heldMinor);
    reply = await _afterReply(reply, calc, now, heldMinor);
    _rememberReply(reply);
    return reply;
  }

  Future<AssistantReply> _say(String text, FinanceCalculator calc, DateTime now, int heldMinor) async {
    final data = calc.data;
    String? fallbackNote;
    if (remote != null && text.trim().length <= 500) {
      final masker = AssistantMasker(data);
      final answer = await remote!(contextFor(text, data, now, masker: masker));
      final intent = answer.intent;
      if (intent != null) {
        intent.resolve(masker);
        _amountsSaid = masker.amountsIn(text);
        final reply = await _understood(intent, Signals(text, now), calc, now, heldMinor);
        if (reply != null) return reply;
      } else {
        fallbackNote = switch (answer.error) {
          'assistant_quota' => 'Hoy ya has usado tus 40 frases libres: sigo con mis reglas hasta mañana.',
          'assistant_quota_server' => 'Hoy se ha agotado el cupo gratuito del intérprete: sigo con mis reglas hasta mañana.',
          'network' => 'Sin conexión: lo interpreto con mis reglas.',
          _ => 'El intérprete no ha respondido: lo interpreto con mis reglas.',
        };
      }
    }
    final reply = await _byRules(text, calc, now, heldMinor);
    reply.note ??= fallbackNote;
    return reply;
  }

  /// The rules on this device: simple sentences only. Nothing is added here for particular wordings.
  Future<AssistantReply> _byRules(String text, FinanceCalculator calc, DateTime now, int heldMinor) async {
    final s = Signals(text, now);
    final data = calc.data;
    final draft = _draft;
    if (draft != null && s.cancel && !s.mainIntent) {
      _draft = null;
      return AssistantMessage('Cancelado: no se ha guardado nada.');
    }
    // 1. The answer to the question asked, read in its context (a date question reads «5» as the day).
    if (draft != null &&
        draft.pending != null &&
        !_asksElsewhere(s, draft) &&
        !_correctsInstead(s, draft) &&
        // Another operation with its own amount is not the answer («he gastado 20 € …» is not a name).
        !(s.amountMinor != null && draft.pending != PendingField.amount && _otherSubject(s, null, draft, data)) &&
        _fill(draft, draft.pending!, s, data, now)) {
      return _next(calc, now, heldMinor);
    }
    if (s.courtesy) {
      final open = _draft;
      if (open == null) return AssistantMessage(_any(s.words, ['gracias', 'gracia', 'grasias', 'thanks']) ? '¡De nada! Aquí estoy si necesitas algo más.' : 'Perfecto. Aquí estoy si necesitas algo más.');
      return AssistantMessage(open.preview != null
          ? 'De nada. ${_capital(open.describe())} sigue esperando: confírmalo, cancélalo o dime qué cambio.'
          : 'De nada. Seguimos cuando quieras: ${open.question ?? 'dime el dato que falta'}');
    }
    final proposal = _proposals;
    if (proposal != null && s.amountMinor != null && !s.register && !s.spend && !s.earn && !s.reserve && !s.plan) {
      final same = proposal.items.where((i) => !i.applied && i.transaction.amountMinor == s.amountMinor).toList();
      if (same.length == 1) {
        final item = same.single;
        bool fits(Category c) => categorySupports(c, item.transaction.type);
        // The category named, or the one a concept clearly suggests among theirs («gasolina» → Combustible).
        var c = namedCategory(s.raw, data, fits);
        final concept = c == null ? extractConcept(s.raw, data) : null;
        if (concept != null) {
          final (found, _) = hintedCategories(concept, data, fits);
          if (found.length == 1) c = found.single;
        }
        if (c != null) {
          item
            ..categoryId = c.id
            ..source = 'person';
          return AssistantMessage('Hecho: «${shortConcept(item.transaction)}» irá a ${c.name}. Confírmalo en la tarjeta.');
        }
      }
    }
    if (_scopeWaiting != null) {
      final choice = _any(s.words, ['categoria', 'solo']) ? true : (_any(s.words, ['todos', 'todo', 'todas']) ? false : null);
      if (choice != null) return _scopeChosen(choice, calc, now);
    }
    if (draft == null && s.resume && _parked != null && !s.mainIntent) return resume(calc, now, heldMinor: heldMinor);
    const AssistantIntent? intent = null;
    // 3. With a draft open: an update of it, or a short question about what is still missing.
    if (draft != null && !_otherSubject(s, intent, draft, data)) {
      final reply = _update(draft, s, intent, data, now) ? await _next(calc, now, heldMinor) : _clarify(draft);
      return reply;
    }
    // 4. A new subject (or nothing open): the model's reading, or the rules'.
    if (intent != null && intent.kind != IntentKind.unknown && intent.kind != IntentKind.correction) {
      final reply = await _fromIntent(intent, s, calc, now, heldMinor);
      if (reply != null) return reply;
    }
    final kind = _decide(s, data);
    return _start(kind, s, calc, now, heldMinor, park: draft != null);
  }

  /// Goes back to the draft set aside, with everything it had.
  Future<AssistantReply> resume(FinanceCalculator calc, DateTime now, {int heldMinor = 0}) async {
    final reply = await _afterReply(await _resume(calc, now, heldMinor), calc, now, heldMinor);
    _rememberReply(reply);
    return reply;
  }

  Future<AssistantReply> _resume(FinanceCalculator calc, DateTime now, int heldMinor) async {
    if (_parked == null) return AssistantMessage('No hay nada apartado. ¿Qué quieres apuntar o consultar?');
    _draft = _parked
      ?..pending = null
      ..preview = null;
    _parked = null;
    return _next(calc, now, heldMinor);
  }

  /// Sets the open draft aside before a new subject, said explicitly; returns the note.
  String? _park() {
    final draft = _draft;
    if (draft == null) return null;
    _parked = draft;
    _draft = null;
    return 'Dejo aparte ${draft.describe()} sin guardar; puedes seguir con él cuando quieras.';
  }

  /// A question or a request to see is never the answer to «¿Con qué cuenta?».
  bool _asksElsewhere(Signals s, _Draft d) =>
      s.question && d.pending != PendingField.dueDate && d.pending != PendingField.dueMonth ||
      s.consult ||
      s.summary && s.amountMinor == null ||
      s.listNoun ||
      s.simulate ||
      s.categorize ||
      s.transfer ||
      s.reserve && d.kind != IntentKind.reserve ||
      s.plan && d.kind != IntentKind.createPlan && d.kind != IntentKind.payInstalment;

  /// «Te he dicho que un préstamo» while a name is asked: a correction, not the name.
  bool _correctsInstead(Signals s, _Draft d) =>
      (d.pending == PendingField.planName || d.pending == PendingField.purpose) && (s.correction || _planKind(s) != null && d.planKind != _planKind(s));

  /// Whether a sentence opens another subject instead of continuing the open draft: a question or a request to see,
  /// another operation with its own amount, or the model reading another kind that the sentence itself supports.
  bool _otherSubject(Signals s, AssistantIntent? intent, _Draft d, Finances data) {
    // A summary never carries an amount: «el total son 4.500 €» speaks of the draft's money, not of a query.
    if ((s.question || s.consult || s.summary && s.amountMinor == null || s.listNoun || s.simulate || s.transfer) && !s.correction) return true;
    final stated = s.spend || s.earn || s.reserve || s.plan ? _decide(s, data) : null;
    // In a plan the amount must be said as money (it has other numbers); in a movement a verb and an amount suffice.
    if (stated != null && s.amountMinor != null && (moneyCue(s) || d.kind != IntentKind.createPlan) && !s.correction) {
      if (stated != d.kind) return true;
      // The same kind again with another amount, while nothing about the amount was asked: a new one.
      if (d.amountMinor != null && s.amountMinor != d.amountMinor && d.pending != PendingField.amount && d.preview != null) return true;
    }
    final read = intent?.kind;
    // The model reads another operation and the sentence supports it (its own intent words or its own amount).
    return read != null && read != IntentKind.unknown && read != IntentKind.correction && read != d.kind && (s.mainIntent || s.amountMinor != null) && !s.correction;
  }

  /// Asks again only for what is missing, keeping everything else.
  AssistantReply _clarify(_Draft d) {
    if (d.pending != null && d.question != null) {
      return AssistantQuestion('No te he entendido. ${d.question!}', d.pending, d.questionOptions);
    }
    if (d.preview != null) {
      return AssistantMessage('No te he entendido. Puedes confirmar ${d.describe()}, cancelarlo o decirme qué cambio (por ejemplo, «el importe son 45 €» o «fue ayer»).');
    }
    return AssistantMessage('No te he entendido. Sigo con ${d.describe()}: dime el dato que falta o «cancela».');
  }


  /// What the interpreter receives, all masked on this device (`AssistantMasker`): the sentence, today, the person's
  /// accounts and cards (marker and type), plans and goals (markers), the movements on screen (markers, kind, day and
  /// category marker), the last turns, the last request and the draft in words. Never an amount, a name of theirs or
  /// a bank text.
  Map<String, Object?> contextFor(String sentence, Finances data, DateTime now, {AssistantMasker? masker}) {
    final m = masker ?? AssistantMasker(data);
    String clip(String text, int max) => text.length > max ? text.substring(0, max) : text;
    final draft = _draft;
    String? describeDraft() {
      if (draft == null) return null;
      final what = <String>[
        draft.planKind?.title ?? draft.describe(),
        if (draft.planKind != null && draft.amountMinor != null) 'de ${money(draft.amountMinor!)}${draft.perInstalment ? ' cada cuota' : ' en total'}',
        if (draft.concept != null) '(${draft.concept})',
        if (draft.accountId != null) 'en ${data.account(draft.accountId)?.name ?? ''}',
        if (draft.toAccountId != null) 'hacia ${data.account(draft.toAccountId)?.name ?? ''}',
        if (draft.categoryId != null) 'categoría ${data.category(draft.categoryId)?.name ?? ''}',
        if (draft.count != null) 'en ${draft.count} cuotas',
        if (draft.dueDay != null) 'día ${draft.dueDay}',
        if (draft.pending != null && draft.question != null) '; pregunta pendiente: ${draft.question}',
        if (draft.preview != null) '; enseñado para confirmar',
      ].join(' ');
      return clip(m.mask(what), 400);
    }

    String day(DateTime d) => '${d.year.toString().padLeft(4, '0')}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    String kindOf(Account a) => switch (a.type) {
          AccountType.checking => 'corriente',
          AccountType.savings => 'ahorro',
          AccountType.investment => 'inversión',
          _ => a.type.isLiability ? 'crédito' : 'otra',
        };
    final shown = [
      for (final t in _shownMovements.take(12))
        '${m.movement(t)}: ${t.type.countsAsIncome ? 'ingreso' : (t.type == TransactionType.transfer ? 'traspaso' : 'gasto')} de [${m.amount(t.amountMinor)}] el ${day(t.date)}'
            '${data.account(t.sourceAccountId) == null ? '' : ' en ${m.account(data.account(t.sourceAccountId)!)}'}'
            ', ${data.category(t.categoryId) == null ? 'sin categoría' : 'categoría ${m.category(data.category(t.categoryId)!)}'}',
    ];
    return {
      'sentence': clip(m.mask(sentence.trim()), 600),
      'today': day(now),
      'accounts': [
        for (final a in data.accounts.where((a) => !a.isArchived).take(30))
          '${m.account(a)}: ${kindOf(a)}${AssistantMasker.commonWords(a.name).isEmpty ? '' : ' (${AssistantMasker.commonWords(a.name).join(', ')})'}',
        for (final c in data.cards.where((c) => !c.isArchived).take(10))
          '${m.card(c)}: tarjeta${data.account(c.linkedAccountId) == null ? '' : ' de ${m.account(data.account(c.linkedAccountId)!)}'}',
      ],
      'plans': [for (final p in data.installmentPlans.where((p) => !p.isArchived).take(40)) '${m.plan(p)}: ${p.kind.title.toLowerCase()}'],
      'goals': [for (final g in data.goals.where((g) => !g.isCompleted).take(40)) m.goal(g)],
      if (shown.isNotEmpty) 'shown': shown,
      if (_turns.isNotEmpty) 'history': [for (final t in _turns) clip(m.mask(t), 600)],
      if (_last != null)
        'lastQuery': clip(
            m.mask('${switch (_last!.kind) {
              IntentKind.categorize => 'poner categoría',
              IntentKind.summary => 'resumen',
              _ => 'ver',
            }}: ${_last!.selection.describe(data)}'),
            400),
      if (describeDraft() != null) 'draft': describeDraft(),
    };
  }

  void _remember(String who, String text) {
    if (text.trim().isEmpty) return;
    _turns.add('$who: ${text.trim()}');
    while (_turns.length > 6) {
      _turns.removeAt(0);
    }
  }

  /// What Don Bigotes answered, in a line (for the next turn), and the movements now on screen.
  void _rememberReply(AssistantReply reply) {
    final text = switch (reply) {
      AssistantQuestion q => q.text,
      AssistantMessage m => m.text,
      AssistantPointer p => p.text,
      AssistantResult r => '${r.title}. ${r.lines.isEmpty ? '' : r.lines.first}',
      AssistantPreview p => 'Preparado para confirmar: ${p.title}',
    };
    _remember('Don Bigotes', text);
    if (reply is AssistantResult && reply.transactions.isNotEmpty) _shownMovements = reply.transactions.take(12).toList();
    if (reply is AssistantPreview && reply.items.isNotEmpty) _shownMovements = [for (final i in reply.items.take(12)) i.transaction];
  }

  /// The interpreter's reading, acted on. A correction changes what is open (the draft, a card, the last request);
  /// anything else is a new request (what was open is set aside, said).
  Future<AssistantReply?> _understood(AssistantIntent i, Signals s, FinanceCalculator calc, DateTime now, int heldMinor) async {
    final data = calc.data;
    final draft = _draft;
    switch (i.kind) {
      case IntentKind.courtesy:
        if (draft == null) return AssistantMessage('¡De nada! Aquí estoy si necesitas algo más.');
        return AssistantMessage(draft.preview != null
            ? 'De nada. ${_capital(draft.describe())} sigue esperando: confírmalo, cancélalo o dime qué cambio.'
            : 'De nada. Seguimos cuando quieras: ${draft.question ?? 'dime el dato que falta'}');
      case IntentKind.cancel:
        final open = draft != null || _batch != null || _proposals != null;
        cancel();
        _proposals = null;
        return AssistantMessage(open ? 'Cancelado: no se ha guardado nada.' : 'No había nada pendiente.');
      case IntentKind.unknown:
        // Nothing open: the rules may still recognise a simple sentence. With a draft open, only what is missing is asked.
        return draft == null ? null : _clarify(draft);
      case IntentKind.correction:
        // A card of categories: «el segundo es ocio», «el de [N3], gasolina».
        final proposal = _proposals;
        if (proposal != null && i.targetId != null && proposal.items.any((x) => x.transaction.id == i.targetId)) {
          final item = proposal.items.firstWhere((x) => x.transaction.id == i.targetId);
          final c = _categoryFor(i, item.transaction.type, data);
          if (c != null && chooseCategory(proposal, item.transaction.id, c.id)) {
            return AssistantMessage('Hecho: «${shortConcept(item.transaction)}» irá a ${c.name}. Confírmalo en la tarjeta.');
          }
        }
        if (_batch != null) return AssistantMessage('Para cambiar algo de estas operaciones, pulsa Cancelar y cuéntamelo de nuevo con el cambio.');
        if (draft != null) {
          var changed = _applyIntent(draft, i, data, now);
          // A short answer to the question asked that the interpreter did not turn into data («sí», «la segunda»).
          if (!changed && draft.pending != null) changed = _fill(draft, draft.pending!, s, data, now);
          return changed ? _next(calc, now, heldMinor) : _clarify(draft);
        }
        if (_last != null) {
          i
            ..kind = _last!.kind
            ..refine = true;
          return _fromIntent(i, s, calc, now, heldMinor);
        }
        return AssistantMessage('No hay nada abierto que corregir. ¿Qué quieres apuntar o consultar?');
      default:
        // A card of categories is open and the interpreter reads «change that one»: the card is updated.
        final open = _proposals;
        if (open != null && (i.kind == IntentKind.editMovement || i.kind == IntentKind.describeExisting) && open.items.any((x) => x.transaction.id == i.targetId)) {
          final item = open.items.firstWhere((x) => x.transaction.id == i.targetId);
          final c = _categoryFor(i, item.transaction.type, data);
          if (c != null && i.amountMinor == null && chooseCategory(open, item.transaction.id, c.id)) {
            return AssistantMessage('Hecho: «${shortConcept(item.transaction)}» irá a ${c.name}. Confírmalo en la tarjeta.');
          }
        }
        // The open draft's own kind, without a new amount: it is about the same thing.
        if (draft != null &&
            (i.kind == draft.kind || draft.kind == IntentKind.unknown && (i.kind == IntentKind.expense || i.kind == IntentKind.income)) &&
            (i.amountMinor == null || draft.amountMinor == null || i.amountMinor == draft.amountMinor || draft.preview == null)) {
          final kindChanged = draft.kind == IntentKind.unknown;
          if (kindChanged) {
            draft
              ..kind = i.kind
              ..pending = null;
          }
          final changed = _applyIntent(draft, i, data, now) || kindChanged || draft.pending != null && _fill(draft, draft.pending!, s, data, now);
          return changed ? _next(calc, now, heldMinor) : _clarify(draft);
        }
        return _fromIntent(i, s, calc, now, heldMinor);
    }
  }

  Category? _categoryFor(AssistantIntent i, TransactionType type, Finances data) {
    bool fits(Category c) => !c.isArchived && categorySupports(c, type);
    final marked = data.category(i.categoryId);
    if (marked != null && fits(marked)) return marked;
    final words = i.categoryText;
    if (words == null) return null;
    final named = namedCategory(words, data, fits);
    if (named != null) return named;
    final concept = extractConcept(words, data) ?? words;
    final (found, _) = hintedCategories(concept, data, fits);
    return found.length == 1 ? found.single : null;
  }

  /// The interpreter's correction applied to the open draft: only what it states changes. Returns whether anything did.
  bool _applyIntent(_Draft d, AssistantIntent i, Finances data, DateTime now) {
    var changed = false;
    void apply(bool condition, void Function() change) {
      if (!condition) return;
      change();
      changed = true;
    }

    final plan = d.kind == IntentKind.createPlan;
    final said = _amountsSaid;
    apply(i.amountMinor != null && i.amountMinor != d.amountMinor && (said == null || said.contains(i.amountMinor)), () {
      d.amountMinor = i.amountMinor;
      if (plan && i.perInstalment != null) d.perInstalment = i.perInstalment!;
    });
    if (plan) {
      apply(i.count != null && i.count != d.count, () => d.count = i.count);
      apply(i.dueDate != null && i.dueDate != d.dueDate, () {
        d.dueDate = i.dueDate;
        d.dueDay = null;
      });
      apply(i.dueDate == null && i.dueDay != null && i.dueDay != d.dueDay && d.dueDate == null, () {
        d.dueDay = i.dueDay;
        d.roughDay = false;
      });
      apply(i.planKind != null && i.planKind != d.planKind, () => d.planKind = i.planKind);
      apply(i.purpose != null && i.purpose != d.planName, () => d.planName = _capital(i.purpose!));
      apply(i.recorded != null && i.recorded != d.recorded, () => d.recorded = i.recorded);
    } else {
      final future = d.kind == IntentKind.createGoal;
      apply(i.date != null && i.date != d.date && (future || !i.date!.isAfter(now)), () => d.date = i.date);
    }
    final account = data.account(i.accountId) ?? (i.accountText == null ? null : _onlyAccount(i.accountText!, data));
    apply(account != null && account.id != d.accountId, () {
      d.accountId = account!.id;
      d.accountGuessed = false;
    });
    apply(i.toAccountId != null && i.toAccountId != d.toAccountId, () => d.toAccountId = i.toAccountId);
    apply(i.goalId != null && i.goalId != d.goalId, () => d.goalId = i.goalId);
    apply(i.targetId != null && i.targetId != d.targetId, () => d.targetId = i.targetId);
    apply(i.findAmountMinor != null && i.findAmountMinor != d.findAmountMinor, () {
      d.findAmountMinor = i.findAmountMinor;
      if (i.targetId == null) d.targetId = null;
    });
    apply(i.findDate != null && i.findDate != d.findDate, () => d.findDate = i.findDate);
    apply(i.role != null && i.role != d.role, () => d.role = i.role);
    apply(i.recurring != null && i.recurring != d.recurring, () => d.recurring = i.recurring!);
    final type = d.kind == IntentKind.income || d.incoming == true ? TransactionType.income : TransactionType.expense;
    if (i.clearCategory == true) {
      apply(d.categoryId != null || !d.categoryDecided, () {
        d.categoryId = null;
        d.categoryDecided = true;
        d.proposal = null;
      });
    } else {
      final c = _categoryFor(i, type, data);
      apply(c != null && c.id != d.categoryId, () {
        d.categoryId = c!.id;
        d.categoryDecided = true;
        d.proposal = null;
      });
    }
    final named = d.kind == IntentKind.expense || d.kind == IntentKind.income || d.kind == IntentKind.editMovement || d.kind == IntentKind.createRule ||
        d.kind == IntentKind.transfer;
    apply(named && i.concept != null && i.concept != d.concept, () => d.concept = _capital(i.concept!));
    final purposed = d.kind == IntentKind.reserve || d.kind == IntentKind.createGoal;
    apply(purposed && i.purpose != null && i.purpose != d.purpose, () => d.purpose = _capital(i.purpose!));
    if (changed) d.pending = null;
    return changed;
  }

  Account? _onlyAccount(String text, Finances data) {
    final named = namedAccounts(text, data);
    return named.length == 1 ? named.single.account : null;
  }

  /// Resolves a model's intent with the same rules as a sentence understood here. Null when it says nothing useful
  /// (the rules then try).
  Future<AssistantReply?> _fromIntent(AssistantIntent i, Signals s, FinanceCalculator calc, DateTime now, int heldMinor, {bool nested = false}) async {
    final data = calc.data;
    final draft = _draft;
    if (i.kind == IntentKind.unknown) return null;
    if (i.kind == IntentKind.correction) return null;
    // A new request: an open draft is set aside, said explicitly (never by a later step of the same request).
    final note = draft == null || nested ? null : _park();
    AssistantReply reply;
    // An action on existing movements is never answered with a list: an interpreter without this capability (or
    // one that misreads it) reads «ponles categoría» as a query. A correction of a categorisation stays one.
    var kind = i.kind;
    var steps = i.also;
    var main = i;
    // «Enséñame los sin categoría y pónselas»: categorising shows the same movements as cards; the list would repeat them.
    final categorizeStep = steps.where((step) => step.kind == IntentKind.categorize).firstOrNull;
    if (kind == IntentKind.listMovements && categorizeStep != null) {
      kind = IntentKind.categorize;
      main = categorizeStep;
    }
    if (kind == IntentKind.categorize || categorizeStep != null) {
      steps = [for (final step in steps) if (step.kind != IntentKind.listMovements && step.kind != IntentKind.categorize) step];
    }
    switch (kind) {
      case IntentKind.simulation:
        reply = await _start(i.kind, s, calc, now, heldMinor);
      case IntentKind.courtesy || IntentKind.cancel || IntentKind.correction || IntentKind.unknown:
        return null;
      case IntentKind.planStatus:
        reply = _planStatus(Signals(i.planText ?? '', now), data, now);
      case IntentKind.unsupported:
        reply = AssistantMessage(_unsupported(i.purpose ?? i.concept));
      case IntentKind.summary:
        final period = i.period ?? (i.refine == true ? _last?.selection.period : null) ?? QueryPeriod.thisMonth;
        reply = _summary(calc, now, Signals(i.categoryText ?? '', now), period);
      case IntentKind.listMovements || IntentKind.categorize:
        var change = _selectionOf(i, data);
        if (!identical(main, i)) change = change.refinedBy(_selectionOf(main, data));
        final selection = (i.refine == true || main.refine == true) && _last != null ? _last!.selection.refinedBy(change) : change;
        reply = kind == IntentKind.categorize ? await _categorize(selection, calc, now) : _list(calc, now, selection);
      default:
        final d = _draft = _Draft(i.kind)
          ..amountMinor = i.amountMinor
          ..date = i.date != null && (i.kind == IntentKind.createGoal || !i.date!.isAfter(now)) ? i.date : null
          ..concept = i.concept == null ? null : _capital(i.concept!)
          ..accountId = data.account(i.accountId)?.id
          ..toAccountId = data.account(i.toAccountId)?.id
          ..goalId = i.goalId
          ..targetId = i.targetId
          ..findAmountMinor = i.findAmountMinor
          ..findDate = i.findDate
          ..recurring = i.recurring ?? true;
        if (i.kind == IntentKind.reserve || i.kind == IntentKind.createGoal) d.purpose = i.purpose == null ? null : _capital(i.purpose!);
        if (i.kind == IntentKind.createRule) d.incoming = i.scope == QueryScope.income;
        if (i.kind == IntentKind.editMovement || i.kind == IntentKind.setBudget || i.kind == IntentKind.createRule) {
          final type = i.kind == IntentKind.createRule && i.scope == QueryScope.income ? TransactionType.income : TransactionType.expense;
          final target = data.transactions.where((t) => t.id == i.targetId).firstOrNull;
          final c = _categoryFor(i, target?.type ?? type, data);
          if (c != null) {
            d.categoryId = c.id;
            d.categoryDecided = true;
          } else if (i.clearCategory == true) {
            d.categoryDecided = true;
          }
        }
        if (i.kind == IntentKind.createPlan) {
          d.count = i.count;
          d.perInstalment = i.perInstalment ?? false;
          // The model's due date only when the sentence says the month; a day alone asks for it.
          d.dueDate = i.dueDate != null && _saysMonth(s) ? i.dueDate : null;
          d.dueDay = d.dueDate == null ? (i.dueDay ?? i.dueDate?.day) : null;
          d.planKind = i.planKind;
          d.planName = i.purpose;
          d.date = null;
        }
        if (i.kind == IntentKind.payInstalment) {
          d.instalmentNumber = i.instalmentNumber;
          d.planId = i.planId ?? (i.planText == null ? null : _namedPlan(i.planText!, data)?.id);
        }
        if (i.kind == IntentKind.describeExisting) {
          d.role = i.role ?? _roleOf(s, null);
          d.incoming = i.scope == QueryScope.income ? true : (i.scope == QueryScope.expenses ? false : null);
          d.date = i.date;
        }
        if (d.accountId == null && i.accountText != null) {
          final named = namedAccounts(i.accountText!, data, allowed: i.kind == IntentKind.reserve ? _reservable : null);
          if (named.length == 1) d.accountId = named.single.account.id;
          if (named.length > 1) d.accountOptions = named;
        }
        if (i.kind == IntentKind.expense || i.kind == IntentKind.income) {
          final c = _categoryFor(i, i.kind == IntentKind.income ? TransactionType.income : TransactionType.expense, data);
          if (c != null) {
            d.categoryId = c.id;
            d.categoryDecided = true;
          }
        }
        reply = await _next(calc, now, heldMinor);
    }
    reply.note ??= note;
    reply.canResume = note != null;
    // The other steps of a combined request, in order (at most two). A step that prepares something to confirm waits
    // while another one is open, said; a step that fails is said and does not undo the others.
    if (!nested) {
      for (final step in steps) {
        if (_preparesDraft(step.kind) && _draft != null) {
          if (_together(step.kind) && _together(_draft!.kind)) {
            _queue.add(step);
            continue;
          }
          reply.followUps.add(AssistantMessage('${_capital(_stepTitle(step.kind))} que también pediste lo preparo cuando termines con esto: dímelo entonces.'));
          break;
        }
        try {
          final next = await _fromIntent(step, Signals('', now), calc, now, heldMinor, nested: true);
          if (next != null) reply.followUps.add(next);
        } catch (_) {
          reply.followUps.add(AssistantMessage('No he podido hacer ${_stepTitle(step.kind)}; lo anterior sí está hecho.'));
        }
      }
    }
    return reply;
  }

  MovementSelection _selectionOf(AssistantIntent i, Finances data) {
    final accounts = i.accountText == null ? const <AccountChoice>[] : namedAccounts(i.accountText!, data);
    final category = i.categoryText == null ? null : namedCategory(i.categoryText!, data, (_) => true);
    return MovementSelection(
      period: i.period,
      from: i.from,
      to: i.to,
      scope: i.scope,
      uncategorized: i.uncategorized,
      categoryId: category?.id,
      accountId: accounts.length == 1 ? accounts.single.account.id : null,
      limit: i.limit,
    );
  }

  static bool _preparesDraft(IntentKind k) => const {
        IntentKind.expense,
        IntentKind.income,
        IntentKind.reserve,
        IntentKind.transfer,
        IntentKind.createPlan,
        IntentKind.payInstalment,
        IntentKind.describeExisting,
        IntentKind.editMovement,
        IntentKind.deleteMovement,
        IntentKind.setBudget,
        IntentKind.createGoal,
        IntentKind.addToGoal,
        IntentKind.createRule,
      }.contains(k);

  /// What can be confirmed together with other things of the same story: new movements, transfers and reserves.
  static bool _together(IntentKind k) => const {IntentKind.expense, IntentKind.income, IntentKind.transfer, IntentKind.reserve}.contains(k);

  /// When the draft is ready (its preview), the next thing of the story is prepared; when all are ready, they are
  /// shown together, to confirm with one tap.
  Future<AssistantReply> _afterReply(AssistantReply reply, FinanceCalculator calc, DateTime now, int heldMinor) async {
    var current = reply;
    while (current is AssistantPreview && _queue.isNotEmpty && identical(_draft?.preview, current) && _together(_draft!.kind)) {
      _ready.add(current);
      _draft = null;
      final step = _queue.removeAt(0);
      current = await _fromIntent(step, Signals('', now), calc, now, heldMinor, nested: true) ?? AssistantMessage('No he entendido una de las cosas que me has contado.');
    }
    if (current is AssistantPreview && _ready.isNotEmpty && identical(_draft?.preview, current)) {
      final parts = [..._ready, current];
      _ready.clear();
      _draft = null;
      final batch = _batch = AssistantPreview(
        id: newId(),
        kind: PreviewKind.batch,
        title: '${parts.length} operaciones',
        lines: const [],
        effects: const ['Se guardan juntas. Si algo no está bien, pulsa Cancelar y cuéntamelo de nuevo con el cambio.'],
        warnings: [for (final p in parts) ...p.warnings],
        operation: batchOperation([for (final p in parts) p.operation]),
        parts: parts,
      );
      batch.note = reply.note;
      batch.followUps.addAll(reply.followUps);
      return batch;
    }
    if (!identical(current, reply)) {
      // What the first answer also brought (a summary asked in the same story) is not lost.
      current.followUps.insertAll(0, reply.followUps);
      current.note ??= reply.note;
    }
    if (current is AssistantQuestion && _ready.isNotEmpty) {
      current.note = 'Ya tengo ${_ready.map((p) => p.title.toLowerCase()).join(' y ')}; para lo siguiente me falta un dato.';
    } else if (current is AssistantQuestion && _queue.isNotEmpty) {
      current.note ??= 'Después sigo con lo demás que me has contado.';
    }
    return current;
  }

  static String _stepTitle(IntentKind k) => switch (k) {
        IntentKind.expense => 'el gasto',
        IntentKind.income => 'el ingreso',
        IntentKind.reserve => 'la reserva',
        IntentKind.createPlan => 'el pago a plazos',
        IntentKind.payInstalment => 'la cuota',
        IntentKind.describeExisting => 'el cambio del movimiento',
        IntentKind.categorize => 'lo de las categorías',
        IntentKind.summary => 'el resumen',
        _ => 'la consulta',
      };

  /// An action the chat does not have: said, with what it can do instead. Never replaced by another action.
  String _unsupported(String? what) =>
      'Eso no puedo hacerlo desde el chat${what == null ? '' : ' («$what»)'}. Puedo enseñarte movimientos, ponerles categoría o apuntar gastos, '
      'ingresos, reservas y pagos a plazos. Para borrar o cambiar un movimiento, ábrelo y hazlo desde su detalle.';

  bool _saysMonth(Signals s) => RegExp('(${_months.keys.join('|')}|\\d/\\d|mes que viene|proximo mes|siguiente mes|este mes)').hasMatch(s.plain);

  /// A tapped option of the last question.
  Future<AssistantReply> choose(String value, FinanceCalculator calc, DateTime now, {int heldMinor = 0}) async {
    final reply = await _afterReply(await _choose(value, calc, now, heldMinor), calc, now, heldMinor);
    _rememberReply(reply);
    return reply;
  }

  Future<AssistantReply> _choose(String value, FinanceCalculator calc, DateTime now, int heldMinor) async {
    if (_scopeWaiting != null && value.startsWith('scope:')) return _scopeChosen(value == 'scope:category', calc, now);
    final draft = _draft;
    if (draft == null || draft.pending == null) return AssistantMessage('Eso ya no está pendiente. ¿Qué quieres apuntar o consultar?');
    if (value.startsWith('due:')) {
      final d = DateTime.tryParse(value.substring(4));
      if (d == null) return _clarify(draft);
      draft
        ..dueDate = DateTime(d.year, d.month, d.day, 12)
        ..dueDay = null
        ..pending = null;
      return _next(calc, now, heldMinor);
    }
    if (value.startsWith('to:')) {
      draft
        ..toAccountId = value.substring(3)
        ..pending = null;
      return _next(calc, now, heldMinor);
    }
    if (value.startsWith('goal:')) {
      draft
        ..goalId = value.substring(5)
        ..pending = null;
      return _next(calc, now, heldMinor);
    }
    if (value.startsWith('target:')) {
      draft
        ..targetId = value.substring(7)
        ..pending = null;
      return _next(calc, now, heldMinor);
    }
    if (value.startsWith('role:')) {
      draft
        ..role = value.substring(5)
        ..pending = null;
      return _next(calc, now, heldMinor);
    }
    if (value.startsWith('loancat:')) {
      draft
        ..loanCategory = value.substring(8)
        ..pending = null;
      return _next(calc, now, heldMinor);
    }
    if (value == 'total:same') {
      draft
        ..pending = null
        ..purpose = 'total:same';
      return _next(calc, now, heldMinor);
    }
    if (value == 'due:other') return _ask(draft, PendingField.dueDate, '¿Qué día vence la primera cuota? (por ejemplo, «el 5 de diciembre»)');
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
      case PendingField.amount || PendingField.purpose || PendingField.count || PendingField.planName || PendingField.dueDate || PendingField.dueMonth:
        break;
      case PendingField.target || PendingField.role || PendingField.loanTotal || PendingField.loanCategory || PendingField.toAccount || PendingField.goal || PendingField.change:
        break;
    }
    draft.pending = null;
    return _next(calc, now, heldMinor);
  }

  Future<AssistantReply> _scopeChosen(bool category, FinanceCalculator calc, DateTime now) async {
    _comprasIsCategory = category;
    final w = _scopeWaiting!;
    _scopeWaiting = null;
    return _list(calc, now, MovementSelection(period: w.period, scope: QueryScope.expenses, accountId: w.accountId), compras: true);
  }

  IntentKind _decide(Signals s, Finances data) {
    if (s.existing) return IntentKind.describeExisting;
    if (s.unsupported) return IntentKind.unsupported;
    if (s.categorize) return IntentKind.categorize;
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
    // «y solo los gastos», «los ingresos»: without an amount, a noun of movements after a query continues it.
    if (s.listNoun && s.amountMinor == null && _last != null && !s.register) return _last!.kind;
    // A statement in the past without amount and with a period asks about it («he comprado cosas este mes»).
    if (s.amountMinor == null && s.period != null && (s.spend || s.earn || s.listNoun) && !s.register) return IntentKind.listMovements;
    if (s.earn && !s.spend) return IntentKind.income;
    if (s.spend) return IntentKind.expense;
    if (s.earn) return IntentKind.income;
    if (s.listNoun && _last != null) return IntentKind.listMovements;
    if (_last != null && (s.continuation || s.uncategorized || s.limit != null || s.period != null || namedCategory(s.raw, data, (_) => true) != null)) return _last!.kind;
    return IntentKind.unknown;
  }

  Future<AssistantReply> _start(IntentKind kind, Signals s, FinanceCalculator calc, DateTime now, int heldMinor, {bool park = false}) async {
    final note = park ? _park() : null;
    final reply = await _begin(kind, s, calc, now, heldMinor);
    if (note != null) {
      reply.note ??= note;
      reply.canResume = true;
    }
    return reply;
  }

  Future<AssistantReply> _begin(IntentKind kind, Signals s, FinanceCalculator calc, DateTime now, int heldMinor) async {
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
        return AssistantMessage('No te he entendido. ¿Quieres apuntar algo, consultar tus movimientos o decirme qué es uno que ya tienes?');
      case IntentKind.correction:
        return AssistantMessage('No hay nada abierto que corregir. ¿Qué quieres apuntar o consultar?');
      case IntentKind.simulation:
        return AssistantPointer('Las simulaciones aún no se hacen desde el chat. En la previsión puedes simular un gasto sin apuntarlo.', kind);
      case IntentKind.transfer:
        final named = namedAccounts(s.raw, data);
        _draft = _Draft(kind)
          ..amountMinor = s.amountMinor
          ..date = s.date
          // «a Naranja»: one account named is where it goes; two, from the first to the second.
          ..accountId = named.length == 2 ? named.first.account.id : null
          ..toAccountId = named.length == 1 || named.length == 2 ? named.last.account.id : null;
        return _next(calc, now, heldMinor);
      case IntentKind.listMovements:
      case IntentKind.summary:
      case IntentKind.categorize:
        return _query(kind, s, calc, now);
      case IntentKind.unsupported:
        return AssistantMessage('Sin el intérprete no puedo borrar ni cambiar movimientos por chat: actívalo en Ajustes o hazlo desde el detalle del movimiento.');
      case IntentKind.editMovement || IntentKind.deleteMovement || IntentKind.setBudget || IntentKind.createGoal || IntentKind.addToGoal || IntentKind.createRule:
        return AssistantMessage('Eso lo entiendo con el intérprete activado (Ajustes). Sin él, puedo apuntar gastos, ingresos, reservas y pagos a plazos, y enseñarte movimientos.');
      case IntentKind.courtesy:
        return AssistantMessage('¡De nada! Aquí estoy si necesitas algo más.');
      case IntentKind.cancel:
        cancel();
        return AssistantMessage('Cancelado: no se ha guardado nada.');
      case IntentKind.planStatus:
        return _planStatus(s, data, now);
      case IntentKind.describeExisting:
        final d = _draft = _Draft(kind)
          ..amountMinor = s.amountMinor
          ..date = s.date
          ..concept = extractConcept(s.raw, data)
          ..incoming = _any(s.words, ['ingreso*', 'abono*', 'entrada*', 'recibi*', 'cobr*'])
              ? true
              : (_any(s.words, ['cargo*', 'gasto*', 'pago*', 'compra*', 'salida*']) ? false : null);
        d.role = _roleOf(s, d.incoming);
        final named = namedAccounts(s.raw, data);
        if (named.length == 1) d.accountId = named.single.account.id;
        final category = namedCategory(s.raw, data, (_) => true);
        if (category != null) {
          d.categoryId = category.id;
          d.categoryDecided = true;
        }
        return _next(calc, now, heldMinor);
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
          if (d.dueDate == null && RegExp(r'(primera|vence|cada mes|de cada|el dia|los dias)').hasMatch(s.plain)) d.dueDay = dueDay(s.raw);
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
        d.planName = _capital(s.raw.trim().replaceAll(RegExp(r'^(se llama|llamalo|llámalo|ponle)\s+', caseSensitive: false), ''));
      case PendingField.dueDate:
        if (s.dueDate != null) {
          d.dueDate = s.dueDate;
          d.dueDay = null;
        } else if (dueDay(s.raw) != null && !moneyCue(s)) {
          d.dueDay = dueDay(s.raw); // the month is asked next
        } else if (roughDueDay(s.raw) != null) {
          d.dueDay = roughDueDay(s.raw);
          d.roughDay = true;
        } else {
          return false;
        }
      case PendingField.dueMonth:
        final day = d.dueDay ?? dueDay(s.raw);
        final padded = ' ${s.plain.replaceAll(RegExp(r'[^a-z0-9/]+'), ' ')} ';
        final named = _months.entries.where((e) => padded.contains(' ${e.key} ')).firstOrNull?.value;
        final offset = _monthOffset(padded);
        if (s.dueDate != null) {
          d.dueDate = s.dueDate;
        } else if (day != null && (named != null || offset != null)) {
          final month = named ?? now.month + offset!;
          var date = DateTime(now.year, month, day, 12);
          if (named != null && date.isBefore(DateTime(now.year, now.month - 6))) date = DateTime(now.year + 1, month, day, 12);
          if (date.day != day) return false;
          d.dueDate = date;
        } else {
          return false;
        }
        d.dueDay = null;
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
      case PendingField.target:
        return false; // chosen from the list shown
      case PendingField.toAccount:
        final named = namedAccounts(s.raw, data);
        if (named.length != 1) return false;
        d.toAccountId = named.single.account.id;
      case PendingField.goal:
        final named = data.goals.where((g) => _nameWords(g.name).any((w) => _mentions(s.words, w))).toList();
        if (named.length != 1) return false;
        d.goalId = named.single.id;
      case PendingField.change:
        return _update(d, s, null, data, now);
      case PendingField.loanCategory:
        if (_any(s.words, ['ninguna', 'sin', 'nada', 'no'])) {
          d.loanCategory = 'none';
        } else if (_any(s.words, ['crea*', 'nueva', 'si'])) {
          d.loanCategory = 'new';
        } else {
          final c = namedCategory(s.raw, data, (c) => categorySupports(c, TransactionType.income));
          if (c == null) return false;
          d.loanCategory = c.id;
        }
      case PendingField.role:
        final role = _roleOf(s, d.incoming);
        if (role == null) return false;
        d.role = role;
      case PendingField.loanTotal:
        if (_any(s.words, ['si', 'mismo', 'igual', 'eso'])) {
          d.purpose = 'total:same';
        } else if (s.amountMinor != null) {
          d.count = null;
          d.purpose = 'total:${s.amountMinor}';
        } else {
          return false;
        }
    }
    d.pending = null;
    return true;
  }

  /// Applies to the open draft what the sentence changes, from the rules' reading and the model's ([i]), with the
  /// same guards: the amount only when the sentence speaks of money (a number in a date is never the debt), the
  /// count only when it speaks of instalments, a due date's month only when said. True when something changed.
  bool _update(_Draft d, Signals s, AssistantIntent? i, Finances data, DateTime now) {
    var changed = false;
    final plan = d.kind == IntentKind.createPlan;
    // A plain amount correction («no, eran 45», «fueron cuarenta y cinco») is the amount where there is no other number.
    final aboutMoney = moneyCue(s) || d.pending == PendingField.amount || (!plan && s.correction && s.date == null);
    final amount = s.amountMinor ?? i?.amountMinor;
    if (amount != null && aboutMoney && amount != d.amountMinor) {
      d.amountMinor = amount;
      if (plan) d.perInstalment = amountIsPerInstalment(s.raw) || (i?.perInstalment ?? false);
      changed = true;
    }
    if (plan) {
      final count = s.count ?? (i?.count != null && _any(s.words, ['cuota*', 'mes*', 'plazo*', 'mensualidad*', 'pagos']) ? i!.count : null);
      if (count != null && count != d.count) {
        d.count = count;
        changed = true;
      }
      final due = s.dueDate ?? (i?.dueDate != null && _saysMonth(s) ? i!.dueDate : null);
      if (due != null && due != d.dueDate) {
        d.dueDate = due;
        d.dueDay = null;
        changed = true;
      } else if (d.dueDate == null && !aboutMoney) {
        final day = (d.pending == PendingField.dueDate || d.pending == PendingField.dueMonth ? dueDay(s.raw) : null) ?? i?.dueDay;
        if (day != null && day != d.dueDay) {
          d.dueDay = day;
          d.roughDay = false;
          changed = true;
        }
      }
      final kind = _planKind(s) ?? (_any(s.words, ['prestamo*', 'compra*', 'credito', 'otro', 'otra']) ? i?.planKind : null);
      if (kind != null && kind != d.planKind) {
        d.planKind = kind;
        changed = true;
      }
      final name = RegExp(r'(?:llamalo|ponle de nombre|se llama|el nombre es)\s*:?\s*(.+)$').firstMatch(s.plain);
      if (name != null) {
        d.planName = _capital(s.raw.substring(s.raw.length - name.group(1)!.length).trim());
        changed = true;
      }
    } else {
      final date = s.date ?? (i?.date != null && !i!.date!.isAfter(now) ? i.date : null);
      if (date != null && date != d.date) {
        d.date = date;
        changed = true;
      }
    }
    final accountText = namedAccounts(s.raw, data).isNotEmpty ? s.raw : i?.accountText;
    final named = accountText == null ? const <AccountChoice>[] : namedAccounts(accountText, data, allowed: d.kind == IntentKind.reserve ? _reservable : null);
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
        final c = namedCategory(s.raw, data, (c) => categorySupports(c, type)) ??
            (i?.categoryText == null ? null : namedCategory(i!.categoryText!, data, (c) => categorySupports(c, type)));
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
    if (d.kind == IntentKind.reserve && i?.purpose != null && s.correction && i!.purpose != d.purpose) {
      d.purpose = i.purpose;
      changed = true;
    }
    if (changed) d.pending = null;
    return changed;
  }

  AssistantQuestion _ask(_Draft d, PendingField field, String text, [List<(String, String)> options = const []]) {
    d
      ..pending = field
      ..question = text
      ..questionOptions = options;
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
      case IntentKind.describeExisting:
        return _nextExisting(d, calc, now);
      case IntentKind.payInstalment:
        return _nextInstalment(d, calc, now);
      case IntentKind.transfer:
        return _nextTransfer(d, calc, now, heldMinor);
      case IntentKind.editMovement:
        return _nextEdit(d, calc, now);
      case IntentKind.deleteMovement:
        return _nextDelete(d, calc, now);
      case IntentKind.setBudget:
        return _nextBudget(d, calc, now);
      case IntentKind.createGoal:
        return _nextGoal(d, calc, now);
      case IntentKind.addToGoal:
        return _nextAddToGoal(d, calc, now);
      case IntentKind.createRule:
        return _nextRule(d, calc, now);
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
    final usual = options == null ? _usualAccount(d, data, active) : null;
    if (usual != null) {
      d
        ..accountId = usual.id
        ..accountGuessed = true;
      return usual;
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
        ('Cuenta', '${account.name}${d.accountGuessed ? ' (la que sueles usar)' : ''}'),
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
    if (d.dueDate == null && d.dueDay != null) {
      final day = d.dueDay!;
      final options = <(String, String)>[];
      for (var m = 0; options.length < (d.roughDay ? 2 : 3) && m < 4; m++) {
        final date = DateTime(now.year, now.month + m, day, 12);
        if (date.day != day || date.isBefore(DateTime(now.year, now.month, now.day))) continue;
        options.add((_longDate(date), 'due:${date.toIso8601String().substring(0, 10)}'));
      }
      return _ask(
          d,
          d.roughDay ? PendingField.dueDate : PendingField.dueMonth,
          d.roughDay
              ? '¿Te vale que la primera cuota sea el ${options.first.$1}? Si el contrato dice otro día, escríbelo.'
              : 'Entonces, el día $day de cada mes. ¿En qué mes es la primera cuota?',
          [...options, if (d.roughDay) ('Otro día', 'due:other')]);
    }
    if (d.dueDate == null) return _ask(d, PendingField.dueDate, '¿Cuándo vence la primera cuota? (por ejemplo, «el 5 de diciembre» o «el día 5 de cada mes»)');
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
    // A loan whose money is «already recorded»: that income is found and linked (it is not created again). One
    // candidate of exactly that amount is linked; several are asked with their date, account and amount.
    if (d.planKind == InstallmentKind.loan && d.recorded == true) {
      if (d.targetId != null) d.linkIncomeId = d.targetId;
      if (d.linkIncomeId == null && !d.incomeLookedFor) {
        final candidates = _loanIncomes(data, total, now);
        if (candidates.length > 1) {
          return _ask(d, PendingField.target, '¿Cuál de estos ingresos es el dinero del préstamo?', [
            for (final t in candidates.take(6)) (_label(t, data), 'target:${t.id}'),
          ]);
        }
        d.incomeLookedFor = true;
        if (candidates.length == 1) d.linkIncomeId = candidates.single.id;
      }
      final income = data.transactions.where((t) => t.id == d.linkIncomeId).firstOrNull;
      final ask = income == null ? null : _askLoanCategory(d, income, data);
      if (ask != null) return ask;
    }
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
    final income = d.linkIncomeId == null ? null : data.transactions.where((t) => t.id == d.linkIncomeId).firstOrNull;
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
        if (income != null) ('Dinero recibido', _label(income, data)),
        if (income != null && d.loanCategory != null && d.loanCategory != 'none')
          ('Categoría del ingreso', d.loanCategory == 'new' ? 'Préstamo recibido (nueva)' : data.category(d.loanCategory)?.name ?? ''),
      ],
      effects: [
        'Hoy no se registra ningún pago: cada cuota se apunta cuando la pagas.',
        if (income == null && d.planKind == InstallmentKind.loan && d.recorded == true)
          'No encuentro un ingreso de ${money(total)} para vincular. Cuando quieras, dime cuál es («el ingreso de … € es el préstamo»).',
        if (income != null)
          'El ingreso de ${money(income.amountMinor)} del ${income.date.day}/${income.date.month} queda vinculado como el dinero de este préstamo: '
              'deja de contar como ingreso del día a día. No se crea ningún movimiento nuevo.',
        installmentEffect(plan),
      ],
      calendar: [for (final i in schedule) (i.dueDate, i.amountMinor)],
      operation: income == null
          ? savePlanOperation(plan: plan, create: true, data: data, now: now)
          : batchOperation([savePlanOperation(plan: plan, create: true, data: data, now: now), loanReceivedOperation(plan, income, now), ..._loanCategoryOps(d, income, data, now)]),
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

  /// What an existing movement is, from words: the money of a loan, something paid with it, an instalment, or a
  /// category. Null when the sentence does not say.
  String? _roleOf(Signals s, bool? incoming) {
    final loan = _any(s.words, ['prestamo*', 'credito', 'financiacion']);
    if (loan && (incoming == true || _any(s.words, ['recib*', 'ingres*', 'concedi*', 'dieron', 'dio', 'abono*', 'entrada*']))) return 'loanReceived';
    if (loan && (incoming == false || _any(s.words, ['use', 'usado', 'gaste', 'pague', 'compre', 'gastado', 'pagado', 'comprado']))) return 'loanUse';
    if (_any(s.words, ['cuota*', 'mensualidad*', 'plazo*'])) return 'instalment';
    if (_any(s.words, ['categoria*']) || extractConcept(s.raw, Finances()) != null) return 'category';
    return null;
  }

  String _label(Transaction t, Finances data) =>
      '${t.date.day}/${t.date.month} · ${data.account(t.sourceAccountId)?.name ?? ''} · ${t.type.countsAsIncome ? '+' : '−'}${money(t.amountMinor)}';

  /// An existing movement described by the person: it is found among the person's own movements, what it is is
  /// asked when not said, and a change of that same record is prepared (never a new income, expense or loan).
  Future<AssistantReply> _nextExisting(_Draft d, FinanceCalculator calc, DateTime now) async {
    final data = calc.data;
    if (d.amountMinor == null) return _ask(d, PendingField.amount, '¿De qué importe es el movimiento?');
    if (d.targetId == null) {
      final candidates = [
        for (final t in data.transactions)
          if (t.amountMinor.abs() == d.amountMinor &&
              (d.incoming == null || (d.incoming! ? t.type.countsAsIncome : t.type.countsAsExpense)) &&
              (d.accountId == null || t.sourceAccountId == d.accountId) &&
              (d.date == null || DateTime(t.date.year, t.date.month, t.date.day) == DateTime(d.date!.year, d.date!.month, d.date!.day)) &&
              t.date.isAfter(now.subtract(const Duration(days: 120))))
            t
      ];
      if (candidates.isEmpty) {
        _draft = null;
        return AssistantMessage('No encuentro ningún ${d.incoming == true ? 'ingreso' : (d.incoming == false ? 'cargo' : 'movimiento')} de ${money(d.amountMinor!)} '
            'en los últimos meses${d.accountId == null ? '' : ' en ${data.account(d.accountId)?.name}'}. No creo uno nuevo: dime la cuenta o la fecha, o búscalo en Movimientos.');
      }
      if (candidates.length > 1) {
        return _ask(d, PendingField.target, '¿Cuál de estos es?', [for (final t in candidates.take(8)) (_label(t, data), 'target:${t.id}')]);
      }
      d.targetId = candidates.single.id;
    }
    final target = data.transactions.where((t) => t.id == d.targetId).firstOrNull;
    if (target == null) {
      _draft = null;
      return AssistantMessage('Ese movimiento ya no está. No he cambiado nada.');
    }
    final incoming = target.type.countsAsIncome;
    final fits = switch (d.role) {
      'loanReceived' => incoming,
      'loanUse' || 'instalment' => !incoming,
      _ => true,
    };
    if (d.role == null || !fits) {
      return _ask(
          d,
          PendingField.role,
          '${fits ? '' : 'Eso no encaja con un ${incoming ? 'ingreso' : 'cargo'}. '}¿Qué es el ${incoming ? 'ingreso' : 'cargo'} de ${money(target.amountMinor)} del ${target.date.day}/${target.date.month}?',
          incoming
              ? [('Dinero de un préstamo recibido', 'role:loanReceived'), ('Otra cosa: una categoría', 'role:category')]
              : [('Algo pagado con el dinero de un préstamo', 'role:loanUse'), ('Una cuota de un pago a plazos', 'role:instalment'), ('Otra cosa: una categoría', 'role:category')]);
    }
    final stamp = referenceSeconds(now);
    final restore = Operation('patch', {
      'id': target.id,
      'fields': {'externalID': target.externalId, 'categoryID': target.categoryId, 'descriptionText': target.descriptionText, 'notes': target.notes, 'updatedAt': stamp}
    });
    final loans = data.installmentPlans.where((p) => !p.isArchived && p.kind == InstallmentKind.loan).toList();
    final unlinked = loans.where((p) => !data.transactions.any((t) => t.loanPlanId == p.id)).toList();
    switch (d.role!) {
      case 'loanReceived':
        if (target.externalId != null) {
          _draft = null;
          return AssistantMessage('Ese ingreso ya está vinculado a otra cosa. No he cambiado nada.');
        }
        if (unlinked.length > 1 && d.planId == null) return _ask(d, PendingField.plan, '¿De qué préstamo es este dinero?', [for (final p in unlinked) (p.name, p.id)]);
        final plan = unlinked.length == 1 ? unlinked.single : unlinked.where((p) => p.id == d.planId).firstOrNull;
        if (plan != null) {
          final ask = _askLoanCategory(d, target, data);
          if (ask != null) return ask;
          final ops = [
            loanReceivedOperation(plan, target, now),
            ..._loanCategoryOps(d, target, data, now),
            if (!plan.alreadyRecorded) upsertOperation('installmentPlans', {'id': plan.id, 'alreadyRecorded': true, 'updatedAt': stamp}, create: false),
          ];
          return d.preview = AssistantPreview(
            id: d.previewId ??= newId(),
            kind: PreviewKind.existing,
            title: 'Dinero del préstamo · ${money(target.amountMinor)}',
            lines: [('Movimiento', _label(target, data)), ('Préstamo', plan.name), ('Total a devolver', '${money(plan.totalMinor)} en ${plan.count} cuotas')],
            effects: [
              'El ingreso deja de contar como ingreso del día a día: es dinero prestado.',
              'No se crea ningún movimiento ni otro préstamo; el saldo no cambia.',
              if (!plan.alreadyRecorded) 'Las cuotas pasan a devolver este dinero: no contarán otra vez como gasto (salvo intereses o comisiones indicados en el plan).',
            ],
            operation: ops.length == 1 ? ops.single : batchOperation(ops),
            targetId: target.id,
            undoOperation: batchOperation([
              restore,
              if (!plan.alreadyRecorded) upsertOperation('installmentPlans', {'id': plan.id, 'alreadyRecorded': false, 'updatedAt': stamp}, create: false),
            ]),
          );
        }
        // No loan recorded yet: its commitment is prepared with this income as its money (asked, never assumed).
        if (d.purpose == null) {
          return _ask(d, PendingField.loanTotal, 'No tienes ningún préstamo registrado. ¿El total que vas a devolver es ${money(target.amountMinor)}? Si incluye intereses, escribe el total.',
              [('Sí, ${money(target.amountMinor)}', 'total:same')]);
        }
        final total = d.purpose == 'total:same' ? target.amountMinor : int.parse(d.purpose!.substring(6));
        final next = _draft = _Draft(IntentKind.createPlan)
          ..amountMinor = total
          ..count = d.count
          ..planKind = InstallmentKind.loan
          ..recorded = true
          ..linkIncomeId = target.id
          ..planName = d.concept;
        return _nextPlan(next, calc, now);
      case 'loanUse':
        final plan = loans.length == 1 ? loans.single : null;
        final note = 'Pagado con el dinero del préstamo${plan == null ? '' : ' «${plan.name}»'}.';
        final notes = target.notes.contains(note) ? target.notes : [if (target.notes.trim().isNotEmpty) target.notes.trim(), note].join('\n\n');
        final ops = [
          Operation('patch', {
            'id': target.id,
            'fields': {'notes': notes, if (d.concept != null) 'descriptionText': d.concept, if (d.categoryId != null) 'categoryID': d.categoryId, 'updatedAt': stamp}
          }),
          if (plan != null && !plan.alreadyRecorded) upsertOperation('installmentPlans', {'id': plan.id, 'alreadyRecorded': true, 'updatedAt': stamp}, create: false),
        ];
        return d.preview = AssistantPreview(
          id: d.previewId ??= newId(),
          kind: PreviewKind.existing,
          title: 'Pagado con el préstamo · ${money(target.amountMinor)}',
          lines: [
            ('Movimiento', _label(target, data)),
            if (d.concept != null) ('Concepto', d.concept!),
            if (d.categoryId != null) ('Categoría', data.category(d.categoryId)?.name ?? ''),
            ('Préstamo', plan?.name ?? 'sin registrar todavía'),
          ],
          effects: [
            'Sigue contando como gasto: es lo que compraste o pagaste con ese dinero. No se crea ningún movimiento nuevo.',
            plan == null
                ? 'Cuando registres el préstamo, indica que el dinero ya está apuntado: sus cuotas no contarán este gasto otra vez.'
                : 'Las cuotas del préstamo devuelven el dinero: no contarán este gasto otra vez.',
          ],
          operation: ops.length == 1 ? ops.single : batchOperation(ops),
          targetId: target.id,
          undoOperation: batchOperation([
            restore,
            if (plan != null && !plan.alreadyRecorded) upsertOperation('installmentPlans', {'id': plan.id, 'alreadyRecorded': false, 'updatedAt': stamp}, create: false),
          ]),
        );
      case 'instalment':
        final plans = data.installmentPlans.where((p) => !p.isArchived).toList();
        if (plans.isEmpty) {
          _draft = null;
          return AssistantMessage('No tienes ningún pago a plazos registrado. Créalo primero; después podré vincular este cargo como su cuota.');
        }
        if (plans.length > 1 && d.planId == null) return _ask(d, PendingField.plan, '¿De qué pago a plazos es la cuota?', [for (final p in plans) (p.name, p.id)]);
        final plan = plans.length == 1 ? plans.single : plans.firstWhere((p) => p.id == d.planId);
        final next = installmentProgress(plan, data, now).next;
        if (next == null || target.externalId != null) {
          _draft = null;
          return AssistantMessage(next == null ? '«${plan.name}» ya está pagado entero.' : 'Ese cargo ya está vinculado a otra cosa. No he cambiado nada.');
        }
        return d.preview = AssistantPreview(
          id: d.previewId ??= newId(),
          kind: PreviewKind.existing,
          title: 'Cuota ${next.number}/${plan.count} · ${money(target.amountMinor)}',
          lines: [('Movimiento', _label(target, data)), ('Plan', plan.name), ('Cuota', '${next.number} de ${plan.count}')],
          effects: ['El cargo queda como el pago de esa cuota; no se crea ningún movimiento nuevo.'],
          warnings: [if (target.amountMinor != next.installment.amountMinor) 'Es distinto de la cuota prevista (${money(next.installment.amountMinor)}).'],
          operation: linkOperation(plan, next.number, target, now),
          targetId: target.id,
          undoOperation: restore,
        );
      default:
        final type = target.type;
        if (d.categoryId == null) {
          final concept = d.concept;
          final rule = concept == null ? null : matchRule(concept, type, data);
          final learnt = rule == null && concept != null && propose != null ? await propose!(concept, type) : null;
          final (found, clear) = concept == null ? (const <Category>[], false) : hintedCategories(concept, data, (c) => categorySupports(c, type));
          d.categoryId = rule?.id ?? learnt?.$1 ?? (clear ? found.single.id : null);
          if (d.categoryId == null) {
            return _ask(d, PendingField.category, '¿En qué categoría lo pongo?', [
              for (final c in [...found, ...data.categories.where((c) => !c.isArchived && categorySupports(c, type) && !found.contains(c))].take(8)) (c.name, c.id),
            ]);
          }
        }
        final category = data.category(d.categoryId);
        return d.preview = AssistantPreview(
          id: d.previewId ??= newId(),
          kind: PreviewKind.existing,
          title: 'Clasificar · ${money(target.amountMinor)}',
          lines: [
            ('Movimiento', _label(target, data)),
            if (d.concept != null && d.concept != target.descriptionText) ('Concepto', '${listTitleOf(target)} → ${d.concept}'),
            ('Categoría', '${data.category(target.categoryId)?.name ?? 'Sin categoría'} → ${category?.name ?? 'Sin categoría'}'),
          ],
          effects: ['Solo cambia la clasificación de ese movimiento: el importe, la fecha y el saldo no cambian.'],
          operation: Operation('patch', {
            'id': target.id,
            'fields': {'categoryID': d.categoryId, if (d.concept != null) 'descriptionText': d.concept, 'updatedAt': stamp}
          }),
          targetId: target.id,
          undoOperation: restore,
          draft: TransactionDraft(
              date: target.date, type: type, amountMinor: target.amountMinor, description: d.concept ?? target.descriptionText, sourceAccountId: target.sourceAccountId, categoryId: d.categoryId),
          proposal: category == null ? null : (categoryName: category.name, source: 'chat'),
        );
    }
  }

  /// Existing incomes that may be a loan's money: of exactly [total], not linked to anything, from two months before.
  List<Transaction> _loanIncomes(Finances data, int total, DateTime now) => [
        for (final t in data.transactions)
          if (t.type.countsAsIncome && t.amountMinor == total && t.externalId == null && t.date.isAfter(now.subtract(const Duration(days: 62))) && !t.date.isAfter(now.add(const Duration(days: 1))))
            t
      ];

  /// The person's categories that fit borrowed money (never invented: «Préstamo recibido» is only created if chosen).
  List<Category> _loanCategories(Finances data) => [
        for (final c in data.categories)
          if (!c.isArchived && categorySupports(c, TransactionType.income) && RegExp(r'(prest|deud|financ|credit)').hasMatch(plainText(c.name))) c
      ];

  /// Asks the category of a loan's money once, when the income has none: a compatible one of the person's, creating
  /// «Préstamo recibido» (confirmed with the rest), or none. The treatment (not everyday income) does not depend on it.
  AssistantQuestion? _askLoanCategory(_Draft d, Transaction income, Finances data) {
    if (d.loanCategory != null || income.categoryId != null) return null;
    final existing = _loanCategories(data);
    return _ask(d, PendingField.loanCategory, '¿En qué categoría pongo el ingreso de ${money(income.amountMinor)}? (Ya no contará como ingreso del día a día.)', [
      for (final c in existing.take(4)) (c.name, 'loancat:${c.id}'),
      if (!existing.any((c) => plainText(c.name).trim() == 'prestamo recibido')) ('Crear «Préstamo recibido»', 'loancat:new'),
      ('Dejarlo sin categoría', 'loancat:none'),
    ]);
  }

  List<Operation> _loanCategoryOps(_Draft d, Transaction income, Finances data, DateTime now) {
    final stamp = referenceSeconds(now);
    final choice = d.loanCategory;
    if (choice == null || choice == 'none' || income.categoryId != null) return const [];
    if (choice != 'new') {
      return [
        Operation('patch', {
          'id': income.id,
          'fields': {'categoryID': choice, 'updatedAt': stamp}
        })
      ];
    }
    final id = d.newCategoryId ??= newId();
    return [
      upsertOperation(
          'categories',
          {
            'id': id,
            'name': 'Préstamo recibido',
            'kindRaw': CategoryKind.income.name,
            'colorHex': '#475569',
            'systemImage': 'banknote.fill',
            'isArchived': false,
            'isSystem': false,
            'sortOrder': data.categories.length,
            'createdAt': stamp,
            'updatedAt': stamp,
          },
          create: true),
      Operation('patch', {
        'id': income.id,
        'fields': {'categoryID': id, 'updatedAt': stamp}
      }),
    ];
  }

  /// The account a person uses for most of their recent movements of this kind (3 of every 4 of the last 20, at
  /// least 5): proposed instead of asked, and said on the card.
  Account? _usualAccount(_Draft d, Finances data, List<Account> active) {
    if (d.kind != IntentKind.expense && d.kind != IntentKind.income) return null;
    final income = d.kind == IntentKind.income;
    final ids = {for (final a in active) a.id};
    final recent = [
      for (final t in data.transactions)
        if ((income ? t.type.countsAsIncome : t.type.countsAsExpense) && ids.contains(t.sourceAccountId)) t
    ]..sort(MovementSelection.newestFirst);
    final last = recent.take(20).toList();
    if (last.length < 5) return null;
    final counts = <String, int>{};
    for (final t in last) {
      counts[t.sourceAccountId!] = (counts[t.sourceAccountId!] ?? 0) + 1;
    }
    final best = counts.entries.reduce((a, b) => a.value >= b.value ? a : b);
    return best.value * 4 >= last.length * 3 ? data.account(best.key) : null;
  }

  /// The existing movement a request is about: the one on screen the interpreter named, or the one of that amount
  /// (and day); several are asked with their date, account and amount, never guessed.
  Object _targetOf(_Draft d, Finances data, String what) {
    final known = data.transactions.where((t) => t.id == d.targetId).firstOrNull;
    if (known != null) return known;
    final amount = d.findAmountMinor;
    if (amount == null) return _ask(d, PendingField.target, '¿Qué movimiento quieres $what? Dime su importe y, si hace falta, el día.');
    final day = d.findDate;
    final found = [
      for (final t in data.transactions)
        if (t.amountMinor == amount && (day == null || t.date.year == day.year && t.date.month == day.month && t.date.day == day.day)) t
    ]..sort(MovementSelection.newestFirst);
    if (found.length == 1) {
      d.targetId = found.single.id;
      return found.single;
    }
    if (found.isEmpty) {
      _draft = null;
      return AssistantMessage('No encuentro ningún movimiento de ${money(amount)}${day == null ? '' : ' el ${_when(day, DateTime.now())}'}. '
          'Dime el importe exacto o búscalo en Movimientos.');
    }
    return _ask(d, PendingField.target, '¿Cuál de estos?', [for (final t in found.take(6)) (_label(t, data), 'target:${t.id}')]);
  }

  AssistantReply _nextTransfer(_Draft d, FinanceCalculator calc, DateTime now, int heldMinor) {
    final data = calc.data;
    final active = data.accounts.where((a) => !a.isArchived).toList();
    if (d.amountMinor == null) return _ask(d, PendingField.amount, '¿Cuánto traspasas?');
    if (data.account(d.accountId) == null) {
      return _ask(d, PendingField.account, '¿Desde qué cuenta?', [for (final a in active.take(8)) (a.name, a.id)]);
    }
    if (data.account(d.toAccountId) == null || d.toAccountId == d.accountId) {
      return _ask(d, PendingField.toAccount, '¿A qué cuenta?', [for (final a in active.where((a) => a.id != d.accountId).take(8)) (a.name, 'to:${a.id}')]);
    }
    final from = data.account(d.accountId)!, to = data.account(d.toAccountId)!;
    final date = d.date ?? now;
    final draft = TransactionDraft(
        date: date, type: TransactionType.transfer, amountMinor: d.amountMinor!, description: d.concept ?? 'Traspaso', sourceAccountId: from.id, destinationAccountId: to.id);
    final problem = draft.validate(data);
    if (problem != null) {
      _draft = null;
      return AssistantMessage('No puedo prepararlo: $problem');
    }
    final id = d.previewId ??= newId();
    final amount = d.amountMinor!;
    return d.preview = AssistantPreview(
      id: id,
      kind: PreviewKind.movement,
      title: 'Traspaso · ${money(amount)}',
      lines: [('Desde', from.name), ('A', to.name), ('Fecha', _when(date, now))],
      effects: [
        'Saldo de ${from.name}: ${money(calc.balance(from))} → ${money(calc.balance(from) - amount)}',
        'Saldo de ${to.name}: ${money(calc.balance(to))} → ${money(calc.balance(to) + amount)}',
        'Solo se apunta: no mueve dinero en tu banco.',
      ],
      operation: saveOperation(draft, data, now, newId: id),
      draft: draft,
    );
  }

  AssistantReply _nextEdit(_Draft d, FinanceCalculator calc, DateTime now) {
    final data = calc.data;
    final found = _targetOf(d, data, 'cambiar');
    if (found is AssistantReply) return found;
    final t = found as Transaction;
    final amount = d.amountMinor ?? t.amountMinor;
    final date = d.date ?? t.date;
    final accountId = d.accountId ?? t.sourceAccountId;
    final categoryId = d.categoryDecided ? d.categoryId : t.categoryId;
    final concept = d.concept ?? t.descriptionText;
    String name(String? categoryId) => data.category(categoryId)?.name ?? 'Sin categoría';
    final changes = <(String, String)>[
      if (amount != t.amountMinor) ('Importe', '${money(t.amountMinor)} → ${money(amount)}'),
      if (!_sameDay(date, t.date)) ('Fecha', '${_when(t.date, now)} → ${_when(date, now)}'),
      if (accountId != t.sourceAccountId) ('Cuenta', '${data.account(t.sourceAccountId)?.name ?? ''} → ${data.account(accountId)?.name ?? ''}'),
      if (categoryId != t.categoryId) ('Categoría', '${name(t.categoryId)} → ${name(categoryId)}'),
      if (concept != t.descriptionText) ('Concepto', '${shortConcept(t)} → $concept'),
    ];
    if (changes.isEmpty) {
      return _ask(d, PendingField.change, '¿Qué cambio de «${shortConcept(t)}» (${money(t.amountMinor)}, ${_when(t.date, now)})? El importe, la fecha, la cuenta, la categoría o el concepto.');
    }
    final draft = TransactionDraft(
      date: date,
      type: t.type,
      amountMinor: amount,
      description: concept,
      sourceAccountId: accountId,
      destinationAccountId: t.destinationAccountId,
      categoryId: categoryId,
      notes: t.notes,
      isReconciled: t.isReconciled,
      reservedFundId: t.reservedFundId,
      reservedAmountMinor: t.reservedAmountMinor,
    );
    final problem = draft.validate(data, editing: t);
    if (problem != null) {
      _draft = null;
      return AssistantMessage('No puedo cambiarlo: $problem');
    }
    final stamp = referenceSeconds(now);
    return d.preview = AssistantPreview(
      id: d.previewId ??= newId(),
      kind: PreviewKind.existing,
      title: 'Cambiar · ${shortConcept(t)}',
      lines: changes,
      effects: const ['Solo cambia este movimiento; lo demás queda igual.'],
      warnings: [
        if (t.isBanking && (amount != t.amountMinor || !_sameDay(date, t.date)))
          'Viene de tu banco: si cambias el importe o la fecha, dejará de coincidir con lo que dice el banco.',
      ],
      operation: saveOperation(draft, data, now, editing: t),
      draft: draft,
      targetId: t.id,
      undoOperation: Operation('patch', {
        'id': t.id,
        'fields': {
          'date': referenceSeconds(t.date),
          'amountMinor': t.amountMinor,
          'descriptionText': t.descriptionText,
          'sourceAccountID': t.sourceAccountId,
          'categoryID': t.categoryId,
          'fingerprint': t.fingerprint,
          'updatedAt': stamp,
        }
      }),
    );
  }

  static bool _sameDay(DateTime a, DateTime b) => a.year == b.year && a.month == b.month && a.day == b.day;

  AssistantReply _nextDelete(_Draft d, FinanceCalculator calc, DateTime now) {
    final data = calc.data;
    final found = _targetOf(d, data, 'borrar');
    if (found is AssistantReply) return found;
    final t = found as Transaction;
    // An order goes with its fee: deleting one never leaves the other behind (as in the movement's detail).
    final fee = linkedFee(data, t.id);
    final raws = [record?.call('transactions', t.id), if (fee != null) record?.call('transactions', fee.id)];
    final income = t.type.countsAsIncome;
    return d.preview = AssistantPreview(
      id: d.previewId ??= newId(),
      kind: PreviewKind.delete,
      title: 'Borrar · ${shortConcept(t)}',
      lines: [
        ('Importe', '${income ? '+' : '−'}${money(t.amountMinor)}'),
        ('Fecha', _when(t.date, now)),
        if (data.account(t.sourceAccountId) != null) ('Cuenta', data.account(t.sourceAccountId)!.name),
        if (data.category(t.categoryId) != null) ('Categoría', data.category(t.categoryId)!.name),
      ],
      effects: [
        'Se borra de todos tus dispositivos. Después podrás deshacerlo desde aquí.',
        if (fee != null) 'También se borra su comisión de ${money(fee.amountMinor)}.',
      ],
      warnings: [
        if (t.isBanking) 'Viene de tu banco: volverá a aparecer en la próxima descarga. Si está repetido, mejor únelo en «Revisar y unir».',
      ],
      operation: fee == null ? deleteOperation(t) : batchOperation([deleteOperation(t), deleteOperation(fee)]),
      targetId: t.id,
      undoOperation: raws.contains(null) ? null : batchOperation([for (final r in raws) Operation('insert', {'record': r})]),
    );
  }

  AssistantReply _nextBudget(_Draft d, FinanceCalculator calc, DateTime now) {
    final data = calc.data;
    final category = data.category(d.categoryId);
    if (category == null || !categorySupports(category, TransactionType.expense)) {
      final options = data.categories.where((c) => !c.isArchived && categorySupports(c, TransactionType.expense)).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return _ask(d, PendingField.category, '¿De qué categoría es el presupuesto?', [for (final c in options.take(8)) (c.name, c.id)]);
    }
    if (d.amountMinor == null) return _ask(d, PendingField.amount, '¿Cuánto quieres como límite al mes para ${category.name}?');
    final month = DateTime(now.year, now.month);
    final planned = budgetOperations(
        data: data, category: category, month: month, amountMinor: d.amountMinor!, everyMonth: d.recurring, newId: newId, now: now);
    final (from, to) = QueryPeriod.thisMonth.range(now);
    final spent = data.transactions
        .where((t) => t.categoryId == category.id && !t.date.isBefore(from) && t.date.isBefore(to))
        .fold(0, (sum, t) => sum + FinanceCalculator.budgetExpenseAmount(t));
    final monthName = _monthNames[month.month - 1];
    return d.preview = AssistantPreview(
      id: d.previewId ??= newId(),
      kind: PreviewKind.setting,
      title: 'Presupuesto · ${category.name}',
      lines: [
        ('Límite', '${money(d.amountMinor!)} ${d.recurring ? 'cada mes desde $monthName' : 'solo en $monthName'}'),
        ('Gastado en $monthName', money(spent)),
      ],
      effects: [d.recurring ? 'Si es solo para este mes, dímelo («solo este mes»).' : 'Si es para todos los meses, dímelo («cada mes»).'],
      operation: planned.operation,
      undoOperation: planned.undo,
    );
  }

  AssistantReply _nextGoal(_Draft d, FinanceCalculator calc, DateTime now) {
    final data = calc.data;
    if (d.purpose == null || d.purpose!.isEmpty) return _ask(d, PendingField.purpose, '¿Cómo se llama el objetivo?');
    if (d.amountMinor == null) return _ask(d, PendingField.amount, '¿Cuánto quieres reunir para «${d.purpose}»?');
    final id = d.previewId ??= newId();
    final stamp = referenceSeconds(now);
    final account = data.account(d.accountId);
    return d.preview = AssistantPreview(
      id: id,
      kind: PreviewKind.setting,
      title: 'Objetivo · ${d.purpose}',
      lines: [
        ('Meta', money(d.amountMinor!)),
        if (d.date != null) ('Para', _longDate(d.date!)),
        if (account != null) ('Cuenta', account.name),
      ],
      effects: const ['Lo verás en Presupuestos › Objetivos. Cuando ahorres algo, dímelo («he metido 50 € en el objetivo»).'],
      operation: upsertOperation(
          'goals',
          {
            'id': id,
            'name': d.purpose,
            'targetAmountMinor': d.amountMinor,
            'currentAmountMinor': 0,
            'targetDate': d.date == null ? null : referenceSeconds(d.date!),
            'colorHex': '#2F7D66',
            'isCompleted': false,
            'linkedAccountID': account?.id,
            'notes': '',
            'createdAt': stamp,
            'updatedAt': stamp,
          },
          create: true),
      undoOperation: removeOperation('goals', id),
    );
  }

  AssistantReply _nextAddToGoal(_Draft d, FinanceCalculator calc, DateTime now) {
    final data = calc.data;
    final active = data.goals.where((g) => !g.isCompleted).toList();
    if (active.isEmpty) {
      _draft = null;
      return AssistantMessage('No tienes objetivos abiertos. Dime cuál quieres crear («quiero ahorrar 1.000 € para un viaje»).');
    }
    final goal = data.goals.where((g) => g.id == d.goalId).firstOrNull ?? (active.length == 1 ? active.single : null);
    if (goal == null) return _ask(d, PendingField.goal, '¿Para qué objetivo?', [for (final g in active.take(8)) (g.name, 'goal:${g.id}')]);
    d.goalId = goal.id;
    if (d.amountMinor == null) return _ask(d, PendingField.amount, '¿Cuánto has apartado para «${goal.name}»?');
    final after = goal.currentAmountMinor + d.amountMinor!;
    final stamp = referenceSeconds(now);
    return d.preview = AssistantPreview(
      id: d.previewId ??= newId(),
      kind: PreviewKind.setting,
      title: 'Objetivo · ${goal.name}',
      lines: [('Ahorrado', '${money(goal.currentAmountMinor)} → ${money(after)} de ${money(goal.targetAmountMinor)}')],
      effects: [
        if (after >= goal.targetAmountMinor) '¡Con esto lo completas!',
        'Solo se apunta en el objetivo: no mueve dinero entre cuentas.',
      ],
      operation: upsertOperation('goals', {'id': goal.id, 'currentAmountMinor': after, 'isCompleted': after >= goal.targetAmountMinor || goal.isCompleted, 'updatedAt': stamp},
          create: false),
      undoOperation: upsertOperation('goals', {'id': goal.id, 'currentAmountMinor': goal.currentAmountMinor, 'isCompleted': goal.isCompleted, 'updatedAt': stamp},
          create: false),
    );
  }

  AssistantReply _nextRule(_Draft d, FinanceCalculator calc, DateTime now) {
    final data = calc.data;
    final phrase = d.concept ?? d.purpose;
    if (phrase == null || ruleText(phrase).length < 3) {
      return _ask(d, PendingField.purpose, '¿Qué texto aparece en esos movimientos? (por ejemplo, el nombre del comercio)');
    }
    final type = d.incoming == true ? TransactionType.income : TransactionType.expense;
    final category = data.category(d.categoryId);
    if (category == null || !categorySupports(category, type)) {
      final options = data.categories.where((c) => !c.isArchived && categorySupports(c, type)).toList()
        ..sort((a, b) => a.name.toLowerCase().compareTo(b.name.toLowerCase()));
      return _ask(d, PendingField.category, '¿En qué categoría los pongo?', [for (final c in options.take(8)) (c.name, c.id)]);
    }
    final id = d.previewId ??= newId();
    final existing = data.categoryRules.where((r) => r.transactionType == type && ruleText(r.phrase) == ruleText(phrase)).firstOrNull;
    final operation = rememberRule(phrase, type, category, data, now, id);
    if (operation == null) {
      _draft = null;
      return AssistantMessage('Ese texto es demasiado corto para una regla.');
    }
    final pending = data.transactions
        .where((t) => t.categoryId == null && t.type == type && ruleText(t.descriptionText).contains(ruleText(phrase)))
        .length;
    return d.preview = AssistantPreview(
      id: id,
      kind: PreviewKind.setting,
      title: 'Regla · «$phrase» → ${category.name}',
      lines: [('Se aplica a', type == TransactionType.income ? 'ingresos' : 'gastos'), ('Categoría', category.name)],
      effects: [
        'Se aplicará a los próximos movimientos del banco con ese texto.',
        if (pending > 0) 'Ya tienes $pending sin categoría con ese texto: después, pídeme que les ponga categoría.',
      ],
      operation: operation,
      undoOperation: existing == null
          ? removeOperation('categoryRules', id)
          : upsertOperation('categoryRules', {'id': existing.id, 'categoryID': existing.categoryId, 'isActive': existing.isActive, 'updatedAt': referenceSeconds(now)},
              create: false),
    );
  }

  String listTitleOf(Transaction t) => t.descriptionText.trim().isEmpty ? 'Movimiento' : t.descriptionText.trim();

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

  /// A request about existing movements read with the rules: the conditions the sentence states, applied over the
  /// last request's when it follows it («no, los que no tienen categoría» changes only that condition).
  Future<AssistantReply> _query(IntentKind kind, Signals s, FinanceCalculator calc, DateTime now) async {
    final data = calc.data;
    final last = _last;
    final follows = last != null && (s.continuation || s.period == null);
    final saysIncome = _any(s.words, ['ingresos', 'cobros', 'ingres*', 'cobr*']);
    final saysExpense = _any(s.words, ['gast*', 'compr*', 'pag*']);
    final saysAll = _any(s.words, ['movimientos', 'operaciones', 'transacciones']);
    final scope = saysIncome && !saysExpense ? QueryScope.income : (saysExpense ? QueryScope.expenses : (saysAll ? QueryScope.all : null));
    final accounts = namedAccounts(s.raw, data);
    if (kind == IntentKind.summary) return _summary(calc, now, s, s.period ?? (follows ? last.selection.period : null) ?? QueryPeriod.thisMonth);
    // «compras»: a category of that name, or every expense? From the context, or asked once.
    final compras = kind == IntentKind.listMovements && scope == QueryScope.expenses && _any(s.words, ['compr*']);
    final comprasCategory = _comprasCategory(data);
    final accountId = accounts.length == 1 ? accounts.single.account.id : null;
    if (compras && comprasCategory != null && _comprasIsCategory == null) {
      final period = s.period ?? (follows ? last.selection.period : null);
      _scopeWaiting = (period: period, accountId: accountId ?? (follows ? last.selection.accountId : null));
      return AssistantQuestion('¿Todos los gastos${period == null ? '' : ' de ${period.title}'} o solo la categoría «${comprasCategory.name}»?', null,
          [('Todos los gastos', 'scope:all'), ('Solo «${comprasCategory.name}»', 'scope:category')]);
    }
    final type = scope == QueryScope.income ? TransactionType.income : TransactionType.expense;
    final named = compras || s.uncategorized ? null : namedCategory(s.raw, data, (c) => categorySupports(c, type));
    final change = MovementSelection(
      period: s.period,
      scope: scope,
      uncategorized: s.uncategorized ? true : null,
      categoryId: named?.id,
      accountId: accountId,
      limit: s.limit,
    );
    var selection = follows ? last.selection.refinedBy(change) : change;
    // Another type of movement: a category of the previous type no longer applies.
    if (follows && scope != null && scope != last.selection.scope && named == null) selection = selection.withoutCategory();
    if (kind == IntentKind.categorize) return _categorize(selection, calc, now);
    return _list(calc, now, selection, compras: compras);
  }

  Category? _comprasCategory(Finances data) =>
      data.categories.where((c) => !c.isArchived && plainText(c.name).startsWith('compra') && categorySupports(c, TransactionType.expense)).firstOrNull;

  /// The movements of [asked]. Without a period said, a request about movements without category covers every
  /// date; any other list covers this month, and says so.
  AssistantReply _list(FinanceCalculator calc, DateTime now, MovementSelection asked, {bool compras = false}) {
    final data = calc.data;
    var selection = asked;
    if (compras && _comprasIsCategory == true && _comprasCategory(data) != null) {
      selection = selection.refinedBy(MovementSelection(categoryId: _comprasCategory(data)!.id));
    }
    _last = (kind: IntentKind.listMovements, selection: selection);
    final defaulted = !selection.hasPeriod && selection.uncategorized != true;
    final shown = defaulted ? selection.withDefaultPeriod(QueryPeriod.thisMonth) : selection;
    final rows = shown.select(data, now);
    final all = (shown.scope ?? QueryScope.all) == QueryScope.all;
    final total = all ? null : rows.fold(0, (s, t) => s + t.amountMinor.abs());
    return AssistantResult(
      _capital(shown.describe(data)),
      [
        rows.isEmpty ? 'No hay ninguno.' : '${rows.length} ${rows.length == 1 ? 'movimiento' : 'movimientos'}${total == null ? '' : ' · ${money(total)} en total'}. Tócalos para abrirlos.',
        if (defaulted) 'No has dicho periodo: te enseño este mes.',
      ],
      transactions: rows.take(30).toList(),
      totalMinor: total,
    );
  }

  /// Without a number said, a categorisation works on this many (the most recent), and says so.
  static const categorizeBatch = 10;

  /// Puts categories on the existing movements of [asked] that have none («ponles categoría», «a los últimos 4»).
  /// The movements are chosen first (conditions, most recent first, then the number) and only those are worked on:
  ///  1. the person's own evidence (their rules, their history) is applied now, with its provenance and undo;
  ///  2. the learning's proposals are shown on each card, editable, to confirm together;
  ///  3. one without evidence stays in the selection, asking what it is: never replaced by an older one.
  /// A category already chosen is never changed. Confirming applies only to these movements.
  Future<AssistantReply> _categorize(MovementSelection asked, FinanceCalculator calc, DateTime now) async {
    final data = calc.data;
    final selection = asked.refinedBy(const MovementSelection(uncategorized: true));
    _last = (kind: IntentKind.categorize, selection: selection);
    _proposals = null;
    final keepsChosen = asked.uncategorized == false || asked.categoryId != null;
    final all = selection.withoutLimit().select(data, now);
    if (all.isEmpty) {
      return AssistantResult('Poner categoría', [
        'No hay ninguno sin categoría${selection.hasPeriod ? ' ${selection.periodTitle()}' : ''}.',
        if (keepsChosen) 'Los que ya tienen categoría no los cambio.',
      ]);
    }
    final chosen = all.take(selection.limit ?? categorizeBatch).toList();
    var automatic = const <AutoCategory>[];
    try {
      automatic = await applyEvidence?.call({for (final t in chosen) t.id}) ?? const [];
    } catch (_) {}
    final items = <CategoryItem>[];
    for (final t in chosen) {
      final evidence = automatic.where((a) => a.transactionId == t.id).firstOrNull;
      if (evidence != null) {
        items.add(CategoryItem(t, categoryId: evidence.categoryId, source: evidence.source));
        continue;
      }
      (String, String)? p;
      if (usefulConcept(t) && propose != null) {
        try {
          p = await propose!(listTitle(t.descriptionText, isBanking: t.isBanking), t.type);
        } catch (_) {}
      }
      final c = data.category(p?.$1);
      final fits = c != null && !c.isArchived && categorySupports(c, t.type);
      items.add(CategoryItem(t, categoryId: fits ? c.id : null, source: fits ? p!.$2 : null));
    }
    final applied = items.where((i) => i.applied).length;
    final proposed = items.where((i) => !i.applied && i.categoryId != null).length;
    final unknown = items.length - applied - proposed;
    final limit = selection.limit;
    return _proposals = AssistantPreview(
      id: newId(),
      kind: PreviewKind.categories,
      title: limit == null
          ? (all.length > chosen.length ? 'Los ${chosen.length} más recientes sin categoría' : '${_count(chosen.length)} sin categoría')
          : (chosen.length == 1 ? 'El último sin categoría' : 'Los ${chosen.length} últimos sin categoría'),
      lines: const [],
      effects: [
        [
          if (applied > 0) '$applied con tus reglas o tu historial',
          if (proposed > 0) '$proposed ${proposed == 1 ? 'propuesta' : 'propuestas'}',
          if (unknown > 0) '$unknown sin datos para saber qué ${unknown == 1 ? 'es' : 'son'}',
        ].join(' · '),
        if (limit != null && chosen.length < limit) 'Solo hay ${chosen.length} sin categoría${selection.hasPeriod ? ' ${selection.periodTitle()}' : ''}.',
        if (limit == null && all.length > chosen.length) 'Hay ${all.length} sin categoría; empiezo por estos. Después, pídemelo otra vez.',
        if (unknown > 0) 'Toca la categoría para elegirla, o dímelo («el de ${money(items.firstWhere((i) => !i.applied && i.categoryId == null).transaction.amountMinor)} es …»).',
        if (keepsChosen) 'Los que ya tienen categoría no los cambio.',
      ],
      operation: batchOperation(const []),
      items: items,
    );
  }

  static String _count(int n) => n == 1 ? '1 movimiento' : '$n movimientos';

  /// A category chosen on a card (only one of the movements shown, only while it can be confirmed).
  bool chooseCategory(AssistantPreview preview, String transactionId, String categoryId) {
    if (!identical(_proposals, preview)) return false;
    final item = preview.items.where((i) => i.transaction.id == transactionId && !i.applied).firstOrNull;
    if (item == null) return false;
    item
      ..categoryId = categoryId
      ..source = 'person';
    return true;
  }

  AssistantReply _summary(FinanceCalculator calc, DateTime now, Signals s, QueryPeriod period) {
    final usable = period == QueryPeriod.lastMonth ? QueryPeriod.lastMonth : QueryPeriod.thisMonth;
    final month = usable == QueryPeriod.lastMonth ? DateTime(now.year, now.month - 1) : DateTime(now.year, now.month);
    final category = namedCategory(s.raw, calc.data, (c) => categorySupports(c, TransactionType.expense));
    _last = (kind: IntentKind.summary, selection: MovementSelection(period: usable, scope: QueryScope.expenses, categoryId: category?.id));
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
    if (preview.kind == PreviewKind.batch) {
      if (!identical(_batch, preview) || !applied.add(preview.id)) return null;
      _batch = null;
      if (preview.parts.any((p) => data.transactions.any((t) => t.id == p.id) || data.reservedFunds.any((f) => f.id == p.id))) return null;
      return preview.operation;
    }
    if (preview.kind == PreviewKind.categories) {
      if (!identical(_proposals, preview) || !applied.add(preview.id)) return null;
      _proposals = null;
      final stamp = referenceSeconds(DateTime.now());
      final ops = [
        for (final (id, category, _) in preview.assignments)
          if (data.transactions.any((t) => t.id == id && t.categoryId == null))
            Operation('patch', {
              'id': id,
              'fields': {'categoryID': category, 'updatedAt': stamp}
            }),
      ];
      return ops.isEmpty ? null : batchOperation(ops);
    }
    if (!identical(_draft?.preview, preview)) return null;
    if (!applied.add(preview.id)) return null;
    if (preview.kind != PreviewKind.existing && data.transactions.any((t) => t.id == preview.id) ||
        data.reservedFunds.any((f) => f.id == preview.id) ||
        data.installmentPlans.any((p) => p.id == preview.id)) {
      return null;
    }
    _draft = null;
    return preview.operation;
  }

  /// Whether a card is the one that can still be confirmed.
  bool isCurrent(AssistantPreview preview) => identical(_draft?.preview, preview) || identical(_proposals, preview) || identical(_batch, preview);

  /// The proposals card is dropped (nothing was applied).
  void cancelProposals() => _proposals = null;

  /// Undoes a confirmed preview: the movement, the reserve (if nothing uses it) or the plan (its payments stay).
  Operation? undo(AssistantPreview preview, Finances data, DateTime now) {
    if (preview.kind == PreviewKind.batch) {
      final ops = [for (final p in preview.parts) undo(p, data, now)];
      return ops.contains(null) ? null : batchOperation(ops.cast<Operation>());
    }
    if (preview.kind == PreviewKind.delete || preview.kind == PreviewKind.setting) return preview.undoOperation;
    switch (preview.kind) {
      case PreviewKind.reserve:
        if (data.transactions.any((t) => t.reservedFundId == preview.id)) return null;
        return removeOperation('reservedFunds', preview.id);
      case PreviewKind.plan:
        final plan = data.installmentPlans.where((p) => p.id == preview.id).firstOrNull;
        return plan == null ? null : removePlanOperation(plan, data, now);
      case PreviewKind.movement || PreviewKind.instalment:
        return data.transactions.any((t) => t.id == preview.id) ? Operation('delete', {'id': preview.id}) : null;
      case PreviewKind.existing:
        return preview.undoOperation;
      case PreviewKind.batch || PreviewKind.delete || PreviewKind.setting:
        return preview.undoOperation;
      case PreviewKind.categories:
        final stamp = referenceSeconds(now);
        final ops = [
          for (final (id, category, _) in preview.assignments)
            if (data.transactions.any((t) => t.id == id && t.categoryId == category))
              Operation('patch', {
                'id': id,
                'fields': {'categoryID': null, 'updatedAt': stamp}
              }),
        ];
        return ops.isEmpty ? null : batchOperation(ops);
    }
  }
}
