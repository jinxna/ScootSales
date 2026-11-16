import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/widgets/horizontal_scroll_cue.dart';

double _fadeOpacity(WidgetTester tester) => tester
    .widget<AnimatedOpacity>(
      find.ancestor(
        of: find.byKey(const ValueKey<String>('horizontal-scroll-fade')),
        matching: find.byType(AnimatedOpacity),
      ),
    )
    .opacity;

void main() {
  testWidgets('fade shows while more content is to the right and sticky '
      'column stays at the left edge', (WidgetTester tester) async {
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SizedBox(
            width: 400,
            height: 100,
            child: HorizontalScrollCue(
              child: SizedBox(
                width: 1000,
                child: Row(
                  children: <Widget>[
                    const SizedBox(
                      width: 100,
                      child: StickyColumnCell(
                        background: Colors.white,
                        child: Text('Name'),
                      ),
                    ),
                    Expanded(
                      child: ScrollsBehindStickyColumn(child: Container()),
                    ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ),
    );
    await tester.pumpAndSettle();
    expect(_fadeOpacity(tester), 1);
    expect(tester.getTopLeft(find.text('Name')).dx, 0);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-250, 0),
    );
    await tester.pumpAndSettle();
    expect(_fadeOpacity(tester), 1);
    expect(tester.getTopLeft(find.text('Name')).dx, 0);

    await tester.drag(
      find.byType(SingleChildScrollView),
      const Offset(-900, 0),
    );
    await tester.pumpAndSettle();
    expect(_fadeOpacity(tester), 0);
    expect(tester.getTopLeft(find.text('Name')).dx, 0);
  });
}
