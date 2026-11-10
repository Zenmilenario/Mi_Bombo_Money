// How amounts and bank concepts are shown, as in the iPhone app (`TransactionPresentation.swift`).
// Presentation only: stored texts are never changed.
import 'package:intl/intl.dart';

final _money = NumberFormat.currency(locale: 'es_ES', symbol: '€', decimalDigits: 2);

/// 123456 → "1.234,56 €". `signed` adds "+" to positive amounts.
String money(int minor, {bool signed = false}) {
  final text = _money.format(minor / 100);
  return signed && minor > 0 ? '+$text' : text;
}

final _envelope = RegExp(r'^/TXT/[DH]\|', caseSensitive: false);
final _transfer = RegExp(r'^(?:TRANS\s+INM\.?|TRANSFERENCIA(?:\s+(?:INMEDIATA|EMITIDA|RECIBIDA))?)(?:\s*[/|:\-]\s*|\s+|$)', caseSensitive: false);
final _immediate = RegExp(r'\b(?:INM|INMEDIAT[AO])\b', caseSensitive: false);
final _cardPayment = RegExp(r'^PAGO CON TARJETA(?: DE SERVICIOS VARIOS)?$', caseSensitive: false);

String _bankBody(String original) {
  final text = original.trim();
  final envelope = _envelope.firstMatch(text);
  if (envelope == null) return original;
  final body = text.substring(envelope.end).replaceAll(RegExp(r'\s+'), ' ').trim();
  return body.isEmpty ? original : body;
}

String bankTitle(String original, {required bool isBanking}) {
  if (!isBanking) return original;
  final text = _bankBody(original);
  final marker = _transfer.firstMatch(text);
  if (marker != null) {
    final detail = text.substring(marker.end).trim();
    final label = _immediate.hasMatch(text.substring(marker.start, marker.end)) ? 'Transferencia inmediata' : 'Transferencia';
    return detail.isEmpty ? label : '$label · $detail';
  }
  final segments = text.split('//').map((s) => s.trim()).toList();
  if (segments.length > 1 && segments.last.isNotEmpty && segments.sublist(0, segments.length - 1).every(_cardPayment.hasMatch)) {
    return segments.last;
  }
  return text;
}

/// Pending card postings arrive as "/TXT/MERCHANT DD/MM/YY|REFERENCE".
String _stripBankNoise(String text) {
  var value = text.trim();
  value = value.replaceFirst(RegExp(r'^/TXT/(?![A-Z]\|)', caseSensitive: false), '');
  value = value.replaceFirst(RegExp(r'\|\d{6,}$'), '');
  value = value.replaceFirst(RegExp(r'\s*\d{2}/\d{2}/\d{2,4}$'), '');
  value = value.trim();
  return value.isEmpty ? text : value;
}

const _connectors = {'de', 'del', 'la', 'las', 'el', 'los', 'y', 'e', 'en', 'a', 'al', 'con', 'por', 'para'};
final _abbreviation = RegExp(r'^(?:[A-ZÑ]\.){1,3}[A-ZÑ]?\.?,?$');

/// "COMERCIO DEL NORTE, S.L." → "Comercio del Norte, S.L.". Mixed case, codes and abbreviations stay.
String readableCase(String text) {
  final letters = text.runes.where((r) => String.fromCharCode(r).toLowerCase() != String.fromCharCode(r).toUpperCase()).length;
  if (letters < 4 || text != text.toUpperCase() || text == text.toLowerCase()) return text;
  var isFirst = true;
  return text.split(' ').map((word) {
    if (word.isEmpty) return word;
    final first = isFirst;
    isFirst = false;
    if (word.contains(RegExp(r'\d'))) return word;
    if (_abbreviation.hasMatch(word)) return word;
    final lower = word.toLowerCase();
    if (!first && _connectors.contains(lower)) return lower;
    final index = lower.indexOf(RegExp(r'[a-záéíóúüñ]'));
    if (index < 0) return lower;
    return lower.substring(0, index) + lower[index].toUpperCase() + lower.substring(index + 1);
  }).join(' ');
}

/// Title for lists: names common bank operations and makes all-capital concepts readable.
String listTitle(String original, {required bool isBanking}) {
  final base = bankTitle(isBanking ? _stripBankNoise(original) : original, isBanking: isBanking);
  if (!isBanking) return base;
  final segments = base.split('//').map((s) => s.trim()).where((s) => s.isNotEmpty).toList();
  var text = base;
  if (segments.length > 1) {
    final head = segments.first.toUpperCase();
    if (head.startsWith('RET. EFECTIVO') || head.startsWith('RETIRADA') || head.contains('CAJERO')) {
      text = 'Retirada de efectivo';
    } else if (head.startsWith('ADEUDO') || head.startsWith('RECIBO')) {
      final name = segments.last.replaceFirst(RegExp(r'^N\s*\d+\s+'), '');
      return 'Recibo · ${readableCase(name)}';
    }
  }
  return readableCase(text);
}

/// A daily quote on the sign-in screen, the same idea as on the iPhone: curiosities, never advice.
const dailyQuotes = [
  'El doblón fue una moneda de oro española que circuló durante siglos por medio mundo.',
  'La palabra «salario» viene de la sal con la que se pagaba en la antigua Roma.',
  'Los primeros billetes de Europa se imprimieron en Suecia en 1661.',
  'El símbolo del euro se inspira en la letra griega épsilon.',
  'La hucha con forma de cerdito se popularizó en Europa en el siglo XIX.',
  'La moneda más antigua conocida se acuñó en Lidia, en la actual Turquía.',
  'En la Edad Media se usaba el ábaco para cuadrar las cuentas de los mercaderes.',
];

String quoteOfTheDay([DateTime? day]) {
  final date = day ?? DateTime.now();
  final ordinal = DateTime.utc(date.year, date.month, date.day).difference(DateTime.utc(2026)).inDays;
  return dailyQuotes[ordinal % dailyQuotes.length];
}
