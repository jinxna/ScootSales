import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/ai_insight.dart';
import '../models/conversation_outcome.dart';
import '../models/retailer_priority_ranking.dart';
import '../models/user_profile.dart';
import '../repositories/scoped_dashboard_repository.dart';
import '../utils/app_logger.dart';
import 'outcome_review_service.dart';
import 'visit_priority_service.dart';

class RoutePlannerSignals {
  const RoutePlannerSignals({
    this.rankings = const <RetailerPriorityRanking>[],
    this.insights = const <AiInsight>[],
    this.usualOrderWeekdayByRetailer = const <String, int>{},
    this.followUps = const <ConversationOutcome>[],
    this.failed = const <String>[],
    this.loaded = false,
  });

  static const String rankingSource = 'the weekly ranking';
  static const String insightSource = 'the open insights';
  static const String orderDaySource = 'the usual order days';
  static const String followUpSource = 'the follow-up dates';

  final List<RetailerPriorityRanking> rankings;
  final List<AiInsight> insights;
  final Map<String, int> usualOrderWeekdayByRetailer;
  final List<ConversationOutcome> followUps;
  final List<String> failed;
  final bool loaded;

  bool get rankingFailed => failed.contains(rankingSource);
}

class RoutePlannerSignalsService {
  RoutePlannerSignalsService({FirebaseFirestore? firestore})
    : _repository = ScopedDashboardRepository(firestore: firestore),
      _priorities = VisitPriorityService(firestore: firestore),
      _outcomes = OutcomeReviewService();

  final ScopedDashboardRepository _repository;
  final VisitPriorityService _priorities;
  final OutcomeReviewService _outcomes;

  Future<RoutePlannerSignals> load(
    UserProfile currentUser, {
    required bool withIntelligence,
    required DateTime weekStart,
  }) async {
    final List<String> failed = <String>[];

    Future<T> guard<T>(
      String source,
      T fallback,
      Future<T> Function() read,
    ) async {
      try {
        return await read();
      } catch (error, stackTrace) {
        AppLogger.error(
          'route_planner_signal_read_failed',
          error: error,
          stackTrace: stackTrace,
        );
        failed.add(source);
        return fallback;
      }
    }

    final Future<List<ConversationOutcome>> followUps = guard(
      RoutePlannerSignals.followUpSource,
      const <ConversationOutcome>[],
      () async {
        final List<ConversationOutcome>? rows = await _outcomes
            .loadOpenDatedFollowUps(currentUser);
        if (rows == null) {
          throw StateError('Open follow-ups could not be read in full');
        }
        return rows;
      },
    );
    if (!withIntelligence) {
      return RoutePlannerSignals(
        followUps: await followUps,
        failed: failed,
        loaded: true,
      );
    }
    final Future<List<RetailerPriorityRanking>> rankings = guard(
      RoutePlannerSignals.rankingSource,
      const <RetailerPriorityRanking>[],
      () => _priorities.loadPlannerWeekRankings(
        currentUser,
        weekStart: weekStart,
      ),
    );
    final Future<List<AiInsight>> insights = guard(
      RoutePlannerSignals.insightSource,
      const <AiInsight>[],
      () async {
        final ScopedDashboardReadResult result = await _repository
            .readDocuments(
              collection: 'ai_insights',
              currentUser: currentUser,
              orderBy: 'updatedAt',
              limit: kPriorityInsightReadLimit,
              deadline: kPriorityReadTimeout,
            );
        if (!result.metadata.isComplete) {
          throw StateError('Incomplete insight data');
        }
        return <AiInsight>[
          for (final Map<String, dynamic> row in result.documents)
            AiInsight.fromMap('${row['issueId'] ?? ''}', row),
        ];
      },
    );
    final Future<Map<String, int>> orderDays = guard(
      RoutePlannerSignals.orderDaySource,
      const <String, int>{},
      () async {
        final ScopedDashboardReadResult result = await _repository
            .readDocuments(
              collection: 'visit_briefs',
              currentUser: currentUser,
              limit: kPriorityBriefReadLimit,
              deadline: kPriorityReadTimeout,
            );
        if (!result.metadata.isComplete) {
          throw StateError('Incomplete visit brief data');
        }
        return usualOrderWeekdays(result.documents);
      },
    );
    return RoutePlannerSignals(
      rankings: await rankings,
      insights: await insights,
      usualOrderWeekdayByRetailer: await orderDays,
      followUps: await followUps,
      failed: failed,
      loaded: true,
    );
  }
}

Map<String, int> usualOrderWeekdays(Iterable<Map<String, dynamic>> briefs) {
  final Map<String, int> weekdayByRetailer = <String, int>{};
  final Map<String, DateTime> newestByRetailer = <String, DateTime>{};
  for (final Map<String, dynamic> brief in briefs) {
    final String retailerId = '${brief['retailerId'] ?? ''}'.trim();
    if (retailerId.isEmpty || brief['isDemo'] == true) continue;
    final Object? at = brief['generatedAt'] ?? brief['updatedAt'];
    final DateTime stamp = at is Timestamp
        ? at.toDate()
        : at is DateTime
        ? at
        : DateTime.fromMillisecondsSinceEpoch(0);
    final DateTime? known = newestByRetailer[retailerId];
    if (known != null && !stamp.isAfter(known)) continue;
    newestByRetailer[retailerId] = stamp;
    final Object? weekday = brief['usualOrderWeekday'];
    if (weekday is int && weekday >= 1 && weekday <= 6) {
      weekdayByRetailer[retailerId] = weekday;
    } else {
      weekdayByRetailer.remove(retailerId);
    }
  }
  return weekdayByRetailer;
}
