import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:intl/intl.dart';

import '../theme.dart';
import 'transaction_form.dart' show parseAmount;

/// Small building blocks shared by every form, so all of them look and behave the same.
class FormPage extends StatelessWidget {
  const FormPage({super.key, required this.title, required this.children, required this.onSave, this.saveLabel = 'Guardar', this.message, this.actions});
  final String title;
  final List<Widget> children;
  final VoidCallback? onSave;
  final String saveLabel;
  final String? message;
  final List<Widget>? actions;

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: Text(title, style: const TextStyle(fontWeight: FontWeight.w700)), actions: actions),
      body: ListView(padding: const EdgeInsets.all(16), children: [
        for (final child in children) Padding(padding: const EdgeInsets.only(bottom: 12), child: child),
        if (message != null) Padding(padding: const EdgeInsets.only(bottom: 12), child: Text(message!, style: TextStyle(color: Pulso.of(context).expense))),
        FilledButton(
          onPressed: onSave,
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(52), backgroundColor: const Color(0xFF0F766E)),
          child: Text(saveLabel),
        ),
        const SizedBox(height: 24),
      ]),
    );
  }
}

class TextInput extends StatelessWidget {
  const TextInput({super.key, required this.controller, required this.label, this.maxLines = 1, this.capitalize = true});
  final TextEditingController controller;
  final String label;
  final int maxLines;
  final bool capitalize;
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        maxLines: maxLines,
        minLines: 1,
        textCapitalization: capitalize ? TextCapitalization.sentences : TextCapitalization.none,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );
}

class AmountInput extends StatelessWidget {
  const AmountInput({super.key, required this.controller, required this.label, this.allowNegative = false});
  final TextEditingController controller;
  final String label;
  final bool allowNegative;
  @override
  Widget build(BuildContext context) => TextField(
        controller: controller,
        keyboardType: TextInputType.numberWithOptions(decimal: true, signed: allowNegative),
        inputFormatters: [FilteringTextInputFormatter.allow(RegExp(allowNegative ? r'[0-9.,\-]' : r'[0-9.,]'))],
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
      );
}

/// Cents from an amount field; negative when it starts with "-".
int? amountFrom(TextEditingController controller) {
  final text = controller.text.trim();
  final value = parseAmount(text.replaceFirst('-', ''));
  if (value == null) return null;
  return text.startsWith('-') ? -value : value;
}

String amountText(int minor) => '${minor < 0 ? '-' : ''}${(minor.abs() / 100).toStringAsFixed(2).replaceAll('.', ',')}';

class DateInput extends StatelessWidget {
  const DateInput({super.key, required this.label, required this.value, required this.onChanged, this.optional = false});
  final String label;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;
  final bool optional;
  @override
  Widget build(BuildContext context) => ListTile(
        contentPadding: EdgeInsets.zero,
        leading: const Icon(Icons.event),
        title: Text(label),
        subtitle: Text(value == null ? 'Sin fecha' : DateFormat("d 'de' MMMM yyyy", 'es').format(value!)),
        trailing: optional && value != null ? IconButton(icon: const Icon(Icons.clear), onPressed: () => onChanged(null)) : null,
        onTap: () async {
          final picked = await showDatePicker(context: context, initialDate: value ?? DateTime.now(), firstDate: DateTime(1990), lastDate: DateTime(2100));
          if (picked != null) onChanged(DateTime(picked.year, picked.month, picked.day, 12));
        },
      );
}

class Choice<T> extends StatelessWidget {
  const Choice({super.key, required this.label, required this.value, required this.options, required this.onChanged});
  final String label;
  final T value;
  final Map<T, String> options;
  final ValueChanged<T> onChanged;
  @override
  Widget build(BuildContext context) => DropdownButtonFormField<T>(
        initialValue: value,
        isExpanded: true,
        decoration: InputDecoration(labelText: label, border: const OutlineInputBorder()),
        items: [for (final e in options.entries) DropdownMenuItem<T>(value: e.key, child: Text(e.value, overflow: TextOverflow.ellipsis))],
        onChanged: (v) => onChanged(v as T),
      );
}

/// The colours offered for categories and goals (the «Pulso» palette and a few more).
const palette = ['#0F766E', '#1E7A4C', '#B3263E', '#2457A6', '#6B3FA0', '#8A5A00', '#4D7C8A', '#C2410C', '#BE185D', '#475569'];

class ColorInput extends StatelessWidget {
  const ColorInput({super.key, required this.value, required this.onChanged});
  final String value;
  final ValueChanged<String> onChanged;
  @override
  Widget build(BuildContext context) => Wrap(spacing: 10, runSpacing: 10, children: [
        for (final hex in palette)
          GestureDetector(
            onTap: () => onChanged(hex),
            child: CircleAvatar(
              radius: 16,
              backgroundColor: colorFromHex(hex),
              child: value.toUpperCase() == hex.toUpperCase() ? const Icon(Icons.check, color: Colors.white, size: 18) : null,
            ),
          ),
      ]);
}

Future<bool> confirm(BuildContext context, String title, String message, {String action = 'Confirmar'}) async =>
    await showDialog<bool>(
      context: context,
      builder: (context) => AlertDialog(
        title: Text(title),
        content: Text(message),
        actions: [
          TextButton(onPressed: () => Navigator.pop(context, false), child: const Text('Cancelar')),
          TextButton(onPressed: () => Navigator.pop(context, true), child: Text(action)),
        ],
      ),
    ) ==
    true;
