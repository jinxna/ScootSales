import 'dart:async';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../models/user_profile.dart';

class AccountLockoutService {
  AccountLockoutService._();

  static final AccountLockoutService instance = AccountLockoutService._();
  static const String requestsCollection = 'account_lock_requests';
  static const String receiptsCollection = 'account_lock_receipts';
  static const Duration _networkTimeout = Duration(seconds: 8);

  FirebaseFirestore get _db => FirebaseFirestore.instance;
  final Map<String, _LocalReport> _reports = <String, _LocalReport>{};

  _LocalReport _report(String email, DateTime lockedUntil) {
    final String identity = email.trim().toLowerCase();
    final _LocalReport? previous = _reports[identity];
    if (previous != null && previous.lockedUntil == lockedUntil) {
      return previous;
    }
    final Random random = Random.secure();
    final String id = List<String>.generate(
      32,
      (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    ).join();
    return _reports[identity] = _LocalReport(id, lockedUntil);
  }

  bool isNotified({required String email, required DateTime lockedUntil}) {
    final _LocalReport? report = _reports[email.trim().toLowerCase()];
    return report?.lockedUntil == lockedUntil && report!.notified;
  }

  Future<void> notifyAdmin({
    required String email,
    required DateTime lockedUntil,
  }) async {
    if (!lockedUntil.isAfter(DateTime.now())) {
      throw StateError('The local retry delay has expired.');
    }
    final _LocalReport report = _report(email, lockedUntil);
    if (report.notified) return;
    if (report.commit != null && await _receiptStatus(report.id) != null) {
      report.notified = true;
      return;
    }
    report.commit ??= _createReport(email.trim().toLowerCase(), report);
    try {
      await report.commit!.timeout(_networkTimeout);
      report.notified = true;
    } on TimeoutException {
      rethrow;
    } catch (_) {
      report.commit = null;
      rethrow;
    }
  }

  Future<void> _createReport(String email, _LocalReport report) async {
    final int hour = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 3600000;
    FirebaseException? refused;
    for (final int? shift in <int?>[0, -1, 1, null]) {
      try {
        await _commitReport(
          email,
          report,
          shift == null ? null : hour + shift,
        );
        return;
      } on FirebaseException catch (error) {
        if (error.code != 'permission-denied') rethrow;
        refused = error;
      }
    }
    throw refused!;
  }

  Future<void> _commitReport(String email, _LocalReport report, int? hour) {
    final WriteBatch batch = _db.batch();
    if (hour == null) {
      batch.set(
        _db
            .collection('account_lock_limits')
            .doc(email.replaceAll('%', '%25').replaceAll('/', '%2F')),
        <String, dynamic>{
          'claimedEmail': email,
          'requestId': report.id,
          'createdAt': FieldValue.serverTimestamp(),
        },
      );
    } else {
      batch.set(
        _db.collection('account_lock_windows').doc('h$hour'),
        <String, dynamic>{
          'count': FieldValue.increment(1),
          'requestId': report.id,
        },
        SetOptions(merge: true),
      );
    }
    batch.set(
      _db.collection(requestsCollection).doc(report.id),
      <String, dynamic>{
        'claimedEmail': email,
        'client': 'dashboard',
        'localLockedUntil': Timestamp.fromDate(report.lockedUntil),
        'createdAt': FieldValue.serverTimestamp(),
        'status': 'pending',
        'reviewedAt': null,
        'reviewedBy': null,
      },
    );
    batch.set(
      _db.collection(receiptsCollection).doc(report.id),
      <String, dynamic>{
        'status': 'pending',
        'createdAt': FieldValue.serverTimestamp(),
        'reviewedAt': null,
      },
    );
    batch.set(
      _db.collection('system_audit_logs').doc('lock_request_${report.id}'),
      <String, dynamic>{
        'action': 'local_lock_reported',
        'entityType': requestsCollection,
        'entityId': report.id,
        'summary': 'Unverified local lock reported.',
        'actorUid': '',
        'actorEmail': '',
        'actorName': '',
        'actorRole': 'unauthenticated',
        'metadata': <String, dynamic>{
          'client': 'dashboard',
          'unverified': true,
        },
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    return batch.commit();
  }

  Future<String?> _receiptStatus(String requestId) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> receipt = await _db
          .collection(receiptsCollection)
          .doc(requestId)
          .get(const GetOptions(source: Source.server))
          .timeout(_networkTimeout);
      if (!receipt.exists || receipt.metadata.hasPendingWrites) return null;
      final String? status = receipt.data()?['status'] as String?;
      return status == 'pending' || status == 'unlocked' ? status : null;
    } on FirebaseException {
      return null;
    } on TimeoutException {
      return null;
    }
  }

  Future<bool> isUnlocked({
    required String email,
    required DateTime lockedUntil,
  }) async {
    final _LocalReport? report = _reports[email.trim().toLowerCase()];
    if (report == null || report.lockedUntil != lockedUntil) return false;
    return await _receiptStatus(report.id) == 'unlocked';
  }

  Future<void> unlockRequest({
    required String requestId,
    required UserProfile actor,
  }) async {
    final String uid = FirebaseAuth.instance.currentUser?.uid ?? '';
    if (!actor.isActive || !actor.isAdmin || uid.isEmpty || actor.uid != uid) {
      throw StateError('An active admin session is required.');
    }
    if (!RegExp(r'^[a-f0-9]{64}$').hasMatch(requestId)) {
      throw ArgumentError('Invalid lock request id.');
    }
    final DocumentReference<Map<String, dynamic>> request = _db
        .collection(requestsCollection)
        .doc(requestId);
    final DocumentReference<Map<String, dynamic>> receipt = _db
        .collection(receiptsCollection)
        .doc(requestId);
    await _db.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = await transaction
          .get(request);
      final Map<String, dynamic>? data = snapshot.data();
      if (data == null) throw StateError('The lock report is unavailable.');
      if (data['status'] == 'unlocked') return;
      if (data['status'] != 'pending') {
        throw StateError('The lock report cannot be reviewed.');
      }
      transaction.update(request, <String, dynamic>{
        'status': 'unlocked',
        'reviewedAt': FieldValue.serverTimestamp(),
        'reviewedBy': uid,
      });
      transaction.update(receipt, <String, dynamic>{
        'status': 'unlocked',
        'reviewedAt': FieldValue.serverTimestamp(),
      });
      transaction.set(
        _db.collection('system_audit_logs').doc('lock_unlock_$requestId'),
        <String, dynamic>{
          'action': 'local_lock_unlocked',
          'entityType': requestsCollection,
          'entityId': requestId,
          'summary': 'Admin released a reported local retry delay.',
          'actorUid': uid,
          'actorEmail': FirebaseAuth.instance.currentUser?.email?.trim() ?? '',
          'actorName': actor.name,
          'actorRole': actor.role,
          'metadata': <String, dynamic>{'unverified': true},
          'createdAt': FieldValue.serverTimestamp(),
        },
      );
    });
  }
}

class _LocalReport {
  _LocalReport(this.id, this.lockedUntil);

  final String id;
  final DateTime lockedUntil;
  bool notified = false;
  Future<void>? commit;
}
