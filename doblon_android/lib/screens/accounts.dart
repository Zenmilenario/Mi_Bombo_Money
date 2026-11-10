import 'package:flutter/material.dart';

import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';

/// Cuentas: each active account with its balance and the money reserved in it.
class AccountsScreen extends StatelessWidget {
  const AccountsScreen({super.key, required this.calc});
  final FinanceCalculator calc;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final data = calc.data;
    final active = data.accounts.where((a) => !a.isArchived).toList();
    return ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
      Row(children: [
        Expanded(child: _Summary(label: 'Patrimonio', value: money(calc.netWorth()), color: pulso.accent)),
        const SizedBox(width: 10),
        Expanded(child: _Summary(label: 'Disponible', value: money(calc.spendableCash()), color: pulso.income)),
      ]),
      const SizedBox(height: 16),
      if (active.isEmpty) const Text('Sin cuentas activas.'),
      for (final account in active) ...[
        _AccountCard(account: account, calc: calc),
        const SizedBox(height: 10),
      ],
    ]);
  }
}

class _Summary extends StatelessWidget {
  const _Summary({required this.label, required this.value, required this.color});
  final String label, value;
  final Color color;
  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Text(label, style: Theme.of(context).textTheme.labelMedium),
            FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: Text(value, style: TextStyle(fontSize: 20, fontWeight: FontWeight.w800, color: color))),
          ]),
        ),
      );
}

class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.calc});
  final Account account;
  final FinanceCalculator calc;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final balance = calc.balance(account);
    final reserved = account.type.isLiability || account.type == AccountType.investment ? 0 : calc.reservedAmount(account);
    final institution = calc.data.institutionName(account.institutionId);
    return Card(
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Row(children: [
            Icon(account.bankIdentityKey != null ? Icons.link : Icons.account_balance_wallet_outlined, color: pulso.accent, size: 20),
            const SizedBox(width: 10),
            Expanded(
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text(account.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                Text([institution, account.type.title].whereType<String>().join(' · '), style: Theme.of(context).textTheme.bodySmall),
              ]),
            ),
            Text(money(balance, currency: account.currencyCode),
                style: TextStyle(fontWeight: FontWeight.w800, fontSize: 16, color: balance < 0 ? pulso.expense : null)),
          ]),
          if (reserved > 0) ...[
            const SizedBox(height: 10),
            Text(
                'Reservado ${money(reserved, currency: account.currencyCode)} · libre ${money(balance - reserved > 0 ? balance - reserved : 0, currency: account.currencyCode)}',
                style: TextStyle(fontSize: 12, color: pulso.warning)),
          ],
          if (!account.includeInNetWorth) ...[
            const SizedBox(height: 6),
            Text('No cuenta en el patrimonio', style: Theme.of(context).textTheme.bodySmall),
          ],
        ]),
      ),
    );
  }
}
