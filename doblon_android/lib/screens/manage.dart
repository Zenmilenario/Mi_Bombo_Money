import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../automation.dart';
import '../banking.dart' show referenceSeconds;
import '../data.dart';
import '../edits.dart';
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'forms.dart';
import 'widgets.dart' show RowGlyph, SectionTitle;

/// A management list that follows the repository: rebuilds when data changes.
class _Managed extends StatelessWidget {
  const _Managed({required this.repository, required this.title, required this.builder, this.onAdd});
  final FinanceRepository repository;
  final String title;
  final List<Widget> Function(BuildContext, Finances) builder;
  final VoidCallback? onAdd;
  @override
  Widget build(BuildContext context) => ListenableBuilder(
        listenable: repository,
        builder: (context, _) {
          final data = repository.finances;
          return Scaffold(
            appBar: AppBar(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700))),
            floatingActionButton: onAdd == null ? null : FloatingActionButton(onPressed: onAdd, child: const Icon(Icons.add)),
            body: data == null
                ? const Center(child: CircularProgressIndicator())
                : ListView(padding: const EdgeInsets.all(16), children: [...builder(context, data), const SizedBox(height: 80)]),
          );
        },
      );
}

void _open(BuildContext context, Widget page) => Navigator.of(context).push(MaterialPageRoute(builder: (_) => page));

String _kindTitle(CategoryKind kind) => switch (kind) {
      CategoryKind.expense => 'Gasto',
      CategoryKind.income => 'Ingreso',
      CategoryKind.both => 'Gasto e ingreso',
      CategoryKind.transfer => 'Traspaso',
    };

// ---------------------------------------------------------------- categories

class CategoriesScreen extends StatelessWidget {
  const CategoriesScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  Widget build(BuildContext context) => _Managed(
        repository: repository,
        title: 'Categorías',
        onAdd: () => _open(context, CategoryFormScreen(repository: repository)),
        builder: (context, data) {
          final active = data.categories.where((c) => !c.isArchived).toList();
          final archived = data.categories.where((c) => c.isArchived).toList();
          Widget tile(Category c) => ListTile(
                leading: RowGlyph(icon: symbolIcon(c.systemImage), tint: colorFromHex(c.colorHex)),
                title: Text(c.name),
                subtitle: Text(_kindTitle(c.kind)),
                onTap: () => _open(context, CategoryFormScreen(repository: repository, editing: c)),
              );
          return [
            Card(child: Column(children: [for (final c in active) tile(c)])),
            if (archived.isNotEmpty) ExpansionTile(title: Text('Archivadas (${archived.length})'), children: [for (final c in archived) tile(c)]),
          ];
        },
      );
}

class CategoryFormScreen extends StatefulWidget {
  const CategoryFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final Category? editing;
  @override
  State<CategoryFormScreen> createState() => _CategoryFormScreenState();
}

class _CategoryFormScreenState extends State<CategoryFormScreen> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late CategoryKind _kind = widget.editing?.kind ?? CategoryKind.expense;
  late String _color = widget.editing?.colorHex ?? '#4D7C8A';
  late String _symbol = widget.editing?.systemImage ?? 'tag.fill';
  String? _message;

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing;
    final used = editing != null && widget.repository.finances!.transactions.any((t) => t.categoryId == editing.id);
    return FormPage(
      title: editing == null ? 'Nueva categoría' : 'Editar categoría',
      message: _message,
      actions: [
        if (editing != null)
          IconButton(
            tooltip: editing.isArchived ? 'Recuperar' : 'Archivar',
            icon: Icon(editing.isArchived ? Icons.unarchive_outlined : Icons.archive_outlined),
            onPressed: () async {
              await widget.repository.apply(upsertOperation(
                  'categories', {'id': editing.id, 'isArchived': !editing.isArchived, 'updatedAt': referenceSeconds(DateTime.now())},
                  create: false));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
      ],
      onSave: () async {
        final name = _name.text.trim();
        if (name.isEmpty) return setState(() => _message = 'Escribe el nombre.');
        final now = referenceSeconds(DateTime.now());
        final fields = {'name': name, 'kindRaw': _kind.name, 'colorHex': _color, 'systemImage': _symbol, 'updatedAt': now};
        await widget.repository.apply(editing != null
            ? upsertOperation('categories', {'id': editing.id, ...fields}, create: false)
            : upsertOperation(
                'categories',
                {
                  'id': widget.repository.newId(),
                  ...fields,
                  'isArchived': false,
                  'isSystem': false,
                  'sortOrder': widget.repository.finances!.categories.length,
                  'createdAt': now,
                },
                create: true));
        if (mounted) Navigator.of(this.context).pop();
      },
      children: [
        TextInput(controller: _name, label: 'Nombre'),
        if (!used)
          Choice<CategoryKind>(
              label: 'Tipo', value: _kind, options: {for (final k in CategoryKind.values) k: _kindTitle(k)}, onChanged: (v) => setState(() => _kind = v))
        else
          Text('Tipo: ${_kindTitle(_kind)} (ya tiene movimientos, no se puede cambiar).'),
        ColorInput(value: _color, onChanged: (v) => setState(() => _color = v)),
        const SizedBox(height: 8),
        // As on the iPhone: the icon, chosen from a grid, and a preview of how the category looks.
        Text('Icono', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Wrap(spacing: 8, runSpacing: 8, children: [
          for (final symbol in categorySymbols)
            Semantics(
              selected: symbol == _symbol,
              button: true,
              child: InkWell(
                borderRadius: BorderRadius.circular(12),
                onTap: () => setState(() => _symbol = symbol),
                child: Container(
                  width: 44,
                  height: 44,
                  decoration: BoxDecoration(
                    color: colorFromHex(_color).withValues(alpha: symbol == _symbol ? 0.22 : 0.08),
                    borderRadius: BorderRadius.circular(12),
                    border: symbol == _symbol ? Border.all(color: colorFromHex(_color), width: 2) : null,
                  ),
                  child: Icon(symbolIcon(symbol), color: colorFromHex(_color)),
                ),
              ),
            ),
        ]),
        const SizedBox(height: 16),
        Text('Vista previa', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: RowGlyph(icon: symbolIcon(_symbol), tint: colorFromHex(_color)),
            title: Text(_name.text.trim().isEmpty ? 'Nombre de la categoría' : _name.text.trim()),
            subtitle: Text(_kindTitle(_kind)),
          ),
        ),
      ],
    );
  }
}

// ---------------------------------------------------------------- rules

class RulesScreen extends StatelessWidget {
  const RulesScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  Widget build(BuildContext context) => _Managed(
        repository: repository,
        title: 'Categorización automática',
        onAdd: () => _open(context, RuleFormScreen(repository: repository)),
        builder: (context, data) => [
          const Text('Cuando un concepto contiene la frase, el movimiento nuevo recibe esa categoría.'),
          const SizedBox(height: 12),
          if (data.categoryRules.isEmpty) const Text('Aún no hay reglas.'),
          Card(
            child: Column(children: [
              for (final r in data.categoryRules)
                ListTile(
                  leading: Icon(r.isActive ? Icons.rule : Icons.pause_circle_outline),
                  title: Text('«${r.phrase}»'),
                  subtitle: Text('${r.transactionType.title} → ${data.category(r.categoryId)?.name ?? 'Sin categoría'}'),
                  onTap: () => _open(context, RuleFormScreen(repository: repository, editing: r)),
                ),
            ]),
          ),
        ],
      );
}

class RuleFormScreen extends StatefulWidget {
  const RuleFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final CategoryRule? editing;
  @override
  State<RuleFormScreen> createState() => _RuleFormScreenState();
}

class _RuleFormScreenState extends State<RuleFormScreen> {
  late final _phrase = TextEditingController(text: widget.editing?.phrase ?? '');
  late TransactionType _type = widget.editing?.transactionType ?? TransactionType.expense;
  late String? _category = widget.editing?.categoryId;
  late bool _active = widget.editing?.isActive ?? true;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final data = widget.repository.finances!;
    final categories = data.categories.where((c) => categorySupports(c, _type)).toList();
    if (_category != null && !categories.any((c) => c.id == _category)) _category = null;
    final editing = widget.editing;
    return FormPage(
      title: editing == null ? 'Nueva regla' : 'Editar regla',
      message: _message,
      actions: [
        if (editing != null)
          IconButton(
            tooltip: 'Borrar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              await widget.repository.apply(removeOperation('categoryRules', editing.id));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
      ],
      onSave: () async {
        final phrase = _phrase.text.trim();
        if (ruleText(phrase).length < 3) return setState(() => _message = 'La frase necesita al menos tres caracteres.');
        if (_category == null) return setState(() => _message = 'Elige la categoría.');
        final now = referenceSeconds(DateTime.now());
        final fields = {'phrase': phrase, 'transactionTypeRaw': _type.name, 'isActive': _active, 'categoryID': _category, 'updatedAt': now};
        await widget.repository.apply(editing != null
            ? upsertOperation('categoryRules', {'id': editing.id, ...fields}, create: false)
            : upsertOperation('categoryRules', {'id': widget.repository.newId(), ...fields, 'createdAt': now}, create: true));
        if (mounted) Navigator.of(this.context).pop();
      },
      children: [
        TextInput(controller: _phrase, label: 'El concepto contiene', capitalize: false),
        Choice<TransactionType>(
            label: 'Tipo de movimiento',
            value: _type,
            options: {for (final t in TransactionType.values.where((t) => t != TransactionType.transfer)) t: t.title},
            onChanged: (v) => setState(() => _type = v)),
        Choice<String?>(
            label: 'Categoría',
            value: _category,
            options: {null: 'Elige una', for (final c in categories) c.id: c.name},
            onChanged: (v) => setState(() => _category = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Activa'), value: _active, onChanged: (v) => setState(() => _active = v)),
      ],
    );
  }
}

// ---------------------------------------------------------------- periodic movements

class RecurringScreen extends StatelessWidget {
  const RecurringScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  Widget build(BuildContext context) => _Managed(
        repository: repository,
        title: 'Cargos y aportaciones periódicas',
        onAdd: () => _open(context, RecurringFormScreen(repository: repository)),
        builder: (context, data) {
          final format = DateFormat("d 'de' MMMM", 'es');
          final active = data.recurringMovements.where((r) => r.isActive).toList();
          final paused = data.recurringMovements.where((r) => !r.isActive).toList();
          final pulso = Pulso.of(context);
          Widget tile(RecurringMovement r) {
            final category = data.category(r.categoryId);
            final color = r.type.countsAsIncome ? pulso.income : (r.type == TransactionType.transfer ? pulso.savings : pulso.expense);
            final destination = data.account(r.destinationAccountId);
            return ListTile(
              leading: RowGlyph(
                  icon: category != null
                      ? symbolIcon(category.systemImage)
                      : (r.type == TransactionType.transfer ? Icons.swap_horiz : (r.isSubscription ? Icons.subscriptions_outlined : Icons.repeat)),
                  tint: category != null ? colorFromHex(category.colorHex) : color),
              title: Text(r.name, style: const TextStyle(fontWeight: FontWeight.w600)),
              subtitle: Text([
                r.frequency.title,
                'próximo ${format.format(r.nextDueDate)}',
                if (destination != null) 'a ${destination.name}',
                if (r.postsAutomatically == true) 'se apunta solo',
              ].join(' · ')),
              trailing: Text(r.type == TransactionType.transfer ? money(r.amountMinor) : money(r.type.countsAsIncome ? r.amountMinor : -r.amountMinor, signed: true),
                  style: TextStyle(fontWeight: FontWeight.w700, color: color)),
              onTap: () => _open(context, RecurringFormScreen(repository: repository, editing: r)),
            );
          }

          return [
            Card(
              child: Padding(
                padding: const EdgeInsets.all(14),
                child: Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
                  const Text('Programar movimientos', style: TextStyle(fontSize: 16, fontWeight: FontWeight.w700)),
                  const SizedBox(height: 4),
                  Text(
                      'Gastos, ingresos y transferencias que se repiten. Los que se apuntan solos lo hacen al abrir la app; en cuentas conectadas al banco no, porque llega el apunte real.',
                      style: TextStyle(fontSize: 12, color: Theme.of(context).hintColor)),
                  const SizedBox(height: 12),
                  FilledButton.tonalIcon(
                    onPressed: () => _open(context, RecurringFormScreen(repository: repository)),
                    icon: const Icon(Icons.repeat),
                    label: const Text('Añadir suscripción o recibo'),
                  ),
                  const SizedBox(height: 8),
                  OutlinedButton.icon(
                    onPressed: data.accounts.any((a) => !a.isArchived && a.type == AccountType.investment)
                        ? () => _open(context, RecurringFormScreen(repository: repository, investmentContribution: true))
                        : null,
                    icon: const Icon(Icons.trending_up),
                    label: const Text('Programar aportación mensual a inversión'),
                  ),
                ]),
              ),
            ),
            if (active.isEmpty && paused.isEmpty) const Padding(padding: EdgeInsets.all(16), child: Text('Aún no hay ninguno.')),
            if (active.isNotEmpty) ...[const SectionTitle('Activos'), Card(child: Column(children: [for (final r in active) tile(r)]))],
            if (paused.isNotEmpty) ...[const SectionTitle('Inactivos'), Card(child: Column(children: [for (final r in paused) tile(r)]))],
          ];
        },
      );
}

class RecurringFormScreen extends StatefulWidget {
  const RecurringFormScreen({super.key, required this.repository, this.editing, this.investmentContribution = false});
  final FinanceRepository repository;
  final RecurringMovement? editing;

  /// Starts as a monthly transfer to the first investment account (Swift «Programar aportación mensual a inversión»).
  final bool investmentContribution;
  @override
  State<RecurringFormScreen> createState() => _RecurringFormScreenState();
}

class _RecurringFormScreenState extends State<RecurringFormScreen> {
  late final RecurringMovement? e = widget.editing;
  late final _name = TextEditingController(text: e?.name ?? '');
  late final _amount = TextEditingController(text: e == null ? '' : amountText(e!.amountMinor));
  late final _description = TextEditingController(text: e?.descriptionText ?? '');
  late TransactionType _type = e?.type ?? (widget.investmentContribution ? TransactionType.transfer : TransactionType.expense);
  late Frequency _frequency = e?.frequency ?? Frequency.monthly;
  late DateTime _next = e?.nextDueDate ?? DateTime.now();
  late DateTime? _end = e?.endDate;
  late String? _source = e?.sourceAccountId;
  late String? _destination = e?.destinationAccountId ??
      (widget.investmentContribution
          ? widget.repository.finances!.accounts.where((a) => !a.isArchived && a.type == AccountType.investment).firstOrNull?.id
          : null);
  late String? _category = e?.categoryId;
  late bool _active = e?.isActive ?? true;
  late bool _subscription = e?.isSubscription ?? false;
  late bool _automatic = e?.postsAutomatically ?? true;
  String? _message;

  @override
  Widget build(BuildContext context) {
    final data = widget.repository.finances!;
    final accounts = data.accounts.where((a) => !a.isArchived).toList();
    final categories = data.categories.where((c) => categorySupports(c, _type)).toList();
    if (_category != null && !categories.any((c) => c.id == _category)) _category = null;
    return FormPage(
      title: e == null ? 'Nuevo periódico' : 'Editar periódico',
      message: _message,
      actions: [
        if (e != null)
          IconButton(
            tooltip: 'Borrar',
            icon: const Icon(Icons.delete_outline),
            onPressed: () async {
              if (!await confirm(context, 'Borrar periódico', 'Los movimientos ya apuntados se conservan.', action: 'Borrar')) return;
              await widget.repository.apply(removeOperation('recurringMovements', e!.id));
              if (context.mounted) Navigator.of(context).pop();
            },
          ),
      ],
      onSave: () async {
        final name = _name.text.trim();
        final amount = amountFrom(_amount);
        if (name.isEmpty) return setState(() => _message = 'Escribe un nombre.');
        if (amount == null || amount <= 0) return setState(() => _message = 'Escribe el importe.');
        if (_source == null) return setState(() => _message = 'Elige la cuenta.');
        if (_type == TransactionType.transfer && (_destination == null || _destination == _source)) {
          return setState(() => _message = 'Elige una cuenta de destino distinta.');
        }
        if (_end != null && _end!.isBefore(_next)) return setState(() => _message = 'La fecha final es anterior al próximo cargo.');
        final now = referenceSeconds(DateTime.now());
        final fields = {
          'name': name,
          'typeRaw': _type.name,
          'amountMinor': amount,
          'descriptionText': _description.text.trim().isEmpty ? name : _description.text.trim(),
          'frequencyRaw': _frequency.name,
          'interval': 1,
          'nextDueDate': referenceSeconds(_next),
          'endDate': _end == null ? null : referenceSeconds(_end!),
          'isActive': _active,
          'isSubscription': _subscription,
          'postsAutomatically': _automatic,
          'sourceAccountID': _source,
          'destinationAccountID': _type == TransactionType.transfer ? _destination : null,
          'categoryID': _type == TransactionType.transfer ? null : _category,
          'updatedAt': now,
        };
        await widget.repository.apply(e != null
            ? upsertOperation('recurringMovements', {'id': e!.id, ...fields}, create: false)
            : upsertOperation('recurringMovements', {'id': widget.repository.newId(), ...fields, 'notes': '', 'createdAt': now}, create: true));
        if (mounted) Navigator.of(this.context).pop();
      },
      children: [
        TextInput(controller: _name, label: 'Nombre (por ejemplo, Alquiler)'),
        Choice<TransactionType>(
            label: 'Tipo', value: _type, options: {for (final t in TransactionType.values) t: t.title}, onChanged: (v) => setState(() => _type = v)),
        AmountInput(controller: _amount, label: 'Importe (€)'),
        Choice<String?>(
            label: _type == TransactionType.transfer ? 'Desde' : 'Cuenta',
            value: _source,
            options: {null: 'Elige una', for (final a in accounts) a.id: a.name},
            onChanged: (v) => setState(() => _source = v)),
        if (_type == TransactionType.transfer)
          Choice<String?>(
              label: 'Hacia',
              value: _destination,
              options: {null: 'Elige una', for (final a in accounts.where((a) => a.id != _source)) a.id: a.name},
              onChanged: (v) => setState(() => _destination = v))
        else
          Choice<String?>(
              label: 'Categoría',
              value: _category,
              options: {null: 'Sin categoría', for (final c in categories) c.id: c.name},
              onChanged: (v) => setState(() => _category = v)),
        Choice<Frequency>(
            label: 'Se repite', value: _frequency, options: {for (final f in Frequency.values) f: f.title}, onChanged: (v) => setState(() => _frequency = v)),
        DateInput(label: 'Próximo', value: _next, onChanged: (v) => setState(() => _next = v ?? _next)),
        DateInput(label: 'Termina', value: _end, optional: true, onChanged: (v) => setState(() => _end = v)),
        TextInput(controller: _description, label: 'Concepto del movimiento'),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Apuntarlo solo cuando toque'),
            subtitle: const Text('Necesita categoría (o ser un traspaso)'),
            value: _automatic,
            onChanged: (v) => setState(() => _automatic = v)),
        SwitchListTile(
            contentPadding: EdgeInsets.zero,
            title: const Text('Es una suscripción'),
            value: _subscription,
            onChanged: (v) => setState(() => _subscription = v)),
        SwitchListTile(contentPadding: EdgeInsets.zero, title: const Text('Activo'), value: _active, onChanged: (v) => setState(() => _active = v)),
      ],
    );
  }
}

// ---------------------------------------------------------------- institutions

class InstitutionsScreen extends StatelessWidget {
  const InstitutionsScreen({super.key, required this.repository});
  final FinanceRepository repository;

  @override
  Widget build(BuildContext context) => _Managed(
        repository: repository,
        title: 'Bancos y entidades',
        onAdd: () => _open(context, InstitutionFormScreen(repository: repository)),
        builder: (context, data) => [
          Text('Los bancos, brókeres y otras entidades que agrupan tus cuentas y tarjetas.', style: TextStyle(color: Theme.of(context).hintColor)),
          const SizedBox(height: 12),
          if (data.institutions.isEmpty) const Text('Aún no hay ninguna.'),
          Card(
            child: Column(children: [
              for (final i in data.institutions)
                () {
                  final accounts = data.accounts.where((a) => a.institutionId == i.id).toList();
                  final cards = data.cards.where((c) => accounts.any((a) => a.id == c.linkedAccountId)).length;
                  return ListTile(
                    leading: RowGlyph(icon: Icons.account_balance, tint: colorFromHex(i.colorHex)),
                    title: Text(i.name, style: const TextStyle(fontWeight: FontWeight.w600)),
                    subtitle: Text('${accounts.length == 1 ? '1 cuenta' : '${accounts.length} cuentas'}'
                        '${cards > 0 ? ' · ${cards == 1 ? '1 tarjeta' : '$cards tarjetas'}' : ''}'),
                    trailing: const Icon(Icons.chevron_right),
                    onTap: () => _open(context, InstitutionFormScreen(repository: repository, editing: i)),
                  );
                }(),
            ]),
          ),
        ],
      );
}

/// A bank or other entity, as on the iPhone: its name and colour with a preview, and its accounts and cards.
class InstitutionFormScreen extends StatefulWidget {
  const InstitutionFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final Institution? editing;
  @override
  State<InstitutionFormScreen> createState() => _InstitutionFormScreenState();
}

class _InstitutionFormScreenState extends State<InstitutionFormScreen> {
  late final _name = TextEditingController(text: widget.editing?.name ?? '');
  late String _color = widget.editing?.colorHex ?? '#1F6B7A';
  String? _message;

  @override
  Widget build(BuildContext context) {
    final editing = widget.editing;
    final data = widget.repository.finances!;
    final accounts = editing == null ? const <Account>[] : data.accounts.where((a) => a.institutionId == editing.id).toList();
    final cards = data.cards.where((c) => accounts.any((a) => a.id == c.linkedAccountId)).toList();
    final hint = Theme.of(context).hintColor;
    return FormPage(
      title: editing == null ? 'Nueva entidad' : 'Editar entidad',
      message: _message,
      onSave: () async {
        final name = _name.text.trim();
        if (name.isEmpty) return setState(() => _message = 'Escribe el nombre.');
        final now = referenceSeconds(DateTime.now());
        await widget.repository.apply(editing != null
            ? upsertOperation('institutions', {'id': editing.id, 'name': name, 'colorHex': _color, 'updatedAt': now}, create: false)
            : upsertOperation(
                'institutions', {'id': widget.repository.newId(), 'name': name, 'colorHex': _color, 'notes': '', 'createdAt': now, 'updatedAt': now},
                create: true));
        if (mounted) Navigator.of(this.context).pop();
      },
      children: [
        TextInput(controller: _name, label: 'Nombre'),
        Text('Color de la entidad', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        ColorInput(value: _color, onChanged: (v) => setState(() => _color = v)),
        const SizedBox(height: 16),
        Text('Vista previa', style: Theme.of(context).textTheme.titleSmall),
        const SizedBox(height: 8),
        Card(
          child: ListTile(
            leading: RowGlyph(icon: Icons.account_balance, tint: colorFromHex(_color)),
            title: Text(_name.text.trim().isEmpty ? 'Nombre de la entidad' : _name.text.trim()),
          ),
        ),
        if (editing != null) ...[
          const SectionTitle('Cuentas asociadas'),
          Card(
            child: accounts.isEmpty
                ? Padding(padding: const EdgeInsets.all(16), child: Text('Todavía no hay cuentas asociadas a esta entidad.', style: TextStyle(color: hint)))
                : Column(children: [
                    for (final a in accounts)
                      ListTile(
                        leading: Icon(Icons.account_balance_wallet_outlined, color: colorFromHex(_color)),
                        title: Text(a.name),
                        subtitle: Text(a.type.title),
                        trailing: Text(money(FinanceCalculator(data).balance(a), currency: a.currencyCode), style: const TextStyle(fontWeight: FontWeight.w600)),
                      ),
                  ]),
          ),
          const SectionTitle('Tarjetas'),
          Card(
            child: cards.isEmpty
                ? Padding(padding: const EdgeInsets.all(16), child: Text('Todavía no hay tarjetas asociadas a esta entidad.', style: TextStyle(color: hint)))
                : Column(children: [
                    for (final c in cards)
                      ListTile(
                        leading: Icon(Icons.credit_card, color: colorFromHex(_color)),
                        title: Text(c.name),
                        subtitle: Text([c.type.title, if (c.lastFour.isNotEmpty) '•••• ${c.lastFour}'].join(' · ')),
                      ),
                  ]),
          ),
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: Text('Las tarjetas son medios de pago. Su saldo pertenece a la cuenta vinculada.', style: TextStyle(fontSize: 12, color: hint)),
          ),
        ],
      ],
    );
  }
}

/// Posts the periodic movements due now (used when the app opens and from Ajustes).
Future<int> postDue(FinanceRepository repository) async {
  final data = repository.finances;
  if (data == null) return 0;
  final op = postDueMovements(data, DateTime.now());
  if (op == null) return 0;
  final inserted = (op.data['ops'] as List).where((o) => (o as Map)['kind'] == 'insert').length;
  await repository.apply(op);
  return inserted;
}
