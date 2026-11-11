import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../automation.dart';
import '../banking.dart' show referenceSeconds;
import '../data.dart';
import '../edits.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'forms.dart';

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
                leading: CircleAvatar(radius: 10, backgroundColor: colorFromHex(c.colorHex)),
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
        final fields = {'name': name, 'kindRaw': _kind.name, 'colorHex': _color, 'updatedAt': now};
        await widget.repository.apply(editing != null
            ? upsertOperation('categories', {'id': editing.id, ...fields}, create: false)
            : upsertOperation(
                'categories',
                {
                  'id': widget.repository.newId(),
                  ...fields,
                  'systemImage': 'tag',
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
          Widget tile(RecurringMovement r) => ListTile(
                leading: Icon(r.isSubscription ? Icons.subscriptions_outlined : Icons.repeat),
                title: Text(r.name),
                subtitle: Text('${r.frequency.title} · próximo ${format.format(r.nextDueDate)}${r.postsAutomatically == true ? ' · se apunta solo' : ''}'),
                trailing: Text(money(r.type.countsAsIncome ? r.amountMinor : -r.amountMinor, signed: true)),
                onTap: () => _open(context, RecurringFormScreen(repository: repository, editing: r)),
              );
          return [
            const Text(
                'Suscripciones, recibos, nóminas y traspasos que se repiten. Los que se apuntan solos lo hacen al abrir la app; en cuentas conectadas al banco no, porque llega el apunte real.'),
            const SizedBox(height: 12),
            if (active.isEmpty) const Text('Aún no hay ninguno.'),
            Card(child: Column(children: [for (final r in active) tile(r)])),
            if (paused.isNotEmpty) ExpansionTile(title: Text('En pausa (${paused.length})'), children: [for (final r in paused) tile(r)]),
          ];
        },
      );
}

class RecurringFormScreen extends StatefulWidget {
  const RecurringFormScreen({super.key, required this.repository, this.editing});
  final FinanceRepository repository;
  final RecurringMovement? editing;
  @override
  State<RecurringFormScreen> createState() => _RecurringFormScreenState();
}

class _RecurringFormScreenState extends State<RecurringFormScreen> {
  late final RecurringMovement? e = widget.editing;
  late final _name = TextEditingController(text: e?.name ?? '');
  late final _amount = TextEditingController(text: e == null ? '' : amountText(e!.amountMinor));
  late final _description = TextEditingController(text: e?.descriptionText ?? '');
  late TransactionType _type = e?.type ?? TransactionType.expense;
  late Frequency _frequency = e?.frequency ?? Frequency.monthly;
  late DateTime _next = e?.nextDueDate ?? DateTime.now();
  late DateTime? _end = e?.endDate;
  late String? _source = e?.sourceAccountId;
  late String? _destination = e?.destinationAccountId;
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

  Future<void> _edit(BuildContext context, Institution? editing) async {
    final controller = TextEditingController(text: editing?.name ?? '');
    final name = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(editing == null ? 'Nueva entidad' : 'Renombrar entidad'),
        content: TextField(
            controller: controller, autofocus: true, textCapitalization: TextCapitalization.words, decoration: const InputDecoration(labelText: 'Nombre')),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, controller.text.trim()), child: const Text('Guardar')),
        ],
      ),
    );
    if (name == null || name.isEmpty) return;
    final now = referenceSeconds(DateTime.now());
    await repository.apply(editing != null
        ? upsertOperation('institutions', {'id': editing.id, 'name': name, 'updatedAt': now}, create: false)
        : upsertOperation('institutions', {'id': repository.newId(), 'name': name, 'colorHex': '#1F6B7A', 'notes': '', 'createdAt': now, 'updatedAt': now},
            create: true));
  }

  @override
  Widget build(BuildContext context) => _Managed(
        repository: repository,
        title: 'Bancos y entidades',
        onAdd: () => _edit(context, null),
        builder: (context, data) => [
          const Text('Los nombres que agrupan tus cuentas y tarjetas.'),
          const SizedBox(height: 12),
          Card(
            child: Column(children: [
              for (final i in data.institutions)
                ListTile(
                  leading: Icon(Icons.account_balance, color: Pulso.of(context).accent),
                  title: Text(i.name),
                  subtitle: Text('${data.accounts.where((a) => a.institutionId == i.id).length} cuentas'),
                  onTap: () => _edit(context, i),
                ),
            ]),
          ),
        ],
      );
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
