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
import 'transaction_form.dart' show parseAmount;

/// Previsión y simulaciones: how the balance and the free money could evolve with the person's assumptions, and
/// «what if» simulations compared with it. An estimate, never a guarantee; nothing here changes the finances.
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
  bool showFree = true;
  DateTime? selectedDay;
  late DateTime calendarMonth;

  Object? _planFrom, _planSettings, _planActivity;
  ForecastPlan? _plan;
  ForecastResult? _base;

  FinanceRepository get repository => widget.repository;

  @override
  void initState() {
    super.initState();
    accountId = widget.focusAccountId;
    final today = forecastDay(DateTime.now());
    selectedDay = widget.focusDay == null ? today : forecastDay(widget.focusDay!);
    calendarMonth = DateTime.utc(selectedDay!.year, selectedDay!.month);
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
          appBar: AppBar(title: const Text('Previsión')),
          body: forecast == null || store == null
              ? const Center(child: CircularProgressIndicator())
              : _body(context, forecast.$1, forecast.$2, store),
        );
      },
    );
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
    if (selectedDay != null && (selectedDay!.isBefore(plan.today) || selectedDay!.isAfter(plan.end))) selectedDay = plan.today;
    List<int> series(ForecastResult r) => showFree ? r.free(accountId) : r.balance(accountId);
    final limit = accountId == null && showFree ? plan.settings.cushionMinor : 0;

    return ListView(padding: const EdgeInsets.fromLTRB(16, 4, 16, 32), children: [
      // What it is: an estimate with assumptions, and where its starting point comes from.
      Row(children: [
        Icon(Icons.info_outline, size: 16, color: hint),
        const SizedBox(width: 6),
        Expanded(child: Text('Estimación con tus supuestos, no una garantía.', style: TextStyle(fontSize: 13, color: hint))),
        TextButton(onPressed: () => _assumptions(plan, store), child: const Text('Supuestos')),
      ]),
      _StartLine(plan: plan),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
          child: SegmentedButton<int>(
            segments: const [ButtonSegment(value: 30, label: Text('30 días')), ButtonSegment(value: 60, label: Text('60 días')), ButtonSegment(value: 90, label: Text('90 días'))],
            selected: {plan.settings.horizonDays},
            showSelectedIcon: false,
            onSelectionChanged: (v) => store.saveSettings(plan.settings.copyWith(horizonDays: v.single)),
          ),
        ),
      ]),
      const SizedBox(height: 10),
      // Simulations: the base forecast, the saved ones, and a new one.
      Wrap(spacing: 8, runSpacing: 4, children: [
        ChoiceChip(label: const Text('Previsión base'), selected: scenario == null, onSelected: (_) => setState(() => scenarioId = null)),
        for (final s in store.scenarios) ChoiceChip(label: Text(s.name), selected: s.id == scenarioId, onSelected: (_) => setState(() => scenarioId = s.id)),
        ActionChip(avatar: const Icon(Icons.add, size: 18), label: const Text('Simular'), onPressed: () => _editScenario(plan, store)),
      ]),
      const SizedBox(height: 8),
      Row(children: [
        Expanded(
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
        const SizedBox(width: 8),
        SegmentedButton<bool>(
          segments: const [ButtonSegment(value: true, label: Text('Libre')), ButtonSegment(value: false, label: Text('Saldo'))],
          selected: {showFree},
          showSelectedIcon: false,
          onSelectionChanged: (v) => setState(() => showFree = v.single),
        ),
      ]),
      Text(showFree ? 'Libre: saldo menos lo apartado en reservas.' : 'Saldo: todo el dinero de las cuentas, también el reservado.',
          style: TextStyle(fontSize: 12, color: hint)),
      const SizedBox(height: 8),
      Card(
        child: Padding(
          padding: const EdgeInsets.fromLTRB(8, 16, 16, 8),
          child: SizedBox(
            height: 200,
            child: amountsHidden
                ? Center(child: Text('Importes ocultos', style: TextStyle(color: hint)))
                : _ForecastChart(
                    result: shown,
                    base: simulated == null ? null : series(base),
                    values: series(shown),
                    limit: limit,
                    selected: selectedDay == null ? null : shown.indexOf(selectedDay!),
                    onSelect: (i) => setState(() {
                      selectedDay = shown.dayAt(i);
                      calendarMonth = DateTime.utc(selectedDay!.year, selectedDay!.month);
                    }),
                  ),
          ),
        ),
      ),
      if (simulated != null) _Legend(scenario: scenario!.name),
      const SizedBox(height: 8),
      if (scenario == null)
        _BaseSummary(
            result: base,
            onCushion: () => _assumptions(plan, store),
            onShortfall: (s) => setState(() {
                  accountId = s.account.id;
                  selectedDay = s.day;
                  calendarMonth = DateTime.utc(s.day.year, s.day.month);
                }))
      else
        _ScenarioSummary(
          comparison: ScenarioComparison(base, simulated!, scenario),
          onEdit: () => _editScenario(plan, store, editing: scenario),
          onDelete: () => _deleteScenario(store, scenario),
        ),
      const SizedBox(height: 8),
      _ForecastCalendar(
        result: shown,
        values: series(shown),
        limit: limit,
        month: calendarMonth,
        selected: selectedDay,
        onMonth: (m) => setState(() => calendarMonth = m),
        onDay: (day) => setState(() => selectedDay = day),
      ),
      if (selectedDay != null) _DayDetail(result: shown, day: selectedDay!, accountId: accountId, showFree: showFree, onEvent: (e) => _event(plan, store, e)),
      const SizedBox(height: 16),
      Text('Las simulaciones no crean movimientos, no cambian tus saldos ni enseñan a la IA. Se guardan solo en este dispositivo.',
          style: TextStyle(fontSize: 12, color: hint)),
    ]);
  }

  Future<void> _assumptions(ForecastPlan plan, ForecastStore store) => showModalBottomSheet<void>(
        context: context,
        isScrollControlled: true,
        showDragHandle: true,
        builder: (_) => _AssumptionsSheet(plan: plan, store: store),
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

class _ForecastChart extends StatelessWidget {
  const _ForecastChart({required this.result, required this.values, this.base, required this.limit, this.selected, required this.onSelect});
  final ForecastResult result;
  final List<int> values;
  final List<int>? base;
  final int limit;
  final int? selected;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final all = [...values, ...?base, limit];
    final low = all.reduce(math.min) / 100, high = all.reduce(math.max) / 100;
    final margin = math.max((high - low) * 0.12, 10.0);
    var lowest = 0;
    for (var i = 1; i < values.length; i++) {
      if (values[i] < values[lowest]) lowest = i;
    }
    final day = DateFormat("d 'de' MMM", 'es');
    final step = values.length > 45 ? 14 : 7;
    LineChartBarData line(List<int> v, Color color, {bool dashed = false, bool marks = false}) => LineChartBarData(
          spots: [for (var i = 0; i < v.length; i++) FlSpot(i.toDouble(), v[i] / 100)],
          isCurved: false,
          color: color,
          barWidth: dashed ? 2 : 3,
          dashArray: dashed ? [5, 4] : null,
          dotData: FlDotData(
            show: marks,
            checkToShowDot: (spot, _) => spot.x.round() == lowest || spot.x.round() == selected,
            getDotPainter: (spot, _, __, ___) => FlDotCirclePainter(radius: 4.5, color: color, strokeWidth: 2, strokeColor: pulso.card),
          ),
          belowBarData: BarAreaData(
            show: !dashed,
            gradient: LinearGradient(begin: Alignment.topCenter, end: Alignment.bottomCenter, colors: [color.withValues(alpha: 0.18), color.withValues(alpha: 0)]),
          ),
        );
    final (minValue, minDay) = (values[lowest], result.dayAt(lowest));
    return Semantics(
      label: 'Previsión: mínimo ${money(minValue)} el ${day.format(minDay)}; al final ${money(values.last)}.',
      child: LineChart(LineChartData(
        minY: low - margin,
        maxY: high + margin,
        gridData: FlGridData(
          drawVerticalLine: false,
          getDrawingHorizontalLine: (_) => FlLine(color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.06), strokeWidth: 1),
        ),
        borderData: FlBorderData(show: false),
        extraLinesData: ExtraLinesData(horizontalLines: [
          if (limit > 0)
            HorizontalLine(
              y: limit / 100,
              color: pulso.warning,
              strokeWidth: 1.5,
              dashArray: [6, 4],
              label: HorizontalLineLabel(
                  show: true, alignment: Alignment.topRight, labelResolver: (_) => 'Colchón', style: TextStyle(color: pulso.warning, fontSize: 11, fontWeight: FontWeight.w700)),
            )
          else
            HorizontalLine(y: 0, color: Theme.of(context).colorScheme.onSurface.withValues(alpha: 0.25), strokeWidth: 1),
        ]),
        lineTouchData: LineTouchData(
          touchCallback: (event, response) {
            final spot = response?.lineBarSpots?.firstOrNull;
            if (event is FlTapUpEvent && spot != null) onSelect(spot.x.round());
          },
          touchTooltipData: LineTouchTooltipData(
            getTooltipColor: (_) => Theme.of(context).colorScheme.onSurface,
            getTooltipItems: (spots) => [
              for (final (n, s) in spots.indexed)
                LineTooltipItem(n == 0 ? '${day.format(result.dayAt(s.x.round()))}\n' : '', TextStyle(color: pulso.page, fontSize: 11), children: [
                  TextSpan(
                      text: '${base != null ? (s.barIndex == 0 ? 'Previsión ' : 'Simulación ') : ''}${money((s.y * 100).round())}',
                      style: TextStyle(color: pulso.page, fontWeight: FontWeight.w800, fontSize: 13)),
                ]),
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
                final i = value.round();
                if (i < 0 || i >= values.length || i % step != 0) return const SizedBox.shrink();
                final d = result.dayAt(i);
                return Padding(padding: const EdgeInsets.only(top: 4), child: Text('${d.day}/${d.month}', style: Theme.of(context).textTheme.bodySmall));
              },
            ),
          ),
        ),
        lineBarsData: [
          if (base != null) line(base!, Theme.of(context).hintColor, dashed: true),
          line(values, pulso.accent, marks: true),
        ],
      )),
    );
  }
}

class _Legend extends StatelessWidget {
  const _Legend({required this.scenario});
  final String scenario;

  @override
  Widget build(BuildContext context) {
    final hint = Theme.of(context).hintColor;
    Widget mark(Color color, String text, {bool dashed = false}) => Row(mainAxisSize: MainAxisSize.min, children: [
          Container(width: 18, height: dashed ? 2 : 3, color: color),
          const SizedBox(width: 6),
          Flexible(child: Text(text, style: TextStyle(fontSize: 12, color: hint), overflow: TextOverflow.ellipsis)),
        ]);
    return Padding(
      padding: const EdgeInsets.only(top: 6, left: 4),
      child: Wrap(spacing: 16, runSpacing: 4, children: [mark(Pulso.of(context).accent, 'Con «$scenario»'), mark(hint, 'Previsión base', dashed: true)]),
    );
  }
}

/// The base forecast in a few figures: the low point and when, the end, the cushion and the accounts that run short.
class _BaseSummary extends StatelessWidget {
  const _BaseSummary({required this.result, required this.onCushion, required this.onShortfall});
  final ForecastResult result;
  final VoidCallback onCushion;
  final ValueChanged<Shortfall> onShortfall;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final (low, lowDay) = result.minimum;
    final cushion = result.plan.settings.cushionMinor;
    final breach = result.cushionBreach();
    final cause = breach == null ? null : result.mainOutflowUntil(breach);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Text('Mínimo libre previsto', style: TextStyle(fontSize: 13, color: hint)),
          Text(money(low), style: TextStyle(fontSize: 26, fontWeight: FontWeight.w800, letterSpacing: -0.5, color: breach != null ? pulso.warning : null)),
          Text('El ${DateFormat("EEEE d 'de' MMMM", 'es').format(lowDay)} · al final del periodo ${money(result.endFree)}', style: TextStyle(color: hint)),
          const SizedBox(height: 12),
          InkWell(
            onTap: onCushion,
            child: Row(children: [
              Icon(breach == null ? Icons.verified_outlined : Icons.warning_amber_rounded, size: 18, color: breach == null ? pulso.income : pulso.warning),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  cushion <= 0
                      ? (breach == null ? 'No baja de cero. Define tu colchón para avisarte antes.' : 'Bajaría de cero el ${shortDay(breach)}.')
                      : breach == null
                          ? 'Se mantiene por encima de tu colchón de ${money(cushion)}.'
                          : 'Bajaría de tu colchón de ${money(cushion)} el ${shortDay(breach)}${cause == null ? '' : ', sobre todo por ${cause.label}'}.',
                ),
              ),
              const Icon(Icons.edit_outlined, size: 16),
            ]),
          ),
          for (final s in result.shortfalls)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: InkWell(
                onTap: () => onShortfall(s),
                child: Row(children: [
                  Icon(Icons.account_balance_wallet_outlined, size: 18, color: pulso.warning),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text('«${s.account.name}» sin saldo el ${shortDay(s.day)}${s.cause == null ? '' : ' por ${s.cause!.label}'}'
                        '${s.elsewhereFreeMinor >= -s.balanceMinor ? '; en otras cuentas hay dinero libre' : ''}.'),
                  ),
                  const Icon(Icons.chevron_right, size: 18),
                ]),
              ),
            ),
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

/// The horizon as a calendar: a dot on days with planned items, the day number in warning colour when the money
/// shown goes below the cushion (or zero). Tapping a day lists what happens in it.
class _ForecastCalendar extends StatelessWidget {
  const _ForecastCalendar(
      {required this.result, required this.values, required this.limit, required this.month, this.selected, required this.onMonth, required this.onDay});
  final ForecastResult result;
  final List<int> values;
  final int limit;
  final DateTime month;
  final DateTime? selected;
  final ValueChanged<DateTime> onMonth;
  final ValueChanged<DateTime> onDay;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final plan = result.plan;
    final first = DateTime.utc(month.year, month.month);
    final days = DateTime.utc(month.year, month.month + 1, 0).day;
    final lead = first.weekday - 1;
    final canBack = first.isAfter(DateTime.utc(plan.today.year, plan.today.month));
    final canForward = DateTime.utc(month.year, month.month + 1).isBefore(plan.end) || DateTime.utc(month.year, month.month + 1) == plan.end;
    final planned = <DateTime>{for (final e in result.events) if (!e.isVariable) e.day};
    return Card(
      child: Padding(
        padding: const EdgeInsets.fromLTRB(8, 4, 8, 12),
        child: Column(children: [
          Row(children: [
            IconButton(
                tooltip: 'Mes anterior', onPressed: canBack ? () => onMonth(DateTime.utc(month.year, month.month - 1)) : null, icon: const Icon(Icons.chevron_left)),
            Expanded(
                child: Text(toBeginningOfSentenceCase(DateFormat('MMMM yyyy', 'es').format(month)),
                    textAlign: TextAlign.center, style: const TextStyle(fontWeight: FontWeight.w700))),
            IconButton(
                tooltip: 'Mes siguiente',
                onPressed: canForward ? () => onMonth(DateTime.utc(month.year, month.month + 1)) : null,
                icon: const Icon(Icons.chevron_right)),
          ]),
          Row(children: [
            for (final d in const ['L', 'M', 'X', 'J', 'V', 'S', 'D'])
              Expanded(child: Text(d, textAlign: TextAlign.center, style: TextStyle(fontSize: 12, color: hint, fontWeight: FontWeight.w600))),
          ]),
          const SizedBox(height: 4),
          for (var week = 0; week * 7 < lead + days; week++)
            Row(children: [
              for (var col = 0; col < 7; col++)
                Expanded(
                  child: Builder(builder: (context) {
                    final n = week * 7 + col - lead + 1;
                    if (n < 1 || n > days) return const SizedBox(height: 44);
                    final day = DateTime.utc(month.year, month.month, n);
                    final inside = !day.isBefore(plan.today) && !day.isAfter(plan.end);
                    final value = inside ? values[result.indexOf(day)] : null;
                    final low = value != null && value < limit;
                    final isSelected = day == selected;
                    return Semantics(
                      button: inside,
                      label: inside ? '${DateFormat("d 'de' MMMM", 'es').format(day)}: ${money(value!)}${planned.contains(day) ? ', con movimientos previstos' : ''}' : null,
                      excludeSemantics: true,
                      child: InkWell(
                        borderRadius: BorderRadius.circular(10),
                        onTap: inside ? () => onDay(day) : null,
                        child: Container(
                          height: 44,
                          margin: const EdgeInsets.all(1.5),
                          decoration: BoxDecoration(
                            color: isSelected ? pulso.accent.withValues(alpha: 0.16) : null,
                            borderRadius: BorderRadius.circular(10),
                            border: day == plan.today ? Border.all(color: pulso.accent) : null,
                          ),
                          child: Column(mainAxisAlignment: MainAxisAlignment.center, children: [
                            Text('$n',
                                style: TextStyle(
                                  fontWeight: isSelected ? FontWeight.w800 : FontWeight.w500,
                                  color: !inside ? hint.withValues(alpha: 0.4) : (low ? pulso.warning : null),
                                )),
                            const SizedBox(height: 3),
                            Container(
                              width: 5,
                              height: 5,
                              decoration: BoxDecoration(shape: BoxShape.circle, color: inside && planned.contains(day) ? pulso.accent : Colors.transparent),
                            ),
                          ]),
                        ),
                      ),
                    );
                  }),
                ),
            ]),
        ]),
      ),
    );
  }
}

/// What happens on the chosen day and what is left at its end. The variable spending is one line.
class _DayDetail extends StatelessWidget {
  const _DayDetail({required this.result, required this.day, this.accountId, required this.showFree, required this.onEvent});
  final ForecastResult result;
  final DateTime day;
  final String? accountId;
  final bool showFree;
  final ValueChanged<ForecastEvent> onEvent;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final events = result.on(day, accountId);
    final planned = events.where((e) => !e.isVariable).toList();
    final variable = events.where((e) => e.isVariable).fold(0, (sum, e) => sum + e.amountMinor);
    final index = result.indexOf(day);
    final value = (showFree ? result.free(accountId) : result.balance(accountId))[index];
    int effect(ForecastEvent e) => accountId != null && e.destinationId == accountId ? -e.amountMinor : (accountId == null && e.isTransfer ? 0 : e.amountMinor);
    return Padding(
      padding: const EdgeInsets.only(top: 12),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Text(toBeginningOfSentenceCase(DateFormat("EEEE d 'de' MMMM", 'es').format(day)), style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
        Text('${showFree ? 'Libre' : 'Saldo'} al final del día: ${money(value)}', style: TextStyle(color: hint)),
        if (planned.isEmpty && variable == 0) Padding(padding: const EdgeInsets.only(top: 8), child: Text('Nada previsto este día.', style: TextStyle(color: hint))),
        for (final e in planned)
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => onEvent(e),
            title: Text(e.label, maxLines: 2, overflow: TextOverflow.ellipsis),
            subtitle: Text([
              e.certainty.title,
              result.plan.account(e.accountId)?.name ?? '',
              if (e.destinationId != null) '→ ${result.plan.account(e.destinationId!)?.name ?? ''}',
              if (e.detail.isNotEmpty) e.detail,
            ].where((t) => t.isNotEmpty).join(' · ')),
            trailing: Text(e.isTransfer && accountId == null ? money(e.amountMinor.abs()) : money(effect(e), signed: true),
                style: TextStyle(fontWeight: FontWeight.w700, color: e.isTransfer && accountId == null ? hint : (effect(e) >= 0 ? pulso.income : pulso.expense))),
          ),
        if (variable != 0)
          ListTile(
            contentPadding: EdgeInsets.zero,
            onTap: () => onEvent(events.firstWhere((e) => e.isVariable)),
            title: const Text('Gasto variable estimado'),
            subtitle: const Text('Estimado · lo que dejan tus presupuestos y tu gasto habitual'),
            trailing: Text(money(variable), style: TextStyle(fontWeight: FontWeight.w700, color: pulso.expense)),
          ),
      ]),
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
