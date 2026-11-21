import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';

const int kFirestoreWhereInMaxValues = 30;
const int kFirestoreDisjunctionMax = 30;

Stream<QuerySnapshot<Map<String, dynamic>>> snapshotsWithIndexFallback(
  Query<Map<String, dynamic>> preferred,
  Query<Map<String, dynamic>> fallback,
) => streamWithFallback<QuerySnapshot<Map<String, dynamic>>>(
  preferred.snapshots,
  fallback.snapshots,
  (Object error) =>
      error is FirebaseException && error.code == 'failed-precondition',
);

Stream<T> streamWithFallback<T>(
  Stream<T> Function() preferred,
  Stream<T> Function() fallback,
  bool Function(Object error) shouldFallBack,
) => Stream<T>.multi((MultiStreamController<T> listener) {
  StreamSubscription<T>? current;
  void listenTo(Stream<T> stream, {required bool canFallBack}) {
    late final StreamSubscription<T> subscription;
    subscription = stream.listen(
      listener.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!identical(current, subscription)) return;
        if (canFallBack && shouldFallBack(error)) {
          unawaited(subscription.cancel());
          listenTo(fallback(), canFallBack: false);
          return;
        }
        listener.addError(error, stackTrace);
      },
      onDone: () {
        if (identical(current, subscription)) listener.close();
      },
    );
    current = subscription;
  }

  listenTo(preferred(), canFallBack: true);
  listener.onCancel = () {
    final StreamSubscription<T>? active = current;
    current = null;
    return active?.cancel();
  };
});

List<List<T>> chunkFirestoreWhereIn<T>(
  Iterable<T> values, {
  int chunkSize = kFirestoreWhereInMaxValues,
}) {
  if (chunkSize <= 0) {
    throw ArgumentError.value(chunkSize, 'chunkSize', 'must be positive');
  }
  final List<T> all = values.toList(growable: false);
  final List<List<T>> chunks = <List<T>>[];
  for (int start = 0; start < all.length; start += chunkSize) {
    final int end = start + chunkSize < all.length
        ? start + chunkSize
        : all.length;
    chunks.add(List<T>.unmodifiable(all.sublist(start, end)));
  }
  return List<List<T>>.unmodifiable(chunks);
}

List<Query<Map<String, dynamic>>> whereInQueryChunks(
  Query<Map<String, dynamic>> query,
  String field,
  Iterable<Object?> values,
) {
  return chunkFirestoreWhereIn(values)
      .map((List<Object?> chunk) => query.where(field, whereIn: chunk))
      .toList(growable: false);
}

Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
getDocumentsFromQueryChunks(
  Iterable<Query<Map<String, dynamic>>> queries, {
  Duration? timeout,
}) async {
  final List<Query<Map<String, dynamic>>> queryList = queries.toList(
    growable: false,
  );
  if (queryList.isEmpty) {
    return <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  }
  final Future<List<QuerySnapshot<Map<String, dynamic>>>> request = Future.wait(
    queryList.map((Query<Map<String, dynamic>> query) => query.get()),
  );
  final List<QuerySnapshot<Map<String, dynamic>>> snapshots = timeout == null
      ? await request
      : await request.timeout(timeout);
  final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId =
      <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
  for (final QuerySnapshot<Map<String, dynamic>> snapshot in snapshots) {
    for (final QueryDocumentSnapshot<Map<String, dynamic>> document
        in snapshot.docs) {
      byId[document.id] = document;
    }
  }
  return byId.values.toList(growable: false);
}

Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
combineFirestoreQuerySnapshots(Iterable<Query<Map<String, dynamic>>> queries) {
  return combineQuerySnapshotStreams(
    queries.map((Query<Map<String, dynamic>> query) => query.snapshots()),
  );
}

Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
combineQuerySnapshotStreams(
  Iterable<Stream<QuerySnapshot<Map<String, dynamic>>>> streams,
) {
  final List<Stream<QuerySnapshot<Map<String, dynamic>>>> queryList = streams
      .toList(growable: false);
  if (queryList.isEmpty) {
    return Stream<List<QueryDocumentSnapshot<Map<String, dynamic>>>>.value(
      const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
    );
  }
  if (queryList.length == 1) {
    return queryList.single.map(
      (QuerySnapshot<Map<String, dynamic>> snapshot) => snapshot.docs,
    );
  }

  late final StreamController<List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  controller;
  final Map<int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>
  docsByQuery = <int, List<QueryDocumentSnapshot<Map<String, dynamic>>>>{};
  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
  subscriptions = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

  void emit() {
    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents
        in docsByQuery.values) {
      for (final QueryDocumentSnapshot<Map<String, dynamic>> document
          in documents) {
        byId[document.id] = document;
      }
    }
    if (!controller.isClosed) {
      controller.add(byId.values.toList(growable: false));
    }
  }

  Future<void> cancelSubscriptions() async {
    for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>>
        subscription
        in subscriptions) {
      await subscription.cancel();
    }
    subscriptions.clear();
  }

  controller =
      StreamController<
        List<QueryDocumentSnapshot<Map<String, dynamic>>>
      >.broadcast(
        onListen: () {
          if (subscriptions.isNotEmpty) return;
          for (int index = 0; index < queryList.length; index++) {
            final int queryIndex = index;
            subscriptions.add(
              queryList[index].listen(
                (QuerySnapshot<Map<String, dynamic>> snapshot) {
                  docsByQuery[queryIndex] = snapshot.docs;
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
