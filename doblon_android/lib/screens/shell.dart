import 'dart:async';
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../automation.dart';
import '../bank_activity.dart' show bankHolds;
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

/// The same five tabs as the iPhone app, with Don Bigotes floating at the bottom right.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.preferences});
  final AppPreferences preferences;
  @override
  State<Shell> createState() => _ShellState();
}

/// While open, the cloud copy and the banks are refreshed this often (and always on returning to the app).
const foregroundRefresh = Duration(minutes: 5);

class _ShellState extends State<Shell> with WidgetsBindingObserver {
  final repository = FinanceRepository();
  int tab = 0;
  DateTime month = DateTime(DateTime.now().year, DateTime.now().month);
  FinanceCalculator? _calculator;
  Object? _calculatedFrom;
  bool _postedToday = false;
  bool _opening = false;
  bool _foreground = true;
  Timer? _refreshTimer;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    repository.addListener(_changed);
    widget.preferences.addListener(_changed);
    _open();
    _refreshTimer = Timer.periodic(foregroundRefresh, (_) {
      if (_foreground) unawaited(_open());
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    repository.removeListener(_changed);
    _refreshTimer?.cancel();
    repository.dispose();
    widget.preferences.removeListener(_changed);
    super.dispose();
  }

  /// Downloads, then posts the periodic movements that are due (once per opening), as the iPhone does.
  Future<void> _open() async {
    if (_opening || !mounted) return;
    _opening = true;
    try {
      await repository.refresh();
      if (!mounted || repository.finances == null || repository.error != null) return;
      if (!_postedToday) {
        _postedToday = true;
        await postDue(repository);
      }
      // Corrections the person taught several times are repeated on new bank movements (as on the iPhone).
      await repository.applyLearnedCorrections();
      unawaited(repository.synchronizeBanks());
    } finally {
      _opening = false;
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    _foreground = state == AppLifecycleState.resumed;
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
        : companionNotes(calc.data, DateTime.now(), holds: bankHolds(calc.data, repository.bankActivity))
            .where((n) => !widget.preferences.dismissedNotes.contains(n.id))
            .toList();
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
        ],
      ),
      body: Stack(children: [
        Positioned.fill(
          child: calc != null && repository.error != null
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
        ),
        if (widget.preferences.companionEnabled && calc != null)
          Positioned(
            right: 16,
            // Above the add button of Movimientos, Cuentas and Presupuestos.
            bottom: tab >= 1 && tab <= 3 ? 88 : 16,
            child: CompanionButton(notes: notes, onTap: () => _showCompanion(notes)),
          ),
      ]),
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

/// Don Bigotes, as on the iPhone: awake with a bubble when he has something to point out, asleep (faded and
/// tilted) when everything is in order. His name is always visible.
class CompanionButton extends StatelessWidget {
  const CompanionButton({super.key, required this.notes, required this.onTap});
  final List<CompanionNote> notes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final scheme = Theme.of(context).colorScheme;
    final awake = notes.isNotEmpty;
    final text = !awake ? 'Don Bigotes' : 'Don Bigotes · ${notes.length == 1 ? 'tengo un aviso' : 'tengo ${notes.length} avisos'}';
    return Semantics(
      button: true,
      label: awake ? 'Don Bigotes tiene ${notes.length == 1 ? 'algo' : '${notes.length} cosas'} que contarte' : 'Don Bigotes, sin novedades',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        child: Row(mainAxisSize: MainAxisSize.min, children: [
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
            decoration: BoxDecoration(
              color: awake ? scheme.onSurface : scheme.surfaceContainerHighest,
              borderRadius: const BorderRadius.only(
                  topLeft: Radius.circular(18), bottomLeft: Radius.circular(18), topRight: Radius.circular(18), bottomRight: Radius.circular(4)),
              boxShadow: awake ? const [BoxShadow(color: Color(0x2E000000), blurRadius: 8, offset: Offset(0, 4))] : null,
            ),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (awake) ...[
                Container(width: 8, height: 8, decoration: BoxDecoration(color: pulso.warning, shape: BoxShape.circle)),
                const SizedBox(width: 7),
              ],
              Text(text,
                  style: TextStyle(
                      fontSize: 13, fontWeight: FontWeight.w600, color: awake ? scheme.surface : scheme.onSurfaceVariant)),
            ]),
          ),
          const SizedBox(width: 8),
          Opacity(
            opacity: awake ? 1 : 0.6,
            child: Transform.rotate(
              angle: awake ? 0 : -0.21,
              child: ClipOval(child: Image.asset('assets/don_bigotes.png', width: awake ? 48 : 42, height: awake ? 48 : 42, fit: BoxFit.cover)),
            ),
          ),
        ]),
      ),
    );
  }
}
