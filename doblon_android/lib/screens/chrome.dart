// The frame around the five tabs: a header that hides while scrolling down and comes back when scrolling up, and a
// dock at the bottom right, within reach of the thumb, with «+ Añadir» and Don Bigotes as two separate buttons.
import 'dart:async';

import 'package:flutter/material.dart';

import '../automation.dart' show CompanionNote;
import '../theme.dart';
import 'shell.dart' show DonBigotesMark;

/// «Buenos días», «Buenas tardes» or «Buenas noches», as on the iPhone.
String greeting(DateTime now) => now.hour >= 6 && now.hour < 12 ? 'Buenos días' : (now.hour >= 12 && now.hour < 21 ? 'Buenas tardes' : 'Buenas noches');

/// Height of the header row under the status bar.
const headerHeight = 52.0;

/// Room kept under the last item of every tab so it scrolls fully above the dock.
const dockReserve = 76.0;

/// How far down the content of a tab starts: the status bar, the header and the error notice, when shown.
class TabInsets extends InheritedWidget {
  const TabInsets({super.key, required this.top, required super.child});
  final double top;

  /// Outside the tabs (tests, screens on their own) it is the status bar.
  static double topOf(BuildContext context) =>
      context.dependOnInheritedWidgetOfExactType<TabInsets>()?.top ?? MediaQuery.paddingOf(context).top;

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

/// «+ Añadir» and Don Bigotes, side by side and separate. Don Bigotes is a face with the number of his notes; his
/// bubble only appears now and then, beside the buttons (never over the content), and can be closed.
class BottomDock extends StatelessWidget {
  const BottomDock({super.key, this.onAdd, required this.notes, this.onCompanion, this.teaser = false, this.onCloseTeaser});
  final VoidCallback? onAdd;
  final List<CompanionNote>? notes;
  final VoidCallback? onCompanion;
  final bool teaser;
  final VoidCallback? onCloseTeaser;

  @override
  Widget build(BuildContext context) {
    // The dock keeps its size with very large text: the labels are still read in full by the screen reader.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.3,
      child: LayoutBuilder(
        // On a narrow phone the bubble would squeeze the buttons: the badge is enough there.
        builder: (context, constraints) => Row(mainAxisSize: MainAxisSize.min, crossAxisAlignment: CrossAxisAlignment.center, children: [
          if (teaser && notes != null && notes!.isNotEmpty && constraints.maxWidth >= 330) ...[
            Flexible(child: _Teaser(notes: notes!, onTap: onCompanion, onClose: onCloseTeaser)),
            const SizedBox(width: 8),
          ],
          if (onAdd != null) ...[
            Semantics(
              button: true,
              label: 'Añadir movimiento',
              excludeSemantics: true,
              child: FilledButton.icon(
                onPressed: onAdd,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 52),
                  padding: const EdgeInsets.symmetric(horizontal: 20),
                  shape: const StadiumBorder(),
                  elevation: 2,
                  shadowColor: Colors.black45,
                  ),
                icon: const Icon(Icons.add),
                label: const Text('Añadir', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
              ),
            ),
            const SizedBox(width: 10),
          ],
          if (notes != null) CompanionButton(notes: notes!, onTap: onCompanion ?? () {}),
        ]),
      ),
    );
  }
}

class _Teaser extends StatelessWidget {
  const _Teaser({required this.notes, this.onTap, this.onClose});
  final List<CompanionNote> notes;
  final VoidCallback? onTap;
  final VoidCallback? onClose;

  @override
  Widget build(BuildContext context) {
    final scheme = Theme.of(context).colorScheme;
    final pulso = Pulso.of(context);
    final text = notes.length == 1 ? notes.first.title : 'Tengo ${notes.length} avisos';
    return Material(
      color: scheme.onSurface,
      elevation: 3,
      // The tail of the bubble points to Don Bigotes, as on the iPhone.
      shape: const RoundedRectangleBorder(
          borderRadius:
              BorderRadius.only(topLeft: Radius.circular(18), bottomLeft: Radius.circular(18), topRight: Radius.circular(18), bottomRight: Radius.circular(4))),
      child: InkWell(
        onTap: onTap,
        child: Padding(
          padding: const EdgeInsets.only(left: 12),
          child: Row(mainAxisSize: MainAxisSize.min, children: [
            Container(width: 8, height: 8, decoration: BoxDecoration(color: pulso.warning, shape: BoxShape.circle)),
            const SizedBox(width: 7),
            Flexible(
              child:
                  Text(text, maxLines: 1, overflow: TextOverflow.ellipsis, style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600, color: scheme.surface)),
            ),
            IconButton(
              tooltip: 'Cerrar el aviso',
              visualDensity: VisualDensity.compact,
              iconSize: 16,
              color: scheme.surface,
              onPressed: onClose,
              icon: const Icon(Icons.close),
            ),
          ]),
        ),
      ),
    );
  }
}

/// Don Bigotes, as on the iPhone: awake with a small badge counting his notes, asleep (faded and tilted) when
/// everything is in order.
class CompanionButton extends StatelessWidget {
  const CompanionButton({super.key, required this.notes, required this.onTap});
  final List<CompanionNote> notes;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final awake = notes.isNotEmpty;
    return Semantics(
      button: true,
      label: awake ? 'Don Bigotes: ${notes.length == 1 ? 'tiene un aviso' : 'tiene ${notes.length} avisos'}' : 'Don Bigotes, sin novedades',
      excludeSemantics: true,
      child: Tooltip(
        message: 'Don Bigotes',
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: SizedBox(
            width: 56,
            height: 56,
            child: Stack(clipBehavior: Clip.none, children: [
              Opacity(
                opacity: awake ? 1 : 0.7,
                child: Transform.rotate(
                  angle: awake ? 0 : -0.21,
                  child: Container(
                    width: 56,
                    height: 56,
                    alignment: Alignment.center,
                    decoration: BoxDecoration(
                      color: awake ? pulso.card : pulso.tertiary,
                      shape: BoxShape.circle,
                      border: Border.all(color: pulso.outline),
                      boxShadow: const [BoxShadow(color: Color(0x2E000000), blurRadius: 9, offset: Offset(0, 4))],
                    ),
                    child: DonBigotesMark(awake: awake, size: awake ? 40 : 34),
                  ),
                ),
              ),
              if (awake)
                Positioned(
                  right: -2,
                  top: -2,
                  child: Container(
                    constraints: const BoxConstraints(minWidth: 20, minHeight: 20),
                    padding: const EdgeInsets.symmetric(horizontal: 5),
                    alignment: Alignment.center,
                    decoration: BoxDecoration(color: pulso.warning, borderRadius: BorderRadius.circular(10), border: Border.all(color: pulso.page, width: 2)),
                    child: Text('${notes.length}', style: const TextStyle(fontSize: 11, fontWeight: FontWeight.w800, color: Colors.black)),
                  ),
                ),
            ]),
          ),
        ),
      ),
    );
  }
}

/// Shows Don Bigotes' bubble once for each new set of notes, for a few seconds.
class TeaserTimer {
  TeaserTimer(this.onChange);
  final VoidCallback onChange;
  String _shownFor = '';
  bool visible = false;
  Timer? _timer;

  void update(List<CompanionNote> notes) {
    final key = (notes.map((n) => n.id).toList()..sort()).join('|');
    if (key == _shownFor) return;
    _shownFor = key;
    _timer?.cancel();
    visible = notes.isNotEmpty;
    if (visible) _timer = Timer(const Duration(seconds: 6), close);
  }

  void close() {
    _timer?.cancel();
    if (!visible) return;
    visible = false;
    onChange();
  }

  void dispose() => _timer?.cancel();
}
