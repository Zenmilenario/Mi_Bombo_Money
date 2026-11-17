import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../bank_activity.dart';
import '../banking.dart' show referenceSeconds, stableUuid;
import '../data.dart';
import '../edits.dart';
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'forms.dart';
import 'manage.dart' show RecurringScreen;
import 'transaction_detail.dart';
import 'chrome.dart' show tabListPadding;
import 'widgets.dart';

/// Cuentas, as on the iPhone (`AccountsView`): net worth, available, reserved and invested; the accounts not updated
/// for 30 days; quick actions; the accounts grouped by kind and the cards.
class AccountsScreen extends StatefulWidget {
  const AccountsScreen({super.key, required this.calc, required this.repository});
  final FinanceCalculator calc;
  final FinanceRepository repository;
  @override
  State<AccountsScreen> createState() => _AccountsScreenState();
}

/// Not updated by hand for 30 days and not fed by a bank.
bool isStaleAccount(Account a, DateTime now) =>
    a.bankIdentityKey == null && !a.isArchived && a.lastUpdatedAt.isBefore(now.subtract(const Duration(days: 30)));

/// Label of a linked account: "Al día" only when the bank sent a booked balance in the last 2 days. Without
/// one (Trade Republic may send none) the balance is the opening balance plus movements, not checked by the bank.
String? bankBalanceLabel(Account a, List<BalanceSnapshot> snapshots, DateTime now) {
  if (a.bankIdentityKey == null) return null;
  final id = stableUuid('${a.bankIdentityKey}|booked-balance');
  final bank = snapshots.where((s) => s.id.toLowerCase() == id).firstOrNull;
  if (bank == null) return 'Sin saldo del banco';
  return bank.date.isBefore(now.subtract(const Duration(days: 2))) ? 'Saldo sin confirmar' : 'Al día';
}

class _AccountsScreenState extends State<AccountsScreen> {
  bool onlyStale = false;

  Future<void> _updateBalance(BuildContext context, List<Account> accounts) async {
    final chosen = await showModalBottomSheet<Account>(
      context: context,
      showDragHandle: true,
      builder: (context) => ListView(shrinkWrap: true, children: [
        const ListTile(title: Text('Elige la cuenta', style: TextStyle(fontWeight: FontWeight.w700))),
        for (final a in accounts)
          ListTile(
            title: Text(a.name),
            subtitle: Text(money(widget.calc.balance(a), currency: a.currencyCode)),
            onTap: () => Navigator.pop(context, a),
          ),
      ]),
    );
    if (chosen != null && context.mounted) {
      await Navigator.of(context).push(MaterialPageRoute(
          builder: (_) => BalanceFormScreen(repository: widget.repository, account: chosen, current: widget.calc.balance(chosen))));
    }
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final calc = widget.calc;
    final data = calc.data;
    final now = DateTime.now();
    final active = data.accounts.where((a) => !a.isArchived).toList();
    final archived = data.accounts.where((a) => a.isArchived).toList();
    final stale = active.where((a) => isStaleAccount(a, now)).toList();
    final shown = onlyStale ? stale : active;
    final cards = data.cards.where((c) => !c.isArchived).toList();
    final groups = <(String, bool Function(Account))>[
      ('Día a día', (a) => a.type == AccountType.checking || a.type == AccountType.cash),
      ('Ahorro', (a) => a.type == AccountType.savings),
      ('Inversiones', (a) => a.type == AccountType.investment),
      ('Deudas y crédito', (a) => a.type.isLiability),
      ('Otras cuentas', (a) => a.type == AccountType.other),
    ];
    Widget tile(String label, int value, IconData icon, Color color) => Container(
          padding: const EdgeInsets.all(12),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.10), borderRadius: BorderRadius.circular(Pulso.cardRadius)),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Icon(icon, size: 15, color: color),
              const SizedBox(width: 5),
              Text(label, style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
            ]),
            const SizedBox(height: 4),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(money(value), style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        );
    Widget chip(String label, IconData icon, VoidCallback? onTap) => Padding(
          padding: const EdgeInsets.only(right: 8),
          child: ActionChip(avatar: Icon(icon, size: 17, color: pulso.accent), label: Text(label), onPressed: onTap),
        );
    return Scaffold(
      backgroundColor: Colors.transparent,
      // At the left of the dock's row, where «+ Añadir» and Don Bigotes are on the right.
      floatingActionButtonLocation: FloatingActionButtonLocation.startFloat,
      floatingActionButton: FloatingActionButton(
        tooltip: 'Añadir cuenta',
        onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountFormScreen(repository: widget.repository))),
        child: const Icon(Icons.add),
      ),
      body: ListView(
          physics: const AlwaysScrollableScrollPhysics(),
          padding: tabListPadding(context, top: 12),
          children: [
            LayoutBuilder(builder: (context, c) {
              final perRow = c.maxWidth >= 600 ? 4 : 2;
              final width = (c.maxWidth - (perRow - 1) * 10) / perRow;
              return Wrap(spacing: 10, runSpacing: 10, children: [
                for (final t in [
                  tile('Patrimonio', calc.netWorth(), Icons.functions, Theme.of(context).colorScheme.onSurface),
                  tile('Disponible', calc.spendableCash(), Icons.account_balance_wallet_outlined, pulso.accent),
                  tile('Reservado', calc.reservedTotal(), Icons.lock_outline, pulso.savings),
                  tile('Invertido', calc.invested(), Icons.trending_up, pulso.investment),
                ])
                  SizedBox(width: width, child: t),
              ]);
            }),
            if (stale.isNotEmpty) ...[
              const SizedBox(height: 12),
              Material(
                color: pulso.warning.withValues(alpha: 0.12),
                borderRadius: BorderRadius.circular(Pulso.compactRadius),
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.update, color: pulso.warning),
                  title: Text(onlyStale ? 'Mostrar todas las cuentas' : 'Revisar saldos sin actualizar (${stale.length})',
                      style: TextStyle(color: pulso.warning, fontWeight: FontWeight.w600)),
                  trailing: Icon(Icons.chevron_right, color: pulso.warning),
                  onTap: () => setState(() => onlyStale = !onlyStale),
                ),
              ),
            ],
            const SizedBox(height: 12),
            SingleChildScrollView(
              scrollDirection: Axis.horizontal,
              child: Row(children: [
                chip('Actualizar saldo', Icons.refresh, active.isEmpty ? null : () => _updateBalance(context, active)),
                chip('Cargos periódicos', Icons.event_repeat,
                    () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => RecurringScreen(repository: widget.repository)))),
                chip('Añadir tarjeta', Icons.credit_card,
                    () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CardFormScreen(repository: widget.repository)))),
              ]),
            ),
            if (active.isEmpty) const Padding(padding: EdgeInsets.only(top: 16), child: Text('Aún no tienes cuentas. Pulsa + para añadir la primera.')),
            for (final (title, test) in groups)
              if (shown.where(test).toList() case final items when items.isNotEmpty) ...[
                SectionTitle(title),
                for (final account in items) ...[
                  _AccountCard(account: account, calc: calc, repository: widget.repository, now: now),
                  const SizedBox(height: 10),
                ],
              ],
            if (cards.isNotEmpty && !onlyStale) ...[
              const SectionTitle('Tus tarjetas'),
              Card(
                child: Column(children: [
                  for (final card in cards)
                    ListTile(
                      leading: RowGlyph(icon: card.type == CardType.credit ? Icons.credit_card : Icons.credit_card_outlined, tint: pulso.accent),
                      title: Text(card.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                      subtitle: Text([
                        card.type.title,
                        if (card.lastFour.isNotEmpty) '•••• ${card.lastFour}',
                        if (data.account(card.linkedAccountId) case final a?) a.name,
                      ].join(' · ')),
                      trailing: const Icon(Icons.chevron_right),
                      onTap: () =>
                          Navigator.of(context).push(MaterialPageRoute(builder: (_) => CardFormScreen(repository: widget.repository, editing: card))),
                    ),
                ]),
              ),
            ],
            if (archived.isNotEmpty && !onlyStale)
              ExpansionTile(
                title: Text('Archivadas (${archived.length})'),
                children: [for (final a in archived) _AccountCard(account: a, calc: calc, repository: widget.repository, now: now)],
              ),
          ]),
    );
  }
}

/// One account as on the iPhone: its bank's colour, its state, the balance and how it splits (free, reserved, held).
class _AccountCard extends StatelessWidget {
  const _AccountCard({required this.account, required this.calc, required this.repository, required this.now});
  final Account account;
  final FinanceCalculator calc;
  final FinanceRepository repository;
  final DateTime now;

  String _updated(DateTime when) {
    final days = DateTime(now.year, now.month, now.day).difference(DateTime(when.year, when.month, when.day)).inDays;
    return days <= 0 ? 'hoy' : (days == 1 ? 'ayer' : 'hace $days días');
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final balance = calc.balance(account);
    final reserved = account.type.isLiability || account.type == AccountType.investment ? 0 : calc.reservedAmount(account);
    final activity = account.bankIdentityKey == null ? null : repository.bankActivity[account.bankIdentityKey];
    final charges = account.isArchived ? const <PendingMovement>[] : (activity?.pendingMovements ?? const <PendingMovement>[]).where((m) => m.signedAmountMinor < 0).toList();
    final held = charges.fold(0, (s, m) => s - m.signedAmountMinor);
    final free = balance - reserved - held > 0 ? balance - reserved - held : 0;
    final institution = calc.data.institutions.where((i) => i.id == account.institutionId).firstOrNull;
    final tint = colorFromHex(institution?.colorHex ?? '#1F6B7A');
    final stale = isStaleAccount(account, now);
    final cardCount = calc.data.cards.where((c) => c.linkedAccountId == account.id && !c.isArchived).length;
    Widget pill(String text, Color color, [IconData? icon]) => Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
          decoration: BoxDecoration(color: color.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(20)),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            if (icon != null) ...[Icon(icon, size: 12, color: color), const SizedBox(width: 3)],
            Text(text, style: TextStyle(fontSize: 11, fontWeight: FontWeight.w600, color: color)),
          ]),
        );
    final icon = institution != null
        ? Icons.account_balance
        : switch (account.type) {
            AccountType.cash => Icons.payments_outlined,
            AccountType.investment => Icons.trending_up,
            AccountType.savings => Icons.savings_outlined,
            AccountType.creditCard => Icons.credit_card,
            _ => Icons.account_balance_wallet_outlined,
          };
    return Card(
      child: InkWell(
        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountDetailScreen(repository: repository, accountId: account.id))),
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              Container(
                width: 42,
                height: 42,
                decoration: BoxDecoration(color: tint.withValues(alpha: 0.13), borderRadius: BorderRadius.circular(12)),
                child: Icon(icon, color: tint),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(institution?.name ?? account.name, style: const TextStyle(fontWeight: FontWeight.w700)),
                  Text(institution == null ? account.type.title : account.name,
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 12, color: hint)),
                ]),
              ),
              if (stale)
                pill('Sin actualizar', pulso.warning, Icons.schedule)
              else if (bankBalanceLabel(account, calc.data.snapshots, now) case final label?)
                pill(label, label == 'Al día' ? pulso.accent : pulso.warning),
            ]),
            const SizedBox(height: 10),
            Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
              Expanded(
                child: FittedBox(
                  fit: BoxFit.scaleDown,
                  alignment: Alignment.centerLeft,
                  child: Text(money(balance, currency: account.currencyCode),
                      style: TextStyle(fontSize: 24, fontWeight: FontWeight.w800, color: balance < 0 ? pulso.expense : null)),
                ),
              ),
              Text('Actualizada ${_updated(account.lastUpdatedAt)}', style: TextStyle(fontSize: 11, color: hint.withValues(alpha: 0.7))),
            ]),
            if (reserved > 0 || held > 0) ...[
              const SizedBox(height: 8),
              ClipRRect(
                borderRadius: BorderRadius.circular(4),
                child: SizedBox(
                  height: 7,
                  // Stretched: an empty coloured box would otherwise be zero pixels high.
                  child: Row(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    if (free > 0) Expanded(flex: free, child: ColoredBox(color: pulso.accent)),
                    if (reserved > 0) ...[const SizedBox(width: 2), Expanded(flex: reserved, child: ColoredBox(color: pulso.savings))],
                    if (held > 0) ...[const SizedBox(width: 2), Expanded(flex: held, child: ColoredBox(color: pulso.warning))],
                  ]),
                ),
              ),
              const SizedBox(height: 6),
              Text.rich(TextSpan(style: const TextStyle(fontSize: 12), children: [
                TextSpan(text: 'Libre ', style: TextStyle(color: hint)),
                TextSpan(text: money(free, currency: account.currencyCode), style: const TextStyle(fontWeight: FontWeight.w600)),
                if (reserved > 0) ...[
                  TextSpan(text: '   Reservado ', style: TextStyle(color: hint)),
                  TextSpan(text: money(reserved, currency: account.currencyCode), style: const TextStyle(fontWeight: FontWeight.w600)),
                ],
              ])),
            ],
            if (charges.isNotEmpty) ...[
              const SizedBox(height: 8),
              pill('${charges.length == 1 ? '1 retenido' : '${charges.length} retenidos'} · ${money(-held, signed: true)}', pulso.warning),
            ],
            if (cardCount > 0 || !account.includeInNetWorth) ...[
              const SizedBox(height: 8),
              Text(
                  [
                    if (cardCount > 0) cardCount == 1 ? '1 tarjeta' : '$cardCount tarjetas',
                    if (!account.includeInNetWorth) 'Fuera del patrimonio',
                  ].join(' · '),
                  style: TextStyle(fontSize: 12, color: hint)),
            ],
          ]),
        ),
      ),
    );
  }
}

/// One account: balance, reserves, cards, latest movements and its actions.
/// What the bank reported for a linked account: its balances and the movements it has not booked yet
/// (Swift `AccountDetailView.bankActivitySections`).
List<Widget> bankActivitySections(BuildContext context, BankActivity activity, Account account, Finances data, int balance) {
  final pulso = Pulso.of(context);
  final when = DateFormat("d MMM yyyy, HH:mm", 'es').format(activity.observedAt);
  const caption = TextStyle(fontSize: 12);
  final pending = activity.pendingMovements;
  return [
    const SectionTitle('Saldos comunicados por el banco'),
    Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (activity.bookedBalance != null)
          ListTile(title: const Text('Saldo contable'), trailing: Text(money(activity.bookedBalance!, currency: activity.currency))),
        if (activity.availableBalance != null)
          ListTile(title: const Text('Saldo disponible del banco'), trailing: Text(money(activity.availableBalance!, currency: activity.currency))),
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 4, 16, 12),
          child: Text('Consulta del $when. El disponible del banco puede reflejar retenciones y se muestra separado de tus reservas en la app.', style: caption),
        ),
      ]),
    ),
    const SectionTitle('Pendientes del banco'),
    Card(
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        if (pending == null)
          const ListTile(title: Text('Detalle de retenciones no disponible en esta consulta.'))
        else if (pending.isEmpty)
          const ListTile(title: Text('Sin retenciones ni movimientos pendientes comunicados en esta consulta.'))
        else ...[
          for (final m in pending)
            ListTile(
              title: Text(listTitle(m.description, isBanking: true), maxLines: 1, overflow: TextOverflow.ellipsis),
              subtitle: Text([m.isHold ? 'Retenido' : 'Pendiente', if (m.date != null) m.date!.split('-').reversed.join('/')].join(' · ')),
              trailing: Text(money(m.signedAmountMinor, signed: true, currency: m.currency),
                  style: TextStyle(fontWeight: FontWeight.w700, color: m.signedAmountMinor < 0 ? pulso.expense : pulso.income)),
            ),
          ListTile(
            title: const Text('Saldo tras retenciones', style: TextStyle(fontWeight: FontWeight.w700)),
            trailing: Text(money(balance + heldMinor(activity, account, data), currency: activity.currency), style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          const Padding(
            padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
            child: Text(
                'Importes provisionales. Los cargos se reflejan en el historial y el presupuesto cuando el banco los da por definitivos; también los ves en Movimientos.',
                style: caption),
          ),
        ],
      ]),
    ),
  ];
}

class AccountDetailScreen extends StatelessWidget {
  const AccountDetailScreen({super.key, required this.repository, required this.accountId});
  final FinanceRepository repository;
  final String accountId;

  @override
  Widget build(BuildContext context) {
    return ListenableBuilder(
      listenable: repository,
      builder: (context, _) {
        final data = repository.finances;
        final account = data?.account(accountId);
        if (data == null || account == null) return Scaffold(appBar: AppBar(), body: const Center(child: Text('Esta cuenta ya no existe.')));
        final calc = FinanceCalculator(data);
        final pulso = Pulso.of(context);
        final balance = calc.balance(account);
        final funds = data.reservedFunds.where((f) => f.accountId == account.id).toList();
        final cards = data.cards.where((c) => c.linkedAccountId == account.id && !c.isArchived).toList();
        final movements = data.transactions.where((t) => t.sourceAccountId == account.id || t.destinationAccountId == account.id).take(30).toList();
        Future<void> setArchived(bool value) async {
          await repository
              .apply(upsertOperation('accounts', {'id': account.id, 'isArchived': value, 'updatedAt': referenceSeconds(DateTime.now())}, create: false));
        }

        return Scaffold(
          appBar: AppBar(title: Text(account.name, style: const TextStyle(fontWeight: FontWeight.w700)), actions: [
            IconButton(
              tooltip: 'Editar',
              icon: const Icon(Icons.edit_outlined),
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => AccountFormScreen(repository: repository, editing: account))),
            ),
            PopupMenuButton<String>(
              onSelected: (value) async {
                if (value == 'archive' &&
                    await confirm(context, 'Archivar cuenta', 'Dejará de aparecer y de contar en el patrimonio. Sus movimientos se conservan.',
                        action: 'Archivar')) {
                  await setArchived(true);
                }
                if (value == 'restore') await setArchived(false);
              },
              itemBuilder: (_) => [
                if (!account.isArchived) const PopupMenuItem(value: 'archive', child: Text('Archivar cuenta')),
                if (account.isArchived) const PopupMenuItem(value: 'restore', child: Text('Recuperar cuenta')),
              ],
            ),
          ]),
          body: ListView(padding: const EdgeInsets.all(16), children: [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(18),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(account.type.title, style: Theme.of(context).textTheme.labelLarge),
                  Text(money(balance, currency: account.currencyCode), style: const TextStyle(fontSize: 30, fontWeight: FontWeight.w800)),
                  if (account.bankIdentityKey != null) Text('Conectada con tu banco', style: TextStyle(color: pulso.accent)),
                  const SizedBox(height: 12),
                  if (account.bankIdentityKey == null)
                    OutlinedButton.icon(
                      icon: const Icon(Icons.edit_note),
                      label: const Text('Actualizar saldo'),
                      onPressed: () => Navigator.of(context)
                          .push(MaterialPageRoute(builder: (_) => BalanceFormScreen(repository: repository, account: account, current: balance))),
                    ),
                ]),
              ),
            ),
            if (account.bankIdentityKey != null && !account.isArchived)
              if (repository.bankActivity[account.bankIdentityKey] case final activity?) ...bankActivitySections(context, activity, account, data, balance),
            SectionTitle('Dinero reservado'),
            Card(
              child: Column(children: [
                for (final fund in funds)
                  ListTile(
                    title: Text(fund.name),
                    subtitle: Text('Reservado ${money(fund.amountMinor)}'),
                    trailing:
                        Text(money(reservedBalances(fund.accountId!, fund.amountMinor, calc.reserveEntries(fund), through: DateTime.now())?[account.id] ?? 0)),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReserveFormScreen(repository: repository, editing: fund))),
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Reservar dinero'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ReserveFormScreen(repository: repository, accountId: account.id))),
                ),
              ]),
            ),
            SectionTitle('Tarjetas'),
            Card(
              child: Column(children: [
                for (final card in cards)
                  ListTile(
                    leading: const Icon(Icons.credit_card),
                    title: Text(card.name),
                    subtitle: Text('${card.type.title}${card.lastFour.isEmpty ? '' : ' · •••• ${card.lastFour}'}'),
                    onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CardFormScreen(repository: repository, editing: card))),
                  ),
                ListTile(
                  leading: const Icon(Icons.add),
                  title: const Text('Añadir tarjeta'),
                  onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => CardFormScreen(repository: repository, accountId: account.id))),
                ),
              ]),
            ),
            SectionTitle('Últimos movimientos'),
            Card(
              child: movements.isEmpty
                  ? const Padding(padding: EdgeInsets.all(16), child: Text('Sin movimientos.'))
                  : Column(children: [
                      for (final t in movements)
                        InkWell(
                          onTap: () => Navigator.of(context)
                              .push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: repository, transactionId: t.id))),
                          child: IgnorePointer(child: TransactionTile(transaction: t, data: data)),
                        ),
                    ]),
            ),
            if (account.notes.isNotEmpty) ...[SectionTitle('Notas'), Card(child: Padding(padding: const EdgeInsets.all(16), child: Text(account.notes)))],
          ]),
        );
      },
    );
  }
}

class AccountFormScreen extends StatefulWidget {
  const AccountFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final Account? editing;
  @override
  State<AccountFormScreen> createState() => _AccountFormScreenState();
}

class _AccountFormScreenState extends State<AccountFormScreen> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late final _opening = TextEditingController(text: widget.editing == null ? '' : amountText(widget.editing!.openingBalanceMinor));
  late final _notes = TextEditingController(text: widget.editing?.notes ?? '');
  late AccountType _type = widget.editing?.type ?? AccountType.checking;
  late DateTime _openingDate = widget.editing?.openingDate ?? DateTime.now();
  late bool _included = widget.editing?.includeInNetWorth ?? true;
  late String? _institution = widget.editing?.institutionId;
  String? _message;

  Future<void> _save() async {
    final name = _name.text.trim();
    final opening = _opening.text.trim().isEmpty ? 0 : amountFrom(_opening);
    if (name.isEmpty) return setState(() => _message = 'Escribe el nombre de la cuenta.');
    if (opening == null) return setState(() => _message = 'El saldo inicial no es un importe válido.');
    final now = referenceSeconds(DateTime.now());
    final fields = {
      'name': name,
      'typeRaw': _type.name,
      'openingBalanceMinor': opening,
      'openingDate': referenceSeconds(_openingDate),
      'includeInNetWorth': _included,
      'institutionID': _institution,
      'notes': _notes.text.trim(),
      'updatedAt': now,
    };
    final editing = widget.editing;
    if (editing != null) {
      await widget.repository.apply(upsertOperation('accounts', {'id': editing.id, ...fields}, create: false));
    } else {
      await widget.repository.apply(upsertOperation(
          'accounts',
          {
            'id': widget.repository.newId(),
            ...fields,
            'currencyCode': 'EUR',
            'annualInterestRate': 0,
            'targetBalanceMinor': 0,
            'creditLimitMinor': null,
            'isArchived': false,
            'sortOrder': widget.repository.finances?.accounts.length ?? 0,
            'lastUpdatedAt': now,
            'createdAt': now,
            'bankIdentityKey': null,
          },
          create: true));
    }
    if (mounted) Navigator.of(context).pop();
  }

  @override
  Widget build(BuildContext context) {
    final institutions = widget.repository.finances?.institutions ?? const <Institution>[];
    return FormPage(
      title: widget.editing == null ? 'Nueva cuenta' : 'Editar cuenta',
      message: _message,
      onSave: _save,
      children: [
        TextInput(controller: _name, label: 'Nombre'),
        Choice<AccountType>(
            label: 'Tipo', value: _type, options: {for (final t in AccountType.values) t: t.title}, onChanged: (v) => setState(() => _type = v)),
        Choice<String?>(
          label: 'Banco o entidad',
          value: _institution,
          options: {null: 'Sin entidad', for (final i in institutions) i.id: i.name},
          onChanged: (v) => setState(() => _institution = v),
        ),
        AmountInput(controller: _opening, label: 'Saldo inicial (€)', allowNegative: true),
        DateInput(label: 'Fecha del saldo inicial', value: _openingDate, onChanged: (v) => setState(() => _openingDate = v ?? _openingDate)),
        SwitchListTile(
            contentPadding: EdgeInsets.zero, title: const Text('Cuenta en el patrimonio'), value: _included, onChanged: (v) => setState(() => _included = v)),
        TextInput(controller: _notes, label: 'Notas', maxLines: 3),
      ],
    );
  }
}

/// "Actualizar saldo": records the balance the person sees in their bank today (a manual snapshot).
class BalanceFormScreen extends StatefulWidget {
  const BalanceFormScreen({super.key, required this.repository, required this.account, required this.current});
  final FinanceRepository repository;
  final Account account;
  final int current;
  @override
  State<BalanceFormScreen> createState() => _BalanceFormScreenState();
}

class _BalanceFormScreenState extends State<BalanceFormScreen> {
  late final _amount = TextEditingController(text: amountText(widget.current));
  DateTime _date = DateTime.now();
  String? _message;

  @override
  Widget build(BuildContext context) => FormPage(
        title: 'Actualizar saldo',
        message: _message,
        onSave: () async {
          final value = amountFrom(_amount);
          if (value == null) return setState(() => _message = 'Escribe el saldo actual.');
          final now = referenceSeconds(DateTime.now());
          await widget.repository.apply(batchOperation([
            upsertOperation(
                'snapshots',
                {
                  'id': widget.repository.newId(),
                  'date': referenceSeconds(_date),
                  'balanceMinor': value,
                  'sourceRaw': 'manual',
                  'notes': 'Saldo actualizado a mano',
                  'createdAt': now,
                  'accountID': widget.account.id,
                },
                create: true),
            upsertOperation('accounts', {'id': widget.account.id, 'lastUpdatedAt': now, 'updatedAt': now}, create: false),
          ]));
          if (mounted) Navigator.of(this.context).pop();
        },
        children: [
          Text('Escribe el saldo que ves hoy en ${widget.account.name}. Desde esa fecha, Doblón sumará los movimientos posteriores.'),
          AmountInput(controller: _amount, label: 'Saldo (€)', allowNegative: true),
          DateInput(label: 'Fecha', value: _date, onChanged: (v) => setState(() => _date = v ?? _date)),
        ],
      );
}

class CardFormScreen extends StatefulWidget {
  const CardFormScreen({super.key, required this.repository, this.editing, this.accountId});
  final FinanceRepository repository;
  final PaymentCard? editing;
  final String? accountId;
  @override
  State<CardFormScreen> createState() => _CardFormScreenState();
}

class _CardFormScreenState extends State<CardFormScreen> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late final _lastFour = TextEditingController(text: widget.editing?.lastFour ?? '');
  late CardType _type = widget.editing?.type ?? CardType.debit;
  late String? _account = widget.editing?.linkedAccountId ?? widget.accountId;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final accounts = widget.repository.finances?.accounts.where((a) => !a.isArchived).toList() ?? const <Account>[];
    final editing = widget.editing;
    return FormPage(
      title: editing == null ? 'Nueva tarjeta' : 'Editar tarjeta',
      message: _message,
      actions: [
        if (editing != null)
          IconButton(
            tooltip: 'Archivar',
            icon: const Icon(Icons.archive_outlined),
            onPressed: () async {
              await widget.repository
                  .apply(upsertOperation('cards', {'id': editing.id, 'isArchived': true, 'updatedAt': referenceSeconds(DateTime.now())}, create: false));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
      ],
      onSave: () async {
        final name = _name.text.trim();
        final four = _lastFour.text.trim();
        if (name.isEmpty) return setState(() => _message = 'Escribe el nombre de la tarjeta.');
        if (four.isNotEmpty && !RegExp(r'^\d{4}$').hasMatch(four)) return setState(() => _message = 'Los últimos dígitos son cuatro números.');
        final now = referenceSeconds(DateTime.now());
        final fields = {'name': name, 'typeRaw': _type.name, 'lastFour': four, 'linkedAccountID': _account, 'updatedAt': now};
        await widget.repository.apply(editing != null
            ? upsertOperation('cards', {'id': editing.id, ...fields}, create: false)
            : upsertOperation(
                'cards',
                {
                  'id': widget.repository.newId(),
                  ...fields,
                  'limitMinor': null,
                  'limitKindRaw': null,
                  'onlinePurchasesEnabled': null,
                  'contactlessEnabled': null,
                  'atmWithdrawalsEnabled': null,
                  'internationalPaymentsEnabled': null,
                  'cashbackEnabled': null,
                  'cashbackPercent': null,
                  'roundUpEnabled': null,
                  'isArchived': false,
                  'notes': '',
                  'createdAt': now,
                  'institutionID': null,
                },
                create: true));
        if (mounted) Navigator.of(this.context).pop();
      },
      children: [
        TextInput(controller: _name, label: 'Nombre'),
        Choice<CardType>(label: 'Tipo', value: _type, options: {for (final t in CardType.values) t: t.title}, onChanged: (v) => setState(() => _type = v)),
        TextField(
            controller: _lastFour,
            keyboardType: TextInputType.number,
            maxLength: 4,
            decoration: const InputDecoration(labelText: 'Últimos cuatro dígitos', border: OutlineInputBorder())),
        Choice<String?>(
          label: 'Cuenta de la que sale el dinero',
          value: _account,
          options: {null: 'Ninguna', for (final a in accounts) a.id: a.name},
          onChanged: (v) => setState(() => _account = v),
        ),
      ],
    );
  }
}

/// Money set aside in an account for a purpose. Payments made with it do not count against budgets.
class ReserveFormScreen extends StatefulWidget {
  const ReserveFormScreen({super.key, required this.repository, this.editing, this.accountId});
  final FinanceRepository repository;
  final ReservedFund? editing;
  final String? accountId;
  @override
  State<ReserveFormScreen> createState() => _ReserveFormScreenState();
}

class _ReserveFormScreenState extends State<ReserveFormScreen> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late final _amount = TextEditingController(text: widget.editing == null ? '' : amountText(widget.editing!.amountMinor));
  late String? _account = widget.editing?.accountId ?? widget.accountId;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final data = widget.repository.finances!;
    final accounts = data.accounts.where((a) => !a.isArchived && a.type != AccountType.investment && !a.type.isLiability).toList();
    final editing = widget.editing;
    final used = editing != null && data.transactions.any((t) => t.reservedFundId == editing.id);
    return FormPage(
      title: editing == null ? 'Reservar dinero' : 'Editar reserva',
      message: _message,
      actions: [
        if (editing != null && !used)
          IconButton(
            tooltip: 'Borrar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (!await confirm(context, 'Borrar reserva', 'El dinero vuelve a estar libre en la cuenta.', action: 'Borrar')) return;
              await widget.repository.apply(removeOperation('reservedFunds', editing.id));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
      ],
      onSave: () async {
        final name = _name.text.trim();
        final amount = amountFrom(_amount);
        if (name.isEmpty) return setState(() => _message = 'Escribe para qué es la reserva.');
        if (amount == null || amount < 0) return setState(() => _message = 'Escribe el importe reservado.');
        if (_account == null) return setState(() => _message = 'Elige la cuenta.');
        if (editing != null) {
          final spent =
              data.transactions.where((t) => t.reservedFundId == editing.id && t.type.countsAsExpense).fold(0, (s, t) => s + (t.reservedAmountMinor ?? 0));
          if (amount < spent) return setState(() => _message = 'Ya se han pagado ${money(spent)} con esta reserva: no puede ser menor.');
        }
        final now = referenceSeconds(DateTime.now());
        await widget.repository.apply(editing != null
            ? upsertOperation('reservedFunds', {'id': editing.id, 'name': name, 'amountMinor': amount, 'updatedAt': now}, create: false)
            : upsertOperation(
                'reservedFunds',
                {
                  'id': widget.repository.newId(),
                  'name': name,
                  'amountMinor': amount,
                  'notes': '',
                  'createdAt': now,
                  'updatedAt': now,
                  'accountID': _account,
                },
                create: true));
        if (mounted) Navigator.of(this.context).pop();
      },
      children: [
        TextInput(controller: _name, label: 'Para qué es'),
        AmountInput(controller: _amount, label: 'Importe reservado (€)'),
        if (editing == null)
          Choice<String?>(
              label: 'Cuenta',
              value: _account,
              options: {null: 'Elige una cuenta', for (final a in accounts) a.id: a.name},
              onChanged: (v) => setState(() => _account = v)),
        if (used) const Text('Ya hay pagos con esta reserva: no se puede borrar, solo cambiar su nombre o importe.'),
      ],
    );
  }
}
