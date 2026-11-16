import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/conversation_outcome.dart';
import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';
import '../utils/order_data_utils.dart';

class OutcomeReviewService {
  OutcomeReviewService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<ConversationOutcome>> watchOutcomes(
    UserProfile currentUser, {
    int limit = 120,
  }) {
    final int safeLimit = limit.clamp(1, 120).toInt();
    final Query<Map<String, dynamic>> query = _firestore.collection(
      'conversation_outcomes',
    );
    final List<Query<Map<String, dynamic>>> scopedQueries = _roleScopedQueries(
      query,
      currentUser,
    );
    if (scopedQueries.isEmpty) {
      return Stream<List<ConversationOutcome>>.value(
        const <ConversationOutcome>[],
      );
    }
    final List<Query<Map<String, dynamic>>> boundedQueries = scopedQueries
        .map((Query<Map<String, dynamic>> scoped) {
          Query<Map<String, dynamic>> bounded = scoped;
          if (currentUser.isAdmin) {
            bounded = bounded.orderBy('submittedAt', descending: true);
          }
          return bounded.limit(safeLimit);
        })
        .toList(growable: false);

    return combineFirestoreQuerySnapshots(boundedQueries).map((
      List<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
    ) {
      final List<ConversationOutcome> outcomes = documents
          .where(
            (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                !isDemoRow(<String, dynamic>{
                  'docId': document.id,
                  ...document.data(),
                }),
          )
          .map(ConversationOutcome.fromFirestore)
          .where((ConversationOutcome outcome) => !outcome.isDemo)
          .toList(growable: false);
      outcomes.sort((ConversationOutcome left, ConversationOutcome right) {
        final DateTime leftTime =
            left.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final DateTime rightTime =
            right.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return rightTime.compareTo(leftTime);
      });
      return outcomes.length > safeLimit
          ? outcomes.take(safeLimit).toList(growable: false)
          : outcomes;
    });
  }

  Future<List<ConversationOutcome>?> loadOpenDatedFollowUps(
    UserProfile currentUser, {
    int limit = 300,
  }) async {
    final int safeLimit = limit.clamp(1, 500).toInt();
    final Query<Map<String, dynamic>> query = _firestore
        .collection('conversation_outcomes')
        .where('followUpStatus', isEqualTo: 'open')
        .orderBy('followUpDate');
    final List<Query<Map<String, dynamic>>> scopedQueries = _roleScopedQueries(
      query,
      currentUser,
    );
    if (scopedQueries.isEmpty) return const <ConversationOutcome>[];

    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
          await getDocumentsFromQueryChunks(
            scopedQueries.map(
              (Query<Map<String, dynamic>> scoped) =>
                  scoped.limit(safeLimit + 1),
            ),
          );
      if (documents.length > safeLimit) return null;
      final List<ConversationOutcome> followUps =
          documents
              .where(
                (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                    !isDemoRow(<String, dynamic>{
                      'docId': document.id,
                      ...document.data(),
                    }),
              )
              .map(ConversationOutcome.fromFirestore)
              .where(
                (ConversationOutcome outcome) =>
                    !outcome.isDemo && outcome.hasOpenDatedFollowUp,
              )
              .toList(growable: false)
            ..sort((ConversationOutcome left, ConversationOutcome right) {
              final int byDate = left.followUpDate.compareTo(
                right.followUpDate,
              );
              if (byDate != 0) return byDate;
              return left.followUpTime.compareTo(right.followUpTime);
            });
      return followUps;
    } catch (_) {
      return null;
    }
  }

  Future<Set<String>> loadDueFollowUpRetailerIds(
    UserProfile currentUser, {
    required String salesmanUid,
    String salesmanCode = '',
    int recentDays = 45,
    int limit = 120,
  }) async {
    final int safeLimit = limit.clamp(1, 120).toInt();
    final Query<Map<String, dynamic>> query = _firestore.collection(
      'conversation_outcomes',
    );
    final List<Query<Map<String, dynamic>>> scopedQueries = _roleScopedQueries(
      query,
      currentUser,
    );
    if (scopedQueries.isEmpty) return <String>{};
    final List<Query<Map<String, dynamic>>> boundedQueries = scopedQueries
        .map((Query<Map<String, dynamic>> scoped) {
          Query<Map<String, dynamic>> bounded = scoped;
          if (currentUser.isAdmin) {
            bounded = bounded.orderBy('submittedAt', descending: true);
          }
          return bounded.limit(safeLimit);
        })
        .toList(growable: false);

    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
          await getDocumentsFromQueryChunks(boundedQueries);
      return deriveDueFollowUpRetailerIds(
        documents
            .where(
              (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                  !isDemoRow(<String, dynamic>{
                    'docId': document.id,
                    ...document.data(),
                  }),
            )
            .map(ConversationOutcome.fromFirestore)
            .where((ConversationOutcome outcome) => !outcome.isDemo),
        salesmanUid: salesmanUid,
        salesmanCode: salesmanCode,
        cutoff: DateTime.now().subtract(Duration(days: recentDays)),
      );
    } catch (_) {
      return <String>{};
    }
  }

  Future<Map<String, dynamic>?> loadRetailerMemorySnapshot(
    String retailerId,
  ) async {
    final String safeId = retailerId.trim();
    if (safeId.isEmpty) return null;
    try {
      final DocumentSnapshot<Map<String, dynamic>> doc = await _firestore
          .collection('retailer_memory')
          .doc(safeId)
          .get();
      return doc.exists ? doc.data() : null;
    } catch (_) {
      return null;
    }
  }

  Future<List<ConversationOutcome>?> loadRetailerOutcomes(
    UserProfile currentUser, {
    required String retailerId,
    int limit = 60,
  }) {
    return _loadScopedOutcomes(
      currentUser,
      field: 'retailerId',
      value: retailerId,
      limit: limit,
    );
  }

  Future<List<ConversationOutcome>?> loadOutcomesForIssueKey(
    UserProfile currentUser, {
    required String issueKey,
    int limit = 60,
  }) {
    return _loadScopedOutcomes(
      currentUser,
      field: 'issueKey',
      value: issueKey,
      limit: limit,
    );
  }

  Future<List<ConversationOutcome>?> _loadScopedOutcomes(
    UserProfile currentUser, {
    required String field,
    required String value,
    required int limit,
  }) async {
    final String safeValue = value.trim();
    if (safeValue.isEmpty) return const <ConversationOutcome>[];
    final int safeLimit = limit.clamp(1, 120).toInt();
    final Query<Map<String, dynamic>> query = _firestore
        .collection('conversation_outcomes')
        .where(field, isEqualTo: safeValue);
    final List<Query<Map<String, dynamic>>> scopedQueries = _roleScopedQueries(
      query,
      currentUser,
    );
    if (scopedQueries.isEmpty) {
      return const <ConversationOutcome>[];
    }
    final List<Query<Map<String, dynamic>>> boundedQueries = scopedQueries
        .map((Query<Map<String, dynamic>> scoped) => scoped.limit(safeLimit))
        .toList(growable: false);
    try {
      final List<QueryDocumentSnapshot<Map<String, dynamic>>> documents =
          await getDocumentsFromQueryChunks(boundedQueries);
      final List<ConversationOutcome> outcomes = documents
          .where(
            (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                !isDemoRow(<String, dynamic>{
                  'docId': document.id,
                  ...document.data(),
                }),
          )
          .map(ConversationOutcome.fromFirestore)
          .where((ConversationOutcome outcome) => !outcome.isDemo)
          .toList();
      outcomes.sort((ConversationOutcome left, ConversationOutcome right) {
        final DateTime leftTime =
            left.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        final DateTime rightTime =
            right.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0);
        return rightTime.compareTo(leftTime);
      });
      return outcomes;
    } catch (_) {
      return null;
    }
  }

  List<Query<Map<String, dynamic>>> _roleScopedQueries(
    Query<Map<String, dynamic>> query,
    UserProfile currentUser,
  ) {
    if (currentUser.isSupervisor) {
      final List<String> codes = currentUser.assignedSalesmanCodes
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
      return whereInQueryChunks(query, 'salesmanCode', codes);
    }
    if (currentUser.isBranchManager) {
      final String branchId = currentUser.branchId.trim();
      return branchId.isEmpty
          ? const <Query<Map<String, dynamic>>>[]
          : <Query<Map<String, dynamic>>>[
              query.where('branchId', isEqualTo: branchId),
            ];
    }
    if (currentUser.isAdmin) {
      return <Query<Map<String, dynamic>>>[query];
    }
    return const <Query<Map<String, dynamic>>>[];
  }

  static Set<String> deriveDueFollowUpRetailerIds(
    Iterable<ConversationOutcome> outcomes, {
    required String salesmanUid,
    String salesmanCode = '',
    required DateTime cutoff,
  }) {
    final String uid = salesmanUid.trim().toLowerCase();
    final String code = salesmanCode.trim().toLowerCase();
    final Map<String, ConversationOutcome> latestByRetailer =
        <String, ConversationOutcome>{};
    for (final ConversationOutcome outcome in outcomes) {
      final bool matches =
          (uid.isNotEmpty && outcome.salesmanUid.trim().toLowerCase() == uid) ||
          (code.isNotEmpty &&
              outcome.salesmanCode.trim().toLowerCase() == code);
      if (!matches) continue;
      final DateTime? at = outcome.submittedAt;
      if (at == null || at.isBefore(cutoff)) continue;
      final String retailerId = outcome.retailerId.trim();
      if (retailerId.isEmpty) continue;
      final ConversationOutcome? existing = latestByRetailer[retailerId];
      if (existing == null ||
          at.isAfter(
            existing.submittedAt ?? DateTime.fromMillisecondsSinceEpoch(0),
          )) {
        latestByRetailer[retailerId] = outcome;
      }
    }
    return latestByRetailer.entries
        .where(
          (MapEntry<String, ConversationOutcome> entry) =>
              entry.value.needsFollowUp,
        )
        .map((MapEntry<String, ConversationOutcome> entry) => entry.key)
        .toSet();
  }
}
