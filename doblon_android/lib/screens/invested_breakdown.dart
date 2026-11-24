import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../finance.dart';
import '../investments.dart';
import '../presentation.dart';
import '../theme.dart';

/// The investment summary and its portfolios. Two separate choices: which portfolios make up the summary (chosen
/// here, kept for this person on this device) and which count in net worth (set in each account, unchanged here).
/// Each portfolio shows its value and where it comes from: a valuation and its date (written by the person or
/// reported by a bank) plus what was recorded after it, never a market price.
Future<void> showInvestedBreakdown(BuildContext context, FinanceRepository repository) => showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => ListenableBuilder(
        listenable: repository,
        builder: (context, _) {
          final data = repository.finances;
          if (data == null) return const SizedBox.shrink();
          final calc = FinanceCalculator(data);
          final now = DateTime.now();
          final hidden = repository.hiddenPortfolios;
          final values = portfolioValues(data, calc.balance, now);
          final shownIds = {for (final a in summaryPortfolios(data, hidden)) a.id};
          final inSummary = values.where((v) => shownIds.contains(v.account.id)).fold(0, (sum, v) => sum + v.valueMinor);
          final flows = investmentFlows(data, DateTime(now.year, now.month), now: now, accounts: shownIds);
          final day = DateFormat("d 'de' MMMM", 'es');
          final hint = Theme.of(context).hintColor;
          final pulso = Pulso.of(context);
          String basis(PortfolioValue v) {
            final valuation = v.valuation;
            final after = v.movementsAfter == 0
                ? ''
                : ' + ${v.movementsAfter == 1 ? '1 movimiento posterior' : '${v.movementsAfter} movimientos posteriores'} (${money(v.afterMinor, signed: true)})';
            if (valuation == null) return 'Sin valoración: suma de lo registrado$after';
            final age = DateTime(now.year, now.month, now.day).difference(DateTime(valuation.date.year, valuation.date.month, valuation.date.day)).inDays;
            final source = v.fromBank ? 'Saldo comunicado por el banco' : 'Valoración que indicaste';
            return '$source el ${day.format(valuation.date)}${age > 7 ? ' (hace $age días)' : ''}$after';
          }

          return SafeArea(
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 24), children: [
              Text('Tus carteras', style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
              Text('Elige cuáles forman tu resumen de inversión. Que una cartera cuente o no en tu patrimonio se decide aparte, en su ficha.',
                  style: TextStyle(color: hint)),
              const SizedBox(height: 8),
              if (values.isEmpty) const Text('No tienes cuentas de tipo Inversión.'),
              for (final v in values)
                SwitchListTile(
                  contentPadding: EdgeInsets.zero,
                  value: shownIds.contains(v.account.id),
                  onChanged: (shown) => repository.setPortfolioInSummary(v.account.id, shown),
                  title: Row(children: [
                    Expanded(child: Text(v.account.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600))),
                    Text(money(v.valueMinor), style: const TextStyle(fontWeight: FontWeight.w700)),
                  ]),
                  subtitle: Text('${basis(v)}\n${v.counted ? 'Cuenta en tu patrimonio' : 'Fuera de tu patrimonio'}'),
                  isThreeLine: true,
                ),
              const Divider(),
              _Line(label: 'Resumen de inversión', value: money(inSummary)),
              Text('Es el valor registrado en la app, no una cotización en tiempo real.', style: TextStyle(fontSize: 12, color: hint)),
              const SizedBox(height: 12),
              Text('Este mes, en estas carteras', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
              _Line(label: 'Aportado', value: money(flows.contributedMinor), color: pulso.investment),
              _Line(label: 'Retirado', value: money(flows.withdrawnMinor)),
              _Line(label: 'Comisiones', value: money(flows.feesMinor), color: flows.feesMinor > 0 ? pulso.expense : null),
              const SizedBox(height: 8),
              Text(
                  'Una valoración sustituye al valor anterior en su fecha; lo aportado después se suma una vez. Aportar no es rentabilidad, y la comisión sale del efectivo.',
                  style: TextStyle(fontSize: 12, color: hint)),
            ]),
          );
        },
      ),
    );

class _Line extends StatelessWidget {
  const _Line({required this.label, required this.value, this.color});
  final String label, value;
  final Color? color;

  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.symmetric(vertical: 3),
        child: Row(children: [
          Expanded(child: Text(label)),
          Text(value, style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        ]),
      );
}
