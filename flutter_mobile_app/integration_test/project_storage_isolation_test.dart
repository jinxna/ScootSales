import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:integration_test/integration_test.dart';
import 'package:shared_preferences/shared_preferences.dart';
// ignore: depend_on_referenced_packages
import 'package:shared_preferences_platform_interface/shared_preferences_platform_interface.dart';

import 'package:fmcg_sales/models/route_stop_lifecycle_event.dart';
import 'package:fmcg_sales/models/work_session.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/models/visit_brief.dart';
import 'package:fmcg_sales/services/cart_draft_cache.dart';
import 'package:fmcg_sales/services/guided_visit_session_store.dart';
import 'package:fmcg_sales/services/project_local_store.dart';
import 'package:fmcg_sales/services/route_stop_outbox.dart';
import 'package:fmcg_sales/services/sales_visit_copilot_service.dart';
import 'package:fmcg_sales/services/work_session_store.dart';

const _uid = 'storage-shared-uid';
const _projectA = 'demo-storage-a';
const _projectB = 'demo-storage-b';

class _FailingPreferences extends InMemorySharedPreferencesStore {
  _FailingPreferences() : super.empty();
  bool failCopy = false;
  bool loseCopy = false;

  @override
  Future<bool> setValue(String valueType, String key, Object value) async {
    if (key.contains(ProjectLocalStore.recoveryPrefix)) {
      if (failCopy) return false;
      if (loseCopy) return true;
    }
    return super.setValue(valueType, key, value);
  }
}

RouteStopLifecycleEvent _event(String id) => RouteStopLifecycleEvent(
  uid: _uid,
  planId: 'plan',
  stopId: 'stop',
  workSessionId: '0123456789abcdef0123456789abcdef',
  workSessionGeneration: 1,
  sessionEventSequence: 1,
  eventId: id,
  status: 'completed',
  deviceOccurredAt: DateTime.utc(2026, 10, 27),
  payload: const {'salesmanUid': _uid},
  expectedSelectedStopId: 'stop',
  expectedSelectionRevision: 0,
);

Future<void> _activate(String project) async {
  if (Firebase.apps.any((app) => app.name == '[DEFAULT]')) {
    await Firebase.app().delete();
  }
  await Firebase.initializeApp(
    options: FirebaseOptions(
      apiKey: 'synthetic-$project',
      appId: '1:123456789:windows:storage',
      messagingSenderId: '123456789',
      projectId: project,
    ),
  );
  await FirebaseAuth.instance.useAuthEmulator('127.0.0.1', 18779);
  await FirebaseAuth.instance.signInAnonymously();
}

void main() {
  final binding = IntegrationTestWidgetsFlutterBinding.ensureInitialized();

  setUp(() async {
    SharedPreferences.setMockInitialValues({});
    await _activate(_projectA);
    CartDraftCache.resetRuntime();
  });

  testWidgets('same UID keeps real outbox/session/drafts in its project', (
    tester,
  ) async {
    final outboxA = RouteStopOutbox();
    final sessionsA = WorkSessionStore();
    await outboxA.put(_event('event-a'));
    await sessionsA.write(
      const WorkSession(
        uid: _uid,
        sessionId: 'session-a',
        generation: 1,
        lastFixSequence: 0,
        status: WorkSessionLocalStatus.active,
      ),
    );
    await CartDraftCache.initialise();
    final keyA = CartDraftCache.keyFor(
      salesmanUid: _uid,
      retailerId: 'retailer',
    );
    expect(
      (await CartDraftCache.saveAndWait(
        keyA,
        CartDraftSnapshot(
          salesmanUid: _uid,
          retailerId: 'retailer',
          pendingOrderId: 'unsent-order-a',
        ),
      )).isSaved,
      isTrue,
    );
    await GuidedVisitSessionStore.markOutcomeRecorded(
      salesmanUid: _uid,
      routePlanId: 'plan',
      routeStopId: 'stop',
    );

    await _activate(_projectB);
    final outboxB = RouteStopOutbox();
    expect(await outboxB.readForUid(_uid), isEmpty);
    expect(await WorkSessionStore().read(_uid), isNull);
    await CartDraftCache.initialise();
    expect(
      CartDraftCache.readForRetailer(salesmanUid: _uid, retailerId: 'retailer'),
      isNull,
    );
    expect(
      (await GuidedVisitSessionStore.read(
        salesmanUid: _uid,
        routePlanId: 'plan',
        routeStopId: 'stop',
      )).outcomeRecorded,
      isFalse,
    );
    await outboxB.put(_event('event-b'));
    await _activate(_projectA);
    expect((await outboxA.readForUid(_uid)).single.eventId, 'event-a');
    expect((await sessionsA.read(_uid))?.sessionId, 'session-a');
    await CartDraftCache.initialise();
    expect(CartDraftCache.read(keyA)?.pendingOrderId, 'unsent-order-a');
    expect(
      (await GuidedVisitSessionStore.read(
        salesmanUid: _uid,
        routePlanId: 'plan',
        routeStopId: 'stop',
      )).outcomeRecorded,
      isTrue,
    );
    binding.reportData = {'sameUidProjectIsolation': 'passed'};
  });

  testWidgets('untagged work from this build migrates and still syncs', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    String part(String text) =>
        base64Url.encode(utf8.encode(text)).replaceAll('=', '');
    ProjectLocalStore.recoveryNotice.value = '';
    GuidedVisitSessionStore.resetRuntime();
    final event = _event('pre-upgrade-event');
    final outboxKey =
        'route_stop_outbox_v2_${part(_uid)}_${part('plan')}_'
        '${part(event.workSessionId)}_1';
    final guidedKey =
        'guided_visit.v2.${part(_uid)}.${part('plan')}.${part('stop')}'
        '.outcome_recorded';
    await prefs.setString(outboxKey, jsonEncode([event.toJson()]));
    await prefs.setString(
      'work_session_v1_$_uid',
      jsonEncode(
        const WorkSession(
          uid: _uid,
          sessionId: 'pre-upgrade-session',
          generation: 1,
          lastFixSequence: 0,
          status: WorkSessionLocalStatus.active,
        ).toMap(),
      ),
    );
    await prefs.setBool(guidedKey, true);
    await prefs.setString(
      'cart_draft_cache.v1',
      jsonEncode({
        '$_uid|retailer:retailer': {
          'salesmanUid': _uid,
          'retailerId': 'retailer',
          'pendingOrderId': 'pre-upgrade-order',
          'revision': 3,
          'items': [
            {'productId': 'p1', 'name': 'Product', 'qty': 2},
          ],
        },
        'other-uid|retailer:retailer': {
          'salesmanUid': 'other-uid',
          'retailerId': 'retailer',
          'pendingOrderId': 'other-order',
          'revision': 1,
          'items': [],
        },
      }),
    );

    expect(
      (await RouteStopOutbox().readForUid(_uid)).single.eventId,
      'pre-upgrade-event',
    );
    expect(
      (await WorkSessionStore().read(_uid))?.sessionId,
      'pre-upgrade-session',
    );
    expect(
      (await GuidedVisitSessionStore.read(
        salesmanUid: _uid,
        routePlanId: 'plan',
        routeStopId: 'stop',
      )).outcomeRecorded,
      isTrue,
    );
    await CartDraftCache.initialise();
    final draft = CartDraftCache.readForRetailer(
      salesmanUid: _uid,
      retailerId: 'retailer',
    );
    expect(draft?.pendingOrderId, 'pre-upgrade-order');
    expect(draft?.items.single['qty'], 2);

    await prefs.reload();
    for (final key in [outboxKey, 'work_session_v1_$_uid', guidedKey]) {
      expect(prefs.containsKey(key), isFalse, reason: key);
    }
    expect((jsonDecode(prefs.getString('cart_draft_cache.v1')!) as Map).keys, [
      'other-uid|retailer:retailer',
    ]);
    expect(
      prefs.getKeys().any(
        (key) => key.startsWith(ProjectLocalStore.recoveryPrefix),
      ),
      isFalse,
    );
    expect(ProjectLocalStore.recoveryNotice.value, isEmpty);
    await _activate(_projectB);
    expect(await RouteStopOutbox().readForUid(_uid), isEmpty);
    await _activate(_projectA);
    expect(await RouteStopOutbox().readForUid(_uid), hasLength(1));
  });

  testWidgets('untagged work of an account not signed in here stays put', (
    tester,
  ) async {
    ProjectLocalStore.recoveryNotice.value = '';
    final prefs = await SharedPreferences.getInstance();
    final original = jsonEncode(
      const WorkSession(
        uid: 'other-uid',
        sessionId: 'other-session',
        generation: 1,
        lastFixSequence: 0,
        status: WorkSessionLocalStatus.active,
      ).toMap(),
    );
    await prefs.setString('work_session_v1_other-uid', original);

    expect(await WorkSessionStore().read('other-uid'), isNull);
    await prefs.reload();
    expect(prefs.getString('work_session_v1_other-uid'), original);
    expect(
      prefs.getKeys().any(
        (key) => key.startsWith(ProjectLocalStore.recoveryPrefix),
      ),
      isFalse,
    );
    expect(ProjectLocalStore.recoveryNotice.value, isEmpty);
  });

  testWidgets('legacy outbox naming another owner is recovered, not replayed', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    String part(String text) =>
        base64Url.encode(utf8.encode(text)).replaceAll('=', '');
    final event = _event('unbound-event');
    final legacy =
        'route_stop_outbox_v2_${part(_uid)}_${part('plan')}_'
        '${part(event.workSessionId)}_1';
    final raw = jsonEncode([
      {...event.toJson(), 'uid': 'someone-else'},
    ]);
    await prefs.setString(legacy, raw);
    expect(await RouteStopOutbox().readForUid(_uid), isEmpty);
    await prefs.reload();
    expect(prefs.containsKey(legacy), isFalse);
    expect(
      prefs
          .getKeys()
          .where((key) => key.startsWith(ProjectLocalStore.recoveryPrefix))
          .map(prefs.getString)
          .any((value) => value?.contains('unbound-event') ?? false),
      isTrue,
    );
    expect(ProjectLocalStore.recoveryNotice.value, isNotEmpty);
  });

  testWidgets('collision preserves both copies and migration retries safely', (
    tester,
  ) async {
    final store = ProjectLocalStore(projectId: _projectA);
    final prefs = await SharedPreferences.getInstance();
    await store.write(_uid, 'work_session', jsonEncode({'unsent': 'new'}));
    final legacy = 'work_session_v1_$_uid';
    final original = jsonEncode({
      'projectId': _projectA,
      'uid': _uid,
      'unsent': 'old',
    });
    await prefs.setString(legacy, original);
    expect(
      await store.read(_uid, 'work_session', legacyKey: legacy),
      jsonEncode({'unsent': 'new'}),
    );
    await prefs.reload();
    expect(
      prefs.containsKey(legacy) ||
          prefs
              .getKeys()
              .where((key) => key.startsWith(ProjectLocalStore.recoveryPrefix))
              .map(prefs.getString)
              .any((raw) => raw?.contains('old') ?? false),
      isTrue,
    );
    expect(
      await store.read(_uid, 'work_session', legacyKey: legacy),
      jsonEncode({'unsent': 'new'}),
    );
  });

  testWidgets('tagged session migrates only to its matching project', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final session = const WorkSession(
      uid: _uid,
      sessionId: 'tagged-a',
      generation: 1,
      lastFixSequence: 0,
      status: WorkSessionLocalStatus.active,
    );
    await prefs.setString(
      'work_session_v1_$_uid',
      jsonEncode({...session.toMap(), 'projectId': _projectA}),
    );
    await _activate(_projectB);
    expect(await WorkSessionStore().read(_uid), isNull);
    await _activate(_projectA);
    expect((await WorkSessionStore().read(_uid))?.sessionId, 'tagged-a');
  });

  for (final failure in ['rejected copy', 'missing readback']) {
    testWidgets('$failure retains unbound work and retry recovers it', (
      tester,
    ) async {
      final platform = _FailingPreferences();
      SharedPreferencesStorePlatform.instance = platform;
      final prefs = await SharedPreferences.getInstance();
      await prefs.setString('work_session_v1_$_uid', 'unsent raw legacy');
      platform.failCopy = failure == 'rejected copy';
      platform.loseCopy = failure == 'missing readback';
      expect(await WorkSessionStore().read(_uid), isNull);
      await prefs.reload();
      expect(prefs.getString('work_session_v1_$_uid'), 'unsent raw legacy');
      platform.failCopy = false;
      platform.loseCopy = false;
      expect(await WorkSessionStore().read(_uid), isNull);
      await prefs.reload();
      expect(prefs.containsKey('work_session_v1_$_uid'), isFalse);
      expect(
        prefs
            .getKeys()
            .where((key) => key.startsWith(ProjectLocalStore.recoveryPrefix))
            .map(prefs.getString)
            .any((value) => value?.contains('unsent raw legacy') ?? false),
        isTrue,
      );
    });
  }

  testWidgets('wrong-project envelope never becomes replayable', (
    tester,
  ) async {
    final prefs = await SharedPreferences.getInstance();
    final store = ProjectLocalStore(projectId: _projectA);
    await prefs.setString(
      store.key(_uid, 'outcomes'),
      jsonEncode({
        'version': 1,
        'projectId': _projectB,
        'uid': _uid,
        'data': jsonEncode([
          {'unsent': 'project-b'},
        ]),
      }),
    );
    expect(await store.read(_uid, 'outcomes'), isNull);
    await prefs.reload();
    expect(
      prefs
          .getKeys()
          .where((key) => key.startsWith(ProjectLocalStore.recoveryPrefix))
          .map(prefs.getString)
          .any((value) => value?.contains('project-b') ?? false),
      isTrue,
    );
  });

  testWidgets('failed recovery blocks replacement of a damaged unsent draft', (
    tester,
  ) async {
    final platform = _FailingPreferences();
    SharedPreferencesStorePlatform.instance = platform;
    final prefs = await SharedPreferences.getInstance();
    final key = CartDraftCache.keyFor(salesmanUid: _uid, retailerId: 'damaged');
    final original = jsonEncode({
      'version': 1,
      'projectId': _projectA,
      'uid': _uid,
      'data': '{damaged unsent draft bytes',
    });
    await prefs.setString(key, original);
    platform.failCopy = true;
    await expectLater(CartDraftCache.initialise(uid: _uid), throwsStateError);
    await prefs.reload();
    expect(prefs.getString(key), original);
    platform.failCopy = false;
    await CartDraftCache.initialise(uid: _uid);
    await prefs.reload();
    expect(prefs.containsKey(key), isFalse);
    expect(
      prefs
          .getKeys()
          .where((key) => key.startsWith(ProjectLocalStore.recoveryPrefix))
          .map(prefs.getString)
          .any(
            (value) => value?.contains('damaged unsent draft bytes') ?? false,
          ),
      isTrue,
    );
  });

  testWidgets(
    'reloaded login editing first draft preserves second unsent draft',
    (tester) async {
      await CartDraftCache.initialise(uid: _uid);
      final first = CartDraftCache.keyFor(
        salesmanUid: _uid,
        retailerId: 'first',
      );
      final second = CartDraftCache.keyFor(
        salesmanUid: _uid,
        retailerId: 'second',
      );
      await CartDraftCache.saveAndWait(
        first,
        CartDraftSnapshot(
          salesmanUid: _uid,
          retailerId: 'first',
          pendingOrderId: 'unsent-first',
        ),
      );
      await CartDraftCache.saveAndWait(
        second,
        CartDraftSnapshot(
          salesmanUid: _uid,
          retailerId: 'second',
          pendingOrderId: 'unsent-second',
        ),
      );
      CartDraftCache.resetRuntime();
      await CartDraftCache.initialise(uid: _uid);
      expect(CartDraftCache.read(first)?.pendingOrderId, 'unsent-first');
      await CartDraftCache.saveAndWait(
        first,
        CartDraftCache.read(first)!.copyWith(revision: 2),
      );
      CartDraftCache.resetRuntime();
      await CartDraftCache.initialise(uid: _uid);
      expect(CartDraftCache.read(first)?.revision, 2);
      expect(CartDraftCache.read(second)?.pendingOrderId, 'unsent-second');
      await _activate(_projectB);
      CartDraftCache.resetRuntime();
      await CartDraftCache.saveAndWait(
        first,
        CartDraftSnapshot(
          salesmanUid: _uid,
          retailerId: 'first',
          pendingOrderId: 'late-first-a',
        ),
      );
      expect(CartDraftCache.read(first), isNull);
      await _activate(_projectA);
      CartDraftCache.resetRuntime();
      await CartDraftCache.initialise(uid: _uid);
      expect(CartDraftCache.read(first)?.pendingOrderId, 'late-first-a');
      expect(CartDraftCache.read(second)?.pendingOrderId, 'unsent-second');
    },
  );

  testWidgets('real queued outcome from A cannot replay under same UID in B', (
    tester,
  ) async {
    final user = UserModel.fromMap({
      'staffId': 'staff',
      'branchId': 'branch',
      'role': 'salesman',
    }, _uid);
    final brief = VisitBrief.fromMap('brief', {
      'retailerId': 'retailer',
      'retailerName': 'Synthetic outlet',
      'salesmanUid': _uid,
      'salesmanCode': 'staff',
      'branchId': 'branch',
      'topInsights': [
        {
          'issueId': 'issue',
          'issueKey': 'demand_drop::retailer::product',
          'type': 'demand_drop',
          'productId': 'product',
          'productName': 'Synthetic item',
        },
      ],
    });
    final serviceA = SalesVisitCopilotService(
      firestore: FirebaseFirestore.instance,
    );
    final queued = await serviceA.queueOutcome(
      user: user,
      branchId: 'branch',
      planId: 'plan',
      stopId: 'stop',
      brief: brief,
      insight: brief.topInsights.single,
      reasonCode: 'retailer_busy',
      note: '',
      replacementProductId: '',
      isOnline: false,
    );
    expect(queued.synced, isFalse);
    expect(serviceA.pendingCount, 1);
    await _activate(_projectB);
    expect(FirebaseAuth.instance.currentUser?.uid, _uid);
    final serviceB = SalesVisitCopilotService(
      firestore: FirebaseFirestore.instance,
    );
    await serviceB.initialiseForUser(_uid);
    expect(serviceB.pendingCount, 0);
    await serviceA.flushPending(isOnline: true, force: true);
    final savedA = await ProjectLocalStore(
      projectId: _projectA,
    ).read(_uid, 'outcomes');
    expect(savedA, contains(queued.outcomeId));
    expect(
      await ProjectLocalStore(projectId: _projectB).read(_uid, 'outcomes'),
      isNull,
    );
    await _activate(_projectA);
    final restored = SalesVisitCopilotService(
      firestore: FirebaseFirestore.instance,
    );
    await restored.initialiseForUser(_uid);
    expect(restored.pendingCount, 1);
    serviceA.dispose();
    serviceB.dispose();
    restored.dispose();
  });
}
