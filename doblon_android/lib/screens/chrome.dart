// The frame around the five tabs: a header that hides while scrolling down and comes back when scrolling up, and an
// action band above the tabs with Don Bigotes (what is pending) and «+ Añadir», as two separate buttons.
import 'package:flutter/material.dart';

import '../automation.dart' show CompanionNote;
import '../theme.dart';
import 'shell.dart' show DonBigotesMark;

/// «Buenos días», «Buenas tardes» or «Buenas noches», as on the iPhone.
String greeting(DateTime now) => now.hour >= 6 && now.hour < 12 ? 'Buenos días' : (now.hour >= 12 && now.hour < 21 ? 'Buenas tardes' : 'Buenas noches');

/// Height of the header row under the status bar.
const headerHeight = 52.0;

/// Room under the last item of every tab. The band and the tabs are already in the bottom padding.
const dockReserve = 20.0;

/// How far down the content of a tab starts: the status bar, the header and the error notice, when shown.
class TabInsets extends InheritedWidget {
  const TabInsets({super.key, required this.top, required super.child});
  final double top;

  /// Outside the tabs (tests, screens on their own) it is the status bar.
  static double topOf(BuildContext context) => context.dependOnInheritedWidgetOfExactType<TabInsets>()?.top ?? MediaQuery.paddingOf(context).top;

  @override
  bool updateShouldNotify(TabInsets old) => old.top != top;
}

/// Padding of the main list of a tab: below the header, and above the tab bar and the dock.
EdgeInsets tabListPadding(BuildContext context, {double horizontal = 16, double top = 8}) =>
    EdgeInsets.fromLTRB(horizontal, TabInsets.topOf(context) + top, horizontal, MediaQuery.paddingOf(context).bottom + dockReserve);

/// How much of the header is shown (1 shown, 0 hidden) after scrolling `delta` pixels, at `pixels` from the top.
/// At the top it is always shown, so the first item is never under a half-hidden header.
double nextHeaderShown(double shown, double delta, double pixels) {
  if (pixels <= 0) return 1;
  return (shown - delta / headerHeight).clamp(0.0, 1.0);
}

/// The header: the status bar strip stays, the row below slides under it. It is opaque, so nothing is seen through
/// while it moves, and the content starts below it (see [tabListPadding]).
class ShellHeader extends StatelessWidget {
  const ShellHeader({super.key, required this.shown, required this.title, required this.actions, this.scrolled = false});
  final Animation<double> shown;
  final Widget title;
  final List<Widget> actions;
  final bool scrolled;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final top = MediaQuery.paddingOf(context).top;
    return AnimatedBuilder(
      animation: shown,
      builder: (context, child) => SizedBox(
        height: top + headerHeight * shown.value,
        child: Stack(clipBehavior: Clip.hardEdge, children: [
          Positioned(
            left: 0,
            right: 0,
            top: top - headerHeight * (1 - shown.value),
            height: headerHeight,
            // Hidden from the screen reader and from taps once it is gone.
            child: IgnorePointer(ignoring: shown.value < 0.5, child: ExcludeSemantics(excluding: shown.value < 0.5, child: child!)),
          ),
          Positioned(left: 0, right: 0, top: 0, height: top, child: ColoredBox(color: pulso.page)),
        ]),
      ),
      child: DecoratedBox(
        decoration: BoxDecoration(
          color: pulso.page,
          border: Border(bottom: BorderSide(color: scrolled ? pulso.outline : Colors.transparent)),
        ),
        child: Padding(
          padding: const EdgeInsets.only(left: 20, right: 6),
          child: Row(children: [
            Expanded(child: DefaultTextStyle.merge(maxLines: 1, overflow: TextOverflow.ellipsis, child: title)),
            ...actions,
          ]),
        ),
      ),
    );
  }
}

/// The action band, fixed above the tabs and part of the bottom bar: Don Bigotes with what is pending on the left
/// and «+ Añadir» on the right, within reach of the thumb. Nothing floats over the content, so no amount, day or
/// control is ever under them; the lists only scroll behind the translucent bar, as behind the tabs.
class BottomDock extends StatelessWidget {
  const BottomDock({super.key, this.onAdd, required this.notes, this.onCompanion, this.companion = true});
  final VoidCallback? onAdd;
  final List<CompanionNote> notes;
  final VoidCallback? onCompanion;

  /// With Don Bigotes switched off, the pending list is still reachable, without his face.
  final bool companion;

  /// Height of the band, without the tabs.
  static const height = 64.0;

  @override
  Widget build(BuildContext context) {
    // The band keeps its size with very large text; the screen reader still reads the full labels.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: SizedBox(
        height: height,
        child: Padding(
          padding: const EdgeInsets.fromLTRB(12, 8, 12, 4),
          child: Row(children: [
            Expanded(child: Align(alignment: Alignment.centerLeft, child: _PendingPill(notes: notes, companion: companion, onTap: onCompanion))),
            const SizedBox(width: 8),
            if (onAdd != null)
              Semantics(
                button: true,
                label: 'Añadir movimiento',
                excludeSemantics: true,
                child: FilledButton.icon(
                  onPressed: onAdd,
                  style:
                      FilledButton.styleFrom(minimumSize: const Size(0, 46), padding: const EdgeInsets.symmetric(horizontal: 20), shape: const StadiumBorder()),
                  icon: const Icon(Icons.add),
                  label: const Text('Añadir', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}

/// Don Bigotes and what is pending, in one compact button: «Todo en orden» or the number of notices and the first.
class _PendingPill extends StatelessWidget {
  const _PendingPill({required this.notes, required this.companion, this.onTap});
  final List<CompanionNote> notes;
  final bool companion;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final hint = Theme.of(context).hintColor;
    final awake = notes.isNotEmpty;
    final urgent = notes.any((n) => n.urgent);
    final count = notes.length == 1 ? '1 aviso' : '${notes.length} avisos';
    return Semantics(
      button: true,
      label: awake ? '$count pendientes: ${notes.first.title}${urgent ? '. Urgente' : ''}' : 'Don Bigotes: todo en orden',
      excludeSemantics: true,
      child: Material(
        color: urgent ? pulso.warning.withValues(alpha: 0.16) : pulso.tertiary,
        shape: const StadiumBorder(),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.fromLTRB(4, 4, 14, 4),
            child: Row(mainAxisSize: MainAxisSize.min, children: [
              if (companion)
                CompanionButton(notes: notes, onTap: onTap ?? () {}, size: 38)
              else
                Padding(padding: const EdgeInsets.all(8), child: Icon(awake ? Icons.inbox_outlined : Icons.check_circle_outline, size: 22, color: hint)),
              const SizedBox(width: 8),
              Flexible(
                child: Column(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.start, children: [
                  Text(awake ? (urgent ? '$count · urgente' : count) : 'Todo en orden',
                      maxLines: 1, overflow: TextOverflow.ellipsis, style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700)),
                  if (awake) Text(notes.first.title, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 11, color: hint)),
                ]),
              ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Don Bigotes, as on the iPhone: awake with a small badge counting his notes, asleep (faded and tilted) when
/// everything is in order.
class CompanionButton extends StatelessWidget {
  const CompanionButton({super.key, required this.notes, required this.onTap, this.size = 56});
  final List<CompanionNote> notes;
  final VoidCallback onTap;
  final double size;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final awake = notes.isNotEmpty;
    return Semantics(
      button: true,
      label: awake ? 'Don Bigotes: ${notes.length == 1 ? 'tiene un aviso' : 'tiene ${notes.length} avisos'}' : 'Don Bigotes, sin novedades',
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: size,
          height: size,
          child: Stack(clipBehavior: Clip.none, children: [
            Opacity(
              opacity: awake ? 1 : 0.7,
              child: Transform.rotate(
                angle: awake ? 0 : -0.21,
                child: Container(
                  width: size,
                  height: size,
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: pulso.card, shape: BoxShape.circle, border: Border.all(color: pulso.outline)),
                  child: DonBigotesMark(awake: awake, size: size * (awake ? 0.72 : 0.62)),
                ),
              ),
            ),
            if (awake)
              Positioned(
                right: -4,
                top: -4,
                child: Container(
                  constraints: const BoxConstraints(minWidth: 18, minHeight: 18),
                  padding: const EdgeInsets.symmetric(horizontal: 4),
                  alignment: Alignment.center,
                  decoration: BoxDecoration(color: pulso.warning, borderRadius: BorderRadius.circular(9), border: Border.all(color: pulso.page, width: 2)),
                  child: Text('${notes.length}', style: const TextStyle(fontSize: 10, fontWeight: FontWeight.w800, color: Colors.black)),
                ),
              ),
          ]),
        ),
      ),
    );
  }
}
