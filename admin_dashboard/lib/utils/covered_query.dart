import 'dart:async';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'collection_rows.dart';
import 'order_data_utils.dart';

Stream<List<Map<String, dynamic>>> watchCoveredQuery(
  Query<Map<String, dynamic>> query, {
  Query<Map<String, dynamic>>? probe,
  int? limit,
  String? newestFirstField,
}) {
  late final StreamController<List<Map<String, dynamic>>> controller;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? querySubscription;
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? probeSubscription;
  QuerySnapshot<Map<String, dynamic>>? latest;
  QuerySnapshot<Map<String, dynamic>>? coverage;
  bool failed = false;
  bool windowFull(QuerySnapshot<Map<String, dynamic>> snapshot) =>
      limit != null && limit > 0 && snapshot.docs.length >= limit;
  void emit() {
    final snapshot = latest;
    if (snapshot == null || controller.isClosed) return;
    if (probe != null && coverage == null && !windowFull(snapshot)) return;
    controller.add(
      _coveredRows(
        snapshot,
        probeConfigured: probe != null,
        probe: coverage,
        limit: limit,
        failed: failed,
        newestFirstField: newestFirstField,
      ),
    );
  }

  void error(Object error, StackTrace stack) {
    failed = true;
    emit();
    if (!controller.isClosed) controller.addError(error, stack);
  }

  void startProbe() {
    final probeQuery = probe;
    if (probeQuery == null || probeSubscription != null) return;
    probeSubscription = probeQuery
        .snapshots(includeMetadataChanges: true)
        .listen((probeSnapshot) {
          coverage = probeSnapshot;
          emit();
        }, onError: error);
  }

  void syncProbe(QuerySnapshot<Map<String, dynamic>> snapshot) {
    if (probe == null) return;
    if (!windowFull(snapshot)) {
      startProbe();
    } else if (probeSubscription != null) {
      final stale = probeSubscription!;
      probeSubscription = null;
      coverage = null;
      unawaited(stale.cancel());
    }
  }

  controller = StreamController<List<Map<String, dynamic>>>(
    onListen: () {
      querySubscription = query.snapshots(includeMetadataChanges: true).listen((
        snapshot,
      ) {
        latest = snapshot;
        syncProbe(snapshot);
        emit();
      }, onError: error);
      startProbe();
    },
    onCancel: () async {
      await querySubscription?.cancel();
      await probeSubscription?.cancel();
    },
  );
  return controller.stream;
}

CollectionRows _coveredRows(
  QuerySnapshot<Map<String, dynamic>> snapshot, {
  required bool probeConfigured,
  QuerySnapshot<Map<String, dynamic>>? probe,
  int? limit,
  bool failed = false,
  String? newestFirstField,
}) {
  bool confirmed(QuerySnapshot<Map<String, dynamic>> s) =>
      !s.metadata.isFromCache && !s.metadata.hasPendingWrites;
  final ids = snapshot.docs.map((doc) => doc.id).toSet();
  final bool windowFull =
      limit != null && limit > 0 && snapshot.docs.length >= limit;
  final DateTime? coveredSince =
      failed || newestFirstField == null || !confirmed(snapshot)
      ? null
      : windowFull
      ? parseFlexibleDate(snapshot.docs.last.data()[newestFirstField])
      : coversAllRows;
  return CollectionRows(
    snapshot.docs.map(
      (doc) => <String, dynamic>{...doc.data(), 'docId': doc.id},
    ),
    isComplete:
        !failed &&
        confirmed(snapshot) &&
        (limit == null || limit <= 0 || snapshot.docs.length < limit) &&
        (!probeConfigured ||
            (probe != null &&
                confirmed(probe) &&
                probe.docs.length == ids.length &&
                probe.docs.every((doc) => ids.contains(doc.id)))),
    coveredSince: coveredSince,
  );
}

Future<CollectionRows> readCoveredQuery(
  Query<Map<String, dynamic>> query, {
  Query<Map<String, dynamic>>? probe,
  int? limit,
  GetOptions? options,
  String? newestFirstField,
}) async {
  final reads = await Future.wait([
    query.get(options ?? const GetOptions(source: Source.server)),
    if (probe != null)
      probe.get(options ?? const GetOptions(source: Source.server)),
  ]);
  return _coveredRows(
    reads.first,
    probeConfigured: probe != null,
    probe: probe == null ? null : reads.last,
    limit: limit,
    newestFirstField: newestFirstField,
  );
}
