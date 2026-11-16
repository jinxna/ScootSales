import 'package:flutter/material.dart';
import 'package:flutter/rendering.dart';
import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/pages/admin/views/all_orders_page.dart';

Future<RenderParagraph> _chip(WidgetTester tester, double width) async {
  await tester.pumpWidget(
    MaterialApp(
      home: Scaffold(
        body: Align(
          alignment: Alignment.topLeft,
          child: SizedBox(
            width: width,
            child: DefaultTextStyle.merge(
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              child: const PossibleDuplicateChip(),
            ),
          ),
        ),
      ),
    ),
  );
  return tester.renderObject<RenderParagraph>(find.text('Possible duplicate'));
}

void main() {
  testWidgets('Possible duplicate stays fully readable at 390 px', (
    WidgetTester tester,
  ) async {
    final RenderParagraph narrow = await _chip(tester, 130);
    expect(narrow.didExceedMaxLines, isFalse);
    expect(find.text('Possible duplicate'), findsOneWidget);
  });

  testWidgets('Possible duplicate stays on one line at 2000 px', (
    WidgetTester tester,
  ) async {
    final RenderParagraph wide = await _chip(tester, 400);
    expect(wide.size.height, lessThan(20));
  });
}
