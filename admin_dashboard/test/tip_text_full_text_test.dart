import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/widgets/tip_text.dart';

void main() {
  testWidgets('a name shown in full has no tooltip, a one-line name keeps it', (
    WidgetTester tester,
  ) async {
    const String name = 'Choice Supermarket Tabuan Jaya';
    await tester.pumpWidget(
      const MaterialApp(
        home: Scaffold(body: SizedBox(width: 200, child: TipText(name))),
      ),
    );
    expect(find.text(name), findsOneWidget);
    expect(find.byType(Tooltip), findsNothing);

    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 200,
            child: DefaultTextStyle.merge(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: const TipText(name),
            ),
          ),
        ),
      ),
    );
    expect(find.byType(Tooltip), findsOneWidget);
  });
}
