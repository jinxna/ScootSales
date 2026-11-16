import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';

class ScopedDashboardRepository {
  ScopedDashboardRepository({FirebaseFirestore? firestore})
    : _firestore = firestore;

  final FirebaseFirestore? _firestore;

  Future<ScopedDashboardReadResult> readDocuments({
    required String collection,
    required UserProfile currentUser,
    String salesmanField = 'salesmanCode',
    String? orderBy,
    required int limit,
    required Duration deadline,
    bool includeDocId = false,
    Duration historyWindow = const Duration(days: 180),
    DateTime? asOf,
  }) async {
    final ScopedDashboardReadPlan plan = buildScopedDashboardReadPlan(
      collection: collection,
      currentUser: currentUser,
      salesmanField: salesmanField,
      orderBy: orderBy,
      limit: limit,
      deadline: deadline,
      includeDocId: includeDocId,
      historyWindow: historyWindow,
      asOf: asOf,
    );
    if (plan.queries.isEmpty) {
      return ScopedDashboardReadResult(
        documents: const <Map<String, dynamic>>[],
        metadata: plan.metadataFor(documentCount: 0),
      );
    }

    final Query<Map<String, dynamic>> baseQuery =
        (_firestore ?? FirebaseFirestore.instance).collection(collection);
    final List<Query<Map<String, dynamic>>> scopes = plan.queries
        .map((ScopedDashboardQueryPlan queryPlan) {
          Query<Map<String, dynamic>> query = baseQuery;
          if (queryPlan.whereInField != null) {
            query = query.where(
              queryPlan.whereInField!,
              whereIn: queryPlan.whereInValues,
            );
          } else if (queryPlan.equalsField != null) {
            query = query.where(
              queryPlan.equalsField!,
              isEqualTo: queryPlan.equalsValue,
            );
          }
          return query;
        })
        .toList(growable: false);
    const GetOptions server = GetOptions(source: Source.server);
    final List<List<QuerySnapshot<Map<String, dynamic>>>>
    chunks = await Future.wait(
      scopes.map(
        (
          Query<Map<String, dynamic>> scope,
        ) => Future.wait(<Future<QuerySnapshot<Map<String, dynamic>>>>[
          scope
              .where(
                plan.timeField,
                isGreaterThanOrEqualTo: Timestamp.fromDate(plan.windowStart),
              )
              .where(
                plan.timeField,
                isLessThan: Timestamp.fromDate(plan.windowEnd),
              )
              .orderBy(plan.timeField, descending: true)
              .orderBy(FieldPath.documentId, descending: true)
              .limit(plan.limit)
              .get(server),
          scope.orderBy(FieldPath.documentId).limit(plan.limit + 1).get(server),
        ]),
      ),
    ).timeout(plan.deadline);
    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final List<QuerySnapshot<Map<String, dynamic>>> chunk in chunks) {
      for (final QueryDocumentSnapshot<Map<String, dynamic>> document
          in chunk.first.docs) {
        byId[document.id] = document;
      }
    }
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> snapshots =
        byId.values.toList()..sort((a, b) {
          final int time = (b.data()[plan.timeField] as Timestamp).compareTo(
            a.data()[plan.timeField] as Timestamp,
          );
          return time != 0 ? time : b.id.compareTo(a.id);
        });
    final List<Map<String, dynamic>> documents = snapshots
        .map(
          (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
              mapScopedDashboardDocument(
                documentId: document.id,
                data: document.data(),
                includeDocId: plan.includeDocId,
              ),
        )
        .toList(growable: false);
    return ScopedDashboardReadResult(
      documents: documents,
      metadata: plan.metadataFor(
        documentCount: documents.length,
        chunkDocumentCounts: chunks
            .map((chunk) => chunk.first.docs.length)
            .toList(growable: false),
        serverConfirmed: chunks.every(
          (chunk) => chunk.every(
            (snapshot) =>
                !snapshot.metadata.isFromCache &&
                !snapshot.metadata.hasPendingWrites,
          ),
        ),
        canonicalCoverageVerified: chunks.every((chunk) {
          final inventory = chunk.last.docs;
          if (inventory.length > plan.limit ||
              inventory.any((doc) => doc.data()[plan.timeField] is! Timestamp)) {
            return false;
          }
          final expected = inventory
              .where((doc) {
                final at = (doc.data()[plan.timeField] as Timestamp)
                    .toDate()
                    .toUtc();
                return !at.isBefore(plan.windowStart) &&
                    at.isBefore(plan.windowEnd);
              })
              .map((doc) => doc.id)
              .toSet();
          final received = chunk.first.docs.map((doc) => doc.id).toSet();
          return expected.length == received.length &&
              expected.containsAll(received);
        }),
      ),
    );
  }
}

Map<String, dynamic> mapScopedDashboardDocument({
  required String documentId,
  required Map<String, dynamic> data,
  required bool includeDocId,
}) {
  return includeDocId ? <String, dynamic>{'docId': documentId, ...data} : data;
}

ScopedDashboardReadPlan buildScopedDashboardReadPlan({
  required String collection,
  required UserProfile currentUser,
  String salesmanField = 'salesmanCode',
  String? orderBy,
  required int limit,
  required Duration deadline,
  bool includeDocId = false,
  Duration historyWindow = const Duration(days: 180),
  DateTime? asOf,
}) {
  const Map<String, String> timeFields = <String, String>{
    'orders': 'submittedAt',
    'visit_logs': 'arrivalTime',
    'route_plan_progress': 'updatedAt',
    'route_stop_progress': 'arrivedAt',
    'route_plans': 'weekStart',
    'conversation_outcomes': 'submittedAt',
    'ai_insights': 'updatedAt',
    'visit_briefs': 'generatedAt',
    'retailer_memory': 'updatedAt',
    'retailer_priority_rankings': 'generatedAt',
  };
  final String? timeField = orderBy ?? timeFields[collection];
  if (timeField == null || limit < 1 || historyWindow <= Duration.zero) {
    throw ArgumentError(
      'Scoped reads require a canonical time field, positive cap and history window.',
    );
  }
  final DateTime end = (asOf ?? DateTime.now()).toUtc();
  final List<ScopedDashboardQueryPlan> queries;
  if (currentUser.isSupervisor) {
    final List<String> codes = currentUser.assignedSalesmanCodes
        .map((String value) => value.trim())
        .where((String value) => value.isNotEmpty)
        .toSet()
        .toList(growable: false);
    queries = chunkFirestoreWhereIn(codes)
        .map(
          (List<String> chunk) => ScopedDashboardQueryPlan(
            whereInField: salesmanField,
            whereInValues: chunk,
          ),
        )
        .toList(growable: false);
  } else if (currentUser.isBranchManager) {
    final String branchId = currentUser.branchId.trim();
    queries = branchId.isEmpty
        ? const <ScopedDashboardQueryPlan>[]
        : <ScopedDashboardQueryPlan>[
            ScopedDashboardQueryPlan(
              equalsField: 'branchId',
              equalsValue: branchId,
            ),
          ];
  } else if (currentUser.isAdmin) {
    queries = <ScopedDashboardQueryPlan>[
      ScopedDashboardQueryPlan(orderBy: orderBy, descending: orderBy != null),
    ];
  } else {
    queries = const <ScopedDashboardQueryPlan>[];
  }

  return ScopedDashboardReadPlan(
    collection: collection,
    limit: limit,
    deadline: deadline,
    includeDocId: includeDocId,
    timeField: timeField,
    windowStart: end.subtract(historyWindow),
    windowEnd: end,
    queries: List<ScopedDashboardQueryPlan>.unmodifiable(
      queries.map(
        (query) => ScopedDashboardQueryPlan(
          whereInField: query.whereInField,
          whereInValues: query.whereInValues,
          equalsField: query.equalsField,
          equalsValue: query.equalsValue,
          orderBy: timeField,
          descending: true,
        ),
      ),
    ),
  );
}

class ScopedDashboardReadPlan {
  const ScopedDashboardReadPlan({
    required this.collection,
    required this.limit,
    required this.deadline,
    required this.includeDocId,
    required this.queries,
    required this.timeField,
    required this.windowStart,
    required this.windowEnd,
  });

  final String collection;
  final int limit;
  final Duration deadline;
  final bool includeDocId;
  final List<ScopedDashboardQueryPlan> queries;
  final String timeField;
  final DateTime windowStart;
  final DateTime windowEnd;

  ScopedDashboardReadMetadata metadataFor({
    required int documentCount,
    List<int>? chunkDocumentCounts,
    bool canonicalCoverageVerified = false,
    bool serverConfirmed = true,
  }) {
    return ScopedDashboardReadMetadata(
      scopedQueryCount: queries.length,
      documentCount: documentCount,
      limit: limit,
      chunkDocumentCounts: List<int>.unmodifiable(
        chunkDocumentCounts ??
            (queries.length == 1 ? <int>[documentCount] : const <int>[]),
      ),
      canonicalCoverageVerified: canonicalCoverageVerified,
      serverConfirmed: serverConfirmed,
      windowStart: windowStart,
      windowEnd: windowEnd,
    );
  }
}

class ScopedDashboardQueryPlan {
  const ScopedDashboardQueryPlan({
    this.whereInField,
    this.whereInValues = const <String>[],
    this.equalsField,
    this.equalsValue,
    this.orderBy,
    this.descending = false,
  });

  final String? whereInField;
  final List<String> whereInValues;
  final String? equalsField;
  final String? equalsValue;
  final String? orderBy;
  final bool descending;

  bool get isUnscoped => whereInField == null && equalsField == null;
}

class ScopedDashboardReadResult {
  const ScopedDashboardReadResult({
    required this.documents,
    required this.metadata,
  });

  final List<Map<String, dynamic>> documents;
  final ScopedDashboardReadMetadata metadata;
}

class ScopedDashboardReadMetadata {
  const ScopedDashboardReadMetadata({
    required this.scopedQueryCount,
    required this.documentCount,
    required this.limit,
    required this.chunkDocumentCounts,
    required this.canonicalCoverageVerified,
    required this.serverConfirmed,
    required this.windowStart,
    required this.windowEnd,
  });

  final int scopedQueryCount;
  final int documentCount;
  final int limit;
  final List<int> chunkDocumentCounts;
  final bool canonicalCoverageVerified;
  final bool serverConfirmed;
  final DateTime windowStart;
  final DateTime windowEnd;

  bool get mayBeTruncated =>
      chunkDocumentCounts.length != scopedQueryCount ||
      chunkDocumentCounts.any((int count) => count >= limit);

  bool get isComplete =>
      scopedQueryCount > 0 &&
      serverConfirmed &&
      canonicalCoverageVerified &&
      !mayBeTruncated;
}
