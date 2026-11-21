import 'dart:io';

import 'package:flutter/foundation.dart';
import 'package:flutter/gestures.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/navigation/cms_navigation.dart';
import 'package:flutter_web_app/voice/copilot/copilot_status.dart';
import 'package:flutter_web_app/widgets/dashboard_chrome.dart';
import 'package:scoot_design/scoot_design.dart';

const String _title = 'Account';
const String _fact = 'Your plan, renewal date and usage against the plan limits.';

Future<String?> _dragAndCopy(WidgetTester tester, Finder text) async {
  String? copied;
  tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
    SystemChannels.platform,
    (MethodCall call) async {
      if (call.method == 'Clipboard.setData') {
        copied = (call.arguments as Map<Object?, Object?>)['text'] as String?;
      }
      return null;
    },
  );
  addTearDown(
    () => tester.binding.defaultBinaryMessenger.setMockMethodCallHandler(
      SystemChannels.platform,
      null,
    ),
  );
  final Rect box = tester.getRect(text);
  final TestGesture gesture = await tester.startGesture(
    Offset(box.left + 1, box.center.dy),
    kind: PointerDeviceKind.mouse,
  );
  await tester.pump();
  await gesture.moveTo(Offset(box.right - 1, box.center.dy));
  await tester.pump();
  await gesture.up();
  await tester.pumpAndSettle();
  await tester.sendKeyDownEvent(LogicalKeyboardKey.controlLeft);
  await tester.sendKeyEvent(LogicalKeyboardKey.keyC);
  await tester.sendKeyUpEvent(LogicalKeyboardKey.controlLeft);
  await tester.pumpAndSettle();
  return copied;
}

Future<void> _pumpChrome(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1300, 1000);
  addTearDown(tester.view.reset);
  final List<CmsNavSection> sections = cmsSidebarSections('admin');
  await tester.pumpWidget(
    MaterialApp(
      theme: ScootTheme.dashboard(),
      home: Scaffold(
        body: DashboardChrome(
          user: UserProfile(
            docId: 'u',
            uid: 'u',
            email: 'u@example.test',
            name: 'Test User',
            role: 'admin',
            employeeCode: 'U-1',
            status: UserProfile.statusActive,
          ),
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
          pageTitle: _title,
          pageFact: _fact,
          child: const SizedBox.expand(),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
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

  testWidgets('the page title can be selected with the mouse and copied', (
    WidgetTester tester,
  ) async {
    await _pumpChrome(tester);
    expect(await _dragAndCopy(tester, find.text(_title)), _title);
  });

  testWidgets('the line under the page title can be selected and copied', (
    WidgetTester tester,
  ) async {
    await _pumpChrome(tester);
    expect(await _dragAndCopy(tester, find.text(_fact)), _fact);
  });
}
