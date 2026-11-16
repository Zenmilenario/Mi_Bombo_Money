import 'package:flutter/material.dart';

import '../card_payments.dart';
import '../data.dart';
import '../models.dart';

/// Ajustes → Pagos con Apple Pay (iPhone): how to set up the Shortcuts automation and which account each card is.
/// A payment filed in the wrong account would not be paired with the bank's movement and would show twice.
class CardPaymentsScreen extends StatefulWidget {
  const CardPaymentsScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  State<CardPaymentsScreen> createState() => _CardPaymentsScreenState();
}

class _CardPaymentsScreenState extends State<CardPaymentsScreen> {
  ({String? defaultAccount, Map<String, String> cards, List<String> seen})? choice;
  int waiting = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final pending = await CardPaymentInbox.pending();
    await CardPaymentInbox.rememberCards(pending.map((p) => p.card));
    final loaded = await CardPaymentInbox.settings();
    if (mounted) {
      setState(() {
        choice = loaded;
        waiting = pending.length;
      });
    }
  }

  Future<void> _changed() async {
    await _load();
    final filed = await CardPaymentInbox.file(widget.repository);
    if (filed > 0 && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(filed == 1 ? '1 pago apuntado.' : '$filed pagos apuntados.')));
      await _load();
    }
  }

  Widget _accountPicker(String label, String? value, List<Account> accounts, ValueChanged<String?> onChanged) => DropdownButtonFormField<String?>(
        initialValue: accounts.any((a) => a.id == value) ? value : null,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [
          const DropdownMenuItem<String?>(value: null, child: Text('Sin elegir')),
          for (final account in accounts) DropdownMenuItem<String?>(value: account.id, child: Text(account.name)),
        ],
        onChanged: onChanged,
      );

  @override
  Widget build(BuildContext context) {
    final current = choice;
    final accounts = [
      for (final a in widget.repository.finances?.accounts ?? const <Account>[])
        if (!a.isArchived && a.type != AccountType.investment) a
    ];
    return Scaffold(
      appBar: AppBar(title: const Text('Pagos con Apple Pay', style: TextStyle(fontWeight: FontWeight.w700))),
      body: current == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(padding: const EdgeInsets.all(16), children: [
              const Card(
                child: Padding(
                  padding: EdgeInsets.all(16),
                  child: Text('Cada pago con Apple Pay se apunta al momento como gasto pendiente del banco. Cuando llega el '
                      'movimiento del banco, se unen y no se duplica.\n\n'
                      'Para activarlo, en la app Atajos: Automatización → Nueva → Transacción → elige tus tarjetas → '
                      'acción «Apuntar pago con tarjeta» de Doblón, con Importe, Comercio y Tarjeta de la transacción.'),
                ),
              ),
              if (waiting > 0)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 8),
                  child: Text(waiting == 1
                      ? '1 pago espera a que elijas la cuenta de su tarjeta.'
                      : '$waiting pagos esperan a que elijas la cuenta de su tarjeta.'),
                ),
              const SizedBox(height: 12),
              _accountPicker('Cuenta para cualquier tarjeta', current.defaultAccount, accounts, (id) async {
                await CardPaymentInbox.setDefaultAccount(id);
                await _changed();
              }),
              const SizedBox(height: 16),
              if (current.seen.isEmpty)
                const Text('Cuando hagas el primer pago, su tarjeta aparecerá aquí para elegir su cuenta.')
              else ...[
                Text('Cuenta de cada tarjeta', style: Theme.of(context).textTheme.titleSmall),
                const SizedBox(height: 8),
                for (final card in current.seen)
                  Padding(
                    padding: const EdgeInsets.only(bottom: 12),
                    child: _accountPicker(card, current.cards[normalizedCard(card)], accounts, (id) async {
                      await CardPaymentInbox.setCardAccount(card, id);
                      await _changed();
                    }),
                  ),
              ],
            ]),
    );
  }
}
