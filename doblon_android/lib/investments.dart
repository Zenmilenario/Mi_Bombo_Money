// Contributions to investment accounts and their fees (24 November 2026).
//
// An order bought from the cash of a broker is one operation with two parts: the capital, a transfer from the cash
// account to the investment account (the portfolio), and its fee, a separate «fee» movement out of the same cash,
// linked to the transfer. The cash goes down by both; the portfolio only by the capital; the fee is a cost of
// investing, apart from everyday spending and budgets. The banks' data (Enable Banking) has no fee field nor a split
// of the amount, so the fee is written by the person; nothing is assumed (never a fixed fee per broker).
//
// The link uses fields the cloud already keeps for every profile (also the developer's relational copy): the fee's
// `externalID` is `investment-fee:<transfer id>` and its id is derived from the transfer's, so the operation is always
// found, edited and deleted together. What makes a transfer a contribution is the destination account being of type
// Investment, not the name of a category.
import 'banking.dart' show stableUuid, referenceSeconds;
import 'edits.dart';
import 'models.dart';

/// The stable id of the fee of an operation: the same on every device.
String investmentFeeId(String transferId) => stableUuid('investment-fee|${transferId.toLowerCase()}');

/// The fee linked to an operation, if it has one.
Transaction? linkedFee(Finances data, String transferId) =>
    data.transactions.where((t) => t.isInvestmentFee && t.investmentOperationId?.toLowerCase() == transferId.toLowerCase()).firstOrNull;

/// A transfer from cash (not an investment account) to an investment account: money contributed to the portfolio.
bool isContribution(Transaction t, Finances data) =>
    t.type == TransactionType.transfer &&
    data.account(t.destinationAccountId)?.type == AccountType.investment &&
    data.account(t.sourceAccountId)?.type != AccountType.investment;

/// A transfer from an investment account to cash: money taken out of the portfolio.
bool isWithdrawal(Transaction t, Finances data) =>
    t.type == TransactionType.transfer &&
    data.account(t.sourceAccountId)?.type == AccountType.investment &&
    data.account(t.destinationAccountId)?.type != AccountType.investment;

/// A month of investing: contributed, withdrawn and paid in fees. A move between two portfolios, or between two cash
/// accounts (for example from the bank to the broker's cash), is neither: the money is only moved once into the
/// portfolio. Future-dated movements are left out. None of this is a return.
class InvestmentFlows {
  const InvestmentFlows({this.contributedMinor = 0, this.withdrawnMinor = 0, this.feesMinor = 0, this.operations = 0});
  final int contributedMinor, withdrawnMinor, feesMinor, operations;
  int get netMinor => contributedMinor - withdrawnMinor;
  bool get isEmpty => contributedMinor == 0 && withdrawnMinor == 0 && feesMinor == 0;
}

/// [accounts] limits the flows to those portfolios (the ones of the investment summary); [accountId] to one.
InvestmentFlows investmentFlows(Finances data, DateTime month, {DateTime? now, String? accountId, Set<String>? accounts}) {
  bool mine(String? id) => (accountId == null || id == accountId) && (accounts == null || accounts.contains(id));
  final until = now ?? DateTime.now();
  final key = monthKey(month);
  var contributed = 0, withdrawn = 0, fees = 0, operations = 0;
  for (final t in data.transactions) {
    if (monthKey(t.date) != key || t.date.isAfter(until)) continue;
    if (isContribution(t, data) && mine(t.destinationAccountId)) {
      contributed += t.amountMinor;
      operations++;
    } else if (isWithdrawal(t, data) && mine(t.sourceAccountId)) {
      withdrawn += t.amountMinor;
      operations++;
    } else if (t.isInvestmentFee) {
      final operation = data.transactions.where((o) => o.id.toLowerCase() == t.investmentOperationId?.toLowerCase()).firstOrNull;
      if (mine(operation?.destinationAccountId)) fees += t.amountMinor;
    }
  }
  return InvestmentFlows(contributedMinor: contributed, withdrawnMinor: withdrawn, feesMinor: fees, operations: operations);
}

/// Checks the split of an order: the total that left the cash, and its fee (zero or more). Null when valid.
String? validateSplit({required int totalMinor, required int feeMinor}) {
  if (feeMinor < 0) return 'La comisión no puede ser negativa.';
  if (totalMinor <= 0) return 'Escribe el importe total cargado.';
  if (feeMinor >= totalMinor) return 'La comisión debe ser menor que el importe total cargado.';
  return null;
}

/// The operations that keep the fee of [transfer] as written: created, changed or removed, never duplicated. The
/// fee leaves the same cash account on the same date as the order.
List<Operation> feeOperations({
  required String transferId,
  required Transaction? currentFee,
  required int feeMinor,
  required String? sourceAccountId,
  required DateTime date,
  required String orderDescription,
  required DateTime now,
}) {
  final id = currentFee?.id ?? investmentFeeId(transferId);
  if (feeMinor <= 0) return currentFee == null ? const [] : [deleteOperation(currentFee)];
  final description = 'Comisión · ${orderDescription.trim().isEmpty ? 'aportación a inversión' : orderDescription.trim()}';
  final fields = <String, dynamic>{
    'date': referenceSeconds(date),
    'typeRaw': TransactionType.fee.name,
    'amountMinor': feeMinor,
    'descriptionText': description,
    'sourceAccountID': sourceAccountId,
    'destinationAccountID': null,
    'externalID': '$investmentFeeMarker$transferId',
    'fingerprint': fingerprint(date: date, source: sourceAccountId, destination: null, type: TransactionType.fee, amountMinor: feeMinor, description: description),
    'updatedAt': referenceSeconds(now),
  };
  if (currentFee != null) return [Operation('patch', {'id': id, 'fields': fields})];
  return [
    Operation('insert', {
      'record': {
        'id': id,
        ...fields,
        'notes': '',
        'isReconciled': false,
        'duplicateStateRaw': 'none',
        'importBatchID': null,
        'recurringMovementID': null,
        'reservedFundID': null,
        'reservedAmountMinor': null,
        'categoryID': null,
        'bankEntryKey': null,
        'createdAt': referenceSeconds(now),
      }
    })
  ];
}

/// What a portfolio is worth in the app and where that figure comes from: the last valuation (written by the person,
/// or the balance a bank reported) and the movements recorded after it, or only the movements when it has none. It
/// is the recorded value, not a market price: a valuation keeps its date.
class PortfolioValue {
  PortfolioValue({required this.account, required this.valueMinor, this.valuation, required this.afterMinor, required this.movementsAfter});
  final Account account;
  final int valueMinor;
  final BalanceSnapshot? valuation;

  /// Contributions, withdrawals and other movements recorded after the valuation (already in [valueMinor]).
  final int afterMinor;
  final int movementsAfter;

  bool get fromBank => valuation?.source == 'bankAPI';
  bool get counted => account.includeInNetWorth;
}

/// Every active portfolio, with its value as the calculator gives it ([balanceAt] is `FinanceCalculator.balance`).
List<PortfolioValue> portfolioValues(Finances data, int Function(Account, DateTime) balanceAt, DateTime now) {
  final values = <PortfolioValue>[];
  for (final account in data.accounts.where((a) => !a.isArchived && a.type == AccountType.investment)) {
    final valuation = (data.snapshots.where((s) => s.accountId == account.id && !s.date.isAfter(now)).toList()..sort((a, b) => b.date.compareTo(a.date)))
        .firstOrNull;
    var after = 0, count = 0;
    for (final t in data.transactions) {
      if (t.date.isAfter(now) || (valuation != null && !t.date.isAfter(valuation.date))) continue;
      final into = t.destinationAccountId == account.id && t.type == TransactionType.transfer;
      final out = t.sourceAccountId == account.id;
      if (!into && !out) continue;
      count++;
      after += into ? t.amountMinor : (t.type.countsAsIncome ? t.amountMinor : -t.amountMinor);
    }
    values.add(PortfolioValue(account: account, valueMinor: balanceAt(account, now), valuation: valuation, afterMinor: after, movementsAfter: count));
  }
  return values;
}

/// The portfolios of the investment summary (Inicio and Cuentas): every active investment account except those the
/// person took out of it. Independent of net worth: a portfolio left out of net worth is still shown here unless it
/// is taken out of the summary too.
List<Account> summaryPortfolios(Finances data, Set<String> hidden) =>
    [for (final a in data.accounts) if (!a.isArchived && a.type == AccountType.investment && !hidden.contains(a.id)) a];

/// What the investment summary shows: the recorded value of its portfolios ([balanceAt] is `FinanceCalculator.balance`).
int investedInSummary(Finances data, int Function(Account, DateTime) balanceAt, Set<String> hidden, DateTime now) =>
    summaryPortfolios(data, hidden).fold(0, (sum, a) => sum + balanceAt(a, now));
