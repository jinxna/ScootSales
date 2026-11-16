import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter/services.dart' show LogicalKeyboardKey;
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/browser_page_history.dart';
import '../../../app_runtime.dart';
import '../../../models/route_plan.dart';
import '../../../models/tracking_control.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/geoapify_config.dart';
import '../../../services/salesman_scorecard_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/ai_data_freshness.dart';
import '../../../utils/assigned_retailer_status.dart';
import '../../../utils/collection_rows.dart';
import '../../../utils/firestore_query_utils.dart';
import '../../../utils/geo_field_utils.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/order_id_resolver.dart';
import '../../../utils/salesman_scorecard.dart';
import '../../../utils/visit_data_utils.dart';
import '../../../utils/my_team_roster.dart'
    show isSameMalaysiaDay, malaysiaWeekStart, parseTeamTimestamp;
import '../../../utils/user_facing_error.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../widgets/cms_panel.dart';
import 'tracking/marker_labels.dart';
import 'tracking/tracking_status.dart';
import 'tracking/tracking_widgets.dart';
import '../widgets/order_details_dialog.dart';
import '../../../widgets/geoapify_map_attribution.dart';
import '../../../utils/money_format.dart';
import '../../../security/team_scope.dart';
import '../../../widgets/tip_text.dart';
import '../../../utils/gps_accuracy.dart';
import '../../../widgets/slow_loading.dart';

int routeStopsPlannedOn(RoutePlan plan, DateTime day) {
  int stops = 0;
  for (final RouteDay routeDay in plan.days) {
    if (isSameMalaysiaDay(routeDay.date, day)) stops += routeDay.stops.length;
  }
  return stops;
}

int routeStopsPlannedToday(Iterable<RoutePlan> plans, DateTime day) {
  int stops = 0;
  for (final RoutePlan plan in plans) {
    if (plan.status.toLowerCase() != 'published') continue;
    stops += routeStopsPlannedOn(plan, day);
  }
  return stops;
}

({bool visits, bool location}) activityCoverage(
  List<Map<String, dynamic>>? rows,
  DateTime windowStart,
) {
  final bool visits = collectionRowsCover(rows, windowStart);
  return (
    visits: visits,
    location: visits && locationRowsCover(rows, windowStart),
  );
}

const Duration salesmanPerformanceWindow = Duration(days: 28);

const String _performanceWindowLabel = 'Supportive view · last 28 days';

({DateTime start, bool fullWindow, bool location})? salesmanPerformancePeriod(
  List<Map<String, dynamic>>? visitRows,
  List<Map<String, dynamic>>? orderRows,
  DateTime now,
) {
  final DateTime? covered = combinedCoverage(<List<Map<String, dynamic>>?>[
    visitRows,
    orderRows,
  ]);
  if (covered == null) return null;
  DateTime start = now.subtract(salesmanPerformanceWindow);
  final bool fullWindow = !covered.isAfter(start);
  if (!fullWindow) {
    final DateTime coveredKl = covered.toUtc().add(const Duration(hours: 8));
    start = kuchingDayStartUtc(coveredKl.year, coveredKl.month, coveredKl.day);
    if (start.isBefore(covered)) start = start.add(const Duration(days: 1));
    final DateTime nowKl = now.toUtc().add(const Duration(hours: 8));
    final DateTime yesterdayStart = kuchingDayStartUtc(
      nowKl.year,
      nowKl.month,
      nowKl.day - 1,
    );
    if (start.isAfter(yesterdayStart)) return null;
  }
  return (
    start: start,
    fullWindow: fullWindow,
    location: locationRowsCover(visitRows, start),
  );
}

DateTime _todayStartUtc() {
  final DateTime nowKl = DateTime.now().toUtc().add(const Duration(hours: 8));
  return kuchingDayStartUtc(nowKl.year, nowKl.month, nowKl.day);
}

class SalesmanActivityPage extends StatelessWidget {
  const SalesmanActivityPage({
    super.key,
    required this.currentUser,
    this.showAuthLogs = false,
    @visibleForTesting this.repositoryOverride,
  });

  final UserProfile currentUser;
  final bool showAuthLogs;

  final CmsRepository? repositoryOverride;

  @override
  Widget build(BuildContext context) {
    if (supervisorHasNoTeam(currentUser)) {
      return const _NoTeamAssignedState();
    }
    final CmsRepository repository = repositoryOverride ?? CmsRepository();
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: repository.watchCollection('users'),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> userSnap,
          ) {
            final Map<String, _SalesmanUser> userIndex =
                _buildSalesmanUserIndex(
                  userSnap.data ?? <Map<String, dynamic>>[],
                );
            return LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final Set<String> allowedSalesmanUids = _uniqueSalesmen(
                  userIndex,
                ).map((_SalesmanUser person) => person.uid).toSet();
                final Widget overview = _LiveTrackingWorkspace(
                  repository: repository,
                  allowedSalesmanUids: allowedSalesmanUids,
                  scopeKey: _trackingScopeKey(currentUser),
                  builder: (BuildContext context, _LiveTrackingView tracking) =>
                      _liveOverview(
                        context,
                        constraints,
                        repository,
                        userIndex,
                        userSnap.hasData && !userSnap.hasError,
                        tracking,
                      ),
                );
                return DefaultTabController(
                  length: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      const _TrackingTabs(),
                      const SizedBox(height: 16),
                      Expanded(
                        child: TabBarView(
                          children: <Widget>[
                            overview,
                            _salesmanPerformancePanel(repository, userIndex),
                            _CoachingScorecardPanel(
                              currentUser: currentUser,
                              users:
                                  userSnap.data ??
                                  const <Map<String, dynamic>>[],
                            ),
                          ],
                        ),
                      ),
                    ],
                  ),
                );
              },
            );
          },
    );
  }

  @visibleForTesting
  static bool supervisorHasNoTeam(UserProfile user) =>
      user.isSupervisor &&
      !user.assignedSalesmanCodes.any((String c) => c.trim().isNotEmpty);

  String _trackingScopeKey(UserProfile user) {
    final List<String> codes = user.assignedSalesmanCodes.toList()..sort();
    return '${user.uid}|${user.role}|${user.branchId}|${codes.join(',')}';
  }

  Widget _liveOverview(
    BuildContext context,
    BoxConstraints constraints,
    CmsRepository repository,
    Map<String, _SalesmanUser> userIndex,
    bool profilesLoaded,
    _LiveTrackingView tracking,
  ) {
    final double width = constraints.maxWidth;
    final bool wide = width >= 1000;
    final double centreHeight = constraints.hasBoundedHeight
        ? (constraints.maxHeight - 76).clamp(600.0, 860.0)
        : 700.0;
    final Widget centre = _RetryableStream(
      builder: (BuildContext context, VoidCallback retry) =>
          StreamBuilder<List<Map<String, dynamic>>>(
            stream: repository.watchCollection('visit_logs'),
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> historySnap,
                ) {
                  return _CurrentWeekPlans(
                    currentUser: currentUser,
                    people: _uniqueSalesmen(userIndex),
                    builder:
                        (
                          BuildContext context,
                          List<Map<String, dynamic>>? planRows,
                          bool plansFailed,
                        ) {
                          final List<Map<String, dynamic>> rows =
                              _scopeVisitLogs(
                                historySnap.data ?? <Map<String, dynamic>>[],
                              );
                          final List<RoutePlan> plans = planRows != null
                              ? _scopePublishedPlans(planRows, userIndex)
                              : const <RoutePlan>[];
                          return _CommandCentre(
                            data: _buildCommandData(
                              rows,
                              tracking,
                              userIndex,
                              plans,
                            ),
                            tracking: tracking,
                            repository: repository,
                            currentUser: currentUser,
                            wide: wide,
                            drawerWidth: width >= 1200 ? 380 : 340,
                            historyLoading:
                                historySnap.connectionState ==
                                    ConnectionState.waiting &&
                                !historySnap.hasData &&
                                !historySnap.hasError,
                            historyError: historySnap.hasError,
                            plansError: plansFailed,
                            onRetryHistory: () {
                              retry();
                              tracking.refresh();
                            },
                            colorForKey: _salesmanColor,
                            onOpenOrder: (_TimelineItem item) =>
                                OrderDetailsDialog.show(
                                  context,
                                  orderDocumentId: item.orderDocumentId,
                                  repository: repository,
                                  initialOrder: item.row,
                                  currentUser: currentUser,
                                  showActions: true,
                                ),
                          );
                        },
                  );
                },
          ),
    );
    final Widget report = _dailyReportPanel(repository, userIndex);
    final Widget activity = _logsPanel(repository, userIndex);
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        if (currentUser.isSupervisor && profilesLoaded)
          _UnresolvedAssignmentsNotice(
            codes: _unresolvedAssignedCodes(currentUser, userIndex),
          ),
        if (wide) SizedBox(height: centreHeight, child: centre) else centre,
        const SizedBox(height: 16),
        if (width >= 840)
          SizedBox(
            height: 360,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Expanded(child: report),
                const SizedBox(width: 16),
                Expanded(child: activity),
              ],
            ),
          )
        else ...<Widget>[
          SizedBox(height: 380, child: report),
          const SizedBox(height: 16),
          SizedBox(height: 460, child: activity),
        ],
      ],
    );
  }

  List<String> _unresolvedAssignedCodes(
    UserProfile user,
    Map<String, _SalesmanUser> userIndex,
  ) {
    final Set<String> loadedCodes = _uniqueSalesmen(userIndex)
        .map((_SalesmanUser person) => _normaliseKey(person.salesmanCode))
        .where((String code) => code.isNotEmpty)
        .toSet();
    return user.assignedSalesmanCodes
        .where((String code) => !loadedCodes.contains(_normaliseKey(code)))
        .toList(growable: false);
  }

  _CommandData _buildCommandData(
    List<Map<String, dynamic>> historyRows,
    _LiveTrackingView tracking,
    Map<String, _SalesmanUser> userIndex,
    List<RoutePlan> plans,
  ) {
    final List<_MapPoint> points = _buildMapPoints(
      tracking.currentRows,
      userIndex,
      historyRows: historyRows,
    );
    final Map<String, Set<String>> completedByKey = _completedRetailerIdsByKey(
      historyRows,
      userIndex,
    );
    final Map<String, int> plannedByKey = <String, int>{};
    for (final _SalesmanUser person in _uniqueSalesmen(userIndex)) {
      final ({List<_AssignedPoint> points, int missing, int plannedToday})
      assigned = _assignedPointsForSalesman(
        person.key,
        plans,
        completedByKey[person.key] ?? const <String>{},
        userIndex,
      );
      plannedByKey[person.key] = assigned.plannedToday;
    }
    final List<_FleetEntry> entries = _buildFleetEntries(
      historyRows,
      userIndex,
      tracking.currentRows,
      plannedByKey,
    );
    final String? selectedKey = tracking.selectedUid.isEmpty
        ? null
        : userIndex[_normaliseKey(tracking.selectedUid)]?.key;
    List<_AssignedPoint> assignedPoints = const <_AssignedPoint>[];
    int missingAssigned = 0;
    _FleetEntry? selected;
    List<_TimelineItem> timeline = const <_TimelineItem>[];
    double? routeKm;
    if (selectedKey != null) {
      final ({List<_AssignedPoint> points, int missing, int plannedToday})
      assigned = _assignedPointsForSalesman(
        selectedKey,
        plans,
        completedByKey[selectedKey] ?? const <String>{},
        userIndex,
      );
      assignedPoints = assigned.points;
      missingAssigned = assigned.missing;
      for (final _FleetEntry entry in entries) {
        if (entry.salesmanKey == selectedKey) selected = entry;
      }
      timeline = _timelineFor(selectedKey, historyRows, userIndex);
      if (assignedPoints.length > 1) {
        const Distance distance = Distance();
        double meters = 0;
        for (int i = 1; i < assignedPoints.length; i++) {
          meters += distance(
            assignedPoints[i - 1].position,
            assignedPoints[i].position,
          );
        }
        routeKm = meters / 1000;
      }
    }
    final ({bool visits, bool location}) covered = activityCoverage(
      historyRows,
      _todayStartUtc(),
    );
    return _CommandData(
      historyComplete: covered.visits,
      locationComplete: covered.location,
      entries: entries,
      points: points,
      assignedPoints: assignedPoints,
      missingAssigned: missingAssigned,
      missingTodayCount: historyRows
          .where(
            (Map<String, dynamic> row) =>
                _isTodayInKualaLumpur(row) && _extractLatLng(row) == null,
          )
          .length,
      selectedKey: selectedKey,
      selected: selected,
      timeline: timeline,
      routeKm: routeKm,
      lastActivityLabel: _latestActivityLabel(historyRows),
      activeToday: _activeSalesmanCount(historyRows),
      completedToday: _completedTodayCount(historyRows),
      markerCount: _historyMarkerCount(points),
    );
  }

  List<_TimelineItem> _timelineFor(
    String salesmanKey,
    List<Map<String, dynamic>> historyRows,
    Map<String, _SalesmanUser> userIndex,
  ) {
    final Map<String, Map<String, dynamic>> byKey =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> row in historyRows) {
      if (_salesmanKey(row, userIndex) != salesmanKey) continue;
      if (!_isTodayInKualaLumpur(row)) continue;
      final String source = _safeText(
        row['sourceCollection'],
        fallback: '',
      ).toLowerCase();
      final String status = _smartTrackingStatus(row);
      final bool completed =
          source == 'orders' || status == 'Visited' || status == 'Completed';
      if (!completed) continue;
      final String orderId = OrderIdResolver.resolve(row);
      final String retailer = _safeText(
        row['retailerName'] ?? row['retailer_id'],
        fallback: 'Visit',
      );
      final String key = orderId.isNotEmpty
          ? orderId
          : '$retailer:${_sortTimestampValue(row) ~/ 60000000}';
      final Map<String, dynamic>? existing = byKey[key];
      if (existing == null ||
          _sortTimestampValue(row) >= _sortTimestampValue(existing)) {
        byKey[key] = row;
      }
    }
    final List<Map<String, dynamic>> rows = byKey.values.toList()
      ..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            _sortTimestampValue(a).compareTo(_sortTimestampValue(b)),
      );
    return rows
        .map((Map<String, dynamic> row) {
          final DateTime? date = _dateForRow(row);
          final DateTime? kl = date?.toUtc().add(const Duration(hours: 8));
          final double total = _toDouble(row['totalPrice']) ?? 0;
          final String source = _safeText(
            row['sourceCollection'],
            fallback: '',
          ).toLowerCase();
          final String orderId = OrderIdResolver.resolve(row);
          return _TimelineItem(
            timeLabel: kl == null
                ? '--:--'
                : '${_twoDigits(kl.hour)}:${_twoDigits(kl.minute)}',
            title: _safeText(
              row['retailerName'] ?? row['retailer_id'],
              fallback: 'Visit',
            ),
            outcome: source == 'orders'
                ? 'Score sheet submitted${total > 0 ? ' · ${formatRm(total)}' : ''}'
                : 'Visit completed',
            orderDocumentId:
                orderId.isNotEmpty &&
                    (source == 'orders' || source == 'visit_logs')
                ? orderId
                : '',
            row: row,
          );
        })
        .toList(growable: false);
  }

  Widget _incompleteActivityCounts() => const Padding(
    padding: EdgeInsets.all(18),
    child: _EmptyState(
      icon: ScootIcons.info,
      title: 'Incomplete activity coverage',
      subtitle: 'Visit counts and performance summaries are unavailable.',
    ),
  );

  Widget _salesmanPerformancePanel(
    CmsRepository repository,
    Map<String, _SalesmanUser> userIndex,
  ) {
    final Stream<List<Map<String, dynamic>>> orderStream = repository
        .watchCollection('orders', limit: 500);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: repository.watchCollection('visit_logs', limit: 500),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) => StreamBuilder<List<Map<String, dynamic>>>(
            stream: orderStream,
            builder:
                (
                  BuildContext context,
                  AsyncSnapshot<List<Map<String, dynamic>>> orders,
                ) {
                  final ({String label, List<SalesmanPerformance>? people})?
                  panel = snapshot.hasData && orders.hasData
                      ? _performancePanel(
                          snapshot.data,
                          orders.data,
                          userIndex,
                          DateTime.now(),
                        )
                      : null;
                  return CmsPanel(
                    title: 'Salesman Performance',
                    trailing: _SmallChip(
                      label: panel?.label ?? _performanceWindowLabel,
                    ),
                    child: Builder(
                      builder: (BuildContext context) {
                        if ((snapshot.connectionState ==
                                    ConnectionState.waiting &&
                                !snapshot.hasData) ||
                            (orders.connectionState ==
                                    ConnectionState.waiting &&
                                !orders.hasData)) {
                          return const SlowLoading();
                        }
                        if (snapshot.hasError || orders.hasError) {
                          return const Padding(
                            padding: EdgeInsets.all(18),
                            child: _EmptyState(
                              icon: ScootIcons.error,
                              title: 'Performance data unavailable',
                              subtitle:
                                  'Salesman activity could not be loaded. Check the visit/order bridge and try again.',
                            ),
                          );
                        }
                        final List<SalesmanPerformance>? summaries =
                            panel?.people;
                        if (summaries == null) {
                          return _incompleteActivityCounts();
                        }
                        if (summaries.isEmpty) {
                          return const Padding(
                            padding: EdgeInsets.all(18),
                            child: _EmptyState(
                              icon: ScootIcons.reports,
                              title: 'Insufficient data',
                              subtitle:
                                  'Performance summaries need recent visit or order activity.',
                            ),
                          );
                        }
                        return ListView.separated(
                          padding: const EdgeInsets.all(16),
                          itemCount: summaries.length,
                          separatorBuilder: (_, _) =>
                              const SizedBox(height: 10),
                          itemBuilder: (BuildContext context, int index) {
                            final SalesmanPerformance item = summaries[index];
                            return Container(
                              padding: const EdgeInsets.all(14),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(14),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      CircleAvatar(
                                        radius: 18,
                                        backgroundColor: item.color.withValues(
                                          alpha: 0.12,
                                        ),
                                        child: Text(
                                          item.initial,
                                          style: TextStyle(
                                            fontWeight: FontWeight.w900,
                                            color: item.color,
                                          ),
                                        ),
                                      ),
                                      const SizedBox(width: 10),
                                      Expanded(
                                        child: Column(
                                          crossAxisAlignment:
                                              CrossAxisAlignment.start,
                                          children: <Widget>[
                                            Text(
                                              item.salesmanName,
                                              style: const TextStyle(
                                                fontSize: 14,
                                                fontWeight: FontWeight.w900,
                                              ),
                                            ),
                                            const SizedBox(height: 3),
                                            Text(
                                              item.recommendedFollowUp,
                                              style: TextStyle(
                                                fontSize: 12,
                                                color: Theme.of(
                                                  context,
                                                ).colorScheme.onSurfaceVariant,
                                                height: 1.4,
                                              ),
                                            ),
                                          ],
                                        ),
                                      ),
                                      _statusPill(context, item.label),
                                    ],
                                  ),
                                  const SizedBox(height: 12),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 8,
                                    children: <Widget>[
                                      for (final (String label, String value)
                                          in item.figures)
                                        _performanceMetric(
                                          context,
                                          label,
                                          value,
                                        ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        );
                      },
                    ),
                  );
                },
          ),
    );
  }

  @visibleForTesting
  ({String label, List<SalesmanPerformance>? people}) performancePanel(
    List<Map<String, dynamic>>? visitRows,
    List<Map<String, dynamic>>? orderRows,
    List<Map<String, dynamic>> users,
    DateTime now,
  ) => _performancePanel(
    visitRows,
    orderRows,
    _buildSalesmanUserIndex(users),
    now,
  );

  ({String label, List<SalesmanPerformance>? people}) _performancePanel(
    List<Map<String, dynamic>>? visitRows,
    List<Map<String, dynamic>>? orderRows,
    Map<String, _SalesmanUser> userIndex,
    DateTime now,
  ) {
    final ({DateTime start, bool fullWindow, bool location})? period =
        salesmanPerformancePeriod(visitRows, orderRows, now);
    return (
      label: period == null || period.fullWindow
          ? _performanceWindowLabel
          : 'Supportive view · since ${formatAiFreshnessDate(period.start)}',
      people: period == null
          ? null
          : _buildPerformanceSummaries(
              _scopeVisitLogs(visitRows ?? <Map<String, dynamic>>[]),
              TeamScope.filter(
                currentUser,
                orderRows ?? <Map<String, dynamic>>[],
              ),
              userIndex,
              now,
              period,
            ),
    );
  }

  List<SalesmanPerformance> _buildPerformanceSummaries(
    List<Map<String, dynamic>> rows,
    List<Map<String, dynamic>> orders,
    Map<String, _SalesmanUser> userIndex,
    DateTime now,
    ({DateTime start, bool fullWindow, bool location}) period,
  ) {
    final Map<String, _PerformanceBuilder> builders =
        <String, _PerformanceBuilder>{};
    final DateTime currentStart = now.subtract(const Duration(days: 14));

    for (final Map<String, dynamic> row in rows) {
      final bool locationOnly = isLocationOnlyVisitRow(row);
      if (locationOnly && !period.location) continue;
      final DateTime? date = _dateForRow(row);
      if (date != null && date.isBefore(period.start)) continue;
      final String key = _salesmanKey(row, userIndex);
      if (key.isEmpty) continue;
      final String name = _displaySalesman(row, userIndex);
      final _PerformanceBuilder builder = builders.putIfAbsent(
        key,
        () => _PerformanceBuilder(salesmanKey: key, salesmanName: name),
      );
      if (date != null) {
        if (builder.lastSync == null || date.isAfter(builder.lastSync!)) {
          builder.lastSync = date;
        }
        builder.activeDays.add(_dateKeyKualaLumpur(row));
        if (!date.isBefore(currentStart)) {
          builder.currentPeriodActivity += 1;
        } else {
          builder.previousPeriodActivity += 1;
        }
      }

      final String source = _safeText(
        row['sourceCollection'],
        fallback: '',
      ).toLowerCase();
      final String status = _smartTrackingStatus(row);
      final bool completedVisit =
          source == 'orders' || status == 'Visited' || status == 'Completed';
      if (completedVisit) builder.visitsCompleted += 1;
      final String retailer = _safeText(
        row['retailerName'] ?? row['retailer_id'],
        fallback: '',
      );
      if (retailer.isNotEmpty && !locationOnly) builder.retailers.add(retailer);
      if (_extractLatLng(row) != null) builder.hasGps = true;
    }

    for (final Map<String, dynamic> order in orders) {
      final DateTime? date = orderDateFromRow(order);
      if (!orderCountsAsSale(order) ||
          date == null ||
          date.isBefore(period.start)) {
        continue;
      }
      final String key = _salesmanKey(order, userIndex);
      if (key.isEmpty) continue;
      builders
              .putIfAbsent(
                key,
                () => _PerformanceBuilder(
                  salesmanKey: key,
                  salesmanName: _displaySalesman(order, userIndex),
                ),
              )
              .ordersSubmitted +=
          1;
    }

    final List<SalesmanPerformance> summaries =
        builders.values
            .map(
              (_PerformanceBuilder builder) => builder.build(
                now,
                _salesmanColor(builder.salesmanKey),
                locationCovered: period.location,
                fullWindow: period.fullWindow,
              ),
            )
            .toList(growable: false)
          ..sort((SalesmanPerformance a, SalesmanPerformance b) {
            final int aScore = a.score ?? -1;
            final int bScore = b.score ?? -1;
            return bScore.compareTo(aScore);
          });
    return summaries;
  }

  List<RoutePlan> _scopePublishedPlans(
    List<Map<String, dynamic>> docs,
    Map<String, _SalesmanUser> userIndex,
  ) {
    final List<RoutePlan> plans = <RoutePlan>[];
    for (final Map<String, dynamic> doc in docs) {
      if (_safeText(doc['status'], fallback: '').toLowerCase() != 'published') {
        continue;
      }
      if (currentUser.isSupervisor) {
        final String code = _safeText(
          doc['salesmanCode'] ?? doc['salesman_code'],
          fallback: '',
        );
        final String codeKey = _normaliseKey(code);
        if (!currentUser.assignedSalesmanCodes.any(
          (String c) => _normaliseKey(c) == codeKey,
        )) {
          continue;
        }
      } else if (currentUser.isBranchManager &&
          currentUser.branchId.isNotEmpty) {
        final String branch = _safeText(
          doc['branchId'] ?? doc['branch_id'],
          fallback: '',
        );
        if (branch != currentUser.branchId) continue;
      }
      final String id = _safeText(
        doc['planId'] ?? doc['docId'] ?? doc['id'],
        fallback: '',
      );
      plans.add(RoutePlan.fromMap(id, doc));
    }
    return plans;
  }

  ({List<_AssignedPoint> points, int missing, int plannedToday})
  _assignedPointsForSalesman(
    String key,
    List<RoutePlan> plans,
    Set<String> completed,
    Map<String, _SalesmanUser> userIndex,
  ) {
    RoutePlan? chosen;
    final List<RoutePlan> own = <RoutePlan>[];
    for (final RoutePlan plan in plans) {
      final String uidKey = _normaliseKey(plan.salesmanUid);
      final String planKey =
          userIndex[uidKey]?.key ?? _normaliseKey(plan.salesmanCode);
      if (planKey != key) continue;
      own.add(plan);
      if (chosen == null || plan.weekStart.isAfter(chosen.weekStart)) {
        chosen = plan;
      }
    }
    if (chosen == null) {
      return (points: const <_AssignedPoint>[], missing: 0, plannedToday: 0);
    }

    final Set<String> seen = <String>{};
    final List<_AssignedPoint> result = <_AssignedPoint>[];
    int missing = 0;
    for (final RouteDay day in chosen.days) {
      for (final RouteStop stop in day.stops) {
        final String id = stop.retailerId.trim();
        final String dedupeKey = id.isEmpty
            ? '${stop.retailerName}:${stop.lat},${stop.lng}'
            : id;
        if (!seen.add(dedupeKey)) continue;
        final AssignedRetailerStatus status = assignedRetailerStatus(
          lat: stop.lat,
          lng: stop.lng,
          stopStatus: stop.status,
          retailerId: id,
          completedRetailerIds: completed,
        );
        if (status == AssignedRetailerStatus.missingCoordinates) {
          missing += 1;
          continue;
        }
        result.add(
          _AssignedPoint(
            position: LatLng(stop.lat, stop.lng),
            retailerName: stop.retailerName,
            status: status,
          ),
        );
      }
    }
    return (
      points: result,
      missing: missing,
      plannedToday: routeStopsPlannedToday(own, DateTime.now()),
    );
  }

  Map<String, Set<String>> _completedRetailerIdsByKey(
    List<Map<String, dynamic>> rows,
    Map<String, _SalesmanUser> userIndex,
  ) {
    final Map<String, Set<String>> byKey = <String, Set<String>>{};
    for (final Map<String, dynamic> row in rows) {
      final String source = _safeText(
        row['sourceCollection'],
        fallback: '',
      ).toLowerCase();
      final String status = _smartTrackingStatus(row);
      final bool completed =
          source == 'orders' || status == 'Visited' || status == 'Completed';
      if (!completed) continue;
      final String key = _salesmanKey(row, userIndex);
      if (key.isEmpty) continue;
      final String retailerId = _safeText(
        row['retailerId'] ?? row['retailer_id'],
        fallback: '',
      );
      if (retailerId.isEmpty) continue;
      byKey.putIfAbsent(key, () => <String>{}).add(retailerId);
    }
    return byKey;
  }

  List<_FleetEntry> _buildFleetEntries(
    List<Map<String, dynamic>> historyRows,
    Map<String, _SalesmanUser> userIndex,
    List<Map<String, dynamic>> liveRows,
    Map<String, int> plannedByKey,
  ) {
    final ({bool visits, bool location}) covered = activityCoverage(
      historyRows,
      _todayStartUtc(),
    );
    final Map<String, _DailySalesmanSummary> summaries =
        <String, _DailySalesmanSummary>{
          for (final _DailySalesmanSummary summary in _buildDailySummaries(
            historyRows,
            userIndex,
            locationCovered: covered.location,
          ))
            summary.salesmanKey: summary,
        };
    final Map<String, Map<String, dynamic>> positionsByUid =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> row in liveRows) {
      final String uid = _safeText(
        row['salesmanUid'] ?? row['salesman_uid'] ?? row['docId'],
        fallback: '',
      );
      if (uid.isNotEmpty) positionsByUid[uid] = row;
    }

    final List<_FleetEntry> entries = _uniqueSalesmen(userIndex).map((
      _SalesmanUser person,
    ) {
      final _DailySalesmanSummary? history = summaries[person.key];
      final Map<String, dynamic>? live = positionsByUid[person.uid];
      final bool hasPosition = live != null && _extractLatLng(live) != null;
      final DateTime? serverReceivedAt = live == null
          ? null
          : _serverReceiptAt(live);
      final bool sharingDisabled = !person.gpsSharingEnabled;
      final bool hasSession = live != null && _hasActiveWorkSession(live);
      final bool endedSession = live != null && _hasEndedWorkSession(live);
      final bool fresh =
          hasPosition &&
          !sharingDisabled &&
          hasSession &&
          _isLivePositionFresh(live);
      final String statusKind = sharingDisabled
          ? 'sharing_disabled'
          : live == null
          ? 'missing'
          : endedSession
          ? 'ended'
          : fresh
          ? 'active'
          : hasPosition
          ? 'stale'
          : hasSession
          ? 'idle'
          : 'off';
      final LatLng? position = live == null ? null : _extractLatLng(live);
      final double? accuracy = live == null
          ? null
          : _numberValue(live['accuracyMeters'] ?? live['accuracy']);
      return _FleetEntry(
        historyComplete: covered.visits,
        salesmanKey: person.key,
        name: history?.salesmanName ?? person.name,
        salesmanUid: person.uid,
        salesmanCode: person.salesmanCode,
        branchId: person.branchId,
        color: _salesmanColor(person.key),
        statusKind: statusKind,
        lastLocation: position == null
            ? sharingDisabled
                  ? 'Location sharing is disabled'
                  : hasSession
                  ? 'Waiting for a phone location'
                  : live == null
                  ? 'No phone tracking row'
                  : endedSession
                  ? 'Work session ended'
                  : 'No current phone session'
            : '${sharingDisabled ? 'Last known: ' : ''}${position.latitude.toStringAsFixed(5)}, ${position.longitude.toStringAsFixed(5)}',
        positionAgeLabel: live == null || _positionTime(live) == null
            ? 'unavailable'
            : _capturedAgeLabel(live),
        lastSyncLabel: _syncAgeLabel(serverReceivedAt),
        accuracyLabel: _hasUsableAccuracy(accuracy)
            ? accuracyText(accuracy!)
            : 'Accuracy unknown',
        lowAccuracy: _hasUsableAccuracy(accuracy) && isLowAccuracy(accuracy!),
        positionClockLabel: live == null || _positionTime(live) == null
            ? ''
            : _clockLabel(_positionTime(live)!),
        completedToday: history?.completedOrders ?? 0,
        plannedStops: plannedByKey[person.key] ?? 0,
      );
    }).toList();

    int rank(String kind) => switch (kind) {
      'active' => 0,
      'stale' => 1,
      'idle' => 2,
      'sharing_disabled' => 3,
      'ended' => 4,
      _ => 5,
    };
    entries.sort((_FleetEntry a, _FleetEntry b) {
      final int byStatus = rank(a.statusKind).compareTo(rank(b.statusKind));
      if (byStatus != 0) return byStatus;
      if (a.historyComplete && b.historyComplete) {
        final int byDone = b.completedToday.compareTo(a.completedToday);
        if (byDone != 0) return byDone;
      }
      return a.name.toLowerCase().compareTo(b.name.toLowerCase());
    });
    return entries;
  }

  List<_SalesmanUser> _uniqueSalesmen(Map<String, _SalesmanUser> userIndex) {
    final Map<String, _SalesmanUser> byUid = <String, _SalesmanUser>{};
    for (final _SalesmanUser person in userIndex.values) {
      final String uid = person.uid.trim();
      if (uid.isNotEmpty) byUid.putIfAbsent(uid, () => person);
    }
    final List<_SalesmanUser> people = byUid.values.toList(growable: false)
      ..sort(
        (_SalesmanUser left, _SalesmanUser right) =>
            left.name.toLowerCase().compareTo(right.name.toLowerCase()),
      );
    return people;
  }

  Widget _dailyReportPanel(
    CmsRepository repository,
    Map<String, _SalesmanUser> userIndex,
  ) {
    return CmsPanel(
      title: 'Daily Salesman Report',
      trailing: const _SmallChip(label: 'Today'),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: repository.watchCollection('visit_logs'),
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
            ) => StreamBuilder<List<Map<String, dynamic>>>(
              stream: repository.watchCollection('orders', limit: 500),
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<Map<String, dynamic>>> orderSnapshot,
                  ) {
                    final List<Map<String, dynamic>> rows = _scopeVisitLogs(
                      snapshot.data ?? <Map<String, dynamic>>[],
                    );
                    final ({bool visits, bool location}) covered =
                        activityCoverage(snapshot.data, _todayStartUtc());
                    if (!covered.visits) {
                      return _incompleteActivityCounts();
                    }
                    if (orderSnapshot.hasError) {
                      return const Padding(
                        padding: EdgeInsets.all(18),
                        child: _EmptyState(
                          icon: ScootIcons.error,
                          title: 'Orders could not be loaded',
                          subtitle: 'Try again in a moment.',
                        ),
                      );
                    }
                    if (!orderSnapshot.hasData) return const SlowLoading();
                    if (!collectionRowsCover(
                      orderSnapshot.data,
                      _todayStartUtc(),
                    )) {
                      return _incompleteActivityCounts();
                    }
                    final List<_DailySalesmanSummary> summaries =
                        _buildDailySummaries(
                          rows,
                          userIndex,
                          locationCovered: covered.location,
                          orders: TeamScope.filter(
                            currentUser,
                            orderSnapshot.data!,
                          ),
                        );
                    if (summaries.isEmpty) {
                      return const Padding(
                        padding: EdgeInsets.all(18),
                        child: _EmptyState(
                          icon: ScootIcons.document,
                          title: 'No daily activity yet',
                          subtitle:
                              'Submitted score sheets, visit logs and GPS activity for today will be summarised here.',
                        ),
                      );
                    }
                    return ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: summaries.length,
                      separatorBuilder: (_, _) => const Divider(height: 18),
                      itemBuilder: (BuildContext context, int index) {
                        final _DailySalesmanSummary item = summaries[index];
                        final Color color = _salesmanColor(item.salesmanKey);
                        return Row(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            CircleAvatar(
                              radius: 18,
                              backgroundColor: color.withValues(alpha: 0.14),
                              child: Text(
                                item.initial,
                                style: TextStyle(
                                  fontWeight: FontWeight.w900,
                                  color: color,
                                ),
                              ),
                            ),
                            const SizedBox(width: 10),
                            Expanded(
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    item.salesmanName,
                                    style: const TextStyle(
                                      fontWeight: FontWeight.w800,
                                    ),
                                  ),
                                  const SizedBox(height: 4),
                                  Text(
                                    '${item.completedOrders} score sheet(s) submitted • ${item.visitedRetailers.length} retailer(s) visited • ${item.lastSeenLabel}',
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: Theme.of(
                                        context,
                                      ).colorScheme.onSurfaceVariant,
                                      height: 1.45,
                                    ),
                                  ),
                                  if (item
                                      .visitedRetailers
                                      .isNotEmpty) ...<Widget>[
                                    const SizedBox(height: 4),
                                    Text(
                                      item.visitedRetailers.take(3).join(', '),
                                      maxLines: 1,
                                      overflow: TextOverflow.ellipsis,
                                      style: const TextStyle(
                                        fontSize: 12,
                                        fontWeight: FontWeight.w600,
                                      ),
                                    ),
                                  ],
                                ],
                              ),
                            ),
                            _statusPill(context, formatRm(item.totalSales)),
                          ],
                        );
                      },
                    );
                  },
            ),
      ),
    );
  }

  Widget _logsPanel(
    CmsRepository repository,
    Map<String, _SalesmanUser> userIndex,
  ) {
    return CmsPanel(
      title: showAuthLogs ? 'Authentication Events' : 'Activity History',
      trailing: const _SmallChip(label: "Today's chronology"),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: repository.watchCollection(
          showAuthLogs ? 'auth_logs' : 'visit_logs',
        ),
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
            ) {
              final List<Map<String, dynamic>> rows = showAuthLogs
                  ? _scopeAuthLogs(snapshot.data ?? <Map<String, dynamic>>[])
                  : _scopeVisitLogs(
                      snapshot.data ?? <Map<String, dynamic>>[],
                    ).where(_isTodayInKualaLumpur).toList(growable: false);
              rows.sort(
                (Map<String, dynamic> a, Map<String, dynamic> b) =>
                    _sortTimestampValue(b).compareTo(_sortTimestampValue(a)),
              );
              if (rows.isEmpty) {
                if (showAuthLogs
                    ? !collectionRowsComplete(snapshot.data)
                    : !activityCoverage(
                        snapshot.data,
                        _todayStartUtc(),
                      ).location) {
                  return _incompleteActivityCounts();
                }
                return const Padding(
                  padding: EdgeInsets.all(18),
                  child: _EmptyState(
                    icon: ScootIcons.history,
                    title: 'No logs yet',
                    subtitle:
                        'Today\'s submitted score sheets and location updates will appear here. $gpsRetentionNote',
                  ),
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length > 12 ? 12 : rows.length,
                separatorBuilder: (_, _) => const Divider(height: 18),
                itemBuilder: (BuildContext context, int index) {
                  final Map<String, dynamic> item = rows[index];
                  final String time = _formatKualaLumpurTime(
                    item['submittedAt'] ??
                        item['departureTime'] ??
                        item['departure_time'] ??
                        item['arrivalTime'] ??
                        item['arrival_time'] ??
                        item['updatedAt'] ??
                        item['timestamp'],
                  );
                  final String salesmanKey = _salesmanKey(item, userIndex);
                  final Color markerColor = _salesmanColor(salesmanKey);
                  final String source = _safeText(
                    item['sourceCollection'],
                    fallback: '',
                  ).toLowerCase();
                  final String action = source == 'orders'
                      ? 'Submitted score sheet'
                      : source == 'gps_tracking'
                      ? 'Historical GPS sample'
                      : _smartTrackingStatus(item) == 'Visited'
                      ? 'Completed visit'
                      : 'Visit activity';
                  final String orderDocumentId = OrderIdResolver.resolve(item);
                  final bool clickable =
                      orderDocumentId.isNotEmpty &&
                      (source == 'orders' || source == 'visit_logs');
                  final Widget rowContent = Row(
                    children: <Widget>[
                      CircleAvatar(
                        radius: 18,
                        backgroundColor: markerColor.withValues(alpha: 0.14),
                        child: Icon(
                          ScootIcons.place,
                          size: 18,
                          color: markerColor,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              _displaySalesman(item, userIndex),
                              style: const TextStyle(
                                fontWeight: FontWeight.w700,
                              ),
                            ),
                            const SizedBox(height: 4),
                            Text(
                              '$action • ${_safeText(item['retailerName'] ?? item['retailer_id'], fallback: 'Location')} • $time',
                              style: TextStyle(
                                fontSize: 12,
                                color: Theme.of(
                                  context,
                                ).colorScheme.onSurfaceVariant,
                                height: 1.45,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (clickable) ...<Widget>[
                        Icon(
                          ScootIcons.chevronRight,
                          color: Theme.of(context).colorScheme.onSurfaceVariant,
                        ),
                        const SizedBox(width: 4),
                      ],
                      _statusPill(context, _smartTrackingStatus(item)),
                    ],
                  );
                  if (!clickable) return rowContent;
                  return InkWell(
                    borderRadius: BorderRadius.circular(8),
                    onTap: () => OrderDetailsDialog.show(
                      context,
                      orderDocumentId: orderDocumentId,
                      repository: repository,
                      initialOrder: item,
                      currentUser: currentUser,
                      showActions: true,
                    ),
                    child: Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: rowContent,
                    ),
                  );
                },
              );
            },
      ),
    );
  }

  List<_MapPoint> _buildMapPoints(
    List<Map<String, dynamic>> liveRows,
    Map<String, _SalesmanUser> userIndex, {
    List<Map<String, dynamic>> historyRows = const <Map<String, dynamic>>[],
  }) {
    final List<_MapPoint> points = <_MapPoint>[];
    final List<Map<String, dynamic>> completedRows = <Map<String, dynamic>>[];

    for (final Map<String, dynamic> row in liveRows) {
      final LatLng? latLng = _extractLatLng(row);
      if (latLng == null) continue;
      final String key = _salesmanKey(row, userIndex);
      if (key.isEmpty) continue;
      final DateTime? serverReceivedAt = _serverReceiptAt(row);
      final double? accuracy = _numberValue(
        row['accuracyMeters'] ?? row['accuracy'],
      );
      final bool sharingDisabled =
          _matchIndexedUser(row, userIndex)?.gpsSharingEnabled == false;
      final bool current =
          !sharingDisabled &&
          _hasActiveWorkSession(row) &&
          _isLivePositionFresh(row);
      final String details =
          '${sharingDisabled
              ? 'Sharing disabled · last known fix'
              : current
              ? 'Fresh fix'
              : 'Last known fix'} · captured ${_capturedAgeLabel(row)} · '
          '${_hasUsableAccuracy(accuracy) ? accuracyText(accuracy!) : 'accuracy unavailable'} · '
          '${_syncAgeLabel(serverReceivedAt)} · stale after ${_trackingMode(row).staleMinutes} min';
      points.add(
        _MapPoint(
          position: latLng,
          title: _displaySalesman(row, userIndex),
          subtitle: details,
          kind: current ? _MapPointKind.current : _MapPointKind.lastSeen,
          salesmanKey: key,
          uid: _matchIndexedUser(row, userIndex)?.uid ?? '',
          shortSubtitle:
              '${sharingDisabled
                  ? 'Last known'
                  : current
                  ? 'Live'
                  : 'Last known'} · ${_capturedAgeLabel(row)}',
        ),
      );
    }

    for (final Map<String, dynamic> row in historyRows) {
      final String source = _safeText(
        row['sourceCollection'],
        fallback: '',
      ).toLowerCase();
      final String status = _smartTrackingStatus(row);
      final bool completed =
          source == 'orders' || status == 'Visited' || status == 'Completed';
      if (completed && _isTodayInKualaLumpur(row)) completedRows.add(row);
    }

    final Map<String, Map<String, dynamic>> dedupe =
        <String, Map<String, dynamic>>{};
    for (final Map<String, dynamic> row in completedRows) {
      final LatLng? latLng = _extractLatLng(row);
      if (latLng == null) continue;
      final String key =
          '${_salesmanKey(row, userIndex)}:${_safeText(row['retailerId'] ?? row['retailerName'], fallback: 'retailer')}:${_dateKeyKualaLumpur(row)}:${latLng.latitude.toStringAsFixed(5)}:${latLng.longitude.toStringAsFixed(5)}';
      final Map<String, dynamic>? existing = dedupe[key];
      if (existing == null ||
          _sortTimestampValue(row) >= _sortTimestampValue(existing)) {
        dedupe[key] = row;
      }
    }

    final Map<String, List<Map<String, dynamic>>> bySalesman =
        <String, List<Map<String, dynamic>>>{};
    for (final Map<String, dynamic> row in dedupe.values) {
      bySalesman
          .putIfAbsent(
            _salesmanKey(row, userIndex),
            () => <Map<String, dynamic>>[],
          )
          .add(row);
    }
    for (final MapEntry<String, List<Map<String, dynamic>>> entry
        in bySalesman.entries) {
      entry.value.sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            _sortTimestampValue(a).compareTo(_sortTimestampValue(b)),
      );
      for (int i = 0; i < entry.value.length; i++) {
        final Map<String, dynamic> row = entry.value[i];
        final LatLng latLng = _extractLatLng(row)!;
        points.add(
          _MapPoint(
            position: latLng,
            title: _displaySalesman(row, userIndex),
            subtitle: _safeText(
              row['retailerName'] ?? row['retailer_id'],
              fallback: 'Completed order',
            ),
            kind: _MapPointKind.completed,
            salesmanKey: entry.key,
            sequence: i + 1,
          ),
        );
      }
    }

    points.sort(
      (_MapPoint a, _MapPoint b) => a.kind.index.compareTo(b.kind.index),
    );
    return points;
  }

  List<_DailySalesmanSummary> _buildDailySummaries(
    List<Map<String, dynamic>> rows,
    Map<String, _SalesmanUser> userIndex, {
    required bool locationCovered,
    List<Map<String, dynamic>> orders = const <Map<String, dynamic>>[],
  }) {
    final Map<String, _DailySalesmanSummaryBuilder> builders =
        <String, _DailySalesmanSummaryBuilder>{};
    for (final Map<String, dynamic> order in orders) {
      final DateTime? date = orderDateFromRow(order);
      if (!orderCountsAsSale(order) || date == null) continue;
      final DateTime nowKl = DateTime.now().toUtc().add(
        const Duration(hours: 8),
      );
      final DateTime orderKl = date.toUtc().add(const Duration(hours: 8));
      if (nowKl.year != orderKl.year ||
          nowKl.month != orderKl.month ||
          nowKl.day != orderKl.day) {
        continue;
      }
      final String key = _salesmanKey(order, userIndex);
      if (key.isEmpty) continue;
      builders
          .putIfAbsent(
            key,
            () => _DailySalesmanSummaryBuilder(
              key,
              _displaySalesman(order, userIndex),
            ),
          )
          .totalSales += orderRevenue(
        order,
      );
    }
    for (final Map<String, dynamic> row in rows) {
      final String key = _salesmanKey(row, userIndex);
      if (key.isEmpty) continue;
      final _DailySalesmanSummaryBuilder builder = builders.putIfAbsent(
        key,
        () =>
            _DailySalesmanSummaryBuilder(key, _displaySalesman(row, userIndex)),
      );
      final String status = _smartTrackingStatus(row);
      if (_extractLatLng(row) != null) builder.hasLocation = true;
      final String latest = _formatKualaLumpurTime(
        row['updatedAt'] ??
            row['submittedAt'] ??
            row['departureTime'] ??
            row['arrivalTime'] ??
            row['timestamp'],
        fallback: '',
      );
      if (!locationCovered) {
        builder.lastSeenLabel = 'Incomplete location coverage';
      } else if (latest.isNotEmpty &&
          builder.lastSeenLabel == 'No GPS update yet') {
        builder.lastSeenLabel = 'Last activity $latest';
      }
      if (_isTodayInKualaLumpur(row) &&
          (status == 'Visited' ||
              _safeText(row['sourceCollection'], fallback: '') == 'orders')) {
        builder.completedOrders += 1;
        builder.visitedRetailers.add(
          _safeText(
            row['retailerName'] ?? row['retailer_id'],
            fallback: 'Retailer',
          ),
        );
      }
    }
    final List<_DailySalesmanSummary> summaries = builders.values
        .map((_DailySalesmanSummaryBuilder b) => b.build())
        .toList(growable: false);
    summaries.sort(
      (_DailySalesmanSummary a, _DailySalesmanSummary b) =>
          b.completedOrders.compareTo(a.completedOrders),
    );
    return summaries
        .where(
          (_DailySalesmanSummary s) =>
              s.completedOrders > 0 || s.hasLocation || s.totalSales > 0,
        )
        .toList(growable: false);
  }

  String _latestActivityLabel(List<Map<String, dynamic>> rows) {
    DateTime? latest;
    for (final Map<String, dynamic> row in rows) {
      final DateTime? at = _dateForRow(row);
      if (at != null && (latest == null || at.isAfter(latest))) latest = at;
    }
    return latest == null
        ? 'none recorded'
        : _formatKualaLumpurTime(latest, fallback: 'none recorded');
  }

  int _activeSalesmanCount(List<Map<String, dynamic>> rows) {
    final Set<String> active = <String>{};
    for (final Map<String, dynamic> row in rows) {
      if (!_isTodayInKualaLumpur(row)) continue;
      final String key = _salesmanKey(row, <String, _SalesmanUser>{});
      if (key.isNotEmpty) active.add(key);
    }
    return active.length;
  }

  int _historyMarkerCount(List<_MapPoint> points) => points
      .where((_MapPoint point) => point.kind == _MapPointKind.completed)
      .length;

  int _completedTodayCount(List<Map<String, dynamic>> rows) {
    final Set<String> orderKeys = <String>{};
    for (final Map<String, dynamic> row in rows) {
      final String source = _safeText(
        row['sourceCollection'],
        fallback: '',
      ).toLowerCase();
      final String status = _smartTrackingStatus(row);
      final bool isCompleted =
          source == 'orders' || status == 'Visited' || status == 'Completed';
      if (!isCompleted) continue;
      if (!_isTodayInKualaLumpur(row)) continue;
      final String key = OrderIdResolver.completionKey(row);
      if (key.isNotEmpty) orderKeys.add(key);
    }
    return orderKeys.length;
  }

  List<Map<String, dynamic>> _scopeVisitLogs(List<Map<String, dynamic>> logs) {
    return CollectionRows(
      TeamScope.filter(currentUser, logs),
      isComplete: collectionRowsComplete(logs),
      coveredSince: collectionRowsCoverage(logs),
      locationCoverage: collectionRowsLocationCoverage(logs),
    );
  }

  List<Map<String, dynamic>> _scopeAuthLogs(List<Map<String, dynamic>> logs) =>
      logs;

  String _displaySalesman(
    Map<String, dynamic> item,
    Map<String, _SalesmanUser> userIndex,
  ) {
    final _SalesmanUser? user = _matchIndexedUser(item, userIndex);
    if (user != null) return user.name;
    for (final String field in <String>[
      'salesmanName',
      'salesman_name',
      'submittedByName',
      'createdByName',
      'name',
      'displayName',
    ]) {
      final String value = _safeText(item[field], fallback: '');
      if (value.isNotEmpty &&
          !_isUnknown(value) &&
          !_isGenericSalesmanLabel(value)) {
        return value;
      }
    }
    final String id = _safeText(
      item['salesmanId'] ??
          item['salesman_id'] ??
          item['staffId'] ??
          item['email'],
      fallback: '',
    );
    if (id.isNotEmpty && !_isUnknown(id) && !_isGenericSalesmanLabel(id)) {
      return id;
    }
    return 'Unknown Salesman';
  }

  String _salesmanKey(
    Map<String, dynamic> item,
    Map<String, _SalesmanUser> userIndex,
  ) {
    final _SalesmanUser? user = _matchIndexedUser(item, userIndex);
    if (user != null) return user.key;
    final String key = _firstUsefulText(<Object?>[
      item['salesmanUid'],
      item['salesman_uid'],
      item['submittedByUid'],
      item['uid'],
      item['salesmanEmail'],
      item['salesman_email'],
      item['email'],
      item['staffId'],
      item['staff_id'],
      item['employeeCode'],
      item['employee_code'],
      item['salesmanId'],
      item['salesman_id'],
      item['salesmanName'],
      item['salesman_name'],
      item['name'],
    ]);
    return _normaliseKey(key);
  }

  _SalesmanUser? _matchIndexedUser(
    Map<String, dynamic> item,
    Map<String, _SalesmanUser> userIndex,
  ) {
    for (final Object? value in <Object?>[
      item['salesmanUid'],
      item['salesman_uid'],
      item['submittedByUid'],
      item['submittedById'],
      item['uid'],
      item['userId'],
      item['user_id'],
      item['salesmanId'],
      item['salesman_id'],
      item['staffId'],
      item['staff_id'],
      item['employeeCode'],
      item['employee_code'],
      item['salesmanEmail'],
      item['salesman_email'],
      item['email'],
      item['salesmanName'],
      item['salesman_name'],
      item['name'],
    ]) {
      final String key = _normaliseKey(value);
      if (key.isNotEmpty && userIndex.containsKey(key)) return userIndex[key];
    }
    return null;
  }

  String _smartTrackingStatus(Map<String, dynamic> item) {
    if (isSkippedVisit(item)) return 'Skipped';
    final String explicit = _safeText(
      item['trackingStatus'] ?? item['status'],
      fallback: '',
    ).toLowerCase();
    final String source = _safeText(
      item['sourceCollection'],
      fallback: '',
    ).toLowerCase();
    if (source == 'orders') return 'Visited';
    if (source == 'live_tracking') {
      return _hasActiveWorkSession(item) && _isFresh(item)
          ? 'Current'
          : 'Last seen';
    }
    if (source == 'gps_tracking') return 'Location history';
    if (source == 'users') return 'Last seen';
    if (explicit.contains('complete') ||
        explicit.contains('submit') ||
        explicit.contains('done') ||
        explicit.contains('closed') ||
        explicit.contains('visited')) {
      return 'Visited';
    }
    if (explicit.contains('stop') ||
        explicit.contains('inactive') ||
        explicit.contains('last')) {
      return 'Last seen';
    }
    if (explicit.contains('current') ||
        explicit.contains('active') ||
        explicit.contains('track') ||
        explicit.contains('progress') ||
        explicit.contains('arriv')) {
      return _isFresh(item) ? 'Current' : 'Last seen';
    }
    final String departure = _safeText(
      item['departureTime'] ?? item['departure_time'],
      fallback: '',
    );
    if (departure.isNotEmpty) return 'Visited';
    return 'Last seen';
  }

  bool _isFresh(Map<String, dynamic> item) {
    return _safeText(item['sourceCollection'], fallback: '') ==
            'live_tracking' &&
        _isLivePositionFresh(item);
  }

  Color _salesmanColor(String key) {
    const List<Color> palette = DsoTokens.salesmanMapPalette;
    if (key.trim().isEmpty) return palette.first;
    int hash = 0;
    for (final int unit in key.codeUnits) {
      hash = (hash * 31 + unit) & 0x7fffffff;
    }
    return palette[hash % palette.length];
  }

  bool _isTodayInKualaLumpur(Map<String, dynamic> item) {
    final DateTime? dateTime = _dateForRow(item);
    if (dateTime == null) return false;
    final DateTime nowKl = DateTime.now().toUtc().add(const Duration(hours: 8));
    final DateTime itemKl = dateTime.toUtc().add(const Duration(hours: 8));
    return nowKl.year == itemKl.year &&
        nowKl.month == itemKl.month &&
        nowKl.day == itemKl.day;
  }

  DateTime? _dateForRow(Map<String, dynamic> item) {
    if (_safeText(item['sourceCollection'], fallback: '') == 'live_tracking') {
      return _deviceCapturedAt(item);
    }
    return _toDateTime(
      item['submittedAt'] ??
          item['departureTime'] ??
          item['departure_time'] ??
          item['arrivalTime'] ??
          item['arrival_time'] ??
          item['lastSeen'] ??
          item['updatedAt'] ??
          item['createdAt'] ??
          item['timestamp'],
    );
  }

  String _dateKeyKualaLumpur(Map<String, dynamic> item) {
    final DateTime? dateTime = _dateForRow(item);
    if (dateTime == null) return 'unknown-date';
    final DateTime kl = dateTime.toUtc().add(const Duration(hours: 8));
    return '${kl.year}-${_twoDigits(kl.month)}-${_twoDigits(kl.day)}';
  }

  LatLng? _extractLatLng(Map<String, dynamic> item) {
    return readLatLng(item);
  }

  double? _toDouble(Object? value) {
    if (value == null) return null;
    if (value is num) return value.toDouble();
    return double.tryParse(value.toString().replaceAll('RM', '').trim());
  }

  String _formatKualaLumpurTime(Object? value, {String fallback = '—'}) {
    final DateTime? dateTime = _toDateTime(value);
    if (dateTime == null) return fallback;
    final DateTime klTime = dateTime.toUtc().add(const Duration(hours: 8));
    return '${_twoDigits(klTime.day)}/${_twoDigits(klTime.month)}/${klTime.year} ${_twoDigits(klTime.hour)}:${_twoDigits(klTime.minute)} MYT';
  }

  DateTime? _toDateTime(Object? value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is num) {
      final bool millis = value.abs() > 9999999999;
      final num milliseconds = millis ? value : value * 1000;
      return DateTime.fromMillisecondsSinceEpoch(
        milliseconds.round(),
        isUtc: true,
      );
    }
    final String text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return null;
    final RegExp timestampPattern = RegExp(
      r'Timestamp\(seconds=(\d+),\s*nanoseconds=(\d+)\)',
    );
    final RegExpMatch? match = timestampPattern.firstMatch(text);
    if (match != null) {
      final int seconds = int.tryParse(match.group(1) ?? '') ?? 0;
      final int nanoseconds = int.tryParse(match.group(2) ?? '') ?? 0;
      return DateTime.fromMillisecondsSinceEpoch(
        (seconds * 1000) + (nanoseconds ~/ 1000000),
        isUtc: true,
      );
    }
    return DateTime.tryParse(text);
  }

  int _sortTimestampValue(Map<String, dynamic> item) =>
      _dateForRow(item)?.toUtc().microsecondsSinceEpoch ?? 0;
  String _twoDigits(int value) => value.toString().padLeft(2, '0');
  String _safeText(Object? value, {required String fallback}) {
    if (value == null) return fallback;
    final String text = value.toString().trim();
    return text.isEmpty || text.toLowerCase() == 'null' ? fallback : text;
  }

  String _firstUsefulText(List<Object?> values) {
    for (final Object? value in values) {
      final String text = _safeText(value, fallback: '');
      if (text.isNotEmpty && !_isUnknown(text)) return text;
    }
    return '';
  }

  String _normaliseKey(Object? value) => _firstUsefulText(<Object?>[
    value,
  ]).toLowerCase().replaceAll(RegExp(r'[^a-z0-9@._-]'), '');
  bool _isUnknown(String value) {
    final String text = value.trim().toLowerCase();
    return text.isEmpty ||
        text == 'unknown' ||
        text == 'unknown salesman' ||
        text == 'null' ||
        text == 'n/a' ||
        text == 'na' ||
        text == '—' ||
        text == '-';
  }

  bool _isGenericSalesmanLabel(String value) {
    final String text = value.trim().toLowerCase();
    return _isUnknown(text) ||
        text == 'salesman' ||
        text == 'sales representative' ||
        text == 'representative' ||
        text == 'salesperson';
  }

  Map<String, _SalesmanUser> _buildSalesmanUserIndex(
    List<Map<String, dynamic>> users,
  ) {
    final Map<String, _SalesmanUser> index = <String, _SalesmanUser>{};
    for (final Map<String, dynamic> user in users) {
      final String role = _safeText(
        user['role'] ?? user['user_group'],
        fallback: '',
      ).toLowerCase();
      if (role.isNotEmpty &&
          !(role.contains('sales') ||
              role.contains('representative') ||
              role.contains('salesman'))) {
        continue;
      }
      final String name = _firstUsefulText(<Object?>[
        user['name'],
        user['displayName'],
        user['fullName'],
        user['email'],
      ]);
      if (name.isEmpty) continue;
      final String primary = _normaliseKey(
        _firstUsefulText(<Object?>[
          user['uid'],
          user['staffId'],
          user['employeeCode'],
          user['email'],
          user['docId'],
          name,
        ]),
      );
      final String uid = _firstUsefulText(<Object?>[
        user['uid'],
        user['userUid'],
        user['user_uid'],
      ]);
      final String salesmanCode = _firstUsefulText(<Object?>[
        user['employeeCode'],
        user['employee_code'],
        user['staffId'],
        user['staff_id'],
        user['salesmanCode'],
        user['salesman_code'],
      ]);
      final String branchId = _firstUsefulText(<Object?>[
        user['branchId'],
        user['branch_id'],
      ]);
      final bool gpsSharingEnabled = user['gpsAutofill'] != false;
      final _SalesmanUser salesman = _SalesmanUser(
        name: name,
        key: primary.isEmpty ? _normaliseKey(name) : primary,
        uid: uid,
        salesmanCode: salesmanCode,
        branchId: branchId,
        gpsSharingEnabled: gpsSharingEnabled,
      );
      for (final Object? alias in <Object?>[
        user['docId'],
        user['uid'],
        user['userId'],
        user['employeeCode'],
        user['staffId'],
        user['salesmanId'],
        user['email'],
        user['displayName'],
        user['name'],
        user['fullName'],
      ]) {
        final String key = _normaliseKey(alias);
        if (key.isNotEmpty) index[key] = salesman;
      }
    }
    return index;
  }
}

class _LiveTrackingWorkspace extends StatefulWidget {
  const _LiveTrackingWorkspace({
    required this.repository,
    required this.allowedSalesmanUids,
    required this.scopeKey,
    required this.builder,
  });

  final CmsRepository repository;
  final Set<String> allowedSalesmanUids;
  final String scopeKey;
  final Widget Function(BuildContext context, _LiveTrackingView tracking)
  builder;

  @override
  State<_LiveTrackingWorkspace> createState() => _LiveTrackingWorkspaceState();
}

class _LiveTrackingWorkspaceState extends State<_LiveTrackingWorkspace> {
  List<Map<String, dynamic>>? _snapshotRows;
  DateTime? _refreshedAt;
  bool _isRefreshing = false;
  String _snapshotError = '';
  String _selectedUid = '';
  String _streamUid = '';
  Stream<DocumentSnapshot<Map<String, dynamic>>>? _followStream;
  int _requestGeneration = 0;
  Timer? _ageTimer;
  Timer? _autoRefreshTimer;

  @override
  void initState() {
    super.initState();
    if (widget.allowedSalesmanUids.isNotEmpty) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) _refresh();
      });
    }
    _autoRefreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
      if (mounted && !isBrowserTabHidden()) _refresh();
    });
    _ageTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted && (_snapshotRows != null || _selectedUid.isNotEmpty)) {
        setState(() {});
      }
    });
  }

  @override
  void didUpdateWidget(covariant _LiveTrackingWorkspace oldWidget) {
    super.didUpdateWidget(oldWidget);
    final bool scopeChanged =
        oldWidget.scopeKey != widget.scopeKey ||
        oldWidget.allowedSalesmanUids.length !=
            widget.allowedSalesmanUids.length ||
        !oldWidget.allowedSalesmanUids.containsAll(widget.allowedSalesmanUids);
    if (!scopeChanged) return;
    _requestGeneration++;
    _snapshotRows = null;
    _refreshedAt = null;
    _snapshotError = '';
    _isRefreshing = false;
    if (!widget.allowedSalesmanUids.contains(_selectedUid)) {
      _selectedUid = '';
      _streamUid = '';
      _followStream = null;
    }
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted) _refresh();
    });
  }

  @override
  void dispose() {
    _ageTimer?.cancel();
    _autoRefreshTimer?.cancel();
    super.dispose();
  }

  Future<void> _refresh() async {
    if (_isRefreshing) return;
    final int generation = ++_requestGeneration;
    setState(() {
      _isRefreshing = true;
      _snapshotError = '';
    });
    try {
      final List<Map<String, dynamic>> rows = await widget.repository
          .getScopedLiveTrackingSnapshot();
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _snapshotRows = rows;
        _refreshedAt = DateTime.now().toUtc();
        _snapshotError = '';
        _isRefreshing = false;
      });
    } catch (error) {
      if (!mounted || generation != _requestGeneration) return;
      setState(() {
        _snapshotError = userFacingError(
          error,
          action: 'refresh live locations',
        );
        _isRefreshing = false;
      });
    }
  }

  void _follow(String? uid) {
    final String requestedUid = uid?.trim() ?? '';
    final String nextUid = widget.allowedSalesmanUids.contains(requestedUid)
        ? requestedUid
        : '';
    if (_selectedUid == nextUid) return;
    setState(() {
      _selectedUid = nextUid;
      _streamUid = '';
      _followStream = null;
    });
  }

  Stream<DocumentSnapshot<Map<String, dynamic>>> _streamFor(String uid) {
    if (_streamUid != uid || _followStream == null) {
      _streamUid = uid;
      _followStream = widget.repository.watchLiveTrackingPerson(uid);
    }
    return _followStream!;
  }

  _LiveTrackingView _view({
    Map<String, dynamic>? followedRow,
    bool followLoaded = false,
    String followError = '',
  }) {
    final List<Map<String, dynamic>> rows = (_snapshotRows ?? const [])
        .map(
          (Map<String, dynamic> row) => <String, dynamic>{
            ...row,
            'sourceCollection': 'live_tracking',
          },
        )
        .toList(growable: true);
    if (_selectedUid.isNotEmpty && (followLoaded || followedRow != null)) {
      rows.removeWhere((Map<String, dynamic> row) {
        final String uid =
            (row['docId'] ?? row['salesmanUid'] ?? row['salesman_uid'] ?? '')
                .toString()
                .trim();
        return uid == _selectedUid;
      });
      if (followedRow != null) {
        rows.add(<String, dynamic>{
          ...followedRow,
          'docId': _selectedUid,
          'sourceCollection': 'live_tracking',
        });
      }
    }
    return _LiveTrackingView(
      currentRows: List<Map<String, dynamic>>.unmodifiable(rows),
      followedRow: followedRow,
      followLoaded: followLoaded,
      hasSnapshot: _snapshotRows != null,
      refreshedAt: _refreshedAt,
      isRefreshing: _isRefreshing,
      snapshotError: _snapshotError,
      followError: followError,
      selectedUid: _selectedUid,
      refresh: _refresh,
      follow: _follow,
    );
  }

  @override
  Widget build(BuildContext context) {
    if (_selectedUid.isEmpty) return widget.builder(context, _view());
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      key: ValueKey<String>('followed-live-$_selectedUid'),
      stream: _streamFor(_selectedUid),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>> snapshot,
          ) {
            return widget.builder(
              context,
              _view(
                followedRow: snapshot.data?.exists == true
                    ? <String, dynamic>{
                        ...?snapshot.data?.data(),
                        'docId': _selectedUid,
                        'sourceCollection': 'live_tracking',
                      }
                    : null,
                followLoaded: snapshot.hasData,
                followError: snapshot.hasError ? snapshot.error.toString() : '',
              ),
            );
          },
    );
  }
}

class _RetryableStream extends StatefulWidget {
  const _RetryableStream({required this.builder});

  final Widget Function(BuildContext context, VoidCallback retry) builder;

  @override
  State<_RetryableStream> createState() => _RetryableStreamState();
}

class _RetryableStreamState extends State<_RetryableStream> {
  int _attempt = 0;

  @override
  Widget build(BuildContext context) => KeyedSubtree(
    key: ValueKey<int>(_attempt),
    child: widget.builder(context, () => setState(() => _attempt++)),
  );
}

class _LiveTrackingView {
  const _LiveTrackingView({
    required this.currentRows,
    required this.followedRow,
    required this.followLoaded,
    required this.hasSnapshot,
    required this.refreshedAt,
    required this.isRefreshing,
    required this.snapshotError,
    required this.followError,
    required this.selectedUid,
    required this.refresh,
    required this.follow,
  });

  final List<Map<String, dynamic>> currentRows;
  final Map<String, dynamic>? followedRow;
  final bool followLoaded;
  final bool hasSnapshot;
  final DateTime? refreshedAt;
  final bool isRefreshing;
  final String snapshotError;
  final String followError;
  final String selectedUid;
  final Future<void> Function() refresh;
  final ValueChanged<String?> follow;
}

class _TrackingNotice extends StatelessWidget {
  const _TrackingNotice({required this.message});

  final String message;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return ConstrainedBox(
      constraints: const BoxConstraints(maxWidth: 460),
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
        decoration: BoxDecoration(
          color: dso.dangerSoft,
          borderRadius: BorderRadius.circular(12),
          border: Border.all(color: dso.danger.withValues(alpha: 0.4)),
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(ScootIcons.error, size: 16, color: dso.dangerText),
            const SizedBox(width: 8),
            Flexible(
              child: Text(
                message,
                style: TextStyle(fontSize: 12, color: dso.dangerText),
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TrackingControlPanel extends StatefulWidget {
  const _TrackingControlPanel({
    required this.repository,
    required this.currentUser,
    required this.salesmen,
    required this.tracking,
  });

  final CmsRepository repository;
  final UserProfile currentUser;
  final List<_FleetEntry> salesmen;
  final _LiveTrackingView tracking;

  @override
  State<_TrackingControlPanel> createState() => _TrackingControlPanelState();
}

class _TrackingControlPanelState extends State<_TrackingControlPanel> {
  bool _saving = false;
  String _error = '';

  @override
  Widget build(BuildContext context) {
    final List<_FleetEntry> eligible = widget.salesmen
        .where((_FleetEntry entry) => entry.salesmanUid.trim().isNotEmpty)
        .toList(growable: false);
    final Set<String> eligibleUids = eligible
        .map((_FleetEntry entry) => entry.salesmanUid)
        .toSet();
    final String selectedUid =
        eligibleUids.contains(widget.tracking.selectedUid)
        ? widget.tracking.selectedUid
        : '';
    final _FleetEntry? selected = selectedUid.isEmpty
        ? null
        : eligible.firstWhere(
            (_FleetEntry entry) => entry.salesmanUid == selectedUid,
          );
    if (selected == null) return const SizedBox.shrink();
    return StreamBuilder<DocumentSnapshot<Map<String, dynamic>>>(
      stream: widget.repository.watchTrackingControl(selectedUid),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<DocumentSnapshot<Map<String, dynamic>>>
            controlSnapshot,
          ) {
            if (controlSnapshot.hasError) {
              return _controlCard(
                context,
                const Text(
                  'Upload settings are outside your scope or unavailable.',
                  style: TextStyle(fontSize: 12),
                ),
              );
            }
            if (!controlSnapshot.hasData) {
              return _controlCard(context, const LinearProgressIndicator());
            }
            final TrackingControl control;
            try {
              control = TrackingControl.fromDocument(controlSnapshot.data!);
            } on FormatException {
              return _controlCard(
                context,
                const Text(
                  'The saved upload setting is malformed and needs administrator review.',
                  style: TextStyle(fontSize: 12),
                ),
              );
            }
            return _controlCard(
              context,
              Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  DropdownButtonFormField<TrackingUploadMode>(
                    initialValue: control.mode,
                    isExpanded: true,
                    decoration: const InputDecoration(
                      labelText: 'Phone upload mode',
                      isDense: true,
                    ),
                    items: TrackingUploadMode.values
                        .map(
                          (TrackingUploadMode mode) =>
                              DropdownMenuItem<TrackingUploadMode>(
                                value: mode,
                                child: Text(
                                  '${mode.label} · ${mode.cadenceLabel}',
                                ),
                              ),
                        )
                        .toList(growable: false),
                    onChanged: _saving || widget.currentUser.isBranchManager
                        ? null
                        : (TrackingUploadMode? mode) {
                            if (mode != null) {
                              unawaited(_saveMode(selected, mode));
                            }
                          },
                  ),
                  if (widget.currentUser.isBranchManager) ...<Widget>[
                    const SizedBox(height: 6),
                    const Text(
                      'View only. A supervisor or administrator can change the upload mode.',
                      style: TextStyle(fontSize: 12),
                    ),
                  ],
                  const SizedBox(height: 6),
                  _phoneStatus(context, control, widget.tracking),
                  if (_saving) ...<Widget>[
                    const SizedBox(height: 6),
                    const LinearProgressIndicator(),
                  ],
                  if (_error.isNotEmpty) ...<Widget>[
                    const SizedBox(height: 6),
                    Text(
                      _error,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.error,
                      ),
                    ),
                  ],
                ],
              ),
            );
          },
    );
  }

  Future<void> _saveMode(_FleetEntry selected, TrackingUploadMode mode) async {
    setState(() {
      _saving = true;
      _error = '';
    });
    try {
      await widget.repository.setTrackingMode(
        salesmanUid: selected.salesmanUid,
        salesmanCode: selected.salesmanCode,
        branchId: selected.branchId,
        mode: mode,
        actor: widget.currentUser,
      );
    } catch (_) {
      if (mounted) {
        setState(() {
          _error = 'Mode change failed. Refresh and check your assigned scope.';
        });
      }
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Widget _controlCard(BuildContext context, Widget child) {
    final DsoColors dso = context.dso;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dso.surfaceSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: child,
    );
  }

  Widget _phoneStatus(
    BuildContext context,
    TrackingControl control,
    _LiveTrackingView tracking,
  ) {
    final Map<String, dynamic>? live = tracking.followedRow;
    if (!tracking.followLoaded) {
      return const Padding(
        padding: EdgeInsets.only(top: 6),
        child: Text(
          'Waiting for the followed phone status.',
          style: TextStyle(fontSize: 12),
        ),
      );
    }
    final int appliedRevision = live?['appliedControlRevision'] is int
        ? live!['appliedControlRevision'] as int
        : 0;
    final String appliedMode = live?['trackingMode'] is String
        ? live!['trackingMode'] as String
        : TrackingUploadMode.batterySaver.wireValue;
    final bool hasSession = live != null && _hasActiveWorkSession(live);
    final bool acknowledged =
        appliedRevision == control.revision &&
        appliedMode == control.mode.wireValue;
    final String acknowledgement = live == null
        ? 'No phone tracking row exists yet.'
        : !hasSession
        ? 'No work session is open on this phone.'
        : acknowledged
        ? 'Phone acknowledged revision $appliedRevision.'
        : 'Phone has revision $appliedRevision; waiting for ${control.revision}.';
    if (live == null) {
      return Text(
        'Effective setting: ${control.mode.label} · revision ${control.revision}\n$acknowledgement',
        style: TextStyle(
          fontSize: 12,
          color: Theme.of(context).colorScheme.onSurfaceVariant,
        ),
      );
    }
    final double? latitude = _numberValue(
      live['latitude'] ?? live['gpsLatitude'],
    );
    final double? longitude = _numberValue(
      live['longitude'] ?? live['gpsLongitude'],
    );
    final DateTime? serverReceivedAt = _serverReceiptAt(live);
    final bool fresh = _isLivePositionFresh(live);
    final double? accuracy = _numberValue(
      live['accuracyMeters'] ?? live['accuracy'],
    );
    final String positionLabel = latitude == null || longitude == null
        ? (hasSession
              ? 'Waiting for a phone location fix'
              : 'No current phone location')
        : '${fresh && hasSession ? 'Fresh phone fix' : 'Last known fix'} · ${_capturedAgeLabel(live)} · '
              '${latitude.toStringAsFixed(5)}, ${longitude.toStringAsFixed(5)} · '
              '${_hasUsableAccuracy(accuracy) ? accuracyText(accuracy!) : 'accuracy unavailable'}';
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Effective setting: ${control.mode.label} · revision ${control.revision} · $acknowledgement',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            positionLabel,
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
          Text(
            'Server receipt: ${_syncAgeLabel(serverReceivedAt)}',
            style: TextStyle(
              fontSize: 12,
              color: Theme.of(context).colorScheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

double? _numberValue(Object? value) {
  if (value is! num || !value.toDouble().isFinite) return null;
  return value.toDouble();
}

DateTime? _deviceCapturedAt(Map<String, dynamic> row) =>
    _dateValue(row['deviceCapturedAt']);

DateTime? _serverReceiptAt(Map<String, dynamic> row) =>
    _dateValue(row['serverReceivedAt'] ?? row['lastSyncedAt']);

TrackingUploadMode _trackingMode(Map<String, dynamic> row) =>
    TrackingUploadMode.tryParse(row['trackingMode']) ??
    TrackingUploadMode.batterySaver;

bool _hasActiveWorkSession(Map<String, dynamic> row) {
  final Object? sessionId = row['activeSessionId'] ?? row['workSessionId'];
  final String sessionStatus = _workSessionStatus(row);
  return sessionId is String &&
      sessionId.trim().isNotEmpty &&
      (sessionStatus == 'active' || sessionStatus == 'starting') &&
      row['workSessionEndedAt'] == null &&
      row['sessionEndedAt'] == null;
}

bool _hasEndedWorkSession(Map<String, dynamic> row) =>
    _workSessionStatus(row) == 'ended' ||
    row['workSessionEndedAt'] != null ||
    row['sessionEndedAt'] != null;

String _workSessionStatus(Map<String, dynamic> row) =>
    '${row['workSessionStatus'] ?? row['sessionStatus'] ?? row['status'] ?? ''}'
        .trim()
        .toLowerCase();

bool _hasUsableAccuracy(double? accuracy) => accuracy != null && accuracy > 0;

DateTime? _positionTime(Map<String, dynamic> row) =>
    _serverReceiptAt(row) ?? _deviceCapturedAt(row);

Duration? _clockSkew(Map<String, dynamic> row) {
  final DateTime? server = _serverReceiptAt(row);
  final DateTime? device = _deviceCapturedAt(row);
  if (server == null || device == null) return null;
  final Duration skew = device.difference(server);
  return skew.abs() > const Duration(minutes: 2) ? skew : null;
}

bool _isLivePositionFresh(Map<String, dynamic> row) {
  final DateTime? capturedAt = _positionTime(row);
  if (capturedAt == null) return false;
  final Duration age = DateTime.now().toUtc().difference(capturedAt);
  return age >= const Duration(minutes: -2) &&
      age <= Duration(minutes: _trackingMode(row).staleMinutes);
}

String _capturedAgeLabel(Map<String, dynamic> row) {
  final DateTime? positionTime = _positionTime(row);
  if (positionTime == null) return 'capture time unavailable';
  final Duration age = DateTime.now().toUtc().difference(positionTime);
  final String base = age.isNegative
      ? (age >= const Duration(minutes: -2)
            ? 'just now'
            : (_serverReceiptAt(row) == null
                  ? 'phone clock is ahead'
                  : 'server clock mismatch'))
      : '${_durationLabel(age)} ago';
  final Duration? skew = _clockSkew(row);
  if (skew == null) return base;
  return '$base (warning: phone clock is ${_durationLabel(skew.abs())} ${skew.isNegative ? 'behind' : 'ahead of'} the server)';
}

String _clockLabel(DateTime utc) {
  final DateTime local = utc.toUtc().add(const Duration(hours: 8));
  return '${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
}

String _syncAgeLabel(DateTime? lastSyncedAt) {
  if (lastSyncedAt == null) return 'server receipt unavailable';
  final Duration age = DateTime.now().toUtc().difference(lastSyncedAt);
  if (age.isNegative) return 'server receipt time is ahead';
  return 'server received ${_durationLabel(age)} ago';
}

DateTime? _dateValue(Object? value) {
  if (value is Timestamp) return value.toDate().toUtc();
  if (value is DateTime) return value.toUtc();
  return null;
}

String _durationLabel(Duration duration) {
  if (duration.isNegative) return 'clock mismatch';
  if (duration.inDays > 0) return '${duration.inDays} d';
  if (duration.inHours > 0) return '${duration.inHours} h';
  if (duration.inMinutes > 0) return '${duration.inMinutes} min';
  return '${duration.inSeconds} s';
}

enum _MapPointKind { current, lastSeen, completed }

class _MapPoint {
  const _MapPoint({
    required this.position,
    required this.title,
    required this.subtitle,
    required this.kind,
    required this.salesmanKey,
    this.uid = '',
    this.shortSubtitle = '',
    this.sequence = 0,
  });

  final LatLng position;
  final String title;
  final String subtitle;
  final _MapPointKind kind;
  final String salesmanKey;
  final String uid;
  final String shortSubtitle;
  final int sequence;

  String get kindLabel {
    switch (kind) {
      case _MapPointKind.current:
        return 'Fresh';
      case _MapPointKind.lastSeen:
        return 'Last known';
      case _MapPointKind.completed:
        return 'History';
    }
  }
}

class _SalesmanUser {
  const _SalesmanUser({
    required this.name,
    required this.key,
    required this.uid,
    required this.salesmanCode,
    required this.branchId,
    required this.gpsSharingEnabled,
  });
  final String name;
  final String key;
  final String uid;
  final String salesmanCode;
  final String branchId;
  final bool gpsSharingEnabled;
}

class _AssignedPoint {
  const _AssignedPoint({
    required this.position,
    required this.retailerName,
    required this.status,
  });
  final LatLng position;
  final String retailerName;
  final AssignedRetailerStatus status;
}

class _DailySalesmanSummary {
  const _DailySalesmanSummary({
    required this.salesmanKey,
    required this.salesmanName,
    required this.completedOrders,
    required this.visitedRetailers,
    required this.totalSales,
    required this.lastSeenLabel,
    required this.hasLocation,
  });

  final String salesmanKey;
  final String salesmanName;
  final int completedOrders;
  final Set<String> visitedRetailers;
  final double totalSales;
  final String lastSeenLabel;
  final bool hasLocation;

  String get initial => salesmanName.trim().isEmpty
      ? '?'
      : salesmanName.trim().substring(0, 1).toUpperCase();
}

class _DailySalesmanSummaryBuilder {
  _DailySalesmanSummaryBuilder(this.salesmanKey, this.salesmanName);
  final String salesmanKey;
  final String salesmanName;
  int completedOrders = 0;
  double totalSales = 0;
  bool hasLocation = false;
  String lastSeenLabel = 'No GPS update yet';
  final Set<String> visitedRetailers = <String>{};

  _DailySalesmanSummary build() => _DailySalesmanSummary(
    salesmanKey: salesmanKey,
    salesmanName: salesmanName,
    completedOrders: completedOrders,
    visitedRetailers: visitedRetailers,
    totalSales: totalSales,
    lastSeenLabel: lastSeenLabel,
    hasLocation: hasLocation,
  );
}

class _PerformanceBuilder {
  _PerformanceBuilder({required this.salesmanKey, required this.salesmanName});

  final String salesmanKey;
  final String salesmanName;
  int visitsCompleted = 0;
  int ordersSubmitted = 0;
  final Set<String> retailers = <String>{};
  final Set<String> activeDays = <String>{};
  DateTime? lastSync;
  bool hasGps = false;
  int currentPeriodActivity = 0;
  int previousPeriodActivity = 0;

  SalesmanPerformance build(
    DateTime now,
    Color color, {
    required bool locationCovered,
    required bool fullWindow,
  }) {
    final int retailerCoverage = retailers.length;
    final bool scored = locationCovered && fullWindow;
    final bool insufficient =
        visitsCompleted == 0 && ordersSubmitted == 0 && lastSync == null;
    final double conversion = visitsCompleted == 0
        ? 0
        : ordersSubmitted / visitsCompleted;
    final int? daysSinceSync = lastSync == null
        ? null
        : now.difference(lastSync!).inDays;
    final bool freshGps = daysSinceSync != null && daysSinceSync < 2 && hasGps;
    final int trendDelta = currentPeriodActivity - previousPeriodActivity;

    int? score;
    String label;
    String followUp;
    if (insufficient) {
      label = 'Insufficient data';
      followUp =
          'Wait for recent visits or orders before reviewing performance.';
    } else if (daysSinceSync == null || daysSinceSync >= 7 || !hasGps) {
      label = 'No recent sync';
      followUp =
          'Check app sync status, GPS permission, or device connectivity.';
    } else {
      final double visitScore = visitsCompleted >= 12
          ? 25
          : (visitsCompleted / 12) * 25;
      final double orderScore = ordersSubmitted >= 8
          ? 20
          : (ordersSubmitted / 8) * 20;
      final double conversionScore = conversion >= 0.6
          ? 20
          : conversion * 33.33;
      final double coverageScore = retailerCoverage >= 10
          ? 15
          : (retailerCoverage / 10) * 15;
      final double gpsScore = freshGps ? 10 : 4;
      final double trendScore = trendDelta >= 0 ? 10 : 4;
      score =
          (visitScore +
                  orderScore +
                  conversionScore +
                  coverageScore +
                  gpsScore +
                  trendScore)
              .round()
              .clamp(0, 100);
      if (score >= 80) {
        label = 'Excellent activity';
        followUp =
            'Keep the current route rhythm and review high-demand retailers.';
      } else if (score >= 55) {
        label = 'On track';
        followUp =
            'Monitor conversion and retailer coverage in the next cycle.';
      } else {
        label = 'Needs follow-up';
        followUp = conversion < 0.35 && visitsCompleted >= 4
            ? 'Active visits with lower conversion. Review retailer feedback or product availability.'
            : 'Review route assignment, visit plan, and recent sync quality.';
      }
    }

    return SalesmanPerformance(
      salesmanKey: salesmanKey,
      salesmanName: salesmanName,
      visitsCompleted: visitsCompleted,
      ordersSubmitted: ordersSubmitted,
      conversion: conversion,
      retailerCoverage: retailerCoverage,
      gpsSyncStatus: freshGps ? 'Recent sync' : 'Check sync',
      lastSync: lastSync,
      activeDays: activeDays.length,
      trendDelta: scored ? trendDelta : null,
      score: scored ? score : null,
      label: scored
          ? label
          : locationCovered
          ? 'Shorter period'
          : 'Incomplete location coverage',
      recommendedFollowUp: scored
          ? followUp
          : locationCovered
          ? 'Trend and score need the full 28 days and are unavailable.'
          : 'GPS sync, last GPS sync, active days, trend and score are unavailable.',
      color: color,
      locationCovered: locationCovered,
    );
  }
}

class SalesmanPerformance {
  const SalesmanPerformance({
    required this.salesmanKey,
    required this.salesmanName,
    required this.visitsCompleted,
    required this.ordersSubmitted,
    required this.conversion,
    required this.retailerCoverage,
    required this.gpsSyncStatus,
    required this.lastSync,
    required this.activeDays,
    required this.trendDelta,
    required this.score,
    required this.label,
    required this.recommendedFollowUp,
    required this.color,
    required this.locationCovered,
  });

  final bool locationCovered;
  final String salesmanKey;
  final String salesmanName;
  final int visitsCompleted;
  final int ordersSubmitted;
  final double conversion;
  final int retailerCoverage;
  final String gpsSyncStatus;
  final DateTime? lastSync;
  final int activeDays;
  final int? trendDelta;
  final int? score;
  final String label;
  final String recommendedFollowUp;
  final Color color;

  List<(String, String)> get figures => <(String, String)>[
    ('Visits completed', '$visitsCompleted'),
    ('Orders submitted', '$ordersSubmitted'),
    ('Conversion', conversionText),
    ('Retailer coverage', '$retailerCoverage'),
    if (locationCovered) ...<(String, String)>[
      ('GPS sync', gpsSyncStatus),
      ('Last GPS sync', lastSyncText),
      ('Active days', '$activeDays'),
    ],
    if (trendDelta != null) ('Trend', trendText),
    if (score != null) ('Score', '$score/100'),
  ];

  String get initial => salesmanName.trim().isEmpty
      ? '?'
      : salesmanName.trim().substring(0, 1).toUpperCase();
  String get conversionText =>
      visitsCompleted == 0 ? '-' : '${(conversion * 100).round()}%';
  String get trendText {
    final int delta = trendDelta ?? 0;
    return delta == 0
        ? 'Flat'
        : delta > 0
        ? '+$delta'
        : '$delta';
  }

  String get lastSyncText {
    if (lastSync == null) return 'No recent sync';
    final DateTime klTime = lastSync!.toUtc().add(const Duration(hours: 8));
    return '${klTime.day.toString().padLeft(2, '0')}/${klTime.month.toString().padLeft(2, '0')} ${klTime.hour.toString().padLeft(2, '0')}:${klTime.minute.toString().padLeft(2, '0')} MYT';
  }
}

Widget _performanceMetric(BuildContext context, String label, String value) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
    decoration: BoxDecoration(
      color: scheme.surfaceContainerHighest,
      borderRadius: BorderRadius.circular(999),
      border: Border.all(color: scheme.outlineVariant),
    ),
    child: Text(
      '$label: $value',
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: scheme.onSurfaceVariant,
      ),
    ),
  );
}

class _AssignedMissingNote extends StatelessWidget {
  const _AssignedMissingNote({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: context.dso.warningSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.dso.warning.withValues(alpha: 0.45)),
      ),
      child: Text(
        '$count assigned retailer(s) have no map coordinates yet, so they are '
        'planned but not plotted here.',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.dso.warningText,
        ),
      ),
    );
  }
}

class _SmallChip extends StatelessWidget {
  const _SmallChip({required this.label});
  final String label;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: dark ? DsoTokens.successSurfaceDark : DsoTokens.successSoft,
        borderRadius: BorderRadius.circular(DsoTokens.rPill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          color: dark ? DsoTokens.successTextDark : DsoTokens.successText,
          fontWeight: FontWeight.w700,
        ),
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(12),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 34, color: scheme.primary),
            const SizedBox(height: 8),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700, fontSize: 16),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 14,
                color: scheme.onSurfaceVariant,
                height: 1.45,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _MissingGpsNote extends StatelessWidget {
  const _MissingGpsNote({required this.count});
  final int count;

  @override
  Widget build(BuildContext context) {
    return Container(
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: context.dso.warningSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.dso.warning.withValues(alpha: 0.45)),
      ),
      child: Text(
        '$count activity row(s) are missing GPS/retailer coordinates, so they are listed in the report but not plotted on the map.',
        maxLines: 2,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: context.dso.warningText,
        ),
      ),
    );
  }
}

class _CurrentWeekPlans extends StatefulWidget {
  const _CurrentWeekPlans({
    required this.currentUser,
    required this.people,
    required this.builder,
  });

  final UserProfile currentUser;
  final List<_SalesmanUser> people;
  final Widget Function(BuildContext, List<Map<String, dynamic>>?, bool)
  builder;

  @override
  State<_CurrentWeekPlans> createState() => _CurrentWeekPlansState();
}

class _CurrentWeekPlansState extends State<_CurrentWeekPlans> {
  List<Map<String, dynamic>>? _rows;
  bool _failed = false;
  String _loadedFor = '';

  List<String> get _codes =>
      (widget.people
            .map((_SalesmanUser p) => p.salesmanCode.trim())
            .where((String c) => c.isNotEmpty)
            .toSet()
            .toList())
        ..sort();

  @override
  void initState() {
    super.initState();
    _maybeLoad();
  }

  @override
  void didUpdateWidget(_CurrentWeekPlans oldWidget) {
    super.didUpdateWidget(oldWidget);
    _maybeLoad();
  }

  void _maybeLoad() {
    final List<String> codes = _codes;
    final String signature = codes.join(',');
    if (signature == _loadedFor) return;
    _loadedFor = signature;
    if (codes.isEmpty) {
      _rows = null;
      _failed = false;
      return;
    }
    unawaited(_load(codes, signature));
  }

  Future<void> _load(List<String> codes, String signature) async {
    final DateTime week = malaysiaWeekStart(DateTime.now());
    final DateTime bound = week.subtract(const Duration(hours: 32));
    final String branch = widget.currentUser.branchId.trim();
    final bool branchScoped = widget.currentUser.isBranchManager;
    if (!AppRuntime.firebaseReady) return;
    final FirebaseFirestore db = FirebaseFirestore.instance;
    bool failed = false;
    List<Map<String, dynamic>> weekRows(
      QuerySnapshot<Map<String, dynamic>> snap,
    ) {
      return snap.docs
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> d) =>
                <String, dynamic>{'docId': d.id, ...d.data()},
          )
          .where((Map<String, dynamic> row) {
            final DateTime? start = parseTeamTimestamp(row['weekStart']);
            return start != null && malaysiaWeekStart(start) == week;
          })
          .toList(growable: false);
    }

    Query<Map<String, dynamic>> inWeek(Query<Map<String, dynamic>> query) {
      return query
          .where('weekStart', isGreaterThanOrEqualTo: Timestamp.fromDate(bound))
          .orderBy('weekStart', descending: true);
    }

    Future<List<Map<String, dynamic>>> readForCode(String code) async {
      try {
        Query<Map<String, dynamic>> query = db
            .collection('route_plans')
            .where('salesmanCode', isEqualTo: code);
        if (branchScoped && branch.isNotEmpty) {
          query = query.where('branchId', isEqualTo: branch);
        }
        return weekRows(await inWeek(query).get());
      } catch (_) {
        failed = true;
        return const <Map<String, dynamic>>[];
      }
    }

    Future<List<Map<String, dynamic>>> readForCodes(List<String> chunk) async {
      try {
        final Set<String> wanted = chunk.toSet();
        final List<Map<String, dynamic>> rows = weekRows(
          await inWeek(
            db.collection('route_plans').where('salesmanCode', whereIn: chunk),
          ).get(),
        );
        return rows
            .where(
              (Map<String, dynamic> row) =>
                  wanted.contains('${row['salesmanCode'] ?? ''}'),
            )
            .toList(growable: false);
      } catch (_) {
        final List<List<Map<String, dynamic>>> each = await Future.wait(
          chunk.map(readForCode),
        );
        return each.expand((List<Map<String, dynamic>> r) => r).toList();
      }
    }

    Future<List<Map<String, dynamic>>> readForAdmin() async {
      try {
        final Set<String> wanted = codes.toSet();
        final List<Map<String, dynamic>> rows = weekRows(
          await inWeek(db.collection('route_plans')).get(),
        );
        return rows
            .where(
              (Map<String, dynamic> row) =>
                  wanted.contains('${row['salesmanCode'] ?? ''}'),
            )
            .toList(growable: false);
      } catch (_) {
        final List<List<Map<String, dynamic>>> each = await Future.wait(
          codes.map(readForCode),
        );
        return each.expand((List<Map<String, dynamic>> r) => r).toList();
      }
    }

    final List<List<Map<String, dynamic>>> perPerson =
        widget.currentUser.isAdmin
        ? <List<Map<String, dynamic>>>[await readForAdmin()]
        : widget.currentUser.isSupervisor
        ? await Future.wait(chunkFirestoreWhereIn(codes).map(readForCodes))
        : await Future.wait(codes.map(readForCode));
    if (!mounted || signature != _loadedFor) return;
    setState(() {
      _rows = perPerson.expand((r) => r).toList();
      _failed = failed;
    });
  }

  @override
  Widget build(BuildContext context) => widget.builder(context, _rows, _failed);
}

class _NoLiveLocationNote extends StatelessWidget {
  const _NoLiveLocationNote({required this.lastActivity});
  final String lastActivity;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      key: const ValueKey<String>('no-live-location-note'),
      constraints: const BoxConstraints(maxWidth: 460),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 9),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: dso.hairline),
      ),
      child: Text(
        'No live location today; last activity $lastActivity',
        style: TextStyle(fontSize: 12, color: dso.body),
      ),
    );
  }
}

Widget _statusPill(BuildContext context, String label) {
  final ColorScheme scheme = Theme.of(context).colorScheme;
  final bool dark = scheme.brightness == Brightness.dark;
  final bool money = label.startsWith('RM');
  final bool active =
      label.toLowerCase().contains('current') ||
      label.toLowerCase().contains('active');
  final bool success = money || active;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
    decoration: BoxDecoration(
      color: success
          ? (dark ? DsoTokens.successSurfaceDark : DsoTokens.successSoft)
          : (dark ? DsoTokens.infoSurfaceDark : DsoTokens.infoSoft),
      borderRadius: BorderRadius.circular(DsoTokens.rPill),
    ),
    child: Text(
      label,
      style: TextStyle(
        fontSize: 12,
        fontWeight: FontWeight.w700,
        color: success
            ? (dark ? DsoTokens.successTextDark : DsoTokens.successText)
            : (dark ? DsoTokens.infoTextDark : DsoTokens.infoText),
      ),
    ),
  );
}

class _UnresolvedAssignmentsNotice extends StatelessWidget {
  const _UnresolvedAssignmentsNotice({required this.codes});

  final List<String> codes;

  static String _caseVariant(String code) =>
      code == code.toLowerCase() ? code.toUpperCase() : code.toLowerCase();

  @override
  Widget build(BuildContext context) {
    if (codes.isEmpty) return const SizedBox.shrink();
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(bottom: 14),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.tertiaryContainer,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(ScootIcons.person, color: scheme.onTertiaryContainer),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              '${codes.length} assigned salesperson code${codes.length == 1 ? '' : 's'} '
              'ha${codes.length == 1 ? 's' : 've'} no visible profile: ${codes.join(', ')}. '
              'Possible case mismatch: ${codes.map((String c) => '${_caseVariant(c)} vs $c').join(', ')} '
              '- ask an admin to fix. '
              'Team activity includes visible profiles only.',
              style: TextStyle(
                fontSize: 12.5,
                height: 1.45,
                color: scheme.onTertiaryContainer,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _TrackingTabs extends StatelessWidget {
  const _TrackingTabs();

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    Tab tab(IconData icon, String label) => Tab(
      height: 44,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 18),
          const SizedBox(width: 8),
          Text(label),
        ],
      ),
    );
    return TabBar(
      isScrollable: true,
      tabAlignment: TabAlignment.start,
      dividerColor: dso.hairline,
      indicatorColor: dso.accent,
      labelColor: dso.accentText,
      unselectedLabelColor: dso.muted,
      labelStyle: const TextStyle(fontSize: 14, fontWeight: FontWeight.w700),
      unselectedLabelStyle: const TextStyle(
        fontSize: 14,
        fontWeight: FontWeight.w500,
      ),
      tabs: <Tab>[
        tab(ScootIcons.locationSearching, 'Live Status'),
        tab(ScootIcons.reports, 'Salesman Performance'),
        tab(ScootIcons.badge, 'Coaching Scorecard'),
      ],
    );
  }
}

class _TimelineItem {
  const _TimelineItem({
    required this.timeLabel,
    required this.title,
    required this.outcome,
    required this.orderDocumentId,
    required this.row,
  });

  final String timeLabel;
  final String title;
  final String outcome;
  final String orderDocumentId;
  final Map<String, dynamic> row;
}

class _CommandData {
  const _CommandData({
    required this.historyComplete,
    required this.locationComplete,
    required this.entries,
    required this.points,
    required this.assignedPoints,
    required this.missingAssigned,
    required this.missingTodayCount,
    required this.selectedKey,
    required this.selected,
    required this.timeline,
    required this.routeKm,
    required this.lastActivityLabel,
    required this.activeToday,
    required this.completedToday,
    required this.markerCount,
  });

  final List<_FleetEntry> entries;
  final bool historyComplete;
  final bool locationComplete;
  final List<_MapPoint> points;
  final List<_AssignedPoint> assignedPoints;
  final int missingAssigned;
  final int missingTodayCount;
  final String? selectedKey;
  final _FleetEntry? selected;
  final List<_TimelineItem> timeline;
  final double? routeKm;
  final String lastActivityLabel;
  final int activeToday;
  final int completedToday;
  final int markerCount;

  List<_MapPoint> get visiblePoints => selectedKey == null
      ? points
      : points
            .where((_MapPoint p) => p.salesmanKey == selectedKey)
            .toList(growable: false);

  bool get hasVehicle =>
      visiblePoints.any((_MapPoint p) => p.kind != _MapPointKind.completed);

  List<LatLng> get coordinates => <LatLng>[
    ...visiblePoints.map((_MapPoint p) => p.position),
    ...assignedPoints.map((_AssignedPoint a) => a.position),
  ];
}

class _CommandCentre extends StatefulWidget {
  const _CommandCentre({
    required this.data,
    required this.tracking,
    required this.repository,
    required this.currentUser,
    required this.wide,
    required this.drawerWidth,
    required this.historyLoading,
    required this.historyError,
    required this.plansError,
    required this.onRetryHistory,
    required this.colorForKey,
    required this.onOpenOrder,
  });

  final VoidCallback onRetryHistory;
  final _CommandData data;
  final _LiveTrackingView tracking;
  final CmsRepository repository;
  final UserProfile currentUser;
  final bool wide;
  final double drawerWidth;
  final bool historyLoading;
  final bool historyError;
  final bool plansError;
  final Color Function(String key) colorForKey;
  final ValueChanged<_TimelineItem> onOpenOrder;

  @override
  State<_CommandCentre> createState() => _CommandCentreState();
}

class _CommandCentreState extends State<_CommandCentre> {
  final Set<FleetStatusGroup> _groups = <FleetStatusGroup>{};
  final ValueNotifier<String?> _hovered = ValueNotifier<String?>(null);
  String _query = '';

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  void _toggleUid(String uid) =>
      widget.tracking.follow(widget.tracking.selectedUid == uid ? null : uid);

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final _CommandData data = widget.data;
    final List<_FleetEntry> visible = data.entries
        .where(
          (_FleetEntry e) => fleetEntryMatches(
            statusKind: e.statusKind,
            name: e.name,
            lastLocation: e.lastLocation,
            groups: _groups,
            query: _query,
          ),
        )
        .toList(growable: false);
    final Widget rail = _FleetRail(
      all: data.entries,
      visible: visible,
      groups: _groups,
      selectedUid: widget.tracking.selectedUid,
      loading: widget.historyLoading,
      error: widget.historyError,
      onQuery: (String value) => setState(() => _query = value),
      onToggleGroup: (FleetStatusGroup group) => setState(() {
        if (!_groups.remove(group)) _groups.add(group);
      }),
      onSelect: _toggleUid,
      onRetry: widget.onRetryHistory,
    );
    final _FleetEntry? selected = data.selected;
    final Widget? drawer = selected == null
        ? null
        : _SalesmanDrawer(
            key: ValueKey<String>('drawer-${selected.salesmanUid}'),
            entry: selected,
            data: data,
            repository: widget.repository,
            currentUser: widget.currentUser,
            tracking: widget.tracking,
            onOpenOrder: widget.onOpenOrder,
            scrollable: widget.wide,
          );
    final Widget map = _CommandMap(
      data: data,
      tracking: widget.tracking,
      hovered: _hovered,
      colorForKey: widget.colorForKey,
      onSelectUid: _toggleUid,
      wide: widget.wide,
      drawer: widget.wide ? drawer : null,
      drawerWidth: widget.drawerWidth,
      historyError: widget.historyError,
      plansError: widget.plansError,
      loadingHistory: widget.historyLoading,
    );
    final BorderRadius radius = BorderRadius.circular(18);
    if (widget.wide) {
      return CallbackShortcuts(
        bindings: <ShortcutActivator, VoidCallback>{
          const SingleActivator(LogicalKeyboardKey.escape): () =>
              widget.tracking.follow(null),
        },
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: dso.card,
            borderRadius: radius,
            border: Border.all(color: dso.hairline),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 340, child: rail),
                VerticalDivider(width: 1, color: dso.hairline),
                Expanded(child: map),
              ],
            ),
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ClipRRect(
          borderRadius: radius,
          child: SizedBox(height: 460, child: map),
        ),
        if (drawer != null) ...<Widget>[const SizedBox(height: 16), drawer],
        const SizedBox(height: 16),
        DecoratedBox(
          decoration: BoxDecoration(
            color: dso.card,
            borderRadius: radius,
            border: Border.all(color: dso.hairline),
          ),
          child: ClipRRect(
            borderRadius: radius,
            child: SizedBox(height: 480, child: rail),
          ),
        ),
      ],
    );
  }
}

class _CommandMap extends StatefulWidget {
  const _CommandMap({
    required this.data,
    required this.tracking,
    required this.hovered,
    required this.colorForKey,
    required this.onSelectUid,
    required this.wide,
    required this.drawer,
    required this.drawerWidth,
    required this.historyError,
    required this.plansError,
    required this.loadingHistory,
  });

  final _CommandData data;
  final _LiveTrackingView tracking;
  final ValueNotifier<String?> hovered;
  final Color Function(String key) colorForKey;
  final ValueChanged<String> onSelectUid;
  final bool wide;
  final Widget? drawer;
  final double drawerWidth;
  final bool historyError;
  final bool plansError;
  final bool loadingHistory;

  @override
  State<_CommandMap> createState() => _CommandMapState();
}

class _CommandMapState extends State<_CommandMap> {
  static const Duration _mapLoadTimeout = Duration(seconds: 2);
  static const LatLng _kuchingCenter = LatLng(1.5533, 110.3593);

  final MapController _controller = MapController();
  bool _showMap = false;
  bool _mapReady = false;
  bool _timedOut = false;
  Timer? _timeoutTimer;
  String _fitSignature = '';

  bool get _drawerOpen => widget.wide && widget.drawer != null;

  EdgeInsets get _fitPadding => EdgeInsets.fromLTRB(
    56,
    104,
    _drawerOpen ? widget.drawerWidth + 56 : 56,
    72,
  );

  @override
  void initState() {
    super.initState();
    _fitSignature = _signature();
    _beginLoad();
  }

  String _signature() =>
      '${widget.data.selectedKey}|${widget.data.coordinates.length}';

  void _beginLoad() {
    _timeoutTimer?.cancel();
    _showMap = false;
    _mapReady = false;
    _timedOut = false;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      setState(() => _showMap = true);
    });
    _timeoutTimer = Timer(_mapLoadTimeout, () {
      if (!mounted || _mapReady) return;
      setState(() => _timedOut = true);
    });
  }

  void _handleMapReady() {
    _timeoutTimer?.cancel();
    if (!mounted || (_mapReady && !_timedOut)) return;
    setState(() {
      _mapReady = true;
      _timedOut = false;
    });
  }

  @override
  void didUpdateWidget(covariant _CommandMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    final String signature = _signature();
    if (signature == _fitSignature) return;
    _fitSignature = signature;
    if (!_mapReady) return;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (mounted && _mapReady) _fit();
    });
  }

  void _fit() {
    final List<LatLng> coordinates = widget.data.coordinates;
    if (coordinates.length > 1) {
      _controller.fitCamera(
        CameraFit.coordinates(
          coordinates: coordinates,
          padding: _fitPadding,
          maxZoom: 15,
        ),
      );
    } else if (coordinates.length == 1) {
      _controller.move(coordinates.first, 15);
    } else {
      _controller.move(_kuchingCenter, 12);
    }
  }

  void _zoom(double delta) {
    if (!_mapReady) return;
    final MapCamera camera = _controller.camera;
    _controller.move(camera.center, camera.zoom + delta);
  }

  void _hover(String id, bool hovering) {
    if (hovering) {
      widget.hovered.value = id;
    } else if (widget.hovered.value == id) {
      widget.hovered.value = null;
    }
  }

  @override
  void dispose() {
    _timeoutTimer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  List<Marker> _markers(DsoColors dso) {
    final _CommandData data = widget.data;
    final List<Marker> markers = <Marker>[];
    final List<_MapPoint> points = data.visiblePoints;
    for (int i = 0; i < data.assignedPoints.length; i++) {
      final _AssignedPoint a = data.assignedPoints[i];
      final (Color color, IconData icon) = switch (a.status) {
        AssignedRetailerStatus.completed => (dso.success, ScootIcons.check),
        AssignedRetailerStatus.skipped => (dso.subtle, ScootIcons.rejected),
        AssignedRetailerStatus.missingCoordinates => (
          dso.subtle,
          ScootIcons.help,
        ),
        AssignedRetailerStatus.pending => (dso.info, ScootIcons.store),
      };
      final String id = 'a:$i';
      markers.add(
        Marker(
          point: a.position,
          width: 34,
          height: 34,
          child: TrackingMarkerButton(
            semanticLabel: 'Assigned stop ${a.retailerName}',
            onHover: (bool h) => _hover(id, h),
            child: StopBadge(color: color, icon: icon, size: 28),
          ),
        ),
      );
    }
    for (final _MapPoint p in points) {
      if (p.kind != _MapPointKind.completed) continue;
      final String id = 'h:${p.salesmanKey}:${p.sequence}';
      markers.add(
        Marker(
          point: p.position,
          width: 30,
          height: 30,
          child: TrackingMarkerButton(
            semanticLabel: 'Visit ${p.sequence}, ${p.subtitle}, ${p.title}',
            onHover: (bool h) => _hover(id, h),
            child: StopBadge(
              color: widget.colorForKey(p.salesmanKey),
              number: p.sequence,
              size: 28,
            ),
          ),
        ),
      );
    }
    for (final _MapPoint p in points) {
      if (p.kind == _MapPointKind.completed) continue;
      final bool selected = p.salesmanKey == data.selectedKey;
      final String id = 'v:${p.salesmanKey}';
      markers.add(
        Marker(
          point: p.position,
          width: 56,
          height: 56,
          child: TrackingMarkerButton(
            semanticLabel:
                '${p.title}, ${p.kindLabel}. '
                '${selected ? 'Selected' : 'Select to follow'}',
            selected: selected,
            onTap: p.uid.isEmpty ? null : () => widget.onSelectUid(p.uid),
            onHover: (bool h) => _hover(id, h),
            child: VehicleBadge(
              color: widget.colorForKey(p.salesmanKey),
              live: p.kind == _MapPointKind.current,
              selected: selected,
            ),
          ),
        ),
      );
    }
    return markers;
  }

  List<MapLabelSpec> _labels() {
    final _CommandData data = widget.data;
    return <MapLabelSpec>[
      for (final _MapPoint p in data.visiblePoints)
        if (p.kind == _MapPointKind.completed)
          MapLabelSpec(
            id: 'h:${p.salesmanKey}:${p.sequence}',
            point: p.position,
            title: p.subtitle,
            subtitle: 'Visit ${p.sequence} · ${p.title}',
          )
        else
          MapLabelSpec(
            id: 'v:${p.salesmanKey}',
            point: p.position,
            title: p.title,
            subtitle: p.shortSubtitle,
          ),
      for (int i = 0; i < data.assignedPoints.length; i++)
        MapLabelSpec(
          id: 'a:$i',
          point: data.assignedPoints[i].position,
          title: data.assignedPoints[i].retailerName,
          subtitle: switch (data.assignedPoints[i].status) {
            AssignedRetailerStatus.completed => 'Assigned stop · completed',
            AssignedRetailerStatus.skipped => 'Assigned stop · skipped',
            AssignedRetailerStatus.missingCoordinates => 'Assigned stop',
            AssignedRetailerStatus.pending => 'Assigned stop · pending',
          },
        ),
    ];
  }

  List<Polyline<Object>> _routes() {
    final _CommandData data = widget.data;
    final String? key = data.selectedKey;
    if (key == null) return const <Polyline<Object>>[];
    final Color color = widget.colorForKey(key);
    final List<LatLng> history = data.visiblePoints
        .where((_MapPoint p) => p.kind == _MapPointKind.completed)
        .map((_MapPoint p) => p.position)
        .toList(growable: false);
    return <Polyline<Object>>[
      if (history.length > 1)
        Polyline<Object>(
          points: history,
          color: color.withValues(alpha: 0.55),
          strokeWidth: 3,
          pattern: StrokePattern.dashed(segments: const <double>[8, 8]),
        ),
      if (data.assignedPoints.length > 1)
        Polyline<Object>(
          points: data.assignedPoints
              .map((_AssignedPoint point) => point.position)
              .toList(growable: false),
          color: color.withValues(alpha: 0.85),
          strokeWidth: 5,
          borderColor: Colors.white.withValues(alpha: 0.95),
          borderStrokeWidth: 2,
        ),
    ];
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final _CommandData data = widget.data;
    final _LiveTrackingView tracking = widget.tracking;
    if (_timedOut && !_mapReady) {
      return _MapTimeoutFallback(
        points: data.visiblePoints,
        colorForKey: widget.colorForKey,
        onRetry: () => setState(_beginLoad),
      );
    }
    final List<LatLng> coordinates = data.coordinates;
    final List<Polyline<Object>> routes = _routes();
    final EdgeInsets labelSafe = EdgeInsets.fromLTRB(
      16,
      104,
      _drawerOpen ? widget.drawerWidth + 32 : 16,
      56,
    );
    final bool showLoadPrompt =
        !tracking.hasSnapshot && !data.hasVehicle && data.selectedKey == null;
    final bool compactPrompt = MediaQuery.sizeOf(context).width < 600;
    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        ColoredBox(color: dso.surfaceSoft),
        if (_showMap)
          SelectionContainer.disabled(
            child: RepaintBoundary(
              child: FlutterMap(
                mapController: _controller,
                options: MapOptions(
                  onMapReady: _handleMapReady,
                  initialCenter: coordinates.length == 1
                      ? coordinates.first
                      : _kuchingCenter,
                  initialZoom: coordinates.length == 1 ? 15 : 12,
                  initialCameraFit: coordinates.length > 1
                      ? CameraFit.coordinates(
                          coordinates: coordinates,
                          padding: _fitPadding,
                          maxZoom: 15,
                        )
                      : null,
                  interactionOptions: const InteractionOptions(
                    flags: InteractiveFlag.all & ~InteractiveFlag.rotate,
                  ),
                ),
                children: <Widget>[
                  GeoapifyConfig.lightTileLayer(),
                  if (routes.isNotEmpty)
                    PolylineLayer<Object>(polylines: routes),
                  MarkerLayer(markers: _markers(dso)),
                  MapLabelLayer(
                    labels: _labels(),
                    hoveredId: widget.hovered,
                    pinnedIds: data.selectedKey == null
                        ? const <String>{}
                        : <String>{'v:${data.selectedKey}'},
                    safe: labelSafe,
                  ),
                  const GeoapifyMapAttribution(),
                ],
              ),
            ),
          ),
        if (!_mapReady)
          ColoredBox(
            color: dso.surfaceSoft,
            child: Center(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  SizedBox(
                    width: 26,
                    height: 26,
                    child: CircularProgressIndicator(
                      strokeWidth: 3,
                      valueColor: AlwaysStoppedAnimation<Color>(dso.accent),
                    ),
                  ),
                  const SizedBox(height: 10),
                  Text(
                    'Loading map…',
                    style: TextStyle(fontSize: 12, color: dso.muted),
                  ),
                ],
              ),
            ),
          ),
        if (widget.loadingHistory)
          const Positioned(
            left: 0,
            right: 0,
            top: 0,
            child: LinearProgressIndicator(minHeight: 3),
          ),
        Positioned(
          left: 16,
          top: 16,
          right: 16,
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Wrap(
                alignment: WrapAlignment.spaceBetween,
                crossAxisAlignment: WrapCrossAlignment.start,
                spacing: 12,
                runSpacing: 8,
                children: <Widget>[
                  TrackingKpiStrip(
                    kpis: <TrackingKpi>[
                      if (data.historyComplete) ...<TrackingKpi>[
                        if (data.locationComplete)
                          TrackingKpi(
                            label: 'Active today',
                            value: data.activeToday,
                            icon: ScootIcons.team,
                          ),
                        TrackingKpi(
                          label: 'Visits done',
                          value: data.completedToday,
                          icon: ScootIcons.success,
                        ),
                      ],
                    ],
                  ),
                  _RefreshPill(tracking: tracking),
                ],
              ),
              if (!data.historyComplete) ...<Widget>[
                const SizedBox(height: 8),
                const _TrackingNotice(
                  message:
                      'Incomplete activity coverage — today\'s visit counts are unavailable.',
                ),
              ],
              if (data.historyComplete && !data.locationComplete) ...<Widget>[
                const SizedBox(height: 8),
                const _TrackingNotice(
                  message:
                      'Incomplete location coverage — the active count for today is unavailable.',
                ),
              ],
              if (tracking.snapshotError.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                _TrackingNotice(
                  message: tracking.hasSnapshot
                      ? 'Refresh failed. Showing the previous scoped snapshot. ${tracking.snapshotError}'
                      : 'Scoped location snapshot unavailable. ${tracking.snapshotError}',
                ),
              ],
              if (tracking.followError.isNotEmpty) ...<Widget>[
                const SizedBox(height: 8),
                const _TrackingNotice(
                  message:
                      'The followed phone location is unavailable. The map keeps its last manually refreshed position.',
                ),
              ],
              if (widget.historyError) ...<Widget>[
                const SizedBox(height: 8),
                const _TrackingNotice(
                  message:
                      'Visit and order history could not be loaded. Check your connection and retry.',
                ),
              ],
              if (widget.plansError) ...<Widget>[
                const SizedBox(height: 8),
                const _TrackingNotice(
                  message:
                      "This week's route plans could not be loaded for everyone, so some route progress is missing. Reload the page to try again.",
                ),
              ],
              if (data.selectedKey == null &&
                  tracking.hasSnapshot &&
                  !data.points.any(
                    (_MapPoint p) => p.kind == _MapPointKind.current,
                  )) ...<Widget>[
                const SizedBox(height: 8),
                _NoLiveLocationNote(lastActivity: data.lastActivityLabel),
              ],
              if (data.selectedKey == null &&
                  data.missingTodayCount > 0) ...<Widget>[
                const SizedBox(height: 8),
                _MissingGpsNote(count: data.missingTodayCount),
              ],
              if (data.selectedKey != null &&
                  data.missingAssigned > 0) ...<Widget>[
                const SizedBox(height: 8),
                _AssignedMissingNote(count: data.missingAssigned),
              ],
            ],
          ),
        ),
        if (showLoadPrompt && compactPrompt)
          Positioned(
            right: 16,
            bottom: 16,
            child: FilledButton.icon(
              onPressed: tracking.isRefreshing
                  ? null
                  : () => unawaited(tracking.refresh()),
              icon: const Icon(ScootIcons.refresh, size: 18),
              label: const Text('Load positions'),
            ),
          )
        else if (showLoadPrompt)
          Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 340),
              child: TrackingGlass(
                padding: const EdgeInsets.all(20),
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    Icon(
                      ScootIcons.locationSearching,
                      size: 32,
                      color: dso.accentText,
                    ),
                    const SizedBox(height: 8),
                    Text(
                      'Load a fleet snapshot',
                      style: TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: dso.ink,
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      'Phone positions appear after you load the scoped '
                      'snapshot. Numbered markers are visit history.',
                      textAlign: TextAlign.center,
                      style: TextStyle(
                        fontSize: 14,
                        height: 1.4,
                        color: dso.muted,
                      ),
                    ),
                    const SizedBox(height: 16),
                    FilledButton.icon(
                      onPressed: tracking.isRefreshing
                          ? null
                          : () => unawaited(tracking.refresh()),
                      icon: const Icon(ScootIcons.refresh, size: 18),
                      label: const Text('Load positions'),
                    ),
                  ],
                ),
              ),
            ),
          ),
        Positioned(
          left: 16,
          right: 16,
          bottom: 16,
          child: Align(
            alignment: Alignment.bottomLeft,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                TrackingGlass(
                  padding: const EdgeInsets.all(4),
                  radius: 14,
                  child: Column(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      IconButton(
                        tooltip: 'Fit all markers',
                        onPressed: _mapReady ? _fit : null,
                        icon: const Icon(ScootIcons.map),
                      ),
                      IconButton(
                        tooltip: 'Zoom in',
                        onPressed: _mapReady ? () => _zoom(1) : null,
                        icon: const Icon(ScootIcons.add),
                      ),
                      IconButton(
                        tooltip: 'Zoom out',
                        onPressed: _mapReady ? () => _zoom(-1) : null,
                        icon: const Icon(ScootIcons.remove),
                      ),
                    ],
                  ),
                ),
                if (!(showLoadPrompt && compactPrompt)) ...<Widget>[
                  const SizedBox(height: 8),
                  _MapLegend(followed: data.selectedKey != null),
                ],
              ],
            ),
          ),
        ),
        if (widget.wide)
          Positioned(
            top: 88,
            right: 16,
            bottom: 48,
            width: widget.drawerWidth,
            child: AnimatedSwitcher(
              duration: const Duration(milliseconds: 220),
              switchInCurve: Curves.easeOutCubic,
              transitionBuilder: (Widget child, Animation<double> animation) =>
                  FadeTransition(
                    opacity: animation,
                    child: SlideTransition(
                      position: Tween<Offset>(
                        begin: const Offset(0.08, 0),
                        end: Offset.zero,
                      ).animate(animation),
                      child: child,
                    ),
                  ),
              child: widget.drawer ?? const SizedBox.shrink(),
            ),
          ),
      ],
    );
  }
}

class _RefreshPill extends StatelessWidget {
  const _RefreshPill({required this.tracking});

  final _LiveTrackingView tracking;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final String label = tracking.refreshedAt == null
        ? 'Positions not loaded'
        : 'Refreshed ${_durationLabel(DateTime.now().toUtc().difference(tracking.refreshedAt!))} ago';
    return TrackingGlass(
      radius: 999,
      padding: const EdgeInsets.fromLTRB(16, 4, 4, 4),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: dso.muted),
            ),
          ),
          const SizedBox(width: 8),
          FilledButton.tonalIcon(
            onPressed: tracking.isRefreshing
                ? null
                : () => unawaited(tracking.refresh()),
            icon: tracking.isRefreshing
                ? const SizedBox(
                    width: 16,
                    height: 16,
                    child: CircularProgressIndicator(strokeWidth: 2),
                  )
                : const Icon(ScootIcons.refresh, size: 18),
            label: Text(tracking.hasSnapshot ? 'Refresh' : 'Load'),
          ),
        ],
      ),
    );
  }
}

class _MapLegend extends StatelessWidget {
  const _MapLegend({required this.followed});

  final bool followed;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    Widget dot(Color color, String label) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Container(
          width: 10,
          height: 10,
          decoration: BoxDecoration(color: color, shape: BoxShape.circle),
        ),
        const SizedBox(width: 6),
        Text(label, style: TextStyle(fontSize: 12, color: dso.body)),
      ],
    );
    return TrackingGlass(
      radius: 12,
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      child: Wrap(
        spacing: 14,
        runSpacing: 6,
        children: <Widget>[
          dot(dso.success, 'Live'),
          dot(dso.warning, 'Last known'),
          if (followed) ...<Widget>[
            dot(dso.info, 'Pending stop'),
            dot(dso.success, 'Done'),
            dot(dso.subtle, 'Skipped'),
          ],
          Text(
            'Position history is kept 30 days.',
            style: TextStyle(fontSize: 12, color: dso.muted),
          ),
        ],
      ),
    );
  }
}

class _MapTimeoutFallback extends StatelessWidget {
  const _MapTimeoutFallback({
    required this.points,
    required this.colorForKey,
    required this.onRetry,
  });

  final List<_MapPoint> points;
  final Color Function(String key) colorForKey;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<_MapPoint> latest = points
        .where((_MapPoint p) => p.kind != _MapPointKind.completed)
        .toList(growable: false);
    final List<_MapPoint> tablePoints = latest.isEmpty ? points : latest;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: scheme.outlineVariant),
      ),
      padding: const EdgeInsets.all(16),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(
                ScootIcons.map,
                color: scheme.brightness == Brightness.dark
                    ? DsoTokens.warningTextDark
                    : DsoTokens.warningText,
              ),
              const SizedBox(width: 10),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Map could not load',
                      style: TextStyle(
                        fontSize: 14,
                        fontWeight: FontWeight.w800,
                        color: scheme.onSurface,
                      ),
                    ),
                    SizedBox(height: 2),
                    Text(
                      'The map could not load. Showing the position list instead.',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 10),
              FilledButton.tonalIcon(
                onPressed: onRetry,
                icon: const Icon(ScootIcons.refresh, size: 18),
                label: const Text('Retry'),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Expanded(
            child: tablePoints.isEmpty
                ? const _EmptyState(
                    icon: ScootIcons.locationOff,
                    title: 'No GPS points',
                    subtitle:
                        'No recent salesman coordinates are available yet. $gpsRetentionNote',
                  )
                : _GpsPointsTable(
                    points: tablePoints,
                    colorForKey: colorForKey,
                  ),
          ),
        ],
      ),
    );
  }
}

class _GpsPointsTable extends StatelessWidget {
  const _GpsPointsTable({required this.points, required this.colorForKey});

  final List<_MapPoint> points;
  final Color Function(String key) colorForKey;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: points.length,
      separatorBuilder: (_, _) => const Divider(height: 14),
      itemBuilder: (BuildContext context, int index) {
        final _MapPoint p = points[index];
        final Color color = colorForKey(p.salesmanKey);
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.only(top: 3),
              child: CircleAvatar(radius: 6, backgroundColor: color),
            ),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    p.title,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 13,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    p.subtitle.isEmpty ? p.kindLabel : p.subtitle,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
            const SizedBox(width: 10),
            Text(
              '${p.position.latitude.toStringAsFixed(4)}, '
              '${p.position.longitude.toStringAsFixed(4)}',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        );
      },
    );
  }
}

class _FleetEntry {
  const _FleetEntry({
    required this.historyComplete,
    required this.salesmanKey,
    required this.name,
    required this.salesmanUid,
    required this.salesmanCode,
    required this.branchId,
    required this.color,
    required this.statusKind,
    required this.lastLocation,
    required this.positionAgeLabel,
    required this.lastSyncLabel,
    required this.accuracyLabel,
    required this.lowAccuracy,
    required this.positionClockLabel,
    required this.completedToday,
    required this.plannedStops,
  });

  final String salesmanKey;
  final bool historyComplete;
  final String name;
  final String salesmanUid;
  final String salesmanCode;
  final String branchId;
  final Color color;
  final String statusKind;
  final String lastLocation;
  final String positionAgeLabel;
  final String lastSyncLabel;
  final String accuracyLabel;
  final bool lowAccuracy;
  final String positionClockLabel;
  final int completedToday;
  final int plannedStops;

  String get initial =>
      name.trim().isEmpty ? '?' : name.trim().substring(0, 1).toUpperCase();

  String get statusLabel {
    switch (statusKind) {
      case 'active':
        return 'Fresh fix';
      case 'stale':
        return 'Last known fix';
      case 'idle':
        return 'Waiting for location';
      case 'ended':
        return 'Session ended';
      case 'sharing_disabled':
        return 'Sharing disabled';
      case 'off':
        return 'No active session';
      default:
        return 'No location from phone yet';
    }
  }

  Color statusBg(ColorScheme scheme) {
    final bool dark = scheme.brightness == Brightness.dark;
    switch (statusKind) {
      case 'active':
        return dark ? DsoTokens.successSurfaceDark : DsoTokens.successSoft;
      case 'idle':
      case 'stale':
        return dark ? DsoTokens.warningSurfaceDark : DsoTokens.warningSoft;
      case 'ended':
        return dark ? DsoTokens.infoSurfaceDark : DsoTokens.infoSoft;
      case 'sharing_disabled':
        return scheme.surfaceContainerHighest;
      default:
        return scheme.surfaceContainerHighest;
    }
  }

  Color statusFg(ColorScheme scheme) {
    final bool dark = scheme.brightness == Brightness.dark;
    switch (statusKind) {
      case 'active':
        return dark ? DsoTokens.successTextDark : DsoTokens.successText;
      case 'idle':
      case 'stale':
        return dark ? DsoTokens.warningTextDark : DsoTokens.warningText;
      case 'ended':
        return dark ? DsoTokens.infoTextDark : DsoTokens.infoText;
      case 'sharing_disabled':
        return scheme.onSurfaceVariant;
      default:
        return scheme.onSurfaceVariant;
    }
  }
}

Color _statusDotColor(DsoColors dso, String statusKind) {
  switch (statusKind) {
    case 'active':
      return dso.success;
    case 'stale':
      return dso.warning;
    case 'idle':
      return dso.info;
    default:
      return dso.subtle;
  }
}

class _FleetRail extends StatelessWidget {
  const _FleetRail({
    required this.all,
    required this.visible,
    required this.groups,
    required this.selectedUid,
    required this.loading,
    required this.error,
    required this.onQuery,
    required this.onToggleGroup,
    required this.onSelect,
    required this.onRetry,
  });

  final VoidCallback onRetry;
  final List<_FleetEntry> all;
  final List<_FleetEntry> visible;
  final Set<FleetStatusGroup> groups;
  final String selectedUid;
  final bool loading;
  final bool error;
  final ValueChanged<String> onQuery;
  final ValueChanged<FleetStatusGroup> onToggleGroup;
  final ValueChanged<String> onSelect;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    int count(FleetStatusGroup g) => all
        .where((_FleetEntry e) => fleetStatusGroup(e.statusKind) == g)
        .length;
    Widget chip(String label, FleetStatusGroup group, Color dot) {
      final bool on = groups.contains(group);
      return FilterChip(
        key: ValueKey<String>('fleet-chip-${group.name}'),
        selected: on,
        onSelected: (_) => onToggleGroup(group),
        showCheckmark: false,
        avatar: Container(
          width: 8,
          height: 8,
          decoration: BoxDecoration(color: dot, shape: BoxShape.circle),
        ),
        label: Text('$label ${count(group)}'),
        labelStyle: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w600,
          color: on ? dso.accentText : dso.body,
        ),
        backgroundColor: dso.card,
        selectedColor: dso.brandSurface,
        side: BorderSide(color: on ? dso.accent : dso.hairline),
        shape: const StadiumBorder(),
        visualDensity: VisualDensity.compact,
      );
    }

    Widget body;
    if (loading) {
      body = Padding(
        padding: const EdgeInsets.all(16),
        child: ScootLoadingState(
          skeleton: const ScootSkeletonLines(
            widthFactors: <double>[0.9, 0.6, 0.9, 0.6, 0.9, 0.6],
            lineHeight: 14,
            gap: 14,
          ),
          onRetry: onRetry,
        ),
      );
    } else if (error) {
      body = Center(
        child: ScootErrorState(
          title: 'Fleet unavailable',
          message:
              'The salesman activity feed could not be loaded. Check your connection and try again.',
          onRetry: onRetry,
        ),
      );
    } else if (all.isEmpty) {
      body = const Center(
        child: ScootEmptyState(
          icon: ScootIcons.delivery,
          title: 'No salespeople in your scope',
          message: 'No linked salesperson profiles are available.',
        ),
      );
    } else if (visible.isEmpty) {
      body = const Center(
        child: ScootEmptyState(
          icon: ScootIcons.search,
          title: 'No matches',
          message: 'No salespeople match this search or status filter.',
        ),
      );
    } else {
      body = ListView.separated(
        padding: const EdgeInsets.fromLTRB(16, 4, 16, 16),
        itemCount: visible.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (BuildContext context, int index) {
          final _FleetEntry entry = visible[index];
          return _FleetCard(
            key: ValueKey<String>('fleet-card-${entry.salesmanUid}'),
            entry: entry,
            selected:
                entry.salesmanUid.isNotEmpty &&
                entry.salesmanUid == selectedUid,
            onTap: entry.salesmanUid.isEmpty
                ? null
                : () => onSelect(entry.salesmanUid),
          );
        },
      );
    }
    return ColoredBox(
      color: dso.card,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 16, 16, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Fleet',
                    style: TextStyle(
                      fontSize: 18,
                      fontWeight: FontWeight.w700,
                      color: dso.ink,
                    ),
                  ),
                ),
                Text(
                  '${all.length} ${all.length == 1 ? 'salesperson' : 'salespeople'}',
                  style: TextStyle(fontSize: 12, color: dso.muted),
                ),
              ],
            ),
          ),
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: TextField(
              onChanged: onQuery,
              textInputAction: TextInputAction.search,
              decoration: InputDecoration(
                isDense: true,
                hintText: 'Search salesperson or area',
                prefixIcon: const Icon(ScootIcons.search, size: 18),
                filled: true,
                fillColor: dso.surfaceSoft,
                contentPadding: const EdgeInsets.symmetric(
                  horizontal: 12,
                  vertical: 10,
                ),
                border: OutlineInputBorder(
                  borderRadius: BorderRadius.circular(12),
                  borderSide: BorderSide.none,
                ),
              ),
            ),
          ),
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 10, 16, 12),
            child: Wrap(
              spacing: 8,
              runSpacing: 4,
              children: <Widget>[
                chip('Live', FleetStatusGroup.online, dso.success),
                chip('Last known', FleetStatusGroup.lastKnown, dso.warning),
                chip('No position', FleetStatusGroup.offline, dso.subtle),
              ],
            ),
          ),
          Divider(height: 1, color: dso.hairline),
          Expanded(child: body),
        ],
      ),
    );
  }
}

class _FleetCard extends StatelessWidget {
  const _FleetCard({
    super.key,
    required this.entry,
    required this.selected,
    required this.onTap,
  });

  final _FleetEntry entry;
  final bool selected;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final Color dot = _statusDotColor(dso, entry.statusKind);
    final bool hasAge = entry.positionAgeLabel != 'unavailable';
    final int planned = entry.plannedStops;
    final double progress = planned == 0
        ? 0
        : (entry.completedToday / planned).clamp(0.0, 1.0);
    final String sync = entry.lastSyncLabel.replaceFirst(
      'server received ',
      '',
    );
    final bool hasSync = !entry.lastSyncLabel.contains('unavailable');
    final bool hasAccuracy = !entry.accuracyLabel.contains('unavailable');
    return Semantics(
      button: onTap != null,
      selected: selected,
      label:
          '${entry.name}, ${entry.statusLabel}. '
          '${entry.historyComplete ? '${entry.completedToday} completed today' : 'Incomplete activity coverage'}.',
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: selected ? dso.brandSurface : dso.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(14),
          side: BorderSide(
            color: selected ? dso.accent : dso.hairline,
            width: selected ? 1.5 : 1,
          ),
        ),
        clipBehavior: Clip.antiAlias,
        child: InkWell(
          onTap: onTap,
          child: Padding(
            padding: const EdgeInsets.all(12),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    SizedBox(
                      width: 42,
                      height: 42,
                      child: Stack(
                        clipBehavior: Clip.none,
                        children: <Widget>[
                          CircleAvatar(
                            radius: 20,
                            backgroundColor: entry.color.withValues(
                              alpha: 0.16,
                            ),
                            child: Text(
                              entry.initial,
                              style: TextStyle(
                                fontSize: 14,
                                fontWeight: FontWeight.w800,
                                color: entry.color,
                              ),
                            ),
                          ),
                          Positioned(
                            right: -1,
                            bottom: -1,
                            child: Container(
                              width: 14,
                              height: 14,
                              decoration: BoxDecoration(
                                color: dot,
                                shape: BoxShape.circle,
                                border: Border.all(
                                  color: selected ? dso.brandSurface : dso.card,
                                  width: 2.5,
                                ),
                              ),
                            ),
                          ),
                        ],
                      ),
                    ),
                    const SizedBox(width: 12),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          TipText(
                            entry.name,
                            maxLines: 1,
                            style: TextStyle(
                              fontSize: 14,
                              fontWeight: FontWeight.w700,
                              color: dso.ink,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Row(
                            children: <Widget>[
                              _fleetBadge(entry.statusKind),
                              const SizedBox(width: 8),
                              Expanded(
                                child: Text(
                                  hasAge
                                      ? '${entry.positionClockLabel} · ${entry.positionAgeLabel}'
                                      : entry.statusLabel,
                                  maxLines: 1,
                                  overflow: TextOverflow.ellipsis,
                                  style: TextStyle(
                                    fontSize: 12,
                                    color: dso.muted,
                                  ),
                                ),
                              ),
                            ],
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 10),
                if (entry.historyComplete)
                  ClipRRect(
                    borderRadius: BorderRadius.circular(4),
                    child: LinearProgressIndicator(
                      value: planned == 0 ? 0 : progress,
                      minHeight: 6,
                      backgroundColor: dso.surfaceSoft,
                      color: dso.accent,
                    ),
                  ),
                const SizedBox(height: 6),
                Text(
                  !entry.historyComplete
                      ? 'Incomplete visit counts'
                      : planned == 0
                      ? '${entry.completedToday} visits done · no route today'
                      : '${entry.completedToday} visits done of $planned stops today',
                  style: TextStyle(fontSize: 12, color: dso.body),
                ),
                if (hasSync || hasAccuracy) ...<Widget>[
                  const SizedBox(height: 8),
                  Wrap(
                    spacing: 6,
                    runSpacing: 6,
                    children: <Widget>[
                      if (hasSync)
                        _MiniChip(
                          icon: ScootIcons.refresh,
                          label: 'GPS sync $sync',
                        ),
                      if (hasAccuracy)
                        _MiniChip(
                          icon: ScootIcons.locationFixed,
                          label: entry.accuracyLabel,
                        ),
                    ],
                  ),
                ],
                if (entry.lowAccuracy) ...<Widget>[
                  const SizedBox(height: 8),
                  Container(
                    key: ValueKey<String>('low-accuracy-${entry.salesmanUid}'),
                    padding: const EdgeInsets.all(8),
                    decoration: BoxDecoration(
                      color: dso.warningSoft,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Icon(
                          ScootIcons.error,
                          size: 14,
                          color: dso.warningText,
                        ),
                        const SizedBox(width: 6),
                        Expanded(
                          child: Text(
                            'Low accuracy. The position may be off by a street or more.',
                            style: TextStyle(
                              fontSize: 12,
                              color: dso.warningText,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

Widget _fleetBadge(String statusKind) => switch (fleetStatusGroup(statusKind)) {
  FleetStatusGroup.online => const ScootBadge(
    label: 'Live',
    tone: ScootTone.success,
    icon: ScootIcons.check,
  ),
  FleetStatusGroup.lastKnown => const ScootBadge(
    label: 'Last known',
    tone: ScootTone.warning,
    icon: ScootIcons.clock,
  ),
  FleetStatusGroup.offline => const ScootBadge(
    label: 'No position',
    tone: ScootTone.neutral,
    icon: ScootIcons.locationOff,
  ),
};

class _MiniChip extends StatelessWidget {
  const _MiniChip({required this.icon, required this.label});

  final IconData icon;
  final String label;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: dso.surfaceSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 12, color: dso.muted),
          const SizedBox(width: 4),
          Flexible(
            child: Text(
              label,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(fontSize: 12, color: dso.muted),
            ),
          ),
        ],
      ),
    );
  }
}

class _SalesmanDrawer extends StatelessWidget {
  const _SalesmanDrawer({
    super.key,
    required this.entry,
    required this.data,
    required this.repository,
    required this.currentUser,
    required this.tracking,
    required this.onOpenOrder,
    required this.scrollable,
  });

  final _FleetEntry entry;
  final _CommandData data;
  final CmsRepository repository;
  final UserProfile currentUser;
  final _LiveTrackingView tracking;
  final ValueChanged<_TimelineItem> onOpenOrder;
  final bool scrollable;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final Widget content = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Row(
          children: <Widget>[
            CircleAvatar(
              radius: 22,
              backgroundColor: entry.color.withValues(alpha: 0.16),
              child: Text(
                entry.initial,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w800,
                  color: entry.color,
                ),
              ),
            ),
            const SizedBox(width: 12),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  TipText(
                    entry.name,
                    maxLines: 1,
                    style: TextStyle(
                      fontSize: 16,
                      fontWeight: FontWeight.w700,
                      color: dso.ink,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Row(
                    children: <Widget>[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: _statusDotColor(dso, entry.statusKind),
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Flexible(
                        child: Text(
                          entry.statusLabel,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 12, color: dso.muted),
                        ),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            IconButton(
              tooltip: 'Close details',
              onPressed: () => tracking.follow(null),
              icon: const Icon(ScootIcons.close),
            ),
          ],
        ),
        const SizedBox(height: 16),
        Row(
          children: <Widget>[
            Expanded(
              child: _StatTile(
                label: 'Completed',
                value: entry.historyComplete
                    ? '${entry.completedToday}'
                    : 'Incomplete',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: _StatTile(
                label: 'Planned stops',
                value: entry.plannedStops == 0 ? '—' : '${entry.plannedStops}',
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: Tooltip(
                message: 'Straight-line distance between planned stops',
                child: _StatTile(
                  label: 'Route length',
                  value: data.routeKm == null
                      ? '—'
                      : '${data.routeKm!.toStringAsFixed(1)} km',
                ),
              ),
            ),
          ],
        ),
        const SizedBox(height: 16),
        _DrawerSection(
          title: 'Last known position',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                entry.lastLocation,
                style: TextStyle(fontSize: 14, color: dso.ink),
              ),
              const SizedBox(height: 4),
              Text(
                'Position age: ${entry.positionAgeLabel} · ${entry.accuracyLabel}',
                style: TextStyle(fontSize: 12, color: dso.muted),
              ),
              Text(
                entry.lastSyncLabel,
                style: TextStyle(fontSize: 12, color: dso.muted),
              ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        _DrawerSection(
          title: 'Visits today',
          child: !entry.historyComplete
              ? Text(
                  'Incomplete activity coverage — visits today are unavailable.',
                  style: TextStyle(fontSize: 14, color: dso.muted),
                )
              : data.timeline.isEmpty
              ? Text(
                  'No completed visits recorded today. $gpsRetentionNote',
                  style: TextStyle(fontSize: 14, color: dso.muted),
                )
              : Column(
                  children: <Widget>[
                    for (int i = 0; i < data.timeline.length; i++)
                      _TimelineRow(
                        item: data.timeline[i],
                        color: entry.color,
                        last: i == data.timeline.length - 1,
                        onOpen: data.timeline[i].orderDocumentId.isEmpty
                            ? null
                            : () => onOpenOrder(data.timeline[i]),
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        _DrawerSection(
          title: 'Phone upload',
          child: _TrackingControlPanel(
            repository: repository,
            currentUser: currentUser,
            salesmen: <_FleetEntry>[entry],
            tracking: tracking,
          ),
        ),
      ],
    );
    return Container(
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(18),
        border: Border.all(color: dso.hairline),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 24,
            offset: Offset(0, 8),
          ),
        ],
      ),
      padding: const EdgeInsets.all(16),
      child: scrollable ? SingleChildScrollView(child: content) : content,
    );
  }
}

class _DrawerSection extends StatelessWidget {
  const _DrawerSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          title,
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w700,
            color: dso.ink,
          ),
        ),
        const SizedBox(height: 8),
        child,
      ],
    );
  }
}

class _StatTile extends StatelessWidget {
  const _StatTile({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: dso.surfaceSoft,
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: dso.ink,
            ),
          ),
          Text(
            label,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: dso.muted),
          ),
        ],
      ),
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({
    required this.item,
    required this.color,
    required this.last,
    required this.onOpen,
  });

  final _TimelineItem item;
  final Color color;
  final bool last;
  final VoidCallback? onOpen;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final Widget row = IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          SizedBox(
            width: 44,
            child: Padding(
              padding: const EdgeInsets.only(top: 2),
              child: Text(
                item.timeLabel,
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: dso.body,
                ),
              ),
            ),
          ),
          Column(
            children: <Widget>[
              Container(
                width: 10,
                height: 10,
                margin: const EdgeInsets.only(top: 4),
                decoration: BoxDecoration(color: color, shape: BoxShape.circle),
              ),
              if (!last)
                Expanded(child: Container(width: 2, color: dso.hairline)),
            ],
          ),
          const SizedBox(width: 12),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: last ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    item.title,
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 14,
                      fontWeight: FontWeight.w600,
                      color: dso.ink,
                    ),
                  ),
                  Text(
                    item.outcome,
                    style: TextStyle(fontSize: 12, color: dso.muted),
                  ),
                ],
              ),
            ),
          ),
          if (onOpen != null)
            Icon(ScootIcons.chevronRight, size: 18, color: dso.muted),
        ],
      ),
    );
    if (onOpen == null) return row;
    return InkWell(
      onTap: onOpen,
      borderRadius: BorderRadius.circular(8),
      child: row,
    );
  }
}

class _CoachingScorecardPanel extends StatefulWidget {
  const _CoachingScorecardPanel({
    required this.currentUser,
    required this.users,
  });

  final UserProfile currentUser;
  final List<Map<String, dynamic>> users;

  @override
  State<_CoachingScorecardPanel> createState() =>
      _CoachingScorecardPanelState();
}

class _CoachingScorecardPanelState extends State<_CoachingScorecardPanel> {
  final SalesmanScorecardService _service = SalesmanScorecardService();

  SalesmanScorecardInputs _inputs = SalesmanScorecardInputs.empty;
  bool _loading = true;
  bool _error = false;

  int _loadSeq = 0;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final int seq = ++_loadSeq;
    setState(() {
      _loading = true;
      _error = false;
    });
    try {
      final SalesmanScorecardInputs inputs = await _service.loadInputs(
        widget.currentUser,
      );
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _inputs = inputs;
        _loading = false;
        _error = inputs.allSourcesFailed;
      });
    } catch (_) {
      if (!mounted || seq != _loadSeq) return;
      setState(() {
        _loading = false;
        _error = true;
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    Widget body;
    if (_loading) {
      body = const SlowLoading();
    } else if (_error) {
      body = Column(
        mainAxisAlignment: MainAxisAlignment.center,
        children: <Widget>[
          const _EmptyState(
            icon: ScootIcons.error,
            title: 'Could not load scorecard signals',
            subtitle:
                'Visit progress, stop arrivals, plans, orders, outcomes and '
                'insights could not be read. Check your connection and '
                'access, then retry.',
          ),
          const SizedBox(height: 6),
          FilledButton.icon(
            onPressed: _load,
            icon: const Icon(ScootIcons.refresh, size: 18),
            label: const Text('Retry'),
          ),
          const SizedBox(height: 12),
        ],
      );
    } else {
      body = _scorecardList();
    }
    return CmsPanel(
      title: 'Coaching Scorecard',
      trailing: const _SmallChip(label: 'Rule-derived'),
      child: body,
    );
  }

  Widget _scorecardList() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color warningText = scheme.brightness == Brightness.dark
        ? DsoTokens.warningTextDark
        : DsoTokens.warningText;
    final List<ScorecardSalesman> salesmen = scorecardSalesmenFromUsers(
      widget.users,
      widget.currentUser,
    );
    if (salesmen.isEmpty) {
      return const _EmptyState(
        icon: ScootIcons.badge,
        title: 'No salesmen in scope',
        subtitle:
            'Scorecards cover the salesmen your role can see. None were '
            'found in the user directory.',
      );
    }
    final List<SalesmanScorecard> cards = deriveSalesmanScorecards(
      salesmen: salesmen,
      progressDocs: _inputs.progressDocs,
      stopArrivalDocsByPlanId: _inputs.stopArrivalDocsByPlanId,
      plannedStopIdsByPlanId: _inputs.plannedStopIdsByPlanId,
      orders: _inputs.orders,
      outcomes: _inputs.outcomes,
      insights: _inputs.insights,
      now: DateTime.now(),
    );
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        AiFreshnessChip(
          hasData: _inputs.hasAiData,
          timestamps: _inputs.aiTimestamps,
          hasMissingTimestamp: _inputs.hasMissingAiTimestamp,
        ),
        const SizedBox(height: 10),
        if (_inputs.failedSources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Some signals could not be read '
              '(${_inputs.failedSources.join(', ')}) — scorecards run on the '
              'remaining signals only.',
              style: TextStyle(fontSize: 12, color: warningText),
            ),
          ),
        if (_inputs.truncatedSources.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(bottom: 10),
            child: Text(
              'Some signals have incomplete coverage '
              '(${_inputs.truncatedSources.join(', ')}). Counts are withheld when '
              'incomplete; rates and coaching also require complete signals.',
              style: TextStyle(fontSize: 12, color: warningText),
            ),
          ),
        for (final SalesmanScorecard card in cards)
          _ScorecardCard(
            scorecard: card,
            partial:
                _inputs.truncatedSources.isNotEmpty ||
                _inputs.failedSources.isNotEmpty,
            partialReason:
                _inputs.truncatedSources.isNotEmpty &&
                    _inputs.failedSources.isNotEmpty
                ? 'at least one signal hit its read cap and another could not be read'
                : _inputs.truncatedSources.isNotEmpty
                ? 'at least one signal hit its read cap and may be incomplete'
                : 'at least one signal could not be read',
          ),
      ],
    );
  }
}

class _ScorecardCard extends StatelessWidget {
  const _ScorecardCard({
    required this.scorecard,
    this.partial = false,
    this.partialReason = '',
  });

  final SalesmanScorecard scorecard;

  final bool partial;

  final String partialReason;

  static const Color _accent = DsoTokens.green600;

  String _pct(double? value) =>
      value == null ? '—' : '${(value * 100).round()}%';

  String _trendLabel(ScorecardTrend trend) {
    switch (trend) {
      case ScorecardTrend.improving:
        return 'Improving';
      case ScorecardTrend.steady:
        return 'Steady';
      case ScorecardTrend.declining:
        return 'Declining';
      case ScorecardTrend.insufficient:
        return 'Trend: not enough weeks';
    }
  }

  Color _trendColor(ScorecardTrend trend, ColorScheme scheme) {
    switch (trend) {
      case ScorecardTrend.improving:
        return scheme.brightness == Brightness.dark
            ? DsoTokens.successTextDark
            : DsoTokens.successText;
      case ScorecardTrend.declining:
        return scheme.error;
      case ScorecardTrend.steady:
      case ScorecardTrend.insufficient:
        return scheme.onSurfaceVariant;
    }
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final SalesmanScorecard s = scorecard;
    if (partial) {
      return ListTile(
        title: Text(s.salesmanName),
        subtitle: const Text(
          'Incomplete — counts, rates and coaching are unavailable. '
          'The 56-day inputs reached a bound or could not be verified.',
        ),
      );
    }
    final bool withholdRates = partial;
    final Color warningText = scheme.brightness == Brightness.dark
        ? DsoTokens.warningTextDark
        : DsoTokens.warningText;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(DsoTokens.rXl),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              CircleAvatar(
                radius: 16,
                backgroundColor: _accent.withValues(alpha: 0.12),
                child: Text(
                  s.salesmanName.isNotEmpty
                      ? s.salesmanName[0].toUpperCase()
                      : '?',
                  style: const TextStyle(
                    fontWeight: FontWeight.w900,
                    color: _accent,
                  ),
                ),
              ),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  s.salesmanName,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 16,
                    fontWeight: FontWeight.w900,
                  ),
                ),
              ),
              Text(
                _trendLabel(s.trend),
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: _trendColor(s.trend, scheme),
                ),
              ),
            ],
          ),
          const SizedBox(height: 12),
          if (partial)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Partial data: '
                '${partialReason.isEmpty ? 'a signal is incomplete' : partialReason}'
                ', so the rates for this salesman are withheld rather than '
                'shown as a total. Counts are what was read.',
                style: TextStyle(
                  fontSize: 14,
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          if (!s.hasSufficientData)
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Text(
                'Insufficient data: ${s.decidedStops} decided visit(s) on '
                'record (minimum $minDecidedVisitsForScore). Counts are '
                'shown; rates and coaching are withheld rather than guessed.',
                style: TextStyle(
                  fontSize: 14,
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              _chip(context, 'Decided visits', '${s.decidedStops}'),
              _chip(
                context,
                'Completed',
                '${s.completedStops}'
                    '${!withholdRates && s.completionRate != null ? ' (${_pct(s.completionRate)})' : ''}',
              ),
              _chip(
                context,
                'Skipped',
                '${s.skippedStops}'
                    '${!withholdRates && s.skipRate != null ? ' (${_pct(s.skipRate)})' : ''}',
              ),
              _chip(
                context,
                'Plan adherence',
                s.meanAdherence == null || withholdRates
                    ? '—'
                    : '${_pct(s.meanAdherence)} over ${s.adherencePlanCount} plan(s)',
              ),
              _chip(
                context,
                'Avg service time',
                s.meanServiceMinutes == null || withholdRates
                    ? '—'
                    : '${s.meanServiceMinutes!.round()} min '
                          '(${s.serviceSampleCount} stop(s))',
              ),
              _chip(
                context,
                'Orders (8 wk)',
                withholdRates ? '—' : '${s.ordersInWindow}',
              ),
              _chip(
                context,
                'Orders per visit',
                s.ordersPerCompletedVisit == null || withholdRates
                    ? '—'
                    : s.ordersPerCompletedVisit!.toStringAsFixed(2),
              ),
              _chip(
                context,
                'Outcomes recorded',
                '${s.outcomesRecorded}'
                    '${s.outcomesRecorded > 0 ? ' (${s.outcomesLinkedToIssue} on insights)' : ''}',
              ),
              _chip(
                context,
                'Outcome quality',
                s.meanOutcomeQuality == null
                    ? '—'
                    : '${s.meanOutcomeQuality!.round()}/100',
              ),
              _chip(context, 'Insights resolved', '${s.resolvedInsightCount}'),
            ],
          ),
          if (s.coachingPrompts.isNotEmpty) ...<Widget>[
            const SizedBox(height: 12),
            for (final CoachingPrompt prompt in s.coachingPrompts)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Icon(
                      prompt.code == 'on_track'
                          ? ScootIcons.success
                          : ScootIcons.info,
                      size: 16,
                      color: prompt.code == 'on_track'
                          ? DsoTokens.success
                          : warningText,
                    ),
                    const SizedBox(width: 6),
                    Expanded(
                      child: Text(
                        prompt.message,
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                          height: 1.4,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
          ],
        ],
      ),
    );
  }

  Widget _chip(BuildContext context, String label, String value) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
          ),
          const SizedBox(height: 2),
          Text(
            value,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w800),
          ),
        ],
      ),
    );
  }
}

class _NoTeamAssignedState extends StatelessWidget {
  const _NoTeamAssignedState();

  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const Icon(ScootIcons.team, size: 40),
            const SizedBox(height: 12),
            Text(
              'No salesmen are assigned to you yet. '
              'Ask an administrator to assign your team.',
              textAlign: TextAlign.center,
              style: Theme.of(context).textTheme.bodyLarge,
            ),
          ],
        ),
      ),
    );
  }
}
