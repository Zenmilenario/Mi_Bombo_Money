// The finances as the cloud returns them (`finance_snapshot`), the same document the iPhone app syncs.
// Read only in this first version: nothing here writes back.

/// Dates in the document are seconds since 1 January 2001 (Apple's reference date), in UTC.
DateTime referenceDate(num seconds) =>
    DateTime.fromMillisecondsSinceEpoch(((seconds + 978307200) * 1000).round(), isUtc: true).toLocal();

/// A month as a single number, so months compare without time zones: year * 12 + month - 1.
int monthKey(DateTime date) => date.year * 12 + date.month - 1;
DateTime monthStart(DateTime date) => DateTime(date.year, date.month);

enum TransactionType { income, expense, interest, fee, transfer }

extension TransactionTypeRules on TransactionType {
  bool get countsAsIncome => this == TransactionType.income || this == TransactionType.interest;
  bool get countsAsExpense => this == TransactionType.expense || this == TransactionType.fee;
}

enum AccountType { checking, savings, cash, creditCard, investment, other }

extension AccountTypeRules on AccountType {
  bool get isLiability => this == AccountType.creditCard;
  String get title => switch (this) {
        AccountType.checking => 'Cuenta corriente',
        AccountType.savings => 'Ahorro',
        AccountType.cash => 'Efectivo',
        AccountType.creditCard => 'Tarjeta de crédito',
        AccountType.investment => 'Inversión',
        AccountType.other => 'Otra',
      };
}

enum CategoryKind { income, expense, both, transfer }

enum RemainderChoice { save, carryForward }

T _enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) =>
    values.firstWhere((value) => value.name == raw, orElse: () => fallback);

int _int(Object? value) => value is num ? value.toInt() : 0;
int? _intOrNull(Object? value) => value is num ? value.toInt() : null;
String _string(Object? value) => value is String ? value : '';
String? _stringOrNull(Object? value) => value is String && value.isNotEmpty ? value : null;
DateTime _date(Object? value) => value is num ? referenceDate(value) : DateTime(2001);

class Institution {
  Institution({required this.id, required this.name});
  final String id;
  final String name;
  factory Institution.fromJson(Map<String, dynamic> json) =>
      Institution(id: _string(json['id']), name: _string(json['name']));
}

class Account {
  Account({
    required this.id,
    required this.name,
    required this.type,
    this.currencyCode = 'EUR',
    this.openingBalanceMinor = 0,
    required this.openingDate,
    this.includeInNetWorth = true,
    this.isArchived = false,
    this.sortOrder = 0,
    this.institutionId,
    this.bankIdentityKey,
  });
  final String id;
  final String name;
  final AccountType type;
  /// ISO code of the account's currency. Amounts of this account are shown in it.
  final String currencyCode;
  final int openingBalanceMinor;
  final DateTime openingDate;
  final bool includeInNetWorth;
  final bool isArchived;
  final int sortOrder;
  final String? institutionId;
  final String? bankIdentityKey;

  factory Account.fromJson(Map<String, dynamic> json) => Account(
        id: _string(json['id']),
        name: _string(json['name']),
        type: _enumValue(AccountType.values, json['typeRaw'], AccountType.other),
        currencyCode: RegExp(r'^[A-Z]{3}$').hasMatch(_string(json['currencyCode'])) ? _string(json['currencyCode']) : 'EUR',
        openingBalanceMinor: _int(json['openingBalanceMinor']),
        openingDate: _date(json['openingDate']),
        includeInNetWorth: json['includeInNetWorth'] != false,
        isArchived: json['isArchived'] == true,
        sortOrder: _int(json['sortOrder']),
        institutionId: _stringOrNull(json['institutionID']),
        bankIdentityKey: _stringOrNull(json['bankIdentityKey']),
      );
}

class Category {
  Category({required this.id, required this.name, required this.kind, this.colorHex = '#4D7C8A', this.isArchived = false, this.sortOrder = 0});
  final String id;
  final String name;
  final CategoryKind kind;
  final String colorHex;
  final bool isArchived;
  final int sortOrder;

  bool get isExpense => !isArchived && (kind == CategoryKind.expense || kind == CategoryKind.both);

  factory Category.fromJson(Map<String, dynamic> json) => Category(
        id: _string(json['id']),
        name: _string(json['name']),
        kind: _enumValue(CategoryKind.values, json['kindRaw'], CategoryKind.expense),
        colorHex: _string(json['colorHex']).isEmpty ? '#4D7C8A' : _string(json['colorHex']),
        isArchived: json['isArchived'] == true,
        sortOrder: _int(json['sortOrder']),
      );
}

class Transaction {
  Transaction({
    required this.id,
    required this.date,
    required this.type,
    required this.amountMinor,
    required this.descriptionText,
    this.notes = '',
    this.sourceAccountId,
    this.destinationAccountId,
    this.categoryId,
    this.reservedFundId,
    this.reservedAmountMinor,
    this.externalId,
    this.bankEntryKey,
    this.duplicateState = 'none',
  });
  final String id;
  final DateTime date;
  final TransactionType type;
  final int amountMinor;
  final String descriptionText;
  final String notes;
  final String? sourceAccountId;
  final String? destinationAccountId;
  final String? categoryId;
  final String? reservedFundId;
  final int? reservedAmountMinor;
  final String? externalId;
  final String? bankEntryKey;
  final String duplicateState;

  /// Downloaded from a bank (its text needs the bank presentation rules).
  bool get isBanking => bankEntryKey != null;

  /// Recorded with Apple Pay on the iPhone and still waiting for the bank posting.
  bool get awaitsBank => bankEntryKey == null && (externalId?.startsWith('applepay:') ?? false);

  factory Transaction.fromJson(Map<String, dynamic> json) => Transaction(
        id: _string(json['id']),
        date: _date(json['date']),
        type: _enumValue(TransactionType.values, json['typeRaw'], TransactionType.expense),
        amountMinor: _int(json['amountMinor']).abs(),
        descriptionText: _string(json['descriptionText']),
        notes: _string(json['notes']),
        sourceAccountId: _stringOrNull(json['sourceAccountID']),
        destinationAccountId: _stringOrNull(json['destinationAccountID']),
        categoryId: _stringOrNull(json['categoryID']),
        reservedFundId: _stringOrNull(json['reservedFundID']),
        reservedAmountMinor: _intOrNull(json['reservedAmountMinor']),
        externalId: _stringOrNull(json['externalID']),
        bankEntryKey: _stringOrNull(json['bankEntryKey']),
        duplicateState: _string(json['duplicateStateRaw']).isEmpty ? 'none' : _string(json['duplicateStateRaw']),
      );
}

class BalanceSnapshot {
  BalanceSnapshot({required this.id, required this.date, required this.balanceMinor, required this.accountId});
  final String id;
  final DateTime date;
  final int balanceMinor;
  final String? accountId;
  factory BalanceSnapshot.fromJson(Map<String, dynamic> json) => BalanceSnapshot(
        id: _string(json['id']),
        date: _date(json['date']),
        balanceMinor: _int(json['balanceMinor']),
        accountId: _stringOrNull(json['accountID']),
      );
}

class ReservedFund {
  ReservedFund({required this.id, required this.name, required this.amountMinor, required this.accountId});
  final String id;
  final String name;
  final int amountMinor;
  final String? accountId;
  factory ReservedFund.fromJson(Map<String, dynamic> json) => ReservedFund(
        id: _string(json['id']),
        name: _string(json['name']),
        amountMinor: _int(json['amountMinor']),
        accountId: _stringOrNull(json['accountID']),
      );
}

class MonthlyBudget {
  MonthlyBudget({required this.id, required this.monthStart, required this.limitMinor, required this.categoryId});
  final String id;
  final DateTime monthStart;
  final int limitMinor;
  final String? categoryId;
  factory MonthlyBudget.fromJson(Map<String, dynamic> json) => MonthlyBudget(
        id: _string(json['id']),
        monthStart: _date(json['monthStart']),
        limitMinor: _int(json['limitMinor']),
        categoryId: _stringOrNull(json['categoryID']),
      );
}

class RecurringBudget {
  RecurringBudget({required this.id, required this.startMonth, this.endMonth, required this.baseLimitMinor, required this.remainderChoice, required this.categoryId});
  final String id;
  final DateTime startMonth;
  final DateTime? endMonth;
  final int baseLimitMinor;
  final RemainderChoice remainderChoice;
  final String? categoryId;
  factory RecurringBudget.fromJson(Map<String, dynamic> json) => RecurringBudget(
        id: _string(json['id']),
        startMonth: _date(json['startMonth']),
        endMonth: json['endMonth'] is num ? referenceDate(json['endMonth'] as num) : null,
        baseLimitMinor: _int(json['baseLimitMinor']),
        remainderChoice: _enumValue(RemainderChoice.values, json['remainderChoiceRaw'], RemainderChoice.save),
        categoryId: _stringOrNull(json['categoryID']),
      );
}

/// Everything one person has in the cloud, already parsed.
class Finances {
  Finances({
    this.institutions = const [],
    this.accounts = const [],
    this.categories = const [],
    this.transactions = const [],
    this.snapshots = const [],
    this.reservedFunds = const [],
    this.budgets = const [],
    this.recurringBudgets = const [],
  });
  final List<Institution> institutions;
  final List<Account> accounts;
  final List<Category> categories;
  final List<Transaction> transactions;
  final List<BalanceSnapshot> snapshots;
  final List<ReservedFund> reservedFunds;
  final List<MonthlyBudget> budgets;
  final List<RecurringBudget> recurringBudgets;

  static List<T> _list<T>(Map<String, dynamic> document, String key, T Function(Map<String, dynamic>) parse) =>
      ((document[key] as List?) ?? const [])
          .whereType<Map>()
          .map((row) => parse(Map<String, dynamic>.from(row)))
          .toList();

  /// Parses the `document` of `finance_snapshot`. Unknown or missing entities are simply empty.
  factory Finances.fromDocument(Map<String, dynamic> document) {
    final transactions = _list(document, 'transactions', Transaction.fromJson)..sort((a, b) => b.date.compareTo(a.date));
    final accounts = _list(document, 'accounts', Account.fromJson)..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    final categories = _list(document, 'categories', Category.fromJson)..sort((a, b) => a.sortOrder.compareTo(b.sortOrder));
    return Finances(
      institutions: _list(document, 'institutions', Institution.fromJson),
      accounts: accounts,
      categories: categories,
      transactions: transactions,
      snapshots: _list(document, 'snapshots', BalanceSnapshot.fromJson),
      reservedFunds: _list(document, 'reservedFunds', ReservedFund.fromJson),
      budgets: _list(document, 'budgets', MonthlyBudget.fromJson),
      recurringBudgets: _list(document, 'recurringBudgets', RecurringBudget.fromJson),
    );
  }

  Account? account(String? id) => id == null ? null : accounts.where((a) => a.id == id).firstOrNull;
  Category? category(String? id) => id == null ? null : categories.where((c) => c.id == id).firstOrNull;
  String? institutionName(String? id) => id == null ? null : institutions.where((i) => i.id == id).firstOrNull?.name;
}
