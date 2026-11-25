// Short-term forecast of balances and free money, and «what if» scenarios on top of it.
// Read only: it never writes to the finances, never creates movements and never teaches the models. It reuses the
// existing pieces (periodic payments, budgets, reserves, goals, future-dated movements) instead of keeping its own.
import 'dart:math' as math;

import 'automation.dart' show CompanionNote, nextDueDate, ruleText;
import 'finance.dart';
import 'installments.dart';
import 'models.dart';
import 'presentation.dart' show bankTitle, money;

/// A calendar day, as a UTC midnight so that adding days never trips over a change of time.
DateTime forecastDay(DateTime date) {
  final local = date.toLocal();
  return DateTime.utc(local.year, local.month, local.day);
}

DateTime _plus(DateTime day, int days) => DateTime.utc(day.year, day.month, day.day + days);
int _between(DateTime from, DateTime to) => to.difference(from).inDays;
int _daysInMonth(int year, int month) => DateTime.utc(year, month + 1, 0).day;
String isoDay(DateTime day) => day.toIso8601String().substring(0, 10);
DateTime? _parseDay(Object? raw) {
  final value = raw is String ? DateTime.tryParse(raw) : null;
  return value == null ? null : DateTime.utc(value.year, value.month, value.day);
}

String shortDay(DateTime day) => '${day.day}/${day.month}';

/// The words that name a repeated movement, without what changes every month: numbers, month names and filler
/// words of bank concepts («NOMINA JULIO EMPRESA» and «NOMINA AGOSTO EMPRESA» are the same income).
String patternWords(String description) {
  const filler = {
    'enero', 'febrero', 'marzo', 'abril', 'mayo', 'junio', 'julio', 'agosto', 'septiembre', 'setiembre', 'octubre', 'noviembre', 'diciembre', //
    'ene', 'feb', 'mar', 'abr', 'jun', 'jul', 'ago', 'sep', 'sept', 'oct', 'nov', 'dic', 'mes', //
    'de', 'del', 'la', 'el', 'los', 'las', 'en', 'por', 'para', 'con', //
    'transferencia', 'recibida', 'emitida', 'inmediata', 'trans', 'inm', 'transf', 'ref', 'referencia', 'concepto', 'abono', 'cargo', 'recibo',
  };
  return ruleText(description)
      .replaceAll(RegExp(r'\d+'), ' ')
      .split(' ')
      .where((w) => w.length > 1 && !filler.contains(w))
      .take(3)
      .join(' ');
}

/// How sure an item of the forecast is: a movement already recorded with a future date, a periodic payment the
/// person set up, an estimate from the history or the budgets, or a change that only exists in a simulation.
enum ForecastCertainty { recorded, confirmed, estimated, assumed, simulated }

extension ForecastCertaintyTitle on ForecastCertainty {
  String get title => switch (this) {
        ForecastCertainty.recorded => 'Apuntado',
        ForecastCertainty.confirmed => 'Confirmado',
        ForecastCertainty.estimated => 'Estimado',
        ForecastCertainty.assumed => 'Indicado por ti',
        ForecastCertainty.simulated => 'Simulado',
      };
}

/// One expected change of money. [amountMinor] is signed for [accountId] (negative when money leaves it); a transfer
/// takes it from [accountId] and puts it in [destinationId], so the total does not change.
class ForecastEvent {
  const ForecastEvent({
    required this.key,
    required this.source,
    required this.day,
    required this.label,
    required this.amountMinor,
    required this.accountId,
    this.destinationId,
    required this.certainty,
    this.reserveChanges = const {},
    this.categoryId,
    this.detail = '',
    this.excluded = false,
  });
  final String key;

  /// The assumption it comes from, which the person can switch off or change: `rec:<id>` a periodic payment,
  /// `pat:<group>` something repeated in the history, `var` the variable spending, `tx:<id>` a recorded movement,
  /// `hold` a charge the bank holds, `sim:<id>` a simulation.
  final String source;
  final DateTime day;
  final String label;
  final int amountMinor;
  final String accountId;
  final String? destinationId;
  final ForecastCertainty certainty;

  /// Reserved money per account: positive sets money aside, negative is reserved money spent.
  final Map<String, int> reserveChanges;
  final String? categoryId;
  final String detail;
  final bool excluded;

  bool get isTransfer => destinationId != null;
  bool get isVariable => source == 'var';

  ForecastEvent copyWith({DateTime? day, int? amountMinor, bool? excluded, ForecastCertainty? certainty, String? detail}) => ForecastEvent(
        key: key,
        source: source,
        day: day ?? this.day,
        label: label,
        amountMinor: amountMinor ?? this.amountMinor,
        accountId: accountId,
        destinationId: destinationId,
        certainty: certainty ?? this.certainty,
        reserveChanges: reserveChanges,
        categoryId: categoryId,
        detail: detail ?? this.detail,
        excluded: excluded ?? this.excluded,
      );
}

/// The person's assumptions. Changing them never touches a movement or a periodic payment.
/// An income the person expects every month, written only for the forecast: it never becomes a movement. When a
/// real income of a similar amount arrives in that account around its day, it takes its place.
class PlannedIncome {
  const PlannedIncome({required this.id, required this.name, required this.amountMinor, required this.dayOfMonth, required this.accountId});
  final String id;
  final String name;
  final int amountMinor;
  final int dayOfMonth;
  final String accountId;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'amountMinor': amountMinor, 'dayOfMonth': dayOfMonth, 'accountId': accountId};

  static PlannedIncome? fromJson(Map<String, dynamic> json) {
    final day = json['dayOfMonth'], amount = json['amountMinor'];
    if (json['id'] is! String || json['accountId'] is! String || day is! int || amount is! int || day < 1 || day > 31 || amount <= 0) return null;
    return PlannedIncome(
        id: json['id'] as String, name: json['name'] is String ? json['name'] as String : 'Ingreso', amountMinor: amount, dayOfMonth: day, accountId: json['accountId'] as String);
  }
}

class ForecastSettings {
  const ForecastSettings(
      {this.horizonDays = 60,
      this.cushionMinor = 0,
      this.useHistory = true,
      this.variableMonthlyMinor,
      this.excluded = const {},
      this.amounts = const {},
      this.accepted = const {},
      this.incomes = const []});
  final int horizonDays;

  /// Repetitions found in the history that the person confirmed («Sí, cuenta con él»).
  final Set<String> accepted;

  /// Incomes the person expects and wrote for the forecast.
  final List<PlannedIncome> incomes;

  /// Free money the person does not want to go below.
  final int cushionMinor;

  /// Estimates from the history (repeated movements and everyday spending without a budget).
  final bool useHistory;

  /// The variable spending per month, when the person writes it instead of the automatic one.
  final int? variableMonthlyMinor;

  /// Sources left out of the forecast, and amounts changed by the person, by source.
  final Set<String> excluded;
  final Map<String, int> amounts;

  ForecastSettings copyWith(
          {int? horizonDays,
          int? cushionMinor,
          bool? useHistory,
          int? Function()? variableMonthlyMinor,
          Set<String>? excluded,
          Map<String, int>? amounts,
          Set<String>? accepted,
          List<PlannedIncome>? incomes}) =>
      ForecastSettings(
        horizonDays: horizonDays ?? this.horizonDays,
        cushionMinor: cushionMinor ?? this.cushionMinor,
        useHistory: useHistory ?? this.useHistory,
        variableMonthlyMinor: variableMonthlyMinor == null ? this.variableMonthlyMinor : variableMonthlyMinor(),
        excluded: excluded ?? this.excluded,
        amounts: amounts ?? this.amounts,
        accepted: accepted ?? this.accepted,
        incomes: incomes ?? this.incomes,
      );

  /// Counts a repetition from the history (accepted) or leaves it out; either way it is no longer a proposal.
  ForecastSettings review(String source, {required bool keep}) => copyWith(
        accepted: keep ? ({...accepted, source}) : ({...accepted}..remove(source)),
        excluded: keep ? ({...excluded}..remove(source)) : ({...excluded, source}),
      );

  Map<String, dynamic> toJson() => {
        'horizonDays': horizonDays,
        'cushionMinor': cushionMinor,
        'useHistory': useHistory,
        'variableMonthlyMinor': variableMonthlyMinor,
        'excluded': excluded.toList()..sort(),
        'amounts': amounts,
        'accepted': accepted.toList()..sort(),
        'incomes': [for (final i in incomes) i.toJson()],
      };

  factory ForecastSettings.fromJson(Map<String, dynamic> json) => ForecastSettings(
        horizonDays: const [30, 60, 90].contains(json['horizonDays']) ? json['horizonDays'] as int : 60,
        cushionMinor: json['cushionMinor'] is int && (json['cushionMinor'] as int) >= 0 ? json['cushionMinor'] as int : 0,
        useHistory: json['useHistory'] != false,
        variableMonthlyMinor: json['variableMonthlyMinor'] is int && (json['variableMonthlyMinor'] as int) >= 0 ? json['variableMonthlyMinor'] as int : null,
        excluded: {for (final item in (json['excluded'] as List?) ?? const []) '$item'},
        amounts: {
          for (final entry in ((json['amounts'] as Map?) ?? const {}).entries)
            if (entry.value is int && (entry.value as int) >= 0) '${entry.key}': entry.value as int
        },
        accepted: {for (final item in (json['accepted'] as List?) ?? const []) '$item'},
        incomes: [
          for (final raw in (json['incomes'] as List?) ?? const [])
            if (raw is Map) PlannedIncome.fromJson(Map<String, dynamic>.from(raw))
        ].whereType<PlannedIncome>().toList(),
      );
}

enum ScenarioKind { purchase, monthlyExpense, incomeChange, reserveContribution }

extension ScenarioKindTitle on ScenarioKind {
  String get title => switch (this) {
        ScenarioKind.purchase => 'Compra puntual',
        ScenarioKind.monthlyExpense => 'Nuevo gasto mensual',
        ScenarioKind.incomeChange => 'Cambio de ingresos',
        ScenarioKind.reserveContribution => 'Aportar a una reserva',
      };
}

/// One change of a simulation. [amountMinor] is positive, except for a change of income, where it is the variation
/// (negative when the income goes down).
class ScenarioChange {
  const ScenarioChange(
      {required this.kind, required this.amountMinor, required this.day, this.accountId, this.reserveId, this.incomeSource, this.delayDays = 0, this.monthly = false});
  final ScenarioKind kind;
  final int amountMinor;
  final DateTime day;
  final String? accountId;
  final String? reserveId;
  final String? incomeSource;
  final int delayDays;
  final bool monthly;

  Map<String, dynamic> toJson() => {
        'kind': kind.name,
        'amountMinor': amountMinor,
        'day': isoDay(day),
        'accountId': accountId,
        'reserveId': reserveId,
        'incomeSource': incomeSource,
        'delayDays': delayDays,
        'monthly': monthly,
      };

  static ScenarioChange? fromJson(Map<String, dynamic> json) {
    final kind = ScenarioKind.values.where((k) => k.name == json['kind']).firstOrNull;
    final day = _parseDay(json['day']);
    if (kind == null || day == null || json['amountMinor'] is! int) return null;
    String? text(Object? value) => value is String && value.isNotEmpty ? value : null;
    return ScenarioChange(
      kind: kind,
      amountMinor: json['amountMinor'] as int,
      day: day,
      accountId: text(json['accountId']),
      reserveId: text(json['reserveId']),
      incomeSource: text(json['incomeSource']),
      delayDays: json['delayDays'] is int ? (json['delayDays'] as int).clamp(0, 120) : 0,
      monthly: json['monthly'] == true,
    );
  }
}

/// A saved simulation. It lives apart from the finances: it never becomes a movement.
class Scenario {
  const Scenario({required this.id, required this.name, required this.changes});
  final String id;
  final String name;
  final List<ScenarioChange> changes;

  Map<String, dynamic> toJson() => {'id': id, 'name': name, 'changes': [for (final c in changes) c.toJson()]};

  static Scenario? fromJson(Map<String, dynamic> json) {
    if (json['id'] is! String || json['name'] is! String) return null;
    final changes = [
      for (final raw in (json['changes'] as List?) ?? const [])
        if (raw is Map) ScenarioChange.fromJson(Map<String, dynamic>.from(raw))
    ].whereType<ScenarioChange>().toList();
    return changes.isEmpty ? null : Scenario(id: json['id'] as String, name: json['name'] as String, changes: changes);
  }
}

/// Where an account's starting balance comes from.
enum StartBasis { bank, manual, computed }

/// Something that repeated in the history about once a month: a proposal the person can confirm or leave out.
class HistoryProposal {
  const HistoryProposal(
      {required this.source, required this.label, required this.amountMinor, required this.dayOfMonth, required this.accountId, required this.isIncome, required this.times});
  final String source;
  final String label;
  final int amountMinor;
  final int dayOfMonth;
  final String accountId;
  final bool isIncome;
  final int times;
}

class AccountStart {
  AccountStart({required this.account, required this.balanceMinor, required this.reservedMinor, required this.basis, this.basisDate});
  final Account account;
  final int balanceMinor;
  final int reservedMinor;
  final StartBasis basis;
  final DateTime? basisDate;

  String get basisText => switch (basis) {
        StartBasis.bank => 'Saldo recibido del banco${basisDate == null ? '' : ' el ${shortDay(forecastDay(basisDate!))}'}',
        StartBasis.manual => 'Saldo que indicaste${basisDate == null ? '' : ' el ${shortDay(forecastDay(basisDate!))}'}',
        StartBasis.computed => 'Saldo calculado con tus movimientos',
      };
}

/// The base forecast: the starting point, every expected item (also those switched off) and what limits it.
class ForecastPlan {
  ForecastPlan({
    required this.data,
    required this.now,
    required this.today,
    required this.end,
    required this.settings,
    required this.starts,
    required this.events,
    required this.limitations,
    required this.funds,
    required this.variableMonthlyMinor,
    required this.variableFromBudgetsMinor,
    required this.historyDays,
    this.proposals = const [],
    this.irregularIncomes = const [],
    this.pastBalances = const {},
    this.pastReserved = const {},
  });

  /// What repeats in the history, to review: counted as an estimate until the person says otherwise.
  final List<HistoryProposal> proposals;

  /// Incomes of the history that do not repeat regularly: never counted, only pointed out.
  final List<String> irregularIncomes;

  /// The real balance and reserved money of each account at the end of each of the last [pastDays] days, oldest
  /// first (today is the starting point of the forecast).
  final Map<String, List<int>> pastBalances;
  final Map<String, List<int>> pastReserved;
  static const pastDays = 30;

  /// Whether any income is expected in the horizon: without one, the line can only go down.
  bool get hasIncome => active.any((e) => e.amountMinor > 0 && !e.isTransfer && e.certainty != ForecastCertainty.simulated);
  final Finances data;
  final DateTime now, today, end;
  final ForecastSettings settings;
  final List<AccountStart> starts;
  final List<ForecastEvent> events;
  final List<String> limitations;

  /// Where each reserve's money is now: reserve → account → amount.
  final Map<String, Map<String, int>> funds;

  /// The automatic variable spending of a whole month, and the part of it that comes from budgets.
  final int variableMonthlyMinor;
  final int variableFromBudgetsMinor;

  /// Days of history the estimates could learn from.
  final int historyDays;

  List<HistoryProposal> get pendingProposals => [for (final p in proposals) if (!settings.accepted.contains(p.source) && !settings.excluded.contains(p.source)) p];

  int get days => _between(today, end);
  List<ForecastEvent> get active => [for (final e in events) if (!e.excluded) e];
  Account? account(String id) => starts.where((s) => s.account.id == id).firstOrNull?.account;

  /// The account with the most everyday activity: the default one for a simulation.
  String? get defaultAccountId {
    final checking = starts.where((s) => s.account.type == AccountType.checking).toList()
      ..sort((a, b) => (b.balanceMinor - b.reservedMinor).compareTo(a.balanceMinor - a.reservedMinor));
    return (checking.isNotEmpty ? checking : starts).firstOrNull?.account.id;
  }

  /// The income items a simulation can change or delay: one per periodic payment or repeated income.
  List<(String source, String label)> get incomeSources {
    final seen = <String>{};
    return [
      for (final e in events)
        if (!e.isTransfer && e.amountMinor > 0 && (e.source.startsWith('rec:') || e.source.startsWith('pat:')) && seen.add(e.source)) (e.source, e.label)
    ];
  }

  /// The account where a reserve keeps most of its money.
  String? reserveAccount(String reserveId) {
    final located = funds[reserveId];
    if (located == null || located.isEmpty) return data.reservedFunds.where((f) => f.id == reserveId).firstOrNull?.accountId;
    return (located.entries.toList()..sort((a, b) => b.value.compareTo(a.value))).first.key;
  }
}

/// Builds the base forecast from the finances. [holds] are the charges the bank holds and has not booked yet
/// (account, negative amount): they are already taken from what is available.
ForecastPlan buildForecast(FinanceCalculator calc, DateTime now, ForecastSettings settings, {List<(String, int)> holds = const []}) {
  final data = calc.data;
  final today = forecastDay(now);
  final end = _plus(today, settings.horizonDays);
  final limitations = <String>[];
  final tracked = <String, Account>{};
  for (final a in data.accounts) {
    if (a.isArchived || !a.includeInNetWorth || a.type == AccountType.investment || a.type.isLiability) continue;
    if (a.currencyCode != 'EUR') {
      limitations.add('«${a.name}» está en ${a.currencyCode} y no entra en la previsión.');
      continue;
    }
    tracked[a.id] = a;
  }

  // Reserves: where their money is now. It is not available for everyday spending.
  final funds = <String, Map<String, int>>{};
  for (final fund in data.reservedFunds) {
    if (fund.accountId == null) continue;
    final located = reservedBalances(fund.accountId!, fund.amountMinor, calc.reserveEntries(fund), through: now);
    if (located != null) funds[fund.id] = {for (final e in located.entries) if (e.value > 0) e.key: e.value};
  }

  final starts = <AccountStart>[];
  for (final account in tracked.values) {
    final snapshot = (data.snapshots.where((s) => s.accountId == account.id && !s.date.isAfter(now)).toList()..sort((a, b) => b.date.compareTo(a.date)))
        .firstOrNull;
    final basis = snapshot == null ? StartBasis.computed : (snapshot.source == 'bankAPI' ? StartBasis.bank : StartBasis.manual);
    starts.add(AccountStart(
      account: account,
      balanceMinor: calc.balance(account, now),
      reservedMinor: funds.values.fold(0, (sum, located) => sum + (located[account.id] ?? 0)),
      basis: basis,
      basisDate: snapshot?.date,
    ));
    if (snapshot != null) {
      final age = _between(forecastDay(snapshot.date), today);
      final hasLaterMovements = data.transactions.any((t) => t.sourceAccountId == account.id && t.date.isAfter(snapshot.date) && !t.date.isAfter(now));
      if (age > 7 && !hasLaterMovements) limitations.add('El saldo de «${account.name}» es de hace $age días.');
    } else {
      limitations.add('«${account.name}»: saldo calculado con tus movimientos, sin saldo del banco.');
    }
  }

  final events = <ForecastEvent>[];
  ForecastEvent? flow({
    required String key,
    required String source,
    required DateTime day,
    required String label,
    required TransactionType type,
    required int amount,
    required String? from,
    String? to,
    required ForecastCertainty certainty,
    String? categoryId,
    String detail = '',
    Map<String, int> reserveChanges = const {},
  }) {
    final value = amount.abs();
    final excluded = settings.excluded.contains(source);
    if (type == TransactionType.transfer) {
      final fromTracked = from != null && tracked.containsKey(from);
      final toTracked = to != null && to != from && tracked.containsKey(to);
      if (fromTracked) {
        return ForecastEvent(
            key: key,
            source: source,
            day: day,
            label: label,
            amountMinor: -value,
            accountId: from,
            destinationId: toTracked ? to : null,
            certainty: certainty,
            categoryId: categoryId,
            detail: detail,
            reserveChanges: reserveChanges,
            excluded: excluded);
      }
      if (toTracked) {
        return ForecastEvent(
            key: key, source: source, day: day, label: label, amountMinor: value, accountId: to, certainty: certainty, detail: detail, excluded: excluded);
      }
      return null;
    }
    if (from == null || !tracked.containsKey(from)) return null;
    return ForecastEvent(
        key: key,
        source: source,
        day: day,
        label: label,
        amountMinor: type.countsAsIncome ? value : -value,
        accountId: from,
        certainty: certainty,
        categoryId: categoryId,
        detail: detail,
        reserveChanges: reserveChanges,
        excluded: excluded);
  }

  // 1. Movements already recorded with a later date: real, so they count as they are.
  for (final t in data.transactions) {
    if (!t.date.isAfter(now)) break; // newest first
    final day = forecastDay(t.date);
    if (day.isAfter(end)) continue;
    final reserve = <String, int>{};
    final spentFromReserve = FinanceCalculator.reservedExpenseAmount(t);
    if (spentFromReserve > 0 && t.sourceAccountId != null) reserve[t.sourceAccountId!] = -spentFromReserve;
    if (t.type == TransactionType.transfer && t.reservedFundId != null && (t.reservedAmountMinor ?? 0) > 0) {
      reserve[t.sourceAccountId ?? ''] = -(t.reservedAmountMinor!);
      if (t.destinationAccountId != null) reserve[t.destinationAccountId!] = t.reservedAmountMinor!;
    }
    final fund = data.reservedFunds.where((f) => f.id == t.reservedFundId).firstOrNull;
    final setAside = FinanceCalculator.reservedIncomeAmount(t);
    if (setAside > 0 && fund?.createdAt != null && t.date.isAfter(fund!.createdAt!) && t.sourceAccountId != null) reserve[t.sourceAccountId!] = setAside;
    final event = flow(
        key: 'tx:${t.id}',
        source: 'tx:${t.id}',
        day: day,
        label: bankTitle(t.descriptionText, isBanking: t.isBanking),
        type: t.type,
        amount: t.amountMinor,
        from: t.sourceAccountId,
        to: t.destinationAccountId,
        certainty: ForecastCertainty.recorded,
        categoryId: t.categoryId,
        detail: 'Movimiento ya apuntado',
        reserveChanges: reserve);
    if (event != null) events.add(event.copyWith(excluded: false));
  }

  // 1b. Instalments of the plans paid in instalments (`lib/installments.dart`): each open one is a confirmed payment
  // on its due date; an overdue one counts today, unless a bank charge that may be it already arrived (to confirm).
  // A periodic payment that is the same payment (`overlappingRecurring`) gives way to it near its dates.
  final instalmentDays = <String, List<DateTime>>{};
  for (final plan in data.installmentPlans) {
    if (plan.isArchived || plan.accountId == null) continue;
    final progress = installmentProgress(plan, data, now);
    final arrived = {for (final (s, _) in compatibleCharges(progress, data)) s.number};
    final overlapping = overlappingRecurring(plan, data);
    for (final s in progress.states) {
      if (!s.isOpen || arrived.contains(s.number)) continue;
      final day = forecastDay(s.installment.dueDate);
      if (day.isAfter(end)) break;
      for (final r in overlapping) {
        (instalmentDays[r.id] ??= []).add(day);
      }
      final late = day.isBefore(today);
      final event = flow(
          key: 'inst:${plan.id}:${s.number}',
          source: 'inst:${plan.id}',
          day: late ? today : day,
          label: 'Cuota ${s.number}/${plan.count} · ${plan.name}',
          type: TransactionType.expense,
          amount: s.installment.amountMinor,
          from: plan.accountId,
          certainty: ForecastCertainty.confirmed,
          detail: late ? 'Vencía el ${shortDay(day)}; aún no está pagada' : 'Pago a plazos');
      if (event != null) events.add(event);
    }
  }

  // 2. Periodic payments. An occurrence that already arrived (posted by the app or downloaded from the bank, a few
  // days early or late) is replaced by the real movement; one that is late by up to a week still counts, today.
  const grace = 7;
  final used = <String>{};
  final ruleLike = <String>{};
  bool similar(int a, int b) => (a - b).abs() <= math.max(100, (b * 0.15).round());
  for (final rule in data.recurringMovements) {
    if (!rule.isActive || rule.amountMinor <= 0) continue;
    final destination = rule.type == TransactionType.transfer ? rule.destinationAccountId : null;
    final candidates = [
      for (final t in data.transactions)
        if (t.recurringMovementId == rule.id ||
            (t.sourceAccountId == rule.sourceAccountId &&
                t.type == rule.type &&
                (rule.type != TransactionType.transfer || t.destinationAccountId == destination) &&
                similar(t.amountMinor, rule.amountMinor)))
          t
    ];
    ruleLike.addAll(candidates.map((t) => t.id));
    if (!tracked.containsKey(rule.sourceAccountId) && (destination == null || !tracked.containsKey(destination))) continue;
    final window = rule.frequency == Frequency.weekly ? 3 : 6;
    final source = 'rec:${rule.id}';
    var next = rule.nextDueDate;
    for (var i = 0; i < 400; i++) {
      final day = forecastDay(next);
      if (day.isAfter(end) || (rule.endDate != null && day.isAfter(forecastDay(rule.endDate!)))) break;
      next = nextDueDate(next, rule.frequency, rule.interval);
      final late = _between(day, today);
      if (late > grace) continue;
      if (instalmentDays[rule.id]?.any((d) => _between(d, day).abs() <= window) ?? false) continue;
      final arrived = candidates.where((t) {
        final gap = _between(day, forecastDay(t.date)).abs();
        return !used.contains(t.id) && gap <= (t.recurringMovementId == rule.id ? 2 * window : window);
      }).firstOrNull;
      if (arrived != null) {
        used.add(arrived.id);
        continue;
      }
      final event = flow(
          key: 'rec:${rule.id}:${isoDay(day)}',
          source: source,
          day: late > 0 ? today : day,
          label: rule.name.trim().isEmpty ? rule.descriptionText : rule.name,
          type: rule.type,
          amount: settings.amounts[source] ?? rule.amountMinor,
          from: rule.sourceAccountId,
          to: destination,
          certainty: ForecastCertainty.confirmed,
          categoryId: rule.categoryId,
          detail: late > 0 ? 'Previsto el ${shortDay(day)}; aún no ha llegado' : 'Pago periódico ${rule.frequency.title.toLowerCase()}');
      if (event != null) events.add(event);
    }
  }

  // History: how far back the movements of these accounts go.
  final history = data.transactions.where((t) => tracked.containsKey(t.sourceAccountId) && !t.date.isAfter(now)).toList();
  final earliest = history.isEmpty ? today : forecastDay(history.last.date);
  final historyDays = _between(earliest, today);
  bool everyday(Transaction t) =>
      tracked.containsKey(t.sourceAccountId) &&
      !t.date.isAfter(now) &&
      t.recurringMovementId == null &&
      t.installmentPlanId == null &&
      !ruleLike.contains(t.id) &&
      !t.awaitsBank &&
      data.category(t.categoryId)?.kind != CategoryKind.transfer;

  // 3. Repeated in the history: about once a month, a similar amount on a similar day (a salary, a bill without a
  // periodic payment). An estimate, never confirmed.
  final repeated = <String>{};
  final proposals = <HistoryProposal>[];
  final irregular = <String>[];
  if (settings.useHistory) {
    final since = now.subtract(const Duration(days: 185));
    final groups = <String, List<Transaction>>{};
    for (final t in history) {
      if (t.date.isBefore(since) || !everyday(t) || !(t.type.countsAsIncome || t.type.countsAsExpense) || t.amountMinor <= 0) continue;
      final words = patternWords(t.descriptionText);
      if (words.isEmpty) continue;
      (groups['${t.sourceAccountId}|${t.type.countsAsIncome ? 'in' : 'out'}|$words'] ??= []).add(t);
    }
    // Movements already recorded with a later date, by group: real, so they take the place of that month's estimate.
    final recordedLater = <String, List<Transaction>>{};
    for (final t in data.transactions) {
      if (!t.date.isAfter(now)) break; // newest first
      if (!tracked.containsKey(t.sourceAccountId) || !(t.type.countsAsIncome || t.type.countsAsExpense)) continue;
      (recordedLater['${t.sourceAccountId}|${t.type.countsAsIncome ? 'in' : 'out'}|${patternWords(t.descriptionText)}'] ??= []).add(t);
    }
    for (final MapEntry(key: group, value: items) in groups.entries) {
      final months = items.map((t) => monthKey(t.date)).toSet();
      final isIncome = items.first.type.countsAsIncome;
      final label = bankTitle(items.first.descriptionText, isBanking: items.first.isBanking);
      bool regular() {
        if (items.length < 3 || months.length < 3 || items.length > months.length + 1) return false;
        if (_between(forecastDay(items.first.date), today) > 45) return false;
        final amounts = items.map((t) => t.amountMinor).toList()..sort();
        final typical = amounts[amounts.length ~/ 2];
        if (amounts.any((a) => (a - typical).abs() > math.max(100, (typical * 0.2).round()))) return false;
        final daysOfMonth = items.map((t) => t.date.toLocal().day).toList()..sort();
        return daysOfMonth.last - daysOfMonth.first <= 8;
      }

      if (!regular()) {
        // An income seen in two or more months, but without a steady amount or day: never assumed to come back.
        if (isIncome && months.length >= 2) irregular.add(label);
        continue;
      }
      final amounts = items.map((t) => t.amountMinor).toList()..sort();
      final typical = amounts[amounts.length ~/ 2];
      final daysOfMonth = items.map((t) => t.date.toLocal().day).toList()..sort();
      final dayOfMonth = daysOfMonth[daysOfMonth.length ~/ 2];
      repeated.addAll(items.map((t) => t.id));
      final latest = items.first;
      final source = 'pat:$group';
      final first = forecastDay(items.last.date);
      final accepted = settings.accepted.contains(source);
      proposals.add(HistoryProposal(
          source: source,
          label: label,
          amountMinor: settings.amounts[source] ?? typical,
          dayOfMonth: dayOfMonth,
          accountId: latest.sourceAccountId!,
          isIncome: isIncome,
          times: items.length));
      for (var offset = 0;; offset++) {
        final year = today.year + (today.month - 1 + offset) ~/ 12, month = (today.month - 1 + offset) % 12 + 1;
        final day = DateTime.utc(year, month, math.min(dayOfMonth, _daysInMonth(year, month)));
        if (day.isAfter(end)) break;
        final arrived = [...items, ...?recordedLater[group]].any((t) => monthKey(t.date) == year * 12 + month - 1 || _between(day, forecastDay(t.date)).abs() <= 6);
        if (arrived) continue;
        final late = _between(day, today);
        if (late > grace) {
          limitations.add('«$label» no ha llegado este mes (solía llegar hacia el día $dayOfMonth): no se cuenta.');
          continue;
        }
        final event = flow(
            key: 'pat:$group:${isoDay(day)}',
            source: source,
            day: late > 0 ? today : day,
            label: label,
            type: latest.type,
            amount: settings.amounts[source] ?? typical,
            from: latest.sourceAccountId,
            certainty: ForecastCertainty.estimated,
            categoryId: latest.categoryId,
            detail: [
              late > 0 ? 'Solía llegar hacia el día $dayOfMonth; aún no ha llegado' : 'Se repite cada mes desde ${shortDay(first)} (${items.length} veces)',
              accepted ? 'confirmado por ti' : 'detectado en tu historial, por revisar',
            ].join(' · '));
        if (event != null) events.add(event);
      }
    }
  }

  // 3b. Incomes the person expects and wrote for the forecast. A real income of a similar amount in that account
  // around its day (a week before or after) takes its place, so it is never counted twice.
  for (final income in settings.incomes) {
    if (!tracked.containsKey(income.accountId)) continue;
    final source = 'plan:${income.id}';
    for (var offset = -1;; offset++) {
      final year = today.year + (today.month - 1 + offset) ~/ 12, month = (today.month - 1 + offset) % 12 + 1;
      final day = DateTime.utc(year, month, math.min(income.dayOfMonth, _daysInMonth(year, month)));
      if (day.isAfter(end)) break;
      final late = _between(day, today);
      if (late > grace) continue;
      // Any real income: also one recorded with a later date, which already counts as it is.
      final arrived = data.transactions.any((t) =>
          t.sourceAccountId == income.accountId &&
          t.type.countsAsIncome &&
          (t.amountMinor - income.amountMinor).abs() <= math.max(100, (income.amountMinor * 0.25).round()) &&
          _between(day, forecastDay(t.date)).abs() <= grace);
      if (arrived) continue;
      events.add(ForecastEvent(
          key: '$source:${isoDay(day)}',
          source: source,
          day: late > 0 ? today : day,
          label: income.name,
          amountMinor: income.amountMinor,
          accountId: income.accountId,
          certainty: ForecastCertainty.assumed,
          detail: late > 0 ? 'Lo esperabas el ${shortDay(day)}; aún no ha llegado' : 'Ingreso que esperas cada mes, el día ${income.dayOfMonth}',
          excluded: settings.excluded.contains(source)));
    }
  }

  // 4. Variable spending. A budget already plans the spending of its category: what it still allows, minus the
  // payments of that category already in the forecast, so nothing is counted twice. Without a budget, the usual
  // everyday spending of the last months, leaving out what is periodic or repeated.
  final budgetedNow = {
    for (final b in calc.budgetProgress(DateTime(today.year, today.month), asOf: now))
      if (b.limitMinor > 0) b.category.id
  };
  var unbudgetedMonthly = 0;
  if (settings.useHistory && historyDays >= 60) {
    final totals = <int>[];
    for (var back = 1; back <= 3; back++) {
      final start = DateTime(today.year, today.month - back);
      if (forecastDay(start).isBefore(earliest)) break;
      final key = monthKey(start);
      totals.add(history
          .where((t) => monthKey(t.date) == key && t.type.countsAsExpense && everyday(t) && !repeated.contains(t.id) && !budgetedNow.contains(t.categoryId))
          .fold(0, (sum, t) => sum + FinanceCalculator.budgetExpenseAmount(t)));
    }
    totals.sort();
    if (totals.isNotEmpty) unbudgetedMonthly = totals[totals.length ~/ 2];
  } else if (settings.useHistory) {
    limitations.add('Poco historial ($historyDays días): no se estima el gasto variable; cuentan los pagos previstos y tus presupuestos.');
  } else {
    limitations.add('Sin historial: solo cuentan los pagos previstos, lo ya apuntado y tus presupuestos.');
  }

  // Which accounts the everyday spending usually comes from.
  final share = <String, int>{};
  for (final t in history) {
    if (t.date.isBefore(now.subtract(const Duration(days: 90))) || !t.type.countsAsExpense || !everyday(t) || repeated.contains(t.id)) continue;
    share[t.sourceAccountId!] = (share[t.sourceAccountId!] ?? 0) + FinanceCalculator.budgetExpenseAmount(t);
  }
  final fallback = starts.where((s) => s.account.type == AccountType.checking).firstOrNull?.account.id ?? starts.firstOrNull?.account.id;
  if (share.values.every((v) => v <= 0) && fallback != null) {
    share
      ..clear()
      ..[fallback] = 1;
  }
  final shareTotal = share.values.fold(0, (a, b) => a + b);

  var budgetsThisMonth = 0;
  for (var offset = 0;; offset++) {
    final year = today.year + (today.month - 1 + offset) ~/ 12, month = (today.month - 1 + offset) % 12 + 1;
    final first = offset == 0 ? _plus(today, 1) : DateTime.utc(year, month);
    if (first.isAfter(end) || shareTotal <= 0) break;
    final dim = _daysInMonth(year, month);
    final last = DateTime.utc(year, month, dim).isAfter(end) ? end : DateTime.utc(year, month, dim);
    final spanDays = _between(first, last) + 1;
    if (spanDays <= 0) continue;
    int total;
    if (settings.variableMonthlyMinor != null) {
      total = settings.variableMonthlyMinor! * spanDays ~/ dim;
    } else {
      var fromBudgets = 0;
      for (final b in calc.budgetProgress(DateTime(year, month), asOf: now)) {
        if (b.limitMinor <= 0) continue;
        final planned = events
            .where((e) =>
                !e.excluded &&
                e.certainty != ForecastCertainty.recorded &&
                e.categoryId == b.category.id &&
                e.amountMinor < 0 &&
                e.day.year == year &&
                e.day.month == month)
            .fold(0, (sum, e) => sum - e.amountMinor);
        fromBudgets += math.max(0, b.limitMinor - b.spentMinor - planned);
      }
      if (offset == 0) budgetsThisMonth = fromBudgets;
      // What a budget still allows spreads over the days left of its month; the usual spending without a budget, by days.
      total = fromBudgets * spanDays ~/ math.max(1, dim - first.day + 1) + unbudgetedMonthly * spanDays ~/ dim;
    }
    if (total <= 0) continue;
    final excluded = settings.excluded.contains('var');
    var given = 0;
    for (var d = 0; d < spanDays; d++) {
      final day = _plus(first, d);
      final upTo = total * (d + 1) ~/ spanDays;
      final todayAmount = upTo - given;
      given = upTo;
      if (todayAmount <= 0) continue;
      var placed = 0;
      final accounts = share.entries.where((e) => e.value > 0).toList();
      for (var i = 0; i < accounts.length; i++) {
        final part = i == accounts.length - 1 ? todayAmount - placed : todayAmount * accounts[i].value ~/ shareTotal;
        placed += part;
        if (part <= 0) continue;
        events.add(ForecastEvent(
            key: 'var:${isoDay(day)}:${accounts[i].key}',
            source: 'var',
            day: day,
            label: 'Gasto variable estimado',
            amountMinor: -part,
            accountId: accounts[i].key,
            certainty: ForecastCertainty.estimated,
            detail: settings.variableMonthlyMinor != null ? 'Con el gasto mensual que indicaste' : 'Lo que dejan tus presupuestos y tu gasto habitual',
            excluded: excluded));
      }
    }
  }

  // 5. Charges the bank holds: they will be booked, so they leave today.
  for (final (accountId, amount) in holds) {
    if (!tracked.containsKey(accountId) || amount >= 0) continue;
    events.add(ForecastEvent(
        key: 'hold:$accountId:${events.length}',
        source: 'hold',
        day: today,
        label: 'Cargo retenido por el banco',
        amountMinor: amount,
        accountId: accountId,
        certainty: ForecastCertainty.confirmed,
        detail: 'El banco lo retiene y aún no lo ha cargado'));
  }

  // The real balance of the last days: today's starting balance, going back through the real movements, so the
  // line meets today's figure (a bank balance received today is not contradicted by an older calculation).
  final pastBalances = <String, List<int>>{}, pastReserved = <String, List<int>>{};
  final since = now.subtract(const Duration(days: ForecastPlan.pastDays + 2));
  final recent = [for (final t in data.transactions) if (!t.date.isAfter(now) && t.date.isAfter(since)) t];
  for (final start in starts) {
    final id = start.account.id;
    int effect(Transaction t) {
      final amount = t.amountMinor.abs();
      if (t.type == TransactionType.transfer) return (t.destinationAccountId == id && t.sourceAccountId != id ? amount : 0) - (t.sourceAccountId == id ? amount : 0);
      if (t.sourceAccountId != id) return 0;
      return t.type.countsAsIncome ? amount : -amount;
    }

    final balances = <int>[], reserved = <int>[];
    for (var back = ForecastPlan.pastDays; back >= 1; back--) {
      final day = _plus(today, -back);
      final close = DateTime(day.year, day.month, day.day, 23, 59, 59);
      balances.add(start.balanceMinor - recent.where((t) => t.date.isAfter(close)).fold(0, (sum, t) => sum + effect(t)));
      var held = 0;
      for (final fund in data.reservedFunds) {
        if (fund.accountId == null || (fund.createdAt != null && fund.createdAt!.isAfter(close))) continue;
        held += reservedBalances(fund.accountId!, fund.amountMinor, calc.reserveEntries(fund), through: close)?[start.account.id] ?? 0;
      }
      reserved.add(held);
    }
    pastBalances[start.account.id] = balances;
    pastReserved[start.account.id] = reserved;
  }
  if (irregular.isNotEmpty) {
    limitations.add('Ingresos sin día o importe fijos (${irregular.take(2).map((l) => '«$l»').join(', ')}): no se cuentan. Añádelos como ingreso previsto si los esperas.');
  }

  events.sort((a, b) => a.day.compareTo(b.day));
  return ForecastPlan(
    data: data,
    now: now,
    today: today,
    end: end,
    settings: settings,
    starts: starts,
    events: events,
    limitations: limitations,
    funds: funds,
    variableMonthlyMinor: budgetsThisMonth + unbudgetedMonthly,
    variableFromBudgetsMinor: budgetsThisMonth,
    historyDays: historyDays,
    proposals: proposals,
    irregularIncomes: irregular,
    pastBalances: pastBalances,
    pastReserved: pastReserved,
  );
}

/// An account that would go below zero, the first day it happens and the item that takes it there.
class Shortfall {
  Shortfall({required this.account, required this.day, required this.balanceMinor, this.cause, required this.elsewhereFreeMinor});
  final Account account;
  final DateTime day;
  final int balanceMinor;
  final ForecastEvent? cause;

  /// Free money in the other accounts that day.
  final int elsewhereFreeMinor;
}

/// Day by day: balances and free money (balance minus what is reserved), per account and in total.
class ForecastResult {
  ForecastResult({
    required this.plan,
    required this.events,
    required this.balances,
    required this.reserved,
  });
  final ForecastPlan plan;
  final List<ForecastEvent> events;

  /// account → value of each day, from today (index 0) to the end of the horizon.
  final Map<String, List<int>> balances;
  final Map<String, List<int>> reserved;

  int get length => plan.days + 1;
  DateTime dayAt(int index) => _plus(plan.today, index);
  int indexOf(DateTime day) => _between(plan.today, forecastDay(day)).clamp(0, plan.days);

  List<int> balance([String? accountId]) => _sum(accountId, (id, i) => balances[id]![i]);
  List<int> free([String? accountId]) => _sum(accountId, (id, i) => balances[id]![i] - reserved[id]![i]);
  List<int> _sum(String? accountId, int Function(String, int) value) => [
        for (var i = 0; i < length; i++) [for (final id in balances.keys) if (accountId == null || id == accountId) value(id, i)].fold(0, (a, b) => a + b)
      ];

  late final List<int> totalFree = free();

  /// The lowest free money and the first day it happens.
  late final (int, DateTime) minimum = () {
    var low = 0;
    for (var i = 1; i < totalFree.length; i++) {
      if (totalFree[i] < totalFree[low]) low = i;
    }
    return (totalFree[low], dayAt(low));
  }();

  int get endFree => totalFree.last;

  /// The first day the free money goes below the cushion (below zero without one).
  DateTime? cushionBreach([int? cushion]) {
    final limit = cushion ?? plan.settings.cushionMinor;
    for (var i = 0; i < totalFree.length; i++) {
      if (totalFree[i] < limit) return dayAt(i);
    }
    return null;
  }

  late final List<Shortfall> shortfalls = () {
    final found = <Shortfall>[];
    for (final start in plan.starts) {
      final values = balances[start.account.id]!;
      for (var i = 0; i < values.length; i++) {
        if (values[i] >= 0 || (i > 0 && values[i - 1] < 0) || (i == 0 && start.balanceMinor < 0)) continue;
        final day = dayAt(i);
        final that = events.where((e) => e.day == day && e.accountId == start.account.id && e.amountMinor < 0).toList()
          // The planned item explains it better than the variable spending; then the biggest one.
          ..sort((a, b) => a.isVariable != b.isVariable ? (a.isVariable ? 1 : -1) : a.amountMinor.compareTo(b.amountMinor));
        final elsewhere = [
          for (final other in plan.starts)
            if (other.account.id != start.account.id) math.max(0, balances[other.account.id]![i] - reserved[other.account.id]![i])
        ].fold(0, (a, b) => a + b);
        found.add(Shortfall(account: start.account, day: day, balanceMinor: values[i], cause: that.firstOrNull, elsewhereFreeMinor: elsewhere));
        break;
      }
    }
    found.sort((a, b) => a.day.compareTo(b.day));
    return found;
  }();

  /// The biggest planned outflow (not the variable spending) up to a day: what most explains a low point.
  ForecastEvent? mainOutflowUntil(DateTime day) {
    final options = events.where((e) => !e.isVariable && !e.isTransfer && e.amountMinor < 0 && !e.day.isAfter(day)).toList()
      ..sort((a, b) => a.amountMinor.compareTo(b.amountMinor));
    return options.firstOrNull;
  }

  /// The real values of the last days (oldest first), as they were: not estimated.
  List<int> pastBalance([String? accountId]) => _past(accountId, (id, i) => plan.pastBalances[id]![i]);
  List<int> pastFree([String? accountId]) => _past(accountId, (id, i) => plan.pastBalances[id]![i] - plan.pastReserved[id]![i]);
  List<int> _past(String? accountId, int Function(String, int) value) => [
        for (var i = 0; i < ForecastPlan.pastDays; i++)
          [for (final id in plan.pastBalances.keys) if (accountId == null || id == accountId) value(id, i)].fold(0, (a, b) => a + b)
      ];

  /// From today to [day]: what comes in, what goes out and how sure each part is.
  ForecastChange explain(DateTime day, [String? accountId]) {
    final until = forecastDay(day);
    int effect(ForecastEvent e) {
      if (accountId == null) return e.isTransfer ? 0 : e.amountMinor;
      if (e.accountId == accountId) return e.amountMinor;
      return e.destinationId == accountId ? -e.amountMinor : 0;
    }

    final items = [
      for (final e in events)
        if (!e.day.isAfter(until) && !e.isVariable && effect(e) != 0) (e, effect(e))
    ];
    final variable = events.where((e) => e.isVariable && !e.day.isAfter(until) && (accountId == null || e.accountId == accountId)).fold(0, (sum, e) => sum + e.amountMinor);
    final index = indexOf(until);
    return ForecastChange(
      day: until,
      startFree: free(accountId).first,
      endFree: free(accountId)[index],
      endBalance: balance(accountId)[index],
      incomes: [for (final i in items) if (i.$2 > 0) i],
      expenses: [for (final i in items) if (i.$2 < 0) i],
      variableMinor: variable,
    );
  }

  List<ForecastEvent> on(DateTime day, [String? accountId]) =>
      [for (final e in events) if (e.day == day && (accountId == null || e.accountId == accountId || e.destinationId == accountId)) e];
}

/// Runs the forecast day by day with [events] (the active ones of the plan when not given).
ForecastResult simulateForecast(ForecastPlan plan, [List<ForecastEvent>? events]) {
  final used = events ?? plan.active;
  final balance = {for (final s in plan.starts) s.account.id: s.balanceMinor};
  final reserve = {for (final s in plan.starts) s.account.id: s.reservedMinor};
  final balances = {for (final id in balance.keys) id: <int>[]};
  final reserved = {for (final id in balance.keys) id: <int>[]};
  final byDay = <int, List<ForecastEvent>>{};
  for (final e in used) {
    final index = _between(plan.today, e.day);
    if (index < 0 || index > plan.days) continue;
    (byDay[index] ??= []).add(e);
  }
  for (var i = 0; i <= plan.days; i++) {
    for (final e in byDay[i] ?? const <ForecastEvent>[]) {
      if (balance.containsKey(e.accountId)) balance[e.accountId] = balance[e.accountId]! + e.amountMinor;
      if (e.destinationId != null && balance.containsKey(e.destinationId)) balance[e.destinationId!] = balance[e.destinationId]! - e.amountMinor;
      for (final MapEntry(key: account, value: change) in e.reserveChanges.entries) {
        if (reserve.containsKey(account)) reserve[account] = math.max(0, reserve[account]! + change);
      }
    }
    for (final id in balance.keys) {
      balances[id]!.add(balance[id]!);
      reserved[id]!.add(reserve[id]!);
    }
  }
  return ForecastResult(plan: plan, events: [for (final e in used) if (_between(plan.today, e.day) <= plan.days) e], balances: balances, reserved: reserved);
}

/// The base forecast with a simulation's changes. The plan and the finances are left as they were.
List<ForecastEvent> scenarioEvents(ForecastPlan plan, Scenario scenario) {
  var events = [...plan.active];
  final source = 'sim:${scenario.id}';
  DateTime clamp(DateTime day) => day.isBefore(plan.today) ? plan.today : day;
  Iterable<DateTime> monthly(DateTime from) sync* {
    final first = clamp(from);
    for (var offset = 0;; offset++) {
      final year = first.year + (first.month - 1 + offset) ~/ 12, month = (first.month - 1 + offset) % 12 + 1;
      final day = DateTime.utc(year, month, math.min(from.day, _daysInMonth(year, month)));
      if (day.isAfter(plan.end)) return;
      if (!day.isBefore(first)) yield day;
    }
  }

  for (final (index, change) in scenario.changes.indexed) {
    final account = change.accountId != null && plan.account(change.accountId!) != null ? change.accountId! : plan.defaultAccountId;
    if (account == null) continue;
    final key = '$source:$index';
    switch (change.kind) {
      case ScenarioKind.purchase:
        final covered = change.reserveId == null ? 0 : math.min(change.amountMinor, plan.funds[change.reserveId]?[account] ?? 0);
        final fund = plan.data.reservedFunds.where((f) => f.id == change.reserveId).firstOrNull;
        events.add(ForecastEvent(
            key: key,
            source: source,
            day: clamp(change.day),
            label: scenario.name,
            amountMinor: -change.amountMinor,
            accountId: account,
            certainty: ForecastCertainty.simulated,
            reserveChanges: covered > 0 ? {account: -covered} : const {},
            detail: covered > 0 ? 'Paga ${money(covered)} con la reserva «${fund?.name ?? ''}»' : 'Compra simulada'));
      case ScenarioKind.monthlyExpense:
        for (final day in monthly(change.day)) {
          events.add(ForecastEvent(
              key: '$key:${isoDay(day)}',
              source: source,
              day: day,
              label: scenario.name,
              amountMinor: -change.amountMinor,
              accountId: account,
              certainty: ForecastCertainty.simulated,
              detail: 'Gasto mensual simulado'));
        }
      case ScenarioKind.incomeChange:
        if (change.incomeSource != null && events.any((e) => e.source == change.incomeSource)) {
          events = [
            for (final e in events)
              if (e.source != change.incomeSource)
                e
              else if (!_plus(e.day, change.delayDays).isAfter(plan.end))
                e.copyWith(
                    day: _plus(e.day, change.delayDays),
                    amountMinor: math.max(0, e.amountMinor + change.amountMinor),
                    certainty: ForecastCertainty.simulated,
                    detail: [
                      if (change.delayDays > 0) 'Llega ${change.delayDays} días más tarde',
                      if (change.amountMinor != 0) 'Cambia en ${money(change.amountMinor, signed: true)}',
                    ].join(' · '))
          ];
        } else if (change.amountMinor != 0) {
          for (final day in monthly(change.day)) {
            events.add(ForecastEvent(
                key: '$key:${isoDay(day)}',
                source: source,
                day: day,
                label: scenario.name,
                amountMinor: change.amountMinor,
                accountId: account,
                certainty: ForecastCertainty.simulated,
                detail: change.amountMinor > 0 ? 'Ingreso mensual simulado' : 'Menos ingresos cada mes (simulado)'));
          }
        }
      case ScenarioKind.reserveContribution:
        final reserveId = change.reserveId;
        final into = reserveId == null ? null : plan.reserveAccount(reserveId);
        if (into == null || plan.account(into) == null) continue;
        final from = change.accountId != null && plan.account(change.accountId!) != null ? change.accountId! : into;
        for (final day in change.monthly ? monthly(change.day) : [clamp(change.day)]) {
          events.add(ForecastEvent(
              key: '$key:${isoDay(day)}',
              source: source,
              day: day,
              label: scenario.name,
              amountMinor: from == into ? 0 : -change.amountMinor,
              accountId: from,
              destinationId: from == into ? null : into,
              certainty: ForecastCertainty.simulated,
              reserveChanges: {into: change.amountMinor},
              detail: 'Aparta ${money(change.amountMinor)} en la reserva (simulado)'));
        }
    }
  }
  events.sort((a, b) => a.day.compareTo(b.day));
  return events;
}

/// A simulation against the base forecast: the low point, the end, the cushion, the accounts, reserves and goals
/// it touches, in a few plain sentences.
class ScenarioComparison {
  ScenarioComparison(this.base, this.result, this.scenario);
  final ForecastResult base, result;
  final Scenario scenario;

  ForecastPlan get plan => base.plan;
  int get minimumChange => result.minimum.$1 - base.minimum.$1;
  int get endChange => result.endFree - base.endFree;

  /// Accounts whose lowest balance goes down with the simulation.
  List<Account> get affectedAccounts => [
        for (final start in plan.starts)
          if (_low(result, start.account.id) < _low(base, start.account.id) || result.balances[start.account.id]!.last < base.balances[start.account.id]!.last)
            start.account
      ];

  static int _low(ForecastResult r, String id) => r.balances[id]!.reduce(math.min);

  /// Goals that follow the balance of an affected account.
  List<SavingsGoal> get affectedGoals {
    final ids = affectedAccounts.map((a) => a.id).toSet();
    return [for (final g in plan.data.goals) if (!g.isCompleted && ids.contains(g.linkedAccountId)) g];
  }

  /// Reserved money the simulation spends (negative) or sets aside (positive).
  int get reserveChange {
    final before = base.reserved.values.fold(0, (sum, v) => sum + v.last), after = result.reserved.values.fold(0, (sum, v) => sum + v.last);
    return after - before;
  }

  List<Shortfall> get newShortfalls => [
        for (final s in result.shortfalls)
          if (!base.shortfalls.any((b) => b.account.id == s.account.id && !b.day.isAfter(s.day))) s
      ];

  List<String> get summary {
    final cushion = plan.settings.cushionMinor;
    final (low, lowDay) = result.minimum;
    final breach = result.cushionBreach(), baseBreach = base.cushionBreach();
    return [
      if (breach == null)
        cushion > 0
            ? 'Tu disponible libre se mantiene por encima del colchón de ${money(cushion)}.'
            : 'Tu disponible libre no baja de cero. Define un colchón para comprobar un margen.'
      else if (baseBreach != null && !baseBreach.isAfter(breach))
        'Ya sin la simulación bajarías ${cushion > 0 ? 'del colchón' : 'de cero'} el ${shortDay(baseBreach)}.'
      else
        'Bajarías ${cushion > 0 ? 'del colchón' : 'de cero'} el ${shortDay(breach)}.',
      'Mínimo previsto: ${money(low)} el ${shortDay(lowDay)} (${money(minimumChange, signed: true)} frente a la previsión).',
      'Al final del periodo: ${money(endChange, signed: true)}.',
      if (reserveChange == 0)
        'Tus reservas no se tocan.'
      else if (reserveChange < 0)
        'Usa ${money(-reserveChange)} de tus reservas.'
      else
        'Aparta ${money(reserveChange)} más en tus reservas.',
      for (final s in newShortfalls) '«${s.account.name}» se quedaría sin saldo el ${shortDay(s.day)}.',
      for (final g in affectedGoals) 'Afecta a tu objetivo «${g.name}»: su cuenta tendría menos dinero.',
    ];
  }
}

/// Don Bigotes' notes about the forecast: an account that could run out for a charge, and the free money going below
/// the cushion. Facts with the assumption behind them; he never moves money.
List<CompanionNote> forecastNotes(ForecastResult result, {int days = 30}) {
  final plan = result.plan;
  final limit = _plus(plan.today, days);
  final notes = <CompanionNote>[];
  for (final s in result.shortfalls) {
    if (s.day.isAfter(limit) || s.cause == null || s.cause!.isVariable) continue;
    final cause = s.cause!;
    final missing = -s.balanceMinor;
    notes.add(CompanionNote(
      id: 'forecast:account:${s.account.id}:${isoDay(s.day)}',
      title: '«${s.account.name}» podría quedarse sin saldo el ${shortDay(s.day)}',
      detail: '${cause.label} (${money(-cause.amountMinor)}, ${cause.certainty.title.toLowerCase()}). '
          '${s.elsewhereFreeMinor >= missing ? 'En otras cuentas tienes dinero libre suficiente.' : 'Faltarían ${money(missing)}.'}',
      tab: 0,
      urgent: _between(plan.today, s.day) <= 3,
    ));
  }
  final cushion = plan.settings.cushionMinor;
  final breach = result.cushionBreach();
  if (cushion > 0 && breach != null && !breach.isAfter(limit)) {
    final (low, lowDay) = result.minimum;
    final cause = result.mainOutflowUntil(breach);
    notes.add(CompanionNote(
      id: 'forecast:cushion:${isoDay(breach)}',
      title: 'Tu disponible podría bajar del colchón el ${shortDay(breach)}',
      detail: 'Mínimo previsto ${money(low)} el ${shortDay(lowDay)}${cause == null ? '' : ', sobre todo por ${cause.label} (${cause.certainty.title.toLowerCase()})'}.',
      tab: 0,
    ));
  }
  return notes;
}

/// What explains the money of a day: from today, the incomes and the payments in between (with how sure each one
/// is) and the estimated variable spending.
class ForecastChange {
  ForecastChange(
      {required this.day,
      required this.startFree,
      required this.endFree,
      required this.endBalance,
      required this.incomes,
      required this.expenses,
      required this.variableMinor});
  final DateTime day;
  final int startFree, endFree, endBalance;
  final List<(ForecastEvent, int)> incomes, expenses;
  final int variableMinor;

  int get incomeMinor => incomes.fold(0, (sum, i) => sum + i.$2);
  int get expenseMinor => expenses.fold(0, (sum, i) => sum + i.$2);

  /// The part that is sure (recorded or confirmed) and the part that is estimated, assumed or simulated.
  int get sureMinor => [...incomes, ...expenses].where((i) => i.$1.certainty == ForecastCertainty.recorded || i.$1.certainty == ForecastCertainty.confirmed).fold(0, (s, i) => s + i.$2);
  int get estimatedMinor => incomeMinor + expenseMinor - sureMinor + variableMinor;
}

enum MomentKind { income, lowest, overdraft, cushion }

/// A date worth pointing out, from the forecast itself.
class ForecastMoment {
  const ForecastMoment({required this.kind, required this.day, required this.title, required this.detail, this.accountId});
  final MomentKind kind;
  final DateTime day;
  final String title;
  final String detail;
  final String? accountId;
}

/// The dates Don Bigotes points out: the expected incomes, the lowest free money (if lower than today), a possible
/// overdraft and the cushion. All of them are results of the forecast, never guesses.
List<ForecastMoment> forecastMoments(ForecastResult r) {
  final plan = r.plan;
  final moments = <ForecastMoment>[];
  final incomeDays = <DateTime, List<ForecastEvent>>{};
  for (final e in r.events) {
    if (e.amountMinor > 0 && !e.isTransfer && !e.isVariable) (incomeDays[e.day] ??= []).add(e);
  }
  for (final MapEntry(key: day, value: list) in incomeDays.entries.take(2)) {
    final main = (list..sort((a, b) => b.amountMinor.compareTo(a.amountMinor))).first;
    final total = list.fold(0, (sum, e) => sum + e.amountMinor);
    moments.add(ForecastMoment(
      kind: MomentKind.income,
      day: day,
      title: 'Ingreso esperado',
      detail: '${main.label}: ${money(total, signed: true)} (${main.certainty.title.toLowerCase()}). ${main.detail}',
      accountId: main.accountId,
    ));
  }
  final (low, lowDay) = r.minimum;
  // Only a real dip: at least 50 € or 5 % below today, not the small daily estimate.
  if (r.totalFree.first - low >= math.max(5000, (r.totalFree.first.abs() * 0.05).round())) {
    final cause = r.mainOutflowUntil(lowDay);
    final recovery = incomeDays.keys.where((d) => d.isAfter(lowDay)).firstOrNull;
    moments.add(ForecastMoment(
      kind: MomentKind.lowest,
      day: lowDay,
      title: 'Mínimo de disponible',
      detail: 'Tu dinero libre bajaría a ${money(low)}${cause == null ? '' : ', sobre todo por ${cause.label}'}.'
          '${recovery == null ? ' No hay ingresos previstos después en este periodo.' : ' Se recupera el ${shortDay(recovery)}.'}',
    ));
  }
  final negative = r.cushionBreach(0);
  for (final s in r.shortfalls) {
    if (s.cause == null || s.cause!.isVariable) continue;
    moments.add(ForecastMoment(
      kind: MomentKind.overdraft,
      day: s.day,
      title: 'Posible descubierto',
      detail: '«${s.account.name}» bajaría a ${money(s.balanceMinor)} por ${s.cause!.label} (${s.cause!.certainty.title.toLowerCase()}).'
          '${s.elsewhereFreeMinor >= -s.balanceMinor ? ' En otras cuentas tienes dinero libre suficiente.' : ''}',
      accountId: s.account.id,
    ));
  }
  if (negative != null && !r.shortfalls.any((s) => s.day == negative)) {
    moments.add(ForecastMoment(
        kind: MomentKind.overdraft, day: negative, title: 'Disponible por debajo de cero', detail: 'Tu dinero libre en total sería negativo desde ese día.'));
  }
  final cushion = plan.settings.cushionMinor;
  final breach = cushion > 0 ? r.cushionBreach() : null;
  if (breach != null && (negative == null || breach.isBefore(negative))) {
    moments.add(ForecastMoment(
        kind: MomentKind.cushion, day: breach, title: 'Por debajo del colchón', detail: 'Tu dinero libre bajaría de ${money(cushion)} desde ese día.'));
  }
  moments.sort((a, b) => a.day.compareTo(b.day));
  return moments;
}

/// Don Bigotes' summary of the forecast in one or two short sentences, from its results.
List<String> forecastSummary(ForecastResult r) {
  final plan = r.plan;
  final moments = forecastMoments(r);
  final income = moments.where((m) => m.kind == MomentKind.income).firstOrNull;
  final lowest = moments.where((m) => m.kind == MomentKind.lowest).firstOrNull;
  final overdraft = moments.where((m) => m.kind == MomentKind.overdraft).firstOrNull;
  final lines = <String>[];
  if (!plan.hasIncome) {
    lines.add('No veo ingresos previstos: la línea solo puede bajar. Revisa o añade tus ingresos.');
  } else if (lowest != null && income != null && lowest.day.isBefore(income.day)) {
    lines.add('Bajarías a ${money(r.minimum.$1)} el ${shortDay(lowest.day)} y te recuperas el ${shortDay(income.day)} con el ingreso esperado.');
  } else if (income != null) {
    lines.add('El ${shortDay(income.day)} esperas un ingreso; acabarías el periodo con ${money(r.endFree)} libres.');
  }
  if (overdraft != null) lines.add('Ojo al ${shortDay(overdraft.day)}: ${overdraft.title.toLowerCase()}.');
  if (lines.isEmpty) lines.add('Acabarías el periodo con ${money(r.endFree)} libres, sin bajar de ${money(r.minimum.$1)}.');
  return lines;
}
