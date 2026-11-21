import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/follow_up_promise.dart';
import '../models/offline_operation.dart';
import 'project_local_store.dart';

const String outcomeQueueStoreName = 'outcomes';
const String outcomeNeedsAttentionStatus = 'needs_attention';

class ShopFollowUp {
  const ShopFollowUp({required this.promise, required this.laterOutcomeAt});

  final FollowUpPromise promise;
  final DateTime? laterOutcomeAt;
}

class FollowUpService {
  FollowUpService({FirebaseFirestore? firestore, ProjectLocalStore? store})
    : _db = firestore ?? FirebaseFirestore.instance,
      _store =
          store ??
          ProjectLocalStore(
            projectId:
                (firestore ?? FirebaseFirestore.instance).app.options.projectId,
          );

  static const String storeName = 'follow_ups';
  static const Duration _readTimeout = Duration(seconds: 10);
  static const Duration _reuseFor = Duration(minutes: 2);
  static const int _readLimit = 500;

  static final ValueNotifier<int> changes = ValueNotifier<int>(0);
  static final Map<String, (DateTime, Future<List<Map<String, dynamic>>>)>
  _reads = <String, (DateTime, Future<List<Map<String, dynamic>>>)>{};

  final FirebaseFirestore _db;
  final ProjectLocalStore _store;

  static void noteChanged() {
    _reads.clear();
    changes.value += 1;
  }

  Future<List<FollowUpPromise>> openPromises(
    String uid, {
    bool online = true,
  }) async {
    final String owner = uid.trim();
    if (owner.isEmpty) return const <FollowUpPromise>[];
    return (await _open(owner, online: online)).promises;
  }

  Future<({List<FollowUpPromise> promises, bool reachedServer})> _open(
    String owner, {
    required bool online,
  }) async {
    List<Map<String, dynamic>> rows;
    bool reachedServer = online;
    try {
      rows = online ? await _current(owner) : await _saved(owner);
    } on FirebaseException {
      reachedServer = false;
      rows = await _saved(owner);
    } on TimeoutException {
      reachedServer = false;
      rows = await _saved(owner);
    }
    return (
      promises: openFollowUpPromises(<Map<String, dynamic>>[
        ...rows,
        ...await _held(owner),
      ]),
      reachedServer: reachedServer,
    );
  }

  Future<ShopFollowUp?> forShop({
    required String uid,
    required String retailerId,
  }) async {
    final String shop = retailerId.trim();
    final String owner = uid.trim();
    if (shop.isEmpty || owner.isEmpty) return null;
    final ({List<FollowUpPromise> promises, bool reachedServer}) open =
        await _open(owner, online: true);
    FollowUpPromise? earliest;
    for (final FollowUpPromise one in open.promises) {
      if (one.retailerId == shop) {
        earliest = one;
        break;
      }
    }
    if (earliest == null) return null;
    return ShopFollowUp(
      promise: earliest,
      laterOutcomeAt: await _laterOutcomeAt(
        owner,
        earliest,
        askServer: open.reachedServer,
      ),
    );
  }

  Future<void> remember(String uid, Map<String, dynamic> outcome) async {
    final String owner = uid.trim();
    final FollowUpPromise? promise = FollowUpPromise.fromOutcome(outcome);
    if (owner.isEmpty || promise == null) return;
    await _save(owner, <Map<String, dynamic>>[
      for (final Map<String, dynamic> row in await _saved(owner))
        if (row['outcomeId'] != promise.outcomeId) row,
      promise.toMap(),
    ]);
    noteChanged();
  }

  Future<List<Map<String, dynamic>>> _current(String uid) {
    final String key = '${_store.projectId}|$uid';
    final (DateTime, Future<List<Map<String, dynamic>>>)? known = _reads[key];
    final DateTime now = DateTime.now();
    if (known != null && now.difference(known.$1) < _reuseFor) {
      return known.$2;
    }
    final Future<List<Map<String, dynamic>>> read = _readAndSave(uid);
    _reads[key] = (now, read);
    unawaited(
      read.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_reads[key]?.$2, read)) _reads.remove(key);
        },
      ),
    );
    return read;
  }

  Future<List<Map<String, dynamic>>> _readAndSave(String uid) async {
    final Query<Map<String, dynamic>> own = _db
        .collection('conversation_outcomes')
        .where('salesmanUid', isEqualTo: uid);
    final QuerySnapshot<Map<String, dynamic>> snapshot = await own
        .where('followUpStatus', isEqualTo: FollowUpStatus.open.name)
        .orderBy('followUpDate')
        .limit(_readLimit)
        .get()
        .timeout(_readTimeout);
    if (snapshot.metadata.isFromCache) {
      return <Map<String, dynamic>>[
        ...await Future.wait(<Future<Map<String, dynamic>>>[
          for (final Map<String, dynamic> row in await _saved(uid))
            _cachedState(row),
        ]),
        ..._promiseRows(snapshot),
      ];
    }
    final List<Map<String, dynamic>> read = _promiseRows(snapshot);
    final List<Map<String, dynamic>> open = <Map<String, dynamic>>[
      for (final Map<String, dynamic> row in read)
        if (row['followUpStatus'] == FollowUpStatus.open.name) row,
    ];
    await _save(uid, open);
    return open;
  }

  Future<Map<String, dynamic>> _cachedState(Map<String, dynamic> saved) async {
    final String outcomeId = '${saved['outcomeId'] ?? ''}'.trim();
    if (outcomeId.isEmpty) return saved;
    final DocumentSnapshot<Map<String, dynamic>> doc;
    try {
      doc = await _db
          .collection('conversation_outcomes')
          .doc(outcomeId)
          .get(const GetOptions(source: Source.cache))
          .timeout(_readTimeout);
    } on FirebaseException catch (error) {
      if (error.code == 'unavailable') return saved;
      rethrow;
    }
    final Map<String, dynamic>? data = doc.data();
    if (data == null) return saved;
    return FollowUpPromise.fromOutcome(<String, dynamic>{
          ...data,
          'outcomeId': doc.id,
        })?.toMap() ??
        saved;
  }

  static List<Map<String, dynamic>> _promiseRows(
    QuerySnapshot<Map<String, dynamic>> snapshot,
  ) => <Map<String, dynamic>>[
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in snapshot.docs)
      if (FollowUpPromise.fromOutcome(<String, dynamic>{
            ...doc.data(),
            'outcomeId': doc.id,
          })
          case final FollowUpPromise promise)
        promise.toMap(),
  ];

  Future<void> _save(String uid, List<Map<String, dynamic>> rows) =>
      _store.write(uid, storeName, jsonEncode(rows));

  Future<List<Map<String, dynamic>>> _saved(String uid) async {
    final String? encoded = await _store.read(uid, storeName);
    if (encoded == null || encoded.isEmpty) {
      return const <Map<String, dynamic>>[];
    }
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! List) return const <Map<String, dynamic>>[];
    return <Map<String, dynamic>>[
      for (final Object? row in decoded)
        if (row is Map) Map<String, dynamic>.from(row),
    ];
  }

  Future<List<OfflineOperation>> _heldRows(String uid) async {
    final String? encoded = await _store.read(uid, outcomeQueueStoreName);
    if (encoded == null || encoded.isEmpty) return const <OfflineOperation>[];
    final Object? decoded = jsonDecode(encoded);
    if (decoded is! List) return const <OfflineOperation>[];
    return <OfflineOperation>[
      for (final Object? row in decoded)
        if (row is Map)
          OfflineOperation.fromJson(Map<String, dynamic>.from(row)),
    ].where((OfflineOperation row) {
      return row.payload['salesmanUid'] == uid &&
          row.targetStatus != outcomeNeedsAttentionStatus;
    }).toList();
  }

  Future<List<Map<String, dynamic>>> _held(String uid) async =>
      <Map<String, dynamic>>[
        for (final OfflineOperation row in await _heldRows(uid))
          if (row.followUp case final PendingFollowUp followUp)
            <String, dynamic>{
              ...row.payload,
              'outcomeId': row.documentId,
              'followUpDate': followUp.date,
              'followUpStatus': followUp.status,
            },
      ];

  Future<DateTime?> _laterOutcomeAt(
    String uid,
    FollowUpPromise promise, {
    required bool askServer,
  }) async {
    final DateTime? recordedAt = promise.recordedAt;
    DateTime? latest;
    void consider(String outcomeId, DateTime? at) {
      if (outcomeId == promise.outcomeId || at == null) return;
      if (recordedAt != null && !at.isAfter(recordedAt)) return;
      if (latest == null || at.isAfter(latest!)) latest = at;
    }

    for (final OfflineOperation row in await _heldRows(uid)) {
      if (row.payload['retailerId'] == promise.retailerId &&
          row.payload.containsKey('reasonCode')) {
        consider(row.documentId, row.createdAt);
      }
    }
    if (!askServer) return latest;
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _db
          .collection('conversation_outcomes')
          .where('salesmanUid', isEqualTo: uid)
          .where('retailerId', isEqualTo: promise.retailerId)
          .orderBy('submittedAt', descending: true)
          .limit(1)
          .get()
          .timeout(_readTimeout);
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snapshot.docs) {
        final Object? at =
            doc.data()['clientCreatedAt'] ?? doc.data()['submittedAt'];
        consider(doc.id, at is Timestamp ? at.toDate() : null);
      }
    } on FirebaseException {
      return latest;
    } on TimeoutException {
      return latest;
    }
    return latest;
  }
}
