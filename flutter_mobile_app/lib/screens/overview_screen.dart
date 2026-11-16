import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import '../widgets/phone_status_strip.dart';
import 'package:fmcg_sales/models/user_model.dart' show UserModel;
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import '../providers/auth_provider.dart';
import '../copilot/mobile_copilot_page.dart';
import '../services/cart_draft_cache.dart';
import '../services/route_plan_service.dart';
import '../widgets/home_action_banner.dart';
import '../models/assigned_route_plan.dart';
import '../utils/demo_data.dart';
import '../utils/assigned_route_lifecycle.dart';
import '../utils/planner_marketplaces.dart';
import 'order_history_screen.dart';
import 'stuck_work_screen.dart';
import 'profile_screen.dart';
import 'add_to_cart.dart';
import 'assigned_route_screen.dart';
import 'order_cart_screen.dart' show OrderCartScreen;
import 'order_signature_screen.dart' show OrderSignatureScreen;
import 'planner_screen.dart';
import '../models/guided_visit_context.dart';
import '../services/sales_visit_copilot_service.dart';
import 'guided_visit_screen.dart';
import 'dart:async';
import '../theme/app_theme.dart';
import '../widgets/long_name_text.dart';

DateTime? _asDateTime(dynamic value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(value.toString());
}

int _readProgress(dynamic value) {
  if (value is int) return value;
  return int.tryParse(value?.toString() ?? '0') ?? 0;
}

String overviewGreetingFor(DateTime now) {
  if (now.hour < 5 || now.hour >= 21) return 'Good night';
  if (now.hour < 12) return 'Good morning';
  if (now.hour < 17) return 'Good afternoon';
  return 'Good evening';
}

String _normalizedLookupValue(dynamic value) {
  return (value ?? '').toString().trim().toLowerCase();
}

String _textValue(dynamic value) {
  final String text = (value ?? '').toString().trim();
  return text.toLowerCase() == 'null' ? '' : text;
}

String _docIdOf(Map<String, dynamic> data) => (data['docId'] ?? '').toString();

AssignedRoutePlan? assignedPlanForToday(List<AssignedRoutePlan>? plans) {
  if (plans == null || plans.isEmpty) return null;
  final List<AssignedRoutePlan> candidates = activeAssignedRouteCandidates(
    plans,
    now: DateTime.now(),
  );
  return candidates.isEmpty ? null : candidates.first;
}

List<AssignedRouteStop> assignedStopsForToday(List<AssignedRoutePlan>? plans) {
  return assignedPlanForToday(plans)?.dayFor(DateTime.now())?.stops ??
      const <AssignedRouteStop>[];
}

bool assignedRouteAccepted(
  RouteProgress? progress, {
  bool progressFailed = false,
}) {
  if (progressFailed) return true;
  final String status = (progress?.status ?? '').trim().toLowerCase();
  return status == 'accepted' ||
      status == 'in_progress' ||
      status == 'completed';
}

int assignedPendingStopCount(
  Iterable<AssignedRouteStop> stops,
  RouteProgress? progress, {
  bool progressFailed = false,
}) {
  if (!assignedRouteAccepted(progress, progressFailed: progressFailed)) {
    return 0;
  }
  int pending = 0;
  for (final AssignedRouteStop stop in stops) {
    final String status =
        (progress?.statusFor(stop.stopId, stop.status) ?? stop.status)
            .trim()
            .toLowerCase();
    if (status != 'completed' && status != 'skipped') pending += 1;
  }
  return pending;
}

String assignedStopStatusLabel(String raw) {
  switch (raw.trim().toLowerCase()) {
    case 'completed':
      return 'Done';
    case 'skipped':
      return 'Skipped';
    case 'arrived':
      return 'Arrived';
    case 'in_progress':
      return 'In progress';
    case '':
    case 'not_started':
      return 'Not started';
    default:
      return raw.trim();
  }
}

Stream<T> replayLatest<T>(Stream<T> Function() open) {
  final List<MultiStreamController<T>> listeners = <MultiStreamController<T>>[];
  StreamSubscription<T>? source;
  bool hasLatest = false;
  bool latestIsError = false;
  T? latest;
  Object? latestError;
  StackTrace? latestStack;
  return Stream<T>.multi((MultiStreamController<T> controller) {
    if (hasLatest) {
      if (latestIsError) {
        controller.addError(latestError!, latestStack);
      } else {
        controller.add(latest as T);
      }
    }
    listeners.add(controller);
    controller.onCancel = () {
      listeners.remove(controller);
      if (listeners.isEmpty) {
        source?.cancel();
        source = null;
        hasLatest = false;
        latest = null;
      }
    };
    source ??= open().listen(
      (T value) {
        hasLatest = true;
        latestIsError = false;
        latest = value;
        for (final MultiStreamController<T> listener in List.of(listeners)) {
          listener.add(value);
        }
      },
      onError: (Object error, StackTrace stack) {
        hasLatest = true;
        latestIsError = true;
        latestError = error;
        latestStack = stack;
        for (final MultiStreamController<T> listener in List.of(listeners)) {
          listener.addError(error, stack);
        }
      },
      onDone: () {
        source = null;
        for (final MultiStreamController<T> listener in List.of(listeners)) {
          listener.close();
        }
        listeners.clear();
      },
    );
  }, isBroadcast: true);
}

class OverviewStreams {
  OverviewStreams({
    required this.user,
    required this.uid,
    required this.visitDate,
  });

  final UserModel? user;
  final String uid;
  final String visitDate;
  final RoutePlanService _service = RoutePlanService();
  final Map<String, Stream<RouteProgress>> _progressStreams =
      <String, Stream<RouteProgress>>{};

  final ValueNotifier<bool> retailersPartlyRefused = ValueNotifier<bool>(false);

  late final Stream<List<Map<String, dynamic>>> retailers = replayLatest(
    () => watchAssignedRetailerRows(
      staffId: user?.staffId.trim() ?? '',
      uid: uid,
      branchId: user?.branchId ?? '',
      partlyRefused: retailersPartlyRefused,
    ),
  );

  late final Stream<QuerySnapshot<Map<String, dynamic>>> visits = replayLatest(
    () => uid.isEmpty
        ? const Stream<QuerySnapshot<Map<String, dynamic>>>.empty()
        : FirebaseFirestore.instance
              .collection('visits')
              .where('ownerUid', isEqualTo: uid)
              .where('date', isEqualTo: visitDate)
              .limit(500)
              .snapshots(includeMetadataChanges: true),
  );

  late final Stream<List<AssignedRoutePlan>> plans = replayLatest(
    () => user == null
        ? const Stream<List<AssignedRoutePlan>>.empty()
        : _service.watchAssignedPublishedRoutes(user!),
  );

  Stream<RouteProgress>? progressFor(AssignedRoutePlan? plan) {
    if (plan == null || uid.isEmpty) return null;
    return _progressStreams.putIfAbsent(
      plan.id,
      () => replayLatest(
        () => _service.watchProgress(planId: plan.id, salesmanUid: uid),
      ),
    );
  }
}

Stream<List<Map<String, dynamic>>> watchAssignedRetailerRows({
  required String staffId,
  required String uid,
  String branchId = '',
  ValueNotifier<bool>? partlyRefused,
}) {
  if (!isUsableSalesmanAssignment(staffId) &&
      !isUsableSalesmanAssignment(uid)) {
    return Stream<List<Map<String, dynamic>>>.value(
      const <Map<String, dynamic>>[],
    );
  }
  return watchAssignedRetailers(
    firestore: FirebaseFirestore.instance,
    staffId: staffId,
    uid: uid,
    branchId: branchId,
    partlyRefused: partlyRefused,
  );
}

bool isUsableSalesmanAssignment(String? value) =>
    value?.trim().isNotEmpty == true;

class PendingSignOffFollowUp {
  const PendingSignOffFollowUp({
    required this.retailer,
    required this.visit,
    required this.retailerId,
    required this.visitId,
  });

  final Map<String, dynamic> retailer;
  final Map<String, dynamic> visit;
  final String retailerId;
  final String visitId;
}

List<PendingSignOffFollowUp> buildPoFollowUps(
  Iterable<Map<String, dynamic>> visits,
  Iterable<Map<String, dynamic>> retailers,
) {
  final Map<String, Map<String, dynamic>> retailerById =
      <String, Map<String, dynamic>>{};
  final Map<String, String> retailerIdByLookupId = <String, String>{};
  final Map<String, String> retailerIdByName = <String, String>{};
  final Set<String> excludedRetailerIds = <String>{};
  final Set<String> excludedRetailerNames = <String>{};
  for (final retailer in retailers) {
    final String retailerIdField = _textValue(retailer['retailerId']);
    final String storedRetailerId = retailerIdField.isNotEmpty
        ? retailerIdField
        : _textValue(retailer['docId']);
    final String id = _normalizedLookupValue(storedRetailerId);
    final String name = _normalizedLookupValue(retailer['retailerName']);
    if (id.isNotEmpty) {
      retailerById[id] = retailer;
      retailerIdByLookupId[id] = storedRetailerId;
    }
    if (name.isNotEmpty && id.isNotEmpty) retailerIdByName[name] = id;
    if (!isOperationalRetailerRecord(retailer)) {
      if (id.isNotEmpty) excludedRetailerIds.add(id);
      if (name.isNotEmpty) excludedRetailerNames.add(name);
    }
  }

  final Map<String, PendingSignOffFollowUp> pending =
      <String, PendingSignOffFollowUp>{};
  for (final visit in visits) {
    final int progress = _readProgress(visit['progress']);
    if (progress <= 0 || progress == 3) continue;
    final String name = _normalizedLookupValue(visit['marketplace']);
    final String storedVisitRetailerId = _textValue(visit['retailerId']);
    final String id = _normalizedLookupValue(storedVisitRetailerId);
    final String identity = id.isNotEmpty ? id : retailerIdByName[name] ?? name;
    if (identity.isEmpty ||
        excludedRetailerIds.contains(identity) ||
        excludedRetailerNames.contains(name)) {
      continue;
    }
    final String visitId = (visit['docId'] ?? '').toString().trim();
    if (visitId.isEmpty) continue;
    final retailer = retailerById[identity];
    if (retailer == null) continue;
    final String retailerId =
        retailerIdByLookupId[identity] ?? storedVisitRetailerId;
    if (retailerId.isEmpty) continue;
    pending.putIfAbsent(
      identity,
      () => PendingSignOffFollowUp(
        retailer: retailer,
        visit: visit,
        retailerId: retailerId,
        visitId: visitId,
      ),
    );
  }
  return pending.values.toList(growable: false);
}

int countPoFollowUps(
  Iterable<Map<String, dynamic>> visits,
  Iterable<Map<String, dynamic>> retailers,
) {
  return buildPoFollowUps(visits, retailers).length;
}

List<Map<String, dynamic>> _readMapList(Object? raw) {
  if (raw is! List) return const <Map<String, dynamic>>[];
  return raw
      .whereType<Map>()
      .map((item) => Map<String, dynamic>.from(item))
      .toList();
}

Map<String, dynamic> _readMap(Object? raw) {
  return raw is Map ? Map<String, dynamic>.from(raw) : <String, dynamic>{};
}

Map<String, Map<String, dynamic>> _readNestedMap(Object? raw) {
  if (raw is! Map) return <String, Map<String, dynamic>>{};
  return raw.map<String, Map<String, dynamic>>((key, value) {
    return MapEntry<String, Map<String, dynamic>>(
      key.toString(),
      _readMap(value),
    );
  });
}

class RetailerRoute {
  final String retailerId;
  final String retailerName;
  final String address;
  final String status;
  final int progress;
  final List<String> pendingSignatures;
  final DateTime? step1At;
  final DateTime? step2At;
  final DateTime? step3At;
  final String? plannedTime;
  final String? plannedPurpose;
  final String? visitId;
  final List<Map<String, dynamic>> cartDraftItems;
  final List<Map<String, dynamic>> signatureDraftItems;
  final Map<String, Map<String, dynamic>> signatureDraftSignatures;
  final String signatureDraftPendingOrderId;

  RetailerRoute({
    required this.retailerId,
    required this.retailerName,
    required this.address,
    this.status = 'Pending',
    this.progress = 0,
    this.pendingSignatures = const [],
    this.step1At,
    this.step2At,
    this.step3At,
    this.plannedTime,
    this.plannedPurpose,
    this.visitId,
    this.cartDraftItems = const [],
    this.signatureDraftItems = const [],
    this.signatureDraftSignatures = const {},
    this.signatureDraftPendingOrderId = '',
  });

  factory RetailerRoute.fromFirestore(DocumentSnapshot doc) {
    final Object? raw = doc.data();
    return RetailerRoute.fromMap(<String, dynamic>{
      if (raw is Map) ...Map<String, dynamic>.from(raw),
      'docId': doc.id,
    });
  }

  factory RetailerRoute.fromMap(Map<String, dynamic> data) {
    final signatureDraft = _readMap(data['signatureDraft']);

    final int fetchedProgress = data['progress'] is int
        ? data['progress'] as int
        : int.tryParse(data['progress']?.toString() ?? '0') ?? 0;

    final pending = (data['pendingSignatures'] as List<dynamic>? ?? [])
        .map((e) => e.toString())
        .toList();

    DateTime? toDateTime(dynamic v) {
      if (v == null) return null;
      if (v is Timestamp) return v.toDate();
      return null;
    }

    String resolvedStatus;
    if (fetchedProgress == 3) {
      resolvedStatus = 'Done';
    } else if (fetchedProgress == 4) {
      resolvedStatus = pending.isEmpty
          ? 'Submission Pending'
          : 'Pending Signature';
    } else {
      resolvedStatus = data['status'] as String? ?? 'Pending';
    }

    return RetailerRoute(
      retailerId: data['retailerId'] as String? ?? _docIdOf(data),
      retailerName: data['retailerName'] as String? ?? _docIdOf(data),
      address: data['address'] as String? ?? '',
      status: resolvedStatus,
      progress: fetchedProgress.clamp(0, 4),
      pendingSignatures: pending,
      step1At: toDateTime(data['step1At']),
      step2At: toDateTime(data['step2At']),
      step3At: toDateTime(data['step3At']),
      signatureDraftItems: _readMapList(signatureDraft['items']),
      signatureDraftSignatures: _readNestedMap(signatureDraft['signatures']),
      signatureDraftPendingOrderId:
          signatureDraft['pendingOrderId']?.toString() ?? '',
    );
  }

  RetailerRoute withVisitPlan({
    required String visitId,
    String? time,
    String? purpose,
    String status = 'Planned',
    int progress = 0,
    List<String> pendingSignatures = const [],
    DateTime? step1At,
    DateTime? step2At,
    DateTime? step3At,
    List<Map<String, dynamic>> cartDraftItems = const [],
    List<Map<String, dynamic>> signatureDraftItems = const [],
    Map<String, Map<String, dynamic>> signatureDraftSignatures = const {},
    String signatureDraftPendingOrderId = '',
  }) {
    return RetailerRoute(
      retailerId: retailerId,
      retailerName: retailerName,
      address: address,
      status: status,
      progress: progress,
      pendingSignatures: pendingSignatures,
      step1At: step1At,
      step2At: step2At,
      step3At: step3At,
      plannedTime: time,
      plannedPurpose: purpose,
      visitId: visitId,
      cartDraftItems: cartDraftItems,
      signatureDraftItems: signatureDraftItems,
      signatureDraftSignatures: signatureDraftSignatures,
      signatureDraftPendingOrderId: signatureDraftPendingOrderId,
    );
  }
}

class OverviewScreen extends StatefulWidget {
  const OverviewScreen({super.key});

  @override
  State<OverviewScreen> createState() => _OverviewScreenState();
}

class _OverviewScreenState extends State<OverviewScreen> {
  OverviewStreams? _streams;
  String _streamsKey = '';

  static String _dateString(DateTime dt) {
    return '${dt.year}-${dt.month.toString().padLeft(2, '0')}-${dt.day.toString().padLeft(2, '0')}';
  }

  OverviewStreams _streamsFor(BuildContext context) {
    context.select<AuthProvider, String>(
      (AuthProvider auth) => '${auth.user?.uid}|${auth.user?.staffId.trim()}',
    );
    final UserModel? user = context.read<AuthProvider>().user;
    final String uid =
        (FirebaseAuth.instance.currentUser?.uid ?? user?.uid ?? '').trim();
    final String visitDate = _dateString(DateTime.now());
    final String key = '$uid|${user?.staffId.trim() ?? ''}|$visitDate';
    if (_streams == null || _streamsKey != key) {
      _streamsKey = key;
      _streams = OverviewStreams(user: user, uid: uid, visitDate: visitDate);
    }
    return _streams!;
  }

  void _reviewStuckWork(BuildContext context, OverviewStreams streams) {
    final UserModel? user = streams.user;
    if (user == null || streams.uid.isEmpty) return;
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (_) => StuckWorkScreen(
          uid: streams.uid,
          projectId: FirebaseFirestore.instance.app.options.projectId,
          resendStops: (String planId) async {
            final List<AssignedRoutePlan> plans = await streams.plans.first
                .timeout(const Duration(seconds: 10));
            final AssignedRoutePlan? plan = plans
                .where((AssignedRoutePlan row) => row.id == planId)
                .firstOrNull;
            final Stream<RouteProgress>? progressStream = streams.progressFor(
              plan,
            );
            if (plan == null || progressStream == null) return false;
            final RouteProgress progress = await progressStream.first.timeout(
              const Duration(seconds: 10),
            );
            await RoutePlanService().retryPendingStopEvents(
              plan: plan,
              user: user,
              progress: progress,
            );
            return true;
          },
        ),
      ),
    );
  }

  void _openPlanner(BuildContext context) {
    Navigator.of(
      context,
    ).push(MaterialPageRoute(builder: (context) => const PlannerScreen()));
  }

  @override
  Widget build(BuildContext context) {
    final OverviewStreams streams = _streamsFor(context);
    return ScootPhoneScaffold(
      appBar: _HomeAppBar(streams: streams),
      statusStrip: const PhoneStatusStrip(),
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: [
          HomeActionBanner(
            onReviewAttention: () => _reviewStuckWork(context, streams),
            onViewOrders: () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const OrderHistoryScreen(),
              ),
            ),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.all(ScootSpace.phoneGutter),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: [
                  _OverviewCards(streams: streams),
                  const SizedBox(height: 8),
                  ScootSectionHeader(
                    title: 'Today',
                    actionLabel: 'Planner',
                    actionIcon: ScootIcons.calendar,
                    onAction: () => _openPlanner(context),
                  ),
                  AssignedRoutePreview(
                    routes: streams.plans,
                    progressFor: streams.progressFor,
                  ),
                  const SizedBox(height: 12),
                  _RouteList(streams: streams),
                ],
              ),
            ),
          ),
        ],
      ),
      primaryAction: ScootPrimaryActionBar(
        label: 'Plan a visit',
        icon: ScootIcons.add,
        onPressed: () => _openPlanner(context),
      ),
      bottomNav: const AppBottomNav(currentIndex: 0),
    );
  }
}

class _OverviewCards extends StatefulWidget {
  const _OverviewCards({required this.streams});

  final OverviewStreams streams;

  @override
  State<_OverviewCards> createState() => _OverviewCardsState();
}

bool _completeOverviewQuery(QuerySnapshot<Map<String, dynamic>>? snapshot) =>
    snapshot != null &&
    !snapshot.metadata.isFromCache &&
    !snapshot.metadata.hasPendingWrites &&
    snapshot.docs.length < 500;

class _OverviewCardsState extends State<_OverviewCards> {
  Stream<QuerySnapshot<Map<String, dynamic>>>? _orderStream;
  String _streamKey = '';

  Stream<QuerySnapshot<Map<String, dynamic>>> _todayOrderStream(String uid) {
    final String ownerUid = uid.trim();
    if (ownerUid.isEmpty) {
      return const Stream<QuerySnapshot<Map<String, dynamic>>>.empty();
    }
    final now = DateTime.now();
    final startOfToday = DateTime(now.year, now.month, now.day);
    final startOfTomorrow = startOfToday.add(const Duration(days: 1));

    return FirebaseFirestore.instance
        .collection('orders')
        .where('salesmanUid', isEqualTo: ownerUid)
        .where(
          'submittedAt',
          isGreaterThanOrEqualTo: Timestamp.fromDate(startOfToday),
        )
        .where('submittedAt', isLessThan: Timestamp.fromDate(startOfTomorrow))
        .limit(500)
        .snapshots(includeMetadataChanges: true);
  }

  int _pendingVisitCount(QuerySnapshot<Map<String, dynamic>> visitSnapshot) {
    return visitSnapshot.docs.where((doc) {
      final progress = _readProgress(doc.data()['progress']);
      return progress != 3;
    }).length;
  }

  int _poFollowUpCount(
    QuerySnapshot<Map<String, dynamic>> visitSnapshot,
    List<Map<String, dynamic>> retailerRows,
  ) {
    return countPoFollowUps(
      visitSnapshot.docs.map(
        (doc) => <String, dynamic>{...doc.data(), 'docId': doc.id},
      ),
      retailerRows,
    );
  }

  int _readProgress(dynamic value) {
    if (value is int) return value;
    return int.tryParse(value?.toString() ?? '0') ?? 0;
  }

  String _snapshotValue({
    required bool hasError,
    required bool hasData,
    required int? value,
    bool incomplete = false,
  }) {
    if (hasError) return '-';
    if (!hasData) return '...';
    if (incomplete || value == null) return 'Incomplete';
    return value.toString();
  }

  @override
  Widget build(BuildContext context) {
    final OverviewStreams streams = widget.streams;
    final String nextStreamKey = '${streams.uid}|${streams.visitDate}';
    if (_streamKey != nextStreamKey) {
      _streamKey = nextStreamKey;
      _orderStream = _todayOrderStream(streams.uid);
    }

    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: streams.visits,
      builder: (context, visitSnapshot) {
        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: streams.retailers,
          builder: (context, retailerSnapshot) {
            return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _orderStream,
              builder: (context, orderSnapshot) {
                return StreamBuilder<List<Map<String, dynamic>>>(
                  stream: streams.retailers,
                  builder: (context, assignedOutletSnapshot) {
                    final ordersToday = orderSnapshot.hasData
                        ? orderSnapshot.data!.docs.length
                        : null;
                    final pendingVisits =
                        visitSnapshot.hasData && !visitSnapshot.hasError
                        ? _pendingVisitCount(visitSnapshot.data!)
                        : null;
                    final followUpSnapshotsReady =
                        visitSnapshot.hasData && retailerSnapshot.hasData;
                    final followUpSnapshotsErrored =
                        visitSnapshot.hasError || retailerSnapshot.hasError;
                    final poFollowUps =
                        followUpSnapshotsReady && !followUpSnapshotsErrored
                        ? _poFollowUpCount(
                            visitSnapshot.data!,
                            retailerSnapshot.data!,
                          )
                        : null;
                    final ordersTodayValue = _snapshotValue(
                      hasError: orderSnapshot.hasError,
                      hasData: orderSnapshot.hasData,
                      value: ordersToday,
                      incomplete: !_completeOverviewQuery(orderSnapshot.data),
                    );
                    final poFollowUpValue = _snapshotValue(
                      hasError: followUpSnapshotsErrored,
                      hasData: followUpSnapshotsReady,
                      value: poFollowUps,
                      incomplete: !_completeOverviewQuery(visitSnapshot.data),
                    );
                    return StreamBuilder<List<AssignedRoutePlan>>(
                      stream: streams.plans,
                      builder: (context, planSnapshot) {
                        final AssignedRoutePlan? assignedPlan =
                            assignedPlanForToday(planSnapshot.data);
                        return StreamBuilder<RouteProgress>(
                          stream: streams.progressFor(assignedPlan),
                          builder: (context, progressSnapshot) {
                            final Set<String> outletKeys = <String>{
                              if (assignedOutletSnapshot.hasData)
                                for (final Map<String, dynamic> row
                                    in assignedOutletSnapshot.data!)
                                  if (isOperationalRetailerRecord(row))
                                    (row['retailerId'] ??
                                            row['retailer_id'] ??
                                            row['docId'] ??
                                            '')
                                        .toString(),
                            }..removeWhere((String key) => key.isEmpty);
                            final bool outletsReady =
                                assignedOutletSnapshot.hasData;
                            final String outletValue =
                                assignedOutletSnapshot.hasError
                                ? '-'
                                : outletsReady
                                ? outletKeys.length.toString()
                                : '...';
                            final String pendingValue = visitSnapshot.hasError
                                ? '-'
                                : !visitSnapshot.hasData
                                ? '...'
                                : !_completeOverviewQuery(visitSnapshot.data) ||
                                      planSnapshot.hasError ||
                                      progressSnapshot.hasError
                                ? 'Incomplete'
                                : !planSnapshot.hasData ||
                                      (assignedPlan != null &&
                                          !progressSnapshot.hasData)
                                ? '...'
                                : ((pendingVisits ?? 0) +
                                          assignedPendingStopCount(
                                            assignedStopsForToday(
                                              planSnapshot.data,
                                            ),
                                            progressSnapshot.data,
                                            progressFailed:
                                                progressSnapshot.hasError,
                                          ))
                                      .toString();
                            return _StatRow(
                              stats: <_StatData>[
                                _StatData(outletValue, 'Outlets', true),
                                _StatData(
                                  ordersTodayValue,
                                  'Orders today',
                                  true,
                                ),
                                _StatData(pendingValue, 'Visits left', false),
                                _StatData(poFollowUpValue, 'Follow-ups', false),
                              ],
                            );
                          },
                        );
                      },
                    );
                  },
                );
              },
            );
          },
        );
      },
    );
  }
}

class _RouteList extends StatefulWidget {
  const _RouteList({required this.streams});

  final OverviewStreams streams;

  @override
  State<_RouteList> createState() => _RouteListState();
}

class _RouteListState extends State<_RouteList> {
  final RoutePlanService _routeService = RoutePlanService();
  final SalesVisitCopilotService _copilotService = SalesVisitCopilotService();

  @override
  void initState() {
    super.initState();
    _initialiseCopilotUser();
  }

  @override
  void didUpdateWidget(covariant _RouteList oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.streams.uid != widget.streams.uid) _initialiseCopilotUser();
  }

  void _initialiseCopilotUser() {
    final String uid = widget.streams.uid;
    if (uid.isNotEmpty) unawaited(_copilotService.initialiseForUser(uid));
  }

  @override
  void dispose() {
    _copilotService.dispose();
    super.dispose();
  }

  List<RetailerRoute> _buildTodayRoutes(
    QuerySnapshot<Map<String, dynamic>> visitSnapshot,
    List<Map<String, dynamic>> retailerRows,
  ) {
    final Map<String, RetailerRoute> retailersByName =
        <String, RetailerRoute>{};
    final Set<String> excludedRetailerIds = <String>{};
    final Set<String> excludedRetailerNames = <String>{};
    for (final Map<String, dynamic> data in retailerRows) {
      final String docId = _docIdOf(data);
      final String id = _normalizeName(
        (data['retailerId'] ?? data['retailer_id'] ?? docId).toString(),
      );
      final String name = _normalizeName(
        (data['retailerName'] ?? data['retailer_name'] ?? docId).toString(),
      );
      if (!isOperationalRetailerRecord(data)) {
        if (id.isNotEmpty) excludedRetailerIds.add(id);
        if (name.isNotEmpty) excludedRetailerNames.add(name);
        continue;
      }
      if (name.isNotEmpty) {
        retailersByName[name] = RetailerRoute.fromMap(data);
      }
    }

    final visits = visitSnapshot.docs.toList()
      ..sort((a, b) {
        final aTime = a.data()['time'] as String? ?? '';
        final bTime = b.data()['time'] as String? ?? '';
        return aTime.compareTo(bTime);
      });

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> visibleVisits =
        visits
            .where((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              final Map<String, dynamic> data = doc.data();
              final String visitId = _normalizeName(
                (data['retailerId'] ?? data['retailer_id'] ?? '').toString(),
              );
              final String visitName = _normalizeName(
                (data['marketplace'] ?? doc.id).toString(),
              );
              return !excludedRetailerIds.contains(visitId) &&
                  !excludedRetailerNames.contains(visitName);
            })
            .toList(growable: false);

    return visibleVisits.map((doc) {
      final data = doc.data();
      final marketplace = data['marketplace'] as String? ?? doc.id;
      final matchedRetailer = retailersByName[_normalizeName(marketplace)];
      final pendingSignatures =
          (data['pendingSignatures'] as List<dynamic>? ?? [])
              .map((value) => value.toString())
              .toList();
      final cartDraftItems = _readMapList(data['cartDraftItems']);
      final signatureDraft = _readMap(data['signatureDraft']);
      final signatureDraftItems = _readMapList(signatureDraft['items']);
      final signatureDraftSignatures = _readNestedMap(
        signatureDraft['signatures'],
      );
      final signatureDraftPendingOrderId =
          signatureDraft['pendingOrderId']?.toString() ?? '';
      final progress = _readProgress(data['progress']).clamp(0, 4);
      final status = data['status'] as String? ?? 'Planned';

      if (matchedRetailer != null) {
        return matchedRetailer.withVisitPlan(
          visitId: doc.id,
          time: data['time'] as String?,
          purpose: data['purpose'] as String?,
          status: status,
          progress: progress,
          pendingSignatures: pendingSignatures,
          step1At: _asDateTime(data['step1At']),
          step2At: _asDateTime(data['step2At']),
          step3At: _asDateTime(data['step3At']),
          cartDraftItems: cartDraftItems,
          signatureDraftItems: signatureDraftItems,
          signatureDraftSignatures: signatureDraftSignatures,
          signatureDraftPendingOrderId: signatureDraftPendingOrderId,
        );
      }

      return RetailerRoute(
        retailerId: marketplace,
        retailerName: marketplace,
        address: '',
        status: status,
        progress: progress,
        pendingSignatures: pendingSignatures,
        step1At: _asDateTime(data['step1At']),
        step2At: _asDateTime(data['step2At']),
        step3At: _asDateTime(data['step3At']),
        plannedTime: data['time'] as String?,
        plannedPurpose: data['purpose'] as String?,
        visitId: doc.id,
        cartDraftItems: cartDraftItems,
        signatureDraftItems: signatureDraftItems,
        signatureDraftSignatures: signatureDraftSignatures,
        signatureDraftPendingOrderId: signatureDraftPendingOrderId,
      );
    }).toList();
  }

  String _normalizeName(String value) {
    return value.trim().toLowerCase();
  }

  Future<void> _openAssignedStop(
    BuildContext context, {
    required AssignedRoutePlan? plan,
    required AssignedRouteStop stop,
    required RouteProgress? progress,
  }) async {
    final UserModel? user = context.read<AuthProvider>().user;

    void openAssignedRouteScreen() {
      Navigator.of(context).push(
        MaterialPageRoute<void>(builder: (_) => const AssignedRouteScreen()),
      );
    }

    if (plan == null || progress == null || user == null) {
      openAssignedRouteScreen();
      return;
    }

    final String status = progress.statusFor(stop.stopId, stop.status);
    if (!canUpdateAssignedStop(
      routeStatus: progress.status,
      stopStatus: status,
    )) {
      openAssignedRouteScreen();
      return;
    }

    final GuidedVisitContext visitContext = GuidedVisitContext(
      planId: plan.id,
      stopId: stop.stopId,
      branchId: plan.branchId,
      retailerLatitude: stop.lat,
      retailerLongitude: stop.lng,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: visitContext.routeName),
        builder: (_) => GuidedVisitScreen(
          plan: plan,
          stop: stop,
          user: user,
          stopStatus: status,
          progress: progress,
          service: _routeService,
          copilotService: _copilotService,
          brief: null,
          openCartInitially: false,
        ),
      ),
    );
  }

  void _openRetailer(BuildContext context, RetailerRoute r) {
    final salesmanUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    final draftKey = CartDraftCache.keyFor(
      salesmanUid: salesmanUid,
      retailerId: r.retailerId,
      visitId: r.visitId,
    );
    var draft = CartDraftCache.read(draftKey);
    if ((draft == null || draft.items.isEmpty) &&
        r.progress == 4 &&
        r.signatureDraftItems.isNotEmpty) {
      draft = CartDraftSnapshot(
        salesmanUid: salesmanUid,
        retailerId: r.retailerId,
        visitId: r.visitId,
        progress: 4,
        pendingOrderId: r.signatureDraftPendingOrderId,
        items: r.signatureDraftItems,
        signatures: r.signatureDraftSignatures,
      );
      CartDraftCache.save(draftKey, draft);
    }
    final cached = draft?.items.isNotEmpty == true
        ? draft!.items
        : (r.cartDraftItems.isNotEmpty ? r.cartDraftItems : null);
    final hasMatchingDraft = cached != null && cached.isNotEmpty;
    final stage = hasMatchingDraft
        ? (draft?.progress ?? r.progress)
        : r.progress;
    if ((stage == 3 || stage == 4) &&
        cached != null &&
        cached.isNotEmpty &&
        cached.every(
          (item) => (item['productId'] ?? '').toString().isNotEmpty,
        )) {
      final cartItems = cached
          .map(
            (item) => {
              ...item,
              'retailerId': item['retailerId'] ?? r.retailerId,
              'retailerName': item['retailerName'] ?? r.retailerName,
              'visitId': item['visitId'] ?? r.visitId,
            },
          )
          .toList();

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              OrderSignatureScreen(cartItems: cartItems, visitId: r.visitId),
        ),
      );
      return;
    }

    if (stage == 2 ||
        (cached != null &&
            cached.any(
              (item) => (item['productId'] ?? '').toString().isEmpty,
            ))) {
      if (cached == null || cached.isEmpty) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'The count for this visit is not saved on this phone. Select the items again.',
            ),
          ),
        );

        Navigator.push(
          context,
          MaterialPageRoute(
            builder: (_) => AddToCartPage(
              retailerId: r.retailerId,
              retailerName: r.retailerName,
              visitId: r.visitId,
            ),
          ),
        );
        return;
      }

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) => OrderCartScreen(
            selectedItems: cached,
            retailerId: r.retailerId,
            retailerName: r.retailerName,
            visitId: r.visitId,
          ),
        ),
      );
      return;
    }

    Navigator.push(
      context,
      MaterialPageRoute(
        builder: (_) => AddToCartPage(
          retailerId: r.retailerId,
          retailerName: r.retailerName,
          visitId: r.visitId,
          initialSelectedItems: cached ?? [],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AssignedRoutePlan>>(
      stream: widget.streams.plans,
      builder: (context, planSnapshot) =>
          _buildRouteSections(context, planSnapshot.data),
    );
  }

  Widget _buildRouteSections(
    BuildContext context,
    List<AssignedRoutePlan>? plans,
  ) {
    final AssignedRoutePlan? assignedPlan = assignedPlanForToday(plans);
    final List<AssignedRouteStop> assignedStops = assignedStopsForToday(plans);
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: widget.streams.visits,
      builder: (context, visitSnapshot) {
        if (visitSnapshot.connectionState == ConnectionState.waiting) {
          return const Center(
            child: Padding(
              padding: EdgeInsets.all(24),
              child: CircularProgressIndicator(color: Color(0xFF27AE60)),
            ),
          );
        }

        if (visitSnapshot.hasError) {
          return Center(
            child: Text(
              'Failed to load routes: ${visitSnapshot.error}',
              style: const TextStyle(color: AppColors.textRed, fontSize: 12),
            ),
          );
        }

        return StreamBuilder<List<Map<String, dynamic>>>(
          stream: widget.streams.retailers,
          builder: (context, retailerSnapshot) {
            if (retailerSnapshot.connectionState == ConnectionState.waiting) {
              return const Center(
                child: Padding(
                  padding: EdgeInsets.all(24),
                  child: CircularProgressIndicator(color: Color(0xFF27AE60)),
                ),
              );
            }

            if (retailerSnapshot.hasError) {
              return Center(
                child: Text(
                  'Failed to load retailers: ${retailerSnapshot.error}',
                  style: const TextStyle(
                    color: AppColors.textRed,
                    fontSize: 12,
                  ),
                ),
              );
            }

            final List<RetailerRoute> routes =
                visitSnapshot.hasData && retailerSnapshot.hasData
                ? _buildTodayRoutes(visitSnapshot.data!, retailerSnapshot.data!)
                : const <RetailerRoute>[];

            return StreamBuilder<RouteProgress>(
              stream: widget.streams.progressFor(assignedPlan),
              builder: (context, progressSnapshot) {
                final Widget visitList = TodayVisitList(
                  assignedStops:
                      assignedRouteAccepted(
                        progressSnapshot.data,
                        progressFailed: progressSnapshot.hasError,
                      )
                      ? assignedStops
                      : const <AssignedRouteStop>[],
                  assignedProgress: progressSnapshot.data,
                  personalVisits: routes,
                  waitingStopCount:
                      assignedRouteAccepted(
                        progressSnapshot.data,
                        progressFailed: progressSnapshot.hasError,
                      )
                      ? 0
                      : assignedStops.length,
                  onOpenAssignedStop: (AssignedRouteStop stop) =>
                      _openAssignedStop(
                        context,
                        plan: assignedPlan,
                        stop: stop,
                        progress: progressSnapshot.data,
                      ),
                  onOpenPersonalVisit: (RetailerRoute retailer) =>
                      _openRetailer(context, retailer),
                );
                return ValueListenableBuilder<bool>(
                  valueListenable: widget.streams.retailersPartlyRefused,
                  builder: (context, partlyRefused, _) => partlyRefused
                      ? Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            const Padding(
                              padding: EdgeInsets.only(bottom: 8),
                              child: Text(
                                'Some of your retailers could not be loaded. '
                                'Ask your admin to check your branch and '
                                'retailer assignments.',
                                style: TextStyle(
                                  color: AppColors.textRed,
                                  fontSize: 12,
                                ),
                              ),
                            ),
                            visitList,
                          ],
                        )
                      : visitList,
                );
              },
            );
          },
        );
      },
    );
  }
}

class TodayVisitList extends StatelessWidget {
  const TodayVisitList({
    super.key,
    required this.assignedStops,
    required this.assignedProgress,
    required this.personalVisits,
    this.waitingStopCount = 0,
    required this.onOpenAssignedStop,
    required this.onOpenPersonalVisit,
  });

  final int waitingStopCount;
  final List<AssignedRouteStop> assignedStops;
  final RouteProgress? assignedProgress;
  final List<RetailerRoute> personalVisits;
  final ValueChanged<AssignedRouteStop> onOpenAssignedStop;
  final ValueChanged<RetailerRoute> onOpenPersonalVisit;

  @override
  Widget build(BuildContext context) {
    if (assignedStops.isEmpty && personalVisits.isEmpty) {
      final ScootColors c = ScootColors.of(context);
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            waitingStopCount > 0
                ? "Accept your route to see today's stops."
                : 'No visits planned for today.',
            style: ScootType.bodyStrong.copyWith(color: c.ink),
          ),
          Text(
            waitingStopCount > 0
                ? 'Your route has $waitingStopCount stop${waitingStopCount == 1 ? '' : 's'} today.'
                : 'Plan a visit, or check your assigned route for the week.',
            style: ScootType.body.copyWith(color: c.text2),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ...assignedStops.map(
          (AssignedRouteStop stop) => VisitCard.assignedStop(
            stop: stop,
            status:
                assignedProgress?.statusFor(stop.stopId, stop.status) ??
                stop.status,
            onTap: () => onOpenAssignedStop(stop),
          ),
        ),
        ...personalVisits.map(
          (RetailerRoute retailer) => VisitCard.personalVisit(
            retailer: retailer,
            onTap: () => onOpenPersonalVisit(retailer),
          ),
        ),
      ],
    );
  }
}

class _HomeAppBar extends StatefulWidget implements PreferredSizeWidget {
  const _HomeAppBar({required this.streams});

  final OverviewStreams streams;

  @override
  Size get preferredSize => const Size.fromHeight(ScootSize.phoneAppBar);

  @override
  State<_HomeAppBar> createState() => _HomeAppBarState();
}

class _HomeAppBarState extends State<_HomeAppBar> {
  @override
  Widget build(BuildContext context) {
    final user = context.watch<AuthProvider>().user;
    final name = user?.name.split(' ').first ?? 'User';
    final now = DateTime.now();
    final greeting = overviewGreetingFor(now);
    final today = DateFormat('EEEE, d MMMM').format(now);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: widget.streams.retailers,
      builder: (context, retailerSnapshot) {
        return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
          stream: widget.streams.visits,
          builder: (context, visitSnapshot) {
            final List<Map<String, dynamic>> retailerRows =
                retailerSnapshot.data ?? const <Map<String, dynamic>>[];
            final followUps = visitSnapshot.hasData && retailerSnapshot.hasData
                ? buildPoFollowUps(
                    visitSnapshot.data!.docs.map(
                      (doc) => <String, dynamic>{
                        ...doc.data(),
                        'docId': doc.id,
                      },
                    ),
                    retailerRows,
                  )
                : const <PendingSignOffFollowUp>[];
            final bool followUpsComplete =
                !visitSnapshot.hasError &&
                !retailerSnapshot.hasError &&
                retailerSnapshot.hasData &&
                _completeOverviewQuery(visitSnapshot.data);
            final int followUpCount = followUps.length;

            return ScootPhoneAppBar(
              title: '$greeting, $name',
              subtitle: today,
              actions: <Widget>[
                ScootCopilotPill(onPressed: () => openMobileCopilot(context)),
                ScootPhoneAction(
                  icon: ScootIcons.notifications,
                  label: followUpCount > 0
                      ? 'Follow-up notifications, $followUpCount pending'
                      : 'Follow-up notifications',
                  onPressed: followUpsComplete
                      ? () => _handleNotificationTap(context, followUps)
                      : null,
                  count: !followUpsComplete
                      ? null
                      : followUpCount > 0
                      ? followUpCount
                      : null,
                  countLabel: '$followUpCount follow-up',
                ),
              ],
            );
          },
        );
      },
    );
  }

  void _handleNotificationTap(
    BuildContext context,
    List<PendingSignOffFollowUp> followUps,
  ) {
    if (followUps.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('No PO follow-ups at the moment.')),
      );
      return;
    }

    showModalBottomSheet(
      context: context,
      backgroundColor: Colors.white,
      shape: const RoundedRectangleBorder(
        borderRadius: BorderRadius.vertical(top: Radius.circular(16)),
      ),
      builder: (context) {
        return Padding(
          padding: const EdgeInsets.symmetric(vertical: 16, horizontal: 16),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: [
              Text(
                'PO Follow-ups',
                style: Theme.of(
                  context,
                ).textTheme.titleMedium?.copyWith(fontWeight: FontWeight.bold),
              ),
              const SizedBox(height: 12),
              ...followUps.map((followUp) {
                final data = followUp.retailer;
                final retailerName =
                    data['retailerName'] as String? ?? 'Unknown retailer';
                final savedAt =
                    _asDateTime(followUp.visit['signOffDraftAt']) ??
                    _asDateTime(followUp.visit['updatedAt']) ??
                    _asDateTime(followUp.visit['step3At']);
                final timestampText = savedAt != null
                    ? DateFormat('EEE, d MMM yyyy • h:mm a').format(savedAt)
                    : 'Draft saved time unknown';
                return ListTile(
                  contentPadding: EdgeInsets.zero,
                  title: LongNameText(retailerName),
                  subtitle: Text(timestampText),
                  leading: const Icon(Icons.store, color: Colors.red),
                  trailing: const Icon(Icons.chevron_right),
                  onTap: () {
                    Navigator.pop(context);
                    _openPendingSignOff(context, followUp);
                  },
                );
              }),
            ],
          ),
        );
      },
    );
  }

  void _openPendingSignOff(
    BuildContext context,
    PendingSignOffFollowUp followUp,
  ) {
    final currentRetailerId = followUp.retailerId;
    final visitId = followUp.visitId;
    final salesmanUid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    var draft = CartDraftCache.read(
      CartDraftCache.keyFor(
        salesmanUid: salesmanUid,
        retailerId: currentRetailerId,
        visitId: visitId,
      ),
    );
    if (draft == null || draft.items.isEmpty) {
      final data = followUp.visit;
      final signatureDraft = _readMap(data['signatureDraft']);
      final signatureDraftItems = _readMapList(signatureDraft['items']);
      if (_readProgress(data['progress']) == 4 &&
          signatureDraftItems.isNotEmpty) {
        draft = CartDraftSnapshot(
          salesmanUid: salesmanUid,
          retailerId: currentRetailerId,
          visitId: visitId,
          progress: 4,
          pendingOrderId: signatureDraft['pendingOrderId']?.toString() ?? '',
          items: signatureDraftItems,
          signatures: _readNestedMap(signatureDraft['signatures']),
        );
        CartDraftCache.save(
          CartDraftCache.keyFor(
            salesmanUid: salesmanUid,
            retailerId: currentRetailerId,
            visitId: visitId,
          ),
          draft,
        );
      }
    }
    final cached = draft?.items;
    final stage = draft?.progress;
    final hasMatchingDraft = cached != null && cached.isNotEmpty;

    if (cached != null &&
        cached.isNotEmpty &&
        hasMatchingDraft &&
        (stage == 3 || stage == 4)) {
      final cartItems = cached.map((item) {
        return {
          ...item,
          'retailerId': item['retailerId'] ?? currentRetailerId,
          'retailerName':
              item['retailerName'] ??
              followUp.retailer['retailerName'] ??
              followUp.visit['marketplace'] ??
              '',
        };
      }).toList();

      Navigator.push(
        context,
        MaterialPageRoute(
          builder: (_) =>
              OrderSignatureScreen(cartItems: cartItems, visitId: visitId),
        ),
      );
      return;
    }

    ScaffoldMessenger.of(context).showSnackBar(
      const SnackBar(
        content: Text(
          'Pending sign-off draft not available in this session. Open the retailer from routes to resume the draft.',
        ),
      ),
    );
  }
}

class _StatData {
  const _StatData(this.value, this.label, this.brand);

  final String value;
  final String label;
  final bool brand;
}

class _StatRow extends StatelessWidget {
  const _StatRow({required this.stats});

  final List<_StatData> stats;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: IntrinsicHeight(
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int index = 0; index < stats.length; index++)
              Expanded(
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    border: Border(
                      left: index == 0
                          ? BorderSide.none
                          : BorderSide(color: c.line),
                    ),
                  ),
                  child: Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 12,
                      vertical: 10,
                    ),
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          alignment: Alignment.centerLeft,
                          child: Text(
                            stats[index].value,
                            style: ScootType.kpi.copyWith(
                              fontSize: 22,
                              color: stats[index].brand ? c.brandText : c.ink,
                            ),
                          ),
                        ),
                        Text(
                          stats[index].label,
                          style: ScootType.small.copyWith(color: c.text2),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
      ),
    );
  }
}

enum VisitOrigin { assigned, personal }

ScootTone _visitToneFor({required int progress, required bool notVisited}) {
  if (progress == 3) return ScootTone.success;
  if (progress == 4) return ScootTone.warning;
  if (progress == 0 && notVisited) return ScootTone.neutral;
  return ScootTone.info;
}

class VisitCard extends StatelessWidget {
  final VisitOrigin origin;
  final String retailerName;
  final String address;

  final String detailLine;

  final int progress;

  final bool notVisited;
  final String statusLabel;
  final DateTime? step1At;
  final DateTime? step2At;
  final DateTime? step3At;
  final List<String> pendingSignatures;

  final int sequence;
  final VoidCallback onTap;

  const VisitCard._({
    super.key,
    required this.origin,
    required this.retailerName,
    required this.address,
    required this.detailLine,
    required this.progress,
    required this.notVisited,
    required this.statusLabel,
    required this.sequence,
    required this.onTap,
    this.step1At,
    this.step2At,
    this.step3At,
    this.pendingSignatures = const <String>[],
  });

  factory VisitCard.assignedStop({
    Key? key,
    required AssignedRouteStop stop,
    required String status,
    required VoidCallback onTap,
  }) {
    final String normalizedStatus = status.trim().toLowerCase();
    return VisitCard._(
      key: key,
      origin: VisitOrigin.assigned,
      retailerName: stop.retailerName,
      address: stop.address,
      detailLine: <String>[
        stop.estimatedArrival,
        stop.estimatedDeparture,
      ].where((String value) => value.isNotEmpty).join(' - '),
      progress: normalizedStatus == 'completed' ? 3 : 0,
      notVisited: normalizedStatus.isEmpty || normalizedStatus == 'not_started',
      statusLabel: assignedStopStatusLabel(status),
      sequence: stop.sequence,
      onTap: onTap,
    );
  }

  factory VisitCard.personalVisit({
    Key? key,
    required RetailerRoute retailer,
    required VoidCallback onTap,
  }) {
    final int progress = resumablePersonalVisitProgress(
      progress: retailer.progress,
      hasCountDraft: retailer.progress != 2 || _hasCountDraft(retailer),
    );
    return VisitCard._(
      key: key,
      origin: VisitOrigin.personal,
      retailerName: retailer.retailerName,
      address: retailer.address,
      detailLine: <String>[
        if ((retailer.plannedTime ?? '').isNotEmpty) retailer.plannedTime!,
        if ((retailer.plannedPurpose ?? '').isNotEmpty)
          retailer.plannedPurpose!,
      ].join(' - '),
      progress: progress,
      notVisited: progress == 0,
      statusLabel: _personalVisitStatusLabel(retailer, progress),
      step1At: retailer.step1At,
      step2At: progress >= 2 ? retailer.step2At : null,
      step3At: retailer.step3At,
      pendingSignatures: retailer.pendingSignatures,
      sequence: 0,
      onTap: onTap,
    );
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final ScootToneColors tone = c.tone(
      _visitToneFor(progress: progress, notVisited: notVisited),
    );
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Material(
        color: c.card,
        shape: RoundedRectangleBorder(
          borderRadius: ScootRadius.cardAll,
          side: BorderSide(color: c.line),
        ),
        child: InkWell(
          borderRadius: ScootRadius.cardAll,
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(14),
            child: Row(
              children: [
                Container(
                  width: 40,
                  height: 40,
                  decoration: BoxDecoration(
                    color: c.brandTint,
                    borderRadius: ScootRadius.controlAll,
                  ),
                  child: Icon(ScootIcons.store, color: c.brandText, size: 20),
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: [
                      Wrap(
                        spacing: 6,
                        runSpacing: 4,
                        children: <Widget>[
                          _VisitPill(
                            label: _visitOriginBadgeLabel(origin),
                            color: c.text2,
                          ),
                          if (sequence > 0)
                            _VisitPill(label: 'Stop $sequence', color: c.text2),
                        ],
                      ),
                      const SizedBox(height: 4),
                      Text(
                        retailerName,
                        style: ScootType.bodyStrong.copyWith(color: c.ink),
                      ),
                      if (address.isNotEmpty)
                        Text(
                          address,
                          style: ScootType.small.copyWith(color: c.text2),
                        ),
                      if (detailLine.isNotEmpty)
                        Text(
                          detailLine,
                          style: ScootType.small.copyWith(color: c.text2),
                        ),
                      const SizedBox(height: 10),
                      _DottedProgressBar(
                        progress: progress,
                        notVisited: notVisited,
                        step1At: step1At,
                        step2At: step2At,
                        step3At: step3At,
                      ),
                      const SizedBox(height: 6),
                      Text(
                        statusLabel,
                        style: ScootType.smallStrong.copyWith(
                          color: tone.foreground,
                        ),
                      ),
                      if (progress == 4 && pendingSignatures.isNotEmpty)
                        Text(
                          'Awaiting: ${pendingSignatures.join(', ')}',
                          style: ScootType.small.copyWith(color: tone.noteText),
                        ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                Icon(ScootIcons.chevronRight, color: c.text2),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

int resumablePersonalVisitProgress({
  required int progress,
  required bool hasCountDraft,
}) {
  return progress == 2 && !hasCountDraft ? 1 : progress;
}

bool _hasCountDraft(RetailerRoute retailer) {
  if (retailer.cartDraftItems.isNotEmpty) return true;
  final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
  if (uid.isEmpty) return false;
  try {
    final CartDraftSnapshot? draft = CartDraftCache.read(
      CartDraftCache.keyFor(
        salesmanUid: uid,
        retailerId: retailer.retailerId,
        visitId: retailer.visitId,
      ),
    );
    return draft != null && draft.items.isNotEmpty;
  } catch (_) {
    return false;
  }
}

String _visitOriginBadgeLabel(VisitOrigin origin) {
  return origin == VisitOrigin.assigned ? 'Assigned by Admin' : 'Personal plan';
}

String _personalVisitStatusLabel(RetailerRoute retailer, int shownProgress) {
  if (retailer.progress == 3) return 'Done - Order Submitted';
  final String? unsent = _unsentOrderLabel(retailer);
  if (unsent != null) return unsent;
  if (retailer.progress == 4) {
    return retailer.pendingSignatures.isEmpty
        ? 'Ready to Submit - All Signatures Collected'
        : 'Pending Signature';
  }
  if (retailer.progress == 0) {
    return retailer.status.toLowerCase() == 'planned'
        ? 'Planned - Not Started'
        : 'Not Visited — Salesman has not been here yet';
  }
  return 'In Progress - ${_visitStageLabel(shownProgress)}';
}

String? _unsentOrderLabel(RetailerRoute retailer) {
  final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
  if (uid.isEmpty) return null;
  final CartDraftSnapshot? draft;
  try {
    draft = CartDraftCache.read(
      CartDraftCache.keyFor(
        salesmanUid: uid,
        retailerId: retailer.retailerId,
        visitId: retailer.visitId,
      ),
    );
  } catch (_) {
    return null;
  }
  if (draft == null || draft.progress != 4 || draft.items.isEmpty) return null;
  if (draft.pendingOrderId.trim().isNotEmpty) {
    return 'Submission not confirmed - open to check';
  }
  final bool signed =
      draft.signatures.isNotEmpty &&
      draft.signatures.values.every(
        (Map<String, dynamic> signature) => signature['signed'] == true,
      );
  return signed
      ? 'Signed, not sent yet - open to submit'
      : 'Order not sent yet - open to continue';
}

String _visitStageLabel(int progress) {
  switch (progress) {
    case 1:
      return 'Selecting Items';
    case 2:
      return 'Counting Items';
    case 3:
      return 'Sign Off';
    case 4:
      return 'Submission Pending';
    default:
      return 'Not Started';
  }
}

class _VisitPill extends StatelessWidget {
  const _VisitPill({required this.label, required this.color});

  final String label;
  final Color color;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
      decoration: BoxDecoration(
        color: c.page,
        borderRadius: ScootRadius.controlAll,
        border: Border.all(color: c.line),
      ),
      child: Text(label, style: ScootType.small.copyWith(color: color)),
    );
  }
}

class _DottedProgressBar extends StatelessWidget {
  final int progress;

  final bool notVisited;
  final DateTime? step1At;
  final DateTime? step2At;
  final DateTime? step3At;

  const _DottedProgressBar({
    required this.progress,
    this.notVisited = false,
    this.step1At,
    this.step2At,
    this.step3At,
  });

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    const stages = ['Select', 'Count', 'Sign'];
    final timestamps = [step1At, step2At, step3At];
    final effectiveProgress = progress == 4 ? 3 : progress;
    final isPendingSig = progress == 4;
    return Row(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: List.generate(stages.length, (index) {
        final dotNumber = index + 1;
        final isCompleted = effectiveProgress >= dotNumber;
        final isAmber = isPendingSig && dotNumber == 3;
        final isNotVisitedActive = notVisited && dotNumber == 1;
        final ts = timestamps[index];
        final timeLabel = ts != null ? DateFormat('h:mm a').format(ts) : null;
        final Color dotColor = isAmber
            ? c.warning.foreground
            : isNotVisitedActive
            ? c.muted
            : isCompleted
            ? c.brand
            : c.line2;
        return Expanded(
          child: Column(
            children: [
              Row(
                children: [
                  Expanded(
                    child: index == 0
                        ? const SizedBox()
                        : _StepLine(
                            color: effectiveProgress >= dotNumber
                                ? c.brand
                                : c.line2,
                          ),
                  ),
                  Container(
                    width: 18,
                    height: 18,
                    decoration: BoxDecoration(
                      color: isAmber || isNotVisitedActive || isCompleted
                          ? dotColor
                          : c.card,
                      shape: BoxShape.circle,
                      border: Border.all(color: dotColor, width: 1.5),
                    ),
                    child: Center(
                      child: isAmber
                          ? const Icon(
                              ScootIcons.clock,
                              size: 10,
                              color: Colors.white,
                            )
                          : isNotVisitedActive
                          ? const Icon(
                              ScootIcons.person,
                              size: 10,
                              color: Colors.white,
                            )
                          : isCompleted
                          ? const Icon(
                              ScootIcons.check,
                              size: 12,
                              color: Colors.white,
                            )
                          : Text(
                              '$dotNumber',
                              style: ScootType.small.copyWith(
                                fontSize: 11,
                                color: c.text2,
                              ),
                            ),
                    ),
                  ),
                  Expanded(
                    child: index == stages.length - 1
                        ? const SizedBox()
                        : _StepLine(
                            color: effectiveProgress > dotNumber
                                ? c.brand
                                : c.line2,
                          ),
                  ),
                ],
              ),
              const SizedBox(height: 3),
              Text(
                stages[index],
                style: ScootType.small.copyWith(fontSize: 11, color: c.text2),
              ),
              if (timeLabel != null)
                Text(
                  timeLabel,
                  style: ScootType.smallStrong.copyWith(
                    fontSize: 11,
                    color: c.ink,
                  ),
                )
              else
                const SizedBox(height: 10),
            ],
          ),
        );
      }),
    );
  }
}

class _StepLine extends StatelessWidget {
  const _StepLine({required this.color});

  final Color color;

  @override
  Widget build(BuildContext context) {
    return Container(height: 2, color: color);
  }
}

enum AppBottomNavTransition { none, push, replace, popToRoot }

AppBottomNavTransition resolveAppBottomNavTransition({
  required int currentIndex,
  required int targetIndex,
}) {
  if (targetIndex == currentIndex) return AppBottomNavTransition.none;
  if (targetIndex == 0) return AppBottomNavTransition.popToRoot;
  return currentIndex == 0
      ? AppBottomNavTransition.push
      : AppBottomNavTransition.replace;
}

class AppBottomNav extends StatelessWidget {
  final int currentIndex;
  const AppBottomNav({super.key, required this.currentIndex});

  void _onTap(BuildContext context, int index) {
    final transition = resolveAppBottomNavTransition(
      currentIndex: currentIndex,
      targetIndex: index,
    );
    if (transition == AppBottomNavTransition.none) return;
    if (transition == AppBottomNavTransition.popToRoot) {
      Navigator.popUntil(context, (route) => route.isFirst);
      return;
    }

    Widget page;
    switch (index) {
      case 1:
        page = const AssignedRouteScreen();
        break;
      case 2:
        page = const OrderHistoryScreen();
        break;
      case 3:
        page = const ProfileScreen();
        break;
      default:
        return;
    }
    final route = MaterialPageRoute<void>(builder: (_) => page);
    if (transition == AppBottomNavTransition.push) {
      Navigator.push(context, route);
    } else {
      Navigator.pushReplacement(context, route);
    }
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ScootBottomNav(
          current: ScootPhoneTab.values[currentIndex],
          onSelect: (tab) => _onTap(context, tab.index),
        ),
      ],
    );
  }
}
