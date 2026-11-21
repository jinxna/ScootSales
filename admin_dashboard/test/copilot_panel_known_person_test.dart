import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/navigation/cms_navigation.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/voice/copilot/copilot_client.dart';
import 'package:flutter_web_app/voice/copilot/copilot_entity_resolver.dart';
import 'package:flutter_web_app/voice/copilot/copilot_panel.dart';
import 'package:flutter_web_app/voice/copilot/copilot_status.dart';
import 'package:flutter_web_app/voice/copilot/order_search_session.dart';
import 'package:flutter_web_app/voice/dashboard_voice_catalog.dart';
import 'package:flutter_web_app/voice/dashboard_voice_types.dart';

const String _offTopic =
    "I can only answer questions about this company's orders, routes, shops and team, so I cannot answer that. Try one of these.";

const UserProfile _admin = UserProfile(
  docId: 'a',
  email: 'a@x.test',
  name: 'Admin',
  role: 'admin',
  employeeCode: 'A1',
  status: UserProfile.statusActive,
  uid: 'uid-a',
  branchId: '',
);

class _Server extends CopilotServerClient {
  _Server()
    : super(baseUrl: Uri.parse('http://127.0.0.1:1'), idToken: () async => 't');

  final List<String> asked = <String>[];

  @override
  Future<bool> isReady() async => true;

  @override
  Future<CopilotProposal?> interpret({
    required String text,
    required List<DashboardVoicePage> pages,
    required List<String> actions,
  }) async {
    asked.add(text);
    return null;
  }
}

Future<_Server> _pumpPanel(WidgetTester tester, {List<String>? opened}) async {
  final _Server server = _Server();
  final CopilotServerStatus status = CopilotServerStatus(server);
  await status.wake();
  addTearDown(status.dispose);
  final List<DashboardVoicePage> pages = dashboardVoicePagesFromCms(
    cmsSearchItems('admin'),
  );
  await tester.pumpWidget(
    MaterialApp(
      theme: DsoTheme.light,
      home: Scaffold(
        body: CopilotPanel(
          currentUser: _admin,
          pages: pages,
          onPageRequested: (String key) async => opened?.add(key),
          onClose: () {},
          status: status,
          server: server,
          orders: OrderSearchSession(
            readWindow: (DateTime start, DateTime end) async =>
                const OrderWindow(rows: <Map<String, dynamic>>[]),
            loadSalespeople: () async => const <EntityRef>[
              EntityRef(
                kind: EntityKind.salesperson,
                id: 'u1',
                name: 'Ali Hassan',
                code: 'S0001',
              ),
              EntityRef(
                kind: EntityKind.salesperson,
                id: 'u2',
                name: 'Ng',
                code: 'S0002',
              ),
              EntityRef(
                kind: EntityKind.salesperson,
                id: 'u3',
                name: 'Siti Ab Rahman',
                code: 'S0003',
              ),
            ],
            download: (String filename, String csv) => true,
            recordExport: (set, filename) async {},
            scopeNote: null,
          ),
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
  return server;
}

Future<void> _say(WidgetTester tester, String text) async {
  await tester.enterText(find.byType(TextField), text);
  await tester.testTextInput.receiveAction(TextInputAction.done);
  await tester.pumpAndSettle();
}

void main() {
  for (final String phrase in <String>[
    'who is Ali',
    'who is Ng',
    'who is S0001',
    'who is Rahman',
    'who is siti ab rahman',
  ]) {
    testWidgets(
      'typed in the panel, "$phrase" names a known salesperson, so it is not refused as off topic and the model is asked',
      (WidgetTester tester) async {
        final _Server server = await _pumpPanel(tester);
        await _say(tester, phrase);
        expect(find.text(_offTopic), findsNothing);
        expect(server.asked, <String>[phrase]);
      },
    );
  }

  for (final String phrase in <String>[
    'who is mark zuckerberg',
    'who is ab de villiers',
    'who is S000',
    'who is rahmania',
  ]) {
    testWidgets(
      'typed in the panel, "$phrase" names no known salesperson by a whole name part of 3 letters, a whole name or a whole code, so it is refused as off topic and the model is not asked',
      (WidgetTester tester) async {
        final _Server server = await _pumpPanel(tester);
        await _say(tester, phrase);
        expect(find.text(_offTopic), findsOneWidget);
        expect(server.asked, isEmpty);
      },
    );
  }

  testWidgets(
    'typed in the panel, "i hate planning routes" opens no page, while "open the route planner" does',
    (WidgetTester tester) async {
      final List<String> opened = <String>[];
      await _pumpPanel(tester, opened: opened);
      await _say(tester, 'i hate planning routes');
      expect(opened, isEmpty);
      await _say(tester, 'open the route planner');
      expect(opened, <String>['route_planner']);
    },
  );
}
