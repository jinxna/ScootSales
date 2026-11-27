import 'dart:async';

import 'package:flutter/foundation.dart' show visibleForTesting;

import '../app/build_flags.dart';
import '../models/action_centre_item.dart';
import '../models/conversation_outcome.dart';
import '../models/user_profile.dart';
import '../repositories/cms_repository.dart';
import '../utils/derived_team_alerts.dart';
import '../utils/forecast_catalogue_provenance.dart';
import '../utils/follow_up_dates.dart';
import '../utils/ai_data_freshness.dart';
import 'outcome_review_service.dart';
import '../utils/retailer_readiness.dart';
import '../utils/order_data_utils.dart';
import '../utils/visit_data_utils.dart';
import '../utils/visit_overdue.dart';
import 'route_attention_service.dart';
import '../utils/money_format.dart';
import '../security/team_scope.dart';

class ActionCentreLoadResult {
  const ActionCentreLoadResult({
    required this.items,
    required this.failedSources,
    this.cutShortSources = const <String>[],
  });

  final List<ActionCentreItem> items;
  final List<String> failedSources;
  final List<String> cutShortSources;
}

class ActionCentreService {
  ActionCentreService({CmsRepository? repository})
    : _repository = repository ?? CmsRepository();

  final CmsRepository _repository;
  final OutcomeReviewService _outcomeService = OutcomeReviewService();
  final RouteAttentionService _routeAttentionService = RouteAttentionService();

  static const int _forecastRowLimit = 200;
  static const Duration _sharedDeriveTtl = Duration(seconds: 15);
  static String? _sharedKey;
  static DateTime? _sharedAt;
  static Future<ActionCentreLoadResult>? _sharedFuture;

  static void resetSharedDerive() {
    _sharedKey = null;
    _sharedAt = null;
    _sharedFuture = null;
  }

  Future<List<ActionCentreItem>> loadItems({
    required UserProfile currentUser,
    bool refresh = false,
  }) async {
    final List<ActionCentreItem> withStatus = (await _deriveWithStatus(
      currentUser,
      refresh: refresh,
    )).items;
    final List<ActionCentreItem> visible = withStatus
        .where((ActionCentreItem item) => item.isVisible)
        .toList(growable: false);
    visible.sort(_compareItems);
    return visible;
  }

  Future<List<ActionCentreItem>> loadAllItems({
    required UserProfile currentUser,
    bool refresh = false,
  }) async {
    final List<ActionCentreItem> withStatus = (await _deriveWithStatus(
      currentUser,
      refresh: refresh,
    )).items.toList();
    withStatus.sort(_compareItemsForReview);
    return withStatus;
  }

  Future<ActionCentreLoadResult> loadAllItemsWithHealth({
    required UserProfile currentUser,
    bool refresh = false,
  }) async {
    final ActionCentreLoadResult result = await _deriveWithStatus(
      currentUser,
      refresh: refresh,
    );
    final List<ActionCentreItem> sorted = result.items.toList(growable: false)
      ..sort(_compareItemsForReview);
    return ActionCentreLoadResult(
      items: sorted,
      failedSources: result.failedSources,
      cutShortSources: result.cutShortSources,
    );
  }

  Future<void> setStatus({
    required UserProfile currentUser,
    required String actionId,
    required String status,
    String? note,
  }) {
    _sharedFuture = null;
    return _repository.setActionCentreUserStatus(
      uid: currentUser.uid ?? '',
      actionId: actionId,
      status: status,
      note: note,
    );
  }

  Future<String> readWorkflowStatus({
    required UserProfile currentUser,
    required String actionId,
  }) async {
    final String? saved = await _repository.getActionCentreUserStatus(
      currentUser.uid ?? '',
      actionId,
    );
    return ActionCentreItem.canonicalStatus(saved ?? '');
  }

  Future<bool> setStatusIfUnchanged({
    required UserProfile currentUser,
    required String actionId,
    required String expectedStatus,
    required String status,
  }) {
    _sharedFuture = null;
    return _repository.setActionCentreUserStatusIfUnchanged(
      uid: currentUser.uid ?? '',
      actionId: actionId,
      expectedStatus: expectedStatus,
      status: status,
    );
  }

  Future<ActionCentreLoadResult> _deriveWithStatus(
    UserProfile currentUser, {
    bool refresh = false,
  }) {
    final String key = <String>[
      currentUser.uid ?? '',
      currentUser.role,
      currentUser.branchId,
      ...(currentUser.assignedSalesmanCodes.toList()..sort()),
    ].join('|');
    final DateTime now = DateTime.now();
    final Future<ActionCentreLoadResult>? shared = _sharedFuture;
    final DateTime? sharedAt = _sharedAt;
    if (!refresh &&
        shared != null &&
        _sharedKey == key &&
        sharedAt != null &&
        now.difference(sharedAt) < _sharedDeriveTtl) {
      return shared;
    }
    final Future<ActionCentreLoadResult> future = _deriveWithStatusUncached(
      currentUser,
    );
    _sharedKey = key;
    _sharedAt = now;
    _sharedFuture = future;
    unawaited(
      future.then<void>(
        (_) {},
        onError: (Object _) {
          if (identical(_sharedFuture, future)) _sharedFuture = null;
        },
      ),
    );
    return future;
  }

  Future<ActionCentreLoadResult> _deriveWithStatusUncached(
    UserProfile currentUser,
  ) async {
    final List<String> failedSources = <String>[];
    final List<String> cutShortSources = <String>[];
    final Future<Map<String, Map<String, dynamic>>> statusesFuture = _repository
        .getActionCentreUserStatuses(currentUser.uid ?? '');
    statusesFuture.ignore();
    final List<ActionCentreItem> derived = await _deriveItems(
      currentUser,
      failedSources: failedSources,
      cutShortSources: cutShortSources,
    );
    final Map<String, Map<String, dynamic>> statuses = await statusesFuture;
    final List<ActionCentreItem> items = statuses.isEmpty
        ? derived
        : derived
              .map((ActionCentreItem item) {
                final Map<String, dynamic>? s = statuses[item.id];
                if (s == null) return item;
                return item.copyWith(
                  status: _text(s['status'], fallback: item.status),
                  note: _text(s['note']),
                );
              })
              .toList(growable: false);
    return ActionCentreLoadResult(
      items: items,
      failedSources: List<String>.unmodifiable(failedSources),
      cutShortSources: List<String>.unmodifiable(cutShortSources),
    );
  }

  int _compareItemsForReview(ActionCentreItem a, ActionCentreItem b) {
    final int aHidden = a.isVisible ? 0 : 1;
    final int bHidden = b.isVisible ? 0 : 1;
    if (aHidden != bHidden) return aHidden.compareTo(bHidden);
    return _compareItems(a, b);
  }

  Future<List<ActionCentreItem>> _deriveItems(
    UserProfile currentUser, {
    required List<String> failedSources,
    List<String>? cutShortSources,
  }) async {
    final Future<List<ConversationOutcome>?> datedFollowUpsFuture =
        _outcomeService.loadOpenDatedFollowUps(currentUser);
    final Future<List<Map<String, dynamic>>?> routeProgressFuture =
        _routeAttentionService.loadProgress(currentUser);
    final Future<List<Map<String, dynamic>>?> referencedRoutePlansFuture =
        routeProgressFuture.then((List<Map<String, dynamic>>? progress) {
          if (progress == null) return null;
          return _routeAttentionService.loadReferencedPlans(
            currentUser,
            progress,
          );
        });
    final Future<List<Map<String, dynamic>>> specialRequestsFuture = _repository
        .watchSpecialRequests(currentUser: currentUser)
        .first
        .timeout(const Duration(seconds: 15))
        .catchError((Object _) {
          failedSources.add('special_requests');
          return <Map<String, dynamic>>[];
        });
    final Future<List<Map<String, dynamic>>> retailersFuture = _repository
        .getRetailerDirectory(limit: 2000)
        .catchError((Object _) {
          failedSources.add('retailers');
          return <Map<String, dynamic>>[];
        });
    final List<List<Map<String, dynamic>>> data =
        await Future.wait(<Future<List<Map<String, dynamic>>>>[
          isBasicEdition
              ? Future<List<Map<String, dynamic>>>.value(
                  const <Map<String, dynamic>>[],
                )
              : _safeGet(
                  'demand_forecasts',
                  orderBy: 'periodStart',
                  descending: true,
                  limit: _forecastRowLimit,
                  coverageProbe: false,
                  failedSources: failedSources,
                ),
          _safeGet(
            'orders',
            orderBy: 'submittedAt',
            descending: true,
            limit: 500,
            failedSources: failedSources,
          ),
          _safeGet(
            'visit_logs',
            orderBy: 'arrivalTime',
            descending: true,
            limit: 500,
            failedSources: failedSources,
          ),
          _safeGet('users', limit: 1000, failedSources: failedSources),
          retailersFuture,
          _safeGet('products', limit: 500, failedSources: failedSources),
          _safeGet('route_plans', limit: 200, failedSources: failedSources),
          specialRequestsFuture,
        ]);
    final List<Map<String, dynamic>> specialRequests = data[7];
    final List<ConversationOutcome>? datedFollowUps =
        await datedFollowUpsFuture;
    if (datedFollowUps == null) failedSources.add('conversation_outcomes');
    final List<Map<String, dynamic>>? routeProgress = await routeProgressFuture;
    if (routeProgress == null) failedSources.add('route_plan_progress');
    final List<Map<String, dynamic>>? referencedRoutePlans =
        await referencedRoutePlansFuture;
    if (routeProgress != null && referencedRoutePlans == null) {
      if (!failedSources.contains('route_plans')) {
        failedSources.add('route_plans');
      }
    }

    final List<Map<String, dynamic>> forecasts = data[0]
        .where((Map<String, dynamic> row) => !isDemoRow(row))
        .toList(growable: false);
    final bool restockListPartial = !forecastWindowCoversLatestPeriod(
      data[0],
      forecasts,
      limit: _forecastRowLimit,
    );
    if (restockListPartial && !failedSources.contains('demand_forecasts')) {
      cutShortSources?.add(
        'demand_forecasts (only the newest $_forecastRowLimit rows were checked)',
      );
    }
    final List<Map<String, dynamic>> orders = _scopeOrders(
      data[1],
      currentUser,
    );
    final List<Map<String, dynamic>> saleOrders = orders
        .where(orderCountsAsSale)
        .toList(growable: false);
    final List<Map<String, dynamic>> visits = _scopeVisits(
      data[2],
      currentUser,
    );
    final List<Map<String, dynamic>> users = data[3];
    final List<Map<String, dynamic>> retailers = operationalRetailerRows(
      data[4],
    );
    final List<Map<String, dynamic>> products = data[5];
    final Map<String, Map<String, dynamic>> routePlansById =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> plan in <Map<String, dynamic>>[
      ...data[6],
      ...?referencedRoutePlans,
    ]) {
      final String planId = _text(plan['planId'] ?? plan['docId']);
      if (planId.isNotEmpty) routePlansById[planId] = plan;
    }
    final List<Map<String, dynamic>> routePlans = routePlansById.values.toList(
      growable: false,
    );

    final List<ActionCentreItem> items = <ActionCentreItem>[
      if (routeProgress == null || referencedRoutePlans == null)
        ActionCentreItem(
          id: 'route_execution_worklist_unavailable',
          title: 'Route tracking alerts unavailable',
          category: 'Data Quality',
          priority: 'High',
          reason: routeProgress == null
              ? 'Route progress could not be read or has more than 1,000 active records. Route alerts may be incomplete.'
              : 'A referenced published route could not be read. Route alerts may be incomplete.',
          recommendedAction:
              'Restore access or reduce active route records, then refresh the dashboard.',
          confidence: 'High',
          relatedPageKey: 'route_planner',
          relatedEntityType: 'route_plan_progress',
          relatedEntityId: '',
          createdAt: DateTime.now(),
          source: 'route_plan_progress',
          status: 'open',
        ),
      if (restockListPartial)
        ActionCentreItem(
          id: 'forecast_restock_list_partial',
          title: 'Restock list is incomplete',
          category: 'Data Quality',
          priority: 'Medium',
          reason:
              'The latest forecast week has more products than the $_forecastRowLimit this list reads. Some restock items may be missing.',
          recommendedAction:
              'Open the Restock Recommendations tab for the full list.',
          confidence: 'High',
          relatedPageKey: 'prediction',
          relatedEntityType: 'demand_forecasts',
          relatedEntityId: '',
          createdAt: DateTime.now(),
          source: 'demand_forecasts',
          status: 'open',
        ),
      ..._forecastItems(forecasts),
      ..._retailerFollowUpItems(
        retailers: retailers,
        visits: visits,
        orders: saleOrders,
        currentUser: currentUser,
        visitWindowCoversWeek:
            !failedSources.contains('visit_logs') &&
            _visitWindowCoversWeek(data[2], 500),
      ),
      ..._salesmanSyncItems(
        users: users,
        visits: visits,
        orders: orders,
        currentUser: currentUser,
      ),
      ..._staleSpecialRequestItems(specialRequests, currentUser),
      ..._salesDropItems(saleOrders),
      ..._dataQualityItems(products: products, orders: orders),
      ..._routeWorkflowItems(routePlans, currentUser),
      ..._priorityCoverageItems(retailers, routePlans, currentUser),
      ..._coordinateQualityItems(retailers, currentUser),
      ..._datedFollowUpItems(datedFollowUps ?? const <ConversationOutcome>[]),
      ...routeExecutionAttentionItems(
        progressRows: routeProgress ?? const <Map<String, dynamic>>[],
        routePlans: routePlans,
        visits: visits,
        orders: orders,
      ),
    ];

    final Map<String, ActionCentreItem> deduped = <String, ActionCentreItem>{};
    for (final ActionCentreItem item in items) {
      final String key =
          '${item.category}|${item.relatedEntityType}|${item.relatedEntityId}|${item.title}'
              .toLowerCase();
      final ActionCentreItem? existing = deduped[key];
      if (existing == null || _compareItems(item, existing) < 0) {
        deduped[key] = item;
      }
    }
    return deduped.values.toList(growable: false);
  }

  @visibleForTesting
  List<ActionCentreItem> routeExecutionAttentionItems({
    required List<Map<String, dynamic>> progressRows,
    required List<Map<String, dynamic>> routePlans,
    required List<Map<String, dynamic>> visits,
    required List<Map<String, dynamic>> orders,
    DateTime? now,
  }) {
    final DateTime instant = now ?? DateTime.now();
    final String today = kualaLumpurDateKey(instant);
    final Map<String, Map<String, dynamic>> plansById =
        <String, Map<String, dynamic>>{
          for (final Map<String, dynamic> plan in routePlans)
            if (!isDemoRow(plan) &&
                _text(plan['status']).toLowerCase() == 'published' &&
                _text(plan['planId'] ?? plan['docId']).isNotEmpty)
              _text(plan['planId'] ?? plan['docId']): plan,
        };
    final List<ActionCentreItem> items = <ActionCentreItem>[];

    for (final Map<String, dynamic> progress in progressRows) {
      if (isDemoRow(progress) ||
          _text(progress['status']).toLowerCase() != 'in_progress') {
        continue;
      }
      final String planId = _text(progress['planId']);
      final Map<String, dynamic>? plan = plansById[planId];
      if (plan == null || !_isCurrentKualaLumpurPlan(plan, today)) continue;
      if (!_hasOutstandingRouteStop(plan, progress)) continue;
      if (_text(progress['routeSessionState']).toLowerCase() == 'paused') {
        continue;
      }
      if (!progress.containsKey('lastHeartbeatAt')) continue;

      final String salesmanUid = _text(progress['salesmanUid']);
      final String salesmanCode = _text(progress['salesmanCode']);
      final String salesman = salesmanCode.isEmpty ? salesmanUid : salesmanCode;
      final DateTime? heartbeat = _date(progress['lastHeartbeatAt']);
      final Duration? heartbeatAge = heartbeat == null
          ? null
          : instant.difference(heartbeat);
      final bool heartbeatFresh =
          _text(progress['routeSessionState']).toLowerCase() == 'active' &&
          heartbeatAge != null &&
          !heartbeatAge.isNegative &&
          heartbeatAge <= const Duration(minutes: 15);
      if (!heartbeatFresh) {
        final String reason = heartbeatAge == null
            ? 'No app heartbeat is available for the active route.'
            : heartbeatAge.isNegative
            ? 'The last app heartbeat is in the future; route activity cannot be assessed.'
            : 'The last app heartbeat was ${heartbeatAge.inMinutes} minutes ago.';
        items.add(
          ActionCentreItem(
            id: 'route_tracking_stale_${planId}_$salesmanUid',
            title: 'Route tracking stale · $salesman',
            category: 'Route Tracking',
            priority: 'Medium',
            reason:
                '$reason Idle status is unavailable until tracking resumes.',
            recommendedAction:
                'Check the salesperson’s app sync and route session. This signal uses no location data.',
            confidence: 'Low',
            relatedPageKey: 'salesman_activity',
            relatedEntityType: 'route_plan',
            relatedEntityId: planId,
            createdAt: heartbeat ?? _date(progress['updatedAt']),
            source: 'rule_based_route_heartbeat',
            status: 'open',
          ),
        );
        continue;
      }

      DateTime? lastActivity = _date(progress['updatedAt']);
      final DateTime? startedAt = _date(progress['startedAt']);
      if (startedAt != null &&
          (lastActivity == null || startedAt.isAfter(lastActivity))) {
        lastActivity = startedAt;
      }
      for (final Map<String, dynamic> event in <Map<String, dynamic>>[
        ...visits,
        ...orders,
      ]) {
        if (!_eventBelongsToSalesman(event, salesmanUid, salesmanCode)) {
          continue;
        }
        final DateTime? eventAt = _eventDate(event);
        if (eventAt != null &&
            (lastActivity == null || eventAt.isAfter(lastActivity))) {
          lastActivity = eventAt;
        }
      }
      if (lastActivity == null || lastActivity.isAfter(instant)) {
        items.add(
          ActionCentreItem(
            id: 'route_activity_unavailable_${planId}_$salesmanUid',
            title: 'Route activity unavailable · $salesman',
            category: 'Route Tracking',
            priority: 'Medium',
            reason:
                'The route has a fresh heartbeat but no valid activity timestamp.',
            recommendedAction:
                'Review route and sync records before assessing inactivity.',
            confidence: 'Low',
            relatedPageKey: 'salesman_activity',
            relatedEntityType: 'route_plan',
            relatedEntityId: planId,
            createdAt: heartbeat,
            source: 'rule_based_route_heartbeat',
            status: 'open',
          ),
        );
        continue;
      }
      if (instant.difference(lastActivity) < const Duration(minutes: 90)) {
        continue;
      }
      items.add(
        ActionCentreItem(
          id: 'route_idle_${planId}_$salesmanUid',
          title: 'No route activity for 90 minutes · $salesman',
          category: 'Route Activity',
          priority: 'High',
          reason:
              'The route is active and unpaused, has an outstanding stop, and has a fresh app heartbeat.',
          recommendedAction:
              'Check whether the salesperson needs support with the remaining route.',
          confidence: 'High',
          relatedPageKey: 'salesman_activity',
          relatedEntityType: 'route_plan',
          relatedEntityId: planId,
          createdAt: lastActivity,
          source: 'rule_based_route_idle',
          status: 'open',
        ),
      );
    }
    return items;
  }

  bool _isCurrentKualaLumpurPlan(Map<String, dynamic> plan, String today) {
    final DateTime? start = _date(plan['weekStart'] ?? plan['week_start']);
    final DateTime? end = _date(plan['weekEnd'] ?? plan['week_end']);
    if (start == null || end == null) return false;
    final String startKey = kualaLumpurDateKey(start);
    final String endKey = kualaLumpurDateKey(end);
    return startKey.compareTo(today) <= 0 && endKey.compareTo(today) >= 0;
  }

  bool _hasOutstandingRouteStop(
    Map<String, dynamic> plan,
    Map<String, dynamic> progress,
  ) {
    final Object? rawStopIds = plan['stopIds'];
    if (rawStopIds is! List) return false;
    final Object? rawHandled = progress['handledStopIds'];
    final Set<String> handled = rawHandled is List
        ? rawHandled.map((Object? id) => _text(id)).toSet()
        : <String>{};
    final Object? rawStopProgress = progress['stopProgress'];
    final Map<dynamic, dynamic> stopProgress = rawStopProgress is Map
        ? rawStopProgress
        : const <dynamic, dynamic>{};
    final String lastStopId = _text(progress['lastStopId']);
    final String lastStopStatus = _text(
      progress['lastStopStatus'],
    ).toLowerCase();
    for (final Object? rawId in rawStopIds) {
      final String stopId = _text(rawId);
      if (stopId.isEmpty || handled.contains(stopId)) continue;
      final Object? rawState = stopProgress[stopId];
      final String state = rawState is Map
          ? _text(rawState['status']).toLowerCase()
          : _text(rawState).toLowerCase();
      if (<String>{'completed', 'skipped'}.contains(state) ||
          (lastStopId == stopId &&
              <String>{'completed', 'skipped'}.contains(lastStopStatus))) {
        continue;
      }
      return true;
    }
    return false;
  }

  bool _eventBelongsToSalesman(
    Map<String, dynamic> event,
    String uid,
    String code,
  ) {
    final List<String> uidKeys = <String>[
      'salesmanUid',
      'salesman_uid',
      'uid',
      'userUid',
      'user_uid',
    ];
    final List<String> codeKeys = <String>[
      'salesmanCode',
      'salesman_code',
      'salesmanId',
      'salesman_id',
      'employeeCode',
      'employee_code',
      'staffId',
      'staff_id',
    ];
    return (uid.isNotEmpty &&
            uidKeys.any((String key) => _text(event[key]) == uid)) ||
        (code.isNotEmpty &&
            codeKeys.any((String key) => _text(event[key]) == code));
  }

  DateTime? _eventDate(Map<String, dynamic> event) {
    DateTime? latest;
    for (final String key in <String>[
      'arrivalTime',
      'arrival_time',
      'departureTime',
      'departure_time',
      'submittedAt',
      'submitted_at',
      'orderDate',
      'order_date',
      'createdAt',
      'created_at',
      'timestamp',
    ]) {
      final DateTime? value = _date(event[key]);
      if (value != null && (latest == null || value.isAfter(latest))) {
        latest = value;
      }
    }
    return latest;
  }

  List<ActionCentreItem> _datedFollowUpItems(
    List<ConversationOutcome> outcomes,
  ) {
    final String today = kualaLumpurDateKey();
    final List<ActionCentreItem> items = <ActionCentreItem>[];
    for (final ConversationOutcome outcome in outcomes) {
      if (!isValidKualaLumpurDateKey(outcome.followUpDate) ||
          outcome.followUpDate.compareTo(today) > 0) {
        continue;
      }
      final bool overdue = isKualaLumpurFollowUpOverdue(outcome.followUpDate);
      final String retailer = outcome.retailerName.trim().isEmpty
          ? outcome.retailerId
          : outcome.retailerName.trim();
      final String when = outcome.followUpTime.isEmpty
          ? outcome.followUpDate
          : '${outcome.followUpDate} ${outcome.followUpTime}';
      items.add(
        ActionCentreItem(
          id: 'dated_callback_${outcome.id}',
          title:
              '${overdue ? 'Overdue callback' : 'Callback due today'} · $retailer',
          category: 'Dated Follow-up',
          priority: overdue ? 'High' : 'Medium',
          reason: 'Salesperson ${outcome.salesmanCode} · due $when.',
          recommendedAction:
              'Review the reminder with the salesperson; the published route was not changed.',
          confidence: 'High',
          relatedPageKey: 'visit_logs',
          relatedEntityType: 'conversation_outcome',
          relatedEntityId: outcome.id,
          createdAt: outcome.submittedAt,
          source: 'conversation_outcomes',
          status: 'open',
        ),
      );
    }
    return items;
  }

  Future<List<Map<String, dynamic>>> _safeGet(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
    List<String>? failedSources,
  }) async {
    try {
      return await _repository.getCollectionOnce(
        collectionName,
        orderBy: orderBy,
        descending: descending,
        limit: limit,
        coverageProbe: coverageProbe,
      );
    } catch (_) {
      failedSources?.add(collectionName);
      return <Map<String, dynamic>>[];
    }
  }

  List<ActionCentreItem> _forecastItems(List<Map<String, dynamic>> forecasts) {
    final List<ActionCentreItem> items = <ActionCentreItem>[];
    for (final Map<String, dynamic> row in selectLatestForecastPeriod(
      forecasts,
    )) {
      final String productName = _text(
        _pick(row, <String>[
          'productName',
          'product_name',
          'name',
          'productId',
          'product_id',
        ]),
      );
      if (productName.isEmpty) continue;

      final ForecastRestockSignal signal = forecastRestockSignal(row);
      if (!signal.shouldShow) continue;
      final double changePercent = signal.changePercent;

      final String month = _text(
        _pick(row, <String>['forecastMonth', 'forecast_month', 'month']),
      );
      final String confidence = _normaliseConfidence(
        _text(row['confidence'], fallback: 'medium'),
      );
      final String reason = _text(row['reason']).isNotEmpty
          ? _text(row['reason'])
          : changePercent > 0
          ? 'Forecast demand is ${changePercent.toStringAsFixed(0)}% higher than the reference average.'
          : 'Saved forecast recommends extra stock for ${month.isEmpty ? 'the next forecast month' : month}.';

      items.add(
        ActionCentreItem(
          id: 'forecast_${_text(row['docId'] ?? productName)}',
          title: 'Prepare extra stock for $productName',
          category: 'Restock',
          priority: changePercent >= 25 ? 'High' : 'Medium',
          reason: reason,
          recommendedAction:
              'Review the Restock Recommendations tab and adjust procurement planning.',
          confidence: confidence,
          relatedPageKey: 'prediction',
          relatedEntityType: 'product',
          relatedEntityId: _text(
            row['productId'] ??
                row['product_id'] ??
                row['docId'] ??
                productName,
          ),
          createdAt: _date(
            _pick(row, <String>[
              'createdAt',
              'created_at',
              'updatedAt',
              'updated_at',
              'runCreatedAt',
              'run_created_at',
            ]),
          ),
          source: 'rule_based_forecast',
          status: 'open',
          freshnessAt: aiDataTimestamp(<String, dynamic>{
            'generatedAt': _pick(row, <String>[
              'generatedAt',
              'generated_at',
              'runCreatedAt',
              'run_created_at',
              'createdAt',
              'created_at',
            ]),
            'updatedAt': _pick(row, <String>['updatedAt', 'updated_at']),
            'weekStart': _pick(row, <String>['weekStart', 'week_start']),
          }),
        ),
      );
    }
    return items;
  }

  DateTime? _visitDate(Map<String, dynamic> visit) => _date(
    _pick(visit, <String>[
      'arrivalTime',
      'arrival_time',
      'departureTime',
      'departure_time',
      'submittedAt',
      'submitted_at',
      'createdAt',
      'created_at',
      'timestamp',
    ]),
  );

  bool _visitWindowCoversWeek(List<Map<String, dynamic>> rawVisits, int limit) {
    final List<Map<String, dynamic>> counted = rawVisits
        .where((Map<String, dynamic> row) => !isLocationOnlyVisitRow(row))
        .toList(growable: false);
    if (counted.length < limit) return true;
    DateTime? oldest;
    for (final Map<String, dynamic> visit in counted) {
      final DateTime? at = _visitDate(visit);
      if (at != null && (oldest == null || at.isBefore(oldest))) oldest = at;
    }
    return oldest != null &&
        oldest.isBefore(DateTime.now().subtract(const Duration(days: 7)));
  }

  bool _retailerInViewerScope(Map<String, dynamic> retailer, UserProfile user) {
    if (user.isSupervisor) {
      final Set<String> codes = <String>{
        for (final String key in <String>[
          'assignedSalesmanId',
          'assigned_salesman_id',
          'assignedSalesmanCode',
          'salesmanCode',
          'salesman_code',
        ])
          _text(retailer[key]),
        if (retailer['assignedSalesmanCodes'] is List)
          for (final Object? v in retailer['assignedSalesmanCodes'] as List)
            _text(v),
      }..remove('');
      return codes.any(user.assignedSalesmanCodes.contains);
    }
    if (user.isBranchManager) {
      return user.branchId.isNotEmpty &&
          _text(retailer['branchId'] ?? retailer['branch_id']) == user.branchId;
    }
    return user.isAdmin;
  }

  List<ActionCentreItem> _retailerFollowUpItems({
    required List<Map<String, dynamic>> retailers,
    required List<Map<String, dynamic>> visits,
    required List<Map<String, dynamic>> orders,
    required UserProfile currentUser,
    required bool visitWindowCoversWeek,
  }) {
    final Map<String, _RetailerActivity> byRetailer =
        <String, _RetailerActivity>{};

    for (final Map<String, dynamic> retailer in retailers) {
      final String id = _retailerKey(retailer);
      final String name = _retailerName(retailer);
      if (id.isEmpty && name.isEmpty) continue;
      final _RetailerActivity activity = byRetailer.putIfAbsent(
        id.isNotEmpty ? id : name,
        () => _RetailerActivity(id: id, name: name),
      );
      if (_retailerInViewerScope(retailer, currentUser)) {
        activity.assigned = true;
      }
    }

    for (final Map<String, dynamic> visit in visits) {
      final String id = _retailerKey(visit);
      final String name = _retailerName(visit);
      if (id.isEmpty && name.isEmpty) continue;
      final _RetailerActivity activity = byRetailer.putIfAbsent(
        id.isNotEmpty ? id : name,
        () => _RetailerActivity(id: id, name: name),
      );
      activity.name = activity.name.isEmpty ? name : activity.name;
      activity.assignedSalesman = _salesmanLabel(visit);
      final DateTime? visitedAt = _visitDate(visit);
      if (visitedAt != null &&
          (activity.lastVisit == null ||
              visitedAt.isAfter(activity.lastVisit!))) {
        activity.lastVisit = visitedAt;
      }
    }

    for (final Map<String, dynamic> order in orders) {
      final String id = _retailerKey(order);
      final String name = _retailerName(order);
      if (id.isEmpty && name.isEmpty) continue;
      final _RetailerActivity activity = byRetailer.putIfAbsent(
        id.isNotEmpty ? id : name,
        () => _RetailerActivity(id: id, name: name),
      );
      activity.name = activity.name.isEmpty ? name : activity.name;
      activity.assignedSalesman = activity.assignedSalesman.isEmpty
          ? _salesmanLabel(order)
          : activity.assignedSalesman;
      final DateTime? orderedAt = _orderDate(order);
      if (orderedAt != null &&
          (activity.lastOrder == null ||
              orderedAt.isAfter(activity.lastOrder!))) {
        activity.lastOrder = orderedAt;
      }
      activity.orderRevenue += _orderRevenue(order);
    }

    final DateTime now = DateTime.now();
    final List<ActionCentreItem> items = <ActionCentreItem>[];
    for (final _RetailerActivity activity in byRetailer.values) {
      final bool neverVisited =
          visitWindowCoversWeek &&
          activity.assigned &&
          activity.lastVisit == null;
      if (activity.lastVisit == null &&
          activity.lastOrder == null &&
          !neverVisited) {
        continue;
      }
      final int? daysSinceVisit = visitDaysAgo(activity.lastVisit, now);
      final int? daysSinceOrder = activity.lastOrder == null
          ? null
          : now.difference(activity.lastOrder!).inDays;
      final bool overdueVisit =
          neverVisited || isVisitOverdue(activity.lastVisit, now);
      final bool overdueOrder = daysSinceOrder != null && daysSinceOrder >= 18;
      if (!overdueVisit && !overdueOrder) continue;

      final String name = activity.name.isEmpty ? activity.id : activity.name;
      final String visitText = daysSinceVisit == null
          ? 'no recorded visit'
          : 'last visit $daysSinceVisit days ago';
      final String orderText = daysSinceOrder == null
          ? 'no recorded order'
          : 'last order $daysSinceOrder days ago';

      items.add(
        ActionCentreItem(
          id: 'retailer_followup_${activity.id.isEmpty ? name : activity.id}',
          title: 'Visit $name this week',
          category: 'Retailer Visit',
          priority: (daysSinceVisit ?? 0) >= 14 || (daysSinceOrder ?? 0) >= 30
              ? 'High'
              : 'Medium',
          reason: '$visitText, $orderText.',
          recommendedAction:
              'Schedule a retailer follow-up and confirm restock requirements.',
          confidence: 'Medium',
          relatedPageKey: 'visit_logs',
          relatedEntityType: 'retailer',
          relatedEntityId: activity.id.isEmpty ? name : activity.id,
          createdAt: activity.lastVisit ?? activity.lastOrder,
          source: 'rule_based_visit_order_gap',
          status: 'open',
        ),
      );
    }
    return items;
  }

  List<ActionCentreItem> _staleSpecialRequestItems(
    List<Map<String, dynamic>> requests,
    UserProfile currentUser,
  ) {
    final StaleRequestAudience audience = currentUser.isSupervisor
        ? StaleRequestAudience.supervisor
        : currentUser.isBranchManager
        ? StaleRequestAudience.branchManager
        : StaleRequestAudience.admin;
    final bool informational = audience == StaleRequestAudience.branchManager;
    return staleSpecialRequests(requests, audience: audience)
        .map((Map<String, dynamic> request) {
          final String id = _text(request['docId'] ?? request['orderId']);
          final String retailer = _text(
            request['retailerName'],
            fallback: 'a retailer',
          );
          return ActionCentreItem(
            id: 'special_request_overdue_$id',
            title: 'Special request for $retailer waiting more than 24 hours',
            category: 'Special Request',
            priority: 'High',
            reason: 'No decision has been made on this request yet.',
            recommendedAction: informational
                ? 'Follow up with the approver if the request is urgent.'
                : 'Approve or reject the request.',
            confidence: 'High',
            relatedPageKey: 'special_requests',
            relatedEntityType: 'special_request',
            relatedEntityId: id,
            createdAt: _date(request['createdAt']),
            source: 'special_requests',
            status: 'open',
          );
        })
        .toList(growable: false);
  }

  List<ActionCentreItem> _salesmanSyncItems({
    required List<Map<String, dynamic>> users,
    required List<Map<String, dynamic>> visits,
    required List<Map<String, dynamic>> orders,
    required UserProfile currentUser,
  }) {
    final Map<String, _SalesmanActivity> bySalesman =
        <String, _SalesmanActivity>{};
    for (final Map<String, dynamic> user in users) {
      if (!_isActiveSalesman(user)) continue;
      final String id = _salesmanKey(user);
      if (id.isEmpty) continue;
      if (currentUser.isSupervisor &&
          !currentUser.assignedSalesmanCodes.contains(id)) {
        continue;
      }
      bySalesman[id] = _SalesmanActivity(id: id, name: _salesmanLabel(user));
    }

    void record(Map<String, dynamic> row) {
      final String id = _salesmanKey(row);
      if (id.isEmpty) return;
      final _SalesmanActivity? activity = bySalesman[id];
      if (activity == null) return;
      final DateTime? date = _date(
        _pick(row, <String>[
          'updatedAt',
          'updated_at',
          'lastSeen',
          'last_seen',
          'timestamp',
          'submittedAt',
          'submitted_at',
          'arrivalTime',
          'arrival_time',
        ]),
      );
      if (date == null) return;
      if (activity.lastSeen == null || date.isAfter(activity.lastSeen!)) {
        activity.lastSeen = date;
      }
    }

    for (final Map<String, dynamic> visit in visits) {
      record(visit);
    }
    for (final Map<String, dynamic> order in orders) {
      record(order);
    }

    final DateTime now = DateTime.now();
    final List<ActionCentreItem> items = <ActionCentreItem>[];
    for (final _SalesmanActivity activity in bySalesman.values) {
      final int? daysSinceSync = activity.lastSeen == null
          ? null
          : now.difference(activity.lastSeen!).inDays;
      if (daysSinceSync != null && daysSinceSync < 2) continue;
      items.add(
        ActionCentreItem(
          id: 'salesman_sync_${activity.id}',
          title:
              'Check ${activity.name.isEmpty ? activity.id : activity.name} GPS sync',
          category: 'Salesman Follow-up',
          priority: daysSinceSync == null || daysSinceSync >= 7
              ? 'High'
              : 'Medium',
          reason: daysSinceSync == null
              ? 'No recent GPS, visit, or order activity was found for this active salesman.'
              : 'Last field sync was $daysSinceSync days ago.',
          recommendedAction:
              'Check app sync status, device connectivity, or recent route assignment.',
          confidence: 'Medium',
          relatedPageKey: 'salesman_activity',
          relatedEntityType: 'salesman',
          relatedEntityId: activity.id,
          createdAt: activity.lastSeen,
          source: 'rule_based_salesman_sync',
          status: 'open',
        ),
      );
    }
    return items;
  }

  List<ActionCentreItem> _salesDropItems(List<Map<String, dynamic>> orders) {
    final DateTime now = DateTime.now();
    final DateTime currentStart = now.subtract(const Duration(days: 30));
    final DateTime previousStart = now.subtract(const Duration(days: 60));
    final Map<String, _RevenueWindow> byRetailer = <String, _RevenueWindow>{};

    for (final Map<String, dynamic> order in orders) {
      final DateTime? date = _orderDate(order);
      if (date == null || date.isBefore(previousStart)) continue;
      final String key = _retailerKey(order);
      final String name = _retailerName(order);
      if (key.isEmpty && name.isEmpty) continue;
      final _RevenueWindow window = byRetailer.putIfAbsent(
        key.isEmpty ? name : key,
        () => _RevenueWindow(id: key, name: name),
      );
      window.name = window.name.isEmpty ? name : window.name;
      final double revenue = _orderRevenue(order);
      if (date.isBefore(currentStart)) {
        window.previousRevenue += revenue;
        window.previousOrders += 1;
      } else {
        window.currentRevenue += revenue;
        window.currentOrders += 1;
      }
    }

    final List<ActionCentreItem> items = <ActionCentreItem>[];
    for (final _RevenueWindow window in byRetailer.values) {
      if (window.previousRevenue <= 0 || window.previousOrders < 2) continue;
      if (window.currentRevenue >= window.previousRevenue * 0.6) continue;
      final double dropPercent =
          ((window.previousRevenue - window.currentRevenue) /
              window.previousRevenue) *
          100;
      final String name = window.name.isEmpty ? window.id : window.name;
      items.add(
        ActionCentreItem(
          id: 'sales_drop_${window.id.isEmpty ? name : window.id}',
          title: 'Investigate sales drop for $name',
          category: 'Sales Change',
          priority: dropPercent >= 60 ? 'High' : 'Medium',
          reason:
              'Revenue in the last 30 days is ${formatRm(window.currentRevenue)} vs ${formatRm(window.previousRevenue)} in the previous 30 days.',
          recommendedAction:
              'Review recent orders, visit notes, stock availability, and retailer feedback.',
          confidence: 'Medium',
          relatedPageKey: 'reports',
          relatedEntityType: 'retailer',
          relatedEntityId: window.id.isEmpty ? name : window.id,
          createdAt: now,
          source: 'rule_based_sales_change',
          status: 'open',
        ),
      );
    }
    return items;
  }

  List<ActionCentreItem> _dataQualityItems({
    required List<Map<String, dynamic>> products,
    required List<Map<String, dynamic>> orders,
  }) {
    Map<String, dynamic>? missingPriceProduct;
    for (final Map<String, dynamic> product in products) {
      final double price = _number(
        _pick(product, <String>[
          'unitPrice',
          'unit_price',
          'price',
          'sellingPrice',
          'selling_price',
        ]),
      );
      if (price <= 0) {
        missingPriceProduct = product;
        break;
      }
    }

    missingPriceProduct ??= _firstOrderItemWithMissingPrice(orders);
    if (missingPriceProduct == null) return <ActionCentreItem>[];

    final String productName = _text(
      _pick(missingPriceProduct, <String>[
        'productName',
        'product_name',
        'itemName',
        'item_name',
        'name',
        'code',
        'productId',
        'product_id',
      ]),
      fallback: 'a product',
    );

    return <ActionCentreItem>[
      ActionCentreItem(
        id: 'data_quality_missing_price_${_text(missingPriceProduct['docId'] ?? productName)}',
        title: 'Missing product price in imported data',
        category: 'Data Quality',
        priority: 'Medium',
        reason:
            '$productName has no usable unit price in the latest product/order data.',
        recommendedAction:
            'Open Products and update the missing price before relying on revenue totals.',
        confidence: 'High',
        relatedPageKey: 'product',
        relatedEntityType: 'product',
        relatedEntityId: _text(
          missingPriceProduct['docId'] ??
              missingPriceProduct['productId'] ??
              missingPriceProduct['product_id'] ??
              productName,
        ),
        createdAt: DateTime.now(),
        source: 'rule_based_data_quality',
        status: 'open',
      ),
    ];
  }

  List<ActionCentreItem> _routeWorkflowItems(
    List<Map<String, dynamic>> rows,
    UserProfile currentUser,
  ) {
    final List<ActionCentreItem> items = <ActionCentreItem>[];
    for (final Map<String, dynamic> row in rows) {
      if (!_rowInScope(row, currentUser)) continue;
      final String status = _text(row['status']).toLowerCase();
      if (status != 'draft' && status != 'approved') continue;
      final String planId = _text(row['planId'] ?? row['docId']);
      final String owner = _salesmanLabel(row);
      final int stops = _number(row['totalStops']).toInt();
      final bool approved = status == 'approved';
      items.add(
        ActionCentreItem(
          id: 'route_workflow_$planId',
          title: approved
              ? 'Publish approved route${owner.isEmpty ? '' : ' for $owner'}'
              : 'Review draft route${owner.isEmpty ? '' : ' for $owner'}',
          category: 'Route Workflow',
          priority: approved ? 'High' : 'Medium',
          reason:
              '${stops > 0 ? '$stops planned stop(s). ' : ''}The plan is ${approved ? 'approved but not published' : 'saved as draft and awaiting a decision'}.',
          recommendedAction: approved
              ? 'Open Route Planner, verify the week, and publish explicitly.'
              : 'Open Route Planner, review feasibility, then approve or revise.',
          confidence: 'High',
          relatedPageKey: 'route_planner',
          relatedEntityType: 'route_plan',
          relatedEntityId: planId,
          createdAt: _date(row['updatedAt'] ?? row['createdAt']),
          source: 'route_workflow_state',
          status: 'open',
        ),
      );
    }
    return items;
  }

  List<ActionCentreItem> _coordinateQualityItems(
    List<Map<String, dynamic>> retailers,
    UserProfile currentUser,
  ) {
    final List<Map<String, dynamic>> scoped = retailers
        .where((Map<String, dynamic> row) => _rowInScope(row, currentUser))
        .toList(growable: false);
    final int blocked = scoped.where((Map<String, dynamic> row) {
      return retailerCoordinateStatus(row) != CoordinateStatus.verified;
    }).length;
    if (blocked == 0) return const <ActionCentreItem>[];
    return <ActionCentreItem>[
      ActionCentreItem(
        id: 'data_quality_route_coordinates',
        title: '$blocked retailer coordinate record(s) block trusted routing',
        category: 'Data Quality',
        priority: blocked >= 10 ? 'High' : 'Medium',
        reason:
            'Missing, candidate, or needs-review coordinates are never treated as verified.',
        recommendedAction: currentUser.isAdmin
            ? 'Open Coordinate Review and verify the highest-priority retailers first.'
            : 'Ask an administrator to verify the highest-priority retailer coordinates.',
        confidence: 'High',
        relatedPageKey: currentUser.isAdmin ? 'coordinate_review' : '',
        relatedEntityType: 'retailer_coordinates',
        relatedEntityId: 'unverified',
        createdAt: DateTime.now(),
        source: 'coordinate_data_quality',
        status: 'open',
      ),
    ];
  }

  List<ActionCentreItem> _priorityCoverageItems(
    List<Map<String, dynamic>> retailers,
    List<Map<String, dynamic>> routePlans,
    UserProfile currentUser,
  ) {
    final Set<String> plannedRetailerIds = <String>{};
    for (final Map<String, dynamic> plan in routePlans) {
      if (!_rowInScope(plan, currentUser)) continue;
      final String status = _text(plan['status']).toLowerCase();
      if (status == 'archived' || status == 'cancelled') continue;
      final DateTime? weekEnd = _date(plan['weekEnd'] ?? plan['week_end']);
      final DateTime now = DateTime.now();
      final DateTime startOfToday = DateTime(now.year, now.month, now.day);
      if (weekEnd != null && weekEnd.isBefore(startOfToday)) continue;
      final Object? rawDays = plan['days'];
      if (rawDays is! List) continue;
      for (final Object? rawDay in rawDays) {
        if (rawDay is! Map || rawDay['stops'] is! List) continue;
        for (final Object? rawStop in rawDay['stops'] as List) {
          if (rawStop is! Map) continue;
          final String retailerId = _text(
            rawStop['retailerId'] ?? rawStop['retailer_id'],
          );
          if (retailerId.isNotEmpty) plannedRetailerIds.add(retailerId);
        }
      }
    }

    final List<ActionCentreItem> items = <ActionCentreItem>[];
    for (final Map<String, dynamic> retailer in retailers) {
      if (!_rowInScope(retailer, currentUser)) continue;
      final String retailerId = _retailerKey(retailer);
      if (retailerId.isEmpty || plannedRetailerIds.contains(retailerId)) {
        continue;
      }
      final double score = _number(
        retailer['priorityScore'] ??
            retailer['priority_score'] ??
            retailer['attentionScore'],
      );
      final String priority = _text(
        retailer['priority'] ?? retailer['priorityLabel'],
      ).toLowerCase();
      if (score < 0.6 && priority != 'high' && priority != 'urgent') continue;
      final String name = _retailerName(retailer);
      items.add(
        ActionCentreItem(
          id: 'priority_coverage_$retailerId',
          title:
              '${name.isEmpty ? retailerId : name} is outside the current plan',
          category: 'Priority Coverage',
          priority: priority == 'urgent' || score >= 0.8 ? 'High' : 'Medium',
          reason: score > 0
              ? 'Saved priority evidence is ${score.toStringAsFixed(2)}, but no active route includes this retailer.'
              : 'The retailer is marked ${priority.isEmpty ? 'high priority' : priority}, but no active route includes it.',
          recommendedAction:
              'Open Route Planner and compare coverage before generating the next draft.',
          confidence: score > 0 ? 'Medium' : 'Low',
          relatedPageKey: 'route_planner',
          relatedEntityType: 'retailer',
          relatedEntityId: retailerId,
          createdAt: _date(retailer['updatedAt'] ?? retailer['createdAt']),
          source: 'unscheduled_priority',
          status: 'open',
        ),
      );
    }
    return items;
  }

  bool _rowInScope(Map<String, dynamic> row, UserProfile user) {
    if (user.isSupervisor) {
      final String salesman = _salesmanKey(row);
      if (salesman.isNotEmpty &&
          user.assignedSalesmanCodes.contains(salesman)) {
        return true;
      }
      final Object? rawAssignments =
          row['assignedSalesmanCodes'] ?? row['assigned_salesman_codes'];
      if (rawAssignments is List) {
        return rawAssignments
            .map((Object? value) => _text(value))
            .any(user.assignedSalesmanCodes.contains);
      }
      return false;
    }
    if (user.isBranchManager && user.branchId.isNotEmpty) {
      return _text(row['branchId'] ?? row['branch_id']) == user.branchId;
    }
    return user.isAdmin;
  }

  Map<String, dynamic>? _firstOrderItemWithMissingPrice(
    List<Map<String, dynamic>> orders,
  ) {
    for (final Map<String, dynamic> order in orders) {
      final List<Map<String, dynamic>> items = authoritativeOrderItems(order);
      for (final Map<String, dynamic> item in items) {
        final double price = _number(
          _pick(item, <String>[
            'unitPrice',
            'unit_price',
            'price',
            'sellingPrice',
            'selling_price',
          ]),
        );
        if (price <= 0) return item;
      }
    }
    return null;
  }

  List<Map<String, dynamic>> _scopeOrders(
    List<Map<String, dynamic>> rows,
    UserProfile user,
  ) {
    return TeamScope.filter(user, rows);
  }

  List<Map<String, dynamic>> _scopeVisits(
    List<Map<String, dynamic>> rows,
    UserProfile user,
  ) {
    return TeamScope.filter(user, rows);
  }

  bool _isActiveSalesman(Map<String, dynamic> user) {
    final String role = _text(user['role'] ?? user['user_group']).toLowerCase();
    if (!(role.contains('salesman') ||
        role.contains('sales') ||
        role.contains('representative'))) {
      return false;
    }
    final String status = _text(user['status']).toLowerCase();
    final Object? activeValue = user['isActive'] ?? user['is_active'];
    final bool active = activeValue is bool
        ? activeValue
        : status.isEmpty || status == 'active' || status == 'enabled';
    return active && status != 'suspended' && status != 'inactive';
  }

  int _compareItems(ActionCentreItem a, ActionCentreItem b) {
    final int byPriority = _priorityRank(
      a.priority,
    ).compareTo(_priorityRank(b.priority));
    if (byPriority != 0) return byPriority;
    final DateTime aDate =
        a.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    final DateTime bDate =
        b.createdAt ?? DateTime.fromMillisecondsSinceEpoch(0);
    return bDate.compareTo(aDate);
  }

  int _priorityRank(String priority) {
    switch (priority.toLowerCase()) {
      case 'high':
        return 0;
      case 'medium':
        return 1;
      default:
        return 2;
    }
  }

  String _normaliseConfidence(String confidence) {
    switch (confidence.toLowerCase()) {
      case 'high':
        return 'High';
      case 'low':
        return 'Low';
      default:
        return 'Medium';
    }
  }

  String _retailerKey(Map<String, dynamic> row) => _text(
    _pick(row, <String>[
      'retailerId',
      'retailer_id',
      'retailerCode',
      'retailer_code',
      'outletId',
      'outlet_id',
      'docId',
    ]),
  );

  String _retailerName(Map<String, dynamic> row) => _text(
    _pick(row, <String>[
      'retailerName',
      'retailer_name',
      'outletName',
      'outlet_name',
      'storeName',
      'store_name',
      'name',
    ]),
  );

  String _salesmanKey(Map<String, dynamic> row) => _text(
    _pick(row, <String>[
      'salesmanId',
      'salesman_id',
      'salesmanUid',
      'salesman_uid',
      'salesmanCode',
      'salesman_code',
      'assignedSalesmanId',
      'assignedSalesmanCode',
      'employeeCode',
      'employee_code',
      'staffId',
      'staff_id',
      'uid',
      'docId',
      'email',
    ]),
  );

  String _salesmanLabel(Map<String, dynamic> row) => _text(
    _pick(row, <String>[
      'salesmanName',
      'salesman_name',
      'name',
      'displayName',
      'display_name',
      'employeeCode',
      'staffId',
      'salesmanId',
      'salesman_id',
      'email',
    ]),
  );

  DateTime? _orderDate(Map<String, dynamic> row) => _date(
    _pick(row, <String>[
      'submittedAt',
      'submitted_at',
      'orderDate',
      'order_date',
      'createdAt',
      'created_at',
      'timestamp',
    ]),
  );

  double _orderRevenue(Map<String, dynamic> row) => _number(
    _pick(row, <String>[
      'totalPrice',
      'total_price',
      'total',
      'grandTotal',
      'grand_total',
      'totalAmount',
      'total_amount',
      'amount',
    ]),
  );

  Object? _pick(Map<String, dynamic> row, List<String> keys) {
    for (final String key in keys) {
      if (!row.containsKey(key)) continue;
      final Object? value = row[key];
      if (_text(value).isNotEmpty || value is num || value is DateTime) {
        return value;
      }
    }
    return null;
  }

  String _text(Object? value, {String fallback = ''}) {
    if (value == null) return fallback;
    final String text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
    return text;
  }

  double _number(Object? value) {
    if (value == null) return 0;
    if (value is num) return value.toDouble();
    return double.tryParse(
          value.toString().replaceAll('RM', '').replaceAll(',', '').trim(),
        ) ??
        0;
  }

  DateTime? _date(Object? value) {
    if (value == null) return null;
    if (value is DateTime) return value;
    try {
      final dynamic candidate = value;
      final Object? maybeDate = candidate.toDate();
      if (maybeDate is DateTime) return maybeDate;
    } catch (_) {}
    if (value is num) {
      final int n = value.toInt();
      return DateTime.fromMillisecondsSinceEpoch(
        n > 9999999999 ? n : n * 1000,
        isUtc: true,
      );
    }
    return DateTime.tryParse(value.toString().trim());
  }
}

class _RetailerActivity {
  _RetailerActivity({required this.id, required this.name});
  final String id;
  String name;
  String assignedSalesman = '';
  DateTime? lastVisit;
  DateTime? lastOrder;
  double orderRevenue = 0;
  bool assigned = false;
}

class _SalesmanActivity {
  _SalesmanActivity({required this.id, required this.name});
  final String id;
  final String name;
  DateTime? lastSeen;
}

class _RevenueWindow {
  _RevenueWindow({required this.id, required this.name});
  final String id;
  String name;
  int currentOrders = 0;
  int previousOrders = 0;
  double currentRevenue = 0;
  double previousRevenue = 0;
}
