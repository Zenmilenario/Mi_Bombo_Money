// The app's machine learning, ported from the iPhone with the same formulas and thresholds:
// - `CategoryModel` (Swift `TransactionCategoryModel`): proposes a category from the concept.
// - `OperationModel` (Swift `TransactionOperationModel`): recognises investment contributions, Round up and
//   Saveback in bank movements.
// - `CorrectionModel` (Swift `TransactionCorrectionModel`): repeats a complete correction the person made
//   several times (type, category and destination account), only after checking it against later months.
// What the person confirms is the training data. It is kept on this device and profile (`Learning`), as on
// the iPhone: it never reaches the cloud document, other people or a global model.

import 'dart:convert';
import 'dart:io';
import 'dart:isolate';
import 'dart:math' as math;

import 'automation.dart' show matchRule, ruleText;
import 'banking.dart' show referenceSeconds, sha256Hex;
import 'edits.dart';
import 'models.dart';
import 'presentation.dart' show listTitle;

const _folding = {
  'á': 'a', 'à': 'a', 'â': 'a', 'ä': 'a', 'ã': 'a', 'é': 'e', 'è': 'e', 'ê': 'e', 'ë': 'e', //
  'í': 'i', 'ì': 'i', 'î': 'i', 'ï': 'i', 'ó': 'o', 'ò': 'o', 'ô': 'o', 'ö': 'o', 'õ': 'o', //
  'ú': 'u', 'ù': 'u', 'û': 'u', 'ü': 'u', 'ñ': 'n', 'ç': 'c',
};
final _notLetter = RegExp(r'[^\p{L}]+', unicode: true);

/// Swift `folding(.caseInsensitive, .diacriticInsensitive).lowercased().split(whereSeparator: !isLetter)`.
List<String> letterWords(String text) {
  final folded = text.toLowerCase().split('').map((c) => _folding[c] ?? c).join();
  return folded.split(_notLetter).where((w) => w.isNotEmpty).toList();
}

List<double> _softmax(List<double> scores) {
  final highest = scores.reduce(math.max);
  final values = [for (final s in scores) math.exp(s - highest)];
  final total = values.fold(0.0, (a, b) => a + b);
  return [for (final v in values) v / total];
}

double _log1p(double x) => math.log(1 + x);

/// Trains off the screen's thread. Tests replace it with a direct call.
Future<T> Function<T>(T Function()) runTraining = <T>(T Function() work) => Isolate.run(work);

// Top-level so that the work sent to the other isolate carries only its examples.
Future<(CategoryModel?, CategoryModel?)> _trainCategories(List<CategoryExample> expenses, List<CategoryExample> income) =>
    runTraining(() => (CategoryModel.train(expenses), CategoryModel.train(income)));
Future<OperationModel> _trainOperations(List<OperationExample> examples) => runTraining(() => OperationModel.train(examples));
Future<CorrectionModel?> _trainCorrections(List<CorrectionExample> examples) => runTraining(() => CorrectionModel.train(examples));

// ================================================================ categories

class CategoryExample {
  const CategoryExample(this.text, this.categoryId, this.weight);
  final String text;
  final String categoryId;
  final double weight;
  @override
  bool operator ==(Object other) => other is CategoryExample && other.text == text && other.categoryId == categoryId && other.weight == weight;
  @override
  int get hashCode => Object.hash(text, categoryId, weight);
}

/// A regularised softmax classifier trained on weighted text examples (Swift `TransactionCategoryModel`).
class CategoryModel {
  CategoryModel._(this.labels, this.weights);
  final List<String> labels;
  final Map<String, List<double>> weights;

  static List<String> tokens(String text) =>
      letterWords(text.length > 240 ? text.substring(0, 240) : text).take(18).where((w) => w.length >= 2).toList();

  static List<String> features(String text) {
    final result = <String>{};
    for (final word in tokens(text)) {
      result.add('w:$word');
      final letters = '^${word.length > 24 ? word.substring(0, 24) : word}\$';
      for (var i = 0; i < letters.length - 2; i++) {
        result.add('c:${letters.substring(i, i + 3)}');
      }
    }
    return result.toList()..sort();
  }

  static CategoryModel? train(List<CategoryExample> examples) {
    final labels = examples.map((e) => e.categoryId).toSet().toList()..sort();
    if (labels.length < 2) return null;
    final indices = {for (var i = 0; i < labels.length; i++) labels[i]: i};
    final rows = <(List<String>, int, double)>[];
    for (final example in examples) {
      final f = features(example.text);
      final label = indices[example.categoryId];
      if (f.isEmpty || label == null) continue;
      rows.add((f, label, example.weight));
    }
    if (rows.map((r) => r.$2).toSet().length < 2) return null;
    final weights = <String, List<double>>{};
    for (var epoch = 0; epoch < 18; epoch++) {
      final step = 0.24 / (1 + epoch * 0.12);
      // Rotating the starting point reduces sensitivity to the order of the examples.
      for (var offset = 0; offset < rows.length; offset++) {
        final (f, label, weight) = rows[(offset + epoch * 13) % rows.length];
        final scale = 1 / math.sqrt(f.length);
        final scores = List<double>.filled(labels.length, 0);
        for (final feature in f) {
          final vector = weights[feature];
          if (vector == null) continue;
          for (var i = 0; i < labels.length; i++) {
            scores[i] += vector[i] * scale;
          }
        }
        final probabilities = _softmax(scores);
        final gradient = [for (var i = 0; i < labels.length; i++) step * weight * scale * ((i == label ? 1.0 : 0.0) - probabilities[i])];
        for (final feature in f) {
          final vector = weights[feature] ?? List<double>.filled(labels.length, 0);
          for (var i = 0; i < labels.length; i++) {
            vector[i] = vector[i] * 0.9995 + gradient[i];
          }
          weights[feature] = vector;
        }
      }
    }
    return CategoryModel._(labels, weights);
  }

  /// The proposed category, only when it is clearly ahead of the second one.
  ({String categoryId, double score})? predict(String text, Set<String> allowed) {
    final f = features(text);
    final known = [for (final feature in f) weights[feature]].whereType<List<double>>().toList();
    final candidates = [for (var i = 0; i < labels.length; i++) if (allowed.contains(labels[i])) i];
    if (candidates.length < 2 || known.length < 4 || known.length * 3 < f.length) return null;
    final scale = 1 / math.sqrt(f.length);
    final scores = [for (final i in candidates) known.fold(0.0, (sum, v) => sum + v[i] * scale)];
    final probabilities = _softmax(scores);
    final ranked = List.generate(probabilities.length, (i) => i)..sort((a, b) => probabilities[b].compareTo(probabilities[a]));
    final best = ranked[0], second = ranked[1];
    // This gate decides which proposals are useful enough to show.
    if (probabilities[best] < 0.30 || probabilities[best] - probabilities[second] < 0.10) return null;
    return (categoryId: labels[candidates[best]], score: probabilities[best]);
  }

  /// Invented descriptions grouped by the app's starter categories (the same as the iPhone's).
  static const syntheticExamples = <(String, List<String>)>[
    ('Supermercado', ['Supermercado La Cesta compra', 'Mercado Fresco alimentación', 'Hipermercado Plaza compra semanal', 'Tienda de alimentos Fruta Verde']),
    ('Restaurantes', ['Restaurante El Olivo cena', 'Cafetería Nube desayuno', 'Bar Terraza menú', 'Pizzería Farol comida']),
    ('Transporte', ['Metro billete urbano', 'Taxi trayecto ciudad', 'Autobús recarga abono', 'Tren cercanías billete', 'Viaje VTC traslado urbano']),
    ('Coche', ['Gasolinera Ruta combustible', 'Taller mecánico revisión coche', 'Estacionamiento parking vehículo', 'Peaje autopista']),
    ('Vivienda', ['Alquiler mensual vivienda', 'Recibo comunidad vecinos', 'Cuota hipoteca vivienda', 'Arrendamiento piso']),
    ('Salud', ['Clínica consulta médica', 'Dentista revisión dental', 'Fisioterapia sesión', 'Centro óptico graduación']),
    ('Farmacia', ['Farmacia Plaza medicamentos', 'Parafarmacia Sol', 'Farmacia Avenida receta', 'Farmacia Norte productos']),
    ('Educación', ['Universidad matrícula curso', 'Academia clases idiomas', 'Formación curso profesional', 'Cuota escuela estudios']),
    ('Servicios del hogar', ['Recibo suministro eléctrico', 'Factura gas vivienda', 'Recibo agua municipal', 'Electricidad factura mensual']),
    ('Internet y móvil', ['Factura fibra internet', 'Operador telefonía móvil', 'Banda ancha cuota conexión', 'Recarga teléfono móvil']),
    ('Seguros', ['Póliza seguro hogar', 'Prima seguro vehículo', 'Recibo aseguradora', 'Cuota seguro salud']),
    ('Suscripciones', ['Suscripción streaming mensual', 'Cuota plataforma música', 'Renovación membresía digital', 'Suscripción revista']),
    ('Compras', ['Tienda electrónica auriculares', 'Compra online accesorios', 'Bazar artículos hogar', 'Pedido comercio general']),
    ('Ropa', ['Tienda moda prendas', 'Zapatería calzado', 'Compra ropa abrigo', 'Tienda textil camisetas']),
    ('Ocio', ['Cine entradas película', 'Entrada concierto música', 'Teatro espectáculo', 'Compra videojuego']),
    ('Viajes', ['Hotel reserva alojamiento', 'Billete vuelo aerolínea', 'Hostal estancia', 'Agencia viaje reserva']),
    ('Mascotas', ['Veterinario consulta mascota', 'Alimento perro tienda animales', 'Arena gato tienda mascotas', 'Peluquería canina']),
    ('Impuestos y comisiones', ['Comisión mantenimiento cuenta', 'Impuesto municipal recibo', 'Comisión bancaria tarjeta', 'Tasa administración']),
    ('Nómina', ['Abono nómina mensual', 'Ingreso salario empresa', 'Transferencia haberes nómina', 'Pago mensual sueldo']),
    ('Reembolsos', ['Devolución compra comercio', 'Reembolso pedido devuelto', 'Abono devolución tarjeta', 'Devolución importe compra']),
    ('Intereses', ['Abono intereses cuenta', 'Liquidación intereses ahorro', 'Interés remuneración saldo', 'Intereses depósito']),
    ('Dividendos', ['Abono dividendo acciones', 'Dividendo cartera valores', 'Pago dividendos participaciones', 'Distribución dividendos']),
    ('Ventas', ['Ingreso venta segunda mano', 'Cobro venta artículo', 'Abono venta marketplace', 'Liquidación ventas']),
    ('Retirada de efectivo', ['Retirada efectivo cajero', 'Reintegro en cajero automático', 'Disposición efectivo ATM', 'Extracción de dinero en cajero', 'Retirada de metálico oficina']),
    ('Ingreso de efectivo', ['Ingreso de efectivo en cajero', 'Depósito de billetes en oficina', 'Abono efectivo cajero automático', 'Ingreso de metálico en ventanilla', 'Depósito efectivo autoservicio']),
  ];
}

// ================================================================ operations

enum OperationKind { ordinary, investment, roundUp, saveback }

extension OperationKindText on OperationKind {
  String get title => switch (this) {
        OperationKind.ordinary => 'Otro movimiento',
        OperationKind.investment => 'Aportación a inversión',
        OperationKind.roundUp => 'Round up',
        OperationKind.saveback => 'Saveback',
      };
  String get explanation => switch (this) {
        OperationKind.ordinary => 'No es uno de estos beneficios ni una aportación a inversión.',
        OperationKind.investment => 'Dinero propio destinado a inversión. Comprueba la cuenta de destino antes de convertirlo en transferencia.',
        OperationKind.roundUp => 'Redondeo de pagos: aparta efectivo propio para invertir. No debe sumarse al consumo ni descontarse otra vez al ejecutarse.',
        OperationKind.saveback => 'Recompensa destinada a inversión. Distingue el bruto, la retención y el neto; no presupone una salida de efectivo propio.',
      };
}

/// The card's benefit conditions, known from a date (Swift `CardTerms`).
class CardTerms {
  const CardTerms(this.savebackPercent, this.roundUpMultiplier, this.validFrom);
  final double savebackPercent;
  final int roundUpMultiplier;
  final DateTime validFrom;
  static const multipliers = [1, 2, 3, 5, 10];
  bool get valid => savebackPercent.isFinite && savebackPercent > 0 && savebackPercent <= 100 && multipliers.contains(roundUpMultiplier);
  Map<String, dynamic> toJson() => {'savebackPercent': savebackPercent, 'roundUpMultiplier': roundUpMultiplier, 'validFrom': validFrom.millisecondsSinceEpoch};
  static CardTerms fromJson(Map<String, dynamic> j) =>
      CardTerms((j['savebackPercent'] as num).toDouble(), (j['roundUpMultiplier'] as num).toInt(), DateTime.fromMillisecondsSinceEpoch((j['validFrom'] as num).toInt()));
}

/// What the models see of a bank movement (Swift `TransactionOperationModel.Input`).
class OperationInput {
  const OperationInput(
      {required this.text,
      required this.amountMinor,
      required this.isCredit,
      required this.day,
      required this.weekday,
      required this.month,
      required this.accountKey,
      this.savebackPercent,
      this.roundUpMultiplier});
  final String text;
  final int amountMinor;
  final bool isCredit;
  final int day;

  /// 1 Sunday … 7 Saturday, as Swift's calendar.
  final int weekday;

  /// "year-month", without padding (as Swift writes it).
  final String month;
  final String accountKey;
  final double? savebackPercent;
  final int? roundUpMultiplier;

  bool get valid =>
      amountMinor > 0 &&
      amountMinor <= 1000000000000 &&
      day >= 1 &&
      day <= 31 &&
      weekday >= 1 &&
      weekday <= 7 &&
      accountKey.isNotEmpty &&
      (savebackPercent == null || (savebackPercent!.isFinite && savebackPercent! > 0 && savebackPercent! <= 100)) &&
      (roundUpMultiplier == null || CardTerms.multipliers.contains(roundUpMultiplier));

  List<String> get words => letterWords(text.length > 400 ? text.substring(0, 400) : text).take(30).toList();

  bool get hasDescription => words.any((w) => !const {'movimiento', 'bancario', 'bank', 'transaction', 'txt', 'd', 'h'}.contains(w));

  String get key => '$accountKey|$month|$day|$weekday|$amountMinor|$isCredit|$text|$savebackPercent|$roundUpMultiplier';

  @override
  bool operator ==(Object other) => other is OperationInput && other.key == key;
  @override
  int get hashCode => key.hashCode;

  Map<String, dynamic> toJson() => {
        'text': text,
        'amountMinor': amountMinor,
        'isCredit': isCredit,
        'day': day,
        'weekday': weekday,
        'month': month,
        'accountKey': accountKey,
        if (savebackPercent != null) 'savebackPercent': savebackPercent,
        if (roundUpMultiplier != null) 'roundUpMultiplier': roundUpMultiplier,
      };
  static OperationInput fromJson(Map<String, dynamic> j) => OperationInput(
      text: '${j['text']}',
      amountMinor: (j['amountMinor'] as num).toInt(),
      isCredit: j['isCredit'] == true,
      day: (j['day'] as num).toInt(),
      weekday: (j['weekday'] as num).toInt(),
      month: '${j['month']}',
      accountKey: '${j['accountKey']}',
      savebackPercent: (j['savebackPercent'] as num?)?.toDouble(),
      roundUpMultiplier: (j['roundUpMultiplier'] as num?)?.toInt());
}

class OperationExample {
  const OperationExample(this.input, this.kind, {required this.confirmed});
  final OperationInput input;
  final OperationKind kind;
  final bool confirmed;
}

class OperationPrediction {
  const OperationPrediction(this.kind, this.score, {required this.usesContext});
  final OperationKind kind;

  /// A model score, not a calibrated probability of being right.
  final double score;
  final bool usesContext;
}

/// Supervised recognition of investment operations, independent of categories and accounting.
/// Invented rows teach vocabulary only; context is learned only from confirmed examples.
class OperationModel {
  OperationModel._(this.weights, this.confirmations);
  final Map<String, List<double>> weights;
  final List<OperationExample> confirmations;
  static const kinds = OperationKind.values;

  static Map<String, double> features(OperationInput input, {required bool context}) {
    final result = <String, double>{};
    final words = input.words.where((w) => w.length >= 2 && !const {'movimiento', 'bancario', 'transaction'}.contains(w)).toSet();
    final textScale = 1 / math.sqrt(math.max(1, words.length));
    for (final word in words) {
      result['w:$word'] = textScale;
      final letters = '^${word.length > 30 ? word.substring(0, 30) : word}\$';
      for (var i = 0; i < letters.length - 2; i++) {
        result['c:${letters.substring(i, i + 3)}'] = textScale * 0.25;
      }
    }
    if (!context) return result;
    // No fixed amount or day rule assigns a class.
    result['bias'] = 0.3;
    result['credit'] = input.isCredit ? 0.6 : -0.6;
    result['amount'] = _log1p(input.amountMinor / 100) / 8;
    result['day:${input.day}'] = 0.5;
    result['weekday:${input.weekday}'] = 0.2;
    result['account:${input.accountKey}'] = 0.4;
    result['amount-day'] = result['amount']! * input.day / 31;
    if (input.savebackPercent != null) result['saveback-rate'] = input.savebackPercent! / 100;
    if (input.roundUpMultiplier != null) result['roundup-multiplier'] = input.roundUpMultiplier! / 10;
    return result;
  }

  static OperationModel train(List<OperationExample> examples) {
    // Repeated observations do not inflate support; contradictory ones are ambiguous and left out.
    final groups = <String, List<OperationExample>>{};
    for (final e in examples.where((e) => e.confirmed && e.input.valid)) {
      groups.putIfAbsent(e.input.key, () => []).add(e);
    }
    final confirmed = [
      for (final rows in groups.values)
        if (rows.map((r) => r.kind).toSet().length == 1) rows.first
    ]..sort((a, b) => a.input.key.compareTo(b.input.key));
    final rows = [
      for (final e in [..._synthetic, ...confirmed]) (features(e.input, context: e.confirmed), kinds.indexOf(e.kind), e.confirmed ? 2.0 : 1.0)
    ];
    final weights = <String, List<double>>{};
    for (var epoch = 0; epoch < 70; epoch++) {
      final step = 0.16 / (1 + epoch * 0.03);
      for (var offset = 0; offset < rows.length; offset++) {
        final (f, label, importance) = rows[(offset + epoch * 7) % rows.length];
        final scores = List<double>.filled(kinds.length, 0);
        f.forEach((feature, value) {
          final vector = weights[feature];
          if (vector == null) return;
          for (var i = 0; i < kinds.length; i++) {
            scores[i] += vector[i] * value;
          }
        });
        final probabilities = _softmax(scores);
        f.forEach((feature, value) {
          final vector = weights[feature] ?? List<double>.filled(kinds.length, 0);
          for (var i = 0; i < kinds.length; i++) {
            vector[i] = vector[i] * 0.9997 + step * importance * value * ((i == label ? 1 : 0) - probabilities[i]);
          }
          weights[feature] = vector;
        });
      }
    }
    return OperationModel._(weights, confirmed);
  }

  OperationPrediction? predict(OperationInput input) {
    if (!input.valid) return null;
    final related = confirmations.where((e) => e.input.accountKey == input.accountKey && e.input != input).toList();
    final context = !input.hasDescription;
    if (context) {
      // Amount and date alone are ambiguous: independent evidence of the same account is required.
      if (related.length < 8 || related.map((e) => e.input.month).toSet().length < 2 || related.map((e) => e.kind).toSet().length < 2) return null;
    }
    final f = features(input, context: context);
    if (f.isEmpty) return null;
    final scores = List<double>.filled(kinds.length, 0);
    f.forEach((feature, value) {
      final vector = weights[feature];
      if (vector == null) return;
      for (var i = 0; i < kinds.length; i++) {
        scores[i] += vector[i] * value;
      }
    });
    final probabilities = _softmax(scores);
    final ranked = List.generate(kinds.length, (i) => i)..sort((a, b) => probabilities[b].compareTo(probabilities[a]));
    final first = ranked[0], second = ranked[1], kind = kinds[first];
    if (kind == OperationKind.ordinary || probabilities[first] < (context ? 0.8 : 0.7) || probabilities[first] - probabilities[second] < 0.3) return null;
    if (context && (related.where((e) => e.kind == kind).length < 3 || related.where((e) => e.kind != kind).length < 3)) return null;
    return OperationPrediction(kind, probabilities[first], usesContext: context);
  }

  /// Invented vocabulary, never personal records (the same as the iPhone's).
  static final _synthetic = [
    for (final (kind, texts) in const [
      (OperationKind.roundUp, ['Round up inversión', 'Roundup tarjeta', 'Redondeo de compras', 'Inversión por redondeos', 'Card round up investment', 'Redondeo acumulado tarjeta']),
      (OperationKind.saveback, ['Saveback recompensa', 'Save back inversión', 'Recompensa Saveback neta', 'Saveback reward investment', 'Bonificación Saveback tarjeta', 'Saveback impuestos deducidos']),
      (OperationKind.investment, ['Plan de inversión ejecutado', 'Aportación a cartera de valores', 'Compra participaciones fondo inversión', 'Savings plan execution', 'Aportación periódica inversión', 'Compra ETF plan ahorro']),
      (OperationKind.ordinary, ['Supermercado compra tarjeta', 'Cafetería desayuno', 'Comisión mantenimiento', 'Nómina mensual', 'Bizum recibido', 'Transferencia familiar', 'Pago tarjeta tienda online', 'Intereses cuenta ahorro', 'Pago restaurante', 'Retirada efectivo', 'Abono devolución compra', 'Suscripción plataforma']),
    ])
      for (final text in texts)
        OperationExample(
            OperationInput(text: text, amountMinor: 100, isCredit: false, day: 1, weekday: 1, month: 'synthetic', accountKey: 'synthetic'), kind,
            confirmed: false)
  ];
}

// ================================================================ corrections

/// What a correction leaves: the type, the destination account and the category.
class CorrectionAction {
  const CorrectionAction(this.type, this.destinationId, this.categoryId);
  final String type;
  final String? destinationId;
  final String? categoryId;
  @override
  bool operator ==(Object other) => other is CorrectionAction && other.type == type && other.destinationId == destinationId && other.categoryId == categoryId;
  @override
  int get hashCode => Object.hash(type, destinationId, categoryId);
  Map<String, dynamic> toJson() => {'type': type, 'destinationID': destinationId, 'categoryID': categoryId};
  static CorrectionAction fromJson(Map<String, dynamic> j) => CorrectionAction('${j['type']}', j['destinationID'] as String?, j['categoryID'] as String?);
  static CorrectionAction of(Transaction t) => CorrectionAction(t.type.name, t.destinationAccountId, t.categoryId);
}

class CorrectionExample {
  const CorrectionExample(this.input, this.action);
  final OperationInput input;
  final CorrectionAction action;
  @override
  bool operator ==(Object other) => other is CorrectionExample && other.input == input && other.action == action;
  @override
  int get hashCode => Object.hash(input, action);
  Map<String, dynamic> toJson() => {'input': input.toJson(), 'action': action.toJson()};
  static CorrectionExample fromJson(Map<String, dynamic> j) =>
      CorrectionExample(OperationInput.fromJson(Map<String, dynamic>.from(j['input'] as Map)), CorrectionAction.fromJson(Map<String, dynamic>.from(j['action'] as Map)));
}

class CorrectionDecision {
  const CorrectionDecision(this.action, this.confirmedExamples, this.validatedPredictions);
  final CorrectionAction action;
  final int confirmedExamples;
  final int validatedPredictions;
}

/// Nearest-neighbour classification of complete corrections. No merchant rules or personal amounts: only the
/// person's explicit decisions are examples, and an action is repeated only after it was right on later months.
class CorrectionModel {
  CorrectionModel._(this.examples, this.validated);
  final List<CorrectionExample> examples;
  final Map<String, int> validated;

  static int? month(String value) {
    final parts = value.split('-').map(int.tryParse).toList();
    if (parts.length != 2 || parts.contains(null) || parts[1]! < 1 || parts[1]! > 12) return null;
    return parts[0]! * 12 + parts[1]!;
  }

  static String _validationKey(OperationInput input, CorrectionAction action) =>
      '${input.accountKey}|${input.isCredit}|${action.type}|${action.destinationId}|${action.categoryId}';

  static CorrectionModel? train(List<CorrectionExample> input) {
    final groups = <String, Map<CorrectionAction, CorrectionExample>>{};
    for (final e in input.where((e) => e.input.valid && month(e.input.month) != null)) {
      // Contradictory labels stay as competing evidence instead of hiding the ambiguity.
      groups.putIfAbsent(e.input.key, () => {}).putIfAbsent(e.action, () => e);
    }
    String order(OperationInput i) => '${i.accountKey}|${i.month}|${i.day}|${i.amountMinor}|${i.text}';
    final rows = [for (final g in groups.values) ...g.values]..sort((a, b) => order(a.input).compareTo(order(b.input)));
    if (rows.length < 9) return null;
    final successes = <String, int>{};
    final failures = <String>{};
    // Rolling evaluation in time: each label is predicted only with strictly earlier months.
    for (final row in rows) {
      final earlier = rows.where((e) => (month(e.input.month) ?? 0) < (month(row.input.month) ?? 0)).toList();
      final prediction = _vote(row.input, earlier);
      if (prediction == null) continue;
      final key = _validationKey(row.input, prediction);
      if (prediction == row.action) {
        successes[key] = (successes[key] ?? 0) + 1;
      } else {
        failures.add(key);
      }
    }
    return CorrectionModel._(rows, {
      for (final entry in successes.entries)
        if (!failures.contains(entry.key)) entry.key: entry.value
    });
  }

  CorrectionDecision? automaticDecision(OperationInput input) {
    final inputMonth = month(input.month);
    if (!input.valid || inputMonth == null) return null;
    final action = _vote(input, examples);
    if (action == null) return null;
    final checks = validated[_validationKey(input, action)] ?? 0;
    if (checks < 3) return null;
    final related = examples.where((e) => e.input.accountKey == input.accountKey && e.input.isCredit == input.isCredit).toList();
    final months = related.map((e) => month(e.input.month)).whereType<int>();
    if (months.isEmpty || inputMonth < months.reduce(math.max)) return null;
    final supporting = related.where((e) => e.action == action).toList();
    if (supporting.length < 6 ||
        related.where((e) => e.action != action).length < 3 ||
        supporting.map((e) => month(e.input.month)).whereType<int>().toSet().length < 2) {
      return null;
    }
    return CorrectionDecision(action, supporting.length, checks);
  }

  static CorrectionAction? _vote(OperationInput input, List<CorrectionExample> examples) {
    final peers = examples.where((e) => e.input.accountKey == input.accountKey && e.input.isCredit == input.isCredit && e.input != input).toList();
    if (peers.length < 6) return null;
    final ranked = [for (final e in peers) (e, distance(input, e.input))]..sort((a, b) {
        if (a.$2 != b.$2) return a.$2.compareTo(b.$2);
        return a.$1.input.month.compareTo(b.$1.input.month);
      });
    final nearest = ranked.take(3).toList();
    final action = nearest.first.$1.action;
    if (!nearest.every((n) => n.$1.action == action)) return null;
    final worst = nearest.last.$2;
    if (worst > 0.18) return null;
    final competing = ranked.where((r) => r.$1.action != action).firstOrNull;
    if (competing == null || competing.$2 < worst + 0.08) return null;
    return action;
  }

  static double distance(OperationInput left, OperationInput right) {
    final amount = math.min(1.0, (_log1p(left.amountMinor / 100) - _log1p(right.amountMinor / 100)).abs() / 4);
    final difference = (left.day - right.day).abs();
    final day = math.min(difference, 31 - difference) / 15.5;
    final weekday = left.weekday == right.weekday ? 0.0 : 1.0;
    if (!left.hasDescription && !right.hasDescription) return amount * 0.65 + day * 0.25 + weekday * 0.1;
    if (left.hasDescription != right.hasDescription) return 1;
    final a = left.words.toSet(), b = right.words.toSet();
    final union = a.union(b).length;
    final text = union == 0 ? 1.0 : 1 - a.intersection(b).length / union;
    return text * 0.7 + amount * 0.15 + day * 0.1 + weekday * 0.05;
  }
}

// ================================================================ the person's learning

class _Record {
  const _Record(this.signature, this.kind);
  final String signature;
  final OperationKind kind;
}

class _HumanCorrection {
  const _HumanCorrection(this.example, this.signature);
  final CorrectionExample example;
  final String signature;
  Map<String, dynamic> toJson() => {'example': example.toJson(), 'signature': signature};
  static _HumanCorrection fromJson(Map<String, dynamic> j) => _HumanCorrection(CorrectionExample.fromJson(Map<String, dynamic>.from(j['example'] as Map)), '${j['signature']}');
}

class _Automatic {
  const _Automatic(this.before, this.after, this.signature, this.fingerprint, this.validated);
  final CorrectionAction before;
  final CorrectionAction after;
  final String signature;
  final String fingerprint;
  final int validated;
  Map<String, dynamic> toJson() => {'before': before.toJson(), 'after': after.toJson(), 'signature': signature, 'fingerprint': fingerprint, 'validated': validated};
  static _Automatic fromJson(Map<String, dynamic> j) => _Automatic(CorrectionAction.fromJson(Map<String, dynamic>.from(j['before'] as Map)),
      CorrectionAction.fromJson(Map<String, dynamic>.from(j['after'] as Map)), '${j['signature']}', '${j['fingerprint']}', (j['validated'] as num).toInt());
}

/// A bank movement's facts before an edit; the resulting action is learnt only from a human decision.
class EditSnapshot {
  const EditSnapshot(
      {required this.input,
      required this.action,
      required this.sourceId,
      required this.amount,
      required this.date,
      required this.bankKey,
      required this.kind,
      required this.signature});
  final OperationInput input;
  final CorrectionAction action;
  final String sourceId;
  final int amount;
  final DateTime date;
  final String bankKey;
  final OperationKind? kind;
  final String signature;
}

class OperationReview {
  const OperationReview({this.confirmed, this.prediction});
  final OperationKind? confirmed;
  final OperationPrediction? prediction;
}

class AutomationStatus {
  const AutomationStatus({required this.enabled, required this.savedExamples, required this.automaticallyApplied, required this.validatedPredictions});
  final bool enabled;
  final int savedExamples;
  final bool automaticallyApplied;
  final int validatedPredictions;
}

// ================================================================ the shared document

/// Canonical signatures of the shared learning (CloudBackend/learning-contract.md): the same on both apps.
String learningCategorySignature(String type, String categoryId, String description) => sha256Hex('$type|$categoryId|$description');

String learningIdentity(
        {required String id,
        required String type,
        required int amountMinor,
        required int dateMs,
        required String description,
        String? sourceId,
        String? destinationId,
        String? sourceCurrency,
        String? destinationCurrency,
        String? bankEntryKey}) =>
    sha256Hex([
      id,
      type,
      '$amountMinor',
      '$dateMs',
      description,
      sourceId ?? '',
      destinationId ?? '',
      sourceCurrency ?? '',
      destinationCurrency ?? '',
      bankEntryKey ?? '',
    ].join('|'));

String learningAccountKey(String accountId, String currency) => sha256Hex('$accountId|$currency');

const _entrySections = ['categories', 'operations', 'terms', 'corrections', 'automatic'];

int _at(Object? entry) => entry is Map ? ((entry['at'] as num?)?.toInt() ?? 0) : 0;
Map<String, dynamic> _section(Map<String, dynamic> doc, String key) => doc[key] is Map ? Map<String, dynamic>.from(doc[key] as Map) : {};

/// Combines two learning documents: per entry the newest change wins (the cloud's on a tie), reviews are
/// joined, and the earliest dates are kept (contract «Combinación»).
Map<String, dynamic> mergeLearning(Map<String, dynamic> local, Map<String, dynamic> remote) {
  final result = <String, dynamic>{'version': 1};
  for (final key in ['since', 'enabledAt']) {
    final values = [local[key], remote[key]].whereType<num>().map((v) => v.toInt());
    if (values.isNotEmpty) result[key] = values.reduce(math.min);
  }
  final mine = local['automation'], theirs = remote['automation'];
  if (mine is Map || theirs is Map) result['automation'] = theirs is Map && _at(theirs) >= _at(mine) ? theirs : mine;
  for (final key in _entrySections) {
    final a = _section(local, key), b = _section(remote, key);
    final merged = <String, dynamic>{};
    for (final id in {...a.keys, ...b.keys}) {
      final left = a[id], right = b[id];
      merged[id] = right == null ? left : (left == null || _at(right) >= _at(left) ? right : left);
    }
    if (merged.isNotEmpty) result[key] = merged;
  }
  final a = _section(local, 'reviewed'), b = _section(remote, 'reviewed');
  final reviewed = <String, dynamic>{
    for (final id in {...a.keys, ...b.keys}) id: [a[id], b[id]].whereType<num>().map((v) => v.toInt()).reduce(math.min)
  };
  if (reviewed.isNotEmpty) result['reviewed'] = reviewed;
  return result;
}

/// The same document written the same way: keys sorted, nulls and empty sections left out, and whole
/// numbers without decimals. Two documents with the same content give the same text.
String canonicalLearningJson(Object? value) {
  Object? clean(Object? v) {
    if (v is Map) {
      final keys = v.keys.map((k) => '$k').toList()..sort();
      final result = <String, Object?>{};
      for (final k in keys) {
        final item = clean(v[k]);
        if (item == null || (item is Map && item.isEmpty)) continue;
        result[k] = item;
      }
      return result;
    }
    if (v is List) return [for (final x in v) clean(x)];
    if (v is double && v == v.roundToDouble() && v.abs() < 9e15) return v.toInt();
    return v;
  }

  return jsonEncode(clean(value));
}

/// Everything the person has taught, shared by their devices, and the models trained from it.
class Learning {
  Learning({File? file, DateTime? since}) : _file = file {
    // Milliseconds, as it is saved: the date read back is exactly the same.
    this.since = DateTime.fromMillisecondsSinceEpoch((since ?? DateTime.now()).millisecondsSinceEpoch);
  }

  final File? _file;

  /// Called after every change that should reach the person's other devices.
  void Function()? onChange;

  // Categories (Swift `TransactionLearning.History`).
  late DateTime since;
  final Map<String, String> confirmations = {};

  // Operations and corrections (Swift `TransactionOperationLearning.History`).
  final Map<String, _Record> _records = {};
  final Map<String, List<CardTerms>> _terms = {};
  final Map<String, _HumanCorrection> _corrections = {};
  final Map<String, _HumanCorrection> _priorCorrections = {};
  final Map<String, int> _reviewed = {};
  final Map<String, _Automatic> _automatic = {};
  bool automationEnabled = true;
  DateTime? enabledAt;

  /// When each entry last changed, also for removed ones (so the removal reaches the other devices).
  final Map<String, Map<String, int>> _changedAt = {for (final s in _entrySections) s: {}};
  int _automationAt = 0;

  /// Entries received from another device that this one cannot interpret: kept and passed on unchanged.
  final Map<String, Map<String, dynamic>> _foreign = {for (final s in _entrySections) s: {}};

  int get _now => DateTime.now().millisecondsSinceEpoch;
  void _touch(String section, String key) {
    _changedAt[section]![key] = _now;
    _foreign[section]!.remove(key);
  }

  /// Opens the person's learning, creating it the first time (its date limits the historic examples).
  static Future<Learning> open(Directory directory, String user) async {
    final file = File('${directory.path}${Platform.pathSeparator}learning-$user.json');
    final learning = Learning(file: file);
    try {
      if (await file.exists()) {
        learning.adopt(jsonDecode(await file.readAsString()) as Map<String, dynamic>);
      } else {
        await learning._save(share: false);
      }
    } catch (_) {
      // A damaged file is not used; the movements are unaffected and learning starts again.
    }
    return learning;
  }

  /// Replaces what is known with a shared document (read from the device or combined with the cloud).
  void adopt(Map<String, dynamic> j) {
    confirmations.clear();
    _records.clear();
    _terms.clear();
    _corrections.clear();
    _priorCorrections.clear();
    _reviewed.clear();
    _automatic.clear();
    for (final s in _entrySections) {
      _changedAt[s]!.clear();
      _foreign[s]!.clear();
    }
    Map<String, dynamic> obj(Object? v) => v is Map ? Map<String, dynamic>.from(v) : {};
    if (j['since'] is num) since = DateTime.fromMillisecondsSinceEpoch((j['since'] as num).toInt());
    enabledAt = j['enabledAt'] is num ? DateTime.fromMillisecondsSinceEpoch((j['enabledAt'] as num).toInt()) : null;
    final automation = obj(j['automation']);
    automationEnabled = automation['enabled'] != false;
    _automationAt = _at(automation);
    void each(String section, void Function(String key, Map<String, dynamic> entry) read) {
      obj(j[section]).forEach((key, value) {
        final entry = obj(value);
        _changedAt[section]![key] = _at(entry);
        try {
          read(key, entry);
        } catch (_) {
          _foreign[section]![key] = entry;
        }
      });
    }

    each('categories', (key, e) {
      if (e['signature'] is String) confirmations[key] = e['signature'] as String;
    });
    each('operations', (key, e) {
      if (e['signature'] is! String) return;
      final kind = OperationKind.values.where((x) => x.name == e['kind']).firstOrNull;
      if (kind == null) throw const FormatException('kind');
      _records[key] = _Record(e['signature'] as String, kind);
    });
    each('terms', (key, e) {
      _terms.putIfAbsent('${e['account']}', () => []).add(CardTerms.fromJson(e));
    });
    each('corrections', (key, e) {
      if (e['example'] is Map && e['signature'] is String) {
        _corrections[key] = _HumanCorrection(CorrectionExample.fromJson(obj(e['example'])), e['signature'] as String);
      }
      final prior = obj(e['prior']);
      if (prior['example'] is Map && prior['signature'] is String) _priorCorrections[key] = _HumanCorrection.fromJson(prior);
    });
    each('automatic', (key, e) {
      if (e['after'] is Map) _automatic[key] = _Automatic.fromJson(e);
    });
    obj(j['reviewed']).forEach((key, value) {
      if (value is num) _reviewed[key] = value.toInt();
    });
  }

  /// The shared document (CloudBackend/learning-contract.md).
  Map<String, dynamic> toShared() {
    Map<String, dynamic> section(String name, Map<String, dynamic> Function(String key) entry) {
      final result = <String, dynamic>{..._foreign[name]!};
      for (final key in _changedAt[name]!.keys) {
        if (_foreign[name]!.containsKey(key)) continue;
        result[key] = {...entry(key), 'at': _changedAt[name]![key]};
      }
      return result;
    }

    final termsByKey = <String, (String, CardTerms)>{
      for (final entry in _terms.entries)
        for (final t in entry.value) '${entry.key}|${t.validFrom.millisecondsSinceEpoch}': (entry.key, t)
    };
    return {
      'version': 1,
      'since': since.millisecondsSinceEpoch,
      if (enabledAt != null) 'enabledAt': enabledAt!.millisecondsSinceEpoch,
      'automation': {'enabled': automationEnabled, 'at': _automationAt},
      'categories': section('categories', (k) => {'signature': confirmations[k]}),
      'operations': section('operations', (k) => {'signature': _records[k]?.signature, 'kind': _records[k]?.kind.name}),
      'terms': section('terms', (k) {
        final found = termsByKey[k];
        return found == null ? <String, dynamic>{} : {'account': found.$1, ...found.$2.toJson()};
      }),
      'corrections': section('corrections', (k) => {
            'example': _corrections[k]?.example.toJson(),
            'signature': _corrections[k]?.signature,
            'prior': _priorCorrections[k]?.toJson(),
          }),
      'automatic': section('automatic', (k) => _automatic[k]?.toJson() ?? <String, dynamic>{}),
      'reviewed': {..._reviewed},
    };
  }

  /// Written to a temporary file and renamed. Any change invalidates the trained models.
  Future<void> _save({bool invalidate = true, bool share = true}) async {
    if (invalidate) {
      _categoryJob = null;
      _operationJob = null;
      _correctionJob = null;
    }
    final file = _file;
    if (file != null) {
      final temporary = File('${file.path}.tmp');
      await temporary.writeAsString(jsonEncode(toShared()), flush: true);
      await temporary.rename(file.path);
    }
    if (share) onChange?.call();
  }

  /// Keeps the result of combining with the cloud, without announcing it as a new change.
  Future<void> store(Map<String, dynamic> document) async {
    adopt(document);
    await _save(share: false);
  }

  /// Copy of everything taught, to keep it in a backup.
  String export() => const JsonEncoder.withIndent('  ').convert(toShared());

  // ---------------------------------------------------------------- categories

  String _categorySignature(Transaction t, String categoryId) => learningCategorySignature(t.type.name, categoryId, t.descriptionText);

  /// Records the categories the person chose (Swift `TransactionLearning.confirm`), after the save.
  Future<void> confirmCategories(List<Transaction> rows, Finances data, {bool recordCorrection = true}) async {
    if (rows.isEmpty) return;
    if (recordCorrection) await rememberCategoryReviews(rows, data);
    for (final t in rows) {
      final category = data.category(t.categoryId);
      if (t.type == TransactionType.transfer || category == null || !categorySupports(category, t.type)) {
        if (confirmations.remove(t.id) != null) _touch('categories', t.id);
      } else {
        confirmations[t.id] = _categorySignature(t, category.id);
        _touch('categories', t.id);
      }
    }
    await _save();
  }

  String? _categoryKey;
  Future<(CategoryModel?, CategoryModel?)>? _categoryJob;

  Future<(CategoryModel?, CategoryModel?)> categoryModels(Finances data) {
    final specialized = specializedIds(data);
    final rows = data.transactions.where((t) => !specialized.contains(t.id)).toList();
    final expenses = categoryExamples(TransactionType.expense, data, rows);
    final income = categoryExamples(TransactionType.income, data, rows);
    final key = sha256Hex(jsonEncode([
      for (final list in [expenses, income]) [for (final e in list) '${e.categoryId}|${e.weight}|${e.text}']
    ]));
    if (_categoryJob != null && key == _categoryKey) return _categoryJob!;
    _categoryKey = key;
    return _categoryJob = _trainCategories(expenses, income);
  }

  /// The category the model proposes for a concept, or null when it is not clear enough.
  Future<String?> suggestCategory(String text, TransactionType type, Finances data) async {
    if (type == TransactionType.transfer || CategoryModel.tokens(text).isEmpty) return null;
    final (expenses, income) = await categoryModels(data);
    final model = type.countsAsIncome ? income : expenses;
    final allowed = data.categories.where((c) => categorySupports(c, type)).map((c) => c.id).toSet();
    return model?.predict(text, allowed)?.categoryId;
  }

  /// Swift `TransactionLearning.examples`: invented examples for the starter categories, every confirmed
  /// choice (weight 5) and up to 35 earlier movements per category (weight 0.55).
  List<CategoryExample> categoryExamples(TransactionType type, Finances data, List<Transaction> transactions) {
    final active = data.categories.where((c) => categorySupports(c, type)).toList();
    final grouped = <String, List<Category>>{};
    for (final c in active) {
      grouped.putIfAbsent(ruleText(c.name), () => []).add(c);
    }
    final examples = <CategoryExample>[
      for (final (name, texts) in CategoryModel.syntheticExamples)
        if (grouped[ruleText(name)]?.length == 1)
          for (final text in texts) CategoryExample(text, grouped[ruleText(name)]!.first.id, 1)
    ];
    final ordered = [...transactions]..sort((a, b) {
        final ac = confirmations.containsKey(a.id), bc = confirmations.containsKey(b.id);
        if (ac != bc) return ac ? -1 : 1;
        if (a.date != b.date) return b.date.compareTo(a.date);
        return a.id.compareTo(b.id);
      });
    final seen = <String, Set<String>>{};
    final historical = <String, int>{};
    for (final t in ordered) {
      if (examples.length >= 700) break;
      final category = data.category(t.categoryId);
      if (t.type == TransactionType.transfer ||
          t.type.countsAsIncome != type.countsAsIncome ||
          t.duplicateState == 'possible' ||
          category == null ||
          !categorySupports(category, type) ||
          !categorySupports(category, t.type)) {
        continue;
      }
      final saved = confirmations[t.id];
      final confirmed = saved != null && saved == _categorySignature(t, category.id);
      if (!confirmed) {
        final name = ruleText(category.name);
        if (saved != null ||
            !t.updatedAt.isBefore(since) ||
            t.recurringMovementId != null ||
            name == 'otros gastos' ||
            name == 'otros ingresos' ||
            (historical[category.id] ?? 0) >= 35 ||
            matchRule(t.descriptionText, t.type, data) != null) {
          continue;
        }
      }
      final text = listTitle(t.descriptionText, isBanking: t.isBanking);
      final tokens = CategoryModel.tokens(text);
      if (tokens.isEmpty || !seen.putIfAbsent(category.id, () => {}).add(tokens.join(' '))) continue;
      examples.add(CategoryExample(text, category.id, confirmed ? 5 : 0.55));
      if (!confirmed) historical[category.id] = (historical[category.id] ?? 0) + 1;
    }
    return examples;
  }

  // ---------------------------------------------------------------- operations

  CardTerms? terms(Transaction t) {
    final list = (_terms[t.sourceAccountId] ?? const <CardTerms>[]).where((x) => x.valid && !x.validFrom.isAfter(t.date)).toList();
    if (list.isEmpty) return null;
    return list.reduce((a, b) => a.validFrom.isAfter(b.validFrom) ? a : b);
  }

  /// Only bank movements of active, non-investment, non-credit accounts (Swift `input`).
  OperationInput? input(Transaction t, Finances data, {CardTerms? terms}) {
    final account = data.account(t.sourceAccountId);
    if (account == null ||
        t.bankEntryKey == null ||
        account.isArchived ||
        account.type == AccountType.investment ||
        account.type.isLiability ||
        t.duplicateState == 'possible' ||
        !const {TransactionType.expense, TransactionType.income, TransactionType.transfer}.contains(t.type)) {
      return null;
    }
    // Bank dates are in UTC: travelling must not change the training label.
    final day = t.date.toUtc();
    return OperationInput(
        text: t.descriptionText,
        amountMinor: t.amountMinor,
        isCredit: t.type.countsAsIncome,
        day: day.day,
        weekday: day.weekday % 7 + 1,
        month: '${day.year}-${day.month}',
        accountKey: learningAccountKey(account.id, account.currencyCode),
        savebackPercent: terms?.savebackPercent,
        roundUpMultiplier: terms?.roundUpMultiplier);
  }

  bool supports(Transaction t, Finances data) => input(t, data)?.valid == true;

  String _signature(Transaction t, Finances data, {CorrectionAction? applying}) {
    final source = data.account(t.sourceAccountId);
    final String destinationId, destinationCurrency;
    if (applying != null) {
      destinationId = applying.destinationId ?? '';
      destinationCurrency = applying.destinationId == null ? '' : (source?.currencyCode ?? '');
    } else {
      final destination = data.account(t.destinationAccountId);
      destinationId = destination?.id ?? '';
      destinationCurrency = destination?.currencyCode ?? '';
    }
    return learningIdentity(
        id: t.id,
        type: applying?.type ?? t.type.name,
        amountMinor: t.amountMinor,
        dateMs: t.date.millisecondsSinceEpoch,
        description: t.descriptionText,
        sourceId: source?.id,
        destinationId: destinationId,
        sourceCurrency: source?.currencyCode,
        destinationCurrency: destinationCurrency,
        bankEntryKey: t.bankEntryKey);
  }

  /// Movements identified as Round up, Saveback or investment: they do not teach categories.
  Set<String> specializedIds(Finances data) => {
        for (final t in data.transactions)
          if (_records[t.id] case final record? when record.kind != OperationKind.ordinary && supports(t, data) && record.signature == _signature(t, data)) t.id
      };

  String? _operationKey;
  Future<OperationModel>? _operationJob;

  /// The confirmed identification, or the model's proposal (Swift `review`).
  Future<OperationReview> review(Transaction t, Finances data) async {
    final current = input(t, data, terms: terms(t));
    if (current == null) return const OperationReview();
    final record = _records[t.id];
    if (record != null && record.signature == _signature(t, data)) return OperationReview(confirmed: record.kind);
    final rows = [...data.transactions]..sort((a, b) => a.id.compareTo(b.id));
    final examples = <OperationExample>[];
    for (final row in rows) {
      final r = _records[row.id];
      if (r == null || r.signature != _signature(row, data)) continue;
      final value = input(row, data, terms: terms(row));
      if (value != null) examples.add(OperationExample(value, r.kind, confirmed: true));
      if (examples.length >= 700) break;
    }
    final key = sha256Hex(jsonEncode([for (final e in examples) '${e.kind.name}|${e.input.key}']));
    if (_operationJob == null || key != _operationKey) {
      _operationKey = key;
      _operationJob = _trainOperations(examples);
    }
    final model = await _operationJob!;
    return OperationReview(prediction: model.predict(current));
  }

  /// Only an explicit decision becomes a label. Nothing in the finances changes here.
  Future<void> confirmKind(OperationKind? kind, Transaction t, Finances data) async {
    final value = input(t, data, terms: terms(t));
    if (value == null || !value.valid) throw StateError('unsupported');
    if (kind == null) {
      _records.remove(t.id);
    } else {
      _records[t.id] = _Record(_signature(t, data), kind);
    }
    _touch('operations', t.id);
    await _save();
  }

  Future<void> saveTerms(CardTerms value, Transaction t, Finances data) async {
    final account = t.sourceAccountId;
    if (!value.valid || account == null || !supports(t, data)) throw StateError('invalid');
    final list = _terms.putIfAbsent(account, () => [])..removeWhere((x) => x.validFrom == value.validFrom);
    list.add(value);
    _touch('terms', '$account|${value.validFrom.millisecondsSinceEpoch}');
    await _save();
  }

  // ---------------------------------------------------------------- corrections

  /// The bank facts of a movement before it is edited (Swift `captureEdit`).
  EditSnapshot? captureEdit(Transaction row, Finances data) {
    if (!supports(row, data) || row.sourceAccountId == null || row.bankEntryKey == null) return null;
    if (row.type == TransactionType.transfer) {
      final destination = data.account(row.destinationAccountId);
      if (destination?.type != AccountType.investment || destination?.bankIdentityKey != null) return null;
    }
    final value = input(row, data, terms: terms(row));
    if (value == null) return null;
    final signature = _signature(row, data);
    final prior = _corrections[row.id];
    final saved = _records[row.id];
    return EditSnapshot(
        input: prior != null && prior.signature == signature ? prior.example.input : value,
        action: CorrectionAction.of(row),
        sourceId: row.sourceAccountId!,
        amount: row.amountMinor,
        date: row.date,
        bankKey: row.bankEntryKey!,
        kind: saved?.signature == signature ? saved?.kind : null,
        signature: signature);
  }

  /// Learns the action the person wanted, if the bank facts did not change (Swift `rememberEdit`).
  Future<bool> rememberEdit(EditSnapshot? before, Transaction row, Finances data, {bool explicitlyReviewed = false}) async {
    if (before == null) return false;
    _reviewed.putIfAbsent(row.id, () => _now);
    final desired = CorrectionAction.of(row);
    final learnable = (explicitlyReviewed || desired != before.action) &&
        supports(row, data) &&
        row.sourceAccountId == before.sourceId &&
        row.amountMinor == before.amount &&
        row.date == before.date &&
        row.bankEntryKey == before.bankKey &&
        row.reservedFundId == null &&
        row.reservedAmountMinor == null &&
        row.recurringMovementId == null &&
        (!before.input.isCredit || row.type != TransactionType.transfer);
    if (learnable) {
      final previous = _corrections[row.id];
      if (previous != null && previous.signature == before.signature && previous.example.action == before.action) _priorCorrections[row.id] = previous;
      final signature = _signature(row, data);
      _corrections[row.id] = _HumanCorrection(CorrectionExample(before.input, desired), signature);
      _touch('corrections', row.id);
      enabledAt ??= DateTime.fromMillisecondsSinceEpoch(_now);
      if (before.kind != null) {
        _records[row.id] = _Record(signature, before.kind!);
        _touch('operations', row.id);
      }
    }
    await _save();
    return true;
  }

  /// Categories chosen in a review also teach the correction (Swift `rememberCategoryReviews`).
  Future<void> rememberCategoryReviews(List<Transaction> rows, Finances data) async {
    for (final row in rows) {
      if (row.categoryId == null) continue;
      await rememberEdit(captureEdit(row, data), row, data, explicitlyReviewed: true);
    }
  }

  int get savedCorrections => _corrections.length;
  int get identifiedOperations => _records.length;
  int get automaticCorrections => _automatic.length;

  AutomationStatus automationStatus(Transaction row, Finances data) {
    final audit = _automatic[row.id];
    final applied = audit != null && audit.signature == _signature(row, data) && audit.after == CorrectionAction.of(row);
    return AutomationStatus(
        enabled: automationEnabled, savedExamples: _corrections.length, automaticallyApplied: applied, validatedPredictions: applied ? audit.validated : 0);
  }

  Future<void> setAutomationEnabled(bool enabled) async {
    automationEnabled = enabled;
    _automationAt = _now;
    await _save();
  }

  /// Swift `canApply`: only an uncategorised bank expense or income, without links, to a valid category or
  /// as a transfer to an own investment account not linked to a bank, with no other leg already recorded.
  bool canApply(CorrectionAction desired, Transaction row, Finances data, DateTime now) {
    final source = data.account(row.sourceAccountId);
    if (!supports(row, data) ||
        row.date.isAfter(now) ||
        !(row.type == TransactionType.expense || row.type == TransactionType.income) ||
        row.destinationAccountId != null ||
        row.categoryId != null ||
        row.externalId != null ||
        row.reservedFundId != null ||
        row.reservedAmountMinor != null ||
        row.recurringMovementId != null ||
        row.duplicateState != 'none' ||
        source == null ||
        CorrectionAction.of(row) == desired) {
      return false;
    }
    final category = data.category(desired.categoryId);
    if (desired.categoryId != null && (category == null || category.isArchived)) return false;
    if (desired.type == row.type.name) {
      return desired.destinationId == null && category != null && categorySupports(category, row.type);
    }
    final destination = data.account(desired.destinationId);
    if (desired.type != TransactionType.transfer.name ||
        row.type != TransactionType.expense ||
        destination == null ||
        destination.id == source.id ||
        destination.type != AccountType.investment ||
        destination.isArchived ||
        destination.bankIdentityKey != null ||
        destination.currencyCode != source.currencyCode ||
        destination.openingDate.isAfter(row.date) ||
        (category != null && category.kind != CategoryKind.transfer)) {
      return false;
    }
    return !data.transactions.any((other) {
      if (other.id == row.id || other.amountMinor != row.amountMinor || other.date.difference(row.date).inSeconds.abs() > 7 * 86400) return false;
      if (other.type == TransactionType.income && other.sourceAccountId == destination.id) return true;
      return other.type == TransactionType.transfer && other.sourceAccountId == source.id && other.destinationAccountId == destination.id && other.bankEntryKey == null;
    });
  }

  List<CorrectionExample> _correctionExamples(Finances data) {
    final ordered = [...data.transactions]..sort((a, b) => a.date == b.date ? a.id.compareTo(b.id) : a.date.compareTo(b.date));
    final examples = <CorrectionExample>[];
    for (final row in ordered) {
      final signature = _signature(row, data);
      final action = CorrectionAction.of(row);
      final sample = [_corrections[row.id], _priorCorrections[row.id]].whereType<_HumanCorrection>().where((c) => c.signature == signature && c.example.action == action).firstOrNull;
      if (sample != null) examples.add(sample.example);
    }
    return examples.length > 700 ? examples.sublist(examples.length - 700) : examples;
  }

  String? _correctionKey;
  Future<CorrectionModel?>? _correctionJob;

  /// Repeats learnt corrections on new bank movements (Swift `applyLearnedCorrections`). The audit to undo
  /// each one is saved first; the returned operation changes the finances.
  Future<Operation?> learnedCorrections(Finances data, DateTime now, {Set<String>? only}) async {
    final since = enabledAt;
    if (!automationEnabled || since == null) return null;
    bool pendingAudit(Transaction row) {
      final audit = _automatic[row.id];
      return audit == null || audit.signature != _signature(row, data) || audit.after != CorrectionAction.of(row);
    }

    final candidates = data.transactions
        .where((row) =>
            (only?.contains(row.id) ?? true) &&
            !row.createdAt.isBefore(since) &&
            row.categoryId == null &&
            row.destinationAccountId == null &&
            !_corrections.containsKey(row.id) &&
            !_records.containsKey(row.id) &&
            !_reviewed.containsKey(row.id) &&
            pendingAudit(row) &&
            supports(row, data))
        .toList();
    if (candidates.isEmpty) return null;
    final examples = _correctionExamples(data);
    final key = sha256Hex(jsonEncode([for (final e in examples) e.toJson()]));
    if (_correctionJob == null || key != _correctionKey) {
      _correctionKey = key;
      _correctionJob = _trainCorrections(examples);
    }
    final model = await _correctionJob!;
    if (model == null || !automationEnabled) return null;
    final ops = <Operation>[];
    for (final row in candidates) {
      final value = input(row, data, terms: terms(row));
      final decision = value == null ? null : model.automaticDecision(value);
      if (decision == null || !canApply(decision.action, row, data, now)) continue;
      final action = decision.action;
      final type = TransactionType.values.byName(action.type);
      _automatic[row.id] = _Automatic(CorrectionAction.of(row), action, _signature(row, data, applying: action), row.fingerprint, decision.validatedPredictions);
      _touch('automatic', row.id);
      ops.add(Operation('patch', {
        'id': row.id,
        'fields': {
          'typeRaw': action.type,
          'destinationAccountID': action.destinationId,
          'categoryID': action.categoryId,
          'fingerprint': fingerprint(
              date: row.date, source: row.sourceAccountId, destination: action.destinationId, type: type, amountMinor: row.amountMinor, description: row.descriptionText),
          'updatedAt': referenceSeconds(now),
        }
      }));
    }
    if (ops.isEmpty) return null;
    // The audit is kept first: if the save fails, an inactive audit is harmless.
    await _save(invalidate: false);
    return batchOperation(ops);
  }

  /// Undoes an automatic correction and teaches the model that it was wrong (Swift `undoAutomaticCorrection`).
  Future<Operation?> undoAutomatic(Transaction row, Finances data, DateTime now) async {
    final audit = _automatic[row.id];
    if (audit == null ||
        audit.signature != _signature(row, data) ||
        audit.after != CorrectionAction.of(row) ||
        row.reservedFundId != null ||
        row.reservedAmountMinor != null ||
        row.recurringMovementId != null) {
      return null;
    }
    final before = captureEdit(row, data);
    if (before == null) return null;
    if (audit.before.destinationId != null && data.account(audit.before.destinationId) == null) return null;
    if (audit.before.categoryId != null && data.category(audit.before.categoryId) == null) return null;
    final restored = Transaction(
        id: row.id,
        date: row.date,
        type: TransactionType.values.byName(audit.before.type),
        amountMinor: row.amountMinor,
        descriptionText: row.descriptionText,
        sourceAccountId: row.sourceAccountId,
        destinationAccountId: audit.before.destinationId,
        categoryId: audit.before.categoryId,
        bankEntryKey: row.bankEntryKey,
        externalId: row.externalId,
        duplicateState: row.duplicateState,
        fingerprint: audit.fingerprint,
        createdAt: row.createdAt,
        updatedAt: now);
    await rememberEdit(before, restored, data, explicitlyReviewed: true);
    return Operation('patch', {
      'id': row.id,
      'fields': {
        'typeRaw': audit.before.type,
        'destinationAccountID': audit.before.destinationId,
        'categoryID': audit.before.categoryId,
        'fingerprint': audit.fingerprint,
        'updatedAt': referenceSeconds(now),
      }
    });
  }
}
