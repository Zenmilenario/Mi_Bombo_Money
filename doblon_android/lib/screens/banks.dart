import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:intl/intl.dart';
import 'package:url_launcher/url_launcher.dart';

import '../bank_activity.dart';
import '../banking.dart';
import '../data.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'widgets.dart';

/// Mis bancos: connect a bank in its own website, see the connections and bring their movements in.
class BanksScreen extends StatefulWidget {
  const BanksScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  State<BanksScreen> createState() => _BanksScreenState();
}

class _BanksScreenState extends State<BanksScreen> with WidgetsBindingObserver {
  List<RemoteConnection>? connections;
  bool busy = false;
  String? message;
  bool messageIsError = false;

  BankingClient? get _client {
    final token = Supabase.instance.client.auth.currentSession?.accessToken;
    return token == null ? null : BankingClient(token);
  }

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _loadConnections();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  /// Coming back from the bank's website (the server returns to Doblón): show the new connection.
  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) _loadConnections();
  }

  Future<void> _run(Future<String?> Function(BankingClient client) action) async {
    if (busy) return;
    final client = _client;
    if (client == null) return;
    setState(() {
      busy = true;
      message = null;
    });
    try {
      final text = await action(client);
      if (mounted) {
        setState(() {
          message = text;
          messageIsError = false;
        });
      }
    } on BankingError catch (error) {
      if (mounted) {
        setState(() {
          message = error.message;
          messageIsError = true;
        });
      }
    } catch (_) {
      if (mounted) {
        setState(() {
          message = 'No se ha podido completar. Inténtalo de nuevo más tarde.';
          messageIsError = true;
        });
      }
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadConnections() => _run((client) async {
        final list = await client.connections();
        if (mounted) setState(() => connections = list);
        return null;
      });

  Future<void> _review() async {
    final proposals = widget.repository.bankProposals;
    if (proposals.isEmpty || widget.repository.finances == null) return;
    final decisions = await Navigator.of(context)
        .push<Map<String, String>>(MaterialPageRoute(builder: (_) => BankReviewScreen(proposals: proposals, data: widget.repository.finances!)));
    if (decisions == null || !mounted) return;
    await _run((_) async {
      await widget.repository.reviewBankDownloads(decisions);
      return 'Revisión incorporada.';
    });
  }

  Future<void> _associate(RemoteConnection connection, RemoteAccount remote) async {
    final data = widget.repository.finances;
    if (data == null || remote.currency != 'EUR') return;
    final selected = await showModalBottomSheet<String>(
        context: context,
        showDragHandle: true,
        builder: (context) => SafeArea(
                child: ListView(shrinkWrap: true, children: [
              const ListTile(title: Text('Asociar la cuenta del banco')),
              const ListTile(subtitle: Text('Elige una cuenta existente para conservar sus movimientos y reservas. También puedes crear una nueva.')),
              for (final a in data.accounts.where(
                  (a) => !a.isArchived && a.bankIdentityKey == null && a.currencyCode == 'EUR' && !a.type.isLiability && a.type != AccountType.investment))
                ListTile(leading: const Icon(Icons.account_balance), title: Text(a.name), onTap: () => Navigator.pop(context, a.id)),
              ListTile(leading: const Icon(Icons.add), title: const Text('Crear una cuenta nueva'), onTap: () => Navigator.pop(context, 'new')),
              ListTile(title: const Text('Dejar sin asociar'), onTap: () => Navigator.pop(context)),
            ])));
    if (selected == null || !mounted) return;
    await _run((client) async {
      final empty = AccountFeed(connection: connection, account: remote, balances: [], movements: []);
      await widget.repository.update((document) => importFeeds(document, [empty], DateTime.now(), accountChoices: {remote.id: selected}));
      final result = await widget.repository.synchronizeBanks(manual: true, bank: connection.bank, client: client);
      return result?.summary;
    });
  }

  Future<void> _connect() async {
    if (busy) return;
    final client = _client;
    if (client == null) return;
    List<String> banks;
    try {
      setState(() => busy = true);
      banks = await client.banks();
    } on BankingError catch (error) {
      if (mounted) {
        setState(() {
          message = error.message;
          messageIsError = true;
        });
      }
      return;
    } finally {
      client.close();
      if (mounted) setState(() => busy = false);
    }
    if (!mounted) return;
    final bank = await showModalBottomSheet<String>(
      context: context,
      isScrollControlled: true,
      showDragHandle: true,
      builder: (context) => _BankPicker(banks: banks),
    );
    if (bank == null) return;
    await _run((client) async {
      final url = await client.startAuthorization(bank);
      final opened = await launchUrl(url, mode: LaunchMode.externalApplication);
      if (!opened) throw BankingError('browser_unavailable');
      return 'Autoriza en la web de $bank. Al terminar volverás a Doblón y verás aquí la conexión.';
    });
  }

  /// Downloads every connected account and adds what is new to the cloud, as the iPhone does.
  Future<void> _update({String? bank}) => _run((client) async {
        final result = await widget.repository.synchronizeBanks(manual: true, bank: bank, client: client);
        return result?.summary;
      });

  Future<void> _disconnect(RemoteConnection connection) async {
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text('Desconectar ${connection.bank}'),
        content: const Text('Doblón dejará de recibir sus movimientos. Los que ya tienes se conservan.'),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Desconectar')),
        ],
      ),
    );
    if (confirmed != true) return;
    await _run((client) async {
      await client.disconnect(connection.id);
      final list = await client.connections();
      if (mounted) setState(() => connections = list);
      return '${connection.bank} desconectado.';
    });
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
      listenable: widget.repository,
      builder: (context, _) {
        final pulso = Pulso.of(context);
        final list = connections;
        return Scaffold(
          appBar: AppBar(title: const Text('Mis bancos', style: TextStyle(fontWeight: FontWeight.w700))),
          body: RefreshIndicator(
            onRefresh: _loadConnections,
            child: ListView(physics: const AlwaysScrollableScrollPhysics(), padding: const EdgeInsets.all(16), children: [
              Card(
                child: Padding(
                  padding: const EdgeInsets.all(16),
                  child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                    const Text('Conecta tu banco en su propia web: Doblón solo lee saldos y movimientos y nunca ve tus claves.'),
                    const SizedBox(height: 12),
                    FilledButton.icon(onPressed: busy ? null : _connect, icon: const Icon(Icons.add_link), label: const Text('Conectar un banco')),
                    const SizedBox(height: 8),
                    OutlinedButton.icon(
                        onPressed: busy || (list?.isEmpty ?? true) ? null : () => _update(),
                        icon: const Icon(Icons.sync),
                        label: const Text('Actualizar movimientos')),
                    const Text(
                        'Se actualizan automáticamente las cuentas asociadas. Tras una descarga correcta se esperan seis horas; cada banco conserva su propio plazo.'),
                  ]),
                ),
              ),
              if (busy) const Padding(padding: EdgeInsets.all(16), child: Center(child: CircularProgressIndicator())),
              if (message != null)
                Padding(
                  padding: const EdgeInsets.symmetric(vertical: 12),
                  child: Text(message!, style: TextStyle(color: messageIsError ? pulso.expense : pulso.income)),
                ),
              const SizedBox(height: 8),
              if (widget.repository.bankResult?.errors['Conexión'] case final problem?)
                Padding(padding: const EdgeInsets.all(12), child: Text(problem, style: TextStyle(color: pulso.expense))),
              if (widget.repository.bankProposals.isNotEmpty)
                ListTile(
                    leading: const Icon(Icons.rule),
                    title: Text('${widget.repository.bankProposals.length} coincidencias por revisar'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: busy ? null : _review),
              if (list != null && list.isEmpty) const Text('Aún no has conectado ningún banco.'),
              for (final connection in list ?? const <RemoteConnection>[])
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: Column(children: [
                      ListTile(
                        leading: Icon(Icons.account_balance, color: pulso.accent),
                        title: Text(connection.bank, style: const TextStyle(fontWeight: FontWeight.w700)),
                        subtitle:
                            Text('Permiso válido hasta ${connection.validUntil.length >= 10 ? connection.validUntil.substring(0, 10) : connection.validUntil}'),
                        trailing: IconButton(tooltip: 'Desconectar', onPressed: busy ? null : () => _disconnect(connection), icon: const Icon(Icons.link_off)),
                      ),
                      if (widget.repository.bankResult?.errors[connection.bank] case final problem?)
                        Padding(padding: const EdgeInsets.all(12), child: Text(problem, style: TextStyle(color: pulso.expense))),
                      if (widget.repository.bankResult?.waiting[connection.bank] case final until?)
                        Padding(padding: const EdgeInsets.all(12), child: Text('Próxima consulta a partir de ${DateFormat('d/M HH:mm').format(until)}')),
                      for (final account in connection.accounts) ...[
                        ListTile(
                          dense: true,
                          leading: const SizedBox(width: 24),
                          title: Text('•••• ${account.lastFour}'),
                          subtitle: Text(_archived(account)
                              ? 'Cuenta archivada · recupérala en Cuentas'
                              : widget.repository.linked(account)
                                  ? 'Cuenta asociada'
                                  : 'Sin asociar · no se incorpora'),
                          trailing: account.currency != 'EUR'
                              ? Text(account.currency)
                              : TextButton(
                                  onPressed: busy || _archived(account) || widget.repository.linked(account) ? null : () => _associate(connection, account),
                                  child: const Text('Asociar')),
                        ),
                        if (widget.repository.bankActivity[accountIdentity(account.id)] case final activity?) _Received(account: account, activity: activity),
                      ],
                      TextButton.icon(
                          onPressed: busy ? null : () => _update(bank: connection.bank),
                          icon: const Icon(Icons.sync),
                          label: Text('Actualizar solo ${connection.bank}')),
                    ]),
                  ),
                ),
            ]),
          ),
        );
      });

  bool _archived(RemoteAccount remote) =>
      widget.repository.finances?.accounts.any((a) => a.isArchived && a.bankIdentityKey == accountIdentity(remote.id)) ?? false;
}

/// Diagnostic of what the bank sent in the last query of one account: "did the bank send it?"
/// (Swift `PersonalBankConnectionsView`, «Últimos apuntes recibidos»).
class _Received extends StatelessWidget {
  const _Received({required this.account, required this.activity});
  final RemoteAccount account;
  final BankActivity activity;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    const caption = TextStyle(fontSize: 12);
    final ignored = activity.ignoredStatuses.entries.toList()..sort((a, b) => a.key.compareTo(b.key));
    return ExpansionTile(
      leading: const Icon(Icons.move_to_inbox_outlined),
      title: Text('•••• ${account.lastFour} · ${account.currency}${account.currency == 'EUR' ? '' : ' · no se incorpora'}'),
      subtitle: Text('Últimos apuntes recibidos (${activity.receivedCount})'),
      childrenPadding: const EdgeInsets.fromLTRB(16, 0, 16, 12),
      children: [
        if (activity.recentMovements.isEmpty) const Text('El banco no envió apuntes contabilizados en el periodo consultado.', style: caption),
        for (final m in activity.recentMovements)
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(children: [
              SizedBox(width: 82, child: Text(m.bookingDate.split('-').reversed.join('/'), style: caption)),
              Expanded(child: Text(listTitle(m.description, isBanking: true), maxLines: 1, overflow: TextOverflow.ellipsis, style: caption)),
              Text(money(m.signedAmountMinor, signed: true, currency: m.currency), style: caption.copyWith(fontWeight: FontWeight.w700)),
            ]),
          ),
        if (ignored.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
                'El banco también envió ${ignored.map((e) => '${e.value} ${bankStatusName(e.key)}').join(', ')}. La app no los incorpora porque el banco no los da por contabilizados.',
                style: caption.copyWith(color: pulso.warning)),
          ),
        Padding(
          padding: const EdgeInsets.only(top: 6),
          child: Text(
              'Es lo que envió el banco en la consulta del ${DateFormat("d MMM yyyy, HH:mm", 'es').format(activity.observedAt)}, contabilizado y sin retenidos. Si un pago de tu banco no aparece aquí, el banco aún no lo ha comunicado.',
              style: caption),
        ),
      ],
    );
  }
}

class _BankPicker extends StatefulWidget {
  const _BankPicker({required this.banks});
  final List<String> banks;
  @override
  State<_BankPicker> createState() => _BankPickerState();
}

class _BankPickerState extends State<_BankPicker> {
  String query = '';
  @override
  Widget build(BuildContext context) {
    final visible = widget.banks.where((b) => b.toLowerCase().contains(query.toLowerCase())).toList();
    return SizedBox(
      height: MediaQuery.of(context).size.height * 0.75,
      child: Column(children: [
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
          child: TextField(
            autofocus: true,
            decoration: const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Busca tu banco', border: OutlineInputBorder()),
            onChanged: (value) => setState(() => query = value.trim()),
          ),
        ),
        Expanded(
          child: ListView.builder(
            itemCount: visible.length,
            itemBuilder: (context, index) => ListTile(title: Text(visible[index]), onTap: () => Navigator.pop(context, visible[index])),
          ),
        ),
      ]),
    );
  }
}

/// The downloaded movements that may be ones already recorded by hand: for each, "it is this one" or "new".
class BankReviewScreen extends StatefulWidget {
  const BankReviewScreen({super.key, required this.proposals, required this.data});
  final List<BankProposal> proposals;
  final Finances data;
  @override
  State<BankReviewScreen> createState() => _BankReviewScreenState();
}

class _BankReviewScreenState extends State<BankReviewScreen> {
  // Preselected: the first (closest) candidate, as the iPhone suggests.
  late final Map<String, String> decisions = {for (final p in widget.proposals) p.key: p.candidateIds.first};

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    return Scaffold(
      appBar: AppBar(title: const Text('Revisar la descarga', style: TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Estos movimientos del banco se parecen a otros que ya tenías apuntados. Elige si son el mismo (se unen, sin duplicarse) o uno nuevo.'),
        const SizedBox(height: 12),
        for (final p in widget.proposals)
          Card(
            child: Padding(
              padding: const EdgeInsets.all(12),
              child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                Text('${p.bank} · ${p.date.day}/${p.date.month}/${p.date.year}', style: Theme.of(context).textTheme.labelMedium),
                Text(listTitle(p.description, isBanking: true), style: const TextStyle(fontWeight: FontWeight.w700)),
                Text(money(p.amountMinor, signed: true),
                    style: TextStyle(color: p.amountMinor < 0 ? pulso.expense : pulso.income, fontWeight: FontWeight.w700)),
                const Divider(),
                RadioGroup<String>(
                  groupValue: decisions[p.key],
                  onChanged: (v) => setState(() => decisions[p.key] = v ?? 'new'),
                  child: Column(children: [
                    for (final id in p.candidateIds)
                      if (widget.data.transactions.where((t) => t.id == id).firstOrNull case final t?)
                        RadioListTile<String>(
                          contentPadding: EdgeInsets.zero,
                          value: id,
                          title: const Text('Es este que ya tenía:'),
                          subtitle: IgnorePointer(child: TransactionTile(transaction: t, data: widget.data)),
                        ),
                    const RadioListTile<String>(contentPadding: EdgeInsets.zero, value: 'new', title: Text('Es un movimiento nuevo')),
                  ]),
                ),
              ]),
            ),
          ),
        const SizedBox(height: 12),
        FilledButton(
          onPressed: () => Navigator.of(context).pop(decisions),
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
          child: const Text('Incorporar'),
        ),
      ]),
    );
  }
}
