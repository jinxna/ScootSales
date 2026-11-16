import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/widgets/settings_dialog.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

const DsoSettingsProfile _profile = DsoSettingsProfile(
  authUid: 'uid-1',
  userDocId: 'doc-1',
  name: 'Aina Admin',
  email: 'aina@example.test',
  role: 'admin',
  branch: 'B1',
  userCode: 'A-01',
  status: 'active',
);

Future<void> _openAppearance(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: DsoTheme.light,
      home: Builder(
        builder: (BuildContext context) => Scaffold(
          body: TextButton(
            onPressed: () =>
                showDsoSettings(context, profile: _profile, initialTab: 1),
            child: const Text('open'),
          ),
        ),
      ),
    ),
  );
  await tester.tap(find.text('open'));
  await tester.pumpAndSettle();
}

double _lineHeight(WidgetTester tester, String text) {
  final Finder finder = find.text(text);
  return finder
      .evaluate()
      .map((Element e) => tester.getSize(find.byWidget(e.widget)).height)
      .reduce((double a, double b) => a > b ? a : b);
}

void main() {
  for (final Size size in const <Size>[Size(390, 844), Size(2000, 1200)]) {
    testWidgets(
      'Settings Appearance reads on one line at ${size.width.toInt()} px',
      (WidgetTester tester) async {
        await _openAppearance(tester, size);
        expect(tester.takeException(), isNull);
        expect(_lineHeight(tester, 'Appearance'), lessThan(30));
        expect(_lineHeight(tester, 'Dark'), lessThan(30));
        await tester.tap(find.text('Profile'));
        await tester.pumpAndSettle();
        expect(tester.takeException(), isNull);
        expect(_lineHeight(tester, 'Profile'), lessThan(30));
      },
    );
  }
}
