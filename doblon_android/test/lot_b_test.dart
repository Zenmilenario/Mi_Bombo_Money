// Fictitious data only. Lote B of recovering the iPhone app's screens: goals, recurring movements, entities, the
// budget analysis, help and about, and the drum of the sign-in screen.
import 'dart:io';

import 'package:doblon/data.dart';
import 'package:doblon/finance.dart';
import 'package:doblon/models.dart';
import 'package:doblon/screens/budgets.dart';
import 'package:doblon/screens/info.dart';
import 'package:doblon/screens/manage.dart';
import 'package:doblon/screens/widgets.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_localizations/flutter_localizations.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:intl/date_symbol_data_local.dart';

double seconds(DateTime d) => d.millisecondsSinceEpoch / 1000 - 978307200;

Finances sample(DateTime now) => Finances.fromDocument({
      'institutions': [
        {'id': 'i1', 'name': 'Banco Ficticio', 'colorHex': '#1E40AF'},
      ],
      'accounts': [
        {'id': 'a1', 'name': 'Nómina ficticia', 'typeRaw': 'checking', 'openingDate': 0, 'openingBalanceMinor': 100000, 'institutionID': 'i1'},
        {'id': 'a2', 'name': 'Cartera ficticia', 'typeRaw': 'investment', 'openingDate': 0},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Comida', 'kindRaw': 'expense', 'systemImage': 'basket.fill'},
      ],
      'cards': [
        {'id': 'k1', 'name': 'Visa ficticia', 'typeRaw': 'debit', 'lastFour': '1234', 'linkedAccountID': 'a1'},
      ],
      'goals': [
        {'id': 'g1', 'name': 'Viaje ficticio', 'targetAmountMinor': 120000, 'currentAmountMinor': 30000},
      ],
      'recurringBudgets': [
        {'id': 'r1', 'categoryID': 'c1', 'startMonth': seconds(DateTime(now.year - 1, 1)), 'baseLimitMinor': 10000, 'remainderChoiceRaw': 'save'},
      ],
      'recurringMovements': [
        {'id': 'm1', 'name': 'Gimnasio ficticio', 'typeRaw': 'expense', 'amountMinor': 3000, 'descriptionText': 'Gimnasio', 'frequencyRaw': 'monthly',
          'nextDueDate': seconds(now.add(const Duration(days: 5))), 'isActive': true, 'sourceAccountID': 'a1', 'categoryID': 'c1'},
        {'id': 'm2', 'name': 'Revista antigua', 'typeRaw': 'expense', 'amountMinor': 500, 'descriptionText': 'Revista', 'frequencyRaw': 'monthly',
          'nextDueDate': seconds(now), 'isActive': false, 'sourceAccountID': 'a1'},
      ],
      'transactions': [
        {'id': 't1', 'date': seconds(DateTime(now.year, now.month - 1, 3, 12)), 'typeRaw': 'expense', 'amountMinor': 4000,
          'descriptionText': 'Compra ficticia', 'sourceAccountID': 'a1', 'categoryID': 'c1'},
      ],
    });

Widget app(Widget child) => MaterialApp(
      theme: doblonTheme(Brightness.light),
      locale: const Locale('es', 'ES'),
      supportedLocales: const [Locale('es', 'ES')],
      localizationsDelegates: GlobalMaterialLocalizations.delegates,
      home: child,
    );

Future<void> show(WidgetTester tester, Widget child) async {
  tester.view.physicalSize = const Size(430, 2600);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(app(child));
  await tester.pumpAndSettle();
}

void main() {
  setUpAll(() => initializeDateFormatting('es'));
  final now = DateTime.now();

  test('what a goal still needs, with and without a date', () {
    expect(goalStatus(current: 100, target: 100, now: now), '¡Objetivo conseguido!');
    expect(goalStatus(current: 0, target: 120000, now: now), contains('Faltan'));
    expect(goalStatus(current: 0, target: 120000, date: DateTime(now.year, now.month + 4, 1), now: now), contains('al mes hasta'));
  });

  test('what a past month left with «Queda como ahorro»', () {
    final calc = FinanceCalculator(sample(now));
    expect(unspentKept(calc, DateTime(now.year, now.month - 1)), 6000);
  });

  test('the version of «Acerca de» is the one of the project', () {
    final pubspec = File('pubspec.yaml').readAsStringSync();
    expect(RegExp(r'^version: ([0-9.]+)\+', multiLine: true).firstMatch(pubspec)!.group(1), appVersion);
  });

  testWidgets('a goal in detail', (tester) async {
    final repository = FinanceRepository()..finances = sample(now);
    await show(tester, GoalDetailScreen(repository: repository, goalId: 'g1'));
    for (final text in ['Viaje ficticio', '25 %', 'Ahorrado', 'Falta', 'Manual', 'Fecha objetivo']) {
      expect(find.text(text), findsWidgets, reason: text);
    }
  });

  testWidgets('recurring movements: active and inactive, and the investment contribution starts as a transfer', (tester) async {
    final repository = FinanceRepository()..finances = sample(now);
    await show(tester, RecurringScreen(repository: repository));
    expect(find.text('Activos'), findsOneWidget);
    expect(find.text('Inactivos'), findsOneWidget);
    await show(tester, RecurringFormScreen(repository: repository, investmentContribution: true));
    expect(find.text('Cartera ficticia'), findsWidgets, reason: 'The investment account is chosen as destination');
  });

  testWidgets('an entity with its colour, accounts and cards', (tester) async {
    final data = sample(now);
    await show(tester, InstitutionFormScreen(repository: FinanceRepository()..finances = data, editing: data.institutions.single));
    for (final text in ['Cuentas asociadas', 'Nómina ficticia', 'Tarjetas', 'Visa ficticia', 'Vista previa']) {
      expect(find.text(text), findsWidgets, reason: text);
    }
  });

  testWidgets('the budget analysis of a month', (tester) async {
    await show(tester, BudgetAnalysisScreen(calc: FinanceCalculator(sample(now)), month: DateTime(now.year, now.month - 1)));
    expect(find.text('Presupuesto frente a gasto real'), findsOneWidget);
    expect(find.text('Comparativa por categoría'), findsOneWidget);
  });

  testWidgets('help, privacy, about and the drum', (tester) async {
    await show(tester, const HelpScreen());
    expect(find.text('Primeros pasos'), findsOneWidget);
    await show(tester, const PrivacyScreen());
    expect(find.text('Sin credenciales bancarias'), findsOneWidget);
    await show(tester, const AboutScreen());
    expect(find.text('Don Bigotes'), findsOneWidget);
    expect(find.text(appVersion), findsOneWidget);
    await show(tester, const Scaffold(body: BomboIllustration()));
    expect(find.bySemanticsLabel('Ilustración: monedas que caen dentro de un bombo'), findsOneWidget);
  });
}
