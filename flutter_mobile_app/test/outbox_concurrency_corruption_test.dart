import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/route_stop_lifecycle_event.dart';
import 'package:fmcg_sales/models/work_session.dart';
import 'package:fmcg_sales/services/project_local_store.dart';
import 'package:fmcg_sales/services/route_stop_outbox.dart';
import 'package:fmcg_sales/services/work_session_store.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

RouteStopLifecycleEvent _event(
  int sequence, {
  String uid = 'u1',
  int generation = 1,
}) => RouteStopLifecycleEvent(
  uid: uid,
  planId: 'p',
  stopId: 's$sequence',
  workSessionId: 'w',
  workSessionGeneration: generation,
  sessionEventSequence: sequence,
  eventId: 'e-$generation-$sequence',
  status: 'arrived',
  deviceOccurredAt: DateTime.utc(2026, 1, 1),
  payload: const <String, dynamic>{},
  expectedSelectedStopId: 's$sequence',
  expectedSelectionRevision: 0,
);

void main() {
  setUp(() {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    signInTestUser('u1');
  });

  test('concurrent writes never drop or resurrect events', () async {
    final RouteStopOutbox outbox = RouteStopOutbox();
    final List<RouteStopLifecycleEvent> events = <RouteStopLifecycleEvent>[
      for (int i = 1; i <= 10; i++) _event(i),
      _event(1, generation: 2),
    ];
    await Future.wait(events.map(outbox.put));
    expect((await outbox.readForUid('u1')).length, 11);

    final RouteStopLifecycleEvent stale = events[0].copyWith(
      selectionRebaseCount: 1,
    );
    await Future.wait(<Future<void>>[
      outbox.remove(events[0]),
      outbox.update(stale),
      outbox.put(_event(11)),
      outbox.remove(events[1]),
    ]);
    final List<String> ids = (await outbox.readForUid(
      'u1',
    )).map((RouteStopLifecycleEvent e) => e.eventId).toList();
    expect(ids, isNot(contains(events[0].eventId)));
    expect(ids, isNot(contains(events[1].eventId)));
    expect(ids, contains('e-1-11'));
    expect(ids.length, 10);
    expect(ids.last, 'e-2-1');

    await outbox.update(stale);
    expect(
      (await outbox.readForUid(
        'u1',
      )).any((RouteStopLifecycleEvent e) => e.eventId == stale.eventId),
      isFalse,
    );
  });

  test(
    'corrupt outbox rows are quarantined and the rest still replay',
    () async {
      final RouteStopOutbox outbox = RouteStopOutbox();
      await outbox.put(_event(1));
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ProjectLocalStore store = ProjectLocalStore();
      final String goodKey = prefs.getKeys().single.substring(
        store.prefix('u1').length,
      );
      final String base = goodKey.substring(0, goodKey.lastIndexOf('_'));
      await store.write('u1', '${base}_7', '[{"uid":"u1","eventId"');
      await store.write('u1', '${base}_8', '{"not":"a list"}');
      await store.write(
        'u1',
        '${base}_9',
        jsonEncode(<Object?>[
          _event(2, generation: 9).toJson(),
          _event(3, uid: 'someone-else', generation: 9).toJson(),
          'garbage',
        ]),
      );

      final List<RouteStopLifecycleEvent> rows = await outbox.readForUid('u1');
      expect(rows.map((RouteStopLifecycleEvent e) => e.eventId), <String>[
        'e-1-1',
        'e-9-2',
      ]);
      await prefs.reload();
      expect(
        prefs.getKeys().where(
          (String key) => key.startsWith(ProjectLocalStore.recoveryPrefix),
        ),
        hasLength(3),
      );
      expect(prefs.containsKey(store.key('u1', '${base}_7')), isFalse);
      expect((await outbox.readForUid('u1')).length, 2);
      await outbox.put(_event(4));
      expect((await outbox.readForUid('u1')).length, 3);
    },
  );

  test(
    'corrupt saved work session reads as absent and is quarantined',
    () async {
      const WorkSessionStore store = WorkSessionStore();
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final ProjectLocalStore local = ProjectLocalStore();
      await local.write('u1', 'work_session', '{"uid":"u1"');
      expect(await store.read('u1'), isNull);
      await prefs.reload();
      expect(prefs.containsKey(local.key('u1', 'work_session')), isFalse);
      expect(
        prefs.getKeys().any(
          (String key) => key.startsWith(ProjectLocalStore.recoveryPrefix),
        ),
        isTrue,
      );

      final WorkSession fresh = WorkSession(
        uid: 'u1',
        sessionId: 's',
        generation: 1,
        lastFixSequence: 0,
        status: WorkSessionLocalStatus.active,
      );
      await store.write(fresh);
      expect((await store.read('u1'))?.sessionId, 's');
    },
  );
}
