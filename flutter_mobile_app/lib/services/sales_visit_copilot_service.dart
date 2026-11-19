import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'company_lifecycle_monitor.dart';
import 'follow_up_service.dart';
import 'project_local_store.dart';

import '../models/follow_up_promise.dart';
import '../models/offline_operation.dart';
import '../models/user_model.dart';
import '../edition.dart';
import '../models/visit_brief.dart';
import '../utils/demo_data.dart';
import '../utils/retailer_memory.dart';

class OutcomeQueueResult {
  const OutcomeQueueResult({required this.outcomeId, required this.synced});

  final String outcomeId;
  final bool synced;
}

typedef RetailerMemoryLoad = Future<RetailerMemory?> Function();

class RetailerMemoryRequestCache {
  final Map<String, Future<RetailerMemory?>> _entries =
      <String, Future<RetailerMemory?>>{};
  final Map<String, Future<RetailerMemory?>> _lastGood =
      <String, Future<RetailerMemory?>>{};
  final Map<String, int> _generations = <String, int>{};

  Future<RetailerMemory?> load({
    required String uid,
    required String retailerId,
    required RetailerMemoryLoad loader,
    bool forceRefresh = false,
  }) {
    final String key = _key(uid, retailerId);
    final Future<RetailerMemory?>? existing = _entries[key];
    if (!forceRefresh && existing != null) return existing;

    final int generation = (_generations[key] ?? 0) + 1;
    _generations[key] = generation;
    final Future<RetailerMemory?> request = Future<RetailerMemory?>.sync(
      loader,
    );
    _entries[key] = request;
    unawaited(
      request.then<void>(
        (RetailerMemory? memory) {
          if (_generations[key] != generation) return;
          if (memory == null) {
            _recover(key, request, generation);
          } else {
            _lastGood[key] = request;
          }
        },
        onError: (Object _, StackTrace _) => _recover(key, request, generation),
      ),
    );
    return request;
  }

  void _recover(String key, Future<RetailerMemory?> request, int generation) {
    if (_generations[key] != generation) return;
    if (!identical(_entries[key], request)) return;
    final Future<RetailerMemory?>? fallback = _lastGood[key];
    if (fallback == null) {
      _entries.remove(key);
    } else {
      _entries[key] = fallback;
    }
  }

  void clear() {
    for (final key in _generations.keys.toList()) {
      _generations[key] = _generations[key]! + 1;
    }
    _entries.clear();
    _lastGood.clear();
  }

  void invalidate({required String uid, required String retailerId}) {
    final String key = _key(uid, retailerId);
    _generations[key] = (_generations[key] ?? 0) + 1;
    _entries.remove(key);
    _lastGood.remove(key);
  }

  String _key(String uid, String retailerId) =>
      jsonEncode(<String>[uid.trim(), retailerId.trim()]);
}

class _OutcomeQueueOwner extends ChangeNotifier {
  _OutcomeQueueOwner._(this.uid, this.revision);

  final String uid;
  final int revision;
  bool get current => revision == ProjectLocalStore.runtimeRevision;
  OfflineQueueLedger queue = OfflineQueueLedger();
  bool initialised = false;
  bool flushing = false;
  String lastSyncError = '';
  Future<void> persistTail = Future<void>.value();
  Future<void>? initialising;

  static final Expando<Map<String, _OutcomeQueueOwner>> _byDatabase =
      Expando<Map<String, _OutcomeQueueOwner>>();

  static _OutcomeQueueOwner of(
    FirebaseFirestore db,
    String projectId,
    String uid,
  ) {
    final Map<String, _OutcomeQueueOwner> owners = _byDatabase[db] ??=
        <String, _OutcomeQueueOwner>{};
    final int runtimeRevision = ProjectLocalStore.runtimeRevision;
    final String revision = '$runtimeRevision|';
    final String key = '$revision$projectId|$uid';
    final _OutcomeQueueOwner? existing = owners[key];
    if (existing != null) return existing;
    owners.removeWhere((String other, _) => !other.startsWith(revision));
    return owners[key] = _OutcomeQueueOwner._(uid, runtimeRevision);
  }
}

class SalesVisitCopilotService extends ChangeNotifier {
  SalesVisitCopilotService({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance {
    ProjectLocalStore.recoveryNotice.addListener(_forward);
  }

  static const Set<String> reasonCodes = <String>{
    'low_sell_through',
    'price_too_high',
    'switched_to_alternative',
    'supplier_issue',
    'out_of_stock',
    'shelf_space_limited',
    'cash_flow_issue',
    'seasonal_change',
    'not_decision_maker',
    'not_asked_today',
    'retailer_busy',
    'decision_maker_unavailable',
    'competitor_promotion',
    'packaging_change',
    'quality_complaint',
    'other',
  };

  final FirebaseFirestore _db;
  late final ProjectLocalStore _store = ProjectLocalStore(
    projectId: _db.app.options.projectId,
  );
  final RetailerMemoryRequestCache _memoryCache = RetailerMemoryRequestCache();
  _OutcomeQueueOwner? _attached;
  bool _disposed = false;

  _OutcomeQueueOwner? get _owner {
    final _OutcomeQueueOwner? owner = _attached;
    return owner != null && owner.current ? owner : null;
  }

  String get _uid => _owner?.uid ?? '';
  OfflineQueueLedger get _queue => _owner?.queue ?? OfflineQueueLedger();
  bool get _initialised => _owner?.initialised ?? false;

  static const String needsAttentionStatus = outcomeNeedsAttentionStatus;
  static const String followUpRefusedMessage =
      'The server refused the follow-up date. The visit result itself is saved. Remove this one. Set the date again at the next visit.';

  int get pendingCount => _store.isActive(_uid)
      ? _queue.ordered.where((OfflineOperation row) => !_isStuck(row)).length
      : 0;

  static bool _isStuck(OfflineOperation row) =>
      row.targetStatus == needsAttentionStatus;

  List<OfflineOperation> get stuckOutcomes => _store.isActive(_uid)
      ? _queue.ordered.where(_isStuck).toList(growable: false)
      : const <OfflineOperation>[];

  bool isHeld(String operationId) =>
      _store.isActive(_uid) && _queue[operationId] != null;

  Future<void> resendOutcome(String operationId) async {
    final OfflineOperation? row = _queue[operationId];
    if (row == null || !_isStuck(row)) return;
    await _changeQueue((OfflineQueueLedger ledger) {
      final OfflineOperation? held = ledger[operationId];
      if (held == null || !_isStuck(held)) return;
      ledger.put(held.copyWith(targetStatus: 'retry', lastError: ''));
    });
    _notify();
    await flushPending(isOnline: true, force: true);
  }

  Future<void> discardOutcome(String operationId) async {
    final OfflineOperation? row = _queue[operationId];
    if (row == null || !_isStuck(row)) return;
    await _changeQueue(
      (OfflineQueueLedger ledger) => ledger.remove(operationId),
    );
    _notify();
  }

  static bool _refusedForGood(Object error) {
    if (error is! FirebaseException) return false;
    if (error.code == 'permission-denied') {
      return CompanyLifecycleMonitor.instance.lifecycle?.isOpen ?? false;
    }
    return const <String>{
      'invalid-argument',
      'failed-precondition',
      'out-of-range',
    }.contains(error.code);
  }

  bool get isFlushing => _owner?.flushing ?? false;
  String get lastSyncError => ProjectLocalStore.recoveryNotice.value.isNotEmpty
      ? ProjectLocalStore.recoveryNotice.value
      : _owner?.lastSyncError ?? '';

  static const String briefCacheKeyPrefix = 'visit_brief_cache_v1_';
  static const int briefCacheLimit = 60;

  static String briefCacheKey(String uid) =>
      ProjectLocalStore().key(uid, 'visit_briefs');

  static Future<void> saveCachedBriefs(
    String uid,
    List<VisitBrief> briefs, {
    String? projectId,
  }) async {
    if (uid.trim().isEmpty) return;
    final store = ProjectLocalStore(projectId: projectId);
    try {
      await store.write(
        uid,
        'visit_briefs',
        jsonEncode(
          briefs
              .take(briefCacheLimit)
              .map((VisitBrief brief) => brief.toCacheMap())
              .toList(growable: false),
        ),
      );
    } catch (_) {}
  }

  static Future<List<VisitBrief>> loadCachedBriefs(
    String uid, {
    String? projectId,
  }) async {
    if (uid.trim().isEmpty) return const <VisitBrief>[];
    final store = ProjectLocalStore(projectId: projectId);
    final revision = ProjectLocalStore.runtimeRevision;
    if (kBasicEdition) {
      return const <VisitBrief>[];
    }
    try {
      final String? encoded = await store.read(
        uid,
        'visit_briefs',
        legacyKey: '$briefCacheKeyPrefix${uid.trim()}',
      );
      if (encoded == null || encoded.isEmpty) return const <VisitBrief>[];
      final Object? decoded = jsonDecode(encoded);
      if (decoded is! List) return const <VisitBrief>[];
      final List<VisitBrief> briefs = <VisitBrief>[];
      for (final Object? row in decoded) {
        if (row is! Map) continue;
        final VisitBrief brief = VisitBrief.fromMap(
          '',
          Map<String, dynamic>.from(row),
        );
        if (brief.isActive &&
            !brief.isDemo &&
            brief.salesmanUid == uid.trim()) {
          briefs.add(brief);
        }
      }
      return revision == ProjectLocalStore.runtimeRevision &&
              store.isActive(uid)
          ? List<VisitBrief>.unmodifiable(briefs)
          : const <VisitBrief>[];
    } catch (_) {
      return const <VisitBrief>[];
    }
  }

  Future<void> initialiseForUser(String uid) {
    final safeUid = uid.trim();
    if (safeUid.isEmpty || _disposed) return Future<void>.value();
    final _OutcomeQueueOwner owner = _OutcomeQueueOwner.of(
      _db,
      _store.projectId,
      safeUid,
    );
    _attach(owner);
    if (owner.initialised) return Future<void>.value();
    final pending = owner.initialising;
    if (pending != null) return pending;
    final operation = _load(owner);
    owner.initialising = operation;
    return operation.whenComplete(() {
      if (identical(owner.initialising, operation)) owner.initialising = null;
    });
  }

  void _attach(_OutcomeQueueOwner owner) {
    if (identical(_attached, owner)) return;
    _attached?.removeListener(_forward);
    _attached = owner;
    owner.addListener(_forward);
    _memoryCache.clear();
    _forward();
  }

  Future<void> _load(_OutcomeQueueOwner owner) async {
    final String uid = owner.uid;
    await owner.persistTail;
    final encoded = await _store.read(
      uid,
      outcomeQueueStoreName,
      legacyKey: _queueKeyFor(uid),
    );
    await ProjectLocalStore.refreshRecoveryNotice();
    final operations = <OfflineOperation>[];
    if (encoded != null && encoded.isNotEmpty) {
      try {
        operations.addAll(_decodeQueue(encoded, uid));
      } catch (_) {
        operations.clear();
        await ProjectLocalStore.recoverLegacyKey(
          _store.key(uid, outcomeQueueStoreName),
        );
        if (await _store.read(uid, outcomeQueueStoreName) != null) {
          throw StateError(
            'Outcome queue must be recovered before replacement.',
          );
        }
      }
    }
    if (owner.initialised) return;
    owner.queue = OfflineQueueLedger(operations);
    owner.initialised = true;
    owner.notifyListeners();
  }

  Stream<List<VisitBrief>> watchAssignedBriefs(UserModel user) {
    final current = _store.lease(user.uid);
    if (kBasicEdition) {
      return Stream<List<VisitBrief>>.value(const <VisitBrief>[]);
    }
    late final StreamController<List<VisitBrief>> controller;
    final sources = <String, Map<String, VisitBrief>>{};
    final fromCacheBySource = <String, bool>{};
    final failedSources = <String, Object>{};
    int startedSources = 0;
    final subscriptions =
        <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

    void emit() {
      if (!current()) return;
      final byId = <String, VisitBrief>{};
      for (final source in sources.values) {
        byId.addAll(source);
      }
      final briefs =
          byId.values.where((brief) => brief.isActive && !brief.isDemo).toList()
            ..sort((left, right) {
              final priority = right.highPriorityCount.compareTo(
                left.highPriorityCount,
              );
              if (priority != 0) return priority;
              return right.totalValueAtRiskRm.compareTo(
                left.totalValueAtRiskRm,
              );
            });
      if (briefs.isNotEmpty) {
        unawaited(
          SalesVisitCopilotService.saveCachedBriefs(
            user.uid,
            briefs,
            projectId: _store.projectId,
          ),
        );
        if (!controller.isClosed) controller.add(briefs);
        return;
      }
      final everySourceFromCache =
          fromCacheBySource.isNotEmpty &&
          fromCacheBySource.values.every((bool fromCache) => fromCache);
      if (!everySourceFromCache) {
        if (!controller.isClosed) controller.add(const <VisitBrief>[]);
        return;
      }
      unawaited(
        SalesVisitCopilotService.loadCachedBriefs(
          user.uid,
          projectId: _store.projectId,
        ).then((List<VisitBrief> cached) {
          if (!controller.isClosed && current()) controller.add(cached);
        }),
      );
    }

    Future<void> cancelSubscriptions() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
    }

    void listenTo(String field, String value) {
      final safe = value.trim();
      if (safe.isEmpty) return;
      startedSources += 1;
      subscriptions.add(
        _db
            .collection('visit_briefs')
            .where(field, isEqualTo: safe)
            .limit(100)
            .snapshots()
            .listen(
              (snapshot) {
                if (!current()) return;
                sources[field] = <String, VisitBrief>{
                  for (final doc in snapshot.docs)
                    doc.id: VisitBrief.fromFirestore(doc),
                };
                fromCacheBySource[field] = snapshot.metadata.isFromCache;
                emit();
              },
              onError: (Object error, StackTrace stackTrace) {
                failedSources[field] = error;
                debugPrint(
                  'Visit brief source "$field" could not be read: $error',
                );
                if (sources.isEmpty && failedSources.length >= startedSources) {
                  if (!controller.isClosed) {
                    controller.addError(error, stackTrace);
                  }
                  return;
                }
                emit();
              },
            ),
      );
    }

    controller = StreamController<List<VisitBrief>>(
      onListen: () {
        listenTo('salesmanUid', user.uid);
      },
      onCancel: cancelSubscriptions,
    );
    return controller.stream;
  }

  Future<OutcomeQueueResult> queueOutcome({
    required UserModel user,
    required String branchId,
    required String planId,
    required String stopId,
    required VisitBrief brief,
    required VisitBriefInsight insight,
    required String reasonCode,
    required String note,
    required String replacementProductId,
    required bool isOnline,
    DateTime? followUpOn,
  }) async {
    final current = _store.lease(user.uid);
    if (!current()) {
      throw StateError('The signed-in company or account changed.');
    }
    await initialiseForUser(user.uid);
    if (!current() || !_initialised || _uid != user.uid.trim()) {
      throw StateError('The signed-in company or account changed.');
    }
    final String cleanBranch = branchId.trim();
    final String cleanPlan = planId.trim();
    final String cleanStop = stopId.trim();
    final String cleanBrief = brief.id.trim();
    final String cleanRetailer = brief.retailerId.trim();
    final String cleanRetailerName = brief.retailerName.trim();
    final String cleanIssueId = insight.issueId.trim();
    final String cleanIssueKey = insight.issueKey.trim();
    final String cleanIssueType = insight.type.trim();
    final String cleanProduct = insight.productId.trim();
    final String cleanProductName = insight.productName.trim();
    final String cleanUserUid = user.uid.trim();
    final String cleanStaffId = user.identityCode;

    if (cleanBranch.isEmpty ||
        cleanPlan.isEmpty ||
        cleanStop.isEmpty ||
        cleanBrief.isEmpty ||
        cleanRetailer.isEmpty ||
        cleanRetailerName.isEmpty ||
        cleanIssueId.isEmpty ||
        cleanIssueType.isEmpty ||
        cleanProduct.isEmpty ||
        cleanProductName.isEmpty ||
        cleanUserUid.isEmpty ||
        cleanStaffId.isEmpty) {
      throw ArgumentError('Outcome provenance is incomplete.');
    }
    if (cleanBranch != user.branchId.trim() ||
        brief.salesmanUid.trim() != cleanUserUid ||
        brief.salesmanCode.trim() != cleanStaffId ||
        brief.branchId.trim() != cleanBranch) {
      throw ArgumentError(
        'Outcome is not assigned to this salesman and branch.',
      );
    }
    if (cleanIssueKey != '$cleanIssueType::$cleanRetailer::$cleanProduct') {
      throw ArgumentError('Outcome issue identity is not canonical.');
    }
    final bool insightIsInBrief = brief.topInsights.any(
      (VisitBriefInsight candidate) =>
          candidate.issueId.trim() == cleanIssueId &&
          candidate.issueKey.trim() == cleanIssueKey &&
          candidate.type.trim() == cleanIssueType &&
          candidate.productId.trim() == cleanProduct,
    );
    if (!insightIsInBrief) {
      throw ArgumentError('Outcome issue is not part of the source brief.');
    }
    final cleanReason = reasonCode.trim().toLowerCase();
    if (!reasonCodes.contains(cleanReason)) {
      throw ArgumentError.value(reasonCode, 'reasonCode', 'Unsupported reason');
    }
    final cleanNote = note.trim();
    final cleanReplacement = replacementProductId.trim();
    if (cleanReason == 'other' && cleanNote.length < 8) {
      throw ArgumentError('A meaningful note is required for Other.');
    }
    if (cleanReason == 'switched_to_alternative' && cleanReplacement.isEmpty) {
      throw ArgumentError('Replacement product ID is required.');
    }
    final PendingFollowUp? followUp = _newFollowUp(followUpOn);

    final now = DateTime.now().toUtc();
    final outcomeId = _outcomeId(cleanUserUid, cleanIssueId, now);
    final payload = <String, dynamic>{
      'outcomeId': outcomeId,
      'issueId': cleanIssueId,
      'issueKey': cleanIssueKey,
      'issueType': cleanIssueType,
      'retailerId': cleanRetailer,
      'retailerName': cleanRetailerName,
      'productId': cleanProduct,
      'productName': cleanProductName,
      'reasonCode': cleanReason,
      'note': cleanNote,
      'replacementProductId': cleanReplacement,
      'salesmanUid': cleanUserUid,
      'salesmanCode': cleanStaffId,
      'branchId': cleanBranch,
      'planId': cleanPlan,
      'stopId': cleanStop,
      'sourceBriefId': cleanBrief,
      'source': 'mobile_assigned_route_copilot',
      'isDemo': brief.isDemo,
      'clientCreatedAt': now.toIso8601String(),
    };
    final OfflineOperation queued = OfflineOperation(
      operationId: outcomeId,
      type: 'conversation_outcome',
      documentId: outcomeId,
      payload: payload,
      createdAt: now,
      targetKind: insight.type,
      targetStatus: 'pending',
      stopId: cleanStop,
      followUp: followUp,
    );
    _memoryCache.invalidate(
      uid: '${_store.projectId}|$cleanUserUid',
      retailerId: cleanRetailer,
    );
    await _changeQueue((OfflineQueueLedger ledger) => ledger.put(queued));
    FollowUpService.noteChanged();
    if (!current()) {
      return OutcomeQueueResult(outcomeId: outcomeId, synced: false);
    }
    _notify();
    if (isOnline) {
      await flushPending(isOnline: true, force: true);
    }
    return OutcomeQueueResult(
      outcomeId: outcomeId,
      synced: current() && _queue[outcomeId] == null,
    );
  }

  static final Set<String> noOrderReasonCodes = reasonCodes.difference(<String>{
    'switched_to_alternative',
  });

  Future<OutcomeQueueResult> queueNoOrderOutcome({
    required UserModel user,
    required String branchId,
    required String planId,
    required String stopId,
    required String retailerId,
    required String retailerName,
    required String reasonCode,
    required String note,
    required bool isDemo,
    required bool isOnline,
    DateTime? followUpOn,
  }) async {
    final current = _store.lease(user.uid);
    if (!current()) {
      throw StateError('The signed-in company or account changed.');
    }
    await initialiseForUser(user.uid);
    if (!current() || !_initialised || _uid != user.uid.trim()) {
      throw StateError('The signed-in company or account changed.');
    }
    final String cleanUserUid = user.uid.trim();
    final String cleanStaffId = user.identityCode;
    final String cleanBranch = branchId.trim();
    final String cleanPlan = planId.trim();
    final String cleanStop = stopId.trim();
    final String cleanRetailer = retailerId.trim();
    final String cleanRetailerName = retailerName.trim();
    final String cleanReason = reasonCode.trim().toLowerCase();
    final String cleanNote = note.trim();
    if (cleanUserUid.isEmpty ||
        cleanStaffId.isEmpty ||
        cleanBranch.isEmpty ||
        cleanPlan.isEmpty ||
        cleanStop.isEmpty ||
        cleanRetailer.isEmpty) {
      throw ArgumentError('Outcome provenance is incomplete.');
    }
    if (cleanBranch != user.branchId.trim()) {
      throw ArgumentError('Outcome is not assigned to this branch.');
    }
    if (!noOrderReasonCodes.contains(cleanReason)) {
      throw ArgumentError.value(reasonCode, 'reasonCode', 'Unsupported reason');
    }
    if (cleanReason == 'other' && cleanNote.length < 8) {
      throw ArgumentError('A meaningful note is required for Other.');
    }
    final PendingFollowUp? followUp = _newFollowUp(followUpOn);
    final now = DateTime.now().toUtc();
    final outcomeId = _outcomeId(cleanUserUid, 'no_order', now);
    final payload = <String, dynamic>{
      'outcomeId': outcomeId,
      'outcomeKind': 'no_order',
      'retailerId': cleanRetailer,
      'retailerName': cleanRetailerName.length > 200
          ? cleanRetailerName.substring(0, 200)
          : cleanRetailerName,
      'reasonCode': cleanReason,
      'note': cleanNote.length > 500 ? cleanNote.substring(0, 500) : cleanNote,
      'salesmanUid': cleanUserUid,
      'salesmanCode': cleanStaffId,
      'branchId': cleanBranch,
      'planId': cleanPlan,
      'stopId': cleanStop,
      'source': 'mobile_assigned_route_no_order',
      'isDemo': isDemo,
      'clientCreatedAt': now.toIso8601String(),
    };
    final OfflineOperation queued = OfflineOperation(
      operationId: outcomeId,
      type: 'conversation_outcome',
      documentId: outcomeId,
      payload: payload,
      createdAt: now,
      targetKind: 'no_order',
      targetStatus: 'pending',
      stopId: cleanStop,
      followUp: followUp,
    );
    _memoryCache.invalidate(
      uid: '${_store.projectId}|$cleanUserUid',
      retailerId: cleanRetailer,
    );
    await _changeQueue((OfflineQueueLedger ledger) => ledger.put(queued));
    FollowUpService.noteChanged();
    if (!current()) {
      return OutcomeQueueResult(outcomeId: outcomeId, synced: false);
    }
    _notify();
    if (isOnline) {
      await flushPending(isOnline: true, force: true);
    }
    return OutcomeQueueResult(
      outcomeId: outcomeId,
      synced: current() && _queue[outcomeId] == null,
    );
  }

  static PendingFollowUp? _newFollowUp(DateTime? day) {
    if (day == null) return null;
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime wanted = DateTime(day.year, day.month, day.day);
    if (wanted.isBefore(today) ||
        wanted.isAfter(today.add(const Duration(days: followUpMaxDaysAhead)))) {
      throw ArgumentError.value(day, 'followUpOn', 'Outside the allowed days');
    }
    return PendingFollowUp(
      date: followUpDateKey(wanted),
      status: FollowUpStatus.open.name,
    );
  }

  Future<void> markFollowUpDone({
    required UserModel user,
    required FollowUpPromise promise,
    required bool isOnline,
  }) async {
    final String uid = user.uid.trim();
    final current = _store.lease(uid);
    if (!current()) {
      throw StateError('The signed-in company or account changed.');
    }
    await initialiseForUser(uid);
    if (!current() || !_initialised || _uid != uid) {
      throw StateError('The signed-in company or account changed.');
    }
    final String outcomeId = promise.outcomeId.trim();
    if (outcomeId.isEmpty) throw ArgumentError('Follow-up has no outcome.');
    final String done = FollowUpStatus.completed.name;
    await _changeQueue((OfflineQueueLedger ledger) {
      final OfflineOperation? held = ledger[outcomeId];
      final PendingFollowUp? heldFollowUp = held?.followUp;
      if (held != null) {
        ledger.put(
          held.copyWith(
            followUp:
                heldFollowUp?.withStatus(done) ??
                PendingFollowUp(date: promise.dateKey, status: done),
          ),
        );
        return;
      }
      ledger.put(
        OfflineOperation(
          operationId: outcomeId,
          type: 'conversation_outcome',
          documentId: outcomeId,
          payload: <String, dynamic>{
            'outcomeId': outcomeId,
            'salesmanUid': uid,
            'retailerId': promise.retailerId,
            'retailerName': promise.shop,
          },
          createdAt: DateTime.now().toUtc(),
          targetKind: 'follow_up',
          targetStatus: 'pending',
          followUp: PendingFollowUp(
            date: promise.dateKey,
            status: done,
            outcomeSent: true,
          ),
        ),
      );
    });
    FollowUpService.noteChanged();
    if (!current()) return;
    _notify();
    if (isOnline) await flushPending(isOnline: true, force: true);
  }

  Future<RetailerMemory?> loadRetailerMemory({
    required UserModel user,
    required String retailerId,
    bool forceRefresh = false,
  }) {
    final String safeRetailerId = retailerId.trim();
    final String uid = user.uid.trim();
    if (kBasicEdition || safeRetailerId.isEmpty || uid.isEmpty) {
      return Future<RetailerMemory?>.value(RetailerMemory.empty);
    }
    final current = _store.lease(uid);
    if (!current()) return Future<RetailerMemory?>.value(null);
    return _memoryCache.load(
      uid: '${_store.projectId}|$uid',
      retailerId: safeRetailerId,
      forceRefresh: forceRefresh,
      loader: () async {
        final result = await _fetchRetailerMemory(
          uid: uid,
          retailerId: safeRetailerId,
        );
        return current() ? result : null;
      },
    );
  }

  Future<RetailerMemory?> _fetchRetailerMemory({
    required String uid,
    required String retailerId,
  }) async {
    try {
      final snapshot = await _db
          .collection('conversation_outcomes')
          .where('salesmanUid', isEqualTo: uid)
          .where('retailerId', isEqualTo: retailerId)
          .orderBy('submittedAt', descending: true)
          .limit(40)
          .get()
          .timeout(const Duration(seconds: 10));
      final events = <RetailerOutcomeEvent>[];
      for (final doc in snapshot.docs) {
        final data = doc.data();
        if (isDemoRecord(data)) continue;
        final reason = (data['reasonCode'] ?? '')
            .toString()
            .trim()
            .toLowerCase();
        if (!reasonCodes.contains(reason)) continue;
        events.add(
          RetailerOutcomeEvent(
            reasonCode: reason,
            replacementProductId: (data['replacementProductId'] ?? '')
                .toString()
                .trim(),
            productId: (data['productId'] ?? '').toString().trim(),
            productName: (data['productName'] ?? '').toString().trim(),
            issueKey: (data['issueKey'] ?? '').toString().trim(),
            submittedAt: _timestampToDate(
              data['submittedAt'] ?? data['clientCreatedAt'],
            ),
            isDemo: false,
          ),
        );
      }
      return deriveRetailerMemory(events, now: DateTime.now());
    } catch (_) {
      return null;
    }
  }

  DateTime? _timestampToDate(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse((value ?? '').toString());
  }

  Future<void> flushPending({
    required bool isOnline,
    bool force = false,
  }) async {
    final _OutcomeQueueOwner? owner = _owner;
    if (owner == null) return;
    final String uid = owner.uid;
    final current = _store.lease(uid);
    if (!isOnline ||
        !owner.initialised ||
        owner.flushing ||
        owner.queue.length == 0 ||
        !current()) {
      return;
    }
    owner.flushing = true;
    owner.lastSyncError = '';
    _notify();
    try {
      for (final OfflineOperation queued in owner.queue.ordered) {
        if (!current()) return;
        if (queued.payload['salesmanUid'] != uid) return;
        final OfflineOperation? operation = owner.queue[queued.operationId];
        if (operation == null || _isStuck(operation)) continue;
        final retryAt = operation.nextRetryAt;
        if (!force && retryAt != null && retryAt.isAfter(DateTime.now())) {
          continue;
        }
        bool outcomeSent = operation.followUp?.outcomeSent ?? false;
        try {
          final reference = _db
              .collection('conversation_outcomes')
              .doc(operation.documentId);
          if (!outcomeSent) {
            await reference
                .set(_firestorePayload(operation.payload))
                .timeout(const Duration(seconds: 10));
            if (!current()) return;
          }
          PendingFollowUp? sending;
          await _changeQueue((OfflineQueueLedger ledger) {
            final OfflineOperation? held = ledger[operation.operationId];
            final PendingFollowUp? followUp = held?.followUp;
            if (held == null || followUp == null) {
              ledger.remove(operation.operationId);
              return;
            }
            sending = followUp.afterOutcomeSent;
            ledger.put(held.copyWith(followUp: sending));
          });
          outcomeSent = true;
          if (!current()) return;
          while (sending != null) {
            final PendingFollowUp followUp = sending!;
            await reference
                .update(<String, dynamic>{
                  'followUpDate': followUp.date,
                  'followUpStatus': followUp.status,
                })
                .timeout(const Duration(seconds: 10));
            if (!current()) return;
            sending = null;
            await _changeQueue((OfflineQueueLedger ledger) {
              final PendingFollowUp? latest =
                  ledger[operation.operationId]?.followUp;
              if (latest != null && latest.status != followUp.status) {
                sending = latest;
                return;
              }
              ledger.remove(operation.operationId);
            });
            await FollowUpService(
              firestore: _db,
              store: _store,
            ).remember(uid, <String, dynamic>{
              ...operation.payload,
              'outcomeId': operation.documentId,
              'followUpDate': followUp.date,
              'followUpStatus': followUp.status,
            });
            if (!current()) return;
          }
          _notify();
        } catch (error) {
          if (!current()) return;
          if (_refusedForGood(error)) {
            await _changeQueue(
              (OfflineQueueLedger ledger) => _putIfHeld(
                ledger,
                (ledger[operation.operationId] ?? operation).copyWith(
                  lastError: outcomeSent
                      ? followUpRefusedMessage
                      : 'The server refused this visit result. Sending it again will not help. Record the visit result again, then remove this one.',
                  targetStatus: needsAttentionStatus,
                ),
              ),
            );
            FollowUpService.noteChanged();
            if (current()) _notify();
            continue;
          }
          final attempts = operation.attempts + 1;
          final boundedAttempts = attempts > 6 ? 6 : attempts;
          owner.lastSyncError = 'Some outcomes are waiting to sync.';
          await _changeQueue(
            (OfflineQueueLedger ledger) => _putIfHeld(
              ledger,
              (ledger[operation.operationId] ?? operation).copyWith(
                attempts: attempts,
                nextRetryAt: DateTime.now().add(
                  Duration(seconds: 1 << boundedAttempts),
                ),
                lastError: error.runtimeType.toString(),
                targetStatus: 'retry',
              ),
            ),
          );
          if (current()) _notify();
          break;
        }
      }
    } finally {
      owner.flushing = false;
      _notify();
    }
  }

  Map<String, dynamic> _firestorePayload(Map<String, dynamic> payload) {
    final result = Map<String, dynamic>.from(payload);
    result['clientCreatedAt'] = Timestamp.fromDate(
      DateTime.parse(payload['clientCreatedAt'].toString()).toUtc(),
    );
    result['submittedAt'] = FieldValue.serverTimestamp();
    return result;
  }

  static void _putIfHeld(OfflineQueueLedger ledger, OfflineOperation row) {
    if (ledger[row.operationId] != null) ledger.put(row);
  }

  Future<void> _changeQueue(void Function(OfflineQueueLedger ledger) change) {
    final _OutcomeQueueOwner? owner = _owner;
    if (owner == null) return Future<void>.value();
    final String uid = owner.uid;
    return ProjectLocalStore.locked(_store.key(uid, 'outcome_write'), () async {
      OfflineQueueLedger ledger = owner.queue;
      try {
        final String? stored = await _store.read(uid, outcomeQueueStoreName);
        if (stored != null && stored.isNotEmpty) {
          ledger = OfflineQueueLedger(_decodeQueue(stored, uid));
        }
      } catch (_) {
        ledger = owner.queue;
      }
      change(ledger);
      owner.queue = ledger;
      final encoded = jsonEncode(
        ledger.ordered
            .map((operation) => operation.toJson())
            .toList(growable: false),
      );
      final operation = owner.persistTail.then(
        (_) => _store.write(uid, outcomeQueueStoreName, encoded),
      );
      owner.persistTail = operation.catchError((Object _, StackTrace _) {});
      await operation;
    });
  }

  List<OfflineOperation> _decodeQueue(String encoded, String uid) {
    final decoded = jsonDecode(encoded);
    if (decoded is! List) throw const FormatException('Invalid outcome queue');
    final operations = <OfflineOperation>[];
    for (final raw in decoded) {
      if (raw is! Map) throw const FormatException('Invalid outcome row');
      final operation = OfflineOperation.fromJson(
        Map<String, dynamic>.from(raw),
      );
      if (operation.type == 'conversation_outcome' &&
          (operation.documentId.startsWith('${_safeId(uid)}_') ||
              (operation.followUp?.outcomeSent ?? false)) &&
          operation.payload['salesmanUid'] == uid) {
        operations.add(operation);
      } else {
        throw const FormatException('Invalid outcome owner');
      }
    }
    return operations;
  }

  String _queueKeyFor(String uid) => 'conversation_outcome_queue_v1_$uid';

  String _outcomeId(String uid, String issueId, DateTime now) {
    final safeUid = _safeId(uid);
    final safeIssue = _safeId(issueId);
    return '${safeUid}_${now.microsecondsSinceEpoch}_$safeIssue';
  }

  String _safeId(String value) {
    final cleaned = value.replaceAll(RegExp(r'[^A-Za-z0-9_-]+'), '_');
    if (cleaned.isEmpty) return 'unknown';
    return cleaned.length <= 48 ? cleaned : cleaned.substring(0, 48);
  }

  void _notify() {
    final _OutcomeQueueOwner? owner = _owner;
    if (owner != null) {
      owner.notifyListeners();
    } else {
      _forward();
    }
  }

  void _forward() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    ProjectLocalStore.recoveryNotice.removeListener(_forward);
    _attached?.removeListener(_forward);
    _memoryCache.clear();
    _disposed = true;
    super.dispose();
  }
}
