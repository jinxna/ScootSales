import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

import '../utils/notification_read_state.dart';

class NotificationReadStateService {
  NotificationReadStateService({
    FirebaseFirestore? firestore,
    FirebaseAuth? auth,
    String? authUid,
    this.timeout = const Duration(seconds: 5),
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _auth = auth,
       _configuredAuthUid = authUid;

  static const String collectionName = 'notification_read_state';

  final FirebaseFirestore _firestore;
  final FirebaseAuth? _auth;
  final String? _configuredAuthUid;
  final Duration timeout;

  String get authUid {
    final String configured = _configuredAuthUid?.trim() ?? '';
    if (configured.isNotEmpty) return configured;
    try {
      return (_auth ?? FirebaseAuth.instance).currentUser?.uid.trim() ?? '';
    } on Object {
      return '';
    }
  }

  Future<NotificationReadState?> load({String? forAuthUid}) async {
    final DocumentReference<Map<String, dynamic>> reference = _document(
      forAuthUid,
    );
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await reference
        .get()
        .timeout(timeout);
    return snapshot.exists
        ? NotificationReadState.fromMap(snapshot.data())
        : null;
  }

  Stream<NotificationReadState?> watch({String? forAuthUid}) {
    final String uid = _validatedUid(forAuthUid);
    if (uid.isEmpty) return Stream<NotificationReadState?>.value(null);
    return _firestore
        .collection(collectionName)
        .doc(uid)
        .snapshots(includeMetadataChanges: true)
        .map(
          (DocumentSnapshot<Map<String, dynamic>> snapshot) => snapshot.exists
              ? NotificationReadState.fromMap(snapshot.data())
              : null,
        );
  }

  Future<DateTime> markAllRead({
    String? forAuthUid,
    DateTime? localCutoff,
  }) async {
    final DocumentReference<Map<String, dynamic>> reference = _document(
      forAuthUid,
    );
    final DateTime cutoff = (localCutoff ?? DateTime.now()).toUtc();
    await reference
        .set(<String, dynamic>{
          'readThroughAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        }, SetOptions(merge: true))
        .timeout(timeout);
    return cutoff;
  }

  DocumentReference<Map<String, dynamic>> _document(String? requestedUid) {
    final String uid = _validatedUid(requestedUid);
    if (uid.isEmpty) {
      throw StateError(
        'A signed-in account is required to read notifications.',
      );
    }
    return _firestore.collection(collectionName).doc(uid);
  }

  String _validatedUid(String? requestedUid) {
    final String ownerUid = authUid;
    final String requested = requestedUid?.trim() ?? '';
    if (ownerUid.isEmpty) {
      if (requested.isNotEmpty) {
        throw StateError(
          'A signed-in account is required to read notifications.',
        );
      }
      return '';
    }
    if (requested.isNotEmpty && requested != ownerUid) {
      throw StateError('Notification state belongs to the signed-in account.');
    }
    final String uid = ownerUid;
    if (uid.contains('/')) {
      throw ArgumentError.value(uid, 'authUid', 'must be a single document ID');
    }
    return uid;
  }
}
