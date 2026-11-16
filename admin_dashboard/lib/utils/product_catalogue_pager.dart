import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

const int _cataloguePageSize = 500;

Stream<List<Map<String, dynamic>>> watchPagedProducts(
  FirebaseFirestore firestore,
) {
  final FirebaseAuth auth = FirebaseAuth.instanceFor(app: firestore.app);
  final String? uid = auth.currentUser?.uid;
  if (uid == null) {
    return Stream<List<Map<String, dynamic>>>.error(
      StateError('Sign in before loading the catalogue.'),
    );
  }

  late final StreamController<List<Map<String, dynamic>>> controller;
  final List<_CataloguePage> pages = <_CataloguePage>[];
  StreamSubscription<User?>? authSubscription;
  Future<void> pendingCancellation = Future<void>.value();
  bool stopped = false;

  Future<void> cancel(StreamSubscription<dynamic>? subscription) async {
    try {
      await subscription?.cancel();
    } catch (_) {}
  }

  Future<void> stop() {
    if (stopped) return pendingCancellation;
    stopped = true;
    final List<_CataloguePage> previous = List<_CataloguePage>.of(pages);
    pages.clear();
    for (final _CataloguePage page in previous) {
      page.active = false;
    }
    pendingCancellation = Future.wait<void>(<Future<void>>[
      pendingCancellation,
      cancel(authSubscription),
      for (final _CataloguePage page in previous) cancel(page.subscription),
    ]).then<void>((_) {});
    return pendingCancellation;
  }

  void fail(Object error, StackTrace stack) {
    if (stopped) return;
    controller.addError(error, stack);
    unawaited(stop().then((_) => controller.close()));
  }

  bool current(_CataloguePage page) =>
      !stopped && page.active && auth.currentUser?.uid == uid;

  void emitIfComplete() {
    if (stopped ||
        pages.isEmpty ||
        pages.last.documents.length == _cataloguePageSize ||
        pages.any((_CataloguePage page) => !page.serverReady)) {
      return;
    }
    final Map<String, Map<String, dynamic>> byId =
        <String, Map<String, dynamic>>{};
    for (final _CataloguePage page in pages) {
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in page.documents) {
        byId[doc.id] = <String, dynamic>{...doc.data(), 'docId': doc.id};
      }
    }
    final List<String> ids = byId.keys.toList()..sort();
    controller.add(
      List<Map<String, dynamic>>.unmodifiable(
        ids.map((String id) => byId[id]!),
      ),
    );
  }

  void listenPage(String? cursor) {
    if (stopped || auth.currentUser?.uid != uid) return;
    final int index = pages.length;
    final _CataloguePage page = _CataloguePage();
    pages.add(page);
    Query<Map<String, dynamic>> query = firestore
        .collection('products')
        .orderBy(FieldPath.documentId);
    if (cursor != null) query = query.startAfter(<Object?>[cursor]);
    page.subscription = query
        .limit(_cataloguePageSize)
        .snapshots(includeMetadataChanges: true)
        .listen(
          (QuerySnapshot<Map<String, dynamic>> snapshot) {
            if (!current(page)) return;
            final String? boundary = snapshot.docs.isEmpty
                ? null
                : snapshot.docs.last.id;
            if (page.received && page.boundary != boundary) {
              final List<_CataloguePage> retired = pages.sublist(index + 1);
              pages.removeRange(index + 1, pages.length);
              for (final _CataloguePage tail in retired) {
                tail.active = false;
              }
              pendingCancellation = Future.wait<void>(<Future<void>>[
                pendingCancellation,
                for (final _CataloguePage tail in retired)
                  cancel(tail.subscription),
              ]).then<void>((_) {});
            }
            page.received = true;
            page.boundary = boundary;
            page.documents = snapshot.docs;
            page.serverReady =
                !snapshot.metadata.isFromCache &&
                !snapshot.metadata.hasPendingWrites;
            final int revision = ++page.tailRevision;
            if (page.serverReady &&
                page.documents.length == _cataloguePageSize &&
                pages.length == index + 1) {
              unawaited(
                pendingCancellation.then((_) {
                  if (current(page) &&
                      page.tailRevision == revision &&
                      pages.length == index + 1) {
                    listenPage(boundary);
                  }
                }),
              );
            }
            emitIfComplete();
          },
          onError: (Object error, StackTrace stack) {
            if (current(page)) fail(error, stack);
          },
          onDone: () {
            if (current(page)) {
              fail(StateError('Catalogue listener ended.'), StackTrace.current);
            }
          },
        );
  }

  controller = StreamController<List<Map<String, dynamic>>>(
    onListen: () {
      authSubscription = auth.authStateChanges().listen((User? user) {
        if (!stopped && user?.uid != uid) {
          unawaited(stop().then((_) => controller.close()));
        }
      }, onError: fail);
      listenPage(null);
    },
    onCancel: stop,
  );
  return controller.stream;
}

class _CataloguePage {
  bool active = true;
  bool received = false;
  bool serverReady = false;
  String? boundary;
  int tailRevision = 0;
  List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
      <QueryDocumentSnapshot<Map<String, dynamic>>>[];
  StreamSubscription<QuerySnapshot<Map<String, dynamic>>>? subscription;
}
