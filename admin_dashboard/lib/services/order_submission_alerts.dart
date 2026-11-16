import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';
import 'browser_notifier.dart';

class OrderChange {
  const OrderChange({
    required this.id,
    required this.data,
    this.removed = false,
    this.pendingWrite = false,
  });

  final String id;
  final Map<String, dynamic> data;
  final bool removed;

  final bool pendingWrite;
}

class OrderAlert {
  const OrderAlert({
    required this.orderId,
    required this.message,
    this.specialRequest = false,
  });

  final String orderId;
  final String message;

  final bool specialRequest;
}

class OrderSubmissionAlerts {
  OrderSubmissionAlerts({
    required this.onAlert,
    this.specialRequests = false,
    this.informationalRequests = false,
  });

  final void Function(OrderAlert alert) onAlert;

  final bool specialRequests;

  final bool informationalRequests;
  final Set<String> _seenSubmitted = <String>{};
  bool _baselined = false;

  DateTime? _baselineNewest;
  StreamSubscription<List<OrderChange>>? _subscription;

  static Stream<List<OrderChange>> firestoreChanges(FirebaseFirestore db) {
    return db
        .collection('orders')
        .orderBy('createdAt', descending: true)
        .limit(50)
        .snapshots(includeMetadataChanges: true)
        .where(
          (QuerySnapshot<Map<String, dynamic>> s) => !s.metadata.isFromCache,
        )
        .map(
          (QuerySnapshot<Map<String, dynamic>> snapshot) => snapshot.docChanges
              .map(
                (DocumentChange<Map<String, dynamic>> change) => OrderChange(
                  id: change.doc.id,
                  data: change.doc.data() ?? <String, dynamic>{},
                  removed: change.type == DocumentChangeType.removed,
                  pendingWrite: change.doc.metadata.hasPendingWrites,
                ),
              )
              .toList(growable: false),
        );
  }

  static Stream<List<OrderChange>> scopedChanges(
    FirebaseFirestore db,
    UserProfile user, {
    bool specialRequests = false,
  }) {
    final CollectionReference<Map<String, dynamic>> collection = db.collection(
      specialRequests ? 'special_requests' : 'orders',
    );
    final String timeField = specialRequests ? 'createdAt' : 'submittedAt';
    final List<Query<Map<String, dynamic>>> queries =
        <Query<Map<String, dynamic>>>[];
    if (user.isSupervisor) {
      final List<String> codes = user.assignedSalesmanCodes
          .map((String c) => c.trim())
          .where((String c) => c.isNotEmpty)
          .toSet()
          .toList(growable: false);
      for (final List<String> chunk in chunkFirestoreWhereIn(
        codes,
        chunkSize: 10,
      )) {
        queries.add(collection.where('salesmanCode', whereIn: chunk));
      }
    } else if (user.isBranchManager && user.branchId.trim().isNotEmpty) {
      queries.add(
        collection.where('branchId', isEqualTo: user.branchId.trim()),
      );
    }
    if (queries.isEmpty) return const Stream<List<OrderChange>>.empty();

    final StreamController<List<OrderChange>> controller =
        StreamController<List<OrderChange>>();
    final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>> subs =
        <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
    final List<OrderChange> baseline = <OrderChange>[];
    final Set<int> answered = <int>{};
    bool baselineSent = false;
    void answer(int index, List<OrderChange> docs) {
      if (baselineSent || !answered.add(index)) return;
      baseline.addAll(docs);
      if (answered.length == queries.length) {
        baselineSent = true;
        controller.add(List<OrderChange>.of(baseline, growable: false));
      }
    }

    OrderChange toChange(
      DocumentSnapshot<Map<String, dynamic>> doc, {
      bool removed = false,
    }) => OrderChange(
      id: doc.id,
      data: doc.data() ?? <String, dynamic>{},
      removed: removed,
      pendingWrite: doc.metadata.hasPendingWrites,
    );

    controller.onListen = () {
      for (int i = 0; i < queries.length; i++) {
        subs.add(
          queries[i]
              .orderBy(timeField, descending: true)
              .limit(50)
              .snapshots(includeMetadataChanges: true)
              .where(
                (QuerySnapshot<Map<String, dynamic>> s) =>
                    !s.metadata.isFromCache,
              )
              .listen(
                (QuerySnapshot<Map<String, dynamic>> snapshot) {
                  if (!answered.contains(i)) {
                    answer(
                      i,
                      snapshot.docs
                          .map(
                            (QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                                toChange(d),
                          )
                          .toList(growable: false),
                    );
                    return;
                  }
                  if (!baselineSent) return;
                  controller.add(
                    snapshot.docChanges
                        .map(
                          (DocumentChange<Map<String, dynamic>> change) =>
                              toChange(
                                change.doc,
                                removed:
                                    change.type == DocumentChangeType.removed,
                              ),
                        )
                        .toList(growable: false),
                  );
                },
                onError: (Object error) {
                  debugPrint('Order alert query $i failed: $error');
                  answer(i, const <OrderChange>[]);
                },
              ),
        );
      }
    };
    controller.onCancel = () async {
      for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>> sub
          in subs) {
        await sub.cancel();
      }
    };
    return controller.stream;
  }

  void start(Stream<List<OrderChange>> changes) {
    armBrowserNotificationPermission();
    _subscription = changes.listen(handle, onError: (Object _) {});
  }

  Future<void> dispose() async => _subscription?.cancel();

  void handle(List<OrderChange> changes) {
    final bool baseline = !_baselined;
    _baselined = true;
    final String? ownUid = _ownUid();
    for (final OrderChange change in changes) {
      if (change.removed || change.pendingWrite) continue;
      final DateTime? submittedAt = _submittedAt(change.data);
      if (baseline &&
          submittedAt != null &&
          (_baselineNewest == null || submittedAt.isAfter(_baselineNewest!))) {
        _baselineNewest = submittedAt;
      }
      final String status = '${change.data['status'] ?? ''}'
          .trim()
          .toLowerCase();
      if (specialRequests
          ? !status.startsWith('pending')
          : status != 'submitted' && status != 'held_for_review') {
        continue;
      }
      if (baseline) {
        _seenSubmitted.add(change.id);
        continue;
      }
      if (ownUid != null && '${change.data['createdByUid'] ?? ''}' == ownUid) {
        continue;
      }
      final DateTime? newest = _baselineNewest;
      if (submittedAt != null &&
          newest != null &&
          !submittedAt.isAfter(newest)) {
        continue;
      }
      if (!_seenSubmitted.add(change.id)) continue;
      final OrderAlert alert = OrderAlert(
        orderId: change.id,
        message: specialRequests
            ? _requestMessage(change.data, informational: informationalRequests)
            : _message(change.data),
        specialRequest: specialRequests,
      );
      showBrowserNotification(
        specialRequests ? 'New special request' : 'New order submitted',
        alert.message,
      );
      onAlert(alert);
    }
  }

  static String? _ownUid() {
    try {
      final String? uid = FirebaseAuth.instance.currentUser?.uid;
      return uid == null || uid.isEmpty ? null : uid;
    } catch (_) {
      return null;
    }
  }

  static DateTime? _submittedAt(Map<String, dynamic> data) {
    final Object? raw = data['submittedAt'] ?? data['createdAt'];
    if (raw is Timestamp) return raw.toDate();
    if (raw is DateTime) return raw;
    return null;
  }

  static String _requestMessage(
    Map<String, dynamic> data, {
    bool informational = false,
  }) {
    final String retailer = '${data['retailerName'] ?? ''}'.trim();
    return 'New special request'
        '${retailer.isEmpty ? '' : ' for $retailer'} '
        '${informational ? 'was raised in your branch.' : 'needs a decision.'}';
  }

  static String _message(Map<String, dynamic> data) {
    String pick(List<String> keys) {
      for (final String key in keys) {
        final String value = '${data[key] ?? ''}'.trim();
        if (value.isNotEmpty) return value;
      }
      return '';
    }

    final String salesman = pick(<String>['salesmanName', 'salesman_name']);
    final String retailer = pick(<String>['retailerName', 'retailer_name']);
    return 'Order submitted'
        '${salesman.isEmpty ? '' : ' by $salesman'}'
        '${retailer.isEmpty ? '' : ' for $retailer'}.';
  }
}
