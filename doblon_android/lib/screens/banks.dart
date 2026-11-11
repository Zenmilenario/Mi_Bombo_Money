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
    final client = _client;
    if (client == null || busy) return;
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
      if (mounted) setState(() => busy = false);
    }
  }

  Future<void> _loadConnections() => _run((client) async {
        final list = await client.connections();
        if (mounted) setState(() => connections = list);
        return null;
      });

  Future<void> _connect() async {
    final client = _client;
    if (client == null) return;
    List<String> banks;
    try {
      setState(() => busy = true);
      banks = await client.banks();
    } on BankingError catch (error) {
      setState(() {
        message = error.message;
        messageIsError = true;
      });
      return;
    } finally {
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
  Future<void> _update() => _run((client) async {
        final list = connections ?? await client.connections();
        final now = DateTime.now();
        final feeds = <AccountFeed>[];
        for (final connection in list) {
          for (final account in connection.accounts) {
            feeds.add(await client.feed(connection, account, now));
          }
        }
        if (feeds.isEmpty) return 'No hay cuentas conectadas que actualizar.';
        // Balances, holds and what the bank sent are kept on this device, apart from the accounts.
        await widget.repository.recordBankActivity(feeds, now);
        final result = await widget.repository.update((document) => importFeeds(document, feeds, now));
        await widget.repository.applyLearnedCorrections();
        if (result.proposals.isEmpty || !mounted) return result.summary;
        // Some downloaded movements may be ones recorded by hand: the person decides, then they are brought in.
        final decisions = await Navigator.of(context)
            .push<Map<String, String>>(MaterialPageRoute(builder: (_) => BankReviewScreen(proposals: result.proposals, data: widget.repository.finances!)));
        if (decisions == null) return '${result.summary}. Los que esperan revisión se incorporarán en la próxima actualización.';
        final second = await widget.repository.update((document) => importFeeds(document, feeds, now, decisions: decisions));
        await widget.repository.applyLearnedCorrections();
        return 'Revisión incorporada: ${second.summary}';
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
  Widget build(BuildContext context) {
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
                    onPressed: busy || (list?.isEmpty ?? true) ? null : _update, icon: const Icon(Icons.sync), label: const Text('Actualizar movimientos')),
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
                  for (final account in connection.accounts)
                    if (widget.repository.bankActivity[accountIdentity(account.id)] case final activity?)
                      _Received(account: account, activity: activity)
                    else
                      ListTile(
                        dense: true,
                        leading: const SizedBox(width: 24),
                        title: Text('•••• ${account.lastFour}'),
                        trailing: Text(account.currency == 'EUR' ? 'EUR' : '${account.currency} · no se incorpora'),
                      ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }
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
