import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/navigation/cms_navigation.dart';
import 'package:flutter_web_app/pages/admin/navigation/dashboard_pages.dart';
import 'package:flutter_web_app/services/notification_read_state_service.dart';
import 'package:flutter_web_app/widgets/dashboard_chrome.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter_web_app/utils/notification_read_state.dart';

void main() {
  test('rejects a path that could escape the owner document', () async {
    final NotificationReadStateService service = NotificationReadStateService(
      firestore: _Database(),
      authUid: 'user/other',
    );

    expect(service.load(), throwsArgumentError);
  });

  test('the unread badge drops to 0 after mark all as read', () async {
    final StreamController<NotificationReadState?> readState =
        StreamController<NotificationReadState?>();
    final StreamController<List<Map<String, dynamic>>> system =
        StreamController<List<Map<String, dynamic>>>();
    final StreamController<List<Map<String, dynamic>>> logs =
        StreamController<List<Map<String, dynamic>>>();
    final List<int> badge = <int>[];
    final StreamSubscription<int> subscription =
        NotificationReadStateService.unreadCountOf(
          readState: readState.stream,
          feeds: <Stream<List<Map<String, dynamic>>>>[
            system.stream,
            logs.stream,
          ],
        ).listen(badge.add);
    List<Map<String, dynamic>> rows(int count, int firstMinute) =>
        <Map<String, dynamic>>[
          for (int index = 0; index < count; index++)
            <String, dynamic>{
              'createdAt': DateTime.utc(2026, 11, 18, 10, firstMinute + index),
            },
        ];

    readState.add(null);
    system.add(rows(31, 0));
    logs.add(rows(20, 31));
    await pumpEventQueue();
    readState.add(
      NotificationReadState(readThroughAt: DateTime.utc(2026, 11, 18, 11)),
    );
    await pumpEventQueue();
    logs.add(<Map<String, dynamic>>[
      ...rows(20, 31),
      <String, dynamic>{'createdAt': DateTime.utc(2026, 11, 18, 11, 5)},
    ]);
    await pumpEventQueue();

    expect(badge, <int>[51, 0, 1]);
    await subscription.cancel();
  });

  test('the badge says "or more" once it reaches the 40 newest it reads', () {
    expect(NotificationReadStateService.unreadBadgeLabel(39), 'unread');
    expect(NotificationReadStateService.unreadBadgeLabel(40), 'or more unread');
    expect(NotificationReadStateService.unreadBadgeLabel(41), 'or more unread');
  });

  for (final (int unread, String shown, String spoken)
      in <(int, String, String)>[
        (39, '39', '39 unread'),
        (40, '40+', '40 or more unread'),
        (41, '40+', '41 or more unread'),
      ]) {
    testWidgets(
      '$unread unread notifications show "$shown" on the rail badge',
      (WidgetTester tester) async {
        final SemanticsHandle semantics = tester.ensureSemantics();
        await tester.binding.setSurfaceSize(const Size(400, 2400));
        addTearDown(() => tester.binding.setSurfaceSize(null));
        await tester.pumpWidget(
          MaterialApp(
            theme: ScootTheme.dashboard(),
            home: Scaffold(
              body: SizedBox(
                width: 700,
                child: ScootRail(
                  groups: scootNavGroups(
                    cmsSidebarSections('admin'),
                    badgeKey: DashboardPage.notifications.key,
                    badgeCount: unread,
                    badgeLabel: NotificationReadStateService.unreadBadgeLabel(
                      unread,
                    ),
                    badgeText: NotificationReadStateService.unreadBadgeText(
                      unread,
                    ),
                  ),
                  selectedId: null,
                  onSelect: (String id) {},
                ),
              ),
            ),
          ),
        );
        await tester.pumpAndSettle();
        expect(find.text(shown), findsOneWidget);
        expect(find.bySemanticsLabel(RegExp(', $spoken\$')), findsOneWidget);
        semantics.dispose();
      },
    );
  }
}

class _Database implements FirebaseFirestore {
  @override
  dynamic noSuchMethod(Invocation invocation) => super.noSuchMethod(invocation);
}
