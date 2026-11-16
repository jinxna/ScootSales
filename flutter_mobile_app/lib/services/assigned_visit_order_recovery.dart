import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../utils/order_submission_id.dart';

enum AssignedVisitOrderRecoveryStatus {
  absent,
  pending,
  submitted,
  conflict,
  unavailable,
}

enum AssignedVisitOrderRecoveryCause { timeout, offline, unknown }

class AssignedVisitOrderRecoveryResult {
  const AssignedVisitOrderRecoveryResult(
    this.status, {
    this.orderId = '',
    this.duplicateCount = 0,
    this.cause = AssignedVisitOrderRecoveryCause.unknown,
  });

  final AssignedVisitOrderRecoveryStatus status;
  final String orderId;
  final int duplicateCount;
  final AssignedVisitOrderRecoveryCause cause;
}

class AssignedVisitOrderRecovery {
  AssignedVisitOrderRecovery({FirebaseFirestore? firestore})
    : _db = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _db;

  Future<AssignedVisitOrderRecoveryResult> resolve({
    required String salesmanUid,
    required String retailerId,
    required String routePlanId,
    required String routeStopId,
  }) async {
    final String uid = salesmanUid.trim();
    final String retailer = retailerId.trim();
    final String plan = routePlanId.trim();
    final String stop = routeStopId.trim();
    if (uid.isEmpty || retailer.isEmpty || plan.isEmpty || stop.isEmpty) {
      return const AssignedVisitOrderRecoveryResult(
        AssignedVisitOrderRecoveryStatus.conflict,
      );
    }

    try {
      final QuerySnapshot<Map<String, dynamic>> server = await _query(
        uid: uid,
        plan: plan,
        stop: stop,
        source: Source.server,
      ).timeout(const Duration(seconds: 8));
      return _classify(
        server,
        uid: uid,
        retailer: retailer,
        plan: plan,
        stop: stop,
      );
    } catch (error) {
      final AssignedVisitOrderRecoveryCause cause = error is TimeoutException
          ? AssignedVisitOrderRecoveryCause.timeout
          : error is FirebaseException && error.code == 'unavailable'
          ? AssignedVisitOrderRecoveryCause.offline
          : AssignedVisitOrderRecoveryCause.unknown;
      debugPrint('Assigned-order server reconciliation failed: $error');
      try {
        final QuerySnapshot<Map<String, dynamic>> cached = await _query(
          uid: uid,
          plan: plan,
          stop: stop,
          source: Source.cache,
        );
        if (cached.docs.isNotEmpty) {
          return _classify(
            cached,
            uid: uid,
            retailer: retailer,
            plan: plan,
            stop: stop,
          );
        }
      } catch (error) {
        debugPrint('Assigned-order cache reconciliation failed: $error');
      }
      return AssignedVisitOrderRecoveryResult(
        AssignedVisitOrderRecoveryStatus.unavailable,
        cause: cause,
      );
    }
  }

  Future<QuerySnapshot<Map<String, dynamic>>> _query({
    required String uid,
    required String plan,
    required String stop,
    required Source source,
  }) => _db
      .collection('orders')
      .where('salesmanUid', isEqualTo: uid)
      .where('routePlanId', isEqualTo: plan)
      .where('routeStopId', isEqualTo: stop)
      .limit(3)
      .get(GetOptions(source: source));

  AssignedVisitOrderRecoveryResult _classify(
    QuerySnapshot<Map<String, dynamic>> snapshot, {
    required String uid,
    required String retailer,
    required String plan,
    required String stop,
  }) {
    if (snapshot.docs.isEmpty) {
      return const AssignedVisitOrderRecoveryResult(
        AssignedVisitOrderRecoveryStatus.absent,
      );
    }
    if (snapshot.docs.length > 1) {
      return AssignedVisitOrderRecoveryResult(
        AssignedVisitOrderRecoveryStatus.conflict,
        duplicateCount: snapshot.docs.length,
      );
    }
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in snapshot.docs) {
      if (!matchesOrderSubmissionIdentity(
        doc.data(),
        orderId: doc.id,
        salesmanUid: uid,
        retailerId: retailer,
        routePlanId: plan,
        routeStopId: stop,
      )) {
        return AssignedVisitOrderRecoveryResult(
          AssignedVisitOrderRecoveryStatus.conflict,
          duplicateCount: snapshot.docs.length,
        );
      }
    }
    final QueryDocumentSnapshot<Map<String, dynamic>> preferred =
        snapshot.docs.single;
    return AssignedVisitOrderRecoveryResult(
      snapshot.metadata.hasPendingWrites
          ? AssignedVisitOrderRecoveryStatus.pending
          : AssignedVisitOrderRecoveryStatus.submitted,
      orderId: preferred.id,
      duplicateCount: snapshot.docs.length,
    );
  }
}
