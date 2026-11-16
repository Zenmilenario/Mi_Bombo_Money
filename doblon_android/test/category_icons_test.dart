// Fictitious data only. Each category keeps the icon the iPhone app gave it (an SF Symbol name in the cloud document),
// and a movement shows the icon of its category, as on the iPhone.
import 'package:doblon/models.dart';
import 'package:doblon/presentation.dart';
import 'package:doblon/screens/widgets.dart';
import 'package:doblon/theme.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

void main() {
  test('the SF Symbols of the iPhone categories have their own icon, and an unknown one a tag', () {
    expect(symbolIcon('fork.knife'), Icons.restaurant);
    expect(symbolIcon('cart.fill'), Icons.shopping_cart);
    expect(symbolIcon('arrow.down.circle.fill'), Icons.south_west);
    expect(symbolIcon('algo.inventado'), Icons.sell);
    expect(symbolIcon(null), Icons.sell);
  });

  testWidgets('a movement shows the icon of its category', (tester) async {
    final data = Finances.fromDocument({
      'accounts': [
        {'id': 'a1', 'name': 'Corriente ficticia', 'typeRaw': 'checking', 'openingDate': 0},
      ],
      'categories': [
        {'id': 'c1', 'name': 'Restaurantes', 'kindRaw': 'expense', 'systemImage': 'fork.knife', 'colorHex': '#C2410C'},
        {'id': 'c2', 'name': 'Sin icono', 'kindRaw': 'expense'},
      ],
      'transactions': [
        {'id': 't1', 'date': 815184000, 'typeRaw': 'expense', 'amountMinor': 990, 'descriptionText': 'Cena ficticia', 'sourceAccountID': 'a1', 'categoryID': 'c1'},
      ],
    });
    expect(data.category('c1')!.systemImage, 'fork.knife');
    expect(data.category('c2')!.systemImage, 'tag', reason: 'The default of the iPhone app');
    await tester.pumpWidget(MaterialApp(
        theme: doblonTheme(Brightness.light),
        home: Scaffold(body: TransactionTile(transaction: data.transactions.single, data: data))));
    expect(find.byIcon(Icons.restaurant), findsOneWidget);
  });
}
