import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/navigation/cms_navigation.dart';
import 'package:flutter_web_app/voice/copilot/copilot_status.dart';
import 'package:flutter_web_app/widgets/dashboard_chrome.dart';
import 'package:scoot_design/scoot_design.dart';

UserProfile _user(String role) => UserProfile(
  docId: 'u',
  uid: 'u',
  email: 'u@example.test',
  name: 'Test User',
  role: role,
  employeeCode: 'U-1',
  status: UserProfile.statusActive,
);

Future<void> _size(WidgetTester tester, double width) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = Size(width, 1000);
  addTearDown(tester.view.reset);
}

Future<void> _loadInter() async {
  final FontLoader loader = FontLoader('packages/scoot_design/Inter');
  for (final String file in <String>['Regular', 'SemiBold']) {
    final List<int> bytes = File(
      '../packages/scoot_design/assets/fonts/inter/Inter-$file.ttf',
    ).readAsBytesSync();
    loader.addFont(
      Future<ByteData>.value(ByteData.sublistView(Uint8List.fromList(bytes))),
    );
  }
  await loader.load();
}

void main() {
  setUpAll(_loadInter);
  resizeKeepsState();
}

Future<void> _resizeTo(WidgetTester tester, Size size) async {
  tester.view.physicalSize = size;
  await tester.pump();
  await tester.pump(const Duration(milliseconds: 300));
}

void resizeKeepsState() {
  testWidgets('typed text survives resizing across the phone and short lines', (
    WidgetTester tester,
  ) async {
    await _size(tester, 1300);
    final List<CmsNavSection> sections = cmsSidebarSections('admin');
    await tester.pumpWidget(
      MaterialApp(
        theme: ScootTheme.dashboard(),
        home: Scaffold(
          body: DashboardChrome(
            user: _user('admin'),
            groups: scootNavGroups(sections),
            selectedId: sections.first.items.first.key,
            onSelect: (_) {},
            scopeLabel: 'All branches',
            onSearch: () {},
            copilotStatus: ValueNotifier<CopilotServerState>(
              CopilotServerState.ready,
            ),
            copilotOpen: false,
            onCopilot: () {},
            onSignOut: () {},
            pageTitle: 'Account',
            pageFact: 'f',
            child: const TextField(key: Key('typed')),
          ),
        ),
      ),
    );
    await tester.enterText(find.byKey(const Key('typed')), 'kept');
    for (final Size size in const <Size>[
      Size(600, 900),
      Size(1300, 900),
      Size(1300, 500),
      Size(2000, 900),
      Size(400, 500),
    ]) {
      await _resizeTo(tester, size);
      expect(find.text('kept'), findsOneWidget, reason: 'lost at $size');
    }
  });
}
