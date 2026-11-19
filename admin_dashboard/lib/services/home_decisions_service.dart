import '../models/ai_insight.dart';
import '../models/conversation_outcome.dart';
import '../models/user_profile.dart';
import '../repositories/cms_repository.dart';
import '../security/team_scope.dart';
import '../utils/collection_rows.dart';
import '../utils/count_label.dart';
import '../utils/follow_up_dates.dart';
import '../utils/order_data_utils.dart';
import '../utils/retailer_readiness.dart';
import '../widgets/weekly_bar_chart.dart';
import 'ai_insight_service.dart';
import 'outcome_review_service.dart';
import 'shop_panel_service.dart';

enum HomeDecisionKind {
  routesNotPlanned,
  followUpsDue,
  followUpOverdue,
  pinsNotVerified,
  stoppedOrdering,
  stopsWithoutReason,
}

class HomeDecision {
  const HomeDecision({
    required this.kind,
    required this.text,
    required this.count,
    required this.pageKey,
    this.retailerId = '',
    this.retailerName = '',
    this.productId = '',
  });

  final HomeDecisionKind kind;
  final String text;
  final int count;
  final String pageKey;
  final String retailerId;
  final String retailerName;
  final String productId;
}

class HomeDecisionResult {
  const HomeDecisionResult({
    required this.decisions,
    required this.failed,
    this.incomplete = const <String>[],
  });

  final List<HomeDecision> decisions;
  final List<String> failed;
  final List<String> incomplete;
}

class HomeWeek {
  const HomeWeek({
    required this.mondayKey,
    required this.sundayKey,
    required this.planningMondayKey,
  });

  final String mondayKey;
  final String sundayKey;
  final String planningMondayKey;

  DateTime get mondayStart => DateTime.parse(
    '${mondayKey}T00:00:00Z',
  ).subtract(const Duration(hours: 8));

  DateTime get nextMondayStart => mondayStart.add(const Duration(days: 7));

  String get previousDayKey => _dateKey(
    DateTime.parse('${mondayKey}T00:00:00Z').subtract(const Duration(days: 1)),
  );

  static String _dateKey(DateTime d) =>
      '${d.year.toString().padLeft(4, '0')}-'
      '${d.month.toString().padLeft(2, '0')}-'
      '${d.day.toString().padLeft(2, '0')}';

  static HomeWeek of(DateTime instant) {
    final DateTime local = instant.toUtc().add(const Duration(hours: 8));
    DateTime day = DateTime.utc(local.year, local.month, local.day);
    if (day.weekday == DateTime.sunday) {
      day = day.add(const Duration(days: 1));
    }
    final DateTime monday = day.subtract(Duration(days: day.weekday - 1));
    final DateTime sunday = monday.add(const Duration(days: 6));
    return HomeWeek(
      mondayKey: _dateKey(monday),
      sundayKey: _dateKey(sunday),
      planningMondayKey: _planningMondayKey(instant),
    );
  }

  static String _planningMondayKey(DateTime instant) {
    final DateTime next = instant.toLocal().add(const Duration(days: 7));
    final DateTime day = DateTime.utc(next.year, next.month, next.day);
    return _dateKey(day.subtract(Duration(days: day.weekday - 1)));
  }
}

String homeDateKeyLabel(String key) {
  final DateTime? parsed = DateTime.tryParse(key);
  return parsed == null ? key : weeklyChartDayLabel(parsed);
}

const int _peopleLimit = 1000;
const int _planLimit = 200;
const int _shopLimit = 2000;
const int _stopLimit = 500;
const int _outcomeLimit = 120;
const int _orderCeiling = 2000;

bool _rowsCover(
  List<Map<String, dynamic>> rows,
  int limit,
  DateTime? Function(Map<String, dynamic> row) dateOf,
  String cutoffKey,
) {
  if (rows.length < limit || collectionRowsComplete(rows)) return true;
  DateTime? oldest;
  for (final Map<String, dynamic> row in rows) {
    final DateTime? at = dateOf(row);
    if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
  }
  return oldest != null && kualaLumpurDateKey(oldest).compareTo(cutoffKey) < 0;
}

class HomeDecisionsService {
  HomeDecisionsService({
    CmsRepository? repository,
    AiInsightService? insights,
    OutcomeReviewService? outcomes,
    DateTime Function()? now,
  }) : _repository = repository ?? CmsRepository(),
       _insights = insights ?? AiInsightService(),
       _outcomes = outcomes ?? OutcomeReviewService(),
       _now = now ?? DateTime.now;

  final CmsRepository _repository;
  final AiInsightService _insights;
  final OutcomeReviewService _outcomes;
  final DateTime Function() _now;

  Future<HomeDecisionResult> load(UserProfile user) async {
    final DateTime instant = _now();
    final HomeWeek week = HomeWeek.of(instant);
    final String today = kualaLumpurDateKey(instant);
    final List<String> failed = <String>[];
    final List<String> incomplete = <String>[];
    final String cutoff = week.previousDayKey;

    Future<T?> read<T>(
      String source,
      Future<T?> Function() fetch, {
      bool Function(T value)? covers,
    }) async {
      try {
        final T? value = await fetch();
        if (value == null) {
          failed.add(source);
          return null;
        }
        if (covers != null && !covers(value)) {
          incomplete.add(source);
          return null;
        }
        return value;
      } catch (_) {
        failed.add(source);
        return null;
      }
    }

    final List<Object?> results = await Future.wait(<Future<Object?>>[
      read<List<Map<String, dynamic>>>(
        'people',
        () => _repository.getCollectionOnce('users', limit: _peopleLimit),
        covers: (List<Map<String, dynamic>> rows) =>
            rows.length < _peopleLimit || collectionRowsComplete(rows),
      ),
      read<List<Map<String, dynamic>>>(
        'route plans',
        () => _repository.getCollectionOnce(
          'route_plans',
          orderBy: 'weekStart',
          descending: true,
          limit: _planLimit,
        ),
        covers: (List<Map<String, dynamic>> rows) => _rowsCover(
          rows,
          _planLimit,
          (Map<String, dynamic> row) => parseFlexibleDate(row['weekStart']),
          week.mondayKey,
        ),
      ),
      read<List<ConversationOutcome>>(
        'follow-ups',
        () => _outcomes.loadOpenDatedFollowUps(user),
      ),
      read<List<Map<String, dynamic>>>(
        'shops',
        () => _repository.getRetailerDirectory(limit: _shopLimit),
        covers: (List<Map<String, dynamic>> rows) =>
            rows.length < _shopLimit || collectionRowsComplete(rows),
      ),
      read<List<AiInsight>>(
        'Scout insights',
        () => _insights.watchInsights(user).first,
      ),
      read<List<Map<String, dynamic>>>(
        'completed stops',
        () => _repository
            .watchCollectionRaw(
              'route_stop_progress',
              orderBy: 'arrivedAt',
              descending: true,
              limit: _stopLimit,
            )
            .first,
        covers: (List<Map<String, dynamic>> rows) => _rowsCover(
          rows,
          _stopLimit,
          (Map<String, dynamic> row) => parseFlexibleDate(row['arrivedAt']),
          cutoff,
        ),
      ),
      read<OrderWindowRead>(
        'orders',
        () => _repository.getOrdersSubmittedBetween(
          start: week.mondayStart,
          end: week.nextMondayStart,
          maxDocuments: _orderCeiling,
        ),
        covers: (OrderWindowRead window) => !window.truncated,
      ),
      read<List<ConversationOutcome>>(
        'visit reasons',
        () => _outcomes.watchOutcomes(user, limit: _outcomeLimit).first,
        covers: (List<ConversationOutcome> rows) {
          if (rows.length < _outcomeLimit) return true;
          if (!user.isAdmin) return false;
          DateTime? oldest;
          for (final ConversationOutcome outcome in rows) {
            final DateTime? at = outcome.submittedAt;
            if (at != null && (oldest == null || at.isBefore(oldest))) {
              oldest = at;
            }
          }
          return oldest != null &&
              kualaLumpurDateKey(oldest).compareTo(cutoff) < 0;
        },
      ),
    ]);

    final List<Map<String, dynamic>>? people =
        results[0] as List<Map<String, dynamic>>?;
    final List<Map<String, dynamic>>? plans =
        results[1] as List<Map<String, dynamic>>?;
    final List<ConversationOutcome>? followUps =
        results[2] as List<ConversationOutcome>?;
    final List<Map<String, dynamic>>? shops =
        results[3] as List<Map<String, dynamic>>?;
    final List<AiInsight>? insights = results[4] as List<AiInsight>?;
    final List<Map<String, dynamic>>? stops =
        results[5] as List<Map<String, dynamic>>?;
    final List<Map<String, dynamic>>? orders =
        (results[6] as OrderWindowRead?)?.rows;
    final List<ConversationOutcome>? outcomes =
        results[7] as List<ConversationOutcome>?;

    List<Map<String, dynamic>>? plansOfWeek(String mondayKey) => plans == null
        ? null
        : TeamScope.filter(user, plans)
              .where((Map<String, dynamic> plan) {
                final String status = dataText(plan['status']).toLowerCase();
                if (status == 'archived' || status == 'cancelled') return false;
                final DateTime? start = parseFlexibleDate(plan['weekStart']);
                return start != null &&
                    kualaLumpurDateKey(start) == mondayKey;
              })
              .toList(growable: false);
    final List<Map<String, dynamic>>? weekPlans = plansOfWeek(week.mondayKey);
    final List<Map<String, dynamic>>? planningPlans = plansOfWeek(
      week.planningMondayKey,
    );

    final List<HomeDecision> decisions = <HomeDecision>[
      ?_routesNotPlanned(user, week, people, planningPlans),
      ..._followUps(followUps, today, week),
      ?_pinsNotVerified(user, week, shops, weekPlans),
      ..._stopped(insights),
      ?_stopsWithoutReason(user, week, stops, orders, outcomes),
    ];
    return HomeDecisionResult(
      decisions: List<HomeDecision>.unmodifiable(decisions),
      failed: List<String>.unmodifiable(failed),
      incomplete: List<String>.unmodifiable(incomplete),
    );
  }

  HomeDecision? _routesNotPlanned(
    UserProfile user,
    HomeWeek week,
    List<Map<String, dynamic>>? people,
    List<Map<String, dynamic>>? planningPlans,
  ) {
    if (people == null || planningPlans == null) return null;
    final Set<String> plannedUids = <String>{};
    final Set<String> plannedCodes = <String>{};
    for (final Map<String, dynamic> plan in planningPlans) {
      final String uid = dataText(plan['salesmanUid']);
      final String code = TeamScope.salesmanCodeOf(plan);
      if (uid.isNotEmpty) plannedUids.add(uid);
      if (code.isNotEmpty) plannedCodes.add(code);
    }
    int unplanned = 0;
    for (final Map<String, dynamic> person in TeamScope.filter(user, people)) {
      final String status = dataText(person['status']).toLowerCase();
      if (!UserProfile.isSalesmanRole(person['role'] ?? person['user_group']) ||
          (status.isNotEmpty && status != 'active')) {
        continue;
      }
      final String uid = dataText(person['uid'] ?? person['userUid']);
      final String code = TeamScope.salesmanCodeOf(person);
      if (plannedUids.contains(uid) || plannedCodes.contains(code)) continue;
      unplanned++;
    }
    if (unplanned == 0) return null;
    final String label = homeDateKeyLabel(week.planningMondayKey);
    return HomeDecision(
      kind: HomeDecisionKind.routesNotPlanned,
      count: unplanned,
      pageKey: 'route_planner',
      text: unplanned == 1
          ? '1 route for the week of $label is not planned.'
          : '$unplanned routes for the week of $label are not planned.',
    );
  }

  List<HomeDecision> _followUps(
    List<ConversationOutcome>? followUps,
    String today,
    HomeWeek week,
  ) {
    if (followUps == null) return const <HomeDecision>[];
    final List<ConversationOutcome> overdue = <ConversationOutcome>[];
    int dueThisWeek = 0;
    for (final ConversationOutcome outcome in followUps) {
      final String date = outcome.followUpDate;
      if (date.compareTo(today) < 0) {
        overdue.add(outcome);
      } else if (date.compareTo(week.sundayKey) <= 0) {
        dueThisWeek++;
      }
    }
    String shopOf(ConversationOutcome o) =>
        o.retailerName.trim().isEmpty ? o.retailerId : o.retailerName.trim();
    return <HomeDecision>[
      if (dueThisWeek > 0)
        HomeDecision(
          kind: HomeDecisionKind.followUpsDue,
          count: dueThisWeek,
          pageKey: 'visit_logs',
          text: dueThisWeek == 1
              ? '1 follow-up is due this week.'
              : '$dueThisWeek follow-ups are due this week.',
        ),
      if (overdue.isNotEmpty)
        HomeDecision(
          kind: HomeDecisionKind.followUpOverdue,
          count: overdue.length,
          pageKey: 'visit_logs',
          retailerId: overdue.first.retailerId,
          retailerName: shopOf(overdue.first),
          text: overdue.length == 1
              ? '1 follow-up is overdue: ${shopOf(overdue.first)}, '
                    '${homeDateKeyLabel(overdue.first.followUpDate)}.'
              : '${overdue.length} follow-ups are overdue. The oldest is '
                    '${shopOf(overdue.first)}, '
                    '${homeDateKeyLabel(overdue.first.followUpDate)}.',
        ),
    ];
  }

  HomeDecision? _pinsNotVerified(
    UserProfile user,
    HomeWeek week,
    List<Map<String, dynamic>>? shops,
    List<Map<String, dynamic>>? weekPlans,
  ) {
    if (shops == null || weekPlans == null) return null;
    final Set<String> planned = <String>{};
    for (final Map<String, dynamic> plan in weekPlans) {
      final Object? days = plan['days'];
      if (days is! List) continue;
      for (final Object? day in days) {
        if (day is! Map || day['stops'] is! List) continue;
        for (final Object? stop in day['stops'] as List) {
          if (stop is! Map) continue;
          final String id = dataText(stop['retailerId'] ?? stop['retailer_id']);
          if (id.isNotEmpty) planned.add(id);
        }
      }
    }
    final List<Map<String, dynamic>> unverified = shops
        .where(
          (Map<String, dynamic> shop) =>
              planned.contains(retailerRowId(shop)) &&
              retailerCoordinateStatus(shop) != CoordinateStatus.verified,
        )
        .toList(growable: false);
    if (unverified.isEmpty) return null;
    final Map<String, dynamic> first = unverified.first;
    final String name = dataText(
      pickFirst(first, const <String>['retailerName', 'name']),
      fallback: retailerRowId(first),
    );
    return HomeDecision(
      kind: HomeDecisionKind.pinsNotVerified,
      count: unverified.length,
      pageKey: user.isAdmin ? 'coordinate_review' : '',
      retailerId: retailerRowId(first),
      retailerName: name,
      text: unverified.length == 1
          ? '1 shop pin is not verified: arrival at $name will be unverified.'
          : '${unverified.length} shop pins are not verified: arrival there '
                'will be unverified.',
    );
  }

  List<HomeDecision> _stopped(List<AiInsight>? insights) {
    if (insights == null) return const <HomeDecision>[];
    final List<AiInsight> stopped = insights
        .where(
          (AiInsight i) =>
              i.type == 'stopped_product' && i.isActive && i.retailerId != '',
        )
        .toList(growable: false);
    final List<AiInsight> rest = stopped.skip(3).toList(growable: false);
    final int restShops = rest.map((AiInsight i) => i.retailerId).toSet().length;
    return <HomeDecision>[
      for (final AiInsight insight in stopped.take(3))
        _stoppedSentence(insight),
      if (rest.isNotEmpty)
        HomeDecision(
          kind: HomeDecisionKind.stoppedOrdering,
          count: rest.length,
          pageKey: 'retailer',
          text:
              '${countLabel(rest.length, 'more product')} stopped at '
              '${countLabel(restShops, 'shop')}. Open the shop list to '
              'check them.',
        ),
    ];
  }

  HomeDecision _stoppedSentence(AiInsight insight) {
    return HomeDecision(
      kind: HomeDecisionKind.stoppedOrdering,
      count: 1,
      pageKey: '',
      retailerId: insight.retailerId,
      retailerName: insight.retailerName,
      productId: insight.productId,
      text:
          '${insight.retailerName} ordered no ${insight.productName}'
          '${stoppedWeeksPhrase(stoppedSeriesFromInsight(insight))}.',
    );
  }

  HomeDecision? _stopsWithoutReason(
    UserProfile user,
    HomeWeek week,
    List<Map<String, dynamic>>? stops,
    List<Map<String, dynamic>>? orders,
    List<ConversationOutcome>? outcomes,
  ) {
    if (stops == null || orders == null || outcomes == null) return null;
    final Set<String> ordered = <String>{
      for (final Map<String, dynamic> order in TeamScope.filter(user, orders))
        '${dataText(order['routePlanId'])}|${dataText(order['routeStopId'])}',
    };
    int open = 0;
    for (final Map<String, dynamic> stop in TeamScope.filter(user, stops)) {
      final DateTime? completedAt = parseFlexibleDate(stop['completedAt']);
      if (completedAt == null ||
          kualaLumpurDateKey(completedAt).compareTo(week.mondayKey) < 0) {
        continue;
      }
      if (ordered.contains(
        '${dataText(stop['planId'])}|${dataText(stop['stopId'])}',
      )) {
        continue;
      }
      final DateTime? arrivedAt = parseFlexibleDate(stop['arrivedAt']);
      final String retailerId = dataText(stop['retailerId']);
      final String code = TeamScope.salesmanCodeOf(stop);
      final bool hasReason = outcomes.any(
        (ConversationOutcome o) =>
            o.retailerId == retailerId &&
            o.salesmanCode == code &&
            o.submittedAt != null &&
            (arrivedAt == null || !o.submittedAt!.isBefore(arrivedAt)),
      );
      if (!hasReason) open++;
    }
    if (open == 0) return null;
    return HomeDecision(
      kind: HomeDecisionKind.stopsWithoutReason,
      count: open,
      pageKey: 'visit_logs',
      text: open == 1
          ? '1 completed stop has no order and no reason yet.'
          : '$open completed stops have no order and no reason yet.',
    );
  }
}
