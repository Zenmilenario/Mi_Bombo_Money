import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';
import 'package:url_launcher/url_launcher.dart';

import '../banking.dart';
import '../data.dart';
import '../theme.dart';

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
      if (mounted) setState(() {
        message = text;
        messageIsError = false;
      });
    } on BankingError catch (error) {
      if (mounted) setState(() {
        message = error.message;
        messageIsError = true;
      });
    } catch (_) {
      if (mounted) setState(() {
        message = 'No se ha podido completar. Inténtalo de nuevo más tarde.';
        messageIsError = true;
      });
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
        final result = await widget.repository.update((document) => importFeeds(document, feeds, now));
        return result.summary;
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
                FilledButton.icon(
                    onPressed: busy ? null : _connect, icon: const Icon(Icons.add_link), label: const Text('Conectar un banco')),
                const SizedBox(height: 8),
                OutlinedButton.icon(
                    onPressed: busy || (list?.isEmpty ?? true) ? null : _update,
                    icon: const Icon(Icons.sync),
                    label: const Text('Actualizar movimientos')),
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
                    subtitle: Text('Permiso válido hasta ${connection.validUntil.length >= 10 ? connection.validUntil.substring(0, 10) : connection.validUntil}'),
                    trailing: IconButton(
                        tooltip: 'Desconectar', onPressed: busy ? null : () => _disconnect(connection), icon: const Icon(Icons.link_off)),
                  ),
                  for (final account in connection.accounts)
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
