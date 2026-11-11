import 'dart:convert';
import 'dart:typed_data';

import 'package:file_picker/file_picker.dart';
import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../csv_import.dart';
import '../data.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';
import 'forms.dart';

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

  Future<void> _pick() async {
    final files = await FilePicker.pickFiles(type: FileType.custom, allowedExtensions: ['csv', 'txt']);
    if (files.isEmpty) return;
    try {
      final result = parseCsv(decodeCsv(await files.first.readAsBytes()));
      setState(() {
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
    final plan = parsed == null || accountId == null ? <CsvPlanItem>[] : planCsv(parsed!, data, accountId!);
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
            onChanged: (v) => setState(() => accountId = v),
          ),
          const SizedBox(height: 12),
          Text('${count('new')} nuevos · ${count('possible')} posibles duplicados · ${count('duplicate')} ya estaban · ${count('invalid')} no válidos',
              style: const TextStyle(fontWeight: FontWeight.w600)),
          const SizedBox(height: 8),
          Card(
            child: Column(children: [
              for (final item in plan.take(50))
                ListTile(
                  dense: true,
                  title: Text(item.draft.description, maxLines: 1, overflow: TextOverflow.ellipsis),
                  subtitle: Text('${format.format(item.draft.date)} · ${switch (item.status) {
                    'new' => 'Nuevo',
                    'possible' => 'Posible duplicado: se marcará para revisar',
                    'duplicate' => 'Ya estaba: no se importa',
                    _ => 'Traspaso sin cuenta de destino: no se importa',
                  }}'),
                  trailing: Text(money(item.draft.signedAmountMinor, signed: true)),
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
                    await widget.repository.apply(importCsvOperation(plan, DateTime.now(), widget.repository.newId));
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
