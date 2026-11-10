import 'package:flutter/material.dart';

/// The «Pulso» palette of the iPhone app (`AppDesign` in ReusableViews.swift), light and dark.
class Pulso extends ThemeExtension<Pulso> {
  const Pulso({
    required this.page,
    required this.card,
    required this.tertiary,
    required this.accent,
    required this.income,
    required this.expense,
    required this.savings,
    required this.investment,
    required this.warning,
  });
  final Color page, card, tertiary, accent, income, expense, savings, investment, warning;

  static const light = Pulso(
    page: Color(0xFFF4F2ED),
    card: Color(0xFFFFFFFF),
    tertiary: Color(0xFFF1EFEA),
    accent: Color(0xFF0F766E),
    income: Color(0xFF1E7A4C),
    expense: Color(0xFFB3263E),
    savings: Color(0xFF2457A6),
    investment: Color(0xFF6B3FA0),
    warning: Color(0xFF8A5A00),
  );
  static const dark = Pulso(
    page: Color(0xFF0D1620),
    card: Color(0xFF15212D),
    tertiary: Color(0xFF1C2B3A),
    accent: Color(0xFF5ED3C9),
    income: Color(0xFF7BE0A8),
    expense: Color(0xFFFF9AA8),
    savings: Color(0xFF8DB8FF),
    investment: Color(0xFFC6A6FF),
    warning: Color(0xFFF5C66B),
  );

  static Pulso of(BuildContext context) => Theme.of(context).extension<Pulso>()!;

  @override
  Pulso copyWith() => this;
  @override
  Pulso lerp(ThemeExtension<Pulso>? other, double t) => t < 0.5 ? this : (other as Pulso? ?? this);
}

ThemeData doblonTheme(Brightness brightness) {
  final pulso = brightness == Brightness.dark ? Pulso.dark : Pulso.light;
  final scheme = ColorScheme.fromSeed(seedColor: const Color(0xFF0F766E), brightness: brightness).copyWith(
    primary: pulso.accent,
    surface: pulso.page,
    surfaceContainer: pulso.card,
    surfaceContainerLow: pulso.card,
    surfaceContainerHigh: pulso.tertiary,
    error: pulso.expense,
  );
  return ThemeData(
    useMaterial3: true,
    colorScheme: scheme,
    scaffoldBackgroundColor: pulso.page,
    cardTheme: CardThemeData(color: pulso.card, elevation: 0, margin: EdgeInsets.zero,
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(18))),
    appBarTheme: AppBarTheme(backgroundColor: pulso.page, surfaceTintColor: Colors.transparent, centerTitle: false),
    navigationBarTheme: NavigationBarThemeData(backgroundColor: pulso.card, indicatorColor: pulso.accent.withValues(alpha: 0.18)),
    extensions: [pulso],
  );
}

Color colorFromHex(String hex) {
  final value = int.tryParse(hex.replaceFirst('#', ''), radix: 16);
  return value == null ? const Color(0xFF4D7C8A) : Color(0xFF000000 | value);
}
