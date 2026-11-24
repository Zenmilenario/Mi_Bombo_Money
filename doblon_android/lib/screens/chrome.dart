// The frame around the five tabs: a header that hides while scrolling down and comes back when scrolling up, and two
// small floating controls above the tabs, Don Bigotes and «+ Añadir».
import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../automation.dart' show CompanionNote;
import '../data.dart' show CompanionMood;
import '../theme.dart';
import 'widgets.dart' show LabelValues;
import 'bank_refresh.dart' show ThinkingDots;
import 'shell.dart' show DonBigotesMark;

/// «Buenos días», «Buenas tardes» or «Buenas noches», as on the iPhone.
String greeting(DateTime now) => now.hour >= 6 && now.hour < 12 ? 'Buenos días' : (now.hour >= 12 && now.hour < 21 ? 'Buenas tardes' : 'Buenas noches');

/// Height of the header row under the status bar.
const headerHeight = 52.0;

/// Room under the last item of every tab (the tabs are already in the bottom padding), so it can always be scrolled
/// above Don Bigotes and «+ Añadir».
const dockReserve = 72.0;

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
            // Whole with any text size: it shrinks to the row rather than being cut.
            Expanded(child: FittedBox(fit: BoxFit.scaleDown, alignment: Alignment.centerLeft, child: title)),
            ...actions,
          ]),
        ),
      ),
    );
  }
}

/// Don Bigotes and «+ Añadir», two small floating controls above the tabs: the cat at the left with the number of
/// notices (tapping him shows what they say), «+ Añadir» at the right. No band behind them. Every list keeps
/// [dockReserve] free under its last item, so whatever is under them can always be scrolled into the clear.
class FloatingActions extends StatelessWidget {
  const FloatingActions({super.key, this.onAdd, required this.notes, this.onCompanion, this.companion = true, this.mood = CompanionMood.idle});
  final VoidCallback? onAdd;

  /// What Don Bigotes is doing now (asking the banks, saving…): he shows it on his button.
  final CompanionMood mood;
  final List<CompanionNote> notes;
  final VoidCallback? onCompanion;

  /// With Don Bigotes switched off, the notices are still reachable from a plain button.
  final bool companion;

  @override
  Widget build(BuildContext context) {
    // The controls keep their size with very large text; the screen reader reads their full labels.
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.2,
      child: Row(crossAxisAlignment: CrossAxisAlignment.end, children: [
        if (companion)
          CompanionButton(notes: notes, onTap: onCompanion ?? () {}, size: 44, mood: mood)
        else if (notes.isNotEmpty)
          _NoticesButton(notes: notes, onTap: onCompanion),
        const Spacer(),
        if (onAdd != null) AddButton(onPressed: onAdd!),
      ]),
    );
  }
}

/// «+ Añadir»: compact, with its word, and a touch area of at least 48 points.
class AddButton extends StatelessWidget {
  const AddButton({super.key, required this.onPressed});
  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
        button: true,
        label: 'Añadir movimiento',
        excludeSemantics: true,
        child: FilledButton.icon(
          onPressed: onPressed,
          style: FilledButton.styleFrom(
            minimumSize: const Size(48, 44),
            tapTargetSize: MaterialTapTargetSize.padded,
            padding: const EdgeInsets.symmetric(horizontal: 16),
            shape: const StadiumBorder(),
            elevation: 3,
            shadowColor: Colors.black38,
          ),
          icon: const Icon(Icons.add, size: 20),
          label: const Text('Añadir', style: TextStyle(fontSize: 15, fontWeight: FontWeight.w700)),
        ),
      );
}

class _NoticesButton extends StatelessWidget {
  const _NoticesButton({required this.notes, this.onTap});
  final List<CompanionNote> notes;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    return Semantics(
      button: true,
      label: notes.length == 1 ? '1 aviso pendiente' : '${notes.length} avisos pendientes',
      excludeSemantics: true,
      child: Badge(
        label: Text('${notes.length}'),
        backgroundColor: pulso.warning,
        textColor: Colors.black,
        child: IconButton.filledTonal(onPressed: onTap, icon: const Icon(Icons.inbox_outlined)),
      ),
    );
  }
}

/// Don Bigotes, as on the iPhone: awake with a small badge counting his notes, asleep (faded and tilted) when
/// everything is in order. The touch area is never smaller than 48 points.
class CompanionButton extends StatelessWidget {
  const CompanionButton({super.key, required this.notes, required this.onTap, this.size = 56, this.mood = CompanionMood.idle});
  final List<CompanionNote> notes;
  final VoidCallback onTap;
  final double size;
  final CompanionMood mood;

  @override
  Widget build(BuildContext context) {
    final pulso = Pulso.of(context);
    final awake = notes.isNotEmpty;
    final thinking = mood == CompanionMood.thinking, active = mood != CompanionMood.idle;
    final touch = math.max(48.0, size);
    return Semantics(
      button: true,
      label: switch (mood) {
        CompanionMood.thinking => 'Don Bigotes está consultando tus bancos',
        CompanionMood.saving => 'Don Bigotes está guardando en tu nube',
        CompanionMood.reading => 'Don Bigotes está leyendo tu nube',
        CompanionMood.happy => 'Don Bigotes: bancos al día',
        CompanionMood.worried => 'Don Bigotes: algún banco no se ha podido actualizar',
        CompanionMood.idle => awake ? 'Don Bigotes: ${notes.length == 1 ? 'tiene un aviso' : 'tiene ${notes.length} avisos'}' : 'Don Bigotes, sin novedades',
      },
      excludeSemantics: true,
      child: GestureDetector(
        onTap: onTap,
        behavior: HitTestBehavior.opaque,
        child: SizedBox(
          width: touch,
          height: touch,
          child: Center(
            child: SizedBox(
              width: size,
              height: size,
              child: Stack(clipBehavior: Clip.none, children: [
                Opacity(
                  opacity: awake || active ? 1 : 0.75,
                  child: Transform.rotate(
                    angle: awake || active ? 0 : -0.21,
                    child: Container(
                      width: size,
                      height: size,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: pulso.card,
                        shape: BoxShape.circle,
                        border: Border.all(color: pulso.outline),
                        boxShadow: const [BoxShadow(color: Color(0x29000000), blurRadius: 8, offset: Offset(0, 3))],
                      ),
                      child: DonBigotesMark(awake: awake, mood: mood, size: size * (awake || active ? 0.74 : 0.64)),
                    ),
                  ),
                ),
                if (thinking)
                  Positioned(
                    right: -8,
                    top: -10,
                    child: Container(
                      padding: const EdgeInsets.symmetric(horizontal: 4, vertical: 4),
                      decoration: BoxDecoration(color: pulso.card, borderRadius: BorderRadius.circular(10), border: Border.all(color: pulso.outline)),
                      child: const ThinkingDots(size: 4),
                    ),
                  )
                else if (awake)
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
        ),
      ),
    );
  }
}

/// The five tabs. Labels are read in full where they fit at the person's text size; where they do not (narrow
/// screens or large text) only the icons stay, each with its name for the screen reader and as a tooltip, and the
/// header names the tab. Never a label broken in two lines.
class DoblonNavigationBar extends StatelessWidget {
  const DoblonNavigationBar({super.key, required this.selectedIndex, required this.onDestinationSelected});
  final int selectedIndex;
  final ValueChanged<int> onDestinationSelected;

  static const _labels = ['Inicio', 'Movimientos', 'Cuentas', 'Presupuestos', 'Ajustes'];

  /// Whether the longest label, measured in the tab bar's font at the person's text size, fits in one fifth of
  /// `width` with a pixel to spare on each side.
  static bool labelsFit(double width, TextScaler scale, TextStyle style) => _labels.every((label) => LabelValues.width(label, style, scale) + 2 <= width / 5);

  @override
  Widget build(BuildContext context) {
    final style = DefaultTextStyle.of(context).style.merge(Theme.of(context).navigationBarTheme.labelTextStyle?.resolve({WidgetState.selected}));
    final fit = labelsFit(MediaQuery.sizeOf(context).width, MediaQuery.textScalerOf(context), style);
    return NavigationBar(
      height: fit ? 64 : 56,
      backgroundColor: Colors.transparent,
      labelBehavior: fit ? NavigationDestinationLabelBehavior.alwaysShow : NavigationDestinationLabelBehavior.alwaysHide,
      selectedIndex: selectedIndex,
      onDestinationSelected: onDestinationSelected,
      destinations: [
        for (final (i, icons) in const [
          (Icons.home_outlined, Icons.home),
          (Icons.receipt_long_outlined, Icons.receipt_long),
          (Icons.account_balance_outlined, Icons.account_balance),
          (Icons.pie_chart_outline, Icons.pie_chart),
          (Icons.settings_outlined, Icons.settings),
        ].indexed)
          NavigationDestination(icon: Icon(icons.$1), selectedIcon: Icon(icons.$2), label: _labels[i]),
      ],
    );
  }
}
