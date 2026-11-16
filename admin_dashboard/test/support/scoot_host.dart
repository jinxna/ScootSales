import 'package:flutter_test/flutter_test.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

Widget scootHost(Widget child, {Size? size}) {
  return MaterialApp(
    theme: ScootTheme.dashboard(fontFamily: null),
    home: Scaffold(
      body: Padding(
        padding: const EdgeInsets.all(16),
        child: SizedBox(
          width: size?.width ?? 1200,
          height: size?.height ?? 800,
          child: child,
        ),
      ),
    ),
  );
}

void useDesktopSurface(WidgetTester tester) {
  tester.view.physicalSize = const Size(1440, 900);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
}
