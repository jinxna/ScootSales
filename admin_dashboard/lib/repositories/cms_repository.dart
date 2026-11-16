import 'dart:async';
import 'dart:convert' show utf8;

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show visibleForTesting;
import 'package:uuid/uuid.dart';

import '../app_runtime.dart';
import '../models/action_centre_item.dart';
import '../models/tracking_control.dart';
import '../models/user_profile.dart';
import '../security/order_authorization.dart';
import '../security/team_scope.dart';
import '../services/action_centre_service.dart';
import '../services/audit_log_service.dart';
import '../services/auth_service.dart';
import '../utils/app_logger.dart';
import '../utils/collection_rows.dart';
import '../utils/csv_export.dart';
import '../utils/covered_query.dart';
import '../utils/firestore_query_utils.dart' as firestore_query_utils;
import '../utils/firestore_value_equality.dart';
import '../utils/order_data_utils.dart';
import '../utils/product_catalogue_pager.dart';
import '../utils/ref_counted_replay_stream.dart';
import '../utils/visit_data_utils.dart';

class OrderPageCursor {
  const OrderPageCursor({required this.submittedAt, required this.documentId});

  final Timestamp submittedAt;
  final String documentId;

  List<Object?> get values => <Object?>[submittedAt, documentId];
}

Query<Map<String, dynamic>> buildOrdersPageQuery(
  Query<Map<String, dynamic>> query, {
  OrderPageCursor? before,
}) {
  Query<Map<String, dynamic>> ordered = query
      .orderBy('submittedAt', descending: true)
      .orderBy(FieldPath.documentId, descending: true);
  if (before != null) {
    ordered = ordered.startAfter(before.values);
  }
  return ordered;
}

class CmsRepository {
  CmsRepository();

  final FirebaseFirestore _firestore = FirebaseFirestore.instance;
  final Uuid _uuid = const Uuid();

  static const int _maintenancePageSize = 400;
  static const Duration _orderPurgeLease = Duration(minutes: 15);
  static const int _orderPurgeExportMaxBytes = 700000;

  DocumentReference<Map<String, dynamic>> get _orderPurgeSettingsReference =>
      _firestore.collection('system_settings').doc('order_purge');

  static final Map<String, _ReplayCollectionStream> _streamCache =
      <String, _ReplayCollectionStream>{};

  static Future<void> resetAccessScope() async {
    ActionCentreService.resetSharedDerive();
    final List<_ReplayCollectionStream> previous = <_ReplayCollectionStream>[
      ..._streamCache.values,
      ..._sourceStreamCache.values,
    ];
    _streamCache.clear();
    _sourceStreamCache.clear();
    await Future.wait(
      previous.map((_ReplayCollectionStream stream) => stream.dispose()),
    );
  }

  Stream<List<Map<String, dynamic>>> watchCollection(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
  }) {
    if (!AppRuntime.firebaseReady) {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    if (collectionName == 'live_tracking') {
      return Stream<List<Map<String, dynamic>>>.error(
        StateError(
          'Use getScopedLiveTrackingSnapshot for a manual fleet refresh or '
          'watchLiveTrackingPerson for one followed salesperson.',
        ),
      );
    }

    final int effectiveLimit = limit ?? _defaultWatchLimit(collectionName);
    final String cacheKey = _cacheKey(
      collectionName,
      orderBy: orderBy,
      descending: descending,
      limit: effectiveLimit,
      coverageProbe: coverageProbe,
    );

    final _ReplayCollectionStream cached = _streamCache.putIfAbsent(
      cacheKey,
      () {
        return _ReplayCollectionStream(
          () => _buildRealtimeStream(
            collectionName,
            orderBy: orderBy,
            descending: descending,
            limit: effectiveLimit,
            coverageProbe: coverageProbe,
          ),
        );
      },
    );

    return cached.stream;
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchTrackingControl(
    String salesmanUid,
  ) {
    final String uid = salesmanUid.trim();
    if (!AppRuntime.firebaseReady || uid.isEmpty) {
      return const Stream<DocumentSnapshot<Map<String, dynamic>>>.empty();
    }
    return _firestore.collection('tracking_controls').doc(uid).snapshots();
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchLiveTrackingPerson(
    String salesmanUid,
  ) {
    final String uid = salesmanUid.trim();
    if (!AppRuntime.firebaseReady || uid.isEmpty) {
      return const Stream<DocumentSnapshot<Map<String, dynamic>>>.empty();
    }
    return _firestore.collection('live_tracking').doc(uid).snapshots();
  }

  Future<List<Map<String, dynamic>>> getScopedLiveTrackingSnapshot() async {
    if (!AppRuntime.firebaseReady) {
      throw StateError('Live tracking is not ready. Try again shortly.');
    }
    final List<Map<String, dynamic>> rows =
        await _getPreciseLocationCollectionOnce(
          'live_tracking',
          descending: true,
          limit: 200,
          options: const GetOptions(source: Source.server),
          requireReadableScope: true,
        );
    final List<Map<String, dynamic>> sorted = List<Map<String, dynamic>>.of(
      rows,
    );
    sorted.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final String left = _dateSortText(a['deviceCapturedAt']);
      final String right = _dateSortText(b['deviceCapturedAt']);
      if (left.isEmpty || right.isEmpty) {
        return left.isEmpty == right.isEmpty ? 0 : (left.isEmpty ? 1 : -1);
      }
      return right.compareTo(left);
    });
    return sorted;
  }

  @visibleForTesting
  static bool canChangeTrackingModeFor(UserProfile actor, String salesmanCode) {
    if (actor.isAdmin) return true;
    final String code = salesmanCode.trim();
    return actor.isSupervisor &&
        code.isNotEmpty &&
        actor.assignedSalesmanCodes
            .map((String value) => value.trim())
            .contains(code);
  }

  Future<int> setTrackingMode({
    required String salesmanUid,
    required String salesmanCode,
    required String branchId,
    required TrackingUploadMode mode,
    required UserProfile actor,
  }) async {
    final String uid = salesmanUid.trim();
    final String code = salesmanCode.trim();
    final String actorUid = actor.uid?.trim() ?? '';
    if (!AppRuntime.firebaseReady ||
        uid.isEmpty ||
        actorUid.isEmpty ||
        !actor.isActive ||
        !actor.canUseWebDashboard ||
        actor.isBranchManager ||
        actorUid == uid) {
      throw StateError('Tracking mode cannot be changed for this account.');
    }
    final bool inScope = canChangeTrackingModeFor(actor, code);
    if (!inScope) {
      throw StateError('This salesperson is outside your assigned scope.');
    }

    final DocumentReference<Map<String, dynamic>> reference = _firestore
        .collection('tracking_controls')
        .doc(uid);
    for (int contentionRetry = 0; contentionRetry < 3; contentionRetry++) {
      int? revisionReadByAttempt;
      try {
        return await _firestore.runTransaction<int>((
          Transaction transaction,
        ) async {
          final DocumentSnapshot<Map<String, dynamic>> snapshot =
              await transaction.get(reference);
          int previousRevision = 0;
          if (snapshot.exists) {
            final Object? revision = snapshot.data()?['revision'];
            if (revision is! int || revision < 1) {
              throw StateError('The existing tracking revision is invalid.');
            }
            previousRevision = revision;
          }
          revisionReadByAttempt = previousRevision;
          if (previousRevision >= 0x7fffffff) {
            throw StateError('The tracking revision limit was reached.');
          }
          final int nextRevision = previousRevision + 1;
          transaction.set(reference, <String, dynamic>{
            'mode': mode.wireValue,
            'revision': nextRevision,
            'updatedByUid': actorUid,
            'updatedAt': FieldValue.serverTimestamp(),
          });
          return nextRevision;
        });
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied' ||
            revisionReadByAttempt == null ||
            contentionRetry == 2) {
          rethrow;
        }
        final DocumentSnapshot<Map<String, dynamic>> current = await reference
            .get(const GetOptions(source: Source.server));
        final Object? currentRevision = current.data()?['revision'];
        if (!current.exists ||
            currentRevision is! int ||
            currentRevision <= revisionReadByAttempt!) {
          rethrow;
        }
      }
    }
    throw StateError('Tracking mode updates did not converge.');
  }

  Stream<List<Map<String, dynamic>>> watchSpecialRequests({
    required UserProfile currentUser,
    int limit = 200,
  }) {
    if (!AppRuntime.firebaseReady || limit <= 0) {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    final CollectionReference<Map<String, dynamic>> collection = _firestore
        .collection('special_requests');
    if (currentUser.isSupervisor) {
      final List<String> codes = currentUser.assignedSalesmanCodes
          .map((String code) => code.trim())
          .where((String code) => code.isNotEmpty)
          .toSet()
          .toList(growable: false);
      if (codes.isEmpty) {
        return Stream<List<Map<String, dynamic>>>.value(
          <Map<String, dynamic>>[],
        );
      }
      return _watchSpecialRequestChunks(collection, codes, limit);
    } else if (currentUser.isBranchManager) {
      final String branchId = currentUser.branchId.trim();
      if (branchId.isEmpty) {
        return Stream<List<Map<String, dynamic>>>.value(
          <Map<String, dynamic>>[],
        );
      }
      final Query<Map<String, dynamic>> query = collection
          .where('branchId', isEqualTo: branchId)
          .orderBy('createdAt', descending: true)
          .limit(limit);
      return _mapSpecialRequestSnapshot(query.snapshots());
    } else if (!currentUser.isAdmin) {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    final List<Query<Map<String, dynamic>>> queries =
        <Query<Map<String, dynamic>>>[
          collection.orderBy('createdAt', descending: true).limit(limit),
          collection
              .where(
                'status',
                whereIn: <String>[
                  'pending_supervisor',
                  'pending_branch_manager',
                  'pending_admin',
                  'approved',
                  'rejected',
                ],
              )
              .limit(limit),
          collection
              .where(
                'approvalStep',
                whereIn: <String>[
                  'Supervisor',
                  'Branch Manager',
                  'Admin',
                  'Approved',
                  'Rejected',
                ],
              )
              .limit(limit),
        ];
    return _watchSpecialRequestQueries(
      queries,
      limit,
      preserveInventoryRows: true,
    );
  }

  Stream<List<Map<String, dynamic>>> _watchSpecialRequestQueries(
    List<Query<Map<String, dynamic>>> queries,
    int limit, {
    bool preserveInventoryRows = false,
  }) {
    late final StreamController<List<Map<String, dynamic>>> controller;
    final Map<int, List<Map<String, dynamic>>> latestByQuery =
        <int, List<Map<String, dynamic>>>{};
    final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
    subscriptions = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    bool started = false;

    void emit() {
      final Map<String, Map<String, dynamic>> merged =
          <String, Map<String, dynamic>>{};
      for (final List<Map<String, dynamic>> rows in latestByQuery.values) {
        for (final Map<String, dynamic> row in rows) {
          final String docId = row['docId']?.toString() ?? '';
          if (docId.isNotEmpty) merged[docId] = row;
        }
      }
      final List<Map<String, dynamic>> rows = merged.values.toList()
        ..sort(_compareSpecialRequestRows);
      if (!preserveInventoryRows && rows.length > limit) {
        rows.removeRange(limit, rows.length);
      }
      if (!controller.isClosed) controller.add(List.unmodifiable(rows));
    }

    void start() {
      if (started) return;
      started = true;
      for (int index = 0; index < queries.length; index++) {
        final int queryIndex = index;
        final StreamSubscription<QuerySnapshot<Map<String, dynamic>>>
        subscription = queries[queryIndex].snapshots().listen(
          (QuerySnapshot<Map<String, dynamic>> snapshot) {
            latestByQuery[queryIndex] = snapshot.docs
                .map(_specialRequestDocument)
                .toList(growable: false);
            emit();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!controller.isClosed) controller.addError(error, stackTrace);
          },
        );
        subscriptions.add(subscription);
      }
    }

    Future<void> stop() async {
      for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>> sub
          in subscriptions) {
        await sub.cancel();
      }
      subscriptions.clear();
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<List<Map<String, dynamic>>>.broadcast(
      onListen: start,
      onCancel: stop,
    );
    return controller.stream;
  }

  Stream<List<Map<String, dynamic>>> _watchSpecialRequestChunks(
    CollectionReference<Map<String, dynamic>> collection,
    List<String> salesmanCodes,
    int limit,
  ) {
    late final StreamController<List<Map<String, dynamic>>> controller;
    final Map<int, List<Map<String, dynamic>>> latestByChunk =
        <int, List<Map<String, dynamic>>>{};
    final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
    subscriptions = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    bool started = false;
    final int chunkCount = (salesmanCodes.length + 29) ~/ 30;

    void emit() {
      if (latestByChunk.length < chunkCount) return;
      final Map<String, Map<String, dynamic>> merged =
          <String, Map<String, dynamic>>{};
      for (final List<Map<String, dynamic>> rows in latestByChunk.values) {
        for (final Map<String, dynamic> row in rows) {
          final String docId = row['docId']?.toString() ?? '';
          if (docId.isNotEmpty) merged[docId] = row;
        }
      }
      final List<Map<String, dynamic>> rows = merged.values.toList()
        ..sort(_compareSpecialRequestRows);
      if (rows.length > limit) rows.removeRange(limit, rows.length);
      if (!controller.isClosed) controller.add(List.unmodifiable(rows));
    }

    void start() {
      if (started) return;
      started = true;
      for (
        int offset = 0, chunkIndex = 0;
        offset < salesmanCodes.length;
        offset += 30, chunkIndex++
      ) {
        final List<String> chunk = salesmanCodes
            .skip(offset)
            .take(30)
            .toList(growable: false);
        final int currentChunkIndex = chunkIndex;
        final Query<Map<String, dynamic>> query = collection
            .where('salesmanCode', whereIn: chunk)
            .orderBy('createdAt', descending: true)
            .limit(limit);
        final StreamSubscription<QuerySnapshot<Map<String, dynamic>>>
        subscription = query.snapshots().listen(
          (QuerySnapshot<Map<String, dynamic>> snapshot) {
            latestByChunk[currentChunkIndex] = snapshot.docs
                .map(_specialRequestDocument)
                .toList(growable: false);
            emit();
          },
          onError: (Object error, StackTrace stackTrace) {
            if (!controller.isClosed) controller.addError(error, stackTrace);
          },
        );
        subscriptions.add(subscription);
      }
    }

    Future<void> stop() async {
      for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>> sub
          in subscriptions) {
        await sub.cancel();
      }
      subscriptions.clear();
      if (!controller.isClosed) await controller.close();
    }

    controller = StreamController<List<Map<String, dynamic>>>.broadcast(
      onListen: start,
      onCancel: stop,
    );
    return controller.stream;
  }

  Stream<List<Map<String, dynamic>>> _mapSpecialRequestSnapshot(
    Stream<QuerySnapshot<Map<String, dynamic>>> snapshots, {
    int? limit,
    bool sortByCreatedAt = false,
  }) {
    return snapshots.map((QuerySnapshot<Map<String, dynamic>> snapshot) {
      final List<Map<String, dynamic>> rows = snapshot.docs
          .map(_specialRequestDocument)
          .toList(growable: true);
      if (sortByCreatedAt) rows.sort(_compareSpecialRequestRows);
      if (limit != null && rows.length > limit) {
        rows.removeRange(limit, rows.length);
      }
      return List.unmodifiable(rows);
    });
  }

  Map<String, dynamic> _specialRequestDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> document,
  ) {
    return <String, dynamic>{...document.data(), 'docId': document.id};
  }

  int _compareSpecialRequestRows(
    Map<String, dynamic> left,
    Map<String, dynamic> right,
  ) {
    final dynamic leftValue = left['createdAt'];
    final dynamic rightValue = right['createdAt'];
    final DateTime leftTime = leftValue is Timestamp
        ? leftValue.toDate()
        : DateTime.fromMillisecondsSinceEpoch(0);
    final DateTime rightTime = rightValue is Timestamp
        ? rightValue.toDate()
        : DateTime.fromMillisecondsSinceEpoch(0);
    return rightTime.compareTo(leftTime);
  }

  Future<void> resetCollectionStream(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
  }) async {
    final int effectiveLimit = limit ?? _defaultWatchLimit(collectionName);
    final String cacheKey = _cacheKey(
      collectionName,
      orderBy: orderBy,
      descending: descending,
      limit: effectiveLimit,
    );
    final _ReplayCollectionStream? cached = _streamCache.remove(cacheKey);
    await cached?.dispose();
  }

  Stream<List<Map<String, dynamic>>> watchCollectionRaw(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
  }) {
    if (!AppRuntime.firebaseReady) {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    if (collectionName == 'live_tracking') {
      return Stream<List<Map<String, dynamic>>>.error(
        StateError(
          'Use getScopedLiveTrackingSnapshot for a manual fleet refresh or '
          'watchLiveTrackingPerson for one followed salesperson.',
        ),
      );
    }
    final int effectiveLimit = limit ?? _defaultWatchLimit(collectionName);
    final String cacheKey =
        'raw|${_cacheKey(collectionName, orderBy: orderBy, descending: descending, limit: effectiveLimit)}';
    final _ReplayCollectionStream cached = _streamCache.putIfAbsent(
      cacheKey,
      () {
        return _ReplayCollectionStream(
          () => _buildCollectionStream(
            collectionName,
            orderBy: orderBy,
            descending: descending,
            limit: effectiveLimit,
          ),
        );
      },
    );
    return cached.stream;
  }

  Future<List<Map<String, dynamic>>> getCollectionOnce(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    Duration? timeout,
    bool raw = false,
    bool coverageProbe = true,
  }) async {
    if (!AppRuntime.firebaseReady) return <Map<String, dynamic>>[];

    final String cacheKey = _cacheKey(
      collectionName,
      orderBy: orderBy,
      descending: descending,
      limit: limit,
      coverageProbe: coverageProbe,
    );
    final _ReplayCollectionStream? replay =
        _streamCache[raw ? 'raw|$cacheKey' : cacheKey];
    final List<Map<String, dynamic>>? confirmed = replay?.liveLatest;
    if (confirmed != null &&
        (collectionRowsComplete(confirmed) ||
            collectionRowsCoverage(confirmed) != null)) {
      return confirmed;
    }
    if (collectionName == 'products') {
      final iterator = StreamIterator(watchPagedProducts(_firestore));
      late final List<Map<String, dynamic>> rows;
      try {
        if (!await iterator.moveNext().timeout(
          timeout ?? const Duration(seconds: 30),
        )) {
          throw StateError('Catalogue stream ended before a complete page.');
        }
        rows = iterator.current;
      } finally {
        await iterator.cancel();
      }
      final sorted = List<Map<String, dynamic>>.of(rows);
      if (orderBy != null && orderBy.trim().isNotEmpty) {
        _sortRowsInMemory(sorted, field: orderBy, descending: descending);
      }
      final complete = CollectionRows(sorted, isComplete: true);
      replay?.seed(complete);
      return complete;
    }
    if (!raw && _isBridgeCollection(collectionName)) {
      final List<Map<String, dynamic>> rows = await _getBridgeCollectionOnce(
        collectionName,
      );
      final List<Map<String, dynamic>> sorted = collectionName == 'visit_logs'
          ? visitBridgeRows(
              rows,
              locationSource: collectionRowsLocationCoverage(rows),
              orderBy: orderBy,
              descending: descending,
              limit: limit,
            )
          : _sortAndLimitRows(
              CollectionRows(
                rows,
                isComplete: collectionRowsComplete(rows),
                coveredSince: collectionRowsCoverage(rows),
              ),
              orderBy: orderBy,
              descending: descending,
              limit: limit,
              defaultDescending: true,
            );
      replay?.seed(sorted);
      return sorted;
    }

    if (_isPreciseLocationCollection(collectionName)) {
      final List<Map<String, dynamic>> rows =
          await _getPreciseLocationCollectionOnce(
            collectionName,
            orderBy: orderBy,
            descending: descending,
            limit: limit,
            timeout: timeout,
          );
      replay?.seed(rows);
      return rows;
    }

    final bool sortInMemory = _shouldSortInMemory(collectionName, orderBy);
    final bool capped = limit != null && limit > 0;

    Query<Map<String, dynamic>> query = _firestore.collection(collectionName);
    final bool pushOrderToServer = capped || !sortInMemory;
    if (pushOrderToServer && orderBy != null && orderBy.trim().isNotEmpty) {
      query = query.orderBy(orderBy, descending: descending);
    }
    if (capped) {
      query = query.limit(limit);
    }

    final request = readCoveredQuery(
      query,
      probe: coverageProbe && capped && pushOrderToServer && orderBy != null
          ? _firestore
                .collection(collectionName)
                .orderBy(FieldPath.documentId)
                .limit(limit + 1)
          : null,
      limit: limit,
    );
    final List<Map<String, dynamic>> rows = timeout == null
        ? await request
        : await request.timeout(timeout);
    if (sortInMemory && !pushOrderToServer) {
      final sorted = List<Map<String, dynamic>>.of(rows);
      _sortRowsInMemory(sorted, field: orderBy!, descending: descending);
      final result = CollectionRows(
        sorted,
        isComplete: collectionRowsComplete(rows),
        coveredSince: collectionRowsCoverage(rows),
      );
      replay?.seed(result);
      return result;
    }

    replay?.seed(rows);

    return rows;
  }

  Future<List<Map<String, dynamic>>> _getPreciseLocationCollectionOnce(
    String collectionName, {
    String? orderBy,
    required bool descending,
    int? limit,
    Duration? timeout,
    GetOptions? options,
    bool requireReadableScope = false,
  }) async {
    final _PreciseLocationScope scope = await _resolvePreciseLocationScope();
    if (scope.resolutionFailed) {
      throw StateError(
        'Your access scope could not be resolved. Check your connection and try again.',
      );
    }
    if (!scope.canRead) {
      if (requireReadableScope) {
        throw StateError(
          'Your account has no authorized precise-location scope. Verify '
          'your active role, branch, or assigned salespeople.',
        );
      }
      return <Map<String, dynamic>>[];
    }

    final bool sortInMemory = _shouldSortInMemory(collectionName, orderBy);
    final bool capped = limit != null && limit > 0;
    final bool pushOrderToServer = capped || !sortInMemory;
    final List<Query<Map<String, dynamic>>> scopedQueries =
        _preciseLocationQueries(
          _firestore.collection(collectionName),
          scope,
          collectionName: collectionName,
        );
    if (scopedQueries.isEmpty) {
      if (requireReadableScope) {
        throw StateError('No authorized precise-location query is available.');
      }
      return <Map<String, dynamic>>[];
    }

    final request = Future.wait(
      scopedQueries.map((base) {
        Query<Map<String, dynamic>> query = base;
        if (pushOrderToServer &&
            orderBy != null &&
            orderBy.trim().isNotEmpty &&
            collectionName != 'retailers') {
          query = query.orderBy(orderBy, descending: descending);
        }
        if (capped) query = query.limit(limit);
        return readCoveredQuery(
          query,
          probe: capped && pushOrderToServer && orderBy != null
              ? base.orderBy(FieldPath.documentId).limit(limit + 1)
              : null,
          limit: limit,
          options: options,
        );
      }),
    );
    final chunks = timeout == null
        ? await request
        : await request.timeout(timeout);
    final byId = <String, Map<String, dynamic>>{};
    for (final rows in chunks) {
      for (final row in rows) {
        byId[row['docId'] as String] = row;
      }
    }
    final rows = byId.values.toList();
    if (orderBy != null && orderBy.trim().isNotEmpty) {
      _sortRowsInMemory(rows, field: orderBy, descending: descending);
    }
    return CollectionRows(
      capped ? rows.take(limit) : rows,
      isComplete:
          chunks.every(collectionRowsComplete) &&
          (!capped || rows.length < limit),
    );
  }

  Future<List<Map<String, dynamic>>> getOrdersPageBefore({
    OrderPageCursor? before,
    int limit = 200,
  }) async {
    if (!AppRuntime.firebaseReady || limit <= 0) {
      return <Map<String, dynamic>>[];
    }
    final _PreciseLocationScope scope = await _resolvePreciseLocationScope();
    if (scope.resolutionFailed) {
      throw StateError(
        'Your access scope could not be resolved. Check your connection and try again.',
      );
    }
    if (!scope.canRead) return <Map<String, dynamic>>[];
    final List<Query<Map<String, dynamic>>> scopedQueries =
        _preciseLocationQueries(
          _firestore.collection('orders'),
          scope,
          collectionName: 'orders',
        );
    if (scopedQueries.isEmpty) return <Map<String, dynamic>>[];

    final List<QuerySnapshot<Map<String, dynamic>>> snapshots =
        await Future.wait(
          scopedQueries.map((Query<Map<String, dynamic>> baseQuery) {
            return buildOrdersPageQuery(
              baseQuery,
              before: before,
            ).limit(limit).get();
          }),
        );
    final Map<String, Map<String, dynamic>> rowsById =
        <String, Map<String, dynamic>>{};
    for (final QuerySnapshot<Map<String, dynamic>> snapshot in snapshots) {
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snapshot.docs) {
        rowsById[doc.id] = <String, dynamic>{...doc.data(), 'docId': doc.id};
      }
    }
    final List<Map<String, dynamic>> rows = rowsById.values.toList(
      growable: false,
    );
    rows.sort((Map<String, dynamic> left, Map<String, dynamic> right) {
      final int timestampOrder = _sortValue(
        right,
        'submittedAt',
      ).compareTo(_sortValue(left, 'submittedAt'));
      if (timestampOrder != 0) return timestampOrder;
      return _readText(
        right['docId'],
        fallback: '',
      ).compareTo(_readText(left['docId'], fallback: ''));
    });
    return rows.length > limit
        ? rows.take(limit).toList(growable: false)
        : rows;
  }

  Future<DocumentReference<Map<String, dynamic>>> addDocument({
    required String collectionName,
    required Map<String, dynamic> data,
  }) async {
    final DocumentReference<Map<String, dynamic>> reference = await _firestore
        .collection(collectionName)
        .add(<String, dynamic>{
          ...data,
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
    _queueAdminNotification(
      collectionName: collectionName,
      action: 'created',
      data: data,
      docId: reference.id,
    );
    await AuditLogService.instance.record(
      action: 'created',
      entityType: collectionName,
      entityId: reference.id,
      summary: 'Created ${_auditLabel(collectionName, data, reference.id)}',
    );
    return reference;
  }

  Future<void> upsertDocument({
    required String collectionName,
    String? docId,
    required Map<String, dynamic> data,
    bool merge = true,
  }) async {
    if (!AppRuntime.firebaseReady) return;

    final bool isCreate = docId == null || docId.isEmpty;
    final String finalDocId = isCreate ? _uuid.v4() : docId;
    final Map<String, dynamic> payload = <String, dynamic>{
      ...data,
      'updatedAt': FieldValue.serverTimestamp(),
      if (isCreate) 'createdAt': FieldValue.serverTimestamp(),
    };
    final DocumentReference<Map<String, dynamic>> document = _firestore
        .collection(collectionName)
        .doc(finalDocId);
    if (merge) {
      await document.set(payload, SetOptions(merge: true));
    } else {
      await document.set(payload);
    }
    await recordDocumentUpsert(
      collectionName: collectionName,
      isCreate: isCreate,
      data: data,
      docId: finalDocId,
    );
  }

  Future<void> mergeDocumentIfUnchanged({
    required String collectionName,
    required String docId,
    required bool Function(Map<String, dynamic>? current) stillMatches,
    required Map<String, dynamic> data,
    required String staleMessage,
  }) async {
    if (!AppRuntime.firebaseReady) return;
    final DocumentReference<Map<String, dynamic>> document = _firestore
        .collection(collectionName)
        .doc(docId);
    await _firestore.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> current = await transaction
          .get(document);
      if (!current.exists || !stillMatches(current.data())) {
        throw StateError(staleMessage);
      }
      transaction.set(document, <String, dynamic>{
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
    await recordDocumentUpsert(
      collectionName: collectionName,
      isCreate: false,
      data: data,
      docId: docId,
    );
  }

  Future<void> createDocumentIfAbsent({
    required String collectionName,
    required String docId,
    required Map<String, dynamic> data,
    String? duplicateMessage,
  }) async {
    if (!AppRuntime.firebaseReady) {
      throw StateError('The catalogue is not connected. Try again.');
    }
    final DocumentReference<Map<String, dynamic>> document = _firestore
        .collection(collectionName)
        .doc(docId);
    final bool created = await _firestore.runTransaction<bool>((
      Transaction transaction,
    ) async {
      final DocumentSnapshot<Map<String, dynamic>> current = await transaction
          .get(document);
      if (current.exists) return false;
      transaction.set(document, <String, dynamic>{
        ...data,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
    if (!created) {
      throw StateError(
        duplicateMessage ??
            'A product with this brand and product code already exists. Open it from the catalogue to edit it.',
      );
    }
    await recordDocumentUpsert(
      collectionName: collectionName,
      isCreate: true,
      data: data,
      docId: docId,
    );
  }

  Future<bool> ensureDocument({
    required String collectionName,
    required String docId,
    required Map<String, dynamic> data,
  }) async {
    if (!AppRuntime.firebaseReady) return false;
    final DocumentReference<Map<String, dynamic>> document = _firestore
        .collection(collectionName)
        .doc(docId);
    final bool created = await _firestore.runTransaction<bool>((
      Transaction transaction,
    ) async {
      final DocumentSnapshot<Map<String, dynamic>> current = await transaction
          .get(document);
      if (current.exists) return false;
      transaction.set(document, <String, dynamic>{
        ...data,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
    if (created) {
      await recordDocumentUpsert(
        collectionName: collectionName,
        isCreate: true,
        data: data,
        docId: docId,
      );
    }
    return created;
  }

  Future<void> recordDocumentUpsert({
    required String collectionName,
    required bool isCreate,
    required Map<String, dynamic> data,
    required String docId,
  }) async {
    if (!AppRuntime.firebaseReady) return;

    final String action = isCreate ? 'created' : 'updated';
    _queueAdminNotification(
      collectionName: collectionName,
      action: action,
      data: data,
      docId: docId,
    );
    await AuditLogService.instance.record(
      action: action,
      entityType: collectionName,
      entityId: docId,
      summary:
          '${isCreate ? 'Created' : 'Updated'} '
          '${_auditLabel(collectionName, data, docId)}',
    );
  }

  Future<bool> retireRetailer({
    required String retailerId,
    required UserProfile actor,
  }) async {
    final String id = retailerId.trim();
    if (!AppRuntime.firebaseReady || id.isEmpty) return false;
    if (!actor.isAdmin) {
      throw StateError('Only an administrator can retire a retailer.');
    }
    final String actorUid = actor.uid?.trim() ?? '';
    if (actorUid.isEmpty) {
      throw StateError('A signed-in account is required to retire a retailer.');
    }

    final DocumentReference<Map<String, dynamic>> reference = _firestore
        .collection('retailers')
        .doc(id);
    final bool changed = await _firestore.runTransaction<bool>((
      Transaction transaction,
    ) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(reference);
      if (!snapshot.exists || snapshot.data() == null) {
        throw StateError('Retailer not found.');
      }
      final Map<String, dynamic> current = Map<String, dynamic>.from(
        snapshot.data()!,
      );
      if (isDemoRetailerRecord(current)) {
        throw StateError('This retailer is protected and cannot be retired.');
      }
      final String status = (current['status'] ?? '')
          .toString()
          .trim()
          .toLowerCase();
      if (status == 'retired' || current['retiredAt'] != null) {
        return false;
      }
      transaction.update(reference, <String, dynamic>{
        'status': 'retired',
        'stockListVisible': false,
        'retiredAt': FieldValue.serverTimestamp(),
        'retiredByUid': actorUid,
        'retiredByRole': actor.role,
        'updatedAt': FieldValue.serverTimestamp(),
      });
      return true;
    });
    if (changed) {
      await AuditLogService.instance.record(
        action: 'retired',
        entityType: 'retailers',
        entityId: id,
        summary: 'Retired retailer $id',
        actor: actor,
        metadata: <String, dynamic>{
          'status': 'retired',
          'stockListVisible': false,
        },
      );
    }
    return changed;
  }

  Future<void> deleteDocument({
    required String collectionName,
    required String docId,
  }) async {
    if (!AppRuntime.firebaseReady) return;
    await _firestore.collection(collectionName).doc(docId).delete();
    _queueAdminNotification(
      collectionName: collectionName,
      action: 'deleted',
      data: <String, dynamic>{'docId': docId},
      docId: docId,
    );
    await AuditLogService.instance.record(
      action: 'deleted',
      entityType: collectionName,
      entityId: docId,
      summary: 'Deleted $collectionName record $docId',
    );
  }

  Future<Map<String, Map<String, dynamic>>> getActionCentreUserStatuses(
    String uid, {
    bool throwOnError = false,
  }) async {
    if (!AppRuntime.firebaseReady || uid.trim().isEmpty) {
      if (throwOnError) {
        throw StateError('Action Centre status is unavailable.');
      }
      return <String, Map<String, dynamic>>{};
    }
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('action_centre_user_status')
          .where('uid', isEqualTo: uid)
          .limit(500)
          .get();
      final Map<String, Map<String, dynamic>> byActionId =
          <String, Map<String, dynamic>>{};
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snapshot.docs) {
        final Map<String, dynamic> data = Map<String, dynamic>.from(doc.data());
        final String actionId = (data['actionId'] ?? '').toString().trim();
        if (actionId.isEmpty) continue;
        byActionId[actionId] = data;
      }
      return byActionId;
    } catch (_) {
      if (throwOnError) rethrow;
      return <String, Map<String, dynamic>>{};
    }
  }

  Future<String?> getActionCentreUserStatus(String uid, String actionId) async {
    if (!AppRuntime.firebaseReady ||
        uid.trim().isEmpty ||
        actionId.trim().isEmpty) {
      throw StateError('Action Centre status is unavailable.');
    }
    final DocumentSnapshot<Map<String, dynamic>> doc = await _firestore
        .collection('action_centre_user_status')
        .doc('${uid}_$actionId')
        .get();
    if (!doc.exists) return null;
    return (doc.data()?['status'] ?? '').toString();
  }

  Future<bool> setActionCentreUserStatusIfUnchanged({
    required String uid,
    required String actionId,
    required String expectedStatus,
    required String status,
  }) async {
    if (!AppRuntime.firebaseReady ||
        uid.trim().isEmpty ||
        actionId.trim().isEmpty) {
      throw StateError('Action Centre status is unavailable.');
    }
    final DocumentReference<Map<String, dynamic>> ref = _firestore
        .collection('action_centre_user_status')
        .doc('${uid}_$actionId');
    return _firestore.runTransaction<bool>((Transaction tx) async {
      final DocumentSnapshot<Map<String, dynamic>> snap = await tx.get(ref);
      final String current = ActionCentreItem.canonicalStatus(
        (snap.data()?['status'] ?? '').toString(),
      );
      if (current != expectedStatus) return false;
      tx.set(ref, <String, dynamic>{
        'uid': uid,
        'actionId': actionId,
        'status': status,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
      return true;
    });
  }

  Future<void> setActionCentreUserStatus({
    required String uid,
    required String actionId,
    required String status,
    String? note,
  }) async {
    if (!AppRuntime.firebaseReady ||
        uid.trim().isEmpty ||
        actionId.trim().isEmpty) {
      return;
    }
    final String docId = '${uid}_$actionId';
    await _firestore
        .collection('action_centre_user_status')
        .doc(docId)
        .set(<String, dynamic>{
          'uid': uid,
          'actionId': actionId,
          'status': status,
          if (note != null) 'note': note,
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true));
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> watchOrder(
    String orderDocumentId,
  ) {
    if (!AppRuntime.firebaseReady || orderDocumentId.trim().isEmpty) {
      return const Stream<DocumentSnapshot<Map<String, dynamic>>>.empty();
    }
    return _orderReference(orderDocumentId).snapshots();
  }

  Future<void> approveOrder({
    required String orderDocumentId,
    required UserProfile currentUser,
    required Map<String, dynamic> order,
  }) async {
    OrderAuthorization.ensureCanDecideOrder(
      currentUser,
      order,
      action: OrderWriteAction.approve,
    );
    try {
      await _writeOrderDecision(
        orderDocumentId: orderDocumentId,
        currentUser: currentUser,
        status: 'approved',
        timestampField: 'approvedAt',
        actorFields: <String, dynamic>{
          'approvedByUid': currentUser.uid,
          'approvedByName': currentUser.name,
          'approvedByRole': currentUser.role,
        },
        issuePurchaseOrder: true,
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'order_approve_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{
          'orderDocumentId': orderDocumentId,
          'actorRole': currentUser.role,
          'actorUid': currentUser.uid,
        },
      );
      rethrow;
    }
  }

  Future<void> rejectOrder({
    required String orderDocumentId,
    required UserProfile currentUser,
    required Map<String, dynamic> order,
    String? remark,
  }) async {
    final String safeRemark = (remark ?? '').trim();
    if (safeRemark.length > 500) {
      throw ArgumentError('The rejection remark is limited to 500 characters.');
    }
    OrderAuthorization.ensureCanDecideOrder(
      currentUser,
      order,
      action: OrderWriteAction.reject,
    );
    try {
      await _writeOrderDecision(
        orderDocumentId: orderDocumentId,
        currentUser: currentUser,
        status: 'rejected',
        timestampField: 'rejectedAt',
        actorFields: <String, dynamic>{
          'rejectedByUid': currentUser.uid,
          'rejectedByName': currentUser.name,
          'rejectedByRole': currentUser.role,
          if (safeRemark.isNotEmpty) 'rejectionRemark': safeRemark,
        },
      );
    } catch (error, stackTrace) {
      AppLogger.error(
        'order_reject_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{
          'orderDocumentId': orderDocumentId,
          'actorRole': currentUser.role,
          'actorUid': currentUser.uid,
        },
      );
      rethrow;
    }
  }

  Future<void> _writeOrderDecision({
    required String orderDocumentId,
    required UserProfile currentUser,
    required String status,
    required String timestampField,
    required Map<String, dynamic> actorFields,
    bool issuePurchaseOrder = false,
  }) async {
    if (!AppRuntime.firebaseReady) return;
    final String safeOrderDocumentId = orderDocumentId.trim();
    final String safeStatus = status.trim();
    if (safeOrderDocumentId.isEmpty || safeStatus.isEmpty) return;

    final DocumentReference<Map<String, dynamic>> reference = _orderReference(
      safeOrderDocumentId,
    );

    await _firestore.runTransaction((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(reference);
      if (!snapshot.exists || snapshot.data() == null) {
        throw StateError(
          'This order no longer exists. Refresh the order and try again.',
        );
      }
      final Map<String, dynamic> current = Map<String, dynamic>.from(
        snapshot.data()!,
      );

      OrderAuthorization.ensureCanDecideOrder(
        currentUser,
        current,
        action: safeStatus == 'approved'
            ? OrderWriteAction.approve
            : OrderWriteAction.reject,
      );

      transaction.update(reference, <String, dynamic>{
        'status': safeStatus,
        timestampField: FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
        ...actorFields,
      });

      if (issuePurchaseOrder) {
        _requireConsistentCommercialFacts(current);
        transaction.set(
          _purchaseOrderReference(safeOrderDocumentId),
          purchaseOrderData(safeOrderDocumentId, current, currentUser),
        );
      }
    });

    await AuditLogService.instance.record(
      action: safeStatus,
      entityType: 'orders',
      entityId: safeOrderDocumentId,
      summary:
          '${safeStatus == 'approved' ? 'Approved' : 'Rejected'} order $safeOrderDocumentId',
      actor: currentUser,
    );
  }

  static void _requireConsistentCommercialFacts(Map<String, dynamic> order) {
    if (!orderCommercialFactsAgree(order)) {
      throw const OrderDecisionConflictException(
        "This order's item list does not match its recorded lines and total, "
        'so it cannot be approved. Reject it and ask the salesperson to '
        'submit it again.',
      );
    }
  }

  DocumentReference<Map<String, dynamic>> _purchaseOrderReference(
    String orderDocumentId,
  ) => _firestore.collection('purchase_orders').doc(orderDocumentId.trim());

  static Map<String, dynamic> purchaseOrderData(
    String orderDocumentId,
    Map<String, dynamic> order,
    UserProfile actor, {
    DateTime? now,
  }) {
    String ruleText(String camel, String snake) {
      final Object? camelValue = order[camel];
      if (order.containsKey(camel) && camelValue is String) return camelValue;
      final Object? snakeValue = order[snake];
      return order.containsKey(snake) && snakeValue is String ? snakeValue : '';
    }

    final String salesmanCode = TeamScope.salesmanCodeOf(order);
    final DateTime stamp = (now ?? DateTime.now()).toLocal();
    final String date =
        '${stamp.year.toString().padLeft(4, '0')}'
        '${stamp.month.toString().padLeft(2, '0')}'
        '${stamp.day.toString().padLeft(2, '0')}';
    final String cleanId = orderDocumentId.replaceAll(
      RegExp(r'[^A-Za-z0-9_.-]'),
      '-',
    );
    final String shortId = cleanId.length > 24
        ? cleanId.substring(cleanId.length - 24)
        : cleanId;
    return <String, dynamic>{
      'poNumber': 'PO-$date-$shortId',
      'orderId': orderDocumentId,
      'retailerId': ruleText('retailerId', 'retailer_id'),
      'retailerName': ruleText('retailerName', 'retailer_name'),
      'salesmanCode': salesmanCode,
      'salesmanUid': ruleText('salesmanUid', 'salesman_uid'),
      'branchId': ruleText('branchId', 'branch_id'),
      'totalPrice': order['totalPrice'] ?? 0,
      'lines': order['items'] ?? <dynamic>[],
      'status': 'issued',
      'issuedAt': FieldValue.serverTimestamp(),
      'issuedByUid': actor.uid,
      'issuedByRole': actor.role,
    };
  }

  Future<void> issuePurchaseOrder({
    required String orderDocumentId,
    required UserProfile currentUser,
  }) async {
    if (!AppRuntime.firebaseReady) return;
    if (!currentUser.isActive || !currentUser.isAdmin) {
      throw StateError('Only an administrator can issue a purchase order.');
    }
    final String id = orderDocumentId.trim();
    if (id.isEmpty) return;
    final DocumentReference<Map<String, dynamic>> orderRef = _orderReference(
      id,
    );
    final DocumentReference<Map<String, dynamic>> poRef =
        _purchaseOrderReference(id);
    await _firestore.runTransaction((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> orderSnapshot =
          await transaction.get(orderRef);
      final Map<String, dynamic>? order = orderSnapshot.data();
      if (order == null || '${order['status']}'.toLowerCase() != 'approved') {
        throw StateError('Only an approved order can have a purchase order.');
      }
      if ((await transaction.get(poRef)).exists) {
        throw StateError('A purchase order was already issued for this order.');
      }
      _requireConsistentCommercialFacts(order);
      transaction.set(poRef, purchaseOrderData(id, order, currentUser));
    });
  }

  Stream<List<Map<String, dynamic>>> watchPurchaseOrders({
    required UserProfile currentUser,
    int limit = 500,
  }) {
    if (!AppRuntime.firebaseReady) {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    final CollectionReference<Map<String, dynamic>> collection = _firestore
        .collection('purchase_orders');
    final Stream<QuerySnapshot<Map<String, dynamic>>> snapshots;
    if (currentUser.isAdmin) {
      snapshots = collection
          .orderBy('issuedAt', descending: true)
          .limit(limit)
          .snapshots();
    } else if (currentUser.isBranchManager &&
        currentUser.branchId.trim().isNotEmpty) {
      final Query<Map<String, dynamic>> branch = collection.where(
        'branchId',
        isEqualTo: currentUser.branchId.trim(),
      );
      snapshots = firestore_query_utils.snapshotsWithIndexFallback(
        branch.orderBy('issuedAt', descending: true).limit(limit),
        branch.limit(limit),
      );
    } else {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    return snapshots.map((QuerySnapshot<Map<String, dynamic>> snapshot) {
      final List<Map<String, dynamic>> rows = snapshot.docs
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                <String, dynamic>{...doc.data(), 'docId': doc.id},
          )
          .toList();
      rows.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
        final Object? left = a['issuedAt'];
        final Object? right = b['issuedAt'];
        if (left is Timestamp && right is Timestamp) {
          return right.compareTo(left);
        }
        return 0;
      });
      return rows;
    });
  }

  Stream<List<Map<String, dynamic>>> watchOrdersSince(DateTime since) {
    if (!AppRuntime.firebaseReady) {
      return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
    }
    return _buildPreciseLocationStream(
      'orders',
      orderBy: 'submittedAt',
      descending: true,
      limit: _defaultWatchLimit('orders'),
      since: since,
    );
  }

  static const List<String> _branchStaffRoleSpellings = <String>[
    UserProfile.roleSalesman,
    'Salesman',
    'SALESMAN',
    'sales_representative',
    'sales representative',
    'Sales Representative',
    'Sales representative',
    'Sales_Representative',
    'SALES_REPRESENTATIVE',
    'SALES REPRESENTATIVE',
    UserProfile.roleSupervisor,
    'Supervisor',
    'SUPERVISOR',
    UserProfile.roleBranchManager,
    'branch manager',
    'Branch Manager',
    'Branch manager',
    'Branch_Manager',
    'BRANCH_MANAGER',
    'BRANCH MANAGER',
  ];

  static const List<String> _pendingApprovalStatuses = <String>[
    'submitted',
    'pending',
    'pending_approval',
    'held_for_review',
  ];

  static const int _pendingCountCodeChunkSize = 10;

  Future<int> countPendingApprovalOrders() async {
    if (!AppRuntime.firebaseReady) return 0;
    final _PreciseLocationScope scope = await _resolvePreciseLocationScope();
    if (scope.resolutionFailed) {
      throw StateError(
        'Your access scope could not be resolved. Check your connection and try again.',
      );
    }
    int total = 0;
    for (final Query<Map<String, dynamic>> scoped in _preciseLocationQueries(
      _firestore.collection('orders'),
      scope,
      collectionName: 'orders',
      whereInChunkSize: _pendingCountCodeChunkSize,
    )) {
      final AggregateQuerySnapshot counted = await scoped
          .where('status', whereIn: _pendingApprovalStatuses)
          .count()
          .get();
      total += counted.count ?? 0;
    }
    return total;
  }

  Stream<int> watchPendingApprovalCount({
    Duration every = const Duration(seconds: 30),
  }) async* {
    while (true) {
      try {
        yield await countPendingApprovalOrders();
      } catch (error, stackTrace) {
        yield* Stream<int>.error(error, stackTrace);
      }
      await Future<void>.delayed(every);
    }
  }

  Future<OrderWindowRead> getOrdersSubmittedBetween({
    required DateTime start,
    required DateTime end,
    int maxDocuments = 20000,
  }) async {
    if (!AppRuntime.firebaseReady) {
      return const OrderWindowRead(rows: <Map<String, dynamic>>[]);
    }
    final _PreciseLocationScope scope = await _resolvePreciseLocationScope();
    if (scope.resolutionFailed) {
      throw StateError(
        'Your access scope could not be resolved. Check your connection and try again.',
      );
    }
    if (!scope.canRead) {
      return const OrderWindowRead(rows: <Map<String, dynamic>>[]);
    }
    final Map<String, Map<String, dynamic>> byId =
        <String, Map<String, dynamic>>{};
    final bool truncated = await _readDateWindow(
      collection: 'orders',
      field: 'submittedAt',
      scope: scope,
      start: start,
      end: end,
      maxDocuments: maxDocuments,
      into: byId,
    );
    return OrderWindowRead(
      rows: byId.values.toList(growable: false),
      truncated: truncated,
    );
  }

  Future<VisitWindowRead> getVisitsBetween({
    required DateTime start,
    required DateTime end,
    int maxDocumentsPerCollection = 20000,
    void Function(int documentsRead)? onProgress,
  }) async {
    if (!AppRuntime.firebaseReady) {
      return const VisitWindowRead(rows: <Map<String, dynamic>>[]);
    }
    final _PreciseLocationScope scope = await _resolvePreciseLocationScope();
    if (scope.resolutionFailed) {
      throw StateError(
        'Your access scope could not be resolved. Check your connection and try again.',
      );
    }
    if (!scope.canRead) {
      return const VisitWindowRead(rows: <Map<String, dynamic>>[]);
    }
    int read = 0;
    void progress(int pageDocuments) {
      read += pageDocuments;
      onProgress?.call(read);
    }

    final Map<String, Map<String, dynamic>> logs =
        <String, Map<String, dynamic>>{};
    final bool logsTruncated = await _readDateWindow(
      collection: 'visit_logs',
      field: 'arrivalTime',
      scope: scope,
      start: start,
      end: end,
      maxDocuments: maxDocumentsPerCollection,
      into: logs,
      onPage: progress,
    );
    final Map<String, Map<String, dynamic>> stops =
        <String, Map<String, dynamic>>{};
    final bool stopsTruncated = await _readDateWindow(
      collection: 'route_stop_progress',
      field: 'arrivedAt',
      scope: scope,
      start: start,
      end: end,
      maxDocuments: maxDocumentsPerCollection,
      into: stops,
      onPage: progress,
    );

    int withoutTimestamp = 0;
    for (final Query<Map<String, dynamic>> scoped in _preciseLocationQueries(
      _firestore.collection('visit_logs'),
      scope,
      collectionName: 'visit_logs',
    )) {
      final int all = (await scoped.count().get()).count ?? 0;
      final AggregateQuerySnapshot dated = await scoped
          .where(
            'arrivalTime',
            isGreaterThanOrEqualTo: Timestamp.fromMillisecondsSinceEpoch(0),
          )
          .count()
          .get();
      withoutTimestamp += all - (dated.count ?? 0);
    }

    final List<Map<String, dynamic>> stopRows = stops.values
        .map(routeStopProgressToVisitRow)
        .whereType<Map<String, dynamic>>()
        .toList(growable: false);
    return VisitWindowRead(
      rows: dedupeAssignedRouteVisits(<Map<String, dynamic>>[
        ...logs.values,
        ...stopRows,
      ]),
      routeStopRows: stopRows,
      visitLogsTruncated: logsTruncated,
      routeStopsTruncated: stopsTruncated,
      rowsWithoutTimestamp: withoutTimestamp,
    );
  }

  Future<bool> _readDateWindow({
    required String collection,
    required String field,
    required _PreciseLocationScope scope,
    required DateTime start,
    required DateTime end,
    required int maxDocuments,
    required Map<String, Map<String, dynamic>> into,
    void Function(int pageDocuments)? onPage,
  }) async {
    for (final Query<Map<String, dynamic>> scoped in _preciseLocationQueries(
      _firestore.collection(collection),
      scope,
      collectionName: collection,
    )) {
      final Query<Map<String, dynamic>> window = scoped
          .where(field, isGreaterThanOrEqualTo: Timestamp.fromDate(start))
          .where(field, isLessThan: Timestamp.fromDate(end))
          .orderBy(field, descending: true);
      DocumentSnapshot<Map<String, dynamic>>? cursor;
      while (true) {
        Query<Map<String, dynamic>> page = window.limit(_maintenancePageSize);
        if (cursor != null) page = page.startAfterDocument(cursor);
        final QuerySnapshot<Map<String, dynamic>> snapshot = await page.get();
        for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
            in snapshot.docs) {
          into[doc.id] = <String, dynamic>{...doc.data(), 'docId': doc.id};
        }
        onPage?.call(snapshot.docs.length);
        if (snapshot.docs.length < _maintenancePageSize) break;
        if (into.length >= maxDocuments) return true;
        cursor = snapshot.docs.last;
      }
    }
    return false;
  }

  Future<void> deleteOrder({
    required String orderDocumentId,
    required UserProfile currentUser,
    required Map<String, dynamic> order,
  }) async {
    await _deleteOrderAtomically(
      orderDocumentId: orderDocumentId,
      currentUser: currentUser,
    );
  }

  Future<bool> _deleteOrderAtomically({
    required String orderDocumentId,
    required UserProfile currentUser,
    _OrderPurgeDeleteGuard? purge,
  }) async {
    OrderAuthorization.ensureCanDeleteOrder(currentUser);
    if (!AppRuntime.firebaseReady) return false;
    final String safeOrderDocumentId = orderDocumentId.trim();
    if (safeOrderDocumentId.isEmpty) return false;
    final String actorUid = currentUser.uid?.trim() ?? '';
    if (actorUid.isEmpty) {
      throw StateError('The signed-in user identity is unavailable.');
    }
    final DocumentReference<Map<String, dynamic>> orderReference =
        _orderReference(safeOrderDocumentId);
    final DocumentReference<Map<String, dynamic>> auditReference = _firestore
        .collection('order_audit_logs')
        .doc(safeOrderDocumentId);
    try {
      return await _firestore.runTransaction<bool>((
        Transaction transaction,
      ) async {
        final DocumentSnapshot<Map<String, dynamic>> snapshot =
            await transaction.get(orderReference);
        if (purge != null) {
          final DocumentSnapshot<Map<String, dynamic>> settings =
              await transaction.get(_orderPurgeSettingsReference);
          final DocumentSnapshot<Map<String, dynamic>> backup =
              await transaction.get(purge.exportReference);
          final Map<String, dynamic> state =
              settings.data() ?? <String, dynamic>{};
          _ensureOrderPurgeLock(state, purge.runId);
          final Object? backedOrders = backup.data()?['orders'];
          if (backup.data()?['runId'] != purge.runId ||
              backedOrders is! Map ||
              !sameFirestoreValue(
                backedOrders[safeOrderDocumentId],
                purge.exportedOrder,
              )) {
            throw StateError(
              'The order purge backup is unavailable or changed.',
            );
          }
          final bool unchanged =
              snapshot.exists &&
              sameFirestoreValue(snapshot.data(), purge.exportedOrder) &&
              _isOldFinalOrder(snapshot.data()!, purge.cutoff);
          transaction.update(_orderPurgeSettingsReference, <String, dynamic>{
            'runLeaseUntil': Timestamp.fromDate(
              DateTime.now().add(_orderPurgeLease),
            ),
            unchanged ? 'runDeletedCount' : 'runSkippedCount':
                FieldValue.increment(1),
          });
          transaction.update(purge.exportReference, <String, dynamic>{
            unchanged ? 'deletedCount' : 'keptChangedCount':
                FieldValue.increment(1),
          });
          if (!unchanged) return false;
        }
        if (!snapshot.exists || snapshot.data() == null) {
          throw StateError(
            'This order no longer exists. Refresh the order and try again.',
          );
        }
        final Map<String, dynamic> current = Map<String, dynamic>.from(
          snapshot.data()!,
        );
        OrderAuthorization.ensureCanDeleteOrder(
          currentUser,
          order: purge == null ? current : null,
        );
        transaction.set(auditReference, <String, dynamic>{
          'action': 'delete',
          'orderDocumentId': safeOrderDocumentId,
          'orderId': _readText(
            current['orderId'],
            fallback: safeOrderDocumentId,
          ),
          'previousStatus': _readText(current['status'], fallback: ''),
          'actorUid': actorUid,
          'actorRole': currentUser.role,
          'retailerId': _readText(
            current['retailerId'] ?? current['retailer_id'],
            fallback: '',
          ),
          'salesmanUid': _readText(
            current['salesmanUid'] ?? current['salesman_uid'],
            fallback: '',
          ),
          'occurredAt': FieldValue.serverTimestamp(),
        });
        transaction.delete(orderReference);
        return true;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'order_delete_failed',
        error: error,
        stackTrace: stackTrace,
        fields: <String, Object?>{
          'orderDocumentId': orderDocumentId,
          'actorRole': currentUser.role,
          'actorUid': currentUser.uid,
        },
      );
      rethrow;
    }
  }

  DocumentReference<Map<String, dynamic>> _orderReference(
    String orderDocumentId,
  ) {
    return _firestore.collection('orders').doc(orderDocumentId.trim());
  }

  Stream<List<Map<String, dynamic>>> _buildRealtimeStream(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
  }) {
    if (collectionName == 'orders') {
      return _buildOrderBridgeStream(
        orderBy: orderBy,
        descending: descending,
        limit: limit,
      );
    }
    if (collectionName == 'visit_logs') {
      return _buildVisitLogBridgeStream(
        orderBy: orderBy,
        descending: descending,
        limit: limit,
      );
    }
    if (collectionName == 'notification_logs' ||
        collectionName == 'notifications') {
      return _buildNotificationBridgeStream(
        orderBy: orderBy,
        descending: descending,
        limit: limit,
      );
    }
    return _buildCollectionStream(
      collectionName,
      orderBy: orderBy,
      descending: descending,
      limit: limit,
      coverageProbe: coverageProbe,
    );
  }

  bool _isBridgeCollection(String collectionName) {
    return collectionName == 'orders' ||
        collectionName == 'visit_logs' ||
        collectionName == 'notification_logs' ||
        collectionName == 'notifications';
  }

  Future<List<Map<String, dynamic>>> _getBridgeCollectionOnce(
    String collectionName,
  ) async {
    final bool retailerLookup =
        collectionName != 'notification_logs' &&
        collectionName != 'notifications';
    final List<String> sources = _bridgeSources(collectionName)
        .where((String source) => !retailerLookup || source != 'retailers')
        .toList(growable: false);

    final List<List<Map<String, dynamic>>> reads = await Future.wait(
      sources.map(
        (String source) => _getRawCollectionOnce(
          source,
          orderBy: _sourceOrderBy[source],
          limit: _sourceLimits[source],
        ),
      ),
    );
    final Map<String, List<Map<String, dynamic>>> sourceRows =
        <String, List<Map<String, dynamic>>>{
          for (int i = 0; i < sources.length; i++) sources[i]: reads[i],
        };
    final Map<String, List<Map<String, dynamic>>> rowsBySource = retailerLookup
        ? await _withRetailerLookup(sourceRows)
        : sourceRows;
    final Iterable<List<Map<String, dynamic>>> results = rowsBySource.values;
    if (collectionName == 'orders') {
      return CollectionRows(
        _mergeOrderSources(rowsBySource),
        isComplete: results.every(collectionRowsComplete),
      );
    }
    if (collectionName == 'visit_logs') {
      final List<Map<String, dynamic>>? locations =
          rowsBySource['gps_tracking'];
      final List<Map<String, dynamic>> visits = _mergeVisitSources(
        rowsBySource,
      );
      return CollectionRows(
        visits,
        isComplete:
            visitCoverageSources.every(
              (String source) => collectionRowsComplete(rowsBySource[source]),
            ) &&
            (!_hasOrderVisits(visits) ||
                collectionRowsComplete(rowsBySource['orders'])),
        locationCoverage: locations is CollectionRows ? locations : null,
      );
    }
    return CollectionRows(
      _mergeNotificationSources(rowsBySource),
      isComplete: results.every(collectionRowsComplete),
    );
  }

  List<String> _bridgeSources(String collectionName) {
    return collectionName == 'orders'
        ? <String>['orders', 'users', 'retailers']
        : collectionName == 'visit_logs'
        ? <String>[
            'visit_logs',
            'route_stop_progress',
            'orders',
            'gps_tracking',
            'users',
            'retailers',
          ]
        : <String>[
            'notification_logs',
            'notifications',
            'orders',
            'visit_logs',
            'gps_tracking',
            'users',
            'retailers',
          ];
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _getRawDocumentsAll(
    String collectionName, {
    int pageSize = _maintenancePageSize,
  }) async {
    if (pageSize <= 0) return <QueryDocumentSnapshot<Map<String, dynamic>>>[];

    final List<Query<Map<String, dynamic>>> baseQueries;
    if (_isPreciseLocationCollection(collectionName)) {
      final _PreciseLocationScope scope = await _resolvePreciseLocationScope();
      if (scope.resolutionFailed) {
        throw StateError(
          'Your access scope could not be resolved. Check your connection and try again.',
        );
      }
      if (!scope.canRead) {
        return <QueryDocumentSnapshot<Map<String, dynamic>>>[];
      }
      baseQueries = _preciseLocationQueries(
        _firestore.collection(collectionName),
        scope,
        collectionName: collectionName,
      );
    } else {
      baseQueries = <Query<Map<String, dynamic>>>[
        _firestore.collection(collectionName),
      ];
    }

    final List<List<QueryDocumentSnapshot<Map<String, dynamic>>>> pages =
        await Future.wait(
          baseQueries.map(
            (Query<Map<String, dynamic>> query) =>
                _readAllDocumentsByQuery(query, pageSize: pageSize),
          ),
        );
    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final List<QueryDocumentSnapshot<Map<String, dynamic>>> page
        in pages) {
      for (final QueryDocumentSnapshot<Map<String, dynamic>> document in page) {
        byId[document.id] = document;
      }
    }
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents = byId
        .values
        .toList(growable: false);
    documents.sort(
      (
        QueryDocumentSnapshot<Map<String, dynamic>> left,
        QueryDocumentSnapshot<Map<String, dynamic>> right,
      ) => left.id.compareTo(right.id),
    );
    return documents;
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  _readAllDocumentsByQuery(
    Query<Map<String, dynamic>> baseQuery, {
    required int pageSize,
  }) async {
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
        <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    String? lastDocumentId;
    while (true) {
      Query<Map<String, dynamic>> query = baseQuery
          .orderBy(FieldPath.documentId)
          .limit(pageSize);
      if (lastDocumentId != null) {
        query = query.startAfter(<Object?>[lastDocumentId]);
      }
      final QuerySnapshot<Map<String, dynamic>> snapshot = await query.get(
        const GetOptions(source: Source.server),
      );
      documents.addAll(snapshot.docs);
      if (snapshot.docs.length < pageSize) break;
      lastDocumentId = snapshot.docs.last.id;
    }
    return documents;
  }

  Future<List<Map<String, dynamic>>> _getRawCollectionAll(
    String collectionName,
  ) async {
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
        await _getRawDocumentsAll(collectionName);
    return documents
        .map(
          (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
              <String, dynamic>{...doc.data(), 'docId': doc.id},
        )
        .toList(growable: false);
  }

  Future<List<Map<String, dynamic>>> _getBridgeCollectionAll(
    String collectionName,
  ) async {
    final List<String> sources = _bridgeSources(collectionName);
    final List<List<Map<String, dynamic>>> results = await Future.wait(
      sources.map(_getRawCollectionAll),
    );
    final Map<String, List<Map<String, dynamic>>> rowsBySource =
        <String, List<Map<String, dynamic>>>{
          for (int i = 0; i < sources.length; i++) sources[i]: results[i],
        };
    if (collectionName == 'orders') {
      return _mergeOrderSources(rowsBySource);
    }
    if (collectionName == 'visit_logs') {
      return _mergeVisitSources(rowsBySource);
    }
    return _mergeNotificationSources(rowsBySource);
  }

  Future<List<Map<String, dynamic>>> getOrdersForExport() async {
    if (!AppRuntime.firebaseReady) {
      throw StateError('Order export is not ready.');
    }
    return _getBridgeCollectionAll('orders');
  }

  Future<List<Map<String, dynamic>>> _getCollectionAllForMaintenance(
    String collectionName,
  ) async {
    if (!_isBridgeCollection(collectionName)) {
      return _getRawCollectionAll(collectionName);
    }
    final List<Map<String, dynamic>> rows = await _getBridgeCollectionAll(
      collectionName,
    );
    return _sortAndLimitRows(rows, descending: false, defaultDescending: true);
  }

  Future<List<Map<String, dynamic>>> _getRawCollectionOnce(
    String collectionName, {
    String? orderBy,
    int? limit,
  }) async {
    if (_isPreciseLocationCollection(collectionName)) {
      return _getPreciseLocationCollectionOnce(
        collectionName,
        orderBy: orderBy,
        descending: true,
        limit: limit,
      );
    }
    Query<Map<String, dynamic>> query = _firestore.collection(collectionName);
    if (limit != null && limit > 0) {
      if (orderBy != null && orderBy.trim().isNotEmpty) {
        query = query.orderBy(orderBy, descending: true);
      }
      query = query.limit(limit);
    }
    return readCoveredQuery(
      query,
      limit: limit,
      probe: limit != null && limit > 0 && orderBy != null
          ? _firestore
                .collection(collectionName)
                .orderBy(FieldPath.documentId)
                .limit(limit + 1)
          : null,
    );
  }

  Stream<List<Map<String, dynamic>>> _buildOrderBridgeStream({
    String? orderBy,
    bool descending = false,
    int? limit,
  }) {
    return _combineSourceStreams(
      <String>['orders', 'users', 'retailers'],
      (Map<String, List<Map<String, dynamic>>> rowsBySource) {
        return _sortAndLimitRows(
          _mergeOrderSources(rowsBySource),
          orderBy: orderBy,
          descending: descending,
          limit: limit,
          defaultDescending: true,
        );
      },
      primarySources: const <String>['orders'],
    );
  }

  Stream<List<Map<String, dynamic>>> _buildVisitLogBridgeStream({
    String? orderBy,
    bool descending = false,
    int? limit,
  }) {
    return _combineSourceStreams(
      visitBridgeSources
          .where((String source) => source != 'retailers')
          .toList(growable: false),
      (Map<String, List<Map<String, dynamic>>> rowsBySource) {
        return visitBridgeRows(
          _mergeVisitSources(rowsBySource),
          locationSource: rowsBySource['gps_tracking'],
          orderSource: rowsBySource['orders'],
          orderBy: orderBy,
          descending: descending,
          limit: limit,
        );
      },
      primarySources: const <String>['visit_logs'],
      coverageSources: visitCoverageSources,
      lookupSources: const <String>['retailers'],
      withLookups: _withRetailerLookup,
    );
  }

  static const Duration _retailerLookupTtl = Duration(minutes: 5);

  static const Duration _retailerMissTtl = Duration(seconds: 60);

  static const Duration _retailerDirectoryWait = Duration(seconds: 8);

  static final Map<String, (Future<_PreciseLocationScope>, DateTime)>
  _retailerScopes = <String, (Future<_PreciseLocationScope>, DateTime)>{};

  static final Map<String, Map<String, DateTime>> _retailerMisses =
      <String, Map<String, DateTime>>{};

  static final Map<String, (Future<List<Map<String, dynamic>>>, DateTime)>
  _retailerDirectories =
      <String, (Future<List<Map<String, dynamic>>>, DateTime)>{};

  static final Map<String, (Future<List<Map<String, dynamic>>>, DateTime)>
  _retailerFullListings =
      <String, (Future<List<Map<String, dynamic>>>, DateTime)>{};

  static final Map<
    String,
    Map<String, (Future<Map<String, dynamic>?>, DateTime)>
  >
  _retailersByKey =
      <String, Map<String, (Future<Map<String, dynamic>?>, DateTime)>>{};

  static const List<String> _retailerIdFields = <String>[
    'retailerId',
    'retailer_id',
    'retailerCode',
    'retailer_code',
    'storeId',
    'store_id',
    'currentRetailerId',
    'lastRetailerId',
  ];

  static const List<String> _retailerNameFields = <String>[
    'retailerName',
    'retailer_name',
    'martName',
    'customerName',
    'customer_name',
    'currentRetailerName',
    'lastRetailerName',
    'storeName',
    'store_name',
  ];

  static String _signedInUid() {
    try {
      return FirebaseAuth.instance.currentUser?.uid ?? 'signed_out';
    } catch (_) {
      return 'signed_out';
    }
  }

  static bool _fresh(DateTime at) =>
      DateTime.now().difference(at) < _retailerLookupTtl;

  Future<List<Map<String, dynamic>>> getRetailerDirectory({
    required int limit,
  }) {
    final String uid = _signedInUid();
    final Future<List<Map<String, dynamic>>> read = getCollectionOnce(
      'retailers',
      limit: limit,
    );
    _retailerDirectories[uid] = (read, DateTime.now());
    unawaited(
      read.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_retailerDirectories[uid]?.$1, read)) {
            _retailerDirectories.remove(uid);
          }
        },
      ),
    );
    return read;
  }

  static ({Set<String> keys, bool nameOnly}) _retailerKeysOf(
    Map<String, List<Map<String, dynamic>>> rowsBySource,
  ) {
    final Set<String> keys = <String>{};
    bool nameOnly = false;
    for (final MapEntry<String, List<Map<String, dynamic>>> source
        in rowsBySource.entries) {
      if (source.key == 'retailers') continue;
      final bool users = source.key == 'users';
      for (final Map<String, dynamic> row in source.value) {
        bool hasId = false;
        for (final String field
            in users
                ? const <String>['currentRetailerId', 'lastRetailerId']
                : _retailerIdFields) {
          if (_normaliseLookupKey(row[field]).isEmpty) continue;
          keys.add(_readText(row[field], fallback: '').trim());
          hasId = true;
        }
        if (!users &&
            !hasId &&
            _retailerNameFields.any(
              (String field) => _normaliseLookupKey(row[field]).isNotEmpty,
            )) {
          nameOnly = true;
        }
      }
    }
    return (keys: keys, nameOnly: nameOnly);
  }

  Future<Map<String, List<Map<String, dynamic>>>> _withRetailerLookup(
    Map<String, List<Map<String, dynamic>>> rowsBySource,
  ) async {
    CollectionRows retailers;
    try {
      final ({Set<String> keys, bool nameOnly}) wanted = _retailerKeysOf(
        rowsBySource,
      );
      retailers = await _lookupRetailers(
        wanted.keys,
        nameOnly: wanted.nameOnly,
      );
    } catch (_) {
      retailers = CollectionRows(
        const <Map<String, dynamic>>[],
        isComplete: false,
      );
    }
    return <String, List<Map<String, dynamic>>>{
      ...rowsBySource,
      'retailers': retailers,
    };
  }

  Future<List<Map<String, dynamic>>> _retailerFullListing(String uid) {
    final (Future<List<Map<String, dynamic>>>, DateTime)? cached =
        _retailerFullListings[uid];
    if (cached != null && _fresh(cached.$2)) return cached.$1;
    final Future<List<Map<String, dynamic>>> read = _getRawCollectionOnce(
      'retailers',
      limit: _sourceLimits['retailers'],
    );
    _retailerFullListings[uid] = (read, DateTime.now());
    unawaited(
      read.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_retailerFullListings[uid]?.$1, read)) {
            _retailerFullListings.remove(uid);
          }
        },
      ),
    );
    return read;
  }

  Future<CollectionRows> _lookupRetailers(
    Set<String> keys, {
    required bool nameOnly,
  }) async {
    final String uid = _signedInUid();
    final (Future<List<Map<String, dynamic>>>, DateTime)? cachedDirectory =
        _retailerDirectories[uid];
    final Future<List<Map<String, dynamic>>>? sharedDirectory =
        cachedDirectory != null && _fresh(cachedDirectory.$2)
        ? cachedDirectory.$1
        : null;
    List<Map<String, dynamic>> directory = const <Map<String, dynamic>>[];
    bool directoryRead = false;
    if (sharedDirectory != null) {
      try {
        directory = await sharedDirectory.timeout(_retailerDirectoryWait);
        directoryRead = true;
      } catch (_) {}
    }
    if (directoryRead && collectionRowsComplete(directory)) {
      return CollectionRows(directory, isComplete: true);
    }
    if (nameOnly) {
      try {
        final List<Map<String, dynamic>> listing = await _retailerFullListing(
          uid,
        );
        return CollectionRows(
          listing,
          isComplete: collectionRowsComplete(listing),
        );
      } catch (_) {
        return CollectionRows(directory, isComplete: false);
      }
    }
    final Set<String> listed = <String>{
      for (final Map<String, dynamic> row in directory) ...<String>[
        for (final String field in _retailerAliasFields)
          _normaliseLookupKey(row[field]),
      ],
    };
    final CollectionRows fetched = await _retailersByKeys(
      keys.where((String key) => !listed.contains(key.toLowerCase())).toSet(),
    );
    return CollectionRows(<Map<String, dynamic>>[
      ...directory,
      ...fetched,
    ], isComplete: fetched.isComplete);
  }

  static const List<String> _retailerAliasFields = <String>[
    'docId',
    'retailerId',
    'retailer_id',
    'retailerCode',
  ];

  Future<_PreciseLocationScope> _retailerLookupScope() async {
    final String uid = _signedInUid();
    final (Future<_PreciseLocationScope>, DateTime)? cached =
        _retailerScopes[uid];
    if (cached != null && _fresh(cached.$2)) return cached.$1;
    final Future<_PreciseLocationScope> resolving =
        _resolvePreciseLocationScope();
    _retailerScopes[uid] = (resolving, DateTime.now());
    final _PreciseLocationScope scope = await resolving;
    if (scope.resolutionFailed &&
        identical(_retailerScopes[uid]?.$1, resolving)) {
      _retailerScopes.remove(uid);
    }
    return scope;
  }

  Future<CollectionRows> _retailersByKeys(Set<String> keys) async {
    if (keys.isEmpty) {
      return CollectionRows(const <Map<String, dynamic>>[], isComplete: true);
    }
    final _PreciseLocationScope scope = await _retailerLookupScope();
    if (scope.resolutionFailed) {
      return CollectionRows(const <Map<String, dynamic>>[], isComplete: false);
    }
    if (!scope.canRead) {
      return CollectionRows(const <Map<String, dynamic>>[], isComplete: true);
    }
    final bool admin = scope.kind == _PreciseLocationScopeKind.admin;
    final String branchId = admin
        ? ''
        : scope.kind == _PreciseLocationScopeKind.branchManager
        ? scope.branchId
        : scope.retailerBranchId;
    if (!admin && branchId.isEmpty) {
      return CollectionRows(const <Map<String, dynamic>>[], isComplete: false);
    }
    final String cacheKey = '${_signedInUid()}|$branchId';
    final Map<String, (Future<Map<String, dynamic>?>, DateTime)> cache =
        _retailersByKey.putIfAbsent(
          cacheKey,
          () => <String, (Future<Map<String, dynamic>?>, DateTime)>{},
        );
    final Map<String, DateTime> misses = _retailerMisses.putIfAbsent(
      cacheKey,
      () => <String, DateTime>{},
    );
    final DateTime now = DateTime.now();
    final List<String> pending = keys
        .where((String key) {
          final DateTime? missedAt = misses[key];
          if (missedAt != null && now.difference(missedAt) < _retailerMissTtl) {
            return false;
          }
          final (Future<Map<String, dynamic>?>, DateTime)? entry = cache[key];
          return entry == null || !_fresh(entry.$2);
        })
        .toList(growable: false);
    if (pending.isNotEmpty) {
      final DateTime at = DateTime.now();
      final Future<_RetailerBatch> batch = _fetchRetailersByKeys(
        pending,
        branchId,
      );
      for (final String key in pending) {
        cache[key] = (
          batch.then((_RetailerBatch result) {
            if (result.denied.contains(key)) {
              throw StateError('Retailer $key could not be read.');
            }
            return result.found[key];
          }),
          at,
        );
      }
    }
    final List<(String, Future<Map<String, dynamic>?>)> entries =
        <(String, Future<Map<String, dynamic>?>)>[
          for (final String key in keys)
            if (cache[key] != null) (key, cache[key]!.$1),
        ];
    final List<_RetailerLookupResult> results = await Future.wait(
      entries.map(((String, Future<Map<String, dynamic>?>) entry) async {
        try {
          return _RetailerLookupResult(
            entry.$1,
            entry.$2,
            await entry.$2,
            true,
          );
        } catch (_) {
          return _RetailerLookupResult(entry.$1, entry.$2, null, false);
        }
      }),
    );
    bool complete = true;
    final Map<String, Map<String, dynamic>> rows =
        <String, Map<String, dynamic>>{};
    for (final _RetailerLookupResult result in results) {
      if (!result.ok) complete = false;
      final Map<String, dynamic>? row = result.row;
      if (row == null) {
        if (identical(cache[result.key]?.$1, result.future)) {
          cache.remove(result.key);
          if (result.ok) misses[result.key] = DateTime.now();
        }
        continue;
      }
      rows[_readText(row['docId'], fallback: result.key)] = row;
    }
    return CollectionRows(rows.values, isComplete: complete);
  }

  static bool _usableDocumentId(String value) =>
      value.isNotEmpty &&
      !value.contains('/') &&
      value != '.' &&
      value != '..' &&
      !(value.startsWith('__') && value.endsWith('__')) &&
      utf8.encode(value).length <= 1500;

  Future<_RetailerBatch> _fetchRetailersByKeys(
    List<String> keys,
    String branchId,
  ) async {
    Query<Map<String, dynamic>> base = _firestore.collection('retailers');
    if (branchId.isNotEmpty) {
      base = base.where('branchId', isEqualTo: branchId);
    }
    final Map<String, List<String>> keysByLower = <String, List<String>>{};
    for (final String key in keys) {
      keysByLower.putIfAbsent(key.toLowerCase(), () => <String>[]).add(key);
    }
    final Map<String, Map<String, dynamic>> found =
        <String, Map<String, dynamic>>{};
    final Set<String> denied = <String>{};
    Iterable<String> variants(String key) => <String>{
      key,
      key.toLowerCase(),
      key.toUpperCase(),
    };

    Future<void> readWhereIn(Object field, List<String> values) async {
      await Future.wait(
        firestore_query_utils
            .chunkFirestoreWhereIn(
              values,
              chunkSize: firestore_query_utils.kFirestoreWhereInMaxValues,
            )
            .map((List<String> chunk) async {
              final QuerySnapshot<Map<String, dynamic>> snapshot;
              try {
                snapshot = await base
                    .where(field, whereIn: chunk)
                    .get(const GetOptions(source: Source.server));
              } on FirebaseException catch (error) {
                if (error.code != 'permission-denied') rethrow;
                for (final String value in chunk) {
                  denied.addAll(
                    keysByLower[value.toLowerCase()] ?? const <String>[],
                  );
                }
                return;
              }
              for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
                  in snapshot.docs) {
                final Map<String, dynamic> row = <String, dynamic>{
                  ...doc.data(),
                  'docId': doc.id,
                };
                for (final String alias in <String>{
                  for (final String field in _retailerAliasFields)
                    _readText(row[field], fallback: '').toLowerCase(),
                }) {
                  for (final String key
                      in keysByLower[alias] ?? const <String>[]) {
                    found.putIfAbsent(key, () => row);
                  }
                }
              }
            }),
      );
    }

    await readWhereIn(
      FieldPath.documentId,
      <String>{
        for (final String key in keys)
          ...variants(key).where(_usableDocumentId),
      }.toList(growable: false),
    );
    for (final String field in const <String>[
      'retailerId',
      'retailerCode',
      'retailer_id',
    ]) {
      await readWhereIn(
        field,
        <String>{
          for (final String key in keys)
            if (!found.containsKey(key) && !denied.contains(key))
              ...variants(key),
        }.toList(growable: false),
      );
    }
    return _RetailerBatch(found: found, denied: denied);
  }

  @visibleForTesting
  static List<Map<String, dynamic>> replayedRows(
    List<Map<String, dynamic>> rows,
  ) {
    return CollectionRows(
      rows.map((Map<String, dynamic> row) => Map<String, dynamic>.from(row)),
      isComplete: collectionRowsComplete(rows),
      coveredSince: collectionRowsCoverage(rows),
      locationCoverage: collectionRowsLocationCoverage(rows),
    );
  }

  @visibleForTesting
  static const List<String> visitBridgeSources = <String>[
    'visit_logs',
    'route_stop_progress',
    'orders',
    'gps_tracking',
    'users',
    'retailers',
  ];

  @visibleForTesting
  static const List<String> visitCoverageSources = <String>[
    'visit_logs',
    'route_stop_progress',
    'users',
    'retailers',
  ];

  static bool _hasOrderVisits(List<Map<String, dynamic>> rows) => rows.any(
    (Map<String, dynamic> row) => row['sourceCollection'] == 'orders',
  );

  @visibleForTesting
  static CollectionRows visitBridgeRows(
    List<Map<String, dynamic>> merged, {
    required List<Map<String, dynamic>>? locationSource,
    List<Map<String, dynamic>>? orderSource,
    String? orderBy,
    bool descending = false,
    int? limit,
  }) {
    final List<Map<String, dynamic>> visits = <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> locations = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> row in merged) {
      (isLocationOnlyVisitRow(row) ? locations : visits).add(row);
    }
    CollectionRows newest(List<Map<String, dynamic>> rows, {int? limit}) =>
        _sortAndLimitRows(
          rows,
          orderBy: orderBy,
          descending: descending,
          limit: limit,
          defaultDescending: true,
        );
    final CollectionRows keptVisits = newest(
      merged is CollectionRows
          ? CollectionRows(
              visits,
              isComplete: merged.isComplete,
              coveredSince: merged.coveredSince,
            )
          : visits,
      limit: limit,
    );
    final CollectionRows keptLocations = newest(locations, limit: limit);
    final bool orderVisits = orderSource != null && _hasOrderVisits(visits);
    return CollectionRows(
      newest(<Map<String, dynamic>>[...keptVisits, ...keptLocations]),
      isComplete:
          keptVisits.isComplete &&
          (!orderVisits || collectionRowsComplete(orderSource)),
      coveredSince: orderVisits
          ? combinedCoverage(<List<Map<String, dynamic>>?>[
              keptVisits,
              orderSource,
            ])
          : keptVisits.coveredSince,
      locationCoverage: CollectionRows(
        const <Map<String, dynamic>>[],
        isComplete:
            collectionRowsComplete(locationSource) && keptLocations.isComplete,
        coveredSince: combinedCoverage(<List<Map<String, dynamic>>?>[
          locationSource,
          keptLocations,
        ]),
      ),
    );
  }

  @visibleForTesting
  static CollectionRows combinedSourceRows(
    List<Map<String, dynamic>> rows,
    Map<String, List<Map<String, dynamic>>> latestRows,
    List<String> sourceCollections, {
    List<String>? coverageSources,
  }) {
    final bool allArrived = latestRows.length == sourceCollections.length;
    final List<List<Map<String, dynamic>>?> counted =
        <List<Map<String, dynamic>>?>[
          for (final String source in coverageSources ?? sourceCollections)
            latestRows[source],
        ];
    return CollectionRows(
      rows,
      isComplete:
          allArrived &&
          counted.every(collectionRowsComplete) &&
          (rows is! CollectionRows || rows.isComplete),
      coveredSince: allArrived
          ? combinedCoverage(<List<Map<String, dynamic>>?>[
              ...counted,
              if (rows is CollectionRows) rows,
            ])
          : null,
      locationCoverage: allArrived
          ? collectionRowsLocationCoverage(rows)
          : null,
    );
  }

  Stream<List<Map<String, dynamic>>> _buildNotificationBridgeStream({
    String? orderBy,
    bool descending = false,
    int? limit,
  }) {
    return _combineSourceStreams(
      <String>[
        'notification_logs',
        'notifications',
        'orders',
        'visit_logs',
        'gps_tracking',
        'users',
        'retailers',
      ],
      (Map<String, List<Map<String, dynamic>>> rowsBySource) {
        return _sortAndLimitRows(
          _mergeNotificationSources(rowsBySource),
          orderBy: orderBy,
          descending: descending,
          limit: limit,
          defaultDescending: true,
        );
      },
      primarySources: const <String>['notification_logs', 'notifications'],
    );
  }

  static const Map<String, int> _sourceLimits = <String, int>{
    'orders': 500,
    'gps_tracking': 500,
    'visit_logs': 500,
    'route_stop_progress': 500,
    'notification_logs': 300,
    'notifications': 300,
    'users': 3000,
    'retailers': 3000,
  };

  static const Map<String, String?> _sourceOrderBy = <String, String?>{
    'orders': 'submittedAt',
    'gps_tracking': 'timestamp',
    'visit_logs': 'arrivalTime',
    'route_stop_progress': 'arrivedAt',
    'notification_logs': 'createdAt',
    'notifications': 'createdAt',
  };

  static final Map<String, _ReplayCollectionStream> _sourceStreamCache =
      <String, _ReplayCollectionStream>{};

  Stream<List<Map<String, dynamic>>> _sharedSourceStream(String source) {
    String uid = 'signed_out';
    try {
      uid = FirebaseAuth.instance.currentUser?.uid ?? 'signed_out';
    } catch (_) {}
    final String cacheKey = '$source|$uid';
    return _sourceStreamCache.putIfAbsent(cacheKey, () {
      return _ReplayCollectionStream(
        () => _buildCollectionStream(
          source,
          orderBy: _sourceOrderBy[source],
          descending: true,
          limit: _sourceLimits[source],
        ),
      );
    }).stream;
  }

  Stream<List<Map<String, dynamic>>> _combineSourceStreams(
    List<String> sourceCollections,
    List<Map<String, dynamic>> Function(
      Map<String, List<Map<String, dynamic>>> rowsBySource,
    )
    buildRows, {
    required List<String> primarySources,
    List<String>? coverageSources,
    List<String> lookupSources = const <String>[],
    Future<Map<String, List<Map<String, dynamic>>>> Function(
      Map<String, List<Map<String, dynamic>>> rowsBySource,
    )?
    withLookups,
  }) {
    late final StreamController<List<Map<String, dynamic>>> controller;
    final Map<String, List<Map<String, dynamic>>> latestRows =
        <String, List<Map<String, dynamic>>>{};
    final List<StreamSubscription<List<Map<String, dynamic>>>> subscriptions =
        <StreamSubscription<List<Map<String, dynamic>>>>[];
    final List<String> allSources = <String>[
      ...sourceCollections,
      ...lookupSources,
    ];
    Timer? coalesceTimer;
    bool emitPending = false;
    int emitGeneration = 0;
    int emittedGeneration = 0;

    void emitRows(Map<String, List<Map<String, dynamic>>> rowsBySource) {
      controller.add(
        combinedSourceRows(
          buildRows(rowsBySource),
          rowsBySource,
          allSources,
          coverageSources: coverageSources,
        ),
      );
    }

    void scheduleEmit() {
      if (controller.isClosed) return;
      emitPending = true;
      coalesceTimer ??= Timer(const Duration(milliseconds: 24), () {
        coalesceTimer = null;
        if (!emitPending || controller.isClosed) return;
        emitPending = false;
        if (!primarySources.every(latestRows.containsKey)) return;
        final Map<String, List<Map<String, dynamic>>> snapshot =
            Map<String, List<Map<String, dynamic>>>.of(latestRows);
        final lookup = withLookups;
        if (lookup == null) {
          emitRows(snapshot);
          return;
        }
        final int generation = ++emitGeneration;
        unawaited(
          lookup(snapshot).then((
            Map<String, List<Map<String, dynamic>>> rowsBySource,
          ) {
            if (controller.isClosed || generation <= emittedGeneration) return;
            emittedGeneration = generation;
            emitRows(rowsBySource);
          }),
        );
      });
    }

    Future<void> cancelSubscriptions() async {
      coalesceTimer?.cancel();
      coalesceTimer = null;
      emitPending = false;
      emitGeneration++;
      emittedGeneration = emitGeneration;
      for (final StreamSubscription<List<Map<String, dynamic>>> subscription
          in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
    }

    controller = StreamController<List<Map<String, dynamic>>>.broadcast(
      onListen: () {
        if (subscriptions.isNotEmpty) return;
        for (final String source in sourceCollections) {
          final StreamSubscription<List<Map<String, dynamic>>> subscription =
              _sharedSourceStream(source).listen(
                (List<Map<String, dynamic>> rows) {
                  latestRows[source] = rows;
                  scheduleEmit();
                },
                onError: (Object error, StackTrace stackTrace) {
                  if (!controller.isClosed) {
                    latestRows[source] = CollectionRows(
                      latestRows[source] ?? const <Map<String, dynamic>>[],
                      isComplete: false,
                    );
                    scheduleEmit();
                    controller.addError(error, stackTrace);
                  }
                },
              );
          subscriptions.add(subscription);
        }
      },
      onCancel: cancelSubscriptions,
    );

    return controller.stream;
  }

  List<Map<String, dynamic>> _mergeVisitSources(
    Map<String, List<Map<String, dynamic>>> rowsBySource,
  ) {
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    final Map<String, Map<String, dynamic>> userIndex = _buildUserIndex(
      rowsBySource['users'] ?? <Map<String, dynamic>>[],
    );
    final Map<String, Map<String, dynamic>> retailerIndex = _buildRetailerIndex(
      rowsBySource['retailers'] ?? <Map<String, dynamic>>[],
    );
    final Map<String, String> orderDocIdIndex = _buildOrderDocIdIndex(
      rowsBySource['orders'] ?? <Map<String, dynamic>>[],
    );

    for (final Map<String, dynamic> row
        in rowsBySource['visit_logs'] ?? <Map<String, dynamic>>[]) {
      if (isDemoRow(row) || isArtificialOrderVisit(row)) continue;
      rows.add(
        _withOrderDocId(
          _enrichVisitRow(
            _normaliseVisitRow(row, sourceCollection: 'visit_logs'),
            userIndex: userIndex,
            retailerIndex: retailerIndex,
          ),
          orderDocIdIndex,
        ),
      );
    }

    for (final Map<String, dynamic> stop
        in rowsBySource['route_stop_progress'] ?? <Map<String, dynamic>>[]) {
      if (isDemoRow(stop)) continue;
      final Map<String, dynamic>? visit = routeStopProgressToVisitRow(stop);
      if (visit == null) continue;
      rows.add(
        _enrichVisitRow(
          visit,
          userIndex: userIndex,
          retailerIndex: retailerIndex,
        ),
      );
    }

    for (final Map<String, dynamic> order
        in rowsBySource['orders'] ?? <Map<String, dynamic>>[]) {
      if (isDemoRow(order) ||
          !hasRecordedVisitTiming(order) ||
          !orderCountsAsVisit(order)) {
        continue;
      }
      rows.add(
        _withOrderDocId(
          _enrichVisitRow(
            _orderToVisitRow(order),
            userIndex: userIndex,
            retailerIndex: retailerIndex,
          ),
          orderDocIdIndex,
        ),
      );
    }

    for (final String source in <String>['gps_tracking']) {
      for (final Map<String, dynamic> row
          in rowsBySource[source] ?? <Map<String, dynamic>>[]) {
        if (isDemoRow(row)) continue;
        rows.add(
          _withOrderDocId(
            _enrichVisitRow(
              _trackingToVisitRow(row, sourceCollection: source),
              userIndex: userIndex,
              retailerIndex: retailerIndex,
            ),
            orderDocIdIndex,
          ),
        );
      }
    }

    for (final Map<String, dynamic> user
        in rowsBySource['users'] ?? <Map<String, dynamic>>[]) {
      if (isDemoRow(user)) continue;
      final double? lat = _readLatitude(user);
      final double? lng = _readLongitude(user);
      final String role = _normaliseRole(
        _readText(user['role'] ?? user['user_group'], fallback: ''),
      );
      if (lat != null && lng != null && role == 'salesman') {
        rows.add(
          _enrichVisitRow(
            _userToTrackingRow(user),
            userIndex: userIndex,
            retailerIndex: retailerIndex,
          ),
        );
      }
    }

    final Map<String, Map<String, dynamic>> deduped =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> row in withoutNonCountingOrderReferences(
      rows,
      rowsBySource['orders'] ?? <Map<String, dynamic>>[],
    )) {
      final String key = _readText(
        row['bridgeKey'],
        fallback: _readText(row['docId'], fallback: _uuid.v4()),
      );
      deduped[key] = row;
    }
    return dedupeAssignedRouteVisits(deduped.values.toList(growable: false));
  }

  @visibleForTesting
  static List<Map<String, dynamic>> withoutNonCountingOrderReferences(
    List<Map<String, dynamic>> rows,
    Iterable<Map<String, dynamic>> orders,
  ) {
    const List<String> orderIdentityFields = <String>[
      'docId',
      'orderDocId',
      'orderDocumentId',
      'firestoreOrderDocId',
      'orderId',
      'order_id',
      'referenceId',
      'reference_id',
    ];
    const List<String> orderReferenceFields = <String>[
      'orderDocId',
      'orderDocumentId',
      'firestoreOrderDocId',
      'orderId',
      'order_id',
      'reference_id',
      'referenceId',
      'lastOrderId',
    ];
    final RegExp bridgePrefix = RegExp(
      r'^(order_notification_|notification_logs_|notifications_|order_)',
    );
    String referenceKey(Object? value) => _normaliseLookupKey(
      _readText(value, fallback: '').replaceFirst(bridgePrefix, ''),
    );

    final Set<String> notCounted = <String>{};
    for (final Map<String, dynamic> order in orders) {
      if (orderCountsAsSale(order)) continue;
      for (final String field in orderIdentityFields) {
        final String key = referenceKey(order[field]);
        if (key.isNotEmpty) notCounted.add(key);
      }
    }
    if (notCounted.isEmpty) return rows;

    return rows
        .map((Map<String, dynamic> row) {
          if (!orderReferenceFields.any(
            (String field) => notCounted.contains(referenceKey(row[field])),
          )) {
            return row;
          }
          final Map<String, dynamic> stripped = Map<String, dynamic>.of(row);
          for (final String field in orderReferenceFields) {
            if (notCounted.contains(referenceKey(row[field]))) {
              stripped.remove(field);
            }
          }
          return stripped;
        })
        .toList(growable: false);
  }

  Map<String, Map<String, dynamic>> _buildUserIndex(
    List<Map<String, dynamic>> users,
  ) {
    final Map<String, Map<String, dynamic>> index =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> user in users) {
      final Map<String, dynamic> safeUser = Map<String, dynamic>.from(user);
      for (final Object? alias in <Object?>[
        safeUser['docId'],
        safeUser['uid'],
        safeUser['employeeCode'],
        safeUser['employee_code'],
        safeUser['staffId'],
        safeUser['staff_id'],
        safeUser['salesmanId'],
        safeUser['salesman_id'],
        safeUser['salesmanCode'],
        safeUser['salesman_code'],
        safeUser['salesmanUid'],
        safeUser['salesman_uid'],
        safeUser['userId'],
        safeUser['user_id'],
        safeUser['uid'],
        safeUser['username'],
        safeUser['email'],
        safeUser['name'],
        safeUser['displayName'],
        safeUser['fullName'],
        safeUser['full_name'],
      ]) {
        _addIndexAlias(index, alias, safeUser);
      }
    }
    return index;
  }

  Map<String, Map<String, dynamic>> _buildRetailerIndex(
    List<Map<String, dynamic>> retailers,
  ) {
    final Map<String, Map<String, dynamic>> index =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> retailer in retailers) {
      final Map<String, dynamic> safeRetailer = Map<String, dynamic>.from(
        retailer,
      );
      for (final Object? alias in <Object?>[
        safeRetailer['docId'],
        safeRetailer['retailerId'],
        safeRetailer['retailer_id'],
        safeRetailer['retailerCode'],
        safeRetailer['name'],
        safeRetailer['retailerName'],
        safeRetailer['retailer_name'],
        safeRetailer['martName'],
        safeRetailer['customerName'],
        safeRetailer['customer_name'],
        safeRetailer['storeName'],
        safeRetailer['store_name'],
      ]) {
        _addIndexAlias(index, alias, safeRetailer);
      }
    }
    return index;
  }

  void _addIndexAlias(
    Map<String, Map<String, dynamic>> index,
    Object? alias,
    Map<String, dynamic> row,
  ) {
    final String key = _normaliseLookupKey(alias);
    if (key.isNotEmpty) index[key] = row;
  }

  Map<String, dynamic>? _matchUser(
    Map<String, Map<String, dynamic>> userIndex,
    Map<String, dynamic> row,
  ) {
    final List<Object?> candidates = <Object?>[
      row['salesmanUid'],
      row['salesman_uid'],
      row['submittedByUid'],
      row['submitted_by_uid'],
      row['salesmanId'],
      row['salesman_id'],
      row['salesmanUid'],
      row['salesman_uid'],
      row['actorId'],
      row['actor_id'],
      row['actorUid'],
      row['actor_uid'],
      row['salesmanCode'],
      row['salesman_code'],
      row['salesmanName'],
      row['salesman_name'],
      row['salesmanEmail'],
      row['salesman_email'],
      row['salesman'],
      row['salesPersonId'],
      row['salespersonId'],
      row['salesPersonName'],
      row['salespersonName'],
      row['submittedBy'],
      row['submitted_by'],
      row['submittedById'],
      row['submitted_by_id'],
      row['submittedByName'],
      row['submitted_by_name'],
      row['createdByName'],
      row['created_by_name'],
      row['userId'],
      row['user_id'],
      row['employeeCode'],
      row['employee_code'],
      row['staffId'],
      row['staff_id'],
      row['createdBy'],
      row['createdById'],
      row['created_by'],
      row['uid'],
      row['email'],
      row['name'],
      row['displayName'],
      _salesmanNameFromNotificationMessage(row['message']),
      _salesmanNameFromNotificationMessage(row['title']),
    ];

    for (final Object? candidate in candidates) {
      final String key = _normaliseLookupKey(candidate);
      if (key.isNotEmpty && userIndex.containsKey(key)) return userIndex[key];
    }

    for (final Object? candidate in candidates) {
      final String key = _compactLookupKey(candidate);
      if (key.length < 3) continue;
      for (final MapEntry<String, Map<String, dynamic>> entry
          in userIndex.entries) {
        final String indexedKey = _compactLookupKey(entry.key);
        if (indexedKey.length < 3) continue;
        if (indexedKey == key ||
            indexedKey.contains(key) ||
            key.contains(indexedKey)) {
          return entry.value;
        }
      }
    }

    return null;
  }

  Map<String, dynamic>? _matchRetailer(
    Map<String, Map<String, dynamic>> retailerIndex,
    Map<String, dynamic> row,
  ) {
    for (final Object? candidate in <Object?>[
      row['retailerId'],
      row['retailer_id'],
      row['retailerCode'],
      row['retailerName'],
      row['retailer_name'],
      row['martName'],
      row['customerName'],
      row['currentRetailerName'],
      row['lastRetailerName'],
      row['storeName'],
      row['store_name'],
      row['customer_name'],
    ]) {
      final String key = _normaliseLookupKey(candidate);
      if (key.isNotEmpty && retailerIndex.containsKey(key)) {
        return retailerIndex[key];
      }
    }
    return null;
  }

  Map<String, dynamic> _enrichVisitRow(
    Map<String, dynamic> row, {
    required Map<String, Map<String, dynamic>> userIndex,
    required Map<String, Map<String, dynamic>> retailerIndex,
  }) {
    final Map<String, dynamic>? user = _matchUser(userIndex, row);
    final Map<String, dynamic>? retailer = _matchRetailer(retailerIndex, row);

    final String rawSalesmanId = _firstUsefulText(<Object?>[
      row['salesmanId'],
      row['salesman_id'],
      row['salesmanCode'],
      row['salesman_code'],
      row['salesPersonId'],
      row['salespersonId'],
      row['userId'],
      row['user_id'],
      row['uid'],
      row['salesmanEmail'],
      row['salesman_email'],
      row['submittedByEmail'],
      row['submitted_by_email'],
      row['email'],
      row['employeeCode'],
      row['employee_code'],
      row['staffId'],
      row['staff_id'],
      row['submittedBy'],
      row['submitted_by'],
      row['submittedById'],
      row['submitted_by_id'],
      row['createdBy'],
      row['created_by'],
    ]);
    final String salesmanId = user == null
        ? rawSalesmanId
        : _userCode(user, fallback: rawSalesmanId);
    final String salesmanName;
    if (user != null) {
      salesmanName = _userDisplayName(
        user,
        fallback: rawSalesmanId.isEmpty ? 'Salesman' : rawSalesmanId,
      );
    } else {
      final String recordName = _firstUsefulText(<Object?>[
        row['salesmanName'],
        row['salesman_name'],
        row['submittedByName'],
        row['submitted_by_name'],
        row['createdByName'],
        row['created_by_name'],
      ]);
      if (recordName.isNotEmpty && !_isGenericSalesmanLabel(recordName)) {
        salesmanName = recordName;
      } else if (rawSalesmanId.isNotEmpty &&
          !_isGenericSalesmanLabel(rawSalesmanId)) {
        salesmanName = rawSalesmanId;
      } else {
        salesmanName = 'Unknown Salesman';
      }
    }

    final String rawRetailerId = _firstUsefulText(<Object?>[
      row['retailerId'],
      row['retailer_id'],
      row['retailerCode'],
      row['retailerName'],
      row['retailer_name'],
    ]);
    final String retailerId = retailer == null
        ? rawRetailerId
        : _firstUsefulText(<Object?>[
            retailer['retailerId'],
            retailer['retailer_id'],
            retailer['docId'],
            rawRetailerId,
          ]);
    final String retailerName = retailer == null
        ? _firstUsefulText(<Object?>[
            row['retailerName'],
            row['retailer_name'],
            row['martName'],
            row['customerName'],
            rawRetailerId,
            'Retailer',
          ])
        : _firstUsefulText(<Object?>[
            retailer['retailerName'],
            retailer['retailer_name'],
            retailer['name'],
            retailer['martName'],
            retailer['customerName'],
            rawRetailerId,
            'Retailer',
          ]);

    final String branchId = user == null
        ? _readText(row['branchId'] ?? row['branch_id'], fallback: '')
        : _firstUsefulText(<Object?>[
            user['branchId'],
            user['branch_id'],
            row['branchId'],
            row['branch_id'],
          ]);
    final String supervisorId = user == null
        ? _readText(row['supervisorId'] ?? row['supervisor_id'], fallback: '')
        : _firstUsefulText(<Object?>[
            user['supervisorId'],
            user['supervisor_id'],
            row['supervisorId'],
            row['supervisor_id'],
          ]);

    final double? existingLat = _readLatitude(row);
    final double? existingLng = _readLongitude(row);
    final double? retailerLat = retailer == null
        ? null
        : _readLatitude(retailer);
    final double? retailerLng = retailer == null
        ? null
        : _readLongitude(retailer);
    final double? resolvedLat = existingLat ?? retailerLat;
    final double? resolvedLng = existingLng ?? retailerLng;
    final bool usedRetailerCoordinates =
        existingLat == null &&
        existingLng == null &&
        resolvedLat != null &&
        resolvedLng != null;

    return <String, dynamic>{
      ...row,
      'salesmanId': salesmanId.isEmpty ? salesmanName : salesmanId,
      'salesman_id': salesmanId.isEmpty ? salesmanName : salesmanId,
      'salesmanName': salesmanName,
      'salesman_name': salesmanName,
      if (user != null) 'salesmanEmail': _readText(user['email'], fallback: ''),
      'retailerId': retailerId,
      'retailer_id': retailerId,
      'retailerName': retailerName,
      'retailer_name': retailerName,
      if (resolvedLat != null) 'gpsLatitude': resolvedLat,
      if (resolvedLat != null) 'gps_latitude': resolvedLat,
      if (resolvedLng != null) 'gpsLongitude': resolvedLng,
      if (resolvedLng != null) 'gps_longitude': resolvedLng,
      if (usedRetailerCoordinates)
        'locationSource': 'retailer coordinates fallback',
      if (branchId.isNotEmpty) 'branchId': branchId,
      if (branchId.isNotEmpty) 'branch_id': branchId,
      if (supervisorId.isNotEmpty) 'supervisorId': supervisorId,
      if (supervisorId.isNotEmpty) 'supervisor_id': supervisorId,
      'trackingStatus': _trackingStatusForRow(row),
    };
  }

  String _firstUsefulText(List<Object?> values) {
    for (final Object? value in values) {
      final String text = _readText(value, fallback: '');
      if (text.isNotEmpty && !_isUnknownText(text)) return text;
    }
    return '';
  }

  String _userCode(Map<String, dynamic> user, {required String fallback}) {
    return _firstUsefulText(<Object?>[
      user['employeeCode'],
      user['employee_code'],
      user['staffId'],
      user['staff_id'],
      user['salesmanId'],
      user['salesman_id'],
      user['salesmanCode'],
      user['salesman_code'],
      user['userId'],
      user['user_id'],
      user['docId'],
      user['uid'],
      user['email'],
      fallback,
    ]);
  }

  String _userDisplayName(
    Map<String, dynamic> user, {
    required String fallback,
  }) {
    return _firstUsefulText(<Object?>[
      user['name'],
      user['displayName'],
      user['fullName'],
      user['username'],
      user['userName'],
      user['user_name'],
      user['email'],
      fallback,
    ]);
  }

  String _trackingStatusForRow(Map<String, dynamic> row) {
    if (isSkippedVisit(row)) return 'Skipped';
    final String explicit = _readText(
      row['status'],
      fallback: '',
    ).toLowerCase();
    if (explicit.contains('complete') ||
        explicit.contains('submit') ||
        explicit.contains('done') ||
        explicit.contains('closed') ||
        explicit.contains('visited')) {
      return 'Visited';
    }
    if (explicit.contains('stop') ||
        explicit.contains('inactive') ||
        explicit.contains('last')) {
      return 'Last seen';
    }
    if (explicit.contains('active') ||
        explicit.contains('current') ||
        explicit.contains('track') ||
        explicit.contains('progress') ||
        explicit.contains('arriv')) {
      return _isRecentRow(row) ? 'Current' : 'Last seen';
    }
    final String departure = _readText(
      row['departureTime'] ?? row['departure_time'],
      fallback: '',
    );
    if (departure.isNotEmpty || row['sourceCollection'] == 'orders') {
      return 'Visited';
    }
    if (row['sourceCollection'] == 'users') return 'Last seen';
    return _isRecentRow(row) ? 'Current' : 'Last seen';
  }

  static bool _isRecentRow(Map<String, dynamic> row) {
    final Object? ts =
        row['lastSeen'] ??
        row['updatedAt'] ??
        row['timestamp'] ??
        row['arrivalTime'] ??
        row['arrival_time'] ??
        row['createdAt'];
    DateTime? dateTime;
    if (ts is Timestamp) {
      dateTime = ts.toDate();
    } else if (ts is DateTime) {
      dateTime = ts;
    } else if (ts != null) {
      dateTime = DateTime.tryParse(ts.toString());
    }
    if (dateTime == null) return false;
    return DateTime.now().toUtc().difference(dateTime.toUtc()) <=
        const Duration(minutes: 20);
  }

  static String _normaliseLookupKey(Object? value) {
    final String text = _readText(value, fallback: '').trim().toLowerCase();
    if (text.isEmpty || _isUnknownText(text)) return '';
    return text;
  }

  static String _dayKeyFromRow(Map<String, dynamic> row) {
    final Object? ts =
        row['createdAt'] ??
        row['created_at'] ??
        row['submittedAt'] ??
        row['submitted_at'] ??
        row['timestamp'] ??
        row['arrivalTime'] ??
        row['arrival_time'] ??
        row['departureTime'] ??
        row['departure_time'] ??
        row['updatedAt'] ??
        row['updated_at'];
    if (ts == null) return '';
    DateTime? dt;
    if (ts is Timestamp) {
      dt = ts.toDate();
    } else if (ts is DateTime) {
      dt = ts;
    }
    if (dt == null) return '';
    final DateTime kl = dt.toUtc().add(const Duration(hours: 8));
    return '${kl.year}-${kl.month.toString().padLeft(2, '0')}-${kl.day.toString().padLeft(2, '0')}';
  }

  static String _compactLookupKey(Object? value) {
    final String text = _normaliseLookupKey(value);
    if (text.isEmpty) return '';
    return text.replaceAll(RegExp(r'[^a-z0-9]'), '');
  }

  static bool _isUnknownText(String value) {
    final String text = value.trim().toLowerCase();
    return text.isEmpty ||
        text == 'unknown' ||
        text == 'unknown salesman' ||
        text == 'null' ||
        text == 'n/a' ||
        text == 'na' ||
        text == 'none' ||
        text == '—' ||
        text == '-' ||
        text == 'salesman not linked' ||
        text == 'salesman';
  }

  static String _normaliseRole(String raw) {
    final String value = raw
        .trim()
        .toLowerCase()
        .replaceAll('-', '_')
        .replaceAll(' ', '_');
    if (value.contains('developer')) return 'developer';
    if (value.contains('admin')) return 'admin';
    if (value.contains('branch') && value.contains('manager')) {
      return 'branch_manager';
    }
    if (value.contains('supervisor')) return 'supervisor';
    if (value.contains('sales') ||
        value.contains('salesman') ||
        value.contains('representative')) {
      return 'salesman';
    }
    return value;
  }

  static bool _isGenericSalesmanLabel(String value) {
    final String text = value.trim().toLowerCase();
    return _isUnknownText(text) ||
        text == 'salesman' ||
        text == 'salesman not linked' ||
        text == 'sales person' ||
        text == 'salesperson' ||
        text == 'sales representative' ||
        text == 'representative';
  }

  List<Map<String, dynamic>> _mergeNotificationSources(
    Map<String, List<Map<String, dynamic>>> rowsBySource,
  ) {
    final Map<String, Map<String, dynamic>> userIndex = _buildUserIndex(
      rowsBySource['users'] ?? <Map<String, dynamic>>[],
    );
    final Map<String, Map<String, dynamic>> retailerIndex = _buildRetailerIndex(
      rowsBySource['retailers'] ?? <Map<String, dynamic>>[],
    );
    final Map<String, String> orderDocIdIndex = _buildOrderDocIdIndex(
      rowsBySource['orders'] ?? <Map<String, dynamic>>[],
    );

    final List<Map<String, dynamic>> orderNotifs = <Map<String, dynamic>>[];
    for (final Map<String, dynamic> order
        in rowsBySource['orders'] ?? <Map<String, dynamic>>[]) {
      if (isDemoRow(order)) continue;
      orderNotifs.add(
        _orderToNotificationRow(
          order,
          userIndex: userIndex,
          retailerIndex: retailerIndex,
        ),
      );
    }

    final Map<String, Map<String, String>> resolvedSalesmanByOrderRef =
        <String, Map<String, String>>{};
    final Map<String, Set<String>> namesByRetailerDay = <String, Set<String>>{};
    final Map<String, String> idsByRetailerDay = <String, String>{};
    final Map<String, Set<String>> namesByDay = <String, Set<String>>{};
    final Map<String, String> idsByDay = <String, String>{};

    void indexResolvedRow(Map<String, dynamic> row) {
      final String name = _readText(
        row['salesmanName'] ?? row['salesman_name'],
        fallback: '',
      );
      if (name.isEmpty ||
          _isGenericSalesmanLabel(name) ||
          _isUnknownText(name)) {
        return;
      }
      final String id = _readText(
        row['salesmanId'] ??
            row['salesman_id'] ??
            row['salesmanUid'] ??
            row['salesman_uid'],
        fallback: '',
      );

      for (final Object? ref in <Object?>[
        row['orderDocumentId'],
        row['orderDocId'],
        row['reference_id'],
        row['referenceId'],
        row['orderId'],
        row['order_id'],
        row['docId'],
      ]) {
        final String key = _normaliseLookupKey(_stripBridgePrefix(ref));
        if (key.isNotEmpty) {
          resolvedSalesmanByOrderRef[key] = <String, String>{
            'name': name,
            'id': id,
          };
        }
      }

      final String retailerKey = _normaliseLookupKey(
        row['retailerId'] ??
            row['retailerName'] ??
            row['retailer_id'] ??
            row['retailer_name'],
      );
      final String day = _dayKeyFromRow(row);
      if (day.isNotEmpty) {
        namesByDay.putIfAbsent(day, () => <String>{}).add(name);
        if (id.isNotEmpty && !_isGenericSalesmanLabel(id)) idsByDay[day] = id;
      }
      if (retailerKey.isNotEmpty && day.isNotEmpty) {
        final String key = '$retailerKey:$day';
        namesByRetailerDay.putIfAbsent(key, () => <String>{}).add(name);
        if (id.isNotEmpty && !_isGenericSalesmanLabel(id)) {
          idsByRetailerDay[key] = id;
        }
      }
    }

    for (final Map<String, dynamic> row in orderNotifs) {
      indexResolvedRow(row);
    }
    for (final Map<String, dynamic> row in _mergeVisitSources(rowsBySource)) {
      indexResolvedRow(row);
    }

    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[
      ...orderNotifs,
    ];

    for (final String sourceCol in <String>[
      'notification_logs',
      'notifications',
    ]) {
      for (final Map<String, dynamic> src
          in rowsBySource[sourceCol] ?? <Map<String, dynamic>>[]) {
        if (isDemoRow(src)) continue;
        Map<String, dynamic> enriched = _enrichNotificationRow(
          _normaliseNotificationRow(src, sourceCollection: sourceCol),
          userIndex: userIndex,
          retailerIndex: retailerIndex,
        );
        enriched = _withOrderDocId(enriched, orderDocIdIndex);
        final String currentName = _readText(
          enriched['salesmanName'] ?? enriched['salesman_name'],
          fallback: '',
        );
        if (currentName.isEmpty || _isUnknownText(currentName.toLowerCase())) {
          final Map<String, String> patch = _notificationSalesmanPatch(
            enriched,
            resolvedSalesmanByOrderRef: resolvedSalesmanByOrderRef,
            namesByRetailerDay: namesByRetailerDay,
            idsByRetailerDay: idsByRetailerDay,
            namesByDay: namesByDay,
            idsByDay: idsByDay,
          );
          final String patchedName = patch['name'] ?? '';
          final String patchedId = patch['id'] ?? '';
          if (patchedName.isNotEmpty) {
            final String type = _readText(
              enriched['notification_type'] ?? enriched['type'],
              fallback: 'notification',
            );
            final String retailerLabel = _readText(
              enriched['retailerName'] ?? enriched['retailer_name'],
              fallback: 'retailer',
            );
            enriched = <String, dynamic>{
              ...enriched,
              if (patchedId.isNotEmpty) 'salesmanId': patchedId,
              if (patchedId.isNotEmpty) 'salesman_id': patchedId,
              'salesmanName': patchedName,
              'salesman_name': patchedName,
              'message': _fallbackNotificationMessage(type, <String, dynamic>{
                ...enriched,
                'salesmanName': patchedName,
                'retailerName': retailerLabel,
              }),
            };
          }
        }
        rows.add(enriched);
      }
    }

    final Map<String, Map<String, dynamic>> deduped =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> row in rows) {
      final String type = _readNotificationType(row, fallback: 'notification');
      final String reference = _readText(
        row['orderDocumentId'] ??
            row['orderDocId'] ??
            row['reference_id'] ??
            row['referenceId'] ??
            row['orderId'],
        fallback: '',
      );
      final String key;
      if (reference.isNotEmpty) {
        key = '$type:$reference';
      } else if (_isOrderNotificationType(type)) {
        final String retailer = _normaliseLookupKey(
          row['retailerId'] ??
              row['retailerName'] ??
              row['retailer_id'] ??
              row['retailer_name'],
        );
        final String salesman = _normaliseLookupKey(
          row['salesmanId'] ??
              row['salesmanName'] ??
              row['salesman_id'] ??
              row['salesman_name'],
        );
        final String day = _dayKeyFromRow(row);
        if (retailer.isNotEmpty) {
          key = '$type:${salesman.isNotEmpty ? salesman : "_"}:$retailer:$day';
        } else {
          key = _readText(
            row['bridgeKey'],
            fallback: _readText(row['docId'], fallback: _uuid.v4()),
          );
        }
      } else {
        key = _readText(
          row['bridgeKey'],
          fallback: _readText(row['docId'], fallback: _uuid.v4()),
        );
      }
      final Map<String, dynamic>? existing = deduped[key];
      if (existing == null ||
          _notificationResolutionScore(row) >=
              _notificationResolutionScore(existing)) {
        deduped[key] = row;
      }
    }
    return deduped.values.toList(growable: false);
  }

  Map<String, String> _notificationSalesmanPatch(
    Map<String, dynamic> notification, {
    required Map<String, Map<String, String>> resolvedSalesmanByOrderRef,
    required Map<String, Set<String>> namesByRetailerDay,
    required Map<String, String> idsByRetailerDay,
    required Map<String, Set<String>> namesByDay,
    required Map<String, String> idsByDay,
  }) {
    for (final Object? ref in <Object?>[
      notification['orderDocumentId'],
      notification['orderDocId'],
      notification['reference_id'],
      notification['referenceId'],
      notification['orderId'],
      notification['order_id'],
    ]) {
      final String key = _normaliseLookupKey(_stripBridgePrefix(ref));
      final Map<String, String>? hit = key.isEmpty
          ? null
          : resolvedSalesmanByOrderRef[key];
      final String name = hit == null ? '' : (hit['name'] ?? '');
      if (name.isNotEmpty && !_isGenericSalesmanLabel(name)) return hit!;
    }

    final String retailerKey = _normaliseLookupKey(
      notification['retailerId'] ??
          notification['retailerName'] ??
          notification['retailer_id'] ??
          notification['retailer_name'] ??
          _retailerNameFromNotificationMessage(notification['message']),
    );
    final String day = _dayKeyFromRow(notification);
    if (retailerKey.isEmpty || day.isEmpty) return const <String, String>{};

    final String matchKey = '$retailerKey:$day';
    final Set<String> names = namesByRetailerDay[matchKey] ?? <String>{};
    final Set<String> cleanNames = names
        .where((String name) => !_isGenericSalesmanLabel(name))
        .toSet();
    if (cleanNames.length == 1) {
      return <String, String>{
        'name': cleanNames.first,
        'id': idsByRetailerDay[matchKey] ?? '',
      };
    }

    final Set<String> dayNames = namesByDay[day] ?? <String>{};
    final Set<String> cleanDayNames = dayNames
        .where((String name) => !_isGenericSalesmanLabel(name))
        .toSet();
    if (cleanDayNames.length == 1) {
      return <String, String>{
        'name': cleanDayNames.first,
        'id': idsByDay[day] ?? '',
      };
    }
    return const <String, String>{};
  }

  Object? _stripBridgePrefix(Object? value) {
    final String raw = _readText(value, fallback: '');
    if (raw.isEmpty) return raw;
    return raw
        .replaceFirst(RegExp(r'^order_notification_'), '')
        .replaceFirst(RegExp(r'^order_'), '')
        .replaceFirst(RegExp(r'^notification_logs_'), '')
        .replaceFirst(RegExp(r'^notifications_'), '');
  }

  String _orderDocIdFromBridgeKey(String bridgeKey) {
    final int separator = bridgeKey.indexOf(':');
    if (separator <= 0 || separator == bridgeKey.length - 1) return '';
    final String source = bridgeKey.substring(0, separator).toLowerCase();
    if (source != 'orders' && source != 'order_notification') return '';
    return bridgeKey.substring(separator + 1).trim();
  }

  String _firestoreOrderDocId(Map<String, dynamic> order) {
    final String explicit = _readText(
      order['orderDocId'] ??
          order['orderDocumentId'] ??
          order['firestoreOrderDocId'],
      fallback: '',
    );
    if (explicit.isNotEmpty) {
      return _readText(_stripBridgePrefix(explicit), fallback: explicit);
    }

    final String bridgeKey = _readText(order['bridgeKey'], fallback: '');
    final String fromBridge = _orderDocIdFromBridgeKey(bridgeKey);
    if (fromBridge.isNotEmpty) {
      return fromBridge;
    }

    final String docId = _readText(order['docId'], fallback: '');
    if (docId.isNotEmpty) {
      return _readText(_stripBridgePrefix(docId), fallback: docId);
    }

    return '';
  }

  Map<String, String> _buildOrderDocIdIndex(List<Map<String, dynamic>> orders) {
    final Map<String, String> index = <String, String>{};
    for (final Map<String, dynamic> order in orders) {
      final String docId = _firestoreOrderDocId(order);
      if (docId.isEmpty) continue;
      for (final Object? alias in <Object?>[
        docId,
        order['orderDocId'],
        order['orderDocumentId'],
        order['firestoreOrderDocId'],
        order['docId'],
        order['orderId'],
        order['order_id'],
        order['referenceId'],
        order['reference_id'],
      ]) {
        final String key = _normaliseLookupKey(_stripBridgePrefix(alias));
        if (key.isNotEmpty) index[key] = docId;
      }
    }
    return index;
  }

  String _resolveOrderDocId(
    Map<String, dynamic> row,
    Map<String, String> orderDocIdIndex,
  ) {
    final String explicit = _readText(
      row['orderDocId'] ?? row['orderDocumentId'] ?? row['firestoreOrderDocId'],
      fallback: '',
    );
    if (explicit.isNotEmpty) {
      return _readText(_stripBridgePrefix(explicit), fallback: explicit);
    }

    final String fromBridge = _orderDocIdFromBridgeKey(
      _readText(row['bridgeKey'], fallback: ''),
    );
    if (fromBridge.isNotEmpty) return fromBridge;

    for (final Object? ref in <Object?>[
      row['reference_id'],
      row['referenceId'],
      row['orderId'],
      row['order_id'],
      row['lastOrderId'],
      row['visitId'],
      row['docId'],
    ]) {
      final String key = _normaliseLookupKey(_stripBridgePrefix(ref));
      final String? docId = key.isEmpty ? null : orderDocIdIndex[key];
      if (docId != null && docId.isNotEmpty) return docId;
    }

    final String source = _readText(
      row['sourceCollection'],
      fallback: '',
    ).toLowerCase();
    if (source == 'orders') {
      return _firestoreOrderDocId(row);
    }
    return '';
  }

  Map<String, dynamic> _withOrderDocId(
    Map<String, dynamic> row,
    Map<String, String> orderDocIdIndex,
  ) {
    final String orderDocId = _resolveOrderDocId(row, orderDocIdIndex);
    if (orderDocId.isEmpty) return row;
    return <String, dynamic>{
      ...row,
      'orderDocId': orderDocId,
      'orderDocumentId': orderDocId,
    };
  }

  int _notificationResolutionScore(Map<String, dynamic> row) {
    int score = 0;
    final String salesmanName = _readText(
      row['salesmanName'] ?? row['salesman_name'],
      fallback: '',
    );
    final String salesmanId = _readText(
      row['salesmanId'] ?? row['salesman_id'],
      fallback: '',
    );
    final String message = _readText(
      row['message'],
      fallback: '',
    ).toLowerCase();
    if (salesmanName.isNotEmpty && !_isGenericSalesmanLabel(salesmanName)) {
      score += 6;
    }
    if (salesmanId.isNotEmpty && !_isGenericSalesmanLabel(salesmanId)) {
      score += 2;
    }
    if (!message.contains('n/a') &&
        !message.contains('unknown') &&
        !message.contains('salesman for')) {
      score += 2;
    }
    if (_readText(row['sourceCollection'], fallback: '') == 'orders') {
      score += 1;
    }
    return score;
  }

  List<Map<String, dynamic>> _mergeOrderSources(
    Map<String, List<Map<String, dynamic>>> rowsBySource,
  ) {
    final Map<String, Map<String, dynamic>> userIndex = _buildUserIndex(
      rowsBySource['users'] ?? <Map<String, dynamic>>[],
    );
    final Map<String, Map<String, dynamic>> retailerIndex = _buildRetailerIndex(
      rowsBySource['retailers'] ?? <Map<String, dynamic>>[],
    );

    return (rowsBySource['orders'] ?? <Map<String, dynamic>>[])
        .where((Map<String, dynamic> order) => !isDemoRow(order))
        .map(
          (Map<String, dynamic> order) => _enrichOrderRow(
            order,
            userIndex: userIndex,
            retailerIndex: retailerIndex,
          ),
        )
        .toList(growable: false);
  }

  Map<String, dynamic> _enrichOrderRow(
    Map<String, dynamic> order, {
    required Map<String, Map<String, dynamic>> userIndex,
    required Map<String, Map<String, dynamic>> retailerIndex,
  }) {
    final String orderDocId = _firestoreOrderDocId(order);
    final Map<String, dynamic> visitLike = _enrichVisitRow(
      _orderToVisitRow(order),
      userIndex: userIndex,
      retailerIndex: retailerIndex,
    );
    final Map<String, dynamic>? user = _matchUser(userIndex, visitLike);

    return <String, dynamic>{
      ...order,
      'docId': orderDocId.isNotEmpty
          ? orderDocId
          : _readText(
              order['docId'],
              fallback: _readText(visitLike['docId'], fallback: _uuid.v4()),
            ).replaceFirst(RegExp(r'^order_'), ''),
      if (orderDocId.isNotEmpty) 'orderDocId': orderDocId,
      if (orderDocId.isNotEmpty) 'orderDocumentId': orderDocId,
      'salesmanId': visitLike['salesmanId'],
      'salesman_id': visitLike['salesman_id'],
      'salesmanName': visitLike['salesmanName'],
      'salesman_name': visitLike['salesman_name'],
      if (visitLike['salesmanEmail'] != null)
        'salesmanEmail': visitLike['salesmanEmail'],
      'salesmanPosition': user == null
          ? _readText(
              order['salesmanPosition'] ?? order['position'] ?? order['role'],
              fallback: 'Salesman',
            )
          : _userPosition(user),
      'retailerId': visitLike['retailerId'],
      'retailer_id': visitLike['retailer_id'],
      'retailerName': visitLike['retailerName'],
      'retailer_name': visitLike['retailer_name'],
      if (visitLike['branchId'] != null) 'branchId': visitLike['branchId'],
      if (visitLike['branch_id'] != null) 'branch_id': visitLike['branch_id'],
      if (visitLike['supervisorId'] != null)
        'supervisorId': visitLike['supervisorId'],
      if (visitLike['supervisor_id'] != null)
        'supervisor_id': visitLike['supervisor_id'],
      'submittedAt':
          _pick(order, <String>[
            'submittedAt',
            'submitted_at',
            'orderDate',
            'order_date',
            'createdAt',
            'created',
            'timestamp',
          ]) ??
          visitLike['departureTime'] ??
          visitLike['arrivalTime'],
      'updatedAt':
          _pick(order, <String>[
            'updatedAt',
            'modified',
            'submittedAt',
            'submitted_at',
            'createdAt',
            'timestamp',
          ]) ??
          visitLike['updatedAt'],
    };
  }

  String _userPosition(Map<String, dynamic> user) {
    final String role = _normaliseRole(
      _readText(
        user['role'] ?? user['user_group'] ?? user['position'],
        fallback: 'salesman',
      ),
    );
    switch (role) {
      case 'developer':
        return 'Developer';
      case 'admin':
        return 'Admin';
      case 'branch_manager':
        return 'Branch Manager';
      case 'supervisor':
        return 'Supervisor';
      case 'salesman':
        return 'Salesman';
      default:
        return role.isEmpty ? 'Salesman' : role;
    }
  }

  Map<String, dynamic> _enrichNotificationRow(
    Map<String, dynamic> row, {
    required Map<String, Map<String, dynamic>> userIndex,
    required Map<String, Map<String, dynamic>> retailerIndex,
  }) {
    final Map<String, dynamic> enrichedVisit = _enrichVisitRow(
      _normaliseVisitRow(
        row,
        sourceCollection: _readText(
          row['sourceCollection'],
          fallback: 'notifications',
        ),
      ),
      userIndex: userIndex,
      retailerIndex: retailerIndex,
    );
    final String type = _readText(
      row['notification_type'] ?? row['type'],
      fallback: 'system_update',
    );
    final String currentMessage = _readText(row['message'], fallback: '');
    final String currentSalesmanName = _readText(
      enrichedVisit['salesmanName'] ?? enrichedVisit['salesman_name'],
      fallback: '',
    );
    final bool hasSpecificSalesman =
        currentSalesmanName.isNotEmpty &&
        !_isGenericSalesmanLabel(currentSalesmanName);
    final bool needsReplacement =
        currentMessage.isEmpty ||
        currentMessage.toLowerCase().contains('n/a') ||
        currentMessage.toLowerCase().contains('unknown') ||
        currentMessage.toLowerCase().contains('salesman not linked') ||
        currentMessage.toLowerCase().contains('salesman for retailer') ||
        (currentMessage.toLowerCase().contains('by salesman') &&
            hasSpecificSalesman);

    return <String, dynamic>{
      ...row,
      'salesmanId': enrichedVisit['salesmanId'],
      'salesman_id': enrichedVisit['salesman_id'],
      'salesmanName': enrichedVisit['salesmanName'],
      'salesman_name': enrichedVisit['salesman_name'],
      'retailerId': enrichedVisit['retailerId'],
      'retailer_id': enrichedVisit['retailer_id'],
      'retailerName': enrichedVisit['retailerName'],
      'retailer_name': enrichedVisit['retailer_name'],
      if (enrichedVisit['branchId'] != null)
        'branchId': enrichedVisit['branchId'],
      if (enrichedVisit['branch_id'] != null)
        'branch_id': enrichedVisit['branch_id'],
      'message': needsReplacement
          ? _fallbackNotificationMessage(type, enrichedVisit)
          : currentMessage,
    };
  }

  Map<String, dynamic> _normaliseVisitRow(
    Map<String, dynamic> source, {
    required String sourceCollection,
  }) {
    final Map<String, dynamic> row = Map<String, dynamic>.from(source);
    final Object? arrival = _pick(row, <String>[
      'arrivalTime',
      'arrival_time',
      'visitStartAt',
      'visitStartedAt',
      'startedAt',
      'startTime',
      'createdAt',
      'created',
      'timestamp',
    ]);
    final Object? departure = _pick(row, <String>[
      'departureTime',
      'departure_time',
      'visitEndAt',
      'visitEndedAt',
      'endedAt',
      'endTime',
      'submittedAt',
      'submitted_at',
    ]);
    final double? lat = _readLatitude(row);
    final double? lng = _readLongitude(row);
    return <String, dynamic>{
      ...row,
      'docId': _readText(row['docId'], fallback: _uuid.v4()),
      'bridgeKey':
          '$sourceCollection:${_readText(row['docId'], fallback: _uuid.v4())}',
      'sourceCollection': sourceCollection,
      'salesmanId': _firstUsefulText(<Object?>[
        row['salesmanUid'],
        row['salesman_uid'],
        row['submittedByUid'],
        row['submitted_by_uid'],
        row['salesmanId'],
        row['salesman_id'],
        row['salesmanCode'],
        row['salesman_code'],
        row['salesPersonId'],
        row['salespersonId'],
        row['userId'],
        row['user_id'],
        row['uid'],
        row['employeeCode'],
        row['employee_code'],
        row['staffId'],
        row['staff_id'],
        row['submittedBy'],
        row['submitted_by'],
        row['submittedById'],
        row['submitted_by_id'],
        row['createdBy'],
        row['created_by'],
      ]),
      'retailerId': _readText(
        _pick(row, <String>[
          'retailerId',
          'retailer_id',
          'retailerCode',
          'retailer_code',
          'storeId',
          'store_id',
        ]),
        fallback: _readText(
          _pick(row, <String>[
            'retailerName',
            'retailer_name',
            'storeName',
            'customerName',
          ]),
          fallback: 'unknown',
        ),
      ),
      'retailerName': _readText(
        _pick(row, <String>[
          'retailerName',
          'retailer_name',
          'martName',
          'customerName',
          'customer_name',
          'storeName',
          'store_name',
        ]),
        fallback: _readText(
          _pick(row, <String>['retailerId', 'retailer_id']),
          fallback: 'Retailer',
        ),
      ),
      'arrivalTime': arrival,
      'arrival_time': arrival,
      'departureTime': departure,
      'departure_time': departure,
      if (lat != null) 'gpsLatitude': lat,
      if (lat != null) 'gps_latitude': lat,
      if (lng != null) 'gpsLongitude': lng,
      if (lng != null) 'gps_longitude': lng,
      'status': _readText(
        row['status'],
        fallback: _readText(departure, fallback: '').isEmpty
            ? 'in progress'
            : 'completed',
      ),
      'createdAt':
          _pick(row, <String>['createdAt', 'created', 'timestamp']) ?? arrival,
      'updatedAt':
          _pick(row, <String>['updatedAt', 'modified', 'timestamp']) ??
          departure ??
          arrival,
    };
  }

  Map<String, dynamic> _orderToVisitRow(Map<String, dynamic> order) {
    final Object? submitted = _pick(order, <String>[
      'submittedAt',
      'submitted_at',
      'orderDate',
      'order_date',
      'createdAt',
      'created',
      'timestamp',
    ]);
    final Object? arrival =
        _pick(order, <String>[
          'arrivalTime',
          'arrival_time',
          'visitStartAt',
          'visitStartedAt',
          'startedAt',
          'createdAt',
          'created',
          'timestamp',
        ]) ??
        submitted;
    final double? lat = _readLatitude(order);
    final double? lng = _readLongitude(order);
    final String orderDocId = _readText(
      _stripBridgePrefix(_firestoreOrderDocId(order)),
      fallback: '',
    );
    final String bridgeId = orderDocId.isNotEmpty
        ? orderDocId
        : _readText(order['docId'], fallback: _uuid.v4());
    return <String, dynamic>{
      ...order,
      'docId': 'order_$bridgeId',
      if (orderDocId.isNotEmpty) 'orderDocId': orderDocId,
      if (orderDocId.isNotEmpty) 'orderDocumentId': orderDocId,
      'bridgeKey': 'orders:$bridgeId',
      'sourceCollection': 'orders',
      'salesmanId': _readText(
        _pick(order, <String>[
          'salesmanUid',
          'salesman_uid',
          'submittedByUid',
          'submitted_by_uid',
          'salesmanId',
          'salesman_id',
          'salesmanCode',
          'salesman_code',
          'salesPersonId',
          'salespersonId',
          'userId',
          'user_id',
          'uid',
          'employeeCode',
          'employee_code',
          'staffId',
          'staff_id',
          'submittedBy',
          'submitted_by',
          'submittedById',
          'submitted_by_id',
          'createdBy',
          'created_by',
          'salesmanName',
          'salesman_name',
          'submittedByName',
          'createdByName',
        ]),
        fallback: '',
      ),
      'retailerId': _readText(
        _pick(order, <String>[
          'retailerId',
          'retailer_id',
          'retailerCode',
          'retailer_code',
          'storeId',
          'store_id',
        ]),
        fallback: _readText(
          _pick(order, <String>[
            'retailerName',
            'retailer_name',
            'storeName',
            'customerName',
          ]),
          fallback: 'unknown',
        ),
      ),
      'retailerName': _readText(
        _pick(order, <String>[
          'retailerName',
          'retailer_name',
          'martName',
          'customerName',
          'customer_name',
          'storeName',
          'store_name',
        ]),
        fallback: _readText(
          _pick(order, <String>['retailerId', 'retailer_id']),
          fallback: 'Retailer',
        ),
      ),
      'arrivalTime': arrival,
      'arrival_time': arrival,
      'departureTime': submitted,
      'departure_time': submitted,
      if (lat != null) 'gpsLatitude': lat,
      if (lat != null) 'gps_latitude': lat,
      if (lng != null) 'gpsLongitude': lng,
      if (lng != null) 'gps_longitude': lng,
      'status': _readText(order['status'], fallback: 'submitted'),
      'createdAt': _pick(order, <String>['createdAt', 'created']) ?? arrival,
      'updatedAt': _pick(order, <String>['updatedAt', 'modified']) ?? submitted,
    };
  }

  Map<String, dynamic> _trackingToVisitRow(
    Map<String, dynamic> tracking, {
    required String sourceCollection,
  }) {
    final Object? timestamp = _pick(tracking, <String>[
      'timestamp',
      'lastSeenAt',
      'lastUpdatedAt',
      'updatedAt',
      'createdAt',
      'created',
    ]);
    final double? lat = _readLatitude(tracking);
    final double? lng = _readLongitude(tracking);
    final String docId = _readText(tracking['docId'], fallback: _uuid.v4());
    return <String, dynamic>{
      ...tracking,
      'docId': '${sourceCollection}_$docId',
      'bridgeKey': '$sourceCollection:$docId',
      'sourceCollection': sourceCollection,
      'salesmanId': _readText(
        _pick(tracking, <String>[
          'salesmanUid',
          'salesman_uid',
          'submittedByUid',
          'submitted_by_uid',
          'salesmanId',
          'salesman_id',
          'salesmanCode',
          'salesman_code',
          'salesPersonId',
          'salespersonId',
          'userId',
          'user_id',
          'uid',
          'employeeCode',
          'employee_code',
          'staffId',
          'staff_id',
          'submittedBy',
          'submitted_by',
          'createdBy',
          'created_by',
          'salesmanName',
          'salesman_name',
        ]),
        fallback: '',
      ),
      'retailerId': _readText(
        _pick(tracking, <String>[
          'retailerId',
          'retailer_id',
          'retailerCode',
          'retailer_code',
          'storeId',
          'store_id',
        ]),
        fallback: _readText(
          _pick(tracking, <String>[
            'retailerName',
            'retailer_name',
            'currentRetailerName',
            'storeName',
          ]),
          fallback: 'live',
        ),
      ),
      'retailerName': _readText(
        _pick(tracking, <String>[
          'retailerName',
          'retailer_name',
          'currentRetailerName',
          'lastRetailerName',
          'storeName',
          'customerName',
        ]),
        fallback: 'Live location',
      ),
      'arrivalTime': timestamp,
      'arrival_time': timestamp,
      'departureTime': null,
      'departure_time': null,
      if (lat != null) 'gpsLatitude': lat,
      if (lat != null) 'gps_latitude': lat,
      if (lng != null) 'gpsLongitude': lng,
      if (lng != null) 'gps_longitude': lng,
      'status': _readText(tracking['status'], fallback: 'tracking'),
      'createdAt':
          _pick(tracking, <String>['createdAt', 'created']) ?? timestamp,
      'updatedAt':
          _pick(tracking, <String>['updatedAt', 'modified', 'lastSeenAt']) ??
          timestamp,
    };
  }

  Map<String, dynamic> _userToTrackingRow(Map<String, dynamic> user) {
    final Object? timestamp = _pick(user, <String>[
      'lastSeen',
      'lastSeenAt',
      'lastLocationAt',
      'last_location_at',
      'lastLoginAt',
      'updatedAt',
      'createdAt',
    ]);
    final double? lat = _readLatitude(user);
    final double? lng = _readLongitude(user);
    final String docId = _readText(
      user['docId'],
      fallback: _readText(user['uid'], fallback: _uuid.v4()),
    );
    return <String, dynamic>{
      ...user,
      'docId': 'user_location_$docId',
      'bridgeKey': 'users_location:$docId',
      'sourceCollection': 'users',
      'salesmanId': _readText(
        _pick(user, <String>[
          'employeeCode',
          'employee_code',
          'staffId',
          'staff_id',
          'salesmanId',
          'salesman_id',
          'salesmanCode',
          'salesman_code',
          'userId',
          'user_id',
          'uid',
          'email',
          'name',
        ]),
        fallback: '',
      ),
      'retailerId': _readText(
        _pick(user, <String>['currentRetailerId', 'lastRetailerId']),
        fallback: 'last-known',
      ),
      'retailerName': _readText(
        _pick(user, <String>['currentRetailerName', 'lastRetailerName']),
        fallback: 'Last known location',
      ),
      'arrivalTime': timestamp,
      'arrival_time': timestamp,
      'departureTime': null,
      'departure_time': null,
      if (lat != null) 'gpsLatitude': lat,
      if (lat != null) 'gps_latitude': lat,
      if (lng != null) 'gpsLongitude': lng,
      if (lng != null) 'gps_longitude': lng,
      'status': _readText(
        user['trackingStatus'] ?? user['status'],
        fallback: 'last known',
      ),
      'createdAt': _pick(user, <String>['createdAt', 'created']) ?? timestamp,
      'updatedAt': _pick(user, <String>['updatedAt', 'modified']) ?? timestamp,
    };
  }

  String _readNotificationType(
    Map<String, dynamic> row, {
    required String fallback,
  }) {
    final List<String> candidates =
        <Object?>[
              row['notification_type'],
              row['notificationType'],
              row['eventType'],
              row['type'],
            ]
            .map(_normaliseNotificationTypeToken)
            .where((String value) => value.isNotEmpty)
            .toList(growable: false);

    final String specificOrderType = candidates.firstWhere(
      (String type) =>
          _isOrderNotificationType(type) &&
          !_isGenericOrderNotificationType(type),
      orElse: () => '',
    );
    if (specificOrderType.isNotEmpty) {
      return _canonicalNotificationTypeAlias(specificOrderType);
    }

    if (candidates.isEmpty) return fallback;
    return _canonicalNotificationTypeAlias(candidates.first);
  }

  String _normaliseNotificationTypeToken(Object? value) {
    String text = _readText(value, fallback: '').trim();
    if (text.isEmpty) return '';
    text = text.replaceAllMapped(
      RegExp(r'([a-z0-9])([A-Z])'),
      (Match match) => '${match.group(1)}_${match.group(2)}',
    );
    return text
        .toLowerCase()
        .replaceAll(RegExp(r'[^a-z0-9]+'), '_')
        .replaceAll(RegExp(r'^_+|_+$'), '');
  }

  String _canonicalNotificationTypeAlias(String type) {
    switch (type) {
      case 'order':
      case 'orders':
      case 'order_notification':
      case 'order_notifications':
      case 'order_submit':
      case 'order_submission':
      case 'submitted_order':
      case 'new_order':
        return 'order_submitted';
      default:
        return type;
    }
  }

  bool _isOrderNotificationType(String type) {
    return type == 'order' ||
        type.startsWith('order_') ||
        type.endsWith('_order') ||
        type.contains('_order_');
  }

  bool _isGenericOrderNotificationType(String type) {
    return type == 'order' ||
        type == 'orders' ||
        type == 'order_notification' ||
        type == 'order_notifications';
  }

  Map<String, dynamic> _normaliseNotificationRow(
    Map<String, dynamic> source, {
    required String sourceCollection,
  }) {
    final Map<String, dynamic> row = Map<String, dynamic>.from(source);
    final String docId = _readText(row['docId'], fallback: _uuid.v4());
    final String type = _readNotificationType(row, fallback: 'system_update');
    final String originalMessage = _readText(row['message'], fallback: '');
    final String parsedSalesman = _salesmanNameFromNotificationMessage(
      originalMessage,
    );
    final String parsedRetailer = _retailerNameFromNotificationMessage(
      originalMessage,
    );
    final String existingSalesmanName = _firstUsefulText(<Object?>[
      row['salesmanName'],
      row['salesman_name'],
      row['submittedByName'],
      row['submitted_by_name'],
      row['createdByName'],
      row['created_by_name'],
    ]);
    final String existingRetailerName = _firstUsefulText(<Object?>[
      row['retailerName'],
      row['retailer_name'],
      row['martName'],
      row['customerName'],
      row['storeName'],
    ]);
    final String usableSalesmanName =
        existingSalesmanName.isNotEmpty &&
            !_isGenericSalesmanLabel(existingSalesmanName)
        ? existingSalesmanName
        : parsedSalesman;
    final String usableRetailerName = existingRetailerName.isNotEmpty
        ? existingRetailerName
        : parsedRetailer;

    return <String, dynamic>{
      ...row,
      'docId': '${sourceCollection}_$docId',
      'bridgeKey': '$sourceCollection:$docId',
      'sourceCollection': sourceCollection,
      'notification_type': type,
      'type': type,
      'message': originalMessage.isEmpty
          ? _fallbackNotificationMessage(type, row)
          : originalMessage,
      'salesmanId': _firstUsefulText(<Object?>[
        row['salesmanUid'],
        row['salesman_uid'],
        row['submittedByUid'],
        row['submitted_by_uid'],
        row['salesmanId'],
        row['salesman_id'],
        row['salesmanCode'],
        row['salesman_code'],
        row['salesPersonId'],
        row['salespersonId'],
        row['userId'],
        row['user_id'],
        row['uid'],
        row['employeeCode'],
        row['staffId'],
        row['submittedBy'],
        row['submitted_by'],
        row['submittedById'],
        row['createdBy'],
        row['created_by'],
      ]),
      if (usableSalesmanName.isNotEmpty) 'salesmanName': usableSalesmanName,
      if (usableSalesmanName.isNotEmpty) 'salesman_name': usableSalesmanName,
      if (usableRetailerName.isNotEmpty) 'retailerName': usableRetailerName,
      if (usableRetailerName.isNotEmpty) 'retailer_name': usableRetailerName,
      'recipient_user_id':
          _pick(row, <String>[
            'recipient_user_id',
            'recipientUserId',
            'recipientId',
          ]) ??
          'admin',
      'reference_id': _pick(row, <String>[
        'reference_id',
        'referenceId',
        'orderId',
        'docId',
      ]),
      'is_read': _pick(row, <String>['is_read', 'isRead']) ?? false,
      'createdAt':
          _pick(row, <String>['createdAt', 'created', 'timestamp']) ??
          Timestamp.now(),
    };
  }

  Map<String, dynamic> _orderToNotificationRow(
    Map<String, dynamic> order, {
    required Map<String, Map<String, dynamic>> userIndex,
    required Map<String, Map<String, dynamic>> retailerIndex,
  }) {
    final Map<String, dynamic> enriched = _enrichOrderRow(
      order,
      userIndex: userIndex,
      retailerIndex: retailerIndex,
    );
    final String orderDocId = _readText(
      _stripBridgePrefix(_firestoreOrderDocId(order)),
      fallback: '',
    );
    final String bridgeId = orderDocId.isNotEmpty
        ? orderDocId
        : _readText(order['docId'], fallback: _uuid.v4());
    final String retailerName = _readText(
      enriched['retailerName'] ?? enriched['retailer_name'],
      fallback: 'retailer',
    );
    final String salesmanId = _readText(
      enriched['salesmanId'] ?? enriched['salesman_id'],
      fallback: '',
    );
    String salesmanName = _firstUsefulText(<Object?>[
      enriched['salesmanName'],
      enriched['salesman_name'],
      enriched['submittedByName'],
      enriched['createdByName'],
    ]);
    if (salesmanName.isEmpty || _isGenericSalesmanLabel(salesmanName)) {
      salesmanName = 'Unknown Salesman';
    }
    final Object createdAt =
        _pick(enriched, <String>[
          'submittedAt',
          'submitted_at',
          'createdAt',
          'created',
          'timestamp',
        ]) ??
        Timestamp.now();
    final String productSummary = _summariseOrderItems(
      authoritativeOrderItems(enriched),
    );
    final String baseMessage =
        'New order submitted by $salesmanName for $retailerName';
    final String message = productSummary.isEmpty
        ? '$baseMessage.'
        : '$baseMessage — $productSummary.';
    return <String, dynamic>{
      ...enriched,
      'docId': 'order_notification_$bridgeId',
      if (orderDocId.isNotEmpty) 'orderDocId': orderDocId,
      if (orderDocId.isNotEmpty) 'orderDocumentId': orderDocId,
      'bridgeKey': 'order_notification:$bridgeId',
      'sourceCollection': 'orders',
      'notification_type': 'order_submitted',
      'type': 'order_submitted',
      'message': message,
      if (productSummary.isNotEmpty) 'productSummary': productSummary,
      'salesmanId': salesmanId,
      'salesman_id': salesmanId,
      'salesmanName': salesmanName,
      'salesman_name': salesmanName,
      'retailerName': retailerName,
      'recipient_user_id': 'admin',
      'reference_id': orderDocId.isNotEmpty ? orderDocId : bridgeId,
      'is_read': false,
      'createdAt': createdAt,
      'created_at': createdAt,
    };
  }

  String _summariseOrderItems(Object? items) {
    if (items is! List || items.isEmpty) return '';
    final List<String> parts = <String>[];
    for (final entry in items.take(3)) {
      if (entry is! Map) continue;
      final String name = _readText(
        entry['productName'] ?? entry['name'],
        fallback: '',
      );
      if (name.isEmpty) continue;
      final Object? qtyRaw = entry['qty'] ?? entry['quantity'];
      final int qty = qtyRaw is int
          ? qtyRaw
          : (qtyRaw is num
                ? qtyRaw.toInt()
                : int.tryParse(qtyRaw?.toString() ?? '') ?? 0);
      parts.add(qty > 0 ? '$qty× $name' : name);
    }
    if (parts.isEmpty) return '';
    final int remaining = items.length - parts.length;
    return remaining > 0
        ? '${parts.join(', ')}, +$remaining more'
        : parts.join(', ');
  }

  String _salesmanNameFromNotificationMessage(Object? value) {
    final String message = _readText(value, fallback: '');
    if (message.isEmpty) return '';
    final RegExp byForPattern = RegExp(
      r'\bby\s+(.+?)\s+for\s+(.+?)(?:\.|$)',
      caseSensitive: false,
    );
    final RegExpMatch? match = byForPattern.firstMatch(message);
    if (match == null) return '';
    final String name = _cleanMessageEntity(match.group(1));
    if (name.isEmpty || _isGenericSalesmanLabel(name)) return '';
    return name;
  }

  String _retailerNameFromNotificationMessage(Object? value) {
    final String message = _readText(value, fallback: '');
    if (message.isEmpty) return '';
    final RegExp byForPattern = RegExp(
      r'\bby\s+(.+?)\s+for\s+(.+?)(?:\.|$)',
      caseSensitive: false,
    );
    final RegExpMatch? match = byForPattern.firstMatch(message);
    if (match == null) return '';
    return _cleanMessageEntity(match.group(2));
  }

  String _cleanMessageEntity(String? value) {
    if (value == null) return '';
    String text = value.trim();
    text = text.replaceAll(RegExp(r'\s+'), ' ');
    text = text.replaceAll(RegExp(r'^[\-:•]+|[\-:•]+$'), '').trim();
    return text;
  }

  String _fallbackNotificationMessage(String type, Map<String, dynamic> row) {
    final String retailer = _firstUsefulText(<Object?>[
      row['retailerName'],
      row['retailer_name'],
      row['retailerId'],
      row['retailer_id'],
      row['storeName'],
      row['customerName'],
    ]);
    String salesman = _firstUsefulText(<Object?>[
      row['salesmanName'],
      row['salesman_name'],
      row['submittedByName'],
      row['createdByName'],
      row['salesmanId'],
      row['salesman_id'],
      row['userId'],
      row['user_id'],
    ]);
    if (_isGenericSalesmanLabel(salesman)) salesman = '';
    final String retailerLabel = retailer.isEmpty ? 'retailer' : retailer;
    final String salesmanLabel = salesman.isEmpty
        ? 'Unknown Salesman'
        : salesman;
    final String productSummary =
        _readText(row['productSummary'], fallback: '').isNotEmpty
        ? _readText(row['productSummary'], fallback: '')
        : _summariseOrderItems(authoritativeOrderItems(row));
    if (type.contains('order')) {
      final String base =
          'New order submitted by $salesmanLabel for $retailerLabel';
      return productSummary.isEmpty ? '$base.' : '$base — $productSummary.';
    }
    if (type.contains('arrival') || type.contains('visit')) {
      return '$salesmanLabel updated visit activity for $retailerLabel.';
    }
    if (type.contains('user')) return 'User account activity was updated.';
    return 'New system notification.';
  }

  static const bool _notifyOnDashboardEdits = false;

  void _queueAdminNotification({
    required String collectionName,
    required String action,
    required Map<String, dynamic> data,
    required String docId,
  }) {
    if (!_notifyOnDashboardEdits) return;
    if (!AppRuntime.firebaseReady) return;
    if (collectionName == 'notification_logs' ||
        collectionName == 'notifications') {
      return;
    }
    if (collectionName == 'visit_logs' ||
        collectionName == 'live_tracking' ||
        collectionName == 'gps_tracking') {
      return;
    }

    final String type = _notificationTypeForCollection(collectionName, action);
    final String label = _labelForRecord(collectionName, data, docId);
    final String message =
        '${_titleForCollection(collectionName)} $action: $label';

    unawaited(
      _writeAdminNotification(<String, dynamic>{
        'notification_type': type,
        'type': type,
        'message': message,
        'reference_collection': collectionName,
        'reference_id': docId,
        'recipient_user_id': 'admin',
        'is_read': false,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      }),
    );
  }

  Future<void> _writeAdminNotification(Map<String, dynamic> data) async {
    try {
      await _firestore.collection('notification_logs').add(data);
    } catch (_) {}
  }

  String _notificationTypeForCollection(String collectionName, String action) {
    if (collectionName == 'orders') return 'order_$action';
    if (collectionName == 'users') return 'user_$action';
    if (collectionName == 'retailers') return 'retailer_$action';
    if (collectionName.contains('product') ||
        collectionName.contains('score_sheet')) {
      return 'product_$action';
    }
    return 'admin_$action';
  }

  String _titleForCollection(String collectionName) {
    switch (collectionName) {
      case 'orders':
        return 'Order';
      case 'users':
        return 'User profile';
      case 'retailers':
        return 'Retailer';
      case 'retailer_score_sheet_items':
        return 'Score sheet item';
      case 'departments':
        return 'Department';
      case 'categories':
        return 'Category';
      case 'subcategories':
        return 'Subcategory';
      default:
        return 'Record';
    }
  }

  String _labelForRecord(
    String collectionName,
    Map<String, dynamic> data,
    String docId,
  ) {
    return _readText(
      _pick(data, <String>[
        'name',
        'displayName',
        'email',
        'retailerName',
        'retailer_name',
        'productName',
        'product_name',
        'departmentName',
        'categoryName',
        'subCategoryName',
        'orderNo',
        'orderId',
      ]),
      fallback: docId,
    );
  }

  Stream<List<Map<String, dynamic>>> _buildCollectionStream(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
  }) {
    if (collectionName == 'products') {
      return watchPagedProducts(_firestore).map((rows) {
        final List<Map<String, dynamic>> sorted = List<Map<String, dynamic>>.of(
          rows,
        );
        if (orderBy != null && orderBy.trim().isNotEmpty) {
          _sortRowsInMemory(sorted, field: orderBy, descending: descending);
        }
        return CollectionRows(sorted, isComplete: true);
      });
    }
    if (_isPreciseLocationCollection(collectionName)) {
      return _buildPreciseLocationStream(
        collectionName,
        orderBy: orderBy,
        descending: descending,
        limit: limit,
      );
    }
    final bool sortInMemory = _shouldSortInMemory(collectionName, orderBy);
    final bool capped = limit != null && limit > 0;

    Query<Map<String, dynamic>> query = _firestore.collection(collectionName);

    final bool pushOrderToServer = capped || !sortInMemory;
    if (pushOrderToServer && orderBy != null && orderBy.trim().isNotEmpty) {
      query = query.orderBy(orderBy, descending: descending);
    }
    if (capped) {
      query = query.limit(limit);
    }

    return watchCoveredQuery(
      query,
      probe: coverageProbe && capped && pushOrderToServer && orderBy != null
          ? _firestore
                .collection(collectionName)
                .orderBy(FieldPath.documentId)
                .limit(limit + 1)
          : null,
      limit: limit,
      newestFirstField: pushOrderToServer && descending ? orderBy : null,
    );
  }

  static bool _isPreciseLocationCollection(String collectionName) {
    return collectionName == 'gps_tracking' ||
        collectionName == 'live_tracking' ||
        collectionName == 'users' ||
        collectionName == 'retailers' ||
        collectionName == 'orders' ||
        collectionName == 'route_plans' ||
        collectionName == 'route_stop_progress' ||
        collectionName == 'visits' ||
        collectionName == 'visit_logs';
  }

  Future<_PreciseLocationScope> _resolvePreciseLocationScope() async {
    final User? authUser = FirebaseAuth.instance.currentUser;
    if (authUser == null || authUser.uid.trim().isEmpty) {
      return const _PreciseLocationScope.none();
    }

    try {
      final UserProfile? profile = await AuthService.instance
          .resolveUserProfile(authUser);
      if (profile == null || !profile.isActive) {
        return const _PreciseLocationScope.none();
      }

      final String role = profile.role;
      if (role == UserProfile.roleAdmin || role == UserProfile.roleDeveloper) {
        return const _PreciseLocationScope.admin();
      }
      if (role == UserProfile.roleSupervisor &&
          profile.assignedSalesmanCodes.isNotEmpty) {
        final List<String> assignedCodes = profile.assignedSalesmanCodes
            .map((String code) => code.trim())
            .where((String code) => code.isNotEmpty)
            .toSet()
            .toList(growable: false);
        if (assignedCodes.isEmpty) {
          return const _PreciseLocationScope.none();
        }
        return _PreciseLocationScope.supervisor(
          assignedCodes,
          retailerBranchId: profile.branchId.trim(),
        );
      }
      if (role == UserProfile.roleBranchManager &&
          profile.branchId.isNotEmpty) {
        return _PreciseLocationScope.branchManager(profile.branchId);
      }
      if (role == UserProfile.roleSalesman) {
        return _PreciseLocationScope.salesman(
          authUser.uid,
          retailerBranchId: profile.branchId.trim(),
        );
      }
      return const _PreciseLocationScope.none();
    } catch (_) {
      return const _PreciseLocationScope.failed();
    }
  }

  List<Query<Map<String, dynamic>>> _preciseLocationQueries(
    Query<Map<String, dynamic>> query,
    _PreciseLocationScope scope, {
    String collectionName = 'gps_tracking',
    int whereInChunkSize = firestore_query_utils.kFirestoreWhereInMaxValues,
  }) {
    final bool userProfiles = collectionName == 'users';
    if (collectionName == 'retailers' &&
        scope.kind != _PreciseLocationScopeKind.admin) {
      final String branchId =
          scope.kind == _PreciseLocationScopeKind.branchManager
          ? scope.branchId
          : scope.retailerBranchId;
      if (!scope.canRead) return <Query<Map<String, dynamic>>>[];
      if (branchId.isEmpty) {
        throw StateError(
          'Your account has no branch, so retailers cannot be shown. Ask an admin to set your branch.',
        );
      }
      return <Query<Map<String, dynamic>>>[
        query.where('branchId', isEqualTo: branchId),
      ];
    }
    switch (scope.kind) {
      case _PreciseLocationScopeKind.admin:
        return <Query<Map<String, dynamic>>>[query];
      case _PreciseLocationScopeKind.supervisor:
        final String field = userProfiles ? 'employeeCode' : 'salesmanCode';
        return firestore_query_utils
            .chunkFirestoreWhereIn(
              scope.salesmanCodes,
              chunkSize: whereInChunkSize,
            )
            .map((List<String> chunk) => query.where(field, whereIn: chunk))
            .toList(growable: false);
      case _PreciseLocationScopeKind.branchManager:
        final Query<Map<String, dynamic>> branch = query.where(
          'branchId',
          isEqualTo: scope.branchId,
        );
        if (!userProfiles) return <Query<Map<String, dynamic>>>[branch];
        return <Query<Map<String, dynamic>>>[
          branch.where('role', whereIn: _branchStaffRoleSpellings),
        ];
      case _PreciseLocationScopeKind.salesman:
        return <Query<Map<String, dynamic>>>[
          query.where(
            userProfiles ? 'uid' : 'salesmanUid',
            isEqualTo: scope.uid,
          ),
        ];
      case _PreciseLocationScopeKind.none:
        return <Query<Map<String, dynamic>>>[];
      case _PreciseLocationScopeKind.failed:
        return <Query<Map<String, dynamic>>>[];
    }
  }

  Stream<List<Map<String, dynamic>>> _combineCoveredStreams(
    List<Stream<List<Map<String, dynamic>>>> queries, {
    String? orderBy,
    required bool descending,
    int? limit,
  }) {
    late final StreamController<List<Map<String, dynamic>>> controller;
    final Map<int, List<Map<String, dynamic>>> rowsByQuery =
        <int, List<Map<String, dynamic>>>{};
    final subscriptions = <StreamSubscription<List<Map<String, dynamic>>>>[];

    void emit() {
      final Map<String, Map<String, dynamic>> rowsById =
          <String, Map<String, dynamic>>{};
      for (final List<Map<String, dynamic>> rows in rowsByQuery.values) {
        for (final Map<String, dynamic> row in rows) {
          final String docId = _readText(row['docId'], fallback: '');
          if (docId.isNotEmpty) rowsById[docId] = row;
        }
      }
      final List<Map<String, dynamic>> rows = rowsById.values.toList();
      if (orderBy != null && orderBy.trim().isNotEmpty) {
        _sortRowsInMemory(rows, field: orderBy, descending: descending);
      }
      final bool truncated = limit != null && limit > 0 && rows.length > limit;
      final List<Map<String, dynamic>> visible = truncated
          ? rows.take(limit).toList(growable: false)
          : rows;
      if (!controller.isClosed && rowsByQuery.length == queries.length) {
        final DateTime? truncatedSince = !truncated
            ? coversAllRows
            : descending && orderBy != null
            ? parseFlexibleDate(visible.last[orderBy])
            : null;
        controller.add(
          CollectionRows(
            visible,
            isComplete:
                rowsByQuery.values.every(collectionRowsComplete) &&
                (limit == null || limit <= 0 || rows.length < limit),
            coveredSince: laterCoverage(
              combinedCoverage(rowsByQuery.values),
              truncatedSince,
            ),
          ),
        );
      }
    }

    Future<void> cancelSubscriptions() async {
      for (final subscription in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
    }

    controller = StreamController<List<Map<String, dynamic>>>.broadcast(
      onListen: () {
        if (subscriptions.isNotEmpty) return;
        for (int index = 0; index < queries.length; index++) {
          final int queryIndex = index;
          subscriptions.add(
            queries[index].listen(
              (List<Map<String, dynamic>> rows) {
                rowsByQuery[queryIndex] = rows;
                emit();
              },
              onError: (Object error, StackTrace stackTrace) {
                if (!controller.isClosed) {
                  controller.addError(error, stackTrace);
                }
              },
            ),
          );
        }
      },
      onCancel: cancelSubscriptions,
    );
    return controller.stream;
  }

  Stream<List<Map<String, dynamic>>> _buildPreciseLocationStream(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    DateTime? since,
  }) {
    return Stream.fromFuture(_resolvePreciseLocationScope()).asyncExpand((
      _PreciseLocationScope scope,
    ) {
      if (scope.resolutionFailed) {
        return Stream<List<Map<String, dynamic>>>.error(
          StateError(
            'Your access scope could not be resolved. Check your connection and try again.',
          ),
        );
      }
      if (!scope.canRead) {
        return Stream<List<Map<String, dynamic>>>.value(
          <Map<String, dynamic>>[],
        );
      }
      final List<Query<Map<String, dynamic>>> scopedQueries =
          _preciseLocationQueries(
            _firestore.collection(collectionName),
            scope,
            collectionName: collectionName,
          );
      final List<Query<Map<String, dynamic>>> rangedQueries = scopedQueries
          .map(
            (Query<Map<String, dynamic>> query) =>
                since == null || orderBy == null
                ? query
                : query.where(
                    orderBy,
                    isGreaterThanOrEqualTo: Timestamp.fromDate(since),
                  ),
          )
          .toList(growable: false);
      if (scopedQueries.isEmpty) {
        return Stream<List<Map<String, dynamic>>>.value(
          <Map<String, dynamic>>[],
        );
      }
      final List<Query<Map<String, dynamic>>> queries = rangedQueries
          .map((Query<Map<String, dynamic>> baseQuery) {
            Query<Map<String, dynamic>> query = baseQuery;
            if (limit != null && limit > 0) {
              if (orderBy != null &&
                  orderBy.trim().isNotEmpty &&
                  collectionName != 'retailers') {
                query = query.orderBy(orderBy, descending: descending);
              }
              query = query.limit(limit);
            }
            return query;
          })
          .toList(growable: false);
      final streams = <Stream<List<Map<String, dynamic>>>>[
        for (int i = 0; i < queries.length; i++)
          watchCoveredQuery(
            queries[i],
            limit: limit,
            probe:
                since == null && limit != null && limit > 0 && orderBy != null
                ? scopedQueries[i]
                      .orderBy(FieldPath.documentId)
                      .limit(limit + 1)
                : null,
            newestFirstField: descending ? orderBy : null,
          ),
      ];
      return _combineCoveredStreams(
        streams,
        orderBy: orderBy,
        descending: descending,
        limit: limit,
      );
    });
  }

  static CollectionRows _sortAndLimitRows(
    List<Map<String, dynamic>> rows, {
    String? orderBy,
    required bool descending,
    int? limit,
    required bool defaultDescending,
  }) {
    final List<Map<String, dynamic>> sorted = rows.map((
      Map<String, dynamic> row,
    ) {
      return Map<String, dynamic>.from(row);
    }).toList();

    final String? field = orderBy != null && orderBy.trim().isNotEmpty
        ? orderBy
        : null;
    sorted.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final String left = field == null
          ? _defaultSortValue(a)
          : _sortValue(a, field);
      final String right = field == null
          ? _defaultSortValue(b)
          : _sortValue(b, field);
      final int comparison = left.compareTo(right);
      return (field == null ? defaultDescending : descending)
          ? -comparison
          : comparison;
    });

    if (limit != null && limit > 0 && sorted.length > limit) {
      final List<Map<String, dynamic>> kept = sorted
          .take(limit)
          .toList(growable: false);
      final bool newestFirst = field == null ? defaultDescending : descending;
      final DateTime? keptSince = newestFirst
          ? DateTime.tryParse(
              field == null
                  ? _defaultSortValue(kept.last)
                  : _sortValue(kept.last, field),
            )
          : null;
      return CollectionRows(
        kept,
        isComplete: false,
        coveredSince: laterCoverage(
          combinedCoverage(<List<Map<String, dynamic>>?>[
            if (rows is CollectionRows) rows,
          ]),
          keptSince,
        ),
      );
    }
    return CollectionRows(
      sorted,
      isComplete: rows is! CollectionRows || rows.isComplete,
    );
  }

  static bool _shouldSortInMemory(String collectionName, String? orderBy) {
    if (orderBy == null || orderBy.trim().isEmpty) return false;
    return collectionName == 'users' ||
        collectionName == 'retailers' ||
        collectionName == 'retailer_score_sheet_items' ||
        collectionName == 'orders' ||
        collectionName == 'visit_logs';
  }

  static int _defaultWatchLimit(String collectionName) {
    switch (collectionName) {
      case 'retailers':
      case 'products':
        return 2000;
      case 'users':
        return 1000;
      case 'orders':
      case 'visit_logs':
      case 'gps_tracking':
      case 'notification_logs':
      case 'notifications':
        return 500;
      default:
        return 500;
    }
  }

  static String _cacheKey(
    String collectionName, {
    String? orderBy,
    required bool descending,
    int? limit,
    bool coverageProbe = true,
  }) {
    String uid = 'signed_out';
    try {
      uid = FirebaseAuth.instance.currentUser?.uid ?? 'signed_out';
    } catch (_) {}
    return <String>[
      if (!coverageProbe) 'unprobed',
      uid,
      collectionName,
      orderBy ?? '',
      descending.toString(),
      (limit ?? 0).toString(),
    ].join('|');
  }

  static void _sortRowsInMemory(
    List<Map<String, dynamic>> rows, {
    required String field,
    required bool descending,
  }) {
    rows.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final String left = _sortValue(a, field);
      final String right = _sortValue(b, field);
      final int comparison = left.compareTo(right);
      return descending ? -comparison : comparison;
    });
  }

  static String _defaultSortValue(Map<String, dynamic> row) {
    for (final Object? value in <Object?>[
      row['updatedAt'],
      row['updated_at'],
      row['submittedAt'],
      row['submitted_at'],
      row['arrivalTime'],
      row['arrival_time'],
      row['createdAt'],
      row['created_at'],
      row['timestamp'],
    ]) {
      final String text = _dateSortText(value);
      if (text.isNotEmpty) return text;
    }
    return _sortValue(row, 'docId');
  }

  static String _sortValue(Map<String, dynamic> row, String field) {
    final Object? primary = row[field];
    final String dateText = _dateSortText(primary);
    if (dateText.isNotEmpty) return dateText;
    if (primary != null &&
        '$primary'.trim().isNotEmpty &&
        '$primary'.trim().toLowerCase() != 'null') {
      return '$primary'.trim().toLowerCase();
    }

    for (final Object? fallback in <Object?>[
      row['name'],
      row['email'],
      row['employeeCode'],
      row['userId'],
      row['docId'],
    ]) {
      final String text = '$fallback'.trim();
      if (text.isNotEmpty && text.toLowerCase() != 'null') {
        return text.toLowerCase();
      }
    }
    return '';
  }

  static String _dateSortText(Object? value) {
    if (value == null) return '';
    if (value is Timestamp) return value.toDate().toIso8601String();
    if (value is DateTime) return value.toIso8601String();
    final String text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return '';
    return text;
  }

  static Object? _pick(Map<String, dynamic> row, List<String> keys) {
    for (final String key in keys) {
      if (row.containsKey(key)) {
        final Object? value = row[key];
        if (_readText(value, fallback: '').isNotEmpty) return value;
      }
    }
    return null;
  }

  static String _readText(Object? value, {required String fallback}) {
    if (value == null) return fallback;
    final String text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
    return text;
  }

  static String _auditLabel(
    String collectionName,
    Map<String, dynamic> data,
    String docId,
  ) {
    final String label = _readText(
      _pick(data, <String>[
        'name',
        'retailerName',
        'productName',
        'email',
        'title',
        'branchName',
      ]),
      fallback: docId,
    );
    return '$collectionName: $label';
  }

  Future<String> exportCollectionCsv(String collectionName) async {
    if (!AppRuntime.firebaseReady) return '';
    return _rowsToCsv(
      collectionName,
      await _getCollectionAllForMaintenance(collectionName),
    );
  }

  static String _rowsToCsv(
    String collectionName,
    List<Map<String, dynamic>> rows,
  ) {
    if (rows.isEmpty) return 'collection,empty\n$collectionName,true\n';
    final List<String> headers = <String>{
      for (final Map<String, dynamic> row in rows) ...row.keys,
    }.toList()..sort();
    final StringBuffer buffer = StringBuffer();
    buffer.writeln(headers.map(csvCell).join(','));
    for (final Map<String, dynamic> row in rows) {
      buffer.writeln(
        headers.map((String key) => csvCell(_exportText(row[key]))).join(','),
      );
    }
    return buffer.toString();
  }

  Future<String> purgeCollectionWithCsvExport({
    required String collectionName,
    required String actor,
  }) async {
    if (collectionName.trim().split('/').contains('orders')) {
      throw StateError(
        'Use the order purge schedule to export and purge orders.',
      );
    }
    if (!AppRuntime.firebaseReady) return '';
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> exported =
        await _getRawDocumentsAll(collectionName);
    final String csv = _rowsToCsv(collectionName, <Map<String, dynamic>>[
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in exported)
        <String, dynamic>{...doc.data(), 'docId': doc.id},
    ]);
    final DocumentReference<Map<String, dynamic>> exportRef = await _firestore
        .collection('purge_exports')
        .add(<String, dynamic>{
          'collectionName': collectionName,
          'csv': csv,
          'actor': actor,
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'exported_before_purge',
        });
    final int keptChanged = await _deleteExportedDocuments(exported);
    await exportRef.set(<String, dynamic>{
      'status': 'exported_and_purged',
      'purgedAt': FieldValue.serverTimestamp(),
      'keptChangedCount': keptChanged,
    }, SetOptions(merge: true));
    return csv;
  }

  Future<Map<String, dynamic>> getOrderPurgeSettings() async {
    if (!AppRuntime.firebaseReady) {
      throw StateError(
        'Order purge settings are not ready. Try again shortly.',
      );
    }
    final DocumentSnapshot<Map<String, dynamic>> snapshot =
        await _orderPurgeSettingsReference.get(
          const GetOptions(source: Source.server),
        );
    return snapshot.data() ?? <String, dynamic>{};
  }

  static int orderPurgeRetentionMonths(Map<String, dynamic> settings) {
    final Object? months = settings['retentionMonths'];
    return months is int && orderPurgeRetentionChoices.contains(months)
        ? months
        : orderPurgeDefaultRetentionMonths;
  }

  static const int orderPurgeDefaultRetentionMonths = 84;
  static const List<int> orderPurgeRetentionChoices = <int>[3, 6, 12, 84];

  static DateTime orderPurgeCutoff(DateTime now, int retentionMonths) {
    final DateTime myt = now.toUtc().add(const Duration(hours: 8));
    final DateTime month = DateTime.utc(myt.year, myt.month - retentionMonths);
    final int lastDay = DateTime.utc(month.year, month.month + 1, 0).day;
    return DateTime.utc(
      month.year,
      month.month,
      myt.day.clamp(1, lastDay),
      myt.hour,
      myt.minute,
      myt.second,
      myt.millisecond,
      myt.microsecond,
    ).subtract(const Duration(hours: 8));
  }

  Future<void> saveOrderPurgeSettings({
    required int retentionMonths,
    required bool enabled,
    required UserProfile currentUser,
  }) async {
    OrderAuthorization.ensureCanDeleteOrder(currentUser);
    if (!orderPurgeRetentionChoices.contains(retentionMonths)) {
      throw ArgumentError('Retention must be 3, 6 or 12 months, or 7 years.');
    }
    if (!AppRuntime.firebaseReady) {
      throw StateError('Order purge is not ready.');
    }
    await _firestore.runTransaction((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(_orderPurgeSettingsReference);
      if (_orderPurgeIsRunning(snapshot.data() ?? <String, dynamic>{})) {
        throw StateError(
          'A purge is running. Save the schedule after it finishes.',
        );
      }
      transaction.set(_orderPurgeSettingsReference, <String, dynamic>{
        'retentionMonths': retentionMonths,
        'enabled': enabled,
        'updatedBy': currentUser.uid,
        'updatedAt': FieldValue.serverTimestamp(),
      }, SetOptions(merge: true));
    });
  }

  Future<OrderPurgeSelection> prepareOrderPurge({
    required UserProfile currentUser,
  }) async {
    OrderAuthorization.ensureCanDeleteOrder(currentUser);
    final Map<String, dynamic> policy = await getOrderPurgeSettings();
    final DateTime cutoff = orderPurgeCutoff(
      DateTime.now(),
      orderPurgeRetentionMonths(policy),
    );
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> selected =
        <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    String? cursor;
    while (true) {
      Query<Map<String, dynamic>> query = _firestore
          .collection('orders')
          .orderBy(FieldPath.documentId)
          .limit(_maintenancePageSize);
      if (cursor != null) query = query.startAfter(<Object?>[cursor]);
      final QuerySnapshot<Map<String, dynamic>> page = await query.get(
        const GetOptions(source: Source.server),
      );
      selected.addAll(
        page.docs.where((doc) => _isOldFinalOrder(doc.data(), cutoff)),
      );
      if (page.docs.length < _maintenancePageSize) break;
      cursor = page.docs.last.id;
    }
    return OrderPurgeSelection._(policy, cutoff, selected);
  }

  static bool _isOldFinalOrder(Map<String, dynamic> order, DateTime cutoff) {
    final String status = dataText(order['status']).toLowerCase();
    if (!const <String>{
      'rejected',
      'reject',
      'completed',
      'cancelled',
      'canceled',
      'void',
    }.contains(status)) {
      return false;
    }
    final DateTime? date =
        parseFlexibleDate(order['submittedAt']) ??
        parseFlexibleDate(order['createdAt']) ??
        parseFlexibleDate(order['created_at']);
    return date != null && date.isBefore(cutoff);
  }

  static bool _orderPurgeIsRunning(Map<String, dynamic> settings) {
    final DateTime? lease = parseFlexibleDate(settings['runLeaseUntil']);
    return settings['runId'] != null &&
        lease != null &&
        lease.isAfter(DateTime.now());
  }

  static bool _orderPurgeIsDue(Map<String, dynamic> settings) {
    if (settings['enabled'] != true) return false;
    final DateTime? last = parseFlexibleDate(settings['lastRunAt']);
    if (last == null) return true;
    final DateTime today = DateTime.now().toUtc().add(const Duration(hours: 8));
    final DateTime lastMyt = last.toUtc().add(const Duration(hours: 8));
    return DateTime.utc(
      lastMyt.year,
      lastMyt.month,
      lastMyt.day,
    ).isBefore(DateTime.utc(today.year, today.month, today.day));
  }

  static void _ensureOrderPurgeLock(
    Map<String, dynamic> settings,
    String runId,
  ) {
    if (settings['runId'] != runId ||
        !_orderPurgeIsRunning(settings) ||
        orderPurgeRetentionMonths(settings) != settings['runRetentionMonths'] ||
        (settings['enabled'] == true) != settings['runEnabled'] ||
        !sameFirestoreValue(
          settings['updatedAt'],
          settings['runPolicyUpdatedAt'],
        )) {
      throw StateError(
        'The purge lock or schedule changed. Refresh and try again.',
      );
    }
  }

  Future<OrderPurgeResult?> runDueOrderPurge({
    required UserProfile currentUser,
  }) async {
    OrderAuthorization.ensureCanDeleteOrder(currentUser);
    final Map<String, dynamic> settings = await getOrderPurgeSettings();
    if (!_orderPurgeIsDue(settings) || _orderPurgeIsRunning(settings)) {
      return null;
    }
    return runOrderPurge(
      currentUser: currentUser,
      selection: await prepareOrderPurge(currentUser: currentUser),
      onlyIfDue: true,
    );
  }

  Future<OrderPurgeResult?> runOrderPurge({
    required UserProfile currentUser,
    required OrderPurgeSelection selection,
    bool onlyIfDue = false,
  }) async {
    OrderAuthorization.ensureCanDeleteOrder(currentUser);
    final String runId = _uuid.v4();
    final bool claimed = await _firestore.runTransaction<bool>((
      transaction,
    ) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(_orderPurgeSettingsReference);
      final Map<String, dynamic> settings =
          snapshot.data() ?? <String, dynamic>{};
      if (_orderPurgeIsRunning(settings)) {
        if (onlyIfDue) return false;
        throw StateError(
          'Another admin is already running a purge. Try again later.',
        );
      }
      if (onlyIfDue && !_orderPurgeIsDue(settings)) return false;
      if (orderPurgeRetentionMonths(settings) != selection.retentionMonths ||
          (settings['enabled'] == true) !=
              (selection._policy['enabled'] == true) ||
          !sameFirestoreValue(
            settings['updatedAt'],
            selection._policy['updatedAt'],
          )) {
        throw StateError(
          'The schedule changed after the count. Refresh and try again.',
        );
      }
      transaction.set(_orderPurgeSettingsReference, <String, dynamic>{
        'retentionMonths': selection.retentionMonths,
        'enabled': settings['enabled'] == true,
        'runId': runId,
        'runStartedAt': FieldValue.serverTimestamp(),
        'runLeaseUntil': Timestamp.fromDate(
          DateTime.now().add(_orderPurgeLease),
        ),
        'runRetentionMonths': selection.retentionMonths,
        'runEnabled': settings['enabled'] == true,
        'runPolicyUpdatedAt': settings['updatedAt'],
        'runDeletedCount': 0,
        'runSkippedCount': 0,
        'runStatus': 'running',
      }, SetOptions(merge: true));
      return true;
    });
    if (!claimed) return null;

    int oversizedCount = 0;
    try {
      int index = 0;
      while (index < selection._documents.length) {
        final Map<String, dynamic> orders = <String, dynamic>{};
        final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
        String csv = '';
        while (index < selection._documents.length && rows.length < 100) {
          final QueryDocumentSnapshot<Map<String, dynamic>> doc =
              selection._documents[index];
          final Map<String, dynamic> trialOrders = <String, dynamic>{
            ...orders,
            doc.id: doc.data(),
          };
          final List<Map<String, dynamic>> trialRows = <Map<String, dynamic>>[
            ...rows,
            <String, dynamic>{...doc.data(), 'docId': doc.id},
          ];
          final String trialCsv = _rowsToCsv('orders', trialRows);
          if (_orderPurgeBackupBytes(trialOrders) +
                  utf8.encode(trialCsv).length >
              _orderPurgeExportMaxBytes) {
            if (rows.isNotEmpty) break;
            oversizedCount++;
            index++;
            continue;
          }
          orders[doc.id] = doc.data();
          rows.add(trialRows.last);
          csv = trialCsv;
          index++;
        }
        if (rows.isEmpty) continue;
        final DocumentReference<Map<String, dynamic>> exportReference =
            _firestore.collection('purge_exports').doc();
        await _firestore.runTransaction((transaction) async {
          final DocumentSnapshot<Map<String, dynamic>> snapshot =
              await transaction.get(_orderPurgeSettingsReference);
          _ensureOrderPurgeLock(snapshot.data() ?? <String, dynamic>{}, runId);
          transaction.update(_orderPurgeSettingsReference, <String, dynamic>{
            'runLeaseUntil': Timestamp.fromDate(
              DateTime.now().add(_orderPurgeLease),
            ),
          });
          transaction.set(exportReference, <String, dynamic>{
            'collectionName': 'orders',
            'runId': runId,
            'actor': currentUser.uid,
            'createdAt': FieldValue.serverTimestamp(),
            'cutoff': Timestamp.fromDate(selection.cutoff),
            'retentionMonths': selection.retentionMonths,
            'orders': orders,
            'csv': csv,
            'selectedCount': orders.length,
            'deletedCount': 0,
            'keptChangedCount': 0,
            'status': 'exported_before_purge',
          });
        });
        for (final MapEntry<String, dynamic> entry in orders.entries) {
          await _deleteOrderAtomically(
            orderDocumentId: entry.key,
            currentUser: currentUser,
            purge: _OrderPurgeDeleteGuard(
              runId: runId,
              cutoff: selection.cutoff,
              exportedOrder: entry.value as Map<String, dynamic>,
              exportReference: exportReference,
            ),
          );
        }
        await exportReference.update(<String, dynamic>{
          'status': 'exported_and_purged',
          'purgedAt': FieldValue.serverTimestamp(),
        });
      }
      return await _finishOrderPurge(runId, oversizedCount: oversizedCount);
    } catch (_) {
      try {
        await _finishOrderPurge(
          runId,
          oversizedCount: oversizedCount,
          failed: true,
        );
      } catch (_) {}
      rethrow;
    }
  }

  Future<OrderPurgeResult> _finishOrderPurge(
    String runId, {
    required int oversizedCount,
    bool failed = false,
  }) async {
    return _firestore.runTransaction<OrderPurgeResult>((transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(_orderPurgeSettingsReference);
      final Map<String, dynamic> settings =
          snapshot.data() ?? <String, dynamic>{};
      if (settings['runId'] != runId) {
        throw StateError('The purge was superseded.');
      }
      final int removed = (settings['runDeletedCount'] as num?)?.toInt() ?? 0;
      final int skipped = (settings['runSkippedCount'] as num?)?.toInt() ?? 0;
      transaction.update(_orderPurgeSettingsReference, <String, dynamic>{
        'lastRunAt': FieldValue.serverTimestamp(),
        'lastRunCount': removed,
        'lastRunSkippedCount': skipped + oversizedCount,
        'lastRunOversizedCount': oversizedCount,
        'lastRunId': runId,
        'lastRunStatus': failed ? 'failed' : 'completed',
        'runStatus': failed ? 'failed' : 'completed',
        'runId': FieldValue.delete(),
        'runLeaseUntil': FieldValue.delete(),
      });
      return OrderPurgeResult(
        removed: removed,
        skipped: skipped + oversizedCount,
      );
    });
  }

  static int _orderPurgeBackupBytes(Object? value) {
    if (value == null || value is num || value is bool) return 32;
    if (value is String) return utf8.encode(value).length + 32;
    if (value is Timestamp || value is DateTime || value is GeoPoint) return 64;
    if (value is DocumentReference) return utf8.encode(value.path).length + 256;
    if (value is List) {
      return 32 +
          value.fold<int>(
            0,
            (total, item) => total + _orderPurgeBackupBytes(item),
          );
    }
    if (value is Map) {
      return 32 +
          value.entries.fold<int>(
            0,
            (total, entry) =>
                total +
                utf8.encode(entry.key.toString()).length +
                32 +
                _orderPurgeBackupBytes(entry.value),
          );
    }
    throw StateError(
      'An order has an unsupported backup value. It has not been purged.',
    );
  }

  Future<void> wipeSalespersonLiveLocations({required String actor}) async {
    if (!AppRuntime.firebaseReady) return;
    await purgeCollectionWithCsvExport(
      collectionName: 'live_tracking',
      actor: actor,
    );
    final List<Map<String, dynamic>> users = await _getRawCollectionAll(
      'users',
    );
    await _commitInChunks(users, (WriteBatch batch, Map<String, dynamic> row) {
      final String docId = _readText(row['docId'], fallback: '');
      if (docId.isEmpty) return;
      final String role = _normaliseRole(
        _readText(row['role'] ?? row['user_group'], fallback: ''),
      );
      if (role != 'salesman') return;
      batch.set(_firestore.collection('users').doc(docId), <String, dynamic>{
        'lastLatitude': FieldValue.delete(),
        'lastLongitude': FieldValue.delete(),
        'currentLatitude': FieldValue.delete(),
        'currentLongitude': FieldValue.delete(),
        'locationWipedAt': FieldValue.serverTimestamp(),
        'locationWipedBy': actor,
      }, SetOptions(merge: true));
    });
  }

  Future<BackfillReport> backfillOrderSalesmanNames({
    required String actor,
  }) async {
    if (!AppRuntime.firebaseReady) {
      return const BackfillReport(scanned: 0, patched: 0, unresolved: 0);
    }

    final List<Map<String, dynamic>> users = await _getRawCollectionAll(
      'users',
    );
    final Map<String, Map<String, dynamic>> userIndex = _buildUserIndex(users);

    int scanned = 0;
    int patched = 0;
    int unresolved = 0;
    WriteBatch batch = _firestore.batch();
    int batchOps = 0;

    final List<QueryDocumentSnapshot<Map<String, dynamic>>> orders =
        await _getRawDocumentsAll('orders');
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in orders) {
      scanned += 1;
      final Map<String, dynamic> data = doc.data();
      final String existingName = _readText(
        data['salesmanName'] ?? data['salesman_name'],
        fallback: '',
      );
      if (existingName.isNotEmpty &&
          !_isGenericSalesmanLabel(existingName) &&
          !_isUnknownText(existingName)) {
        continue;
      }

      final Map<String, dynamic>? user = _matchUser(userIndex, data);
      if (user == null) {
        unresolved += 1;
        continue;
      }

      final String name = _userDisplayName(user, fallback: '');
      if (name.isEmpty || _isGenericSalesmanLabel(name)) {
        unresolved += 1;
        continue;
      }

      final Map<String, dynamic> patch = <String, dynamic>{
        'salesmanName': name,
        if (_readText(user['uid'] ?? user['docId'], fallback: '').isNotEmpty)
          'salesmanUid': _readText(user['uid'] ?? user['docId'], fallback: ''),
        if (_readText(user['email'], fallback: '').isNotEmpty)
          'salesmanEmail': _readText(user['email'], fallback: ''),
        'backfilledAt': FieldValue.serverTimestamp(),
        'backfilledBy': actor,
      };

      batch.set(doc.reference, patch, SetOptions(merge: true));
      patched += 1;
      batchOps += 1;

      if (batchOps >= 400) {
        await batch.commit();
        batch = _firestore.batch();
        batchOps = 0;
      }
    }

    if (batchOps > 0) {
      await batch.commit();
    }

    return BackfillReport(
      scanned: scanned,
      patched: patched,
      unresolved: unresolved,
    );
  }

  Future<void> saveSystemPolicy(Map<String, dynamic> data) async {
    if (!AppRuntime.firebaseReady) return;
    await _firestore.collection('system_settings').doc('gps_policy').set(
      <String, dynamic>{...data, 'updatedAt': FieldValue.serverTimestamp()},
      SetOptions(merge: true),
    );
    await AuditLogService.instance.record(
      action: 'updated',
      entityType: 'system_settings',
      entityId: 'gps_policy',
      summary: 'Updated GPS system policy',
    );
  }

  Future<int> _deleteExportedDocuments(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> exported,
  ) async {
    int kept = 0;
    for (int start = 0; start < exported.length; start += 100) {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> chunk = exported
          .sublist(start, (start + 100).clamp(0, exported.length));
      kept += await _firestore.runTransaction<int>((
        Transaction transaction,
      ) async {
        final List<DocumentSnapshot<Map<String, dynamic>>> current =
            <DocumentSnapshot<Map<String, dynamic>>>[
              for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
                  in chunk)
                await transaction.get(doc.reference),
            ];
        int chunkKept = 0;
        for (int i = 0; i < chunk.length; i++) {
          if (current[i].exists &&
              sameFirestoreValue(current[i].data(), chunk[i].data())) {
            transaction.delete(chunk[i].reference);
          } else {
            chunkKept++;
          }
        }
        return chunkKept;
      });
    }
    return kept;
  }

  Future<void> _commitInChunks(
    List<Map<String, dynamic>> rows,
    void Function(WriteBatch batch, Map<String, dynamic> row) addOperation,
  ) async {
    WriteBatch batch = _firestore.batch();
    int operations = 0;
    for (final Map<String, dynamic> row in rows) {
      addOperation(batch, row);
      operations++;
      if (operations >= 400) {
        await batch.commit();
        batch = _firestore.batch();
        operations = 0;
      }
    }
    if (operations > 0) await batch.commit();
  }

  static String _exportText(Object? value) {
    if (value == null) return '';
    if (value is Timestamp) {
      return value
          .toDate()
          .toUtc()
          .add(const Duration(hours: 8))
          .toIso8601String();
    }
    if (value is DateTime) {
      return value.toUtc().add(const Duration(hours: 8)).toIso8601String();
    }
    if (value is GeoPoint) return '${value.latitude},${value.longitude}';
    if (value is Map || value is List) return value.toString();
    return value.toString();
  }

  static double? _readLatitude(Map<String, dynamic> row) {
    return _readCoordinate(row, isLatitude: true);
  }

  static double? _readLongitude(Map<String, dynamic> row) {
    return _readCoordinate(row, isLatitude: false);
  }

  static double? _readCoordinate(
    Map<String, dynamic> row, {
    required bool isLatitude,
  }) {
    final List<String> directKeys = isLatitude
        ? <String>[
            'gpsLatitude',
            'gps_latitude',
            'gpsLat',
            'gps_lat',
            'latitude',
            'lat',
            'Latitude',
            'Lat',
            'lastLatitude',
            'lastLat',
            'last_latitude',
            'lastKnownLatitude',
            'lastKnownLat',
            'currentLatitude',
            'currentLat',
            'current_latitude',
          ]
        : <String>[
            'gpsLongitude',
            'gps_longitude',
            'gpsLng',
            'gps_lng',
            'gpsLon',
            'gps_lon',
            'longitude',
            'lng',
            'lon',
            'Longitude',
            'Lng',
            'Lon',
            'lastLongitude',
            'lastLng',
            'last_longitude',
            'lastKnownLongitude',
            'lastKnownLng',
            'currentLongitude',
            'currentLng',
            'current_longitude',
          ];

    for (final String key in directKeys) {
      final double? value = _toDouble(row[key]);
      if (value != null && value != 0) return value;
    }

    for (final String key in <String>[
      'location',
      'gpsLocation',
      'coordinates',
      'currentLocation',
      'lastLocation',
    ]) {
      final Object? value = row[key];
      if (value is GeoPoint) {
        final double coordinate = isLatitude ? value.latitude : value.longitude;
        if (coordinate != 0) return coordinate;
      }
      if (value is Map) {
        final Map<dynamic, dynamic> map = value;
        final List<String> nestedKeys = isLatitude
            ? <String>[
                'latitude',
                'lat',
                'gpsLatitude',
                'gps_latitude',
                'gpsLat',
                'lastLat',
                'currentLat',
              ]
            : <String>[
                'longitude',
                'lng',
                'lon',
                'gpsLongitude',
                'gps_longitude',
                'gpsLng',
                'lastLng',
                'currentLng',
              ];
        for (final String nestedKey in nestedKeys) {
          final double? coordinate = _toDouble(map[nestedKey]);
          if (coordinate != null && coordinate != 0) return coordinate;
        }
      }
    }
    return null;
  }

  static double? _toDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString());
  }
}

class OrderPurgeSelection {
  OrderPurgeSelection._(
    this._policy,
    this.cutoff,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
  ) : _documents =
          List<QueryDocumentSnapshot<Map<String, dynamic>>>.unmodifiable(
            documents,
          );

  final Map<String, dynamic> _policy;
  final DateTime cutoff;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> _documents;
  int get count => _documents.length;
  int get retentionMonths => CmsRepository.orderPurgeRetentionMonths(_policy);
}

class OrderPurgeResult {
  const OrderPurgeResult({required this.removed, required this.skipped});
  final int removed;
  final int skipped;
}

class _OrderPurgeDeleteGuard {
  const _OrderPurgeDeleteGuard({
    required this.runId,
    required this.cutoff,
    required this.exportedOrder,
    required this.exportReference,
  });
  final String runId;
  final DateTime cutoff;
  final Map<String, dynamic> exportedOrder;
  final DocumentReference<Map<String, dynamic>> exportReference;
}

class OrderWindowRead {
  const OrderWindowRead({required this.rows, this.truncated = false});

  final List<Map<String, dynamic>> rows;

  final bool truncated;
}

class VisitWindowRead {
  const VisitWindowRead({
    required this.rows,
    this.visitLogsTruncated = false,
    this.routeStopsTruncated = false,
    this.rowsWithoutTimestamp = 0,
    this.routeStopRows = const <Map<String, dynamic>>[],
  });

  final List<Map<String, dynamic>> rows;

  final List<Map<String, dynamic>> routeStopRows;

  final bool visitLogsTruncated;
  final bool routeStopsTruncated;
  bool get truncated => visitLogsTruncated || routeStopsTruncated;

  final int rowsWithoutTimestamp;
}

class BackfillReport {
  const BackfillReport({
    required this.scanned,
    required this.patched,
    required this.unresolved,
  });

  final int scanned;
  final int patched;
  final int unresolved;

  String get summary {
    if (scanned == 0) return 'No orders found.';
    if (patched == 0 && unresolved == 0) {
      return 'All $scanned orders already had a salesman name. Nothing to fix.';
    }
    final List<String> parts = <String>['Scanned $scanned'];
    if (patched > 0) parts.add('patched $patched');
    if (unresolved > 0) parts.add('$unresolved could not be matched to a user');
    return '${parts.join(' · ')}.';
  }
}

enum _PreciseLocationScopeKind {
  admin,
  supervisor,
  branchManager,
  salesman,
  none,
  failed,
}

class _PreciseLocationScope {
  const _PreciseLocationScope._(
    this.kind, {
    this.uid = '',
    this.branchId = '',
    this.salesmanCodes = const <String>[],
    this.retailerBranchId = '',
  });

  const _PreciseLocationScope.admin() : this._(_PreciseLocationScopeKind.admin);

  _PreciseLocationScope.supervisor(
    List<String> salesmanCodes, {
    String retailerBranchId = '',
  }) : this._(
         _PreciseLocationScopeKind.supervisor,
         salesmanCodes: List<String>.unmodifiable(salesmanCodes),
         retailerBranchId: retailerBranchId,
       );

  _PreciseLocationScope.branchManager(String branchId)
    : this._(_PreciseLocationScopeKind.branchManager, branchId: branchId);

  _PreciseLocationScope.salesman(String uid, {String retailerBranchId = ''})
    : this._(
        _PreciseLocationScopeKind.salesman,
        uid: uid,
        retailerBranchId: retailerBranchId,
      );

  const _PreciseLocationScope.none() : this._(_PreciseLocationScopeKind.none);

  const _PreciseLocationScope.failed()
    : this._(_PreciseLocationScopeKind.failed);

  final _PreciseLocationScopeKind kind;
  final String uid;
  final String branchId;
  final List<String> salesmanCodes;
  final String retailerBranchId;

  bool get canRead =>
      kind != _PreciseLocationScopeKind.none &&
      kind != _PreciseLocationScopeKind.failed;

  bool get resolutionFailed => kind == _PreciseLocationScopeKind.failed;
}

class _ReplayCollectionStream
    extends RefCountedReplayStream<List<Map<String, dynamic>>> {
  _ReplayCollectionStream(super.createSource)
    : super(
        snapshot: CmsRepository.replayedRows,
        keepAlive: const Duration(seconds: 90),
      );
}

class _RetailerBatch {
  const _RetailerBatch({required this.found, required this.denied});

  final Map<String, Map<String, dynamic>> found;
  final Set<String> denied;
}

class _RetailerLookupResult {
  const _RetailerLookupResult(this.key, this.future, this.row, this.ok);

  final String key;
  final Future<Map<String, dynamic>?> future;
  final Map<String, dynamic>? row;
  final bool ok;
}
