import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/app/workspace_runtime.dart';
import 'package:flutter_web_app/pages/auth/login_page.dart';
import 'package:scoot_design/scoot_design.dart';

FocusNode _fieldFocus(WidgetTester tester, int index) =>
    tester.widget<EditableText>(find.byType(EditableText).at(index)).focusNode;

FocusNode _buttonFocus(WidgetTester tester, String label) =>
    Focus.of(tester.element(find.text(label)));

Future<void> _pumpLogin(WidgetTester tester) async {
  tester.view.physicalSize = const Size(1400, 1000);
  tester.view.devicePixelRatio = 1;
  addTearDown(tester.view.reset);
  await tester.pumpWidget(
    MaterialApp(
      theme: ScootTheme.dashboard(),
      home: LoginPage(onSignedIn: () {}),
    ),
  );
  await tester.pump();
}

void main() {
  setUp(() {
    WorkspaceRuntime.loadError = '';
    WorkspaceRuntime.current = const WorkspaceConfig(
      tenantId: 'demo-a',
      workspace: 'demo-a',
      legalName: 'Demo A',
      companyCode: 'DA',
      status: 'active',
      planRef: 'standard',
      edition: 'standard',
      releaseRing: 'stable',
      rulesVersion: '1',
      version: 1,
      options: FirebaseOptions(
        apiKey: 'demo',
        appId: 'demo',
        messagingSenderId: 'demo',
        projectId: 'demo-a',
      ),
      services: <String, String>{},
    );
  });

  tearDown(() => WorkspaceRuntime.current = null);

  testWidgets('Enter in the email field moves to the password field', (
    WidgetTester tester,
  ) async {
    await _pumpLogin(tester);
    await tester.tap(find.byType(EditableText).at(0));
    await tester.enterText(
      find.byType(EditableText).at(0),
      'owner@example.test',
    );
    await tester.testTextInput.receiveAction(TextInputAction.next);
    await tester.pumpAndSettle();

    expect(_fieldFocus(tester, 1).hasPrimaryFocus, isTrue);
    expect(_buttonFocus(tester, 'Forgot password?').hasFocus, isFalse);
    expect(find.text('Reset password'), findsNothing);
    expect(find.byType(Dialog), findsNothing);
  });

  testWidgets('Tab goes email, password, Sign In, then forgot password', (
    WidgetTester tester,
  ) async {
    await _pumpLogin(tester);
    await tester.tap(find.byType(EditableText).at(0));
    await tester.pump();
    final FocusNode password = _fieldFocus(tester, 1);
    final FocusNode signIn = _buttonFocus(tester, 'Sign In');
    final FocusNode forgot = _buttonFocus(tester, 'Forgot password?');
    final List<String> visited = <String>[];
    for (int step = 0; step < 6; step++) {
      await tester.sendKeyEvent(LogicalKeyboardKey.tab);
      await tester.pump();
      final FocusNode? now = FocusManager.instance.primaryFocus;
      if (now == password) visited.add('password');
      if (now == signIn) visited.add('sign in');
      if (now == forgot) visited.add('forgot');
    }
    expect(visited, <String>['password', 'sign in', 'forgot']);
  });
}
