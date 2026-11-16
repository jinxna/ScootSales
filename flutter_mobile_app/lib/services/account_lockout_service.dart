import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:shared_preferences/shared_preferences.dart';

class AccountLockoutService {
  AccountLockoutService._();

  static final AccountLockoutService instance = AccountLockoutService._();
  static const Duration _networkTimeout = Duration(seconds: 8);
  FirebaseFirestore get _db => FirebaseFirestore.instance;
  final Map<String, Future<void>> _commits = <String, Future<void>>{};
  final Map<String, Future<void>> _notifications = <String, Future<void>>{};

  String _key(String email) =>
      'account_lock_report_${base64Url.encode(utf8.encode(email.trim().toLowerCase()))}';

  Future<Map<String, dynamic>?> _load(
    String email,
    DateTime lockedUntil,
  ) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    final String? encoded = preferences.getString(_key(email));
    if (encoded == null) return null;
    try {
      final Map<String, dynamic> data =
          jsonDecode(encoded) as Map<String, dynamic>;
      if (data['untilMs'] != lockedUntil.millisecondsSinceEpoch ||
          data['id'] is! String ||
          !RegExp(r'^[a-f0-9]{64}$').hasMatch(data['id'] as String)) {
        return null;
      }
      return data;
    } on FormatException {
      return null;
    } on TypeError {
      return null;
    }
  }

  Future<void> _save(String email, Map<String, dynamic> data) async {
    final SharedPreferences preferences = await SharedPreferences.getInstance();
    if (!await preferences.setString(_key(email), jsonEncode(data))) {
      throw StateError('Could not save the local notification receipt.');
    }
  }

  Future<bool> isNotified({
    required String email,
    required DateTime lockedUntil,
  }) async {
    return (await _load(email, lockedUntil))?['notified'] == true;
  }

  Future<void> notifyAdmin({
    required String email,
    required DateTime lockedUntil,
  }) {
    final String key = '${_key(email)}_${lockedUntil.millisecondsSinceEpoch}';
    return _notifications.putIfAbsent(
      key,
      () =>
          _notifyAdmin(email: email, lockedUntil: lockedUntil).whenComplete(() {
            _notifications.remove(key);
          }),
    );
  }

  Future<void> _notifyAdmin({
    required String email,
    required DateTime lockedUntil,
  }) async {
    if (!lockedUntil.isAfter(DateTime.now())) {
      throw StateError('The local retry delay has expired.');
    }
    Map<String, dynamic>? report = await _load(email, lockedUntil);
    if (report?['notified'] == true) return;
    if (report != null &&
        await _receiptStatus(report['id'] as String) != null) {
      report['notified'] = true;
      await _save(email, report);
      return;
    }
    if (report == null) {
      final Random random = Random.secure();
      report = <String, dynamic>{
        'id': List<String>.generate(
          32,
          (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
        ).join(),
        'untilMs': lockedUntil.millisecondsSinceEpoch,
        'notified': false,
      };
      await _save(email, report);
    }
    final String id = report['id'] as String;
    final Future<void> commit = _commits.putIfAbsent(
      id,
      () => _createReport(email.trim().toLowerCase(), lockedUntil, id),
    );
    try {
      await commit.timeout(_networkTimeout);
      report['notified'] = true;
      await _save(email, report);
      _commits.remove(id);
    } on TimeoutException {
      rethrow;
    } catch (_) {
      _commits.remove(id);
      rethrow;
    }
  }

  Future<void> _createReport(
    String email,
    DateTime lockedUntil,
    String id,
  ) async {
    final int hour = DateTime.now().toUtc().millisecondsSinceEpoch ~/ 3600000;
    FirebaseException? refused;
    for (final int? shift in <int?>[0, -1, 1, null]) {
      try {
        await _commitReport(
          email,
          lockedUntil,
          id,
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

  Future<void> _commitReport(
    String email,
    DateTime lockedUntil,
    String id,
    int? hour,
  ) {
    final WriteBatch batch = _db.batch();
    if (hour == null) {
      batch.set(
        _db
            .collection('account_lock_limits')
            .doc(email.replaceAll('%', '%25').replaceAll('/', '%2F')),
        <String, dynamic>{
          'claimedEmail': email,
          'requestId': id,
          'createdAt': FieldValue.serverTimestamp(),
        },
      );
    } else {
      batch.set(
        _db.collection('account_lock_windows').doc('h$hour'),
        <String, dynamic>{'count': FieldValue.increment(1), 'requestId': id},
        SetOptions(merge: true),
      );
    }
    batch
        .set(_db.collection('account_lock_requests').doc(id), <String, dynamic>{
          'claimedEmail': email,
          'client': 'mobile',
          'localLockedUntil': Timestamp.fromDate(lockedUntil),
          'createdAt': FieldValue.serverTimestamp(),
          'status': 'pending',
          'reviewedAt': null,
          'reviewedBy': null,
        });
    batch
        .set(_db.collection('account_lock_receipts').doc(id), <String, dynamic>{
          'status': 'pending',
          'createdAt': FieldValue.serverTimestamp(),
          'reviewedAt': null,
        });
    batch.set(
      _db.collection('system_audit_logs').doc('lock_request_$id'),
      <String, dynamic>{
        'action': 'local_lock_reported',
        'entityType': 'account_lock_requests',
        'entityId': id,
        'summary': 'Unverified local lock reported.',
        'actorUid': '',
        'actorEmail': '',
        'actorName': '',
        'actorRole': 'unauthenticated',
        'metadata': <String, dynamic>{'client': 'mobile', 'unverified': true},
        'createdAt': FieldValue.serverTimestamp(),
      },
    );
    return batch.commit();
  }

  Future<String?> _receiptStatus(String id) async {
    try {
      final DocumentSnapshot<Map<String, dynamic>> receipt = await _db
          .collection('account_lock_receipts')
          .doc(id)
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
    final Map<String, dynamic>? report = await _load(email, lockedUntil);
    if (report == null) return false;
    return await _receiptStatus(report['id'] as String) == 'unlocked';
  }
}
