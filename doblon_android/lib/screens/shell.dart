import 'dart:async';
import 'dart:ui' show ImageFilter;
import 'package:flutter/material.dart';
import 'package:supabase_flutter/supabase_flutter.dart';

import '../automation.dart';
import '../bank_activity.dart' show bankHolds;
import '../banking.dart' show BankingError, permissionDaysLeft, permissionExpiresSoon;
import '../card_payments.dart';
import '../data.dart';
import '../finance.dart';
import '../preferences.dart';
import '../theme.dart';
import 'accounts.dart';
import 'banks.dart';
import 'budgets.dart';
import 'card_payments.dart';
import 'chrome.dart';
import 'home.dart';
import 'info.dart';
import 'learning.dart' show AiMetricsScreen, ReviewProposalsScreen;
import 'manage.dart';
import 'tools.dart';
import 'transaction_form.dart';
import 'transaction_detail.dart';
import 'transactions.dart';
import 'widgets.dart' show RowGlyph;

export 'chrome.dart' show CompanionButton;

/// The same five tabs as the iPhone app, with Don Bigotes floating at the bottom right.
class Shell extends StatefulWidget {
  const Shell({super.key, required this.preferences});
  final AppPreferences preferences;
  @override
  State<Shell> createState() => _ShellState();
}

/// While open, the cloud copy and the banks are refreshed this often (and always on returning to the app).
const foregroundRefresh = Duration(minutes: 5);

class _ShellState extends State<Shell> with WidgetsBindingObserver, SingleTickerProviderStateMixin {
  final repository = FinanceRepository();
  int tab = 0;

  /// 1 while the header is shown, 0 once it has slid away; follows the finger and settles when the scroll stops.
  late final header = AnimationController(vsync: this, value: 1, duration: const Duration(milliseconds: 180));
  bool _scrolled = false;

  bool _onScroll(ScrollNotification n) {
    if (n.depth != 0 || n.metrics.axis != Axis.vertical) return false;
    if (n is ScrollUpdateNotification && n.scrollDelta != null) {
      header.value = nextHeaderShown(header.value, n.scrollDelta!, n.metrics.pixels);
    } else if (n is ScrollEndNotification && header.value > 0 && header.value < 1) {
      header.animateTo(header.value >= 0.5 || n.metrics.pixels < headerHeight ? 1 : 0, curve: Curves.easeOut);
    }
    final scrolled = n.metrics.pixels > 1;
    if (scrolled != _scrolled) setState(() => _scrolled = scrolled);
    return false;
  }

  void _select(int index) {
    header.animateTo(1, curve: Curves.easeOut);
    setState(() {
      tab = index;
      _scrolled = false;
    });
  }

  void _add() => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionFormScreen(repository: repository)));
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
    header.dispose();
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
      // Payments recorded with Apple Pay since the last opening (iPhone only), waiting for the bank.
      try {
        await CardPaymentInbox.file(repository);
      } catch (_) {/* They stay in the inbox and are filed on the next opening. */}
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

  // Don Bigotes' notes walk the whole history: kept until the finances, the bank reports or the day change, so a
  // notice about something else does not compute them again.
  Object? _notesFrom, _notesActivity, _notesConnections;
  String? _notesDay;
  List<CompanionNote> _notes = const [];

  List<CompanionNote> _companionNotes(FinanceCalculator calc) {
    final data = calc.data;
    final now = DateTime.now(), day = '${now.year}-${now.month}-${now.day}';
    if (identical(data, _notesFrom) &&
        identical(repository.bankActivity, _notesActivity) &&
        identical(repository.bankConnections, _notesConnections) &&
        day == _notesDay) {
      return _notes;
    }
    _notesFrom = data;
    _notesActivity = repository.bankActivity;
    _notesConnections = repository.bankConnections;
    _notesDay = day;
    final thisMonth = DateTime(now.year, now.month);
    final over = calc.budgetProgress(thisMonth).where((b) => b.limitMinor > 0 && b.spentMinor > b.limitMinor).length;
    return _notes =
        companionNotes(data, now, holds: bankHolds(data, repository.bankActivity), overBudget: over, budgetMonth: '${now.year}-${now.month}', renewals: [
      for (final connection in repository.bankConnections)
        if (permissionExpiresSoon(connection, now)) (bank: connection.bank, days: permissionDaysLeft(connection, now)!),
    ]);
  }

  /// Don Bigotes' notes, as on the iPhone (`CompanionNotesSheet`): his face, a button to update the banks and each
  /// note with its icon, «Ahora no» and «Ver».
  void _showCompanion(List<CompanionNote> notes, [List<CompanionNote> reviewed = const []]) {
    var refreshing = false;
    String? refreshed;
    showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        final pulso = Pulso.of(context);
        final hint = Theme.of(context).hintColor;
        return SafeArea(
          child: ConstrainedBox(
            constraints: BoxConstraints(maxHeight: MediaQuery.sizeOf(context).height * 0.8),
            child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(20, 0, 20, 20), children: [
              Row(children: [
                DonBigotesMark(awake: notes.isNotEmpty || refreshing, size: 52),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                    Text(notes.isEmpty ? 'Todo en orden' : 'Lo que he visto',
                        style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w700)),
                    Text(notes.isEmpty ? 'No hay nada pendiente. Vuelvo a mi esquina.' : 'Solo cosas tuyas, nada urgente.', style: TextStyle(color: hint)),
                  ]),
                ),
              ]),
              const SizedBox(height: 16),
              if (repository.bankConnections.isNotEmpty) ...[
                FilledButton.icon(
                  onPressed: refreshing
                      ? null
                      : () async {
                          setSheet(() {
                            refreshing = true;
                            refreshed = null;
                          });
                          final result = await repository.synchronizeBanks(manual: true);
                          if (context.mounted) {
                            setSheet(() {
                              refreshing = false;
                              refreshed = result?.summary;
                            });
                          }
                        },
                  style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(46)),
                  icon: refreshing
                      ? const SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2, color: Colors.white))
                      : const Icon(Icons.refresh),
                  label: Text(refreshing ? 'Consultando tus bancos…' : 'Actualizar mis bancos'),
                ),
                if (refreshed case final text? when text.isNotEmpty)
                  Container(
                    margin: const EdgeInsets.only(top: 8),
                    padding: const EdgeInsets.all(12),
                    decoration: BoxDecoration(color: pulso.tertiary, borderRadius: BorderRadius.circular(Pulso.compactRadius)),
                    child: Text(text, style: const TextStyle(fontSize: 13)),
                  ),
                const SizedBox(height: 12),
              ],
              for (final note in notes)
                Padding(
                  padding: const EdgeInsets.only(bottom: 10),
                  child: Card(
                    child: Padding(
                      padding: const EdgeInsets.all(12),
                      child: Row(children: [
                        RowGlyph(icon: _noteIcon(note), tint: note.urgent ? pulso.warning : pulso.accent),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                            Text(note.title, style: const TextStyle(fontWeight: FontWeight.w600)),
                            Text(note.detail, style: TextStyle(fontSize: 12, color: hint)),
                          ]),
                        ),
                        TextButton(
                          onPressed: () {
                            widget.preferences.dismissNote(note.id);
                            Navigator.pop(context);
                          },
                          style: TextButton.styleFrom(foregroundColor: hint, padding: const EdgeInsets.symmetric(horizontal: 8)),
                          child: const Text('Ahora no', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600)),
                        ),
                        FilledButton(
                          onPressed: () {
                            Navigator.pop(context);
                            _select(note.tab);
                          },
                          style: FilledButton.styleFrom(padding: const EdgeInsets.symmetric(horizontal: 14), minimumSize: const Size(0, 34)),
                          child: const Text('Ver', style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700)),
                        ),
                      ]),
                    ),
                  ),
                ),
              // Seen with «Ahora no»: still true, no longer pending; they can come back.
              if (reviewed.isNotEmpty) ...[
                Text(reviewed.length == 1 ? '1 aviso revisado' : '${reviewed.length} avisos revisados', style: Theme.of(context).textTheme.labelLarge),
                for (final note in reviewed)
                  Padding(
                    padding: const EdgeInsets.only(top: 4),
                    child: Row(children: [
                      Icon(Icons.done, size: 16, color: hint),
                      const SizedBox(width: 8),
                      Expanded(child: Text(note.title, style: TextStyle(fontSize: 13, color: hint))),
                    ]),
                  ),
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () {
                      widget.preferences.resetNotes();
                      Navigator.pop(context);
                    },
                    child: const Text('Volver a mostrarlos como pendientes'),
                  ),
                ),
                const SizedBox(height: 8),
              ],
              Text('Puedes apagarlo en Ajustes › A tu gusto.', style: TextStyle(fontSize: 12, color: hint)),
            ]),
          ),
        );
      }),
    );
  }

  static IconData _noteIcon(CompanionNote note) => switch (note.id.split(':').first) {
        'holds' => Icons.hourglass_bottom,
        'review' => Icons.checklist,
        'pairs' => Icons.swap_horiz,
        'renew' => Icons.key,
        'bankReview' => Icons.move_to_inbox,
        'recurring' => Icons.event,
        'stale' => Icons.schedule,
        'awaiting' => Icons.credit_card,
        _ => Icons.lightbulb_outline,
      };

  @override
  Widget build(BuildContext context) {
    final calc = calculator;
    final pulso = Pulso.of(context);
    // One list of what is pending, shown by Inicio and by Don Bigotes (when he is on), never twice on the same screen.
    final allNotes = calc == null ? <CompanionNote>[] : _companionNotes(calc);
    final notes = allNotes.where((n) => !widget.preferences.dismissedNotes.contains(n.id)).toList();
    final reviewed = allNotes.where((n) => widget.preferences.dismissedNotes.contains(n.id)).toList();
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
        edgeOffset: MediaQuery.paddingOf(context).top + headerHeight,
        child: switch (tab) {
          0 => HomeScreen(
              calc: calc,
              month: month,
              onMonth: setMonth,
              onAdd: () => _select(2),
              onOpenTab: _select,
              onOpenTransaction: (t) =>
                  Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: repository, transactionId: t.id))),
              // Charges the bank holds and has not booked yet, as on the iPhone's «Disponible tras retenciones».
              heldMinor: bankHolds(calc.data, repository.bankActivity)
                  .where((h) => h.movement.signedAmountMinor < 0)
                  .fold(0, (sum, h) => sum + h.movement.signedAmountMinor)),
          1 => TransactionsScreen(calc: calc, repository: repository),
          2 => AccountsScreen(calc: calc, repository: repository),
          3 => BudgetsScreen(calc: calc, month: month, onMonth: setMonth, repository: repository),
          _ => _SettingsPage(repository: repository, preferences: widget.preferences),
        },
      );
    }
    final banner = calc != null && repository.error != null;
    // Read outside the Scaffold, which takes the keyboard out of its body's insets.
    final typing = MediaQuery.viewInsetsOf(context).bottom > 0;
    final canAdd = calc != null && calc.data.accounts.any((a) => !a.isArchived);
    return Scaffold(
      // The content scrolls under the translucent tab bar, as on the iPhone app.
      extendBody: true,
      // Read inside the Scaffold: its bottom padding includes the tab bar.
      body: Builder(builder: (context) {
        final media = MediaQuery.of(context);
        return Stack(children: [
          Positioned.fill(
            child: NotificationListener<ScrollNotification>(
              onNotification: _onScroll,
              // The lists start below the header and the error notice (see `tabListPadding`). The status bar is taken
              // out of the padding so lists and grids inside the cards do not add it again.
              child: TabInsets(
                top: media.padding.top + headerHeight + (banner ? 56 : 0),
                child: MediaQuery.removePadding(context: context, removeTop: true, child: body),
              ),
            ),
          ),
          Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              ShellHeader(
                shown: header,
                scrolled: _scrolled,
                title: Text(tab == 0 ? greeting(DateTime.now()) : const ['Inicio', 'Movimientos', 'Cuentas', 'Presupuestos', 'Ajustes'][tab],
                    style: Theme.of(context).textTheme.titleLarge?.copyWith(fontWeight: FontWeight.w800)),
                actions: [
                  if (repository.pending.isNotEmpty)
                    IconButton(
                      tooltip: '${repository.pending.length} cambios sin subir',
                      icon: const Icon(Icons.cloud_upload_outlined),
                      onPressed: repository.refresh,
                    ),
                  if (repository.loading && calc != null)
                    const Padding(padding: EdgeInsets.all(15), child: SizedBox(width: 18, height: 18, child: CircularProgressIndicator(strokeWidth: 2))),
                  // Hide the amounts at a glance, on every tab.
                  IconButton(
                    tooltip: widget.preferences.hideAmounts ? 'Mostrar importes' : 'Ocultar importes',
                    icon: Icon(widget.preferences.hideAmounts ? Icons.visibility_off_outlined : Icons.visibility_outlined),
                    onPressed: () => widget.preferences.setHideAmounts(!widget.preferences.hideAmounts),
                  ),
                ],
              ),
              if (banner)
                Material(
                  color: Color.alphaBlend(pulso.warning.withValues(alpha: 0.15), pulso.page),
                  child: SizedBox(
                    height: 56,
                    child: ListTile(
                      dense: true,
                      leading: Icon(Icons.cloud_off_outlined, color: pulso.warning),
                      title: Text(repository.error!, maxLines: 2, overflow: TextOverflow.ellipsis),
                      trailing: TextButton(onPressed: repository.refresh, child: const Text('Reintentar')),
                    ),
                  ),
                ),
            ]),
          ),
        ]);
      }),
      bottomNavigationBar: ClipRect(
        child: BackdropFilter(
          filter: ImageFilter.blur(sigmaX: 24, sigmaY: 24),
          child: ColoredBox(
            color: pulso.card.withValues(alpha: 0.72),
            child: Column(mainAxisSize: MainAxisSize.min, children: [
              // Don Bigotes and «+ Añadir» in a band of their own, above the tabs: never over the content. Hidden while
              // typing.
              if (calc != null && !typing)
                BottomDock(
                  onAdd: canAdd ? _add : null,
                  notes: notes,
                  companion: widget.preferences.companionEnabled,
                  onCompanion: () => _showCompanion(notes, reviewed),
                ),
              NavigationBar(
                backgroundColor: Colors.transparent,
                selectedIndex: tab,
                onDestinationSelected: _select,
                destinations: const [
                  NavigationDestination(icon: Icon(Icons.home_outlined), selectedIcon: Icon(Icons.home), label: 'Inicio'),
                  NavigationDestination(icon: Icon(Icons.receipt_long_outlined), selectedIcon: Icon(Icons.receipt_long), label: 'Movimientos'),
                  NavigationDestination(icon: Icon(Icons.account_balance_outlined), selectedIcon: Icon(Icons.account_balance), label: 'Cuentas'),
                  NavigationDestination(icon: Icon(Icons.pie_chart_outline), selectedIcon: Icon(Icons.pie_chart), label: 'Presupuestos'),
                  NavigationDestination(icon: Icon(Icons.settings_outlined), selectedIcon: Icon(Icons.settings), label: 'Ajustes'),
                ],
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

class _SettingsPage extends StatelessWidget {
  const _SettingsPage({required this.repository, required this.preferences});
  final FinanceRepository repository;
  final AppPreferences preferences;

  /// Asks to type the word, as the server requires it, and suggests saving a backup first: it cannot be undone.
  Future<void> _deleteAccount(BuildContext context) async {
    final word = TextEditingController();
    final confirmed = await showDialog<bool>(
      context: context,
      builder: (context) => StatefulBuilder(
        builder: (context, setState) => AlertDialog(
          title: const Text('Eliminar mi cuenta'),
          content: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
            const Text('Se desconectan tus bancos y se borran tu cuenta y todos tus datos de la nube. No se puede deshacer. '
                'Si quieres conservarlos, guarda antes una copia en «Copia de seguridad».'),
            const SizedBox(height: 12),
            TextField(
              controller: word,
              autofocus: true,
              decoration: const InputDecoration(labelText: 'Escribe ELIMINAR para confirmar'),
              onChanged: (_) => setState(() {}),
            ),
          ]),
          actions: [
            TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
            TextButton(
              onPressed: word.text.trim() == 'ELIMINAR' ? () => Navigator.pop(context, true) : null,
              child: const Text('Eliminar'),
            ),
          ],
        ),
      ),
    );
    word.dispose();
    if (confirmed != true || !context.mounted) return;
    final messenger = ScaffoldMessenger.of(context);
    try {
      await repository.deleteAccount();
    } catch (error) {
      messenger.showSnackBar(
          SnackBar(content: Text(error is BankingError ? error.message : 'No se ha podido eliminar la cuenta. Comprueba la conexión e inténtalo de nuevo.')));
    }
  }

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
    return ListView(padding: tabListPadding(context), children: [
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
        if (CardPaymentInbox.available)
          route(Icons.credit_card, 'Pagos con Apple Pay', 'Apunta cada pago al momento con Atajos', () => CardPaymentsScreen(repository: repository)),
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
          secondary: const DonBigotesMark(size: 30),
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
      // Review and training tools of the developer, apart from everyday use. Guests never get tasks whose only purpose
      // is to label movements for the AI; their private learning keeps working as before, without asking anything.
      if (repository.isAdministrator)
        section('Avanzado · revisión y entrenamiento', [
          route(Icons.auto_awesome, 'Aplicar las propuestas de la IA', 'Categoriza de una vez lo que está sin categoría',
              () => ReviewProposalsScreen(repository: repository)),
          route(Icons.insights, 'Acierto de la IA', 'Cuántas propuestas de categoría se aceptan', () => AiMetricsScreen(repository: repository)),
        ]),
      section('Ayuda', [
        route(Icons.help_outline, 'Cómo usar la app', 'Primeros pasos y conceptos importantes', () => const HelpScreen()),
        route(Icons.front_hand_outlined, 'Privacidad y protección de datos', '', () => const PrivacyScreen()),
        route(Icons.info_outline, 'Acerca de Doblón', 'Versión $appVersion · conoce a Don Bigotes', () => const AboutScreen()),
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
      Card(
        child: ListTile(
          leading: Icon(Icons.delete_forever, color: pulso.expense),
          title: const Text('Eliminar mi cuenta'),
          subtitle: const Text('Borra tu cuenta y todos tus datos de la nube'),
          onTap: () => _deleteAccount(context),
        ),
      ),
      const SizedBox(height: 8),
      Center(child: Text('Doblón $appVersion', style: Theme.of(context).textTheme.bodySmall)),
    ]);
  }
}

/// Don Bigotes' face, drawn as on the iPhone app (Swift `DonBigotesMark`): open eyes when he has something to point
/// out, closed when everything is in order, and the bow tie in the accent colour.
class DonBigotesMark extends StatelessWidget {
  const DonBigotesMark({super.key, this.awake = true, this.size = 44});
  final bool awake;
  final double size;

  @override
  Widget build(BuildContext context) =>
      ExcludeSemantics(child: CustomPaint(size: Size.square(size), painter: _DonBigotesPainter(awake, Pulso.of(context).accent)));
}

class _DonBigotesPainter extends CustomPainter {
  _DonBigotesPainter(this.awake, this.accent);
  final bool awake;
  final Color accent;

  @override
  void paint(Canvas canvas, Size size) {
    final s = size.shortestSide / 48;
    Offset p(double x, double y) => Offset(x * s, y * s);
    Paint fill(Color color) => Paint()..color = color;
    const ink = Color(0xFF14202C);
    canvas.drawPath(
        Path()
          ..moveTo(10 * s, 20 * s)
          ..lineTo(13 * s, 6 * s)
          ..lineTo(21 * s, 14 * s)
          ..close()
          ..moveTo(38 * s, 20 * s)
          ..lineTo(35 * s, 6 * s)
          ..lineTo(27 * s, 14 * s)
          ..close(),
        fill(const Color(0xFFE9E1D6)));
    canvas.drawOval(Rect.fromLTWH(9 * s, 10.5 * s, 30 * s, 27 * s), fill(const Color(0xFFF3EEE6)));
    if (awake) {
      canvas.drawOval(Rect.fromLTWH(16 * s, 20 * s, 6 * s, 6 * s), fill(ink));
      canvas.drawOval(Rect.fromLTWH(26 * s, 20 * s, 6 * s, 6 * s), fill(ink));
      canvas.drawOval(Rect.fromLTWH(19.5 * s, 20.6 * s, 1.8 * s, 1.8 * s), fill(Colors.white));
      canvas.drawOval(Rect.fromLTWH(29.5 * s, 20.6 * s, 1.8 * s, 1.8 * s), fill(Colors.white));
    } else {
      final lid = Paint()
        ..color = ink
        ..style = PaintingStyle.stroke
        ..strokeWidth = 1.6 * s
        ..strokeCap = StrokeCap.round;
      canvas.drawPath(
          Path()
            ..moveTo(16 * s, 24 * s)
            ..quadraticBezierTo(19 * s, 26.5 * s, 22 * s, 24 * s)
            ..moveTo(26 * s, 24 * s)
            ..quadraticBezierTo(29 * s, 26.5 * s, 32 * s, 24 * s),
          lid);
    }
    canvas.drawPath(Path()..addPolygon([p(22.5, 29), p(25.5, 29), p(24, 31)], true), fill(const Color(0xFFC98C85)));
    canvas.drawPath(Path()..addPolygon([p(24, 37), p(21, 44), p(24, 47), p(27, 44)], true), fill(accent));
  }

  @override
  bool shouldRepaint(_DonBigotesPainter old) => old.awake != awake || old.accent != accent;
}
