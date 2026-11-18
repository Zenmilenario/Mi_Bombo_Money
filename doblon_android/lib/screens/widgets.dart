import 'package:flutter/material.dart';
import 'package:intl/intl.dart' hide TextDirection;

import '../edits.dart';
import '../finance.dart';
import '../models.dart';
import '../presentation.dart';
import '../theme.dart';

/// Previous / next month, as on the iPhone.
class MonthSelector extends StatelessWidget {
  const MonthSelector({super.key, required this.month, required this.onMonth});
  final DateTime month;
  final ValueChanged<DateTime> onMonth;

  @override
  Widget build(BuildContext context) {
    final now = DateTime.now();
    final isCurrent = month.year == now.year && month.month == now.month;
    final label = DateFormat('MMMM yyyy', 'es').format(month);
    return Row(children: [
      IconButton(onPressed: () => onMonth(DateTime(month.year, month.month - 1)), icon: const Icon(Icons.chevron_left)),
      Expanded(
        child: Text('${label[0].toUpperCase()}${label.substring(1)}',
            textAlign: TextAlign.center, style: Theme.of(context).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.w700)),
      ),
      IconButton(onPressed: isCurrent ? null : () => onMonth(DateTime(month.year, month.month + 1)), icon: const Icon(Icons.chevron_right)),
    ]);
  }
}

class SectionTitle extends StatelessWidget {
  const SectionTitle(this.text, {super.key});
  final String text;
  @override
  Widget build(BuildContext context) => Padding(
        padding: const EdgeInsets.fromLTRB(4, 20, 4, 8),
        child: Text(text, style: Theme.of(context).textTheme.titleSmall?.copyWith(fontWeight: FontWeight.w700)),
      );
}

class MetricTile extends StatelessWidget {
  const MetricTile({super.key, required this.label, required this.value, required this.color, this.icon});
  final String label;
  final String value;
  final Color color;
  final IconData? icon;

  @override
  Widget build(BuildContext context) => Card(
        child: Padding(
          padding: const EdgeInsets.all(14),
          child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
            Row(children: [
              if (icon != null) ...[Icon(icon, size: 16, color: color), const SizedBox(width: 6)],
              Expanded(child: Text(label, style: Theme.of(context).textTheme.labelMedium, overflow: TextOverflow.ellipsis)),
            ]),
            const SizedBox(height: 6),
            FittedBox(
              fit: BoxFit.scaleDown,
              alignment: Alignment.centerLeft,
              child: Text(value, style: TextStyle(fontSize: 18, fontWeight: FontWeight.w700, color: color)),
            ),
          ]),
        ),
      );
}

/// One movement in a list: title, account and category, signed amount.
class TransactionTile extends StatelessWidget {
  const TransactionTile({super.key, required this.transaction, required this.data});
  final Transaction transaction;
  final Finances data;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final t = transaction;
    final category = data.category(t.categoryId);
    final source = data.account(t.sourceAccountId);
    final destination = data.account(t.destinationAccountId);
    final signed = switch (t.type) {
      TransactionType.income || TransactionType.interest => t.amountMinor,
      TransactionType.expense || TransactionType.fee => -t.amountMinor,
      TransactionType.transfer => 0,
    };
    final color = signed > 0 ? pulso.income : (signed < 0 ? pulso.expense : pulso.savings);
    // A movement is in the currency of the account it comes from.
    final currency = source?.currencyCode ?? 'EUR';
    final accountText = t.type == TransactionType.transfer ? '${source?.name ?? 'Cuenta'} → ${destination?.name ?? 'Cuenta'}' : (source?.name ?? 'Cuenta');
    return ListTile(
      contentPadding: const EdgeInsets.symmetric(horizontal: 12),
      // The category's own icon, as on the iPhone; without category, the direction of the money.
      leading: RowGlyph(
        icon: category != null
            ? symbolIcon(category.systemImage)
            : (t.type == TransactionType.transfer ? Icons.swap_horiz : (signed > 0 ? Icons.south_west : Icons.north_east)),
        tint: category == null ? color : colorFromHex(category.colorHex),
      ),
      title: Text(listTitle(t.descriptionText, isBanking: t.isBanking),
          maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontWeight: FontWeight.w600)),
      subtitle: Builder(builder: (context) {
        // Only what is pending is flagged; «Sin categoría» already shows on the right, without a warning colour.
        final issues = pendingIssues(t, category);
        if (issues.isEmpty) return Text(accountText, maxLines: 1, overflow: TextOverflow.ellipsis);
        return Text('$accountText · ${issues.first.title}', maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(color: pulso.warning));
      }),
      trailing: Column(mainAxisAlignment: MainAxisAlignment.center, crossAxisAlignment: CrossAxisAlignment.end, children: [
        Text(t.type == TransactionType.transfer ? money(t.amountMinor, currency: currency) : money(signed, signed: true, currency: currency),
            style: TextStyle(fontWeight: FontWeight.w700, color: color)),
        Text(
          t.awaitsBank ? 'Pendiente del banco' : (t.type == TransactionType.transfer ? 'Transferencia' : (category?.name ?? 'Sin categoría')),
          style: TextStyle(fontSize: 11, color: t.awaitsBank ? pulso.warning : Theme.of(context).hintColor),
        ),
      ]),
    );
  }
}

/// An icon on a soft square of its colour (Swift `RowGlyph`).
class RowGlyph extends StatelessWidget {
  const RowGlyph({super.key, required this.icon, required this.tint});
  final IconData icon;
  final Color tint;

  @override
  Widget build(BuildContext context) => Container(
        width: 36,
        height: 36,
        decoration: BoxDecoration(color: tint.withValues(alpha: 0.14), borderRadius: BorderRadius.circular(Pulso.compactRadius)),
        child: Icon(icon, size: 19, color: tint),
      );
}

class BudgetBar extends StatelessWidget {
  const BudgetBar({super.key, required this.item});
  final BudgetProgress item;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final color = item.spentMinor > item.limitMinor ? pulso.expense : (item.fraction >= 0.85 ? pulso.warning : pulso.income);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 8),
      child: Column(crossAxisAlignment: CrossAxisAlignment.start, children: [
        Row(children: [
          Expanded(child: Text(item.category.name, style: const TextStyle(fontWeight: FontWeight.w600))),
          Text(item.limitMinor > 0 ? '${money(item.spentMinor)} de ${money(item.limitMinor)}' : money(item.spentMinor),
              style: Theme.of(context).textTheme.bodySmall),
        ]),
        const SizedBox(height: 6),
        ClipRRect(
          borderRadius: BorderRadius.circular(6),
          child: LinearProgressIndicator(
            value: item.limitMinor > 0 ? item.fraction.clamp(0, 1).toDouble() : 0,
            minHeight: 8,
            color: color,
            backgroundColor: pulso.tertiary,
          ),
        ),
        const SizedBox(height: 4),
        Text(
          item.limitMinor <= 0
              ? 'Sin presupuesto'
              : item.availableMinor >= 0
                  ? 'Quedan ${money(item.availableMinor)}${item.carriedInMinor > 0 ? ' · incluye ${money(item.carriedInMinor)} del mes anterior' : ''}'
                  : 'Superado en ${money(-item.availableMinor)}',
          style: TextStyle(fontSize: 12, color: color),
        ),
      ]),
    );
  }
}

/// Coins falling into a drum («bombo»), drawn as on the iPhone's sign-in screen (Swift `BomboIllustration`).
class BomboIllustration extends StatelessWidget {
  const BomboIllustration({super.key, this.height = 240});
  final double height;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    return Semantics(
      label: 'Ilustración: monedas que caen dentro de un bombo',
      child: CustomPaint(size: Size(double.infinity, height), painter: _BomboPainter(pulso.accent, pulso.warning, pulso.page)),
    );
  }
}

class _BomboPainter extends CustomPainter {
  _BomboPainter(this.accent, this.coin, this.page);
  final Color accent, coin, page;

  @override
  void paint(Canvas canvas, Size size) {
    final s = [size.width / 324, size.height / 290].reduce((a, b) => a < b ? a : b);
    final dx = (size.width - 324 * s) / 2 - 70 * s, dy = (size.height - 290 * s) / 2;
    Rect rect(double x, double y, double w, double h) => Rect.fromLTWH(dx + x * s, dy + y * s, w * s, h * s);
    Offset point(double x, double y) => Offset(dx + x * s, dy + y * s);
    Paint stroke(Color color, double width) => Paint()
      ..color = color
      ..style = PaintingStyle.stroke
      ..strokeWidth = width * s
      ..strokeCap = StrokeCap.round;
    canvas.drawOval(rect(104, 32, 256, 256), Paint()..color = accent.withValues(alpha: 0.07));
    canvas.drawOval(rect(140, 68, 184, 184), Paint()..color = accent.withValues(alpha: 0.07));
    canvas.drawOval(rect(136, 214, 192, 44), stroke(accent, 3));
    canvas.drawLine(point(136, 168), point(136, 236), stroke(accent, 3));
    canvas.drawLine(point(328, 168), point(328, 236), stroke(accent, 3));
    for (final (x1, x2) in const [(150.0, 182.0), (216.0, 248.0), (282.0, 314.0)]) {
      canvas.drawLine(point(x1, 178), point(x2, 228), stroke(accent.withValues(alpha: 0.45), 2));
      canvas.drawLine(point(x2, 178), point(x1, 228), stroke(accent.withValues(alpha: 0.45), 2));
    }
    canvas.drawOval(rect(136, 146, 192, 44), Paint()..color = page);
    canvas.drawOval(rect(136, 146, 192, 44), stroke(accent, 3));
    canvas.drawOval(rect(160, 154, 144, 28), stroke(accent.withValues(alpha: 0.5), 1.5));
    for (final (x, y, r) in const [(216.0, 118.0, 17.0), (198.0, 40.0, 12.0)]) {
      canvas.drawOval(rect(x - r, y - r, r * 2, r * 2), Paint()..color = coin.withValues(alpha: 0.22));
      canvas.drawOval(rect(x - r, y - r, r * 2, r * 2), stroke(coin, 3));
    }
    canvas.drawOval(rect(261, 55, 14, 30), Paint()..color = coin.withValues(alpha: 0.22));
    canvas.drawOval(rect(261, 55, 14, 30), stroke(coin, 3));
    final euro =
        TextPainter(text: TextSpan(text: '€', style: TextStyle(color: coin, fontSize: 17 * s, fontWeight: FontWeight.w900)), textDirection: TextDirection.ltr)
          ..layout();
    euro.paint(canvas, point(216, 119) - Offset(euro.width / 2, euro.height / 2));
  }

  @override
  bool shouldRepaint(_BomboPainter old) => old.accent != accent || old.coin != coin || old.page != page;
}

/// A title that opens and closes the detail below it, read as a button with its state by the screen reader.
class Disclosure extends StatefulWidget {
  const Disclosure({super.key, required this.title, required this.child, this.initiallyOpen = false});
  final String title;
  final Widget child;
  final bool initiallyOpen;

  @override
  State<Disclosure> createState() => _DisclosureState();
}

class _DisclosureState extends State<Disclosure> {
  late bool open = widget.initiallyOpen;

  @override
  Widget build(BuildContext context) {
    final accent = Pulso.of(context).accent;
    return Column(crossAxisAlignment: CrossAxisAlignment.stretch, children: [
      Semantics(
        button: true,
        expanded: open,
        excludeSemantics: true,
        label: widget.title,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: () => setState(() => open = !open),
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 44),
            child: Row(children: [
              Flexible(child: Text(widget.title, style: TextStyle(fontSize: 14, fontWeight: FontWeight.w600, color: accent))),
              AnimatedRotation(turns: open ? 0.5 : 0, duration: const Duration(milliseconds: 180), child: Icon(Icons.expand_more, color: accent)),
            ]),
          ),
        ),
      ),
      AnimatedSize(
        duration: const Duration(milliseconds: 200),
        alignment: Alignment.topCenter,
        child: open ? widget.child : const SizedBox(width: double.infinity),
      ),
    ]);
  }
}
