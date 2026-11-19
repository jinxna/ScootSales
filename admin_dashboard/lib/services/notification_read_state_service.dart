import 'dart:async';

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

  Stream<NotificationReadState?> _savedReadState() {
    final String uid = _validatedUid(null);
    if (uid.isEmpty) return Stream<NotificationReadState?>.value(null);
    return _firestore
        .collection(collectionName)
        .doc(uid)
        .snapshots()
        .where(
          (DocumentSnapshot<Map<String, dynamic>> snapshot) =>
              !snapshot.metadata.hasPendingWrites,
        )
        .map(
          (DocumentSnapshot<Map<String, dynamic>> snapshot) => snapshot.exists
              ? NotificationReadState.fromMap(snapshot.data())
              : null,
        );
  }

  static const List<String> storedFeedCollections = <String>[
    'dashboard_notifications',
    'notification_logs',
  ];

  static const int newestReadPerFeed = 20;

  static int get unreadBadgeCap =>
      newestReadPerFeed * storedFeedCollections.length;

  static String unreadBadgeLabel(int count) =>
      count >= unreadBadgeCap ? 'or more unread' : 'unread';

  static String unreadBadgeText(int count) =>
      count >= unreadBadgeCap ? '$unreadBadgeCap+' : '$count';

  Stream<int> watchUnreadCount({int newestPerFeed = newestReadPerFeed}) =>
      unreadCountOf(
        readState: _savedReadState(),
        feeds: <Stream<List<Map<String, dynamic>>>>[
          for (final String name in storedFeedCollections)
            _firestore
                .collection(name)
                .orderBy('createdAt', descending: true)
                .limit(newestPerFeed)
                .snapshots()
                .map(
                  (QuerySnapshot<Map<String, dynamic>> snapshot) => snapshot
                      .docs
                      .map(
                        (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                            doc.data(),
                      )
                      .toList(growable: false),
                ),
        ],
      );

  static Stream<int> unreadCountOf({
    required Stream<NotificationReadState?> readState,
    required List<Stream<List<Map<String, dynamic>>>> feeds,
  }) {
    final StreamController<int> controller = StreamController<int>();
    final List<StreamSubscription<Object?>> subscriptions =
        <StreamSubscription<Object?>>[];
    final List<List<Map<String, dynamic>>?> rows =
        List<List<Map<String, dynamic>>?>.filled(feeds.length, null);
    bool stateSeen = false;
    NotificationReadState? state;

    void emit() {
      if (!stateSeen || rows.contains(null) || controller.isClosed) return;
      controller.add(
        unreadNotificationCount(
          rows.expand((List<Map<String, dynamic>>? feed) => feed!),
          state,
        ),
      );
    }

    controller.onListen = () {
      subscriptions.add(
        readState.listen((NotificationReadState? value) {
          stateSeen = true;
          state = value;
          emit();
        }, onError: controller.addError),
      );
      for (int index = 0; index < feeds.length; index++) {
        subscriptions.add(
          feeds[index].listen((List<Map<String, dynamic>> value) {
            rows[index] = value;
            emit();
          }, onError: controller.addError),
        );
      }
    };
    controller.onCancel = () async {
      for (final StreamSubscription<Object?> subscription in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
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
