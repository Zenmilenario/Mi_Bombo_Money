// Automatic categories of bank movements (26 November 2026). Before this, imported movements were only proposed a
// category (Por revisar › «Aplicar las propuestas de la IA»); nothing assigned one on its own, so they stayed «Sin
// categoría». Now a category is assigned only with evidence that is the person's own, in this order:
//   1. One of their category rules (explicit).
//   2. Their own history: the same concept categorised by them at least twice, always with the same category.
// This is not the machine-learning model: it is a rule and a count of the person's decisions. The model's guesses
// stay as proposals to review. A category already chosen is never overwritten; a movement without a useful concept
// («Movimiento bancario», only amount and date) gets nothing. Each assignment keeps where it came from, so it can be
// explained and taken back; a category taken back is not assigned again.
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';

import 'automation.dart' show matchRule;
import 'edits.dart' show normalizeText;
import 'models.dart';
import 'presentation.dart' show listTitle;

class AutoCategory {
  AutoCategory({required this.transactionId, required this.categoryId, required this.source, required this.detail});
  final String transactionId, categoryId;

  /// `rule` or `history`.
  final String source;

  /// In words, for the movement's detail: «una regla tuya («iberdulce»)», «3 movimientos tuyos «Iberdulce Pc»».
  final String detail;

  Map<String, dynamic> toJson() => {'categoryId': categoryId, 'source': source, 'detail': detail};
}

/// Bank texts that say nothing about what was bought.
const _generic = {'movimiento bancario', 'movimiento', 'transferencia', 'transferencias', 'compra', 'pago', 'cargo', 'abono', 'ingreso', 'recibo'};

/// The concept a person recognises, normalised: what history is grouped by.
String conceptKey(Transaction t) => normalizeText(listTitle(t.descriptionText, isBanking: t.isBanking));

bool usefulConcept(Transaction t) {
  final key = conceptKey(t);
  return key.length >= 3 && !_generic.contains(key) && RegExp('[a-z]').hasMatch(key);
}

/// The categories that can be assigned now, with their evidence. [automatic] are earlier automatic assignments (not
/// counted as the person's decisions); [rejected] were taken back by the person.
List<AutoCategory> autoCategories(Finances data, {Set<String> automatic = const {}, Set<String> rejected = const {}}) {
  final history = <String, Map<String, int>>{};
  for (final t in data.transactions) {
    if (t.categoryId == null || automatic.contains(t.id) || !(t.type.countsAsExpense || t.type.countsAsIncome) || !usefulConcept(t)) continue;
    final counts = history['${t.type.countsAsIncome}|${conceptKey(t)}'] ??= {};
    counts[t.categoryId!] = (counts[t.categoryId!] ?? 0) + 1;
  }
  final result = <AutoCategory>[];
  for (final t in data.transactions) {
    if (t.categoryId != null || !t.isBanking || rejected.contains(t.id) || !(t.type.countsAsExpense || t.type.countsAsIncome)) continue;
    if (t.isLoanDisbursement || t.isInvestmentFee || t.installmentPlanId != null || !usefulConcept(t)) continue;
    final rule = matchRule(t.descriptionText, t.type, data) ?? matchRule(listTitle(t.descriptionText, isBanking: true), t.type, data);
    if (rule != null) {
      result.add(AutoCategory(transactionId: t.id, categoryId: rule.id, source: 'rule', detail: 'una regla tuya'));
      continue;
    }
    final counts = history['${t.type.countsAsIncome}|${conceptKey(t)}'];
    if (counts != null && counts.length == 1 && counts.values.single >= 2) {
      final category = data.category(counts.keys.single);
      if (category == null || category.isArchived) continue;
      result.add(AutoCategory(
          transactionId: t.id,
          categoryId: category.id,
          source: 'history',
          detail: '${counts.values.single} movimientos tuyos «${listTitle(t.descriptionText, isBanking: true)}» en ${category.name}'));
    }
  }
  return result;
}

/// Where each automatic category came from, on this device (per person), and the ones taken back.
class AutoCategoryStore {
  AutoCategoryStore._();
  static final instance = AutoCategoryStore._();
  String _user = '';
  Map<String, Map<String, dynamic>> entries = {};
  Set<String> rejected = {};

  /// Whether the record could be read: without it nothing is assigned (a rejected one could come back).
  bool loaded = false;

  /// Never stops the finances from loading: without the record, automatic categories just wait.
  Future<void> load(String user) async {
    _user = user;
    loaded = false;
    try {
      final prefs = await SharedPreferences.getInstance();
      final raw = jsonDecode(prefs.getString('autoCategories:$user') ?? '{}') as Map;
      entries = {for (final e in raw.entries) '${e.key}': Map<String, dynamic>.from(e.value as Map)};
      rejected = (prefs.getStringList('autoCategoriesRejected:$user') ?? const []).toSet();
      loaded = true;
    } catch (_) {
      entries = {};
      rejected = {};
    }
  }

  Future<void> _save() async {
    try {
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('autoCategories:$_user', jsonEncode(entries));
      await prefs.setStringList('autoCategoriesRejected:$_user', rejected.toList());
    } catch (_) {}
  }

  Future<void> remember(List<AutoCategory> assigned, DateTime at) async {
    for (final a in assigned) {
      entries[a.transactionId] = {...a.toJson(), 'at': at.millisecondsSinceEpoch};
    }
    await _save();
  }

  /// The person took it back: it is not assigned again.
  Future<void> reject(String transactionId) async {
    entries.remove(transactionId);
    rejected.add(transactionId);
    await _save();
  }

  /// The automatic assignment still in place for [t], if any (a category the person changed is theirs).
  Map<String, dynamic>? current(Transaction t) {
    final e = entries[t.id];
    return e != null && e['categoryId'] == t.categoryId ? e : null;
  }
}
