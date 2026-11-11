import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../automation.dart';
import '../data.dart';
import '../finance.dart';
import '../preferences.dart';
import '../theme.dart';
import 'accounts.dart';
import 'banks.dart';
import 'budgets.dart';
import 'home.dart';
import 'manage.dart';
import 'tools.dart';
import 'transactions.dart';

/// The same five tabs as the iPhone app, with Don Bigotes in the top bar.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.preferences});
  final AppPreferences preferences;
  @override
  State<Shell> createState() => _ShellState();
}

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  final repository = FinanceRepository();
  int tab = 0;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  FinanceCalculator? _calculator;
  Object? _calculatedFrom;
  bool _postedToday = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    repository.addListener(_changed);
    widget.preferences.addListener(_changed);
    _open();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    repository.removeListener(_changed);
    widget.preferences.removeListener(_changed);
    super.dispose();
  }

  /// Downloads, then posts the periodic movements that are due (once per opening), as the iPhone does.
  Future<void> _open() async {
    await repository.refresh();
    if (!_postedToday && repository.finances != null && repository.error == null) {
      _postedToday = true;
      await postDue(repository);
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) {
      _postedToday = false;
      _open();
    }
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

  void _showCompanion(List<CompanionNote> notes) {
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          Row(children: [
            ClipOval(child: Image.asset('assets/don_bigotes.png', width: 44, height: 44, fit: BoxFit.cover)),
            const SizedBox(width: 12),
            Expanded(
                child: Text(notes.isEmpty ? 'Todo en orden. Me echo una siesta.' : 'Esto es lo que he visto:',
                    style: const TextStyle(fontWeight: FontWeight.w700))),
          ]),
          const SizedBox(height: 12),
          for (final note in notes)
            Card(
              child: ListTile(
                title: Text(note.title),
                subtitle: Text(note.detail),
                trailing: Row(mainAxisSize: MainAxisSize.min, children: [
                  TextButton(
                    onPressed: () {
                      Navigator.pop(context);
                      setState(() => tab = note.tab);
                    },
                    child: const Text('Ver'),
                  ),
                  IconButton(
                    tooltip: 'Ocultar',
                    icon: const Icon(Icons.close),
                    onPressed: () {
                      widget.preferences.dismissNote(note.id);
                      Navigator.pop(context);
                    },
                  ),
                ]),
              ),
            ),
        ]),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final calc = calculator;
    final pulso = Pulso.of(context);
    final notes = calc == null || !widget.preferences.companionEnabled
        ? <CompanionNote>[]
        : companionNotes(calc.data, DateTime.now()).where((n) => !widget.preferences.dismissedNotes.contains(n.id)).toList();
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
      void setMonth(DateTime m) => setState(() => month = m);
      body = RefreshIndicator(
        onRefresh: _open,
        child: switch (tab) {
          0 => HomeScreen(calc: calc, month: month, onMonth: setMonth, onAdd: () => setState(() => tab = 2)),
          1 => TransactionsScreen(calc: calc, repository: repository),
          2 => AccountsScreen(calc: calc, repository: repository),
          3 => BudgetsScreen(calc: calc, month: month, onMonth: setMonth, repository: repository),
          _ => _SettingsPage(repository: repository, preferences: widget.preferences),
        },
      );
    }
    return Scaffold(
      appBar: AppBar(
        title: Text(const ['Inicio', 'Movimientos', 'Cuentas', 'Presupuestos', 'Ajustes'][tab], style: const TextStyle(fontWeight: FontWeight.w700)),
        actions: [
          if (repository.pending.isNotEmpty)
            Tooltip(
              message: '${repository.pending.length} cambios sin subir',
              child: IconButton(icon: const Icon(Icons.cloud_upload_outlined), onPressed: repository.refresh),
            ),
          if (repository.loading && calc != null)
            const Padding(padding: EdgeInsets.all(16), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
          if (widget.preferences.companionEnabled && calc != null)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: InkWell(
                customBorder: const CircleBorder(),
                onTap: () => _showCompanion(notes),
                child: Badge(
                  isLabelVisible: notes.isNotEmpty,
                  label: Text('${notes.length}'),
                  backgroundColor: pulso.warning,
                  child: Opacity(
                    // Asleep (faded) when there is nothing to point out.
                    opacity: notes.isEmpty ? 0.45 : 1,
                    child: ClipOval(child: Image.asset('assets/don_bigotes.png', width: 34, height: 34, fit: BoxFit.cover)),
                  ),
                ),
              ),
            ),
        ],
      ),
      body: calc != null && repository.error != null
          ? Column(children: [
              Material(
                color: pulso.warning.withValues(alpha: 0.15),
                child: ListTile(
                  dense: true,
                  leading: Icon(Icons.cloud_off_outlined, color: pulso.warning),
                  title: Text(repository.error!),
                  trailing: TextButton(onPressed: repository.refresh, child: const Text('Reintentar')),
                ),
              ),
              Expanded(child: body),
            ])
          : body,
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
  const _SettingsPage({required this.repository, required this.preferences});
  final FinanceRepository repository;
  final AppPreferences preferences;

  @override
  Widget build(BuildContext context) {
    final user = Supabase.instance.client.auth.currentUser;
    final pulso = Pulso.of(context);
    Widget route(IconData icon, String title, String subtitle, Widget Function() page) => ListTile(
          leading: Icon(icon, color: pulso.accent),
          title: Text(title),
          subtitle: subtitle.isEmpty ? null : Text(subtitle),
          trailing: const Icon(Icons.chevron_right),
          onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page())),
        );
    Widget section(String title, List<Widget> children) => Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
          Padding(padding: const EdgeInsets.fromLTRB(4, 16, 4, 8), child: Text(title, style: Theme.of(context).textTheme.titleSmall)),
          Card(child: Column(children: children)),
        ]);
    return ListView(padding: const EdgeInsets.all(16), children: [
      section('Cuenta y bancos', [
        ListTile(
          leading: Icon(Icons.cloud_done_outlined, color: pulso.accent),
          title: const Text('Mi nube'),
          subtitle: Text([
            if (user?.email != null) user!.email!,
            if (repository.loadedAt != null) 'Actualizado a las ${TimeOfDay.fromDateTime(repository.loadedAt!).format(context)}',
            if (repository.pending.isNotEmpty) '${repository.pending.length} cambios sin subir',
          ].join('\n')),
        ),
        route(Icons.account_balance_outlined, 'Mis bancos', 'Conectar, actualizar y revisar movimientos', () => BanksScreen(repository: repository)),
      ]),
      section('Organiza tus finanzas', [
        route(Icons.sell_outlined, 'Categorías', '', () => CategoriesScreen(repository: repository)),
        route(Icons.rule, 'Categorización automática', 'Reglas para reconocer conceptos habituales', () => RulesScreen(repository: repository)),
        route(Icons.repeat, 'Cargos y aportaciones periódicas', 'Suscripciones, ingresos y traspasos', () => RecurringScreen(repository: repository)),
        route(Icons.account_balance, 'Bancos y entidades', 'Nombres que agrupan cuentas y tarjetas', () => InstitutionsScreen(repository: repository)),
      ]),
      section('A tu gusto', [
        ListTile(
          leading: Icon(Icons.dark_mode_outlined, color: pulso.accent),
          title: const Text('Apariencia'),
          trailing: DropdownButton<ThemeMode>(
            value: preferences.themeMode,
            underline: const SizedBox.shrink(),
            items: const [
              DropdownMenuItem(value: ThemeMode.system, child: Text('Automática')),
              DropdownMenuItem(value: ThemeMode.light, child: Text('Clara')),
              DropdownMenuItem(value: ThemeMode.dark, child: Text('Oscura')),
            ],
            onChanged: (v) => preferences.setThemeMode(v ?? ThemeMode.system),
          ),
        ),
        SwitchListTile(
          secondary: Icon(Icons.visibility_off_outlined, color: pulso.accent),
          title: const Text('Ocultar importes'),
          value: preferences.hideAmounts,
          onChanged: preferences.setHideAmounts,
        ),
        SwitchListTile(
          secondary: ClipOval(child: Image.asset('assets/don_bigotes.png', width: 28, height: 28, fit: BoxFit.cover)),
          title: const Text('Don Bigotes'),
          subtitle: const Text('Señala lo que merece tu atención, sin decirte qué hacer'),
          value: preferences.companionEnabled,
          onChanged: preferences.setCompanionEnabled,
        ),
        if (preferences.dismissedNotes.isNotEmpty)
          ListTile(
            leading: const SizedBox(width: 24),
            title: const Text('Volver a mostrar los avisos ocultos'),
            onTap: preferences.resetNotes,
          ),
      ]),
      section('Seguridad', [
        SwitchListTile(
          secondary: Icon(Icons.fingerprint, color: pulso.accent),
          title: const Text('Bloquear con huella o PIN del móvil'),
          subtitle: const Text('Al abrir Doblón y al volver a él'),
          value: preferences.lockEnabled,
          onChanged: (v) async {
            final done = await preferences.setLockEnabled(v);
            if (!done && context.mounted) {
              ScaffoldMessenger.of(context).showSnackBar(const SnackBar(content: Text('Activa primero un bloqueo de pantalla en tu móvil.')));
            }
          },
        ),
      ]),
      section('Tus datos', [
        route(Icons.upload_file, 'Importar movimientos CSV', 'Añade un extracto de tu banco', () => CsvImportScreen(repository: repository)),
        route(Icons.save_alt, 'Copia de seguridad', 'Guardar, exportar o restaurar', () => BackupScreen(repository: repository)),
      ]),
      const SizedBox(height: 16),
      Card(
        child: ListTile(
          leading: Icon(Icons.logout, color: pulso.expense),
          title: const Text('Salir de la cuenta'),
          onTap: () async {
            if (repository.pending.isNotEmpty) {
              final leave = await showDialog<bool>(
                context: context,
                builder: (context) => AlertDialog(
                  title: const Text('Hay cambios sin subir'),
                  content: Text(
                      '${repository.pending.length} cambios todavía no han llegado a tu nube. Si sales ahora se perderán. Conéctate a internet y espera a que se suban.'),
                  actions: [
                    TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Esperar')),
                    TextButton(onPressed: () => Navigator.pop(context, true), child: const Text('Salir igualmente')),
                  ],
                ),
              );
              if (leave != true) return;
            }
            await repository.signOut();
            await Supabase.instance.client.auth.signOut();
          },
        ),
      ),
      const SizedBox(height: 8),
      Center(child: Text('Doblón para Android', style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}
