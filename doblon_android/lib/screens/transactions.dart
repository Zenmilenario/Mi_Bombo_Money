import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../data.dart';
import '../edits.dart';
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'transaction_detail.dart';
import 'transaction_form.dart';
import 'widgets.dart';

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
    final op = categorizeOperation(chosen, category, DateTime.now());
    final skipped = chosen.length - (op.data['ids'] as List).length;
    await widget.repository.apply(op);
    if (!mounted) return;
    setState(selected.clear);
    if (skipped > 0) {
      ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('$skipped no admiten «${category.name}» y se han dejado como estaban.')));
    }
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
