import 'package:flutter_web_app/app/workspace_runtime.dart';
import 'package:flutter_web_app/pages/admin/widgets/user_management_invitations_panel.dart';
import 'package:flutter_web_app/services/platform_api_client.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';

class _RecordingClient extends PlatformApiClient {
  final List<String> revoked = <String>[];

  @override
  Future<List<InvitationRecord>> listInvitations() async => <InvitationRecord>[
    const InvitationRecord(
      invitationId: '0123456789abcdef0123456789abcdef',
      uid: 'u1',
      displayName: 'Aina',
      signInId: 'aina@example.com',
      role: 'salesman',
      status: 'expired',
      expiresAt: null,
      createdAt: null,
      createdBy: 'admin',
      redeemedAt: null,
      redeemedDevice: '',
      failures: 0,
    ),
  ];

  @override
  Future<void> revokeInvitation(String invitationId) async {
    revoked.add(invitationId);
  }
}

void main() {
  setUp(() {
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

  testWidgets('Invite again keeps the old code until the new one is sent', (
    WidgetTester tester,
  ) async {
    final _RecordingClient client = _RecordingClient();
    final List<String> prefilled = <String>[];
    await tester.pumpWidget(
      MaterialApp(
        home: Scaffold(
          body: SingleChildScrollView(
            child: UserManagementInvitationsPanel(
              client: client,
              onInviteAgain: (InvitationRecord row) =>
                  prefilled.add(row.invitationId),
            ),
          ),
        ),
      ),
    );
    await tester.tap(find.text('Invitations'));
    await tester.pumpAndSettle();
    await tester.tap(find.text('Invite again'));
    await tester.pumpAndSettle();

    expect(prefilled, <String>['0123456789abcdef0123456789abcdef']);
    expect(client.revoked, isEmpty);
  });
}
