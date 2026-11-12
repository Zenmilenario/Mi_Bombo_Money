import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../banking.dart';
import '../contributions.dart';
import '../data.dart';
import '../presentation.dart';
import 'widgets.dart';

class ContributionsScreen extends StatefulWidget {
  const ContributionsScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  State<ContributionsScreen> createState() => _ContributionsScreenState();
}

class _ContributionsScreenState extends State<ContributionsScreen> {
  final Map<String, Set<String>> selections = {};
  bool busy = false;
  String? message;

  Future<void> _confirm(ContributionProposal proposal, Set<String> selected) async {
    setState(() {
      busy = true;
      message = null;
    });
    try {
      await widget.repository.reconcileContribution(proposal, selected);
      if (mounted) setState(() => message = 'Aportación conciliada. Los cargos sustituyen al apunte previsto.');
    } catch (error) {
      if (mounted) setState(() => message = error is BankingError ? error.message : 'No se ha podido guardar. Revisa la conexión.');
    } finally {
      if (mounted) setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.repository,
      builder: (context, _) {
        final data = widget.repository.finances;
        final proposals = data == null ? <ContributionProposal>[] : widget.repository.contributions;
        return Scaffold(
            appBar: AppBar(title: const Text('Revisar aportaciones')),
            body: ListView(padding: const EdgeInsets.all(16), children: [
              const Text(
                  'Comprueba qué cargos corresponden a tu aportación periódica. Al confirmar, pasan a la cuenta de valores y sustituyen al movimiento previsto.'),
              if (message != null) Padding(padding: const EdgeInsets.symmetric(vertical: 12), child: Text(message!)),
              if (proposals.isEmpty) const ListTile(title: Text('No hay aportaciones pendientes de conciliar.')),
              for (final proposal in proposals)
                Builder(builder: (context) {
                  final selected = selections.putIfAbsent(proposal.id, () => {...?proposal.suggested});
                  final total = proposal.candidates.where((t) => selected.contains(t.id)).fold(0, (sum, t) => sum + t.amountMinor);
                  return Card(
                      child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                            Text(proposal.rule.name, style: Theme.of(context).textTheme.titleMedium),
                            Text('${DateFormat('d/M/yyyy').format(proposal.start)} · pendiente ${money(proposal.remaining)}'),
                            if (proposal.suggested == null) const Text('Hay varias combinaciones posibles. Elige los cargos que corresponden al plan.'),
                            for (final row in proposal.candidates)
                              CheckboxListTile(
                                value: selected.contains(row.id),
                                onChanged: busy
                                    ? null
                                    : (value) => setState(() {
                                          if (value == true) {
                                            selected.add(row.id);
                                          } else {
                                            selected.remove(row.id);
                                          }
                                        }),
                                title: IgnorePointer(child: TransactionTile(transaction: row, data: data!)),
                              ),
                            Text('Seleccionado ${money(total)} de ${money(proposal.remaining)}'),
                            FilledButton(
                                onPressed: busy || total != proposal.remaining ? null : () => _confirm(proposal, {...selected}),
                                child: const Text('Confirmar aportación')),
                          ])));
                }),
            ]));
      });
}
