import 'package:flutter_test/flutter_test.dart';

import 'package:example/main.dart';

void main() {
  testWidgets('renders example shell', (WidgetTester tester) async {
    await tester.pumpWidget(const ExampleApp());

    expect(find.text('LiteRT-LM Example'), findsOneWidget);
    expect(find.text('Prepare Engine'), findsOneWidget);
    expect(find.text('Generate'), findsOneWidget);
  });
}
