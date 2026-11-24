import 'dart:math' as math;

import 'package:fl_chart/fl_chart.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../bank_activity.dart' show bankHolds;
import '../data.dart';
import '../finance.dart';
import '../forecast.dart';
import '../forecast_store.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'shell.dart' show DonBigotesMark;
import 'transaction_form.dart' show parseAmount;

/// Previsión: how much money there could be on a future date, from the real balance of the last days to the
/// estimate of the next ones, with Don Bigotes pointing out the dates that matter. Simulations are a secondary
/// action at the end, compared with this forecast; nothing here changes the finances.
class ForecastScreen extends StatefulWidget {
  const ForecastScreen({super.key, required this.repository, this.focusDay, this.focusAccountId});
  final FinanceRepository repository;

  /// Opened from a notice of Don Bigotes: the day and the account it is about.
  final DateTime? focusDay;
  final String? focusAccountId;

  @override
  State<ForecastScreen> createState() => _ForecastScreenState();
}

class _ForecastScreenState extends State<ForecastScreen> {
  String? scenarioId;
  String? accountId;
  DateTime? selectedDay;

  Object? _planFrom, _planSettings, _planActivity;
  ForecastPlan? _plan;
  ForecastResult? _base;

  FinanceRepository get repository => widget.repository;

  @override
  void initState() {
    super.initState();
    accountId = widget.focusAccountId;
    selectedDay = widget.focusDay == null ? null : forecastDay(widget.focusDay!);
  }

  /// One plan per version of the finances, of the assumptions and of the bank reports.
  (ForecastPlan, ForecastResult)? _forecast() {
    final data = repository.finances, store = repository.forecast;
    if (data == null || store == null) return null;
    if (!identical(data, _planFrom) || !identical(store.settings, _planSettings) || !identical(repository.bankActivity, _planActivity)) {
      final holds = [
        for (final h in bankHolds(data, repository.bankActivity))
          if (h.movement.signedAmountMinor < 0) (h.account.id, h.movement.signedAmountMinor)
      ];
      _plan = buildForecast(FinanceCalculator(data), DateTime.now(), store.settings, holds: holds);
      _base = simulateForecast(_plan!);
      _planFrom = data;
      _planSettings = store.settings;
      _planActivity = repository.bankActivity;
    }
    return (_plan!, _base!);
  }

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: Listenable.merge([repository, if (repository.forecast != null) repository.forecast!]),
      builder: (context, _) {
        final forecast = _forecast();
        final store = repository.forecast;
        return Scaffold(
          appBar: AppBar(title: const Text('Previsión'), actions: [
            if (forecast != null && store != null)
              IconButton(tooltip: 'Supuestos', icon: const Icon(Icons.tune), onPressed: () => _assumptions(forecast.$1, store)),
          ]),
          body: forecast == null || store == null
              ? const Center(child: CircularProgressIndicator())
              : _body(context, forecast.$1, forecast.$2, store),
        );
      },
    );
  }

  /// By default, what there would be at the end of this month (or of the horizon, if sooner).
  DateTime _defaultDay(ForecastPlan plan) {
    final monthEnd = DateTime.utc(plan.today.year, plan.today.month + 1, 0);
    final day = monthEnd.isAfter(plan.end) ? plan.end : monthEnd;
    return day == plan.today ? plan.end : day;
  }

  Widget _body(BuildContext context, ForecastPlan plan, ForecastResult base, ForecastStore store) {
    final hint = Theme.of(context).hintColor;
    if (plan.starts.isEmpty) {
      return const Center(
          child: Padding(padding: EdgeInsets.all(24), child: Text('Añade una cuenta corriente, de ahorro o efectivo para ver la previsión.', textAlign: TextAlign.center)));
    }
    final scenario = store.scenarios.where((s) => s.id == scenarioId).firstOrNull;
    final simulated = scenario == null ? null : simulateForecast(plan, scenarioEvents(plan, scenario));
    final shown = simulated ?? base;
    if (accountId != null && plan.account(accountId!) == null) accountId = null;
    var day = selectedDay ?? _defaultDay(plan);
    if (day.isBefore(plan.today) || day.isAfter(plan.end)) day = _defaultDay(plan);
    final change = shown.explain(day, accountId);

    void select(DateTime d) => setState(() => selectedDay = d);
    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      if (scenario != null) ...[
        _ScenarioBanner(name: scenario.name, onClear: () => setState(() => scenarioId = null)),
        _ScenarioSummary(comparison: ScenarioComparison(base, simulated!, scenario), onEdit: () => _editScenario(plan, store, editing: scenario), onDelete: () => _deleteScenario(store, scenario)),
        const SizedBox(height: 8),
      ],
      _Companion(result: base, onMoment: (m) {
        select(m.day);
        if (m.accountId != null && m.kind == MomentKind.overdraft) setState(() => accountId = m.accountId);
        _moment(shown, m);
      }),
      const SizedBox(height: 8),
      _DayPanel(change: change, accountId: accountId, onPick: () => _pickDay(plan, day), onEvent: (e) => _event(plan, store, e)),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 12, 12, 8),
          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            if (plan.starts.length > 1)
              Padding(
                padding: const EdgeInsets.only(left: 8),
                child: DropdownButtonHideUnderline(
                  child: DropdownButton<String?>(
                    isExpanded: true,
                    value: accountId,
                    items: [
                      const DropdownMenuItem(value: null, child: Text('Todas las cuentas')),
                      for (final s in plan.starts) DropdownMenuItem(value: s.account.id, child: Text(s.account.name, overflow: TextOverflow.ellipsis)),
                    ],
                    onChanged: (v) => setState(() => accountId = v),
                  ),
                ),
              ),
            SizedBox(
              height: 210,
              child: amountsHidden
                  ? Center(child: Text('Importes ocultos', style: TextStyle(color: hint)))
                  : _ForecastChart(result: shown, base: simulated == null ? null : base, accountId: accountId, selected: day, onSelect: select),
            ),
            _Legend(simulated: simulated != null),
            const SizedBox(height: 8),
            Center(
              child: SegmentedButton<int>(
                segments: const [ButtonSegment(value: 30, label: Text('30 días')), ButtonSegment(value: 60, label: Text('60 días')), ButtonSegment(value: 90, label: Text('90 días'))],
                selected: {plan.settings.horizonDays},
                showSelectedIcon: false,
                onSelectionChanged: (v) => store.saveSettings(plan.settings.copyWith(horizonDays: v.single)),
              ),
            ),
          ]),
        ),
      ),
      if (!plan.hasIncome || plan.pendingProposals.isNotEmpty || plan.settings.incomes.isNotEmpty) ...[
        const SizedBox(height: 8),
        _IncomeCard(plan: plan, store: store, onAdd: () => _addIncome(plan, store)),
      ],
      const SizedBox(height: 8),
      _Upcoming(result: shown, accountId: accountId, onEvent: (e) => _event(plan, store, e)),
      const SizedBox(height: 8),
      _StartLine(plan: plan),
      Padding(
        padding: const EdgeInsets.fromLTRB(4, 2, 4, 0),
        child: Text('Es una estimación con tus datos y tus supuestos, no una garantía. Se calcula con reglas fijas en tu móvil, sin IA.',
            style: TextStyle(fontSize: 12, color: hint)),
      ),
      const SizedBox(height: 24),
      // Simulations: secondary, apart from the forecast.
      _SimulationSection(
        scenarios: store.scenarios,
        selected: scenarioId,
        onSelect: (id) => setState(() => scenarioId = id == scenarioId ? null : id),
        onNew: () => _editScenario(plan, store),
      ),
    ]);
  }

  Future<void> _pickDay(ForecastPlan plan, DateTime day) async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(day.year, day.month, day.day),
      firstDate: DateTime(plan.today.year, plan.today.month, plan.today.day),
      lastDate: DateTime(plan.end.year, plan.end.month, plan.end.day),
      locale: const Locale('es', 'ES'),
      helpText: '¿Cuánto tendré el…?',
    );
    if (picked != null) setState(() => selectedDay = DateTime.utc(picked.year, picked.month, picked.day));
  }

  Future<void> _moment(ForecastResult result, ForecastMoment moment) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) {
          final change = result.explain(moment.day, moment.kind == MomentKind.overdraft ? moment.accountId : accountId);
          final hint = Theme.of(context).hintColor;
          return SafeArea(
            child: Padding(
              padding: const EdgeInsets.fromLTRB(20, 0, 20, 20),
              child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                Row(children: [
                  const DonBigotesMark(size: 36),
                  const SizedBox(width: 10),
                  Expanded(
                    child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                      Text(moment.title, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
                      Text(_longDay(moment.day), style: TextStyle(color: hint)),
                    ]),
                  ),
                ]),
                const SizedBox(height: 12),
                Text(moment.detail),
                const SizedBox(height: 12),
                _Breakdown(change: change),
              ]),
            ),
          );
        },
      );

  Future<void> _assumptions(ForecastPlan plan, ForecastStore store) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _AssumptionsSheet(plan: plan, store: store),
      );

  Future<void> _addIncome(ForecastPlan plan, ForecastStore store) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _IncomeSheet(plan: plan, store: store, newId: repository.newId),
      );

  Future<void> _editScenario(ForecastPlan plan, ForecastStore store, {Scenario? editing}) async {
    final saved = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (_) => _ScenarioSheet(plan: plan, store: store, editing: editing, newId: repository.newId),
    );
    if (saved != null && mounted) setState(() => scenarioId = saved);
  }

  Future<void> _deleteScenario(ForecastStore store, Scenario scenario) async {
    final ok = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('¿Eliminar «${scenario.name}»?'),
        content: const Text('Solo se borra la simulación. Tus movimientos y saldos no cambian.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          FilledButton(onPressed: () => Navigator.pop(context, true), child: const Text('Eliminar')),
        ],
      ),
    );
    if (ok != true) return;
    await store.deleteScenario(scenario.id);
    if (mounted) setState(() => scenarioId = null);
  }

  /// What an item of the forecast is based on, and the assumptions it can change.
  Future<void> _event(ForecastPlan plan, ForecastStore store, ForecastEvent event) => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (_) => _EventSheet(plan: plan, store: store, event: event),
      );
}

String _longDay(DateTime day) => toBeginningOfSentenceCase(DateFormat("EEEE d 'de' MMMM", 'es').format(day));

/// Don Bigotes inside the forecast: one or two sentences from its results and the dates worth a look.
class _Companion extends StatelessWidget {
  const _Companion({required this.result, required this.onMoment});
  final ForecastResult result;
  final ValueChanged<ForecastMoment> onMoment;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final lines = forecastSummary(result);
    final moments = forecastMoments(result).take(4).toList();
    IconData icon(MomentKind k) => switch (k) {
          MomentKind.income => Icons.south_west,
          MomentKind.lowest => Icons.trending_down,
          MomentKind.overdraft => Icons.warning_amber_rounded,
          MomentKind.cushion => Icons.shield_outlined,
        };
    Color tint(MomentKind k) => switch (k) {
          MomentKind.income => pulso.income,
          MomentKind.lowest => pulso.accent,
          MomentKind.overdraft || MomentKind.cushion => pulso.warning,
        };
    String short(ForecastMoment m) => switch (m.kind) {
          MomentKind.income => 'Ingreso',
          MomentKind.lowest => 'Mínimo',
          MomentKind.overdraft => 'Descubierto',
          MomentKind.cushion => 'Colchón',
        };
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
            const DonBigotesMark(size: 40),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                for (final line in lines) Padding(padding: const EdgeInsets.only(bottom: 2), child: Text(line, style: const TextStyle(fontWeight: FontWeight.w600))),
              ]),
            ),
          ]),
          if (moments.isNotEmpty) ...[
            const SizedBox(height: 10),
            Wrap(spacing: 8, runSpacing: 6, children: [
              for (final m in moments)
                ActionChip(
                  avatar: Icon(icon(m.kind), size: 16, color: tint(m.kind)),
                  label: Text('${short(m)} · ${shortDay(m.day)}'),
                  tooltip: m.title,
                  onPressed: () => onMoment(m),
                ),
            ]),
          ],
          const SizedBox(height: 6),
          Text('Toca una fecha para ver por qué.', style: TextStyle(fontSize: 12, color: hint)),
        ]),
      ),
    );
  }
}

/// «¿Cuánto tendré?»: the free money and the balance on the chosen date, and what explains the change from today.
class _DayPanel extends StatelessWidget {
  const _DayPanel({required this.change, this.accountId, required this.onPick, required this.onEvent});
  final ForecastChange change;
  final String? accountId;
  final VoidCallback onPick;
  final ValueChanged<ForecastEvent> onEvent;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final difference = change.endFree - change.startFree;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 10, 8, 14),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text('¿Cuánto tendré el ${DateFormat("d 'de' MMMM", 'es').format(change.day)}?', style: const TextStyle(fontWeight: FontWeight.w700))),
            TextButton(onPressed: onPick, child: const Text('Otra fecha')),
          ]),
          Wrap(spacing: 24, runSpacing: 4, crossAxisAlignment: WrapCrossAlignment.end, children: [
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Libre para gastar', style: TextStyle(fontSize: 12, color: hint)),
              Text(money(change.endFree), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: change.endFree < 0 ? pulso.expense : null)),
            ]),
            Column(crossAxisAlignment: CrossAxisAlignment.start, mainAxisSize: MainAxisSize.min, children: [
              Text('Saldo total', style: TextStyle(fontSize: 12, color: hint)),
              Text(money(change.endBalance), style: const TextStyle(fontSize: 17, fontWeight: FontWeight.w700)),
            ]),
          ]),
          Text('${money(difference, signed: true)} desde hoy', style: TextStyle(fontSize: 13, color: difference < 0 ? pulso.expense : pulso.income, fontWeight: FontWeight.w600)),
          const SizedBox(height: 10),
          _Breakdown(change: change, onEvent: onEvent),
        ]),
      ),
    );
  }
}

/// Incomes, payments and the variable spending between today and a date, and how much of it is sure.
class _Breakdown extends StatefulWidget {
  const _Breakdown({required this.change, this.onEvent});
  final ForecastChange change;
  final ValueChanged<ForecastEvent>? onEvent;

  @override
  State<_Breakdown> createState() => _BreakdownState();
}

class _BreakdownState extends State<_Breakdown> {
  bool open = false;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final c = widget.change;
    Widget line(String label, int value, Color color) => Padding(
          padding: const EdgeInsets.symmetric(vertical: 2),
          child: Row(children: [
            Expanded(child: Text(label)),
            Text(money(value, signed: true), style: TextStyle(fontWeight: FontWeight.w700, color: value == 0 ? hint : color)),
          ]),
        );
    final items = [...c.incomes, ...c.expenses]..sort((a, b) => a.$1.day.compareTo(b.$1.day));
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      line(c.incomes.length == 1 ? 'Ingresos (1)' : 'Ingresos (${c.incomes.length})', c.incomeMinor, pulso.income),
      line(c.expenses.length == 1 ? 'Pagos previstos (1)' : 'Pagos previstos (${c.expenses.length})', c.expenseMinor, pulso.expense),
      line('Gasto variable estimado', c.variableMinor, pulso.expense),
      Padding(
        padding: const EdgeInsets.only(top: 4),
        child: Text('Seguro (apuntado o periódico): ${money(c.sureMinor, signed: true)} · Estimado: ${money(c.estimatedMinor, signed: true)}',
            style: TextStyle(fontSize: 12, color: hint)),
      ),
      if (items.isNotEmpty)
        Align(
          alignment: Alignment.centerLeft,
          child: TextButton.icon(
            style: TextButton.styleFrom(padding: EdgeInsets.zero),
            onPressed: () => setState(() => open = !open),
            icon: Icon(open ? Icons.expand_less : Icons.expand_more, size: 18),
            label: Text(open ? 'Ocultar el detalle' : 'Ver qué lo explica'),
          ),
        ),
      if (open)
        for (final (e, effect) in items)
          ListTile(
            dense: true,
            contentPadding: EdgeInsets.zero,
            onTap: widget.onEvent == null ? null : () => widget.onEvent!(e),
            title: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
            subtitle: Text('${shortDay(e.day)} · ${e.certainty.title}'),
            trailing: Text(money(effect, signed: true), style: TextStyle(fontWeight: FontWeight.w700, color: effect >= 0 ? pulso.income : pulso.expense)),
          ),
    ]);
  }
}

/// The free money over time: the real line of the last 30 days, then the estimate (dashed), today marked, the
/// incomes as green dots so the recovery after them is seen, and the total balance as a thin line for reference.
class _ForecastChart extends StatelessWidget {
  const _ForecastChart({required this.result, this.base, this.accountId, required this.selected, required this.onSelect});
  final ForecastResult result;
  final ForecastResult? base;
  final String? accountId;
  final DateTime selected;
  final ValueChanged<DateTime> onSelect;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    const past = ForecastPlan.pastDays;
    final pastFree = result.pastFree(accountId), future = result.free(accountId);
    final pastBalance = result.pastBalance(accountId), futureBalance = result.balance(accountId);
    final baseFree = base?.free(accountId);
    final all = [...pastFree, ...future, ...pastBalance, ...futureBalance, ...?baseFree, 0];
    final low = all.reduce(math.min) / 100, high = all.reduce(math.max) / 100;
    final margin = math.max((high - low) * 0.1, 10.0);
    final incomeDays = {
      for (final e in result.events)
        if (e.amountMinor > 0 && !e.isTransfer && (accountId == null || e.accountId == accountId)) result.indexOf(e.day)
    };
    final selectedIndex = result.indexOf(selected);
    FlSpot spot(int x, int v) => FlSpot(x.toDouble(), v / 100);
    DateTime dayOf(int x) => x < past ? DateTime.utc(result.plan.today.year, result.plan.today.month, result.plan.today.day - (past - x)) : result.dayAt(x - past);
    final total = past + future.length;
    final step = total > 75 ? 21 : 14;
    return Semantics(
      label: 'Dinero libre: hoy ${money(future.first)}, el ${shortDay(selected)} ${money(future[selectedIndex])}, al final ${money(future.last)}.',
      child: LineChart(LineChartData(
        minY: low - margin,
        maxY: high + margin,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        extraLinesData: ExtraLinesData(
          horizontalLines: [HorizontalLine(y: 0, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25), strokeWidth: 1)],
          verticalLines: [
            VerticalLine(
              x: past.toDouble(),
              color: hint.withValues(alpha: 0.6),
              strokeWidth: 1,
              dashArray: [3, 3],
              label: VerticalLineLabel(show: true, alignment: Alignment.topLeft, labelResolver: (_) => 'Hoy', style: TextStyle(fontSize: 11, color: hint, fontWeight: FontWeight.w700)),
            ),
            VerticalLine(x: (past + selectedIndex).toDouble(), color: pulso.accent.withValues(alpha: 0.5), strokeWidth: 1.5),
          ],
        ),
        lineTouchData: LineTouchData(
          touchCallback: (event, response) {
            final hit = response?.lineBarSpots?.firstOrNull;
            if (event is FlTapUpEvent && hit != null && hit.x.round() >= past) onSelect(result.dayAt(hit.x.round() - past));
          },
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => Theme.of(context).colorScheme.onSurface,
            getTooltipItems: (spots) => [
              for (final (n, s) in spots.indexed)
                n == 0
                    ? LineTooltipItem('${shortDay(dayOf(s.x.round()))} · ${s.x.round() < past ? 'real' : 'previsto'}\n', TextStyle(color: pulso.page, fontSize: 11), children: [
                        TextSpan(text: 'Libre ${money((s.y * 100).round())}', style: TextStyle(color: pulso.page, fontWeight: FontWeight.w800, fontSize: 13)),
                      ])
                    : null,
            ],
          ),
        ),
        titlesData: FlTitlesData(
          leftTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          rightTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          topTitles: const AxisTitles(sideTitles: SideTitles(showTitles: false)),
          bottomTitles: AxisTitles(
            sideTitles: SideTitles(
              showTitles: true,
              interval: 1,
              reservedSize: 22,
              getTitlesWidget: (value, meta) {
                final x = value.round();
                if (x < 0 || x >= total || (x - past) % step != 0) return const SizedBox.shrink();
                final d = dayOf(x);
                return Padding(padding: const EdgeInsets.only(top: 4), child: Text('${d.day}/${d.month}', style: Theme.of(context).textTheme.bodySmall));
              },
            ),
          ),
        ),
        lineBarsData: [
          // 0: free money, real (solid). 1: free money, estimated (dashed, with its area). 2: total balance (thin).
          LineChartBarData(
            spots: [for (var i = 0; i < past; i++) spot(i, pastFree[i]), spot(past, future.first)],
            color: pulso.accent,
            barWidth: 3,
            dotData: const FlDotData(show: false),
          ),
          LineChartBarData(
            spots: [for (var i = 0; i < future.length; i++) spot(past + i, future[i])],
            color: pulso.accent,
            barWidth: 3,
            dashArray: [6, 4],
            dotData: FlDotData(
              checkToShowDot: (s, _) => incomeDays.contains(s.x.round() - past) || s.x.round() - past == selectedIndex,
              getDotPainter: (s, _, __, ___) => FlDotCirclePainter(
                  radius: s.x.round() - past == selectedIndex ? 5 : 4,
                  color: s.x.round() - past == selectedIndex ? pulso.accent : pulso.income,
                  strokeWidth: 2,
                  strokeColor: pulso.card),
            ),
            belowBarData: BarAreaData(
              show: true,
              gradient: LinearGradient(
                  begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [pulso.accent.withValues(alpha: 0.14), pulso.accent.withValues(alpha: 0)]),
            ),
          ),
          LineChartBarData(
            spots: [for (var i = 0; i < past; i++) spot(i, pastBalance[i]), for (var i = 0; i < futureBalance.length; i++) spot(past + i, futureBalance[i])],
            color: hint.withValues(alpha: 0.55),
            barWidth: 1.2,
            dotData: const FlDotData(show: false),
          ),
          if (baseFree != null)
            LineChartBarData(
              spots: [for (var i = 0; i < baseFree.length; i++) spot(past + i, baseFree[i])],
              color: hint,
              barWidth: 2,
              dashArray: [2, 4],
              dotData: const FlDotData(show: false),
            ),
        ],
      )),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.simulated});
  final bool simulated;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    Widget mark(Widget sample, String text) => Row(mainAxisSize: MainAxisSize.min, children: [
          sample,
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: TextStyle(fontSize: 12, color: hint))),
        ]);
    Widget bar(Color color, double h) => Container(width: 16, height: h, color: color);
    return Padding(
      padding: const EdgeInsets.fromLTRB(8, 6, 0, 0),
      child: Wrap(spacing: 14, runSpacing: 4, children: [
        mark(bar(pulso.accent, 3), simulated ? 'Libre con la simulación' : 'Libre real hasta hoy'),
        if (!simulated) mark(Row(mainAxisSize: MainAxisSize.min, children: [bar(pulso.accent, 3), const SizedBox(width: 3), bar(pulso.accent, 3)]), 'Libre previsto'),
        if (simulated) mark(bar(hint, 2), 'Previsión sin simular'),
        mark(bar(hint.withValues(alpha: 0.55), 1.2), 'Saldo total (incluye reservas)'),
        mark(Container(width: 8, height: 8, decoration: BoxDecoration(color: pulso.income, shape: BoxShape.circle)), 'Ingreso'),
      ]),
    );
  }
}

/// Incomes: the ones found in the history to confirm, the ones the person added, and a way to add one when the
/// forecast has none (otherwise the line can only go down).
class _IncomeCard extends StatelessWidget {
  const _IncomeCard({required this.plan, required this.store, required this.onAdd});
  final ForecastPlan plan;
  final ForecastStore store;
  final VoidCallback onAdd;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final pending = plan.pendingProposals;
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 8),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Tus ingresos', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (!plan.hasIncome)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(Icons.info_outline, size: 18, color: pulso.warning),
                const SizedBox(width: 6),
                const Expanded(child: Text('No hay ingresos previstos: esta previsión solo cuenta gastos y no es fiable para saber cuánto tendrás.')),
              ]),
            ),
          for (final p in pending)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(p.label, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
                Text('${p.isIncome ? '+' : '−'}${money(p.amountMinor)} hacia el día ${p.dayOfMonth} · visto ${p.times} meses en tu historial',
                    style: TextStyle(fontSize: 12, color: hint)),
                Row(children: [
                  Expanded(child: Text('¿Cuento con él?', style: TextStyle(fontSize: 13, color: hint))),
                  TextButton(onPressed: () => store.saveSettings(plan.settings.review(p.source, keep: false)), child: const Text('No')),
                  FilledButton.tonal(onPressed: () => store.saveSettings(plan.settings.review(p.source, keep: true)), child: const Text('Sí')),
                ]),
              ]),
            ),
          for (final i in plan.settings.incomes)
            ListTile(
              contentPadding: EdgeInsets.zero,
              dense: true,
              title: Text(i.name),
              subtitle: Text('+${money(i.amountMinor)} el día ${i.dayOfMonth} · indicado por ti, no es un movimiento'),
              trailing: IconButton(
                tooltip: 'Quitar',
                icon: const Icon(Icons.close),
                onPressed: () => store.saveSettings(plan.settings.copyWith(incomes: [for (final x in plan.settings.incomes) if (x.id != i.id) x])),
              ),
            ),
          Align(
            alignment: Alignment.centerLeft,
            child: TextButton.icon(onPressed: onAdd, icon: const Icon(Icons.add), label: const Text('Añadir un ingreso previsto')),
          ),
        ]),
      ),
    );
  }
}

/// What comes next (not the variable spending), a few lines; the rest on demand.
class _Upcoming extends StatelessWidget {
  const _Upcoming({required this.result, this.accountId, required this.onEvent});
  final ForecastResult result;
  final String? accountId;
  final ValueChanged<ForecastEvent> onEvent;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final items = [
      for (final e in result.events)
        if (!e.isVariable && (accountId == null || e.accountId == accountId || e.destinationId == accountId)) e
    ];
    Widget row(ForecastEvent e) {
      final effect = accountId != null && e.destinationId == accountId ? -e.amountMinor : e.amountMinor;
      final transfer = e.isTransfer && accountId == null;
      return ListTile(
        contentPadding: EdgeInsets.zero,
        onTap: () => onEvent(e),
        leading: SizedBox(width: 44, child: Text(shortDay(e.day), style: const TextStyle(fontWeight: FontWeight.w700))),
        title: Text(e.label, maxLines: 1, overflow: TextOverflow.ellipsis),
        subtitle: Text([e.certainty.title, if (transfer) 'traspaso entre tus cuentas'].join(' · ')),
        trailing: Text(transfer ? money(e.amountMinor.abs()) : money(effect, signed: true),
            style: TextStyle(fontWeight: FontWeight.w700, color: transfer ? hint : (effect >= 0 ? pulso.income : pulso.expense))),
      );
    }

    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 12, 12, 4),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Lo que viene', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
          if (items.isEmpty) Padding(padding: const EdgeInsets.symmetric(vertical: 8), child: Text('Nada previsto aparte del gasto variable.', style: TextStyle(color: hint))),
          for (final e in items.take(5)) row(e),
          if (items.length > 5)
            TextButton(
              onPressed: () => showModalBottomSheet<void>(
                context: context,
                showDragHandle: true,
                isScrollControlled: true,
                builder: (context) => SafeArea(
                  child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
                    Text('Todo lo previsto', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    for (final e in items) row(e),
                  ]),
                ),
              ),
              child: Text('Ver los ${items.length}'),
            ),
        ]),
      ),
    );
  }
}

class _ScenarioBanner extends StatelessWidget {
  const _ScenarioBanner({required this.name, required this.onClear});
  final String name;
  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => Card(
        color: Pulso.of(context).accent.withValues(alpha: 0.10),
        child: Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
          child: Row(children: [
            const Icon(Icons.science_outlined, size: 18),
            const SizedBox(width: 8),
            Expanded(child: Text('Simulando «$name»: no cambia tus cuentas', style: const TextStyle(fontWeight: FontWeight.w600))),
            TextButton(onPressed: onClear, child: const Text('Quitar')),
          ]),
        ),
      );
}

/// Simulations, apart: a short explanation, the saved ones to compare, and a new one.
class _SimulationSection extends StatelessWidget {
  const _SimulationSection({required this.scenarios, required this.selected, required this.onSelect, required this.onNew});
  final List<Scenario> scenarios;
  final String? selected;
  final ValueChanged<String> onSelect;
  final VoidCallback onNew;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
      Text('Simular una decisión', style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      Text('Prueba una compra, un gasto nuevo o un cobro que se retrasa y compáralo con esta previsión, sin tocar tus cuentas.', style: TextStyle(color: hint)),
      const SizedBox(height: 8),
      if (scenarios.isNotEmpty)
        Wrap(spacing: 8, runSpacing: 4, children: [
          for (final s in scenarios) ChoiceChip(label: Text(s.name), selected: s.id == selected, onSelected: (_) => onSelect(s.id)),
        ]),
      const SizedBox(height: 4),
      OutlinedButton.icon(onPressed: onNew, icon: const Icon(Icons.science_outlined), label: const Text('Nueva simulación')),
    ]);
  }
}

/// An income the person expects, for the forecast only: name, amount, day and account, filled in from the history.
class _IncomeSheet extends StatefulWidget {
  const _IncomeSheet({required this.plan, required this.store, required this.newId});
  final ForecastPlan plan;
  final ForecastStore store;
  final String Function() newId;

  @override
  State<_IncomeSheet> createState() => _IncomeSheetState();
}

class _IncomeSheetState extends State<_IncomeSheet> {
  late final name = TextEditingController(text: 'Nómina');
  late final amount = TextEditingController();
  late final day = TextEditingController();
  String? accountId;

  @override
  void initState() {
    super.initState();
    accountId = widget.plan.defaultAccountId;
    // The last income of the history as a starting point, if there is one.
    final last = widget.plan.data.transactions
        .where((t) => t.type == TransactionType.income && widget.plan.account(t.sourceAccountId ?? '') != null && t.amountMinor > 0)
        .firstOrNull;
    if (last != null) {
      amount.text = _amountText(last.amountMinor);
      day.text = '${last.date.toLocal().day}';
      accountId = last.sourceAccountId;
    }
  }

  @override
  void dispose() {
    name.dispose();
    amount.dispose();
    day.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text('Ingreso previsto', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text('Solo para la previsión: no crea ningún movimiento. Cuando llegue el real, ocupa su lugar.', style: TextStyle(color: hint)),
          const SizedBox(height: 12),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre')),
          const SizedBox(height: 8),
          Row(children: [
            Expanded(
              child: TextField(
                  controller: amount,
                  keyboardType: const TextInputType.numberWithOptions(decimal: true),
                  decoration: const InputDecoration(labelText: 'Importe al mes', suffixText: '€')),
            ),
            const SizedBox(width: 12),
            SizedBox(
              width: 110,
              child: TextField(controller: day, keyboardType: TextInputType.number, decoration: const InputDecoration(labelText: 'Día del mes')),
            ),
          ]),
          const SizedBox(height: 8),
          DropdownButtonFormField<String>(
            initialValue: accountId,
            isExpanded: true,
            decoration: const InputDecoration(labelText: 'Cuenta'),
            items: [for (final s in widget.plan.starts) DropdownMenuItem(value: s.account.id, child: Text(s.account.name, overflow: TextOverflow.ellipsis))],
            onChanged: (v) => setState(() => accountId = v),
          ),
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final value = parseAmount(amount.text), dayOfMonth = int.tryParse(day.text.trim());
              if (value == null || value <= 0 || dayOfMonth == null || dayOfMonth < 1 || dayOfMonth > 31 || accountId == null) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Indica un importe y un día del 1 al 31.')));
                return;
              }
              final settings = widget.store.settings;
              widget.store.saveSettings(settings.copyWith(incomes: [
                ...settings.incomes,
                PlannedIncome(
                    id: widget.newId(), name: name.text.trim().isEmpty ? 'Ingreso' : name.text.trim(), amountMinor: value, dayOfMonth: dayOfMonth, accountId: accountId!),
              ]));
              Navigator.pop(context);
            },
            child: const Text('Añadir a la previsión'),
          ),
        ]),
      ),
    );
  }
}

/// The starting point: when each balance was received or calculated, and what limits the forecast.
class _StartLine extends StatelessWidget {
  const _StartLine({required this.plan});
  final ForecastPlan plan;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final bank = plan.starts.where((s) => s.basis == StartBasis.bank).length;
    final computed = plan.starts.where((s) => s.basis == StartBasis.computed).length;
    final parts = [
      if (bank > 0) bank == 1 ? '1 saldo del banco' : '$bank saldos del banco',
      if (plan.starts.length - bank - computed > 0) '${plan.starts.length - bank - computed} indicados por ti',
      if (computed > 0) computed == 1 ? '1 calculado' : '$computed calculados',
    ];
    return InkWell(
      borderRadius: BorderRadius.circular(8),
      onTap: () => showModalBottomSheet<void>(
        context: context,
        showDragHandle: true,
        isScrollControlled: true,
        builder: (context) => SafeArea(
          child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
            Text('Datos de partida', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
            Text('Hoy, ${DateFormat("d 'de' MMMM, HH:mm", 'es').format(plan.now)}', style: TextStyle(color: hint)),
            const SizedBox(height: 12),
            for (final s in plan.starts)
              ListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(s.account.name),
                subtitle: Text([s.basisText, if (s.reservedMinor > 0) '${money(s.reservedMinor)} en reservas'].join(' · ')),
                trailing: Text(money(s.balanceMinor), style: const TextStyle(fontWeight: FontWeight.w700)),
              ),
            if (plan.limitations.isNotEmpty) ...[
              const SizedBox(height: 8),
              Text('Límites de esta previsión', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              for (final l in plan.limitations) Padding(padding: const EdgeInsets.only(top: 6), child: Text('• $l')),
            ],
            const SizedBox(height: 12),
            Text('Las inversiones, tarjetas de crédito y cuentas archivadas no entran en el disponible.', style: TextStyle(fontSize: 12, color: hint)),
          ]),
        ),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 4),
        child: Row(children: [
          Icon(Icons.history, size: 16, color: hint),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'Parte de hoy: ${parts.join(', ')}${plan.limitations.isEmpty ? '' : ' · ${plan.limitations.length == 1 ? '1 límite' : '${plan.limitations.length} límites'}'}',
              style: TextStyle(fontSize: 13, color: hint),
            ),
          ),
          Icon(Icons.chevron_right, size: 18, color: hint),
        ]),
      ),
    );
  }
}

class _ScenarioSummary extends StatelessWidget {
  const _ScenarioSummary({required this.comparison, required this.onEdit, required this.onDelete});
  final ScenarioComparison comparison;
  final VoidCallback onEdit, onDelete;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final breach = comparison.result.cushionBreach();
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Expanded(child: Text(comparison.scenario.name, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700))),
            IconButton(tooltip: 'Editar simulación', onPressed: onEdit, icon: const Icon(Icons.edit_outlined)),
            IconButton(tooltip: 'Eliminar simulación', onPressed: onDelete, icon: const Icon(Icons.delete_outline)),
          ]),
          for (final (i, line) in comparison.summary.indexed)
            Padding(
              padding: const EdgeInsets.only(top: 6, right: 8),
              child: Row(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Icon(i == 0 ? (breach == null ? Icons.verified_outlined : Icons.warning_amber_rounded) : Icons.circle, size: i == 0 ? 18 : 6,
                    color: i == 0 ? (breach == null ? pulso.income : pulso.warning) : Theme.of(context).hintColor),
                SizedBox(width: i == 0 ? 8 : 14),
                Expanded(child: Text(line, style: TextStyle(fontWeight: i == 0 ? FontWeight.w700 : FontWeight.w400))),
              ]),
            ),
        ]),
      ),
    );
  }
}

String _amountText(int minor) => (minor / 100).toStringAsFixed(2).replaceAll('.', ',');

/// The assumptions: the cushion, the variable spending, whether to learn from the history, and each planned item
/// that can be left out or given another amount. None of this changes a movement or a periodic payment.
class _AssumptionsSheet extends StatefulWidget {
  const _AssumptionsSheet({required this.plan, required this.store});
  final ForecastPlan plan;
  final ForecastStore store;

  @override
  State<_AssumptionsSheet> createState() => _AssumptionsSheetState();
}

class _AssumptionsSheetState extends State<_AssumptionsSheet> {
  late ForecastSettings settings = widget.store.settings;
  late final cushion = TextEditingController(text: settings.cushionMinor > 0 ? _amountText(settings.cushionMinor) : '');
  late final variable = TextEditingController(text: _amountText(settings.variableMonthlyMinor ?? widget.plan.variableMonthlyMinor));

  @override
  void dispose() {
    cushion.dispose();
    variable.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final plan = widget.plan;
    final items = <String, ForecastEvent>{};
    for (final e in plan.events) {
      if (e.source.startsWith('rec:') || e.source.startsWith('pat:') || e.source == 'hold') items.putIfAbsent(e.source, () => e);
    }
    // A suggestion from the person's own data: about two weeks of the usual variable spending.
    final suggested = plan.variableMonthlyMinor ~/ 2;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text('Supuestos', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text('Cambiarlos solo afecta a la previsión: tus movimientos y pagos periódicos siguen igual.', style: TextStyle(color: hint)),
          const SizedBox(height: 16),
          TextField(
            controller: cushion,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
              labelText: 'Colchón',
              suffixText: '€',
              helperText: suggested > 0 && settings.cushionMinor == 0
                  ? 'El dinero libre por debajo del cual quieres un aviso. Por ejemplo, ${money(suggested)} (medio mes de gasto variable).'
                  : 'El dinero libre por debajo del cual quieres un aviso.',
              helperMaxLines: 3,
            ),
          ),
          const SizedBox(height: 12),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Gasto variable automático'),
            subtitle: Text(settings.variableMonthlyMinor == null
                ? '${money(plan.variableMonthlyMinor)} este mes: ${money(plan.variableFromBudgetsMinor)} que dejan libres tus presupuestos y '
                    '${money(plan.variableMonthlyMinor - plan.variableFromBudgetsMinor)} de tu gasto habitual sin presupuesto.'
                : 'Usas la cantidad que escribes abajo.'),
            value: settings.variableMonthlyMinor == null,
            onChanged: (auto) => setState(() => settings = settings.copyWith(variableMonthlyMinor: () => auto ? null : plan.variableMonthlyMinor)),
          ),
          if (settings.variableMonthlyMinor != null)
            TextField(
              controller: variable,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Gasto variable al mes', suffixText: '€'),
            ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Aprender del historial'),
            subtitle: const Text('Ingresos y recibos que se repiten cada mes y tu gasto habitual. Sin esto, solo cuentan los pagos previstos y los presupuestos.'),
            value: settings.useHistory,
            onChanged: (v) => setState(() => settings = settings.copyWith(useHistory: v)),
          ),
          SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Contar el gasto variable'),
            value: !settings.excluded.contains('var'),
            onChanged: (v) => setState(() => settings = settings.copyWith(excluded: {...settings.excluded}..remove('var')..addAll(v ? const [] : const ['var']))),
          ),
          if (items.isNotEmpty) ...[
            const SizedBox(height: 8),
            Text('Lo que cuenta la previsión', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
            for (final MapEntry(key: source, value: e) in items.entries)
              SwitchListTile(
                contentPadding: EdgeInsets.zero,
                title: Text(e.label, maxLines: 2, overflow: TextOverflow.ellipsis),
                subtitle: Text('${e.certainty.title} · ${money((settings.amounts[source] ?? e.amountMinor.abs()) * (e.amountMinor < 0 ? -1 : 1))}'),
                value: !settings.excluded.contains(source),
                onChanged: (v) => setState(() => settings = settings.copyWith(excluded: {...settings.excluded}..remove(source)..addAll(v ? const [] : [source]))),
              ),
          ],
          const SizedBox(height: 16),
          FilledButton(
            onPressed: () {
              final cushionValue = cushion.text.trim().isEmpty ? 0 : parseAmount(cushion.text);
              final variableValue = settings.variableMonthlyMinor == null ? null : parseAmount(variable.text);
              if (cushionValue == null || (settings.variableMonthlyMinor != null && variableValue == null)) {
                ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Revisa los importes.')));
                return;
              }
              widget.store.saveSettings(settings.copyWith(cushionMinor: cushionValue, variableMonthlyMinor: () => variableValue));
              Navigator.pop(context);
            },
            child: const Text('Guardar supuestos'),
          ),
        ]),
      ),
    );
  }
}

/// One item of the forecast: where it comes from, and what can be changed about it.
class _EventSheet extends StatefulWidget {
  const _EventSheet({required this.plan, required this.store, required this.event});
  final ForecastPlan plan;
  final ForecastStore store;
  final ForecastEvent event;

  @override
  State<_EventSheet> createState() => _EventSheetState();
}

class _EventSheetState extends State<_EventSheet> {
  late final amount = TextEditingController(text: _amountText(widget.store.settings.amounts[widget.event.source] ?? widget.event.amountMinor.abs()));

  @override
  void dispose() {
    amount.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final e = widget.event;
    final hint = Theme.of(context).hintColor;
    final settings = widget.store.settings;
    final editable = e.source.startsWith('rec:') || e.source.startsWith('pat:');
    final explanation = switch (e.source.split(':').first) {
      'rec' => 'Un pago periódico que tienes configurado. Si el movimiento real llega unos días antes o después, ocupa su lugar y no se cuenta dos veces.',
      'pat' => 'Estimado: se ha repetido cada mes en tu historial con un importe y una fecha parecidos. Cuando llega el real, deja de contarse.',
      'var' => 'Estimado: lo que aún permiten tus presupuestos este mes, menos sus pagos ya previstos, y tu gasto habitual en lo que no tiene presupuesto.',
      'tx' => 'Un movimiento real ya apuntado con fecha futura. Se cambia en Movimientos.',
      'hold' => 'Un cargo que el banco ha retenido y aún no ha cargado. Ya está descontado de tu disponible.',
      _ => 'Forma parte de una simulación: no existe en tus cuentas.',
    };
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.fromLTRB(20, 0, 20, 20 + MediaQuery.viewInsetsOf(context).bottom),
        child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text(e.label, style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text('${e.certainty.title} · ${shortDay(e.day)} · ${money(e.amountMinor, signed: true)}', style: TextStyle(color: hint)),
          const SizedBox(height: 12),
          Text(explanation),
          if (e.detail.isNotEmpty) Padding(padding: const EdgeInsets.only(top: 6), child: Text(e.detail, style: TextStyle(color: hint))),
          if (editable) ...[
            const SizedBox(height: 12),
            SwitchListTile(
              contentPadding: EdgeInsets.zero,
              title: const Text('Contar en la previsión'),
              value: !settings.excluded.contains(e.source),
              onChanged: (v) {
                widget.store.saveSettings(settings.copyWith(excluded: {...settings.excluded}..remove(e.source)..addAll(v ? const [] : [e.source])));
                setState(() {});
              },
            ),
            TextField(
              controller: amount,
              keyboardType: const TextInputType.numberWithOptions(decimal: true),
              decoration: const InputDecoration(labelText: 'Importe previsto', suffixText: '€', helperText: 'Solo para la previsión: el pago o el movimiento no cambian.'),
            ),
            const SizedBox(height: 12),
            Row(children: [
              if (settings.amounts.containsKey(e.source))
                TextButton(
                  onPressed: () {
                    widget.store.saveSettings(settings.copyWith(amounts: {...settings.amounts}..remove(e.source)));
                    Navigator.pop(context);
                  },
                  child: const Text('Volver al original'),
                ),
              const Spacer(),
              FilledButton(
                onPressed: () {
                  final value = parseAmount(amount.text);
                  if (value == null) return;
                  widget.store.saveSettings(settings.copyWith(amounts: {...settings.amounts, e.source: value}));
                  Navigator.pop(context);
                },
                child: const Text('Guardar'),
              ),
            ]),
          ],
        ]),
      ),
    );
  }
}

/// Creates or edits a simulation with few fields, filled in from the person's data.
class _ScenarioSheet extends StatefulWidget {
  const _ScenarioSheet({required this.plan, required this.store, this.editing, required this.newId});
  final ForecastPlan plan;
  final ForecastStore store;
  final Scenario? editing;
  final String Function() newId;

  @override
  State<_ScenarioSheet> createState() => _ScenarioSheetState();
}

class _ScenarioSheetState extends State<_ScenarioSheet> {
  late ScenarioKind kind;
  late final name = TextEditingController();
  late final amount = TextEditingController();
  late final delay = TextEditingController(text: '0');
  late DateTime day;
  String? accountId, reserveId, incomeSource;
  bool monthly = false, raise = false, nameTouched = false;

  ForecastPlan get plan => widget.plan;
  List<ReservedFund> get funds => [for (final f in plan.data.reservedFunds) if (plan.reserveAccount(f.id) != null && plan.account(plan.reserveAccount(f.id)!) != null) f];

  @override
  void initState() {
    super.initState();
    final change = widget.editing?.changes.first;
    kind = change?.kind ?? ScenarioKind.purchase;
    day = change?.day ?? _plusDays(plan.today, 1);
    accountId = change?.accountId ?? plan.defaultAccountId;
    reserveId = change?.reserveId;
    incomeSource = change?.incomeSource;
    monthly = change?.monthly ?? false;
    raise = (change?.amountMinor ?? 0) > 0;
    if (change != null) {
      amount.text = change.amountMinor == 0 ? '' : _amountText(change.amountMinor.abs());
      delay.text = '${change.delayDays}';
      name.text = widget.editing!.name;
      nameTouched = true;
    } else {
      _defaults();
    }
  }

  static DateTime _plusDays(DateTime day, int n) => DateTime.utc(day.year, day.month, day.day + n);

  /// Values from the context for the chosen kind.
  void _defaults() {
    switch (kind) {
      case ScenarioKind.incomeChange:
        incomeSource ??= plan.incomeSources.firstOrNull?.$1;
      case ScenarioKind.reserveContribution:
        reserveId ??= funds.firstOrNull?.id;
        if (reserveId != null) accountId = plan.reserveAccount(reserveId!);
      case ScenarioKind.purchase || ScenarioKind.monthlyExpense:
        break;
    }
    if (!nameTouched) {
      name.text = kind == ScenarioKind.incomeChange && (int.tryParse(delay.text) ?? 0) > 0 ? 'Retraso de cobro' : kind.title;
    }
  }

  @override
  void dispose() {
    name.dispose();
    amount.dispose();
    delay.dispose();
    super.dispose();
  }

  Future<void> _pickDay() async {
    final picked = await showDatePicker(
      context: context,
      initialDate: DateTime(day.year, day.month, day.day),
      firstDate: DateTime(plan.today.year, plan.today.month, plan.today.day),
      lastDate: DateTime(plan.end.year, plan.end.month, plan.end.day),
      locale: const Locale('es', 'ES'),
    );
    if (picked != null) setState(() => day = DateTime.utc(picked.year, picked.month, picked.day));
  }

  void _save() {
    final value = amount.text.trim().isEmpty ? 0 : parseAmount(amount.text);
    final wait = int.tryParse(delay.text.trim()) ?? -1;
    String? problem;
    if (value == null) {
      problem = 'Revisa el importe.';
    } else if (kind == ScenarioKind.incomeChange) {
      if (wait < 0 || wait > 120) problem = 'El retraso va de 0 a 120 días.';
      if (value == 0 && wait <= 0) problem = 'Indica una variación o un retraso.';
      if (incomeSource == null && value == 0) problem = 'Indica cuánto cambian tus ingresos.';
    } else if (value <= 0) {
      problem = 'Indica un importe.';
    }
    if (kind == ScenarioKind.reserveContribution && reserveId == null) problem = 'Elige una reserva.';
    if (problem != null) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(problem)));
      return;
    }
    final change = ScenarioChange(
      kind: kind,
      amountMinor: kind == ScenarioKind.incomeChange && !raise ? -value! : value!,
      day: day,
      accountId: accountId,
      reserveId: kind == ScenarioKind.purchase || kind == ScenarioKind.reserveContribution ? reserveId : null,
      incomeSource: kind == ScenarioKind.incomeChange ? incomeSource : null,
      delayDays: kind == ScenarioKind.incomeChange && incomeSource != null ? wait : 0,
      monthly: kind == ScenarioKind.reserveContribution && monthly,
    );
    final scenario = Scenario(id: widget.editing?.id ?? widget.newId(), name: name.text.trim().isEmpty ? kind.title : name.text.trim(), changes: [change]);
    widget.store.saveScenario(scenario);
    Navigator.pop(context, scenario.id);
  }

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    final accounts = plan.starts.map((s) => s.account).toList();
    final reserveHere = reserveId == null ? 0 : plan.funds[reserveId]?[accountId] ?? 0;
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(bottom: MediaQuery.viewInsetsOf(context).bottom),
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
          Text(widget.editing == null ? 'Nueva simulación' : 'Editar simulación', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
          Text('No crea movimientos ni cambia tus saldos: se compara con tu previsión.', style: TextStyle(color: hint)),
          const SizedBox(height: 12),
          if (widget.editing == null)
            Wrap(spacing: 8, runSpacing: 4, children: [
              for (final k in ScenarioKind.values)
                if (k != ScenarioKind.reserveContribution || funds.isNotEmpty)
                  ChoiceChip(
                      label: Text(k.title),
                      selected: k == kind,
                      onSelected: (_) => setState(() {
                            kind = k;
                            reserveId = null;
                            accountId = plan.defaultAccountId;
                            _defaults();
                          })),
            ]),
          const SizedBox(height: 8),
          TextField(controller: name, decoration: const InputDecoration(labelText: 'Nombre'), onChanged: (_) => nameTouched = true),
          if (kind == ScenarioKind.incomeChange) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: incomeSource,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Ingreso'),
              items: [
                for (final (source, label) in plan.incomeSources) DropdownMenuItem(value: source, child: Text(label, overflow: TextOverflow.ellipsis)),
                const DropdownMenuItem(value: null, child: Text('Un ingreso nuevo o que no está previsto')),
              ],
              onChanged: (v) => setState(() => incomeSource = v),
            ),
            const SizedBox(height: 8),
            SegmentedButton<bool>(
              segments: const [ButtonSegment(value: false, label: Text('Baja')), ButtonSegment(value: true, label: Text('Sube'))],
              selected: {raise},
              showSelectedIcon: false,
              onSelectionChanged: (v) => setState(() => raise = v.single),
            ),
          ],
          const SizedBox(height: 8),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: InputDecoration(
                labelText: switch (kind) {
                  ScenarioKind.purchase => 'Importe',
                  ScenarioKind.monthlyExpense => 'Importe al mes',
                  ScenarioKind.incomeChange => 'Cuánto ${raise ? 'sube' : 'baja'} cada cobro',
                  ScenarioKind.reserveContribution => 'Cantidad a apartar',
                },
                suffixText: '€'),
          ),
          if (kind == ScenarioKind.incomeChange && incomeSource != null) ...[
            const SizedBox(height: 8),
            TextField(
              controller: delay,
              keyboardType: TextInputType.number,
              decoration: const InputDecoration(labelText: 'Días de retraso del cobro', helperText: '0 si llega en su fecha'),
              onChanged: (_) => setState(_defaults),
            ),
          ],
          if (!(kind == ScenarioKind.incomeChange && incomeSource != null)) ...[
            const SizedBox(height: 8),
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(kind == ScenarioKind.purchase ? 'Fecha' : 'A partir del'),
              trailing: Text(DateFormat("d 'de' MMMM", 'es').format(day), style: const TextStyle(fontWeight: FontWeight.w700)),
              onTap: _pickDay,
            ),
          ],
          if (kind == ScenarioKind.reserveContribution) ...[
            DropdownButtonFormField<String>(
              initialValue: reserveId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Reserva'),
              items: [for (final f in funds) DropdownMenuItem(value: f.id, child: Text(f.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => reserveId = v),
            ),
            SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Cada mes'), value: monthly, onChanged: (v) => setState(() => monthly = v)),
          ],
          if (!(kind == ScenarioKind.incomeChange && incomeSource != null))
            DropdownButtonFormField<String>(
              initialValue: accountId,
              isExpanded: true,
              decoration: InputDecoration(labelText: kind == ScenarioKind.reserveContribution ? 'Desde la cuenta' : 'Cuenta'),
              items: [for (final a in accounts) DropdownMenuItem(value: a.id, child: Text(a.name, overflow: TextOverflow.ellipsis))],
              onChanged: (v) => setState(() => accountId = v),
            ),
          if (kind == ScenarioKind.purchase && funds.isNotEmpty) ...[
            const SizedBox(height: 8),
            DropdownButtonFormField<String?>(
              initialValue: reserveId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Pagar con una reserva'),
              items: [
                const DropdownMenuItem(value: null, child: Text('No, con dinero libre')),
                for (final f in funds) DropdownMenuItem(value: f.id, child: Text(f.name, overflow: TextOverflow.ellipsis)),
              ],
              onChanged: (v) => setState(() => reserveId = v),
            ),
            if (reserveId != null)
              Padding(
                padding: const EdgeInsets.only(top: 6),
                child: Text(
                    reserveHere > 0
                        ? 'La reserva cubre hasta ${money(reserveHere)} en esta cuenta: baja el saldo y la reserva, y tu dinero libre solo por lo que no cubra.'
                        : 'Esta reserva no tiene dinero en esta cuenta: se pagaría con dinero libre.',
                    style: TextStyle(fontSize: 12, color: hint)),
              ),
          ],
          const SizedBox(height: 16),
          FilledButton(onPressed: _save, child: const Text('Guardar y comparar')),
        ]),
      ),
    );
  }
}
