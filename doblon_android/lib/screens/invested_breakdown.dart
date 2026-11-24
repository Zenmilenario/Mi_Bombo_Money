import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../finance.dart';
import '../investments.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';

/// The label of «Invertido»: when a portfolio is left out of net worth, the figure is only part of what is invested,
/// and says so.
String investedLabel(Finances data) =>
    data.accounts.any((a) => !a.isArchived && a.type == AccountType.investment && !a.includeInNetWorth) ? 'Invertido en patrimonio' : 'Invertido';

/// What «Invertido» is made of: each portfolio with its value, whether it counts in net worth, and where the value
/// comes from (a valuation and its date, written by the person or reported by a bank, plus what was recorded after
/// it). The person's net worth choices are kept; an old valuation is said to be old, never shown as a market price.
Future<void> showInvestedBreakdown(BuildContext context, FinanceCalculator calc) {
  final now = DateTime.now();
  final values = portfolioValues(calc.data, calc.balance, now);
  final counted = values.where((v) => v.counted).fold(0, (sum, v) => sum + v.valueMinor);
  final outside = values.where((v) => !v.counted).fold(0, (sum, v) => sum + v.valueMinor);
  final flows = investmentFlows(calc.data, DateTime(now.year, now.month), now: now);
  final day = DateFormat("d 'de' MMMM", 'es');
  return showModalBottomSheet<void>(
    context: context,
    showDragHandle: true,
    isScrollControlled: true,
    builder: (context) {
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
          Text('Es el valor registrado en la app, no una cotización en tiempo real.', style: TextStyle(color: hint)),
          const SizedBox(height: 12),
          if (values.isEmpty) const Text('No tienes cuentas de tipo Inversión.'),
          for (final v in values)
            ListTile(
              contentPadding: EdgeInsets.zero,
              title: Text(v.account.name, maxLines: 2, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text('${v.counted ? 'Cuenta en tu patrimonio' : 'Fuera de tu patrimonio (lo elegiste así)'}\n${basis(v)}'),
              isThreeLine: true,
              trailing: Text(money(v.valueMinor), style: TextStyle(fontWeight: FontWeight.w700, color: v.counted ? null : hint)),
            ),
          const Divider(),
          _Line(label: 'Invertido en patrimonio', value: money(counted)),
          if (outside != 0) _Line(label: 'Fuera del patrimonio', value: money(outside), color: hint),
          const SizedBox(height: 12),
          Text('Este mes', style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
          _Line(label: 'Aportado', value: money(flows.contributedMinor), color: pulso.investment),
          _Line(label: 'Retirado', value: money(flows.withdrawnMinor)),
          _Line(label: 'Comisiones', value: money(flows.feesMinor), color: flows.feesMinor > 0 ? pulso.expense : null),
          const SizedBox(height: 8),
          Text(
              'Una valoración sustituye al valor anterior en su fecha; las aportaciones posteriores se suman una vez. '
              'Aportar no es rentabilidad. Puedes cambiar si una cartera cuenta en tu patrimonio desde su ficha en Cuentas.',
              style: TextStyle(fontSize: 12, color: hint)),
        ]),
      );
    },
  );
}

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
