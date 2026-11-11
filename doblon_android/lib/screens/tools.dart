import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../csv_import.dart';
import '../data.dart';
import '../edits.dart' show categorySupports;
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'forms.dart';
import 'learning.dart' show proposeCategory;

/// Importar movimientos CSV: pick a file, check every row, then import what is new.
class CsvImportScreen extends StatefulWidget {
  const CsvImportScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  State<CsvImportScreen> createState() => _CsvImportScreenState();
}

class _CsvImportScreenState extends State<CsvImportScreen> {
  CsvResult? parsed;
  String? accountId;
  String? message;
  bool error = false;
  bool busy = false;

  /// Categories the person chose for some rows (row index → category): they also teach the models.
  final corrections = <int, String>{};

  /// Swift «Elegir categoría» of a CSV row, with the AI proposal.
  Future<void> _chooseCategory(int index, CsvPlanItem item, Finances data) async {
    final options = data.categories.where((c) => categorySupports(c, item.draft.type)).toList();
    final proposal = proposeCategory(widget.repository, item.draft.description, item.draft.type);
    final chosen = await showModalBottomSheet<Category>(
      context: context,
      showDragHandle: true,
      isScrollControlled: true,
      builder: (context) => SizedBox(
        height: MediaQuery.of(context).size.height * 0.7,
        child: ListView(children: [
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
            child: Text(item.draft.description, style: const TextStyle(fontWeight: FontWeight.w700)),
          ),
          FutureBuilder<Category?>(
            future: proposal,
            builder: (context, snapshot) => snapshot.data == null
                ? const SizedBox.shrink()
                : ListTile(
                    leading: const Icon(Icons.auto_awesome),
                    title: Text('Usar propuesta de IA: ${snapshot.data!.name}'),
                    onTap: () => Navigator.pop(context, snapshot.data),
                  ),
          ),
          if (options.isEmpty) const ListTile(title: Text('No hay categorías compatibles. Puedes crearlas en Ajustes → Categorías.')),
          for (final c in options)
            ListTile(
              leading: CircleAvatar(radius: 8, backgroundColor: colorFromHex(c.colorHex)),
              title: Text(c.name),
              onTap: () => Navigator.pop(context, c),
            ),
        ]),
      ),
    );
    if (chosen != null) setState(() => corrections[index] = chosen.id);
  }

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'txt']);
    if (files.isEmpty) return;
    try {
      final result = parseCsv(decodeCsv(await files.first.readAsBytes()));
      setState(() {
        corrections.clear();
        parsed = result;
        message = result.warnings.isEmpty ? null : result.warnings.take(5).join('\n');
        error = false;
      });
    } on CsvError catch (e) {
      setState(() {
        parsed = null;
        message = e.message;
        error = true;
      });
    } catch (_) {
      setState(() {
        parsed = null;
        message = 'No se ha podido leer el archivo.';
        error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final data = widget.repository.finances!;
    final accounts = data.accounts.where((a) => !a.isArchived).toList();
    accountId ??= accounts.isEmpty ? null : accounts.first.id;
    final planned = parsed == null || accountId == null ? <CsvPlanItem>[] : planCsv(parsed!, data, accountId!);
    final plan = [
      for (var i = 0; i < planned.length; i++)
        corrections[i] == null ? planned[i] : CsvPlanItem(planned[i].draft, planned[i].accountId, planned[i].destinationId, corrections[i], planned[i].status)
    ];
    bool importable(CsvPlanItem item) => item.status == 'new' || item.status == 'possible';
    int count(String status) => plan.where((p) => p.status == status).length;
    final format = DateFormat('dd/MM/yyyy');
    return Scaffold(
      appBar: AppBar(title: const Text('Importar movimientos CSV', style: TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text(
            'Descarga el extracto de tu banco en CSV. Hacen falta columnas de fecha, importe y concepto; también se reconocen tipo, cuenta, categoría y notas.'),
        const SizedBox(height: 12),
        OutlinedButton.icon(
            onPressed: busy ? null : _pick, icon: const Icon(Icons.upload_file), label: Text(parsed == null ? 'Elegir archivo' : 'Elegir otro archivo')),
        if (message != null)
          Padding(padding: const EdgeInsets.only(top: 12), child: Text(message!, style: TextStyle(color: error ? pulso.expense : pulso.warning))),
        if (parsed != null && accounts.isNotEmpty) ...[
          const SizedBox(height: 12),
          Choice<String?>(
            label: 'Cuenta (si el archivo no la indica)',
            value: accountId,
            options: {for (final a in accounts) a.id: a.name},
            onChanged: (v) => setState(() {
              accountId = v;
              corrections.clear();
            }),
          ),
          const SizedBox(height: 12),
          Text('${count('new')} nuevos · ${count('possible')} posibles duplicados · ${count('duplicate')} ya estaban · ${count('invalid')} no válidos',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              for (final (index, item) in plan.take(50).indexed)
                ListTile(
                  dense: true,
                  title: Text(item.draft.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${format.format(item.draft.date)} · ${switch (item.status) {
                    'new' => 'Nuevo',
                    'possible' => 'Posible duplicado: se marcará para revisar',
                    'duplicate' => 'Ya estaba: no se importa',
                    _ => 'Traspaso sin cuenta de destino: no se importa',
                  }}${importable(item) && item.draft.type != TransactionType.transfer ? ' · ${data.category(item.categoryId)?.name ?? 'Sin categoría (toca para elegir)'}' : ''}'),
                  trailing: Text(money(item.draft.signedAmountMinor, signed: true)),
                  onTap: importable(item) && item.draft.type != TransactionType.transfer && !busy ? () => _chooseCategory(index, item, data) : null,
                ),
              if (plan.length > 50) Padding(padding: const EdgeInsets.all(12), child: Text('… y ${plan.length - 50} filas más')),
            ]),
          ),
          const SizedBox(height: 12),
          FilledButton(
            onPressed: busy || count('new') + count('possible') == 0
                ? null
                : () async {
                    setState(() => busy = true);
                    // The ids are given in the order of the importable rows, to find the corrected ones afterwards.
                    final ids = <String>[];
                    await widget.repository.apply(importCsvOperation(plan, DateTime.now(), () {
                      final id = widget.repository.newId();
                      ids.add(id);
                      return id;
                    }));
                    final rows = [for (final item in plan) if (importable(item)) item];
                    final corrected = {
                      for (var i = 0; i < rows.length && i < ids.length; i++)
                        if (corrections[plan.indexOf(rows[i])] != null) ids[i]
                    };
                    final learning = widget.repository.learning, latest = widget.repository.finances;
                    if (learning != null && latest != null && corrected.isNotEmpty) {
                      await learning.confirmCategories(latest.transactions.where((t) => corrected.contains(t.id)).toList(), latest);
                    }
                    if (!context.mounted) return;
                    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text('${count('new') + count('possible')} movimientos importados.')));
                    Navigator.of(context).pop();
                  },
            style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52)),
            child: Text('Importar ${count('new') + count('possible')} movimientos'),
          ),
        ],
      ]),
    );
  }
}

/// Copia de seguridad: the whole cloud document as a JSON file (the same format the iPhone syncs), and the
/// movements as CSV.
class BackupScreen extends StatefulWidget {
  const BackupScreen({super.key, required this.repository});
  final FinanceRepository repository;
  @override
  State<BackupScreen> createState() => _BackupScreenState();
}

class _BackupScreenState extends State<BackupScreen> {
  String? message;
  bool busy = false;

  String get _stamp => DateFormat('yyyy-MM-dd').format(DateTime.now());

  Future<void> _save(String name, String text, String mime) async {
    final uri = await FilePicker.saveFile(fileName: name, bytes: Uint8List.fromList(utf8.encode(text)), mimeType: mime);
    setState(() => message = uri == null ? null : 'Guardado: $name');
  }

  Future<void> _restore() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['json']);
    if (files.isEmpty || !mounted) return;
    Map<String, dynamic> document;
    try {
      document = Map<String, dynamic>.from(jsonDecode(utf8.decode(await files.first.readAsBytes())) as Map);
      if ('${document['formatVersion']}' != '2' || document['transactions'] is! List || document['accounts'] is! List) throw const FormatException();
      Finances.fromDocument(document);
    } catch (_) {
      setState(() => message = 'Ese archivo no es una copia de Doblón válida.');
      return;
    }
    if (!mounted) return;
    final accounts = (document['accounts'] as List).length, movements = (document['transactions'] as List).length;
    if (!await confirm(context, 'Restaurar copia',
        'Tus datos actuales se sustituirán en todos tus dispositivos por los de la copia ($accounts cuentas y $movements movimientos). Antes guarda una copia de lo actual si la necesitas.',
        action: 'Restaurar')) {
      return;
    }
    setState(() => busy = true);
    try {
      await widget.repository.update((_) => (document, null));
      setState(() => message = 'Copia restaurada.');
    } catch (_) {
      setState(() => message = 'No se ha podido restaurar. Comprueba la conexión.');
    } finally {
      setState(() => busy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final repository = widget.repository;
    return Scaffold(
      appBar: AppBar(title: const Text('Copia de seguridad', style: TextStyle(fontWeight: FontWeight.w700))),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        const Text('Tus datos ya están en tu nube. Aquí puedes guardar además una copia en un archivo, o exportar tus movimientos para una hoja de cálculo.'),
        const SizedBox(height: 16),
        Card(
          child: Column(children: [
            ListTile(
              leading: const Icon(Icons.save_alt),
              title: const Text('Guardar copia completa'),
              subtitle: const Text('Archivo JSON con cuentas, movimientos, presupuestos y lo demás'),
              enabled: !busy && repository.document != null,
              onTap: () => _save('doblon-copia-$_stamp.json', const JsonEncoder.withIndent(' ').convert(repository.document), 'application/json'),
            ),
            ListTile(
              leading: const Icon(Icons.table_view),
              title: const Text('Exportar movimientos (CSV)'),
              enabled: !busy && repository.finances != null,
              onTap: () => _save('doblon-movimientos-$_stamp.csv', exportCsv(repository.finances!.transactions, repository.finances!), 'text/csv'),
            ),
            ListTile(
              leading: const Icon(Icons.restore),
              title: const Text('Restaurar una copia'),
              subtitle: const Text('Sustituye tus datos actuales'),
              enabled: !busy,
              onTap: _restore,
            ),
          ]),
        ),
        if (message != null) Padding(padding: const EdgeInsets.only(top: 12), child: Text(message!)),
      ]),
    );
  }
}
