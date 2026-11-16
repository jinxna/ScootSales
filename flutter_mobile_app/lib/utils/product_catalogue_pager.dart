import 'dart:async';
import 'dart:convert';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';

import '../services/project_local_store.dart';

const int _cataloguePageSize = 500;
const String _preparedCatalogueName = 'catalogue_prepared.v1';

final ValueNotifier<DateTime?> offlineCatalogueFrom = ValueNotifier<DateTime?>(
  null,
);

class OfflineCatalogueIncomplete implements Exception {
  const OfflineCatalogueIncomplete();

  @override
  String toString() =>
      'The offline catalogue on this device is incomplete. Connect to the internet to refresh it.';
}

class _PreparedCatalogue {
  const _PreparedCatalogue(this.count, this.digest, this.preparedAt);

  final int count;
  final String digest;
  final DateTime preparedAt;

  static String digestOf(List<String> sortedIds) {
    int hash = 0x811c9dc5;
    for (final int unit in utf8.encode(sortedIds.join('\n'))) {
      hash = ((hash ^ unit) * 0x01000193) & 0xffffffff;
    }
    return '${sortedIds.length}:${hash.toRadixString(16)}';
  }

  bool matches(List<String> sortedIds) =>
      sortedIds.length == count && digestOf(sortedIds) == digest;

  String encode() => jsonEncode(<String, Object>{
    'count': count,
    'digest': digest,
    'preparedAt': preparedAt.toUtc().toIso8601String(),
  });

  static _PreparedCatalogue? decode(String? raw) {
    if (raw == null) return null;
    try {
      final Object? value = jsonDecode(raw);
      if (value is! Map) return null;
      final Object? count = value['count'];
      final Object? digest = value['digest'];
      final DateTime? at = DateTime.tryParse('${value['preparedAt']}');
      if (count is! int || digest is! String || at == null) return null;
      return _PreparedCatalogue(count, digest, at.toLocal());
    } catch (_) {
      return null;
    }
  }
}

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
  final ProjectLocalStore store = ProjectLocalStore(
    projectId: firestore.app.options.projectId,
  );
  _PreparedCatalogue? prepared;
  String recordedDigest = '';
  Timer? preparedFallback;
  bool incompleteReported = false;
  StreamSubscription<User?>? authSubscription;
  Future<void> pendingCancellation = Future<void>.value();
  bool stopped = false;

  Future<void> cancel(StreamSubscription<dynamic>? subscription) async {
    try {
      await subscription?.cancel();
    } catch (_) {
    }
  }

  Future<void> stop() {
    if (stopped) return pendingCancellation;
    stopped = true;
    preparedFallback?.cancel();
    preparedFallback = null;
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

  void emitIfComplete({bool usePrepared = false}) {
    if (stopped ||
        pages.isEmpty ||
        pages.last.documents.length == _cataloguePageSize ||
        pages.any((_CataloguePage page) => !page.received)) {
      return;
    }
    final bool serverReady = pages.every(
      (_CataloguePage page) => page.serverReady,
    );
    final _PreparedCatalogue? offlinePack = prepared;
    if (!serverReady && !usePrepared) {
      preparedFallback ??= Timer(const Duration(seconds: 3), () {
        preparedFallback = null;
        emitIfComplete(usePrepared: true);
      });
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
    if (serverReady) {
      preparedFallback?.cancel();
      preparedFallback = null;
      offlineCatalogueFrom.value = null;
      incompleteReported = false;
      final _PreparedCatalogue current = _PreparedCatalogue(
        ids.length,
        _PreparedCatalogue.digestOf(ids),
        DateTime.now(),
      );
      if (current.digest != recordedDigest) {
        recordedDigest = current.digest;
        prepared = current;
        unawaited(
          store
              .write(uid, _preparedCatalogueName, current.encode())
              .catchError((Object _) {}),
        );
      }
    } else {
      if (offlinePack != null) {
        offlineCatalogueFrom.value = offlinePack.preparedAt;
      }
      if (offlinePack == null || !offlinePack.matches(ids)) {
        if (!incompleteReported) {
          incompleteReported = true;
          controller.addError(
            const OfflineCatalogueIncomplete(),
            StackTrace.current,
          );
        }
        return;
      }
      incompleteReported = false;
    }
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
            if ((page.serverReady || prepared != null) &&
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
      unawaited(
        store
            .read(uid, _preparedCatalogueName)
            .then((String? raw) {
              final _PreparedCatalogue? saved = _PreparedCatalogue.decode(raw);
              if (stopped || saved == null || prepared != null) return;
              prepared = saved;
              recordedDigest = saved.digest;
              emitIfComplete();
            })
            .catchError((Object _) {}),
      );
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
