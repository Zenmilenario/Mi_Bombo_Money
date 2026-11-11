// Bank statement import, with the iPhone's rules (`CSVImportService.swift`): delimiter detection, quoted
// fields, Spanish and English headers, several date formats and signed amounts.
import 'dart:convert';

import 'banking.dart' show referenceSeconds;
import 'edits.dart';
import 'models.dart';
import 'screens/transaction_form.dart' show parseAmount;

class CsvDraft {
  CsvDraft(
      {required this.row,
      required this.date,
      required this.type,
      required this.signedAmountMinor,
      required this.description,
      this.accountName,
      this.destinationName,
      this.categoryName,
      this.notes = '',
      this.isReconciled = false,
      this.externalId});
  final int row;
  final DateTime date;
  final TransactionType type;
  final int signedAmountMinor;
  final String description;
  final String? accountName;
  final String? destinationName;
  final String? categoryName;
  final String notes;
  final bool isReconciled;
  final String? externalId;
  int get amountMinor => signedAmountMinor.abs();
}

class CsvResult {
  CsvResult(this.drafts, this.warnings);
  final List<CsvDraft> drafts;
  final List<String> warnings;
}

class CsvError implements Exception {
  CsvError(this.message);
  final String message;
  @override
  String toString() => message;
}

/// UTF-8 first; Latin-1 (Windows exports) otherwise.
String decodeCsv(List<int> bytes) {
  try {
    return utf8.decode(bytes);
  } catch (_) {
    return latin1.decode(bytes);
  }
}

String _header(String value) {
  const folding = {'á': 'a', 'é': 'e', 'í': 'i', 'ó': 'o', 'ú': 'u', 'ü': 'u', 'ñ': 'n'};
  return value.trim().toLowerCase().split('').map((c) => folding[c] ?? c).join().replaceAll(RegExp(r'[^a-z0-9]+'), '');
}

String _delimiter(String text) {
  final first = text.split(RegExp(r'\r?\n')).firstWhere((l) => l.trim().isNotEmpty, orElse: () => text);
  int count(String d) {
    var quoted = false, n = 0;
    for (final c in first.split('')) {
      if (c == '"') quoted = !quoted;
      if (c == d && !quoted) n++;
    }
    return n;
  }

  return [';', ',', '\t'].reduce((a, b) => count(b) > count(a) ? b : a);
}

List<List<String>> _rows(String text, String delimiter) {
  final rows = <List<String>>[];
  var row = <String>[];
  final field = StringBuffer();
  var quoted = false;
  for (var i = 0; i < text.length; i++) {
    final c = text[i];
    if (c == '"') {
      if (quoted && i + 1 < text.length && text[i + 1] == '"') {
        field.write('"');
        i++;
      } else {
        quoted = !quoted;
      }
    } else if (c == delimiter && !quoted) {
      row.add(field.toString());
      field.clear();
    } else if ((c == '\n' || c == '\r') && !quoted) {
      if (c == '\r' && i + 1 < text.length && text[i + 1] == '\n') i++;
      row.add(field.toString());
      field.clear();
      rows.add(row);
      row = [];
    } else {
      field.write(c);
    }
  }
  if (field.isNotEmpty || row.isNotEmpty) {
    row.add(field.toString());
    rows.add(row);
  }
  return rows.where((r) => r.any((f) => f.trim().isNotEmpty)).toList();
}

DateTime? parseCsvDate(String raw) {
  final text = raw.trim();
  final iso = RegExp(r'^(\d{4})[-/](\d{1,2})[-/](\d{1,2})').firstMatch(text);
  if (iso != null) return _valid(int.parse(iso[1]!), int.parse(iso[2]!), int.parse(iso[3]!));
  final dmy = RegExp(r'^(\d{1,2})[/.\-](\d{1,2})[/.\-](\d{2,4})$').firstMatch(text);
  if (dmy != null) {
    var year = int.parse(dmy[3]!);
    if (year < 100) year += 2000;
    final first = int.parse(dmy[1]!), second = int.parse(dmy[2]!);
    // Day first (Spanish); month first only when the day-first reading is impossible (e.g. 12/31/2026).
    return _valid(year, second, first) ?? _valid(year, first, second);
  }
  return null;
}

DateTime? _valid(int year, int month, int day) {
  if (month < 1 || month > 12 || day < 1 || day > 31) return null;
  final date = DateTime(year, month, day, 12);
  return date.month == month && date.day == day ? date : null;
}

TransactionType _type(String? raw, int signed) {
  if (raw == null) return signed < 0 ? TransactionType.expense : TransactionType.income;
  final v = _header(raw);
  if (v.contains('transfer') || v.contains('traspas')) return TransactionType.transfer;
  if (v.contains('interes') || v.contains('interest')) return TransactionType.interest;
  if (v.contains('comision') || v.contains('fee')) return TransactionType.fee;
  if (v.contains('gasto') || v.contains('expense') || v.contains('cargo')) return TransactionType.expense;
  if (v.contains('ingreso') || v.contains('income') || v.contains('abono')) return TransactionType.income;
  return signed < 0 ? TransactionType.expense : TransactionType.income;
}

/// Reads "-12,50", "1.234,56", "(45,00)" and "12.50 €" with their sign.
int? signedAmount(String raw) {
  var text = raw.trim();
  var negative = text.startsWith('-') || (text.startsWith('(') && text.endsWith(')'));
  text = text.replaceAll(RegExp(r'[()+\-]'), '');
  if (text.endsWith('-')) negative = true;
  final value = parseAmount(text.replaceAll('EUR', '').replaceAll(' ', ''));
  if (value == null) return null;
  return negative ? -value : value;
}

CsvResult parseCsv(String text) {
  if (text.trim().isEmpty) throw CsvError('El archivo está vacío.');
  final rows = _rows(text.replaceFirst('﻿', ''), _delimiter(text));
  if (rows.isEmpty) throw CsvError('No se ha encontrado una fila de cabeceras.');
  final headers = rows.first.map(_header).toList();
  int? find(List<String> aliases) {
    final index = headers.indexWhere(aliases.contains);
    return index < 0 ? null : index;
  }

  final date = find(['fecha', 'fechaoperacion', 'fechavalor', 'date', 'bookingdate']);
  final type = find(['tipo', 'tipomovimiento', 'type', 'movementtype']);
  final account = find(['cuenta', 'cuentaorigen', 'cuentaafectada', 'account', 'sourceaccount']);
  final destination = find(['cuentadestino', 'destinationaccount', 'targetaccount']);
  final category = find(['categoria', 'category']);
  final description = find(['descripcion', 'concepto', 'detalle', 'movimiento', 'description', 'merchant', 'payee']);
  final amount = find(['importe', 'cantidad', 'amount', 'monto', 'valor']);
  final reconciled = find(['conciliado', 'reconciled', 'validado']);
  final notes = find(['notas', 'observaciones', 'notes', 'memo']);
  final external = find(['id', 'idmovimiento', 'transactionid', 'idexterno', 'referencia', 'reference']);
  final missing = [if (date == null) 'fecha', if (amount == null) 'importe', if (description == null) 'descripción/concepto'];
  if (missing.isNotEmpty) throw CsvError('Faltan columnas obligatorias: ${missing.join(', ')}.');

  String? at(int? index, List<String> row) {
    if (index == null || index >= row.length) return null;
    final value = row[index].trim();
    return value.isEmpty ? null : value;
  }

  final drafts = <CsvDraft>[];
  final warnings = <String>[];
  for (var i = 1; i < rows.length; i++) {
    final row = rows[i];
    final number = i + 1;
    final parsedDate = at(date, row) == null ? null : parseCsvDate(at(date, row)!);
    if (parsedDate == null) {
      warnings.add('Fila $number: fecha no reconocida.');
      continue;
    }
    final value = at(amount, row) == null ? null : signedAmount(at(amount, row)!);
    if (value == null || value == 0) {
      warnings.add('Fila $number: importe no válido o igual a cero.');
      continue;
    }
    drafts.add(CsvDraft(
      row: number,
      date: parsedDate,
      type: _type(at(type, row), value),
      signedAmountMinor: value,
      description: at(description, row) ?? 'Movimiento importado',
      accountName: at(account, row),
      destinationName: at(destination, row),
      categoryName: at(category, row),
      notes: at(notes, row) ?? '',
      isReconciled: ['si', 'yes', 'true', '1', 'conciliado'].contains(_header(at(reconciled, row) ?? '')),
      externalId: at(external, row),
    ));
  }
  if (drafts.isEmpty) throw CsvError('No se ha encontrado ninguna fila válida para importar.');
  return CsvResult(drafts, warnings);
}

class CsvPlanItem {
  CsvPlanItem(this.draft, this.accountId, this.destinationId, this.categoryId, this.status);
  final CsvDraft draft;
  final String? accountId;
  final String? destinationId;
  final String? categoryId;

  /// new, duplicate (already stored, skipped), possible (imported marked as possible duplicate), invalid.
  final String status;
}

/// Decides, row by row, the accounts, category and whether it is already stored, before importing.
List<CsvPlanItem> planCsv(CsvResult parsed, Finances data, String defaultAccountId) {
  String? accountByName(String? name) {
    if (name == null) return null;
    final n = name.toLowerCase().trim();
    return data.accounts.where((a) => !a.isArchived && a.name.toLowerCase().trim() == n).firstOrNull?.id;
  }

  final fingerprints = {for (final t in data.transactions) t.id: t.fingerprint};
  final items = <CsvPlanItem>[];
  for (final d in parsed.drafts) {
    final account = accountByName(d.accountName) ?? defaultAccountId;
    final destination = d.type == TransactionType.transfer ? accountByName(d.destinationName) : null;
    final named = d.categoryName == null ? null : data.categories.where((c) => c.name.toLowerCase() == d.categoryName!.toLowerCase()).firstOrNull;
    final category = (named != null && categorySupports(named, d.type)) ? named : null;
    if (d.type == TransactionType.transfer && (destination == null || destination == account)) {
      items.add(CsvPlanItem(d, account, null, null, 'invalid'));
      continue;
    }
    final exact = d.externalId != null && data.transactions.any((t) => t.externalId == d.externalId && t.sourceAccountId == account);
    final print = fingerprint(date: d.date, source: account, destination: destination, type: d.type, amountMinor: d.amountMinor, description: d.description);
    final sameFingerprint = data.transactions.any((t) => t.fingerprint == print);
    if (exact || sameFingerprint) {
      items.add(CsvPlanItem(d, account, destination, category?.id, 'duplicate'));
      continue;
    }
    final candidates = duplicateCandidates(
        date: d.date,
        source: account,
        destination: destination,
        type: d.type,
        amountMinor: d.amountMinor,
        description: d.description,
        existing: data.transactions,
        fingerprints: fingerprints);
    items.add(CsvPlanItem(d, account, destination, category?.id, candidates.isEmpty ? 'new' : 'possible'));
  }
  return items;
}

/// The operation that imports the planned rows (duplicates and invalid rows are left out).
Operation importCsvOperation(List<CsvPlanItem> items, DateTime now, String Function() newId) {
  final ops = <Operation>[];
  for (final item in items.where((i) => i.status == 'new' || i.status == 'possible')) {
    final d = item.draft;
    ops.add(Operation('insert', {
      'record': {
        'id': newId(),
        'date': referenceSeconds(d.date),
        'typeRaw': d.type.name,
        'amountMinor': d.amountMinor,
        'descriptionText': d.description,
        'notes': d.notes,
        'isReconciled': d.isReconciled,
        'fingerprint': fingerprint(
            date: d.date, source: item.accountId, destination: item.destinationId, type: d.type, amountMinor: d.amountMinor, description: d.description),
        'duplicateStateRaw': item.status == 'possible' ? 'possible' : 'none',
        'externalID': d.externalId,
        'importBatchID': null,
        'recurringMovementID': null,
        'reservedFundID': null,
        'reservedAmountMinor': null,
        'createdAt': referenceSeconds(now),
        'updatedAt': referenceSeconds(now),
        'sourceAccountID': item.accountId,
        'destinationAccountID': item.destinationId,
        'categoryID': item.categoryId,
        'bankEntryKey': null,
      }
    }));
  }
  return batchOperation(ops);
}

/// CSV export with the iPhone's columns (semicolon separated, decimal comma).
String exportCsv(List<Transaction> transactions, Finances data) {
  String escape(String value) => value.contains(RegExp(r'[;"\n]')) ? '"${value.replaceAll('"', '""')}"' : value;
  final lines = ['Fecha;Tipo;Importe;Cuenta origen;Cuenta destino;Categoría;Concepto;Notas;Conciliado;ID externo'];
  for (final t in transactions) {
    final amount = '${t.amountMinor ~/ 100},${(t.amountMinor % 100).toString().padLeft(2, '0')}';
    lines.add([
      t.date.toUtc().toIso8601String().substring(0, 10),
      t.type.title,
      amount,
      escape(data.account(t.sourceAccountId)?.name ?? ''),
      escape(data.account(t.destinationAccountId)?.name ?? ''),
      escape(data.category(t.categoryId)?.name ?? ''),
      escape(t.descriptionText),
      escape(t.notes),
      t.isReconciled ? 'Sí' : 'No',
      escape(t.externalId ?? ''),
    ].join(';'));
  }
  return lines.join('\n');
}
