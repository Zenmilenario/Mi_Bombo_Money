import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../data.dart';
import '../finance.dart';
import '../theme.dart';
import 'accounts.dart';
import 'banks.dart';
import 'budgets.dart';
import 'home.dart';
import 'transactions.dart';

/// The four tabs of the iPhone app plus a small settings page. Read only in this first version.
class Shell extends StatefulWidget {
  const Shell({super.key});
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  final repository = FinanceRepository();
  int tab = 0;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  FinanceCalculator? _calculator;
  Object? _calculatedFrom;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    repository.addListener(_changed);
    repository.refresh();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    repository.removeListener(_changed);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) repository.refresh();
  }

  void _changed() => setState(() {});

  /// One calculator per download: every screen shares its balance index.
  FinanceCalculator? get calculator {
    final data = repository.finances;
    if (data == null) return null;
    if (!identical(_calculatedFrom, data)) {
      _calculator = FinanceCalculator(data);
      _calculatedFrom = data;
    }
    return _calculator;
  }

  @override
  Widget build(BuildContext context) {
    final calc = calculator;
    final Widget body;
    if (calc == null) {
      body = Center(
        child: repository.error == null
            ? const CircularProgressIndicator()
            : Padding(
                padding: const EdgeInsets.all(24),
                child: Column(mainAxisSize: MainAxisSize.min, children: [
                  Text(repository.error!, textAlign: TextAlign.center),
                  const SizedBox(height: 12),
                  FilledButton(onPressed: repository.refresh, child: const Text('Volver a intentarlo')),
                ]),
              ),
      );
    } else {
      body = RefreshIndicator(
        onRefresh: repository.refresh,
        child: switch (tab) {
          0 => HomeScreen(calc: calc, month: month, onMonth: (m) => setState(() => month = m)),
          1 => TransactionsScreen(calc: calc),
          2 => AccountsScreen(calc: calc),
          3 => BudgetsScreen(calc: calc, month: month, onMonth: (m) => setState(() => month = m)),
          _ => _SettingsPage(repository: repository),
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(const ['Inicio', 'Movimientos', 'Cuentas', 'Presupuestos', 'Ajustes'][tab],
            style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (repository.loading && calc != null)
            const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
        ],
      ),
      body: body,
      bottomNavigationBar: NavigationBar(
        selectedIndex: tab,
        onDestinationSelected: (index) => setState(() => tab = index),
        destinations: const [
          NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Inicio'),
          NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Movimientos'),
          NavigationDestination(icon: Icon(Icons.account_balance_outlined), selectedIcon: Icon(Icons.account_balance), label: 'Cuentas'),
          NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'Presupuestos'),
          NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ajustes'),
        ],
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.repository});
  final FinanceRepository repository;

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final pulso = Pulso.of(context);
    return ListView(padding: const EdgeInsets.all(16), children: [
      Card(
        child: ListTile(
          leading: Icon(Icons.cloud_done_outlined, color: pulso.accent),
          title: const Text('Mi nube'),
          subtitle: Text([
            if (user?.email != null) user!.email!,
            if (repository.loadedAt != null)
              'Actualizado a las ${TimeOfDay.fromDateTime(repository.loadedAt!).format(context)}',
          ].join('\n')),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          leading: Icon(Icons.account_balance_outlined, color: pulso.accent),
          title: const Text('Mis bancos'),
          subtitle: const Text('Conectar, actualizar y desconectar bancos'),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => BanksScreen(repository: repository))),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          leading: Icon(Icons.info_outline, color: pulso.accent),
          title: const Text('Versión para Android'),
          subtitle: const Text('Consulta tus finanzas y trae los movimientos de tus bancos. Para apuntar a mano o categorizar, de momento usa la app del iPhone.'),
        ),
      ),
      const SizedBox(height: 12),
      Card(
        child: ListTile(
          leading: Icon(Icons.logout, color: pulso.expense),
          title: const Text('Salir de la cuenta'),
          onTap: () async {
            repository.clear();
            await Supabase.instance.client.auth.signOut();
          },
        ),
      ),
    ]);
  }
}
