import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../automation.dart';
import '../bank_activity.dart';
import '../data.dart';
import '../edits.dart';
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'learning.dart' show ReviewProposalsScreen;
import 'transaction_detail.dart';
import 'transaction_form.dart';
import 'widgets.dart';
import 'contributions.dart';

enum Period { all, thisMonth, lastMonth, threeMonths, thisYear }

extension PeriodTitle on Period {
  String get title => switch (this) {
        Period.all => 'Todo',
        Period.thisMonth => 'Este mes',
        Period.lastMonth => 'Mes anterior',
        Period.threeMonths => 'Últimos 3 meses',
        Period.thisYear => 'Este año',
      };
  bool contains(DateTime date, DateTime now) {
    final d = date.toLocal();
    return switch (this) {
      Period.all => true,
      Period.thisMonth => d.year == now.year && d.month == now.month,
      Period.lastMonth => monthKey(d) == monthKey(now) - 1,
      Period.threeMonths => monthKey(d) >= monthKey(now) - 2 && !d.isAfter(now.add(const Duration(days: 1))),
      Period.thisYear => d.year == now.year,
    };
  }
}

/// The movement filters, as on the iPhone: search, review, type, account, category and period.
class MovementFilter {
  String query = '';
  bool onlyReview = false;
  TransactionType? type;
  String? accountId;
  String? categoryId;
  Period period = Period.all;

  bool get isActive => onlyReview || type != null || accountId != null || categoryId != null || period != Period.all;

  bool matches(Transaction t, Finances data, DateTime now) {
    if (onlyReview && reviewIssues(t, data.category(t.categoryId)).isEmpty) return false;
    if (type != null && t.type != type) return false;
    if (accountId != null && t.sourceAccountId != accountId && t.destinationAccountId != accountId) return false;
    if (categoryId != null && t.categoryId != categoryId) return false;
    if (!period.contains(t.date, now)) return false;
    if (query.isEmpty) return true;
    final q = query.toLowerCase();
    return [
      t.descriptionText,
      listTitle(t.descriptionText, isBanking: t.isBanking),
      t.notes,
      data.account(t.sourceAccountId)?.name ?? '',
      data.account(t.destinationAccountId)?.name ?? '',
      data.category(t.categoryId)?.name ?? '',
      t.type.title,
    ].any((text) => text.toLowerCase().contains(q));
  }
}

/// Movimientos: grouped by day, with search, filters, review, selection to categorize, and a button to add.
class TransactionsScreen extends StatefulWidget {
  const TransactionsScreen({super.key, required this.calc, required this.repository});
  final FinanceCalculator calc;
  final FinanceRepository repository;
  @override
  State<TransactionsScreen> createState() => _TransactionsScreenState();
}

class _TransactionsScreenState extends State<TransactionsScreen> {
  final filter = MovementFilter();
  final selected = <String>{};

  bool get selecting => selected.isNotEmpty;

  Future<void> _categorizeSelected(Finances data) async {
    final chosen = data.transactions.where((t) => selected.contains(t.id)).toList();
    final category = await pickCategory(context, data, chosen);
    if (category == null) return;
    final skipped = chosen.where((t) => !categorySupports(category, t.type)).length;
    await widget.repository.categorize(chosen, category);
    if (!mounted) return;
    setState(selected.clear);
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$skipped no admiten «${category.name}» y se han dejado como estaban.')));
    }
  }

  /// Charges and credits the bank has not booked yet (Swift `BankHoldsSection`), with the list filters.
  List<Widget> _holds(Finances data) {
    if (filter.categoryId != null || filter.onlyReview) return const [];
    final q = filter.query.toLowerCase();
    final holds = bankHolds(data, widget.repository.bankActivity).where((h) {
      if (filter.accountId != null && h.account.id != filter.accountId) return false;
      final type = filter.type;
      if (type != null) {
        if (type != TransactionType.expense && type != TransactionType.income) return false;
        if ((type == TransactionType.income) != (h.movement.signedAmountMinor > 0)) return false;
      }
      if (q.isEmpty) return true;
      return [h.movement.description, listTitle(h.movement.description, isBanking: true), h.account.name].any((t) => t.toLowerCase().contains(q));
    }).toList();
    if (holds.isEmpty) return const [];
    final pulso = Pulso.of(context);
    String day(String? raw) => raw == null ? '' : ' · ${raw.split('-').reversed.join('/')}';
    return [
      Card(
        margin: const EdgeInsets.only(top: 8),
        child: ExpansionTile(
          leading: Icon(Icons.hourglass_bottom, color: pulso.warning),
          title: Text(holds.length == 1 ? '1 movimiento pendiente del banco' : '${holds.length} movimientos pendientes del banco'),
          subtitle:
              Text('Retenido: ${money(holds.fold(0, (sum, h) => sum + (h.movement.signedAmountMinor < 0 ? h.movement.signedAmountMinor : 0)), signed: true)}'),
          children: [
            for (final h in holds)
              ListTile(
                dense: true,
                title: Text(listTitle(h.movement.description, isBanking: true), maxLines: 1, overflow: TextOverflow.ellipsis),
                subtitle: Text('${h.movement.isHold ? 'Retenido' : 'Pendiente'}${day(h.movement.date)} · ${h.account.name}'),
                trailing: Text(money(h.movement.signedAmountMinor, signed: true, currency: h.movement.currency),
                    style: TextStyle(fontWeight: FontWeight.w700, color: h.movement.signedAmountMinor < 0 ? pulso.expense : pulso.income)),
              ),
            const Padding(
              padding: EdgeInsets.fromLTRB(16, 0, 16, 12),
              child:
                  Text('Importes provisionales. Se reflejan en el historial y el presupuesto cuando el banco los contabiliza.', style: TextStyle(fontSize: 12)),
            ),
          ],
        ),
      ),
    ];
  }

  /// Each pair can be joined into one transfer (it stops counting as income and expense) or left as it is.
  Future<void> _showPairs(Finances data) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SafeArea(
        child: ListView(shrinkWrap: true, padding: const EdgeInsets.fromLTRB(16, 0, 16, 16), children: [
          const Text('Si son la misma operación entre tus cuentas, únelas en un traspaso: dejará de contar como gasto e ingreso.'),
          const SizedBox(height: 12),
          for (final pair in ownTransferPairs(data))
            Card(
              child: Column(children: [
                TransactionTile(transaction: pair.debit, data: data),
                TransactionTile(transaction: pair.credit, data: data),
                Align(
                  alignment: Alignment.centerRight,
                  child: TextButton.icon(
                    icon: const Icon(Icons.merge_type),
                    label: const Text('Unir como traspaso'),
                    onPressed: () async {
                      Navigator.pop(context);
                      await widget.repository.apply(joinOwnTransfer(pair, data, DateTime.now()));
                    },
                  ),
                ),
              ]),
            ),
        ]),
      ),
    );
  }

  Future<void> _chooseFilters(Finances data) async {
    await showModalBottomSheet<void>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => StatefulBuilder(builder: (context, setSheet) {
        void change(VoidCallback update) {
          setSheet(update);
          setState(() {});
        }

        return Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 24),
          child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.stretch, children: [
            const Text('Filtros', style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700)),
            const SizedBox(height: 12),
            DropdownButtonFormField<Period>(
              initialValue: filter.period,
              decoration: const InputDecoration(labelText: 'Periodo', border: OutlineInputBorder()),
              items: [for (final p in Period.values) DropdownMenuItem(value: p, child: Text(p.title))],
              onChanged: (value) => change(() => filter.period = value ?? Period.all),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<TransactionType?>(
              initialValue: filter.type,
              decoration: const InputDecoration(labelText: 'Tipo', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<TransactionType?>(value: null, child: Text('Todos')),
                for (final t in TransactionType.values) DropdownMenuItem<TransactionType?>(value: t, child: Text(t.title)),
              ],
              onChanged: (value) => change(() => filter.type = value),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: filter.accountId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Cuenta', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Todas')),
                for (final a in data.accounts.where((a) => !a.isArchived)) DropdownMenuItem<String?>(value: a.id, child: Text(a.name)),
              ],
              onChanged: (value) => change(() => filter.accountId = value),
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String?>(
              initialValue: filter.categoryId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Categoría', border: OutlineInputBorder()),
              items: [
                const DropdownMenuItem<String?>(value: null, child: Text('Todas')),
                for (final c in data.categories.where((c) => !c.isArchived)) DropdownMenuItem<String?>(value: c.id, child: Text(c.name)),
              ],
              onChanged: (value) => change(() => filter.categoryId = value),
            ),
            const SizedBox(height: 12),
            TextButton(
              onPressed: () => change(() {
                filter
                  ..period = Period.all
                  ..type = null
                  ..accountId = null
                  ..categoryId = null
                  ..onlyReview = false;
              }),
              child: const Text('Quitar filtros'),
            ),
          ]),
        );
      }),
    );
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final data = widget.calc.data;
    final now = DateTime.now();
    final reviewCount = data.transactions.where((t) => reviewIssues(t, data.category(t.categoryId)).isNotEmpty).length;
    final visible = data.transactions.where((t) => filter.matches(t, data, now)).toList();
    final days = <DateTime, List<Transaction>>{};
    for (final t in visible) {
      final local = t.date.toLocal();
      (days[DateTime(local.year, local.month, local.day)] ??= []).add(t);
    }
    final ordered = days.keys.toList()..sort((a, b) => b.compareTo(a));
    final format = DateFormat("EEEE d 'de' MMMM yyyy", 'es');
    final income = visible.where((t) => t.type.countsAsIncome).fold(0, (s, t) => s + t.amountMinor);
    final expense = visible.where((t) => t.type.countsAsExpense).fold(0, (s, t) => s + t.amountMinor);

    return Scaffold(
      backgroundColor: Colors.transparent,
      floatingActionButton: selecting
          ? FloatingActionButton.extended(
              onPressed: () => _categorizeSelected(data),
              icon: const Icon(Icons.sell_outlined),
              label: Text('Categorizar ${selected.length}'),
            )
          : FloatingActionButton(
              tooltip: 'Añadir movimiento',
              onPressed: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => TransactionFormScreen(repository: widget.repository))),
              child: const Icon(Icons.add),
            ),
      body: CustomScrollView(physics: const AlwaysScrollableScrollPhysics(), slivers: [
        SliverPadding(
          padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
          sliver: SliverToBoxAdapter(
            child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
              if (selecting)
                Row(children: [
                  IconButton(onPressed: () => setState(selected.clear), icon: const Icon(Icons.close)),
                  Text('${selected.length} seleccionados', style: const TextStyle(fontWeight: FontWeight.w700)),
                  const Spacer(),
                  TextButton(onPressed: () => setState(() => selected.addAll(visible.map((t) => t.id))), child: const Text('Todos')),
                ])
              else
                TextField(
                  decoration:
                      const InputDecoration(prefixIcon: Icon(Icons.search), hintText: 'Buscar concepto, cuenta o categoría', border: OutlineInputBorder()),
                  onChanged: (value) => setState(() => filter.query = value.trim()),
                ),
              if (!selecting) ..._holds(data),
              if (!selecting && widget.repository.contributions.isNotEmpty)
                Card(
                    child: ListTile(
                        leading: Icon(Icons.savings_outlined, color: pulso.savings),
                        title: Text('${widget.repository.contributions.length} aportaciones por conciliar'),
                        subtitle: const Text('Unir los cargos reales con tu aportación periódica'),
                        trailing: const Icon(Icons.chevron_right),
                        onTap: () => Navigator.of(context).push(MaterialPageRoute(builder: (_) => ContributionsScreen(repository: widget.repository))))),
              if (!selecting && ownTransferPairs(data).isNotEmpty)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: Icon(Icons.swap_horiz, color: pulso.savings),
                    title: Text(ownTransferPairs(data).length == 1
                        ? '1 posible traspaso entre tus cuentas'
                        : '${ownTransferPairs(data).length} posibles traspasos entre tus cuentas'),
                    subtitle: const Text('Un cargo y un abono del mismo importe'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _showPairs(data),
                  ),
                ),
              const SizedBox(height: 8),
              SingleChildScrollView(
                scrollDirection: Axis.horizontal,
                child: Row(children: [
                  if (reviewCount > 0 || filter.onlyReview)
                    Padding(
                      padding: const EdgeInsets.only(right: 8),
                      child: FilterChip(
                        label: Text('Por revisar · $reviewCount'),
                        selected: filter.onlyReview,
                        selectedColor: pulso.warning.withValues(alpha: 0.2),
                        onSelected: (on) => setState(() => filter.onlyReview = on),
                      ),
                    ),
                  ActionChip(
                    avatar: Icon(filter.isActive ? Icons.filter_alt : Icons.filter_alt_outlined, size: 18),
                    label: Text(filter.isActive ? 'Filtros activos' : 'Filtros'),
                    onPressed: () => _chooseFilters(data),
                  ),
                  const SizedBox(width: 8),
                  if (filter.period != Period.all) Chip(label: Text(filter.period.title)),
                ]),
              ),
              if (filter.onlyReview && !selecting)
                Card(
                  margin: const EdgeInsets.only(top: 8),
                  child: ListTile(
                    leading: Icon(Icons.auto_awesome, color: pulso.accent),
                    title: const Text('Aplicar las propuestas de la IA'),
                    subtitle: const Text('Revisa y categoriza varios movimientos de una vez'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () async {
                      final applied = await Navigator.of(context)
                          .push<int>(MaterialPageRoute(builder: (_) => ReviewProposalsScreen(repository: widget.repository)));
                      if (applied != null && applied > 0 && context.mounted) {
                        ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$applied movimientos categorizados.')));
                      }
                    },
                  ),
                ),
              if (filter.isActive || filter.query.isNotEmpty)
                Padding(
                  padding: const EdgeInsets.only(top: 8),
                  child: Text('${visible.length} movimientos · ingresos ${money(income)} · gastos ${money(expense)}',
                      style: Theme.of(context).textTheme.bodySmall),
                ),
            ]),
          ),
        ),
        if (ordered.isEmpty)
          SliverFillRemaining(
            hasScrollBody: false,
            child: Center(child: Text(filter.onlyReview ? 'Nada por revisar.' : 'Sin resultados')),
          )
        else
          SliverList.builder(
            itemCount: ordered.length,
            itemBuilder: (context, index) {
              final day = ordered[index];
              final label = format.format(day);
              return Padding(
                padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Padding(
                    padding: const EdgeInsets.fromLTRB(4, 8, 4, 6),
                    child: Text('${label[0].toUpperCase()}${label.substring(1)}', style: Theme.of(context).textTheme.labelLarge),
                  ),
                  Card(
                    child: Column(children: [
                      for (final t in days[day]!)
                        Container(
                          color: selected.contains(t.id) ? pulso.accent.withValues(alpha: 0.12) : null,
                          child: InkWell(
                            onLongPress: () => setState(() => selected.contains(t.id) ? selected.remove(t.id) : selected.add(t.id)),
                            onTap: () {
                              if (selecting) {
                                setState(() => selected.contains(t.id) ? selected.remove(t.id) : selected.add(t.id));
                              } else {
                                Navigator.of(context)
                                    .push(MaterialPageRoute(builder: (_) => TransactionDetailScreen(repository: widget.repository, transactionId: t.id)));
                              }
                            },
                            child: IgnorePointer(child: TransactionTile(transaction: t, data: data)),
                          ),
                        ),
                    ]),
                  ),
                ]),
              );
            },
          ),
        const SliverToBoxAdapter(child: SizedBox(height: 96)),
      ]),
    );
  }
}
