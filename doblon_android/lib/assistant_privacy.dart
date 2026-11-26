// What Don Bigotes' interpreter may see (26 November 2026, decided with the person): nothing sensitive leaves the
// phone. Before a sentence (and its context) is sent, money, the person's accounts, cards, categories, plans, goals
// and movements are replaced by markers; the interpreter answers with the markers and they are resolved here.
//
//   «Pagué unos 62 con la Bankinter y lo pongo en Restaurantes» → «Pagué unos [N1] con la [CUENTA_1] y lo pongo en
//   [CATEGORIA_2]»
//
// What still leaves: the ordinary words of the sentence (what the person tells: «cena», «cine»), the types of their
// accounts («corriente», «ahorro») and the days of dates («el 5 de diciembre»), which say nothing about their money.
// Amounts never leave: every number that is not part of a date becomes a marker, the same value the same marker.
import 'assistant.dart' show plainText, wordsOf;
import 'models.dart';
import 'presentation.dart' show money;

/// Words of account and plan names too common to identify anything (left as they are, so «la de nómina» is still
/// understood as salary). A distinctive word (a bank's name) is replaced.
const _common = {
  'nomina', 'ahorro', 'ahorros', 'corriente', 'inversion', 'inversiones', 'cuenta', 'cuentas', 'tarjeta', 'tarjetas', 'credito', 'debito', 'uso',
  'principal', 'gastos', 'gasto', 'ingresos', 'rentabilidad', 'plan', 'planes', 'fondo', 'fondos', 'deposito', 'hucha', 'efectivo', 'cartera',
  'compartida', 'conjunta', 'personal', 'online', 'prestamo', 'compra', 'pago', 'pagos', 'plazos', 'cuota', 'cuotas', 'coche', 'casa', 'viaje', 'mas',
  'para', 'del', 'los', 'las', 'con', 'una', 'uno',
};

const _numberWords = {
  'uno': 1, 'un': 1, 'una': 1, 'dos': 2, 'tres': 3, 'cuatro': 4, 'cinco': 5, 'seis': 6, 'siete': 7, 'ocho': 8, 'nueve': 9, 'diez': 10, //
  'once': 11, 'doce': 12, 'trece': 13, 'catorce': 14, 'quince': 15, 'dieciseis': 16, 'diecisiete': 17, 'dieciocho': 18, 'diecinueve': 19, //
  'veinte': 20, 'veintiuno': 21, 'veintiun': 21, 'veintiuna': 21, 'veintidos': 22, 'veintitres': 23, 'veinticuatro': 24, 'veinticinco': 25, //
  'veintiseis': 26, 'veintisiete': 27, 'veintiocho': 28, 'veintinueve': 29, 'treinta': 30, 'cuarenta': 40, 'cincuenta': 50, 'sesenta': 60, //
  'setenta': 70, 'ochenta': 80, 'noventa': 90, 'cien': 100, 'ciento': 100, 'doscientos': 200, 'doscientas': 200, 'trescientos': 300, //
  'trescientas': 300, 'cuatrocientos': 400, 'cuatrocientas': 400, 'quinientos': 500, 'quinientas': 500, 'seiscientos': 600, 'seiscientas': 600, //
  'setecientos': 700, 'setecientas': 700, 'ochocientos': 800, 'ochocientas': 800, 'novecientos': 900, 'novecientas': 900, 'mil': 1000,
};

/// Numbers written in words become digits («cuarenta y cinco con cincuenta» → «45,50», «doscientos pavos» → «200
/// pavos»), so they are masked like any amount. A lone «un», «uno» or «una» is an article, not a number.
String wordsToDigits(String text) {
  final words = RegExp(r'[A-Za-zÀ-ÿ]+').allMatches(text).toList();
  final out = StringBuffer();
  var last = 0, i = 0;
  int? valueAt(int k) => k < words.length ? _numberWords[plainText(words[k].group(0)!)] : null;
  bool joined(int a, int b) => text.substring(words[a].end, words[b].start).trim().isEmpty;
  while (i < words.length) {
    if (valueAt(i) == null) {
      i++;
      continue;
    }
    // The longest run of number words, joined by spaces or «y» (only after tens: «cuarenta y cinco»).
    var total = 0, current = 0, end = i;
    var k = i;
    while (k < words.length) {
      final v = valueAt(k);
      if (v == null) {
        final isY = plainText(words[k].group(0)!) == 'y' && current % 100 >= 20 && current % 10 == 0 && valueAt(k + 1) != null && valueAt(k + 1)! < 10;
        if (isY && joined(k - 1, k) && joined(k, k + 1)) {
          k++;
          continue;
        }
        break;
      }
      if (k > i && !joined(k - 1, k) && plainText(words[k - 1].group(0)!) != 'y') break;
      if (v == 1000) {
        total += (current == 0 ? 1 : current) * 1000;
        current = 0;
      } else {
        current += v;
      }
      end = k;
      k++;
    }
    final single = end == i && const {'un', 'uno', 'una'}.contains(plainText(words[i].group(0)!));
    if (single) {
      i++;
      continue;
    }
    var value = '${total + current}';
    var stop = words[end].end;
    // «… con cincuenta», «… euros con cincuenta»: the cents (the currency word is kept after the amount).
    final currency = end + 1 < words.length && const {'euros', 'euro', 'eur', 'pavos'}.contains(plainText(words[end + 1].group(0)!)) ? end + 1 : null;
    final con = (currency ?? end) + 1;
    if (con + 1 < words.length && plainText(words[con].group(0)!) == 'con' && valueAt(con + 1) != null && valueAt(con + 1)! < 100) {
      var cents = valueAt(con + 1)!, last2 = con + 1;
      if (cents >= 20 && cents % 10 == 0 && con + 3 < words.length && plainText(words[con + 2].group(0)!) == 'y' && (valueAt(con + 3) ?? 10) < 10) {
        cents += valueAt(con + 3)!;
        last2 = con + 3;
      }
      value = '$value,${cents.toString().padLeft(2, '0')}${currency == null ? '' : ' ${words[currency].group(0)}'}';
      stop = words[last2].end;
      end = last2;
    }
    out
      ..write(text.substring(last, words[i].start))
      ..write(value);
    last = stop;
    i = end + 1;
  }
  out.write(text.substring(last));
  return out.toString();
}

const _monthWords ='enero|febrero|marzo|abril|mayo|junio|julio|agosto|septiembre|setiembre|octubre|noviembre|diciembre';

class AssistantMasker {
  AssistantMasker(this.data);
  final Finances data;

  final _numbers = <String, String>{}; // N1 → «44,53»
  final _numberValue = <String, int>{}; // N1 → 4453 (cents)
  final _tokenOfValue = <int, String>{};
  final _entities = <String, Object>{}; // CUENTA_1 → Account, CATEGORIA_2 → Category, …
  final _tokenOf = <String, String>{}; // 'account:<id>' → CUENTA_1

  /// The movements shown to the person, in order (MOV_1, MOV_2…), so «el segundo» or «el de 44,53» can be resolved.
  final shown = <Transaction>[];

  String _entity(String kind, String prefix, String id, Object value) {
    final key = '$kind:$id';
    final existing = _tokenOf[key];
    if (existing != null) return existing;
    final count = _entities.keys.where((k) => k.startsWith('${prefix}_')).length;
    final token = '${prefix}_${count + 1}';
    _entities[token] = value;
    _tokenOf[key] = token;
    return token;
  }

  String account(Account a) => _entity('account', 'CUENTA', a.id, a);
  String card(PaymentCard c) => _entity('card', 'TARJETA', c.id, c);
  String category(Category c) => _entity('category', 'CATEGORIA', c.id, c);
  String plan(InstallmentPlan p) => _entity('plan', 'PLAN', p.id, p);
  String goal(SavingsGoal g) => _entity('goal', 'OBJETIVO', g.id, g);
  String movement(Transaction t) {
    final token = _entity('movement', 'MOV', t.id, t);
    if (!shown.contains(t)) shown.add(t);
    return token;
  }

  /// The marker of an amount in cents (the same value, the same marker).
  String amount(int cents) {
    final existing = _tokenOfValue[cents];
    if (existing != null) return existing;
    final token = 'N${_numbers.length + 1}';
    _numbers[token] = money(cents).replaceAll(RegExp(r'\s*€'), '');
    _numberValue[token] = cents;
    _tokenOfValue[cents] = token;
    return token;
  }

  String _number(String original, int cents) {
    final existing = _tokenOfValue[cents];
    if (existing != null) return existing;
    final token = 'N${_numbers.length + 1}';
    _numbers[token] = original;
    _numberValue[token] = cents;
    _tokenOfValue[cents] = token;
    return token;
  }

  /// The generic words of a name («nómina», «ahorro»): they identify nothing, and let «la de nómina» be matched to
  /// its marker.
  static List<String> commonWords(String name) => [for (final w in wordsOf(name)) if (_common.contains(w) && w.length >= 4) w];

  /// The amounts (cents) written in [text], dates apart: what that sentence can set as an amount.
  Set<int> amountsIn(String text) => {for (final m in RegExp(r'\[(N\d+)\]').allMatches(_maskNumbers(text))) _numberValue[m.group(1)]!};

  /// [text] with its money and the person's names replaced by markers.
  String mask(String text) => _maskNames(_maskNumbers(text));

  String _maskNumbers(String original) {
    final text = wordsToDigits(original);
    final number =RegExp(r'(?<![\w\[])(\d{1,3}(?:\.\d{3})+|\d+)(?:([.,])(\d{1,2}))?(?![\d\w\]])');
    final out = StringBuffer();
    var last = 0;
    for (final m in number.allMatches(text)) {
      final before = plainText(text.substring(0, m.start));
      final after = plainText(text.substring(m.end));
      final whole = m.group(1)!;
      // Parts of a date say nothing about money: «5 de diciembre», «3/11», «el día 5», «2026», «10:30».
      final datePart = RegExp('^\\s*(de\\s+)?($_monthWords)\\b').hasMatch(after) ||
          // «el 5 de cada mes», «el 1 del mes que viene»: the day of a date.
          RegExp(r'^\s*(de\s+)?(cada|del|este)\s+mes\b').hasMatch(after) ||
          RegExp(r'^\s*/\s*\d').hasMatch(after) ||
          RegExp(r'\d\s*/\s*$').hasMatch(before) ||
          RegExp(r'\b(el dia|dia|los dias|el)\s*$').hasMatch(before) && !RegExp(r'^\s*(€|eur|euros?)\b').hasMatch(after) && whole.length <= 2 ||
          RegExp(r'^(19|20)\d\d$').hasMatch(whole) && m.group(3) == null && !RegExp(r'^\s*(€|eur|euros?)\b').hasMatch(after) ||
          RegExp(r'^\s*:\s*\d').hasMatch(after) ||
          RegExp(r'\d\s*:\s*$').hasMatch(before);
      if (datePart) continue;
      final cents = int.parse(whole.replaceAll('.', '')) * 100 + (m.group(3) == null ? 0 : int.parse(m.group(3)!.padRight(2, '0')));
      out
        ..write(text.substring(last, m.start))
        ..write('[${_number(m.group(0)!, cents)}]');
      last = m.end;
    }
    out.write(text.substring(last));
    return out.toString();
  }

  String _maskNames(String text) {
    // The names to look for: a whole name (any entity) or a distinctive word of an account, card, plan or goal.
    final names = <(List<String>, String)>[];
    void add(String name, String token, {bool partial = false}) {
      final words = wordsOf(name);
      if (words.isEmpty) return;
      names.add((words, token));
      if (partial) {
        for (final w in words.where((w) => w.length >= 3 && !_common.contains(w))) {
          names.add(([w], token));
        }
      }
    }

    for (final a in data.accounts.where((a) => !a.isArchived)) {
      add(a.name, account(a), partial: true);
    }
    for (final c in data.cards.where((c) => !c.isArchived)) {
      add(c.name, card(c), partial: true);
    }
    for (final c in data.categories.where((c) => !c.isArchived)) {
      add(c.name, category(c));
    }
    for (final p in data.installmentPlans.where((p) => !p.isArchived)) {
      add(p.name, plan(p), partial: true);
    }
    for (final g in data.goals) {
      add(g.name, goal(g), partial: true);
    }
    names.sort((a, b) => b.$1.length.compareTo(a.$1.length)); // the longest name first
    // Words of the text with their positions, compared without accents or case.
    final spans = [for (final m in RegExp(r'[0-9A-Za-zÀ-ÿ]+').allMatches(text)) (plainText(m.group(0)!), m.start, m.end)];
    final replace = <(int, int, String)>[];
    var i = 0;
    while (i < spans.length) {
      (List<String>, String)? found;
      for (final n in names) {
        if (i + n.$1.length > spans.length) continue;
        var ok = true;
        for (var k = 0; k < n.$1.length; k++) {
          if (spans[i + k].$1 != n.$1[k]) {
            ok = false;
            break;
          }
        }
        if (ok) {
          found = n;
          break;
        }
      }
      if (found == null) {
        i++;
        continue;
      }
      final start = spans[i].$2, end = spans[i + found.$1.length - 1].$3;
      // The same word in two names («Bankinter» in two accounts): both markers, and the interpreter asks.
      final others = {for (final n in names) if (n.$1.length == found.$1.length && _same(n.$1, found.$1) && n.$2 != found.$2) n.$2};
      replace.add((start, end, [found.$2, ...others].join(' o ')));
      i += found.$1.length;
    }
    var out = text;
    for (final (start, end, token) in replace.reversed) {
      // A marker inside brackets already («[N1]») is not touched: words only.
      out = '${out.substring(0, start)}[$token]${out.substring(end)}';
    }
    return out;
  }

  static bool _same(List<String> a, List<String> b) {
    for (var k = 0; k < a.length; k++) {
      if (a[k] != b[k]) return false;
    }
    return true;
  }

  // ------------------------------------------------------------ answers

  static String? _ref(Object? value) {
    if (value is! String) return null;
    final m = RegExp(r'^\[?\s*([A-Z]+(?:_\d+)?|N\d+)\s*\]?$').firstMatch(value.trim());
    return m?.group(1);
  }

  /// An amount in cents from a marker («N1»), or a plain number the interpreter could see (a day, a count).
  int? amountOf(Object? value) {
    final ref = _ref(value);
    if (ref != null) return _numberValue[ref];
    return null;
  }

  /// A whole number (a count, a day, how many) from a marker or as the interpreter wrote it.
  int? intOf(Object? value) {
    if (value is int) return value;
    final cents = amountOf(value);
    return cents != null && cents % 100 == 0 ? cents ~/ 100 : null;
  }

  T? _as<T>(Object? value) {
    final ref = _ref(value);
    final found = ref == null ? null : _entities[ref];
    return found is T ? found : null;
  }

  Account? accountOf(Object? value) => _as<Account>(value) ?? (_as<PaymentCard>(value) == null ? null : data.account(_as<PaymentCard>(value)!.linkedAccountId));
  InstallmentPlan? planOf(Object? value) => _as<InstallmentPlan>(value);
  SavingsGoal? goalOf(Object? value) => _as<SavingsGoal>(value);
  Transaction? movementOf(Object? value) => _as<Transaction>(value);
  Category? categoryOf(Object? value) => _as<Category>(value);

  /// A text written by the interpreter with the markers put back («el [N1] de …» → «el 5 de …», «[CATEGORIA_2]» →
  /// «Restaurantes»), for what is read here (a concept, a category said in words, a date).
  String? unmask(Object? value) {
    if (value is! String || value.trim().isEmpty) return null;
    return value.replaceAllMapped(RegExp(r'\[?\b([A-Z]+_\d+|N\d+)\b\]?'), (m) {
      final ref = m.group(1)!;
      final number = _numbers[ref];
      if (number != null) return number;
      final entity = _entities[ref];
      return switch (entity) {
        Account a => a.name,
        PaymentCard c => c.name,
        Category c => c.name,
        InstallmentPlan p => p.name,
        SavingsGoal g => g.name,
        Transaction t => t.descriptionText,
        _ => m.group(0)!,
      };
    }).trim();
  }
}
