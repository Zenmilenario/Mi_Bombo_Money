// Card payments recorded at the till with the Shortcuts action of the iPhone (ios/Runner/AppDelegate.swift), the
// same as the Swift app (`CardPaymentIntents.swift`, `CardPaymentInbox`). The action writes each payment to this
// device's inbox; the app files it as an expense waiting for the bank, marked `applepay:`, and the bank import
// pairs it with the bank's movement (`importFeeds`) instead of adding it twice.
import 'dart:convert';
import 'dart:io';

import 'package:flutter/services.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'automation.dart' show matchRule;
import 'banking.dart' show referenceSeconds;
import 'data.dart';
import 'edits.dart';
import 'models.dart';

const cardPaymentMarker = 'applepay:';

class CardPayment {
  CardPayment({required this.id, required this.date, required this.amountMinor, required this.merchant, required this.card});
  final String id;
  final DateTime date;
  final int amountMinor;
  final String merchant;
  final String card;

  static CardPayment? tryParse(String raw) {
    try {
      final json = jsonDecode(raw) as Map<String, dynamic>;
      final id = '${json['id']}'.toLowerCase();
      final when = json['date'];
      // The Swift app (same identifier, same inbox) writes seconds since 1 January 2001; this app writes ISO 8601.
      final date = when is num
          ? DateTime.fromMillisecondsSinceEpoch(((when + 978307200) * 1000).round(), isUtc: true)
          : DateTime.tryParse('$when');
      final amount = (json['amountMinor'] as num?)?.toInt();
      if (!RegExp(r'^[0-9a-f-]{36}$').hasMatch(id) || date == null || amount == null || amount <= 0) return null;
      return CardPayment(id: id, date: date, amountMinor: amount, merchant: '${json['merchant'] ?? ''}'.trim(), card: '${json['card'] ?? ''}'.trim());
    } catch (_) {
      return null;
    }
  }
}

String normalizedCard(String card) => card.trim().toLowerCase();

/// The payments that can be filed now, as one operation, and the ids that may leave the inbox. A payment whose card
/// has no account (and there is no default one) stays in the inbox; one filed on an earlier opening only leaves it.
({Operation? operation, Set<String> filed}) fileCardPayments(List<CardPayment> payments, Finances data,
    {required Map<String, String> cardAccounts, String? defaultAccount, required DateTime now}) {
  final active = {for (final a in data.accounts) if (!a.isArchived) a.id.toLowerCase(): a};
  final existing = {for (final t in data.transactions) t.id.toLowerCase()};
  final records = <Map<String, dynamic>>[];
  final filed = <String>{};
  for (final payment in payments) {
    final accountId = cardAccounts[normalizedCard(payment.card)] ?? defaultAccount;
    final account = accountId == null ? null : active[accountId.toLowerCase()];
    if (account == null) continue;
    filed.add(payment.id);
    if (existing.contains(payment.id)) continue;
    final text = payment.merchant.isEmpty ? 'Pago con tarjeta' : payment.merchant;
    records.add({
      'id': payment.id,
      'date': referenceSeconds(payment.date),
      'typeRaw': TransactionType.expense.name,
      'amountMinor': payment.amountMinor,
      'descriptionText': text,
      'notes': payment.card.isEmpty ? 'Apuntado al pagar.' : 'Apuntado al pagar con ${payment.card}.',
      'isReconciled': false,
      'fingerprint': fingerprint(
          date: payment.date, source: account.id, destination: null, type: TransactionType.expense, amountMinor: payment.amountMinor, description: text),
      'duplicateStateRaw': 'none',
      'externalID': '$cardPaymentMarker${payment.id}',
      'importBatchID': null,
      'recurringMovementID': null,
      'reservedFundID': null,
      'reservedAmountMinor': null,
      'createdAt': referenceSeconds(now),
      'updatedAt': referenceSeconds(now),
      'sourceAccountID': account.id,
      'destinationAccountID': null,
      'categoryID': matchRule(text, TransactionType.expense, data)?.id,
      'bankEntryKey': null,
    });
  }
  final operation = records.isEmpty
      ? null
      : Operation('batch', {
          'ops': [
            for (final record in records) Operation('insert', {'record': record}).toJson()
          ]
        });
  return (operation: operation, filed: filed);
}

/// The inbox the Shortcuts action writes to, and which account each card goes to on this device.
class CardPaymentInbox {
  static const _channel = MethodChannel('doblon/card_payments');
  static const _defaultKey = 'cardPaymentDefaultAccount', _cardsKey = 'cardPaymentAccountsV1', _seenKey = 'cardPaymentSeenCardsV1';

  /// Only the iPhone has the Shortcuts action.
  static bool get available => Platform.isIOS;

  static Future<List<CardPayment>> pending() async {
    if (!available) return const [];
    try {
      final raw = await _channel.invokeListMethod<String>('pending') ?? const [];
      return [for (final item in raw) CardPayment.tryParse(item)].whereType<CardPayment>().toList();
    } on MissingPluginException {
      return const [];
    } on PlatformException {
      return const [];
    }
  }

  static Future<void> remove(Set<String> ids) async {
    if (!available || ids.isEmpty) return;
    await _channel.invokeMethod<void>('remove', ids.toList());
  }

  static Future<({String? defaultAccount, Map<String, String> cards, List<String> seen})> settings() async {
    final prefs = await SharedPreferences.getInstance();
    Map<String, String> cards = {};
    try {
      cards = Map<String, String>.from(jsonDecode(prefs.getString(_cardsKey) ?? '{}') as Map);
    } catch (_) {}
    return (defaultAccount: prefs.getString(_defaultKey), cards: cards, seen: prefs.getStringList(_seenKey) ?? const <String>[]);
  }

  static Future<void> setDefaultAccount(String? id) async {
    final prefs = await SharedPreferences.getInstance();
    id == null ? await prefs.remove(_defaultKey) : await prefs.setString(_defaultKey, id);
  }

  static Future<void> setCardAccount(String card, String? id) async {
    final prefs = await SharedPreferences.getInstance();
    final cards = (await settings()).cards;
    id == null ? cards.remove(normalizedCard(card)) : cards[normalizedCard(card)] = id;
    await prefs.setString(_cardsKey, jsonEncode(cards));
  }

  /// Card names seen in payments, so each one can be given an account (the last twelve).
  static Future<void> rememberCards(Iterable<String> names) async {
    final prefs = await SharedPreferences.getInstance();
    final seen = [...prefs.getStringList(_seenKey) ?? const <String>[]];
    for (final name in names.map((n) => n.trim()).where((n) => n.isNotEmpty)) {
      if (!seen.any((s) => normalizedCard(s) == normalizedCard(name))) seen.add(name);
    }
    await prefs.setStringList(_seenKey, seen.length > 12 ? seen.sublist(seen.length - 12) : seen);
  }

  /// Files what the action recorded since the last opening. The operation is saved on this device before the
  /// payments leave the inbox, so none is lost without connection. Returns how many were filed.
  static Future<int> file(FinanceRepository repository) async {
    final payments = await pending();
    final data = repository.finances;
    if (payments.isEmpty || data == null) return 0;
    await rememberCards(payments.map((p) => p.card));
    final choice = await settings();
    final result = fileCardPayments(payments, data, cardAccounts: choice.cards, defaultAccount: choice.defaultAccount, now: DateTime.now());
    if (result.operation case final operation?) await repository.apply(operation);
    // Only what is already among the movements leaves the inbox: if the change could not be kept, nothing is lost.
    final present = {for (final t in repository.finances?.transactions ?? const <Transaction>[]) t.id.toLowerCase()};
    final done = result.filed.where(present.contains).toSet();
    await remove(done);
    return done.length;
  }
}
