// How amounts and bank concepts are shown, as in the iPhone app (`TransactionPresentation.swift`).
// Presentation only: stored texts are never changed.
import 'package:flutter/widgets.dart' show IconData;
import 'package:flutter/material.dart' show Icons;
import 'package:intl/intl.dart';

final _formats = <String, NumberFormat>{};

/// 123456 → "1.234,56 €". `currency` is the account's ISO code: a USD account shows dollars, not euros.
/// Totals that add several accounts (net worth, available) are shown in euros, as on the iPhone.
/// `signed` adds "+" to positive amounts.
/// When true (Ajustes › Ocultar importes), every amount is shown as dots.
bool amountsHidden = false;

/// The icons a category can have, by the SF Symbol name the iPhone app stores (so both apps show the same one).
const categorySymbols = [
  'basket.fill', 'cart.fill', 'fork.knife', 'cup.and.saucer.fill', 'car.fill', 'fuelpump.fill', 'tram.fill', 'airplane', //
  'house.fill', 'bolt.fill', 'wifi', 'phone.fill', 'cross.case.fill', 'pills.fill', 'tshirt.fill', 'bag.fill', //
  'gift.fill', 'gamecontroller.fill', 'film.fill', 'book.fill', 'graduationcap.fill', 'pawprint.fill', 'heart.fill', 'shield.fill', //
  'repeat', 'percent', 'creditcard.fill', 'banknote.fill', 'eurosign.circle.fill', 'chart.line.uptrend.xyaxis', 'chart.bar.fill', //
  'building.columns.fill', 'arrow.down.circle.fill', 'arrow.uturn.backward.circle.fill', 'arrow.left.arrow.right.circle.fill', //
  'ellipsis.circle.fill', 'tag.fill',
];

/// The Material icon closest to an SF Symbol of the iPhone app (the category icons it created). Unknown → a tag.
IconData symbolIcon(String? symbol) {
  final name = (symbol ?? '').replaceAll('.fill', '').replaceAll('.circle', '');
  return switch (name) {
    'airplane' => Icons.flight,
    'arrow.down' => Icons.south_west,
    'arrow.left.arrow.right' => Icons.swap_horiz,
    'arrow.uturn.backward' => Icons.undo,
    'bag' => Icons.shopping_bag,
    'banknote' => Icons.payments,
    'basket' => Icons.shopping_basket,
    'bolt' => Icons.bolt,
    'car' => Icons.directions_car,
    'chart.bar' => Icons.bar_chart,
    'chart.line.uptrend.xyaxis' => Icons.trending_up,
    'cross.case' => Icons.medical_services,
    'ellipsis' => Icons.more_horiz,
    'eurosign' => Icons.euro,
    'fork.knife' => Icons.restaurant,
    'gamecontroller' => Icons.sports_esports,
    'gift' => Icons.card_giftcard,
    'graduationcap' => Icons.school,
    'house' => Icons.home,
    'pawprint' => Icons.pets,
    'percent' => Icons.percent,
    'pills' => Icons.medication,
    'repeat' => Icons.repeat,
    'shield' => Icons.shield,
    'tram' => Icons.tram,
    'tshirt' => Icons.checkroom,
    'wifi' => Icons.wifi,
    'creditcard' => Icons.credit_card,
    'cart' => Icons.shopping_cart,
    'heart' => Icons.favorite,
    'film' => Icons.movie,
    'book' => Icons.menu_book,
    'phone' => Icons.phone,
    'fuelpump' => Icons.local_gas_station,
    'cup.and.saucer' => Icons.local_cafe,
    'building.columns' => Icons.account_balance,
    _ => Icons.sell,
  };
}

String money(int minor, {bool signed = false, String currency = 'EUR'}) {
  if (amountsHidden) return '•••••';
  final format = _formats[currency] ??= NumberFormat.simpleCurrency(locale: 'es_ES', name: currency, decimalDigits: 2);
  final text = format.format(minor / 100);
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
