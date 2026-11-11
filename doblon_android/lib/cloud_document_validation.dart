import 'finance.dart';
import 'models.dart';

/// The server cannot inspect ciphertext. Check the graph and reserved-money ledger on the device
/// before publishing an encrypted snapshot and before accepting one from another device.
void validatePrivateDocument(Map<String, dynamic> doc, String kind) {
  if (kind == 'learning') {
    if (doc['version'] != 1) {
      throw const FormatException('Aprendizaje incompatible.');
    }
    return;
  }
  const entities = [
    'institutions',
    'accounts',
    'categories',
    'cards',
    'reservedFunds',
    'categoryRules',
    'recurringBudgets',
    'budgets',
    'goals',
    'recurringMovements',
    'importBatches',
    'snapshots',
    'transactions'
  ];
  if (doc['formatVersion'] != 2) {
    throw const FormatException('Finanzas incompatibles.');
  }
  final maps = <String, Map<String, Map<String, dynamic>>>{};
  for (final entity in entities) {
    final rows = doc[entity];
    if (rows is! List) throw FormatException('Falta $entity.');
    final indexed = <String, Map<String, dynamic>>{};
    for (final row in rows) {
      if (row is! Map || row['id'] is! String) {
        throw FormatException('Identidad no válida en $entity.');
      }
      final id = (row['id'] as String).toLowerCase();
      if (indexed.containsKey(id)) {
        throw FormatException('Registro repetido en $entity.');
      }
      indexed[id] = Map<String, dynamic>.from(row);
    }
    maps[entity] = indexed;
  }
  const relations = {
    'accounts': {'institutionID': 'institutions'},
    'cards': {'institutionID': 'institutions', 'linkedAccountID': 'accounts'},
    'reservedFunds': {'accountID': 'accounts'},
    'categoryRules': {'categoryID': 'categories'},
    'budgets': {'categoryID': 'categories'},
    'recurringBudgets': {'categoryID': 'categories'},
    'goals': {'linkedAccountID': 'accounts'},
    'recurringMovements': {
      'sourceAccountID': 'accounts',
      'destinationAccountID': 'accounts',
      'categoryID': 'categories'
    },
    'snapshots': {'accountID': 'accounts'},
    'transactions': {
      'sourceAccountID': 'accounts',
      'destinationAccountID': 'accounts',
      'categoryID': 'categories',
      'reservedFundID': 'reservedFunds'
    },
  };
  for (final entity in relations.entries) {
    for (final row in maps[entity.key]!.values) {
      for (final field in entity.value.entries) {
        final id = row[field.key];
        if (id != null &&
            (id is! String ||
                !maps[field.value]!.containsKey(id.toLowerCase()))) {
          throw const FormatException(
              'Hay relaciones financieras incompletas.');
        }
      }
    }
  }
  final entries = <String, List<ReservedEntry>>{};
  final externalIds = <String>{};
  for (final row in maps['transactions']!.values) {
    final amount = row['amountMinor'],
        date = row['date'],
        source = row['sourceAccountID'],
        type = row['typeRaw'];
    if (amount is! int ||
        amount < 0 ||
        date is! num ||
        !date.isFinite ||
        source is! String ||
        !maps['accounts']!.containsKey(source.toLowerCase()) ||
        !['income', 'expense', 'interest', 'fee', 'transfer'].contains(type)) {
      throw const FormatException('Movimiento financiero no válido.');
    }
    if (type == 'transfer' &&
        (row['destinationAccountID'] == null ||
            row['destinationAccountID'] == source)) {
      throw const FormatException(
          'La transferencia necesita dos cuentas distintas.');
    }
    final external = row['externalID'];
    if (external != null &&
        !externalIds.add('${source.toLowerCase()}:$external')) {
      throw const FormatException('Movimiento bancario duplicado.');
    }
    final fund = row['reservedFundID'], reserved = row['reservedAmountMinor'];
    if (fund == null) {
      if (reserved != null) {
        throw const FormatException('Falta la reserva del pago.');
      }
    } else {
      if (reserved is! int ||
          reserved <= 0 ||
          reserved > amount ||
          !['expense', 'fee', 'transfer'].contains(type)) {
        throw const FormatException(
            'Asignación de dinero reservado no válida.');
      }
      entries.putIfAbsent((fund as String).toLowerCase(), () => []).add(
          ReservedEntry(
              id: row['id'],
              date: referenceDate(date),
              source: source,
              destination:
                  type == 'transfer' ? row['destinationAccountID'] : null,
              amount: reserved));
    }
  }
  for (final fund in maps['reservedFunds']!.entries) {
    final amount = fund.value['amountMinor'], origin = fund.value['accountID'];
    if (amount is! int ||
        amount < 0 ||
        origin is! String ||
        reservedBalances(origin, amount, entries[fund.key] ?? []) == null) {
      throw const FormatException(
          'Los pagos superan el dinero reservado en su cuenta.');
    }
  }
}
