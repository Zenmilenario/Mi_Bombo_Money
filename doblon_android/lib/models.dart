// The finances as the cloud returns them (`finance_snapshot`), the same document the iPhone app syncs.
// Read only in this first version: nothing here writes back.

/// Dates in the document are seconds since 1 January 2001 (Apple's reference date), in UTC.
DateTime referenceDate(num seconds) => DateTime.fromMillisecondsSinceEpoch(((seconds + 978307200) * 1000).round(), isUtc: true).toLocal();

/// A month as a single number, so months compare without time zones: year * 12 + month - 1.
int monthKey(DateTime date) => date.year * 12 + date.month - 1;
DateTime monthStart(DateTime date) => DateTime(date.year, date.month);

enum TransactionType { income, expense, interest, fee, transfer }

/// The `externalID` of an investment order's fee: this marker and the id of the order.
const investmentFeeMarker = 'investment-fee:';

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

T _enumValue<T extends Enum>(List<T> values, Object? raw, T fallback) => values.firstWhere((value) => value.name == raw, orElse: () => fallback);

int _int(Object? value) => value is num ? value.toInt() : 0;
int? _intOrNull(Object? value) => value is num ? value.toInt() : null;
String _string(Object? value) => value is String ? value : '';
String? _stringOrNull(Object? value) => value is String && value.isNotEmpty ? value : null;
DateTime _date(Object? value) => value is num ? referenceDate(value) : DateTime(2001);

class Institution {
  Institution({required this.id, required this.name, this.colorHex = '#1F6B7A'});
  final String id;
  final String name;

  /// The bank's colour chosen on the iPhone, used to tint its accounts.
  final String colorHex;
  factory Institution.fromJson(Map<String, dynamic> json) => Institution(
      id: _string(json['id']), name: _string(json['name']), colorHex: _string(json['colorHex']).isEmpty ? '#1F6B7A' : _string(json['colorHex']));
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
    DateTime? lastUpdatedAt,
    this.notes = '',
    this.inInvestmentSummary,
  }) : lastUpdatedAt = lastUpdatedAt ?? openingDate;

  /// Whether an investment account is part of the investment summary (Inicio and Cuentas), chosen apart from net
  /// worth. Unset (an account from before, or a document of an earlier version) means it is.
  final bool? inInvestmentSummary;
  bool get inSummary => inInvestmentSummary != false;
  final String id;
  final String name;
  final AccountType type;
  final DateTime lastUpdatedAt;
  final String notes;

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
        lastUpdatedAt: json['lastUpdatedAt'] is num ? referenceDate(json['lastUpdatedAt'] as num) : null,
        notes: _string(json['notes']),
        inInvestmentSummary: json['inInvestmentSummary'] is bool ? json['inInvestmentSummary'] as bool : null,
      );
}

class Category {
  Category(
      {required this.id,
      required this.name,
      required this.kind,
      this.colorHex = '#4D7C8A',
      this.isArchived = false,
      this.sortOrder = 0,
      this.systemImage = 'tag'});
  final String id;
  final String name;
  final CategoryKind kind;
  final String colorHex;

  /// The icon the iPhone app gave it, an SF Symbol name (`symbolIcon` draws it).
  final String systemImage;
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
        systemImage: _string(json['systemImage']).isEmpty ? 'tag' : _string(json['systemImage']),
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
    this.fingerprint = '',
    this.isReconciled = false,
    this.recurringMovementId,
    DateTime? createdAt,
    DateTime? updatedAt,
  })  : createdAt = createdAt ?? date,
        updatedAt = updatedAt ?? createdAt ?? date;
  final String? recurringMovementId;

  /// When the record was created and last changed (the learning uses them, as on the iPhone).
  final DateTime createdAt;
  final DateTime updatedAt;
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
  final String fingerprint;
  final bool isReconciled;

  /// Downloaded from a bank (its text needs the bank presentation rules).
  bool get isBanking => bankEntryKey != null;

  /// Recorded with Apple Pay on the iPhone and still waiting for the bank posting.
  bool get awaitsBank => bankEntryKey == null && (externalId?.startsWith('applepay:') ?? false);

  /// The fee of an investment order, linked to the order (a transfer to an investment account): a cost of investing,
  /// apart from everyday spending and budgets (`lib/investments.dart`).
  bool get isInvestmentFee => type == TransactionType.fee && (externalId?.startsWith(investmentFeeMarker) ?? false);
  String? get investmentOperationId => isInvestmentFee ? externalId!.substring(investmentFeeMarker.length) : null;

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
        fingerprint: _string(json['fingerprint']),
        isReconciled: json['isReconciled'] == true,
        recurringMovementId: _stringOrNull(json['recurringMovementID']),
        createdAt: json['createdAt'] is num ? referenceDate(json['createdAt'] as num) : null,
        updatedAt: json['updatedAt'] is num ? referenceDate(json['updatedAt'] as num) : null,
      );
}

class BalanceSnapshot {
  BalanceSnapshot({required this.id, required this.date, required this.balanceMinor, required this.accountId, this.source = '', this.notes = ''});
  final String id;
  final DateTime date;
  final int balanceMinor;
  final String? accountId;

  /// «manual» when the person fixed the balance (an update or a regularization), «bankAPI» when the bank reported it.
  final String source;
  final String notes;
  factory BalanceSnapshot.fromJson(Map<String, dynamic> json) => BalanceSnapshot(
        id: _string(json['id']),
        date: _date(json['date']),
        balanceMinor: _int(json['balanceMinor']),
        accountId: _stringOrNull(json['accountID']),
        source: _string(json['sourceRaw']),
        notes: _string(json['notes']),
      );
}

class ReservedFund {
  ReservedFund({required this.id, required this.name, required this.amountMinor, required this.accountId, this.createdAt});
  final String id;
  final String name;

  /// What was set aside when the reserve was created, in [accountId].
  final int amountMinor;
  final String? accountId;

  /// When it was created: income linked to it before this date is where its starting amount came from (it is not
  /// added again); income linked after it adds to the reserve.
  final DateTime? createdAt;
  factory ReservedFund.fromJson(Map<String, dynamic> json) => ReservedFund(
        id: _string(json['id']),
        name: _string(json['name']),
        amountMinor: _int(json['amountMinor']),
        accountId: _stringOrNull(json['accountID']),
        createdAt: json['createdAt'] is num ? referenceDate(json['createdAt'] as num) : null,
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
  RecurringBudget(
      {required this.id, required this.startMonth, this.endMonth, required this.baseLimitMinor, required this.remainderChoice, required this.categoryId});
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
    this.cards = const [],
    this.goals = const [],
    this.recurringMovements = const [],
    this.categoryRules = const [],
  });
  final List<PaymentCard> cards;
  final List<SavingsGoal> goals;
  final List<RecurringMovement> recurringMovements;
  final List<CategoryRule> categoryRules;
  final List<Institution> institutions;
  final List<Account> accounts;
  final List<Category> categories;
  final List<Transaction> transactions;
  final List<BalanceSnapshot> snapshots;
  final List<ReservedFund> reservedFunds;
  final List<MonthlyBudget> budgets;
  final List<RecurringBudget> recurringBudgets;

  static List<T> _list<T>(Map<String, dynamic> document, String key, T Function(Map<String, dynamic>) parse) =>
      ((document[key] as List?) ?? const []).whereType<Map>().map((row) => parse(Map<String, dynamic>.from(row))).toList();

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
      cards: _list(document, 'cards', PaymentCard.fromJson),
      goals: _list(document, 'goals', SavingsGoal.fromJson),
      recurringMovements: _list(document, 'recurringMovements', RecurringMovement.fromJson)..sort((a, b) => a.nextDueDate.compareTo(b.nextDueDate)),
      categoryRules: _list(document, 'categoryRules', CategoryRule.fromJson),
    );
  }

  Account? account(String? id) => id == null ? null : accounts.where((a) => a.id == id).firstOrNull;
  Category? category(String? id) => id == null ? null : categories.where((c) => c.id == id).firstOrNull;
  String? institutionName(String? id) => id == null ? null : institutions.where((i) => i.id == id).firstOrNull?.name;
}

enum CardType { debit, credit, prepaid, virtual }

extension CardTypeTitle on CardType {
  String get title => switch (this) {
        CardType.debit => 'Débito',
        CardType.credit => 'Crédito',
        CardType.prepaid => 'Prepago',
        CardType.virtual => 'Virtual',
      };
}

class PaymentCard {
  PaymentCard({required this.id, required this.name, required this.type, this.lastFour = '', this.linkedAccountId, this.isArchived = false});
  final String id;
  final String name;
  final CardType type;
  final String lastFour;
  final String? linkedAccountId;
  final bool isArchived;
  factory PaymentCard.fromJson(Map<String, dynamic> json) => PaymentCard(
        id: _string(json['id']),
        name: _string(json['name']),
        type: _enumValue(CardType.values, json['typeRaw'], CardType.debit),
        lastFour: _string(json['lastFour']),
        linkedAccountId: _stringOrNull(json['linkedAccountID']),
        isArchived: json['isArchived'] == true,
      );
}

class SavingsGoal {
  SavingsGoal(
      {required this.id,
      required this.name,
      required this.targetAmountMinor,
      this.currentAmountMinor = 0,
      this.targetDate,
      this.colorHex = '#2F7D66',
      this.isCompleted = false,
      this.linkedAccountId});
  final String id;
  final String name;
  final int targetAmountMinor;
  final int currentAmountMinor;
  final DateTime? targetDate;
  final String colorHex;
  final bool isCompleted;
  final String? linkedAccountId;
  factory SavingsGoal.fromJson(Map<String, dynamic> json) => SavingsGoal(
        id: _string(json['id']),
        name: _string(json['name']),
        targetAmountMinor: _int(json['targetAmountMinor']),
        currentAmountMinor: _int(json['currentAmountMinor']),
        targetDate: json['targetDate'] is num ? referenceDate(json['targetDate'] as num) : null,
        colorHex: _string(json['colorHex']).isEmpty ? '#2F7D66' : _string(json['colorHex']),
        isCompleted: json['isCompleted'] == true,
        linkedAccountId: _stringOrNull(json['linkedAccountID']),
      );
}

enum Frequency { weekly, monthly, quarterly, yearly }

extension FrequencyTitle on Frequency {
  String get title => switch (this) {
        Frequency.weekly => 'Semanal',
        Frequency.monthly => 'Mensual',
        Frequency.quarterly => 'Trimestral',
        Frequency.yearly => 'Anual',
      };
}

class RecurringMovement {
  RecurringMovement({
    required this.id,
    required this.name,
    required this.type,
    required this.amountMinor,
    required this.descriptionText,
    this.notes = '',
    required this.frequency,
    this.interval = 1,
    required this.nextDueDate,
    this.endDate,
    this.isActive = true,
    this.isSubscription = false,
    this.postsAutomatically,
    this.sourceAccountId,
    this.destinationAccountId,
    this.categoryId,
  });
  final String id;
  final String name;
  final TransactionType type;
  final int amountMinor;
  final String descriptionText;
  final String notes;
  final Frequency frequency;
  final int interval;
  final DateTime nextDueDate;
  final DateTime? endDate;
  final bool isActive;
  final bool isSubscription;
  final bool? postsAutomatically;
  final String? sourceAccountId;
  final String? destinationAccountId;
  final String? categoryId;
  factory RecurringMovement.fromJson(Map<String, dynamic> json) => RecurringMovement(
        id: _string(json['id']),
        name: _string(json['name']),
        type: _enumValue(TransactionType.values, json['typeRaw'], TransactionType.expense),
        amountMinor: _int(json['amountMinor']),
        descriptionText: _string(json['descriptionText']),
        notes: _string(json['notes']),
        frequency: _enumValue(Frequency.values, json['frequencyRaw'], Frequency.monthly),
        interval: _int(json['interval']) < 1 ? 1 : _int(json['interval']),
        nextDueDate: _date(json['nextDueDate']),
        endDate: json['endDate'] is num ? referenceDate(json['endDate'] as num) : null,
        isActive: json['isActive'] != false,
        isSubscription: json['isSubscription'] == true,
        postsAutomatically: json['postsAutomatically'] is bool ? json['postsAutomatically'] as bool : null,
        sourceAccountId: _stringOrNull(json['sourceAccountID']),
        destinationAccountId: _stringOrNull(json['destinationAccountID']),
        categoryId: _stringOrNull(json['categoryID']),
      );
}

class CategoryRule {
  CategoryRule({required this.id, required this.phrase, required this.transactionType, this.isActive = true, this.categoryId, required this.updatedAt});
  final String id;
  final String phrase;
  final TransactionType transactionType;
  final bool isActive;
  final String? categoryId;
  final DateTime updatedAt;
  factory CategoryRule.fromJson(Map<String, dynamic> json) => CategoryRule(
        id: _string(json['id']),
        phrase: _string(json['phrase']),
        transactionType: _enumValue(TransactionType.values, json['transactionTypeRaw'], TransactionType.expense),
        isActive: json['isActive'] != false,
        categoryId: _stringOrNull(json['categoryID']),
        updatedAt: _date(json['updatedAt']),
      );
}
