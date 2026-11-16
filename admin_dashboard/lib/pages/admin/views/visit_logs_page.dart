import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/csv_downloader.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/collection_rows.dart';
import '../../../utils/csv_export.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/snapshot_load_state.dart';
import '../../../utils/visit_data_utils.dart';
import '../widgets/filter_chip.dart';
import 'visit_logs_parts.dart';
import '../../../security/team_scope.dart';

CollectionRows mergeNewestWindows(
  Iterable<List<Map<String, dynamic>>> sources, {
  required int maxRows,
  required DateTime? Function(Map<String, dynamic>) dateForRow,
  bool sameCollection = false,
}) {
  final Map<String, Map<String, dynamic>> byKey =
      <String, Map<String, dynamic>>{};
  for (final List<Map<String, dynamic>> rows in sources) {
    for (final Map<String, dynamic> row in rows) {
      final String key = _safeText(
        row['docId'] ??
            row['orderId'] ??
            row['order_id'] ??
            row['referenceId'] ??
            row['reference_id'],
        fallback: '',
      );
      byKey[key.isEmpty ? identityHashCode(row).toString() : key] = row;
    }
  }
  final List<Map<String, dynamic>> merged =
      byKey.values
          .where((Map<String, dynamic> row) => dateForRow(row) != null)
          .toList(growable: false)
        ..sort(
          (Map<String, dynamic> a, Map<String, dynamic> b) =>
              dateForRow(b)!.compareTo(dateForRow(a)!),
        );
  DateTime? since = sameCollection && sources.any(collectionRowsComplete)
      ? coversAllRows
      : combinedCoverage(sources);
  if (merged.length > maxRows) {
    since = laterCoverage(since, dateForRow(merged[maxRows - 1]));
  }
  return CollectionRows(
    merged.take(maxRows),
    isComplete: since == coversAllRows,
    coveredSince: since,
  );
}

String? newestWindowNotice(
  List<Map<String, dynamic>> rows,
  DateTime rangeStart, {
  required String what,
}) {
  if (collectionRowsCover(rows, rangeStart)) return null;
  final DateTime? since = collectionRowsCoverage(rows);
  return 'Only the newest $what are loaded'
      '${since == null ? '' : ', complete from ${_formatKualaLumpurTime(since)}'}.';
}

class VisitLogsPage extends StatefulWidget {
  const VisitLogsPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<VisitLogsPage> createState() => _VisitLogsPageState();
}

class _VisitLogsPageState extends State<VisitLogsPage> {
  final CmsRepository repository = CmsRepository();
  final List<StreamSubscription<List<Map<String, dynamic>>>> _subscriptions =
      <StreamSubscription<List<Map<String, dynamic>>>>[];
  AsyncSnapshot<List<Map<String, dynamic>>> _visitSnapshot =
      const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
  AsyncSnapshot<List<Map<String, dynamic>>> _orderSnapshot =
      const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
  AsyncSnapshot<List<Map<String, dynamic>>> _retailerSnapshot =
      const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
  AsyncSnapshot<List<Map<String, dynamic>>> _sheetSnapshot =
      const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();

  UserProfile get currentUser => widget.currentUser;

  int _tab = 0;
  final Set<int> _openedTabs = <int>{0};
  Stream<List<Map<String, dynamic>>>? _plannedStream;

  void _retry() {
    _unsubscribe();
    setState(() {
      _visitSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _orderSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _retailerSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _sheetSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _plannedStream = null;
    });
    _subscribe();
  }

  void _openTab(int index) => setState(() {
    _tab = index;
    _openedTabs.add(index);
  });

  @override
  void initState() {
    super.initState();
    _subscribe();
  }

  @override
  void didUpdateWidget(VisitLogsPage oldWidget) {
    super.didUpdateWidget(oldWidget);
    final UserProfile before = oldWidget.currentUser;
    final UserProfile after = widget.currentUser;
    if (before.uid != after.uid ||
        before.role != after.role ||
        before.branchId != after.branchId ||
        before.assignedSalesmanCodes.join(',') !=
            after.assignedSalesmanCodes.join(',')) {
      _unsubscribe();
      _visitSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _orderSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _retailerSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _sheetSnapshot =
          const AsyncSnapshot<List<Map<String, dynamic>>>.waiting();
      _subscribe();
    }
  }

  @override
  void dispose() {
    _unsubscribe();
    super.dispose();
  }

  void _unsubscribe() {
    for (final StreamSubscription<List<Map<String, dynamic>>> subscription
        in _subscriptions) {
      unawaited(subscription.cancel());
    }
    _subscriptions.clear();
  }

  void _subscribe() {
    _listen(
      _watchVisitCandidates(repository),
      (AsyncSnapshot<List<Map<String, dynamic>>> value) =>
          _visitSnapshot = value,
    );
    _listen(
      _watchOrderCandidates(repository),
      (AsyncSnapshot<List<Map<String, dynamic>>> value) =>
          _orderSnapshot = value,
    );
    _listen(
      repository.watchCollection('retailers'),
      (AsyncSnapshot<List<Map<String, dynamic>>> value) =>
          _retailerSnapshot = value,
    );
    _listen(
      repository.watchCollection('retailer_score_sheet_settings'),
      (AsyncSnapshot<List<Map<String, dynamic>>> value) =>
          _sheetSnapshot = value,
    );
  }

  void _listen(
    Stream<List<Map<String, dynamic>>> stream,
    void Function(AsyncSnapshot<List<Map<String, dynamic>>> value) assign,
  ) {
    _subscriptions.add(
      stream.listen(
        (List<Map<String, dynamic>> rows) {
          if (!mounted) return;
          setState(
            () => assign(
              AsyncSnapshot<List<Map<String, dynamic>>>.withData(
                ConnectionState.active,
                rows,
              ),
            ),
          );
        },
        onError: (Object error, StackTrace stackTrace) {
          if (!mounted) return;
          setState(
            () => assign(
              AsyncSnapshot<List<Map<String, dynamic>>>.withError(
                ConnectionState.active,
                error,
                stackTrace,
              ),
            ),
          );
        },
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final SnapshotLoadState visitLoadState = snapshotLoadState(
      isWaiting: _visitSnapshot.connectionState == ConnectionState.waiting,
      hasData: _visitSnapshot.hasData,
      hasError: _visitSnapshot.hasError,
    );
    final List<Map<String, dynamic>> scopedVisits =
        visitLoadState == SnapshotLoadState.ready
        ? _scopeVisitLogs(_visitSnapshot.data ?? <Map<String, dynamic>>[])
        : const <Map<String, dynamic>>[];

    final Map<String, AsyncSnapshot<List<Map<String, dynamic>>>> sources =
        <String, AsyncSnapshot<List<Map<String, dynamic>>>>{
          'Orders': _orderSnapshot,
          'Retailers': _retailerSnapshot,
          'Retailer score sheets': _sheetSnapshot,
        };
    final List<String> failedSources = <String>[
      for (final MapEntry<String, AsyncSnapshot<List<Map<String, dynamic>>>>
          entry
          in sources.entries)
        if (entry.value.hasError) entry.key,
    ];
    final bool followWaiting =
        failedSources.isEmpty &&
        sources.values.any(
          (AsyncSnapshot<List<Map<String, dynamic>>> snapshot) =>
              !snapshot.hasData,
        );
    List<_RetailerFollowUp> followUps = const <_RetailerFollowUp>[];
    if (failedSources.isEmpty && !followWaiting) {
      followUps = _buildFollowUps(
        _buildRetailerSummaries(
          retailers: _scopeRetailers(
            _retailerSnapshot.data ?? <Map<String, dynamic>>[],
          ),
          visits: scopedVisits,
          orders: _scopeOrders(_orderSnapshot.data ?? <Map<String, dynamic>>[]),
          scoreSheets: _sheetSnapshot.data ?? <Map<String, dynamic>>[],
        ),
      );
    }
    followUps = followUps.toList()
      ..sort(
        (_RetailerFollowUp a, _RetailerFollowUp b) =>
            (b.isOverdue ? 1 : 0) - (a.isOverdue ? 1 : 0),
      );
    final bool followKnown = failedSources.isEmpty && !followWaiting;
    final List<String> followUpCuts = <String>[
      if (followKnown)
        ...<String?>[
          newestWindowNotice(scopedVisits, coversAllRows, what: 'visits'),
          newestWindowNotice(
            _orderSnapshot.data ?? const <Map<String, dynamic>>[],
            coversAllRows,
            what: 'orders',
          ),
        ].whereType<String>(),
    ];

    return Padding(
      padding: const EdgeInsets.all(ScootSpace.lg),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              PageFilterChip(
                key: const ValueKey<String>('visit-tab-visits'),
                label: 'Visits',
                selected: _tab == 0,
                onTap: () => _openTab(0),
              ),
              PageFilterChip(
                key: const ValueKey<String>('visit-tab-follow-up'),
                label: 'Follow-up',
                count: followKnown ? followUps.length : null,
                selected: _tab == 1,
                onTap: () => _openTab(1),
              ),
              PageFilterChip(
                key: const ValueKey<String>('visit-tab-planned'),
                label: 'Planned',
                selected: _tab == 2,
                onTap: () => _openTab(2),
              ),
            ],
          ),
          const SizedBox(height: 12),
          Expanded(
            child: IndexedStack(
              index: _tab,
              children: <Widget>[
                visitLoadState == SnapshotLoadState.ready
                    ? _LatestVisitsTab(
                        visits: scopedVisits,
                        repository: repository,
                        currentUser: currentUser,
                      )
                    : VisitsTableCard(
                        phase: visitLoadState == SnapshotLoadState.error
                            ? ScootLoadPhase.error
                            : ScootLoadPhase.loading,
                        rows: const <VisitRowData>[],
                        onRetry: _retry,
                        emptyTitle: '',
                        emptyMessage: '',
                        summary: '',
                        showDate: false,
                      ),
                _openedTabs.contains(1)
                    ? Column(
                        crossAxisAlignment: CrossAxisAlignment.stretch,
                        children: <Widget>[
                          if (followUpCuts.isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(bottom: 12),
                              child: ScootNotice(
                                key: const ValueKey<String>(
                                  'follow-up-incomplete',
                                ),
                                tone: ScootTone.warning,
                                message:
                                    '${followUpCuts.join(' ')} Follow-up is incomplete: a retailer with no visit or order since then is not listed.',
                              ),
                            ),
                          Expanded(
                            child: FollowUpListCard(
                              phase: followWaiting
                                  ? ScootLoadPhase.loading
                                  : ScootLoadPhase.ready,
                              items: <FollowUpRowData>[
                                for (final _RetailerFollowUp item in followUps)
                                  FollowUpRowData(
                                    retailer: item.retailerName,
                                    salesperson: item.assignedSalesman.isEmpty
                                        ? '-'
                                        : item.assignedSalesman,
                                    lastVisit: _dateLabel(item.lastVisitDate),
                                    lastOrder: _dateLabel(item.lastOrderDate),
                                    reason: item.reason,
                                    action: item.recommendedAction,
                                    overdue: item.isOverdue,
                                  ),
                              ],
                              onRetry: _retry,
                              unavailableMessage: failedSources.isEmpty
                                  ? null
                                  : '${failedSources.join(', ')} could not be loaded, so Follow-up is unavailable. Visits still show.',
                            ),
                          ),
                        ],
                      )
                    : const SizedBox.shrink(),
                _openedTabs.contains(2)
                    ? _PlannedVisitsTab(
                        stream: _plannedStream ??= repository
                            .watchCollectionRaw('visits', limit: 500),
                      )
                    : const SizedBox.shrink(),
              ],
            ),
          ),
        ],
      ),
    );
  }

  List<Map<String, dynamic>> _scopeVisitLogs(List<Map<String, dynamic>> logs) {
    return _sameCoverage(
      logs,
      TeamScope.filter(currentUser, logs).toList()..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            _sortTimeValue(b).compareTo(_sortTimeValue(a)),
      ),
    );
  }

  List<Map<String, dynamic>> _scopeOrders(List<Map<String, dynamic>> orders) {
    return TeamScope.filter(
      currentUser,
      orders,
    ).where(orderCountsAsSale).toList(growable: false);
  }

  Stream<List<Map<String, dynamic>>> _watchVisitCandidates(
    CmsRepository repository,
  ) {
    final Stream<List<Map<String, dynamic>>> assignedStops = repository
        .watchCollectionRaw(
          'route_stop_progress',
          orderBy: 'arrivedAt',
          descending: true,
          limit: 500,
        )
        .map(
          (List<Map<String, dynamic>> docs) => _sameCoverage(
            docs,
            docs
                .map(routeStopProgressToVisitRow)
                .whereType<Map<String, dynamic>>(),
          ),
        );
    return _mergeOrderedCandidateStreams(
      <Stream<List<Map<String, dynamic>>>>[
        _watchVisitLogCandidates(repository),
        assignedStops,
      ],
      maxRows: 500,
      dateForRow: visitDateFromRow,
    ).map(
      (List<Map<String, dynamic>> rows) =>
          _sameCoverage(rows, dedupeAssignedRouteVisits(rows)),
    );
  }

  Stream<List<Map<String, dynamic>>> _watchNewest(
    CmsRepository repository,
    String collection, {
    required String orderBy,
    required int limit,
  }) {
    return repository.watchCollectionRaw(
      collection,
      orderBy: orderBy,
      descending: true,
      limit: limit,
    );
  }

  CollectionRows _sameCoverage(
    List<Map<String, dynamic>> source,
    Iterable<Map<String, dynamic>> rows,
  ) => CollectionRows(
    rows,
    isComplete: collectionRowsComplete(source),
    coveredSince: collectionRowsCoverage(source),
  );

  Stream<List<Map<String, dynamic>>> _watchVisitLogCandidates(
    CmsRepository repository,
  ) {
    if (currentUser.isSupervisor || currentUser.isBranchManager) {
      return _watchScopedCandidates(
        repository,
        collection: 'visit_logs',
        orderBy: 'arrivalTime',
        dateForRow: visitDateFromRow,
      );
    }
    return _mergeOrderedCandidateStreams(
      <Stream<List<Map<String, dynamic>>>>[
        _watchNewest(
          repository,
          'visit_logs',
          orderBy: 'arrivalTime',
          limit: 320,
        ),
        _watchNewest(
          repository,
          'visit_logs',
          orderBy: 'createdAt',
          limit: 160,
        ),
        _watchNewest(
          repository,
          'visit_logs',
          orderBy: 'timestamp',
          limit: 160,
        ),
      ],
      maxRows: 500,
      dateForRow: visitDateFromRow,
      sameCollection: true,
    );
  }

  Stream<List<Map<String, dynamic>>> _watchOrderCandidates(
    CmsRepository repository,
  ) {
    if (currentUser.isSupervisor || currentUser.isBranchManager) {
      return _watchScopedCandidates(
        repository,
        collection: 'orders',
        orderBy: 'submittedAt',
        dateForRow: orderDateFromRow,
      );
    }
    return _mergeOrderedCandidateStreams(
      <Stream<List<Map<String, dynamic>>>>[
        _watchNewest(repository, 'orders', orderBy: 'submittedAt', limit: 320),
        _watchNewest(repository, 'orders', orderBy: 'createdAt', limit: 160),
        _watchNewest(repository, 'orders', orderBy: 'timestamp', limit: 160),
      ],
      maxRows: 500,
      dateForRow: orderDateFromRow,
      sameCollection: true,
    );
  }

  Stream<List<Map<String, dynamic>>> _watchScopedCandidates(
    CmsRepository repository, {
    required String collection,
    required String orderBy,
    required DateTime? Function(Map<String, dynamic>) dateForRow,
  }) {
    return _mergeOrderedCandidateStreams(
      <Stream<List<Map<String, dynamic>>>>[
        _watchNewest(repository, collection, orderBy: orderBy, limit: 500),
      ],
      maxRows: 500,
      dateForRow: dateForRow,
    );
  }

  Stream<List<Map<String, dynamic>>> _mergeOrderedCandidateStreams(
    List<Stream<List<Map<String, dynamic>>>> streams, {
    required int maxRows,
    required DateTime? Function(Map<String, dynamic>) dateForRow,
    bool sameCollection = false,
  }) {
    late final StreamController<List<Map<String, dynamic>>> controller;
    final Map<int, List<Map<String, dynamic>>> latest =
        <int, List<Map<String, dynamic>>>{};
    final List<StreamSubscription<List<Map<String, dynamic>>>> subscriptions =
        <StreamSubscription<List<Map<String, dynamic>>>>[];

    void emit() {
      controller.add(
        mergeNewestWindows(
          latest.values,
          maxRows: maxRows,
          dateForRow: dateForRow,
          sameCollection: sameCollection,
        ),
      );
    }

    controller = StreamController<List<Map<String, dynamic>>>(
      onListen: () {
        for (int i = 0; i < streams.length; i++) {
          subscriptions.add(
            streams[i].listen((List<Map<String, dynamic>> rows) {
              latest[i] = rows;
              emit();
            }, onError: controller.addError),
          );
        }
      },
      onCancel: () async {
        for (final StreamSubscription<List<Map<String, dynamic>>> sub
            in subscriptions) {
          await sub.cancel();
        }
      },
    );
    return controller.stream;
  }

  List<Map<String, dynamic>> _scopeRetailers(
    List<Map<String, dynamic>> retailers,
  ) {
    final List<Map<String, dynamic>> operational = operationalRetailerRows(
      retailers,
    );
    if (currentUser.isSupervisor) return <Map<String, dynamic>>[];
    if (currentUser.isBranchManager && currentUser.branchId.isNotEmpty) {
      return operational
          .where((Map<String, dynamic> retailer) {
            return _safeText(
                  retailer['branchId'] ?? retailer['branch_id'],
                  fallback: '',
                ) ==
                currentUser.branchId;
          })
          .toList(growable: false);
    }
    return operational;
  }

  List<_RetailerVisitSummary> _buildRetailerSummaries({
    required List<Map<String, dynamic>> retailers,
    required List<Map<String, dynamic>> visits,
    required List<Map<String, dynamic>> orders,
    required List<Map<String, dynamic>> scoreSheets,
  }) {
    final Map<String, _RetailerVisitSummaryBuilder> builders =
        <String, _RetailerVisitSummaryBuilder>{};

    _RetailerVisitSummaryBuilder builderFor(String id, String name) {
      final String key = id.isNotEmpty ? id : name;
      return builders.putIfAbsent(
        key,
        () => _RetailerVisitSummaryBuilder(retailerId: id, retailerName: name),
      );
    }

    for (final Map<String, dynamic> retailer in retailers) {
      final String id = _retailerKey(retailer);
      final String name = _retailerName(retailer);
      if (id.isEmpty && name.isEmpty) continue;
      final _RetailerVisitSummaryBuilder builder = builderFor(id, name);
      builder.lastVisitDate = _latestDate(
        builder.lastVisitDate,
        _toDateTime(
          retailer['lastVisitDate'] ??
              retailer['lastVisit'] ??
              retailer['last_visit_date'] ??
              retailer['last_visit'],
        ),
      );
      builder.lastOrderDate = _latestDate(
        builder.lastOrderDate,
        _toDateTime(
          retailer['lastOrderDate'] ??
              retailer['lastOrder'] ??
              retailer['last_order_date'] ??
              retailer['last_order'],
        ),
      );
      builder.assignedSalesman = _safeText(
        retailer['assignedSalesman'] ??
            retailer['assigned_salesman'] ??
            retailer['salesmanId'] ??
            retailer['salesman_id'],
        fallback: builder.assignedSalesman,
      );
    }

    for (final Map<String, dynamic> visit in visits) {
      final String id = _retailerKey(visit);
      final String name = _retailerName(visit);
      if (id.isEmpty && name.isEmpty) continue;
      final _RetailerVisitSummaryBuilder builder = builderFor(id, name);
      builder.salesmanName = _displaySalesman(visit);
      builder.assignedSalesman = builder.assignedSalesman.isEmpty
          ? builder.salesmanName
          : builder.assignedSalesman;
      builder.lastVisitDate = _latestDate(
        builder.lastVisitDate,
        visitDateFromRow(visit),
      );
      builder.lastDepartureDate = _latestDate(
        builder.lastDepartureDate,
        _toDateTime(visit['departureTime'] ?? visit['departure_time']),
      );
      builder.visitRows += 1;
    }

    for (final Map<String, dynamic> order in orders) {
      final String id = _retailerKey(order);
      final String name = _retailerName(order);
      if (id.isEmpty && name.isEmpty) continue;
      final _RetailerVisitSummaryBuilder builder = builderFor(id, name);
      builder.salesmanName = builder.salesmanName.isEmpty
          ? _displaySalesman(order)
          : builder.salesmanName;
      builder.assignedSalesman = builder.assignedSalesman.isEmpty
          ? builder.salesmanName
          : builder.assignedSalesman;
      builder.lastOrderDate = _latestDate(
        builder.lastOrderDate,
        orderDateFromRow(order),
      );
      builder.orderRevenue += orderRevenue(order);
      final Object? rawItems = order['itemNames'] ?? order['productNames'];
      if (rawItems is List) {
        builder.lastOrderItems = rawItems
            .map((dynamic item) => item.toString())
            .toList(growable: false);
      }
    }

    final Map<String, int> scoreSheetCounts = <String, int>{};
    for (final Map<String, dynamic> sheet in scoreSheets) {
      final String retailerId = _safeText(
        sheet['retailerId'] ?? sheet['retailer_id'],
        fallback: '',
      );
      if (retailerId.isEmpty) continue;
      scoreSheetCounts[retailerId] = scoreSheetProductCount(sheet);
    }

    final List<_RetailerVisitSummary> items = builders.values
        .map((_RetailerVisitSummaryBuilder builder) {
          return builder.build(scoreSheetCounts[builder.retailerId] ?? 0);
        })
        .toList(growable: false);
    items.sort((_RetailerVisitSummary a, _RetailerVisitSummary b) {
      final DateTime aDate =
          a.lastVisitDate ??
          a.lastOrderDate ??
          DateTime.fromMillisecondsSinceEpoch(0);
      final DateTime bDate =
          b.lastVisitDate ??
          b.lastOrderDate ??
          DateTime.fromMillisecondsSinceEpoch(0);
      return bDate.compareTo(aDate);
    });
    return items;
  }

  List<_RetailerFollowUp> _buildFollowUps(
    List<_RetailerVisitSummary> summaries,
  ) {
    final DateTime now = DateTime.now();
    final List<_RetailerFollowUp> items = <_RetailerFollowUp>[];
    for (final _RetailerVisitSummary summary in summaries) {
      final int? daysSinceVisit = summary.lastVisitDate == null
          ? null
          : now.difference(summary.lastVisitDate!).inDays;
      final int? daysSinceOrder = summary.lastOrderDate == null
          ? null
          : now.difference(summary.lastOrderDate!).inDays;
      final bool needsVisit = daysSinceVisit != null && daysSinceVisit >= 14;
      final bool needsOrderFollowUp =
          daysSinceOrder != null && daysSinceOrder >= 18;
      if (!needsVisit && !needsOrderFollowUp) continue;
      items.add(
        _RetailerFollowUp(
          retailerName: summary.retailerName,
          lastVisitDate: summary.lastVisitDate,
          lastOrderDate: summary.lastOrderDate,
          assignedSalesman: summary.assignedSalesman.isEmpty
              ? summary.salesmanName
              : summary.assignedSalesman,
          reason:
              '${daysSinceVisit == null ? 'No recorded visit' : 'Last visit $daysSinceVisit days ago'}, '
              '${daysSinceOrder == null ? 'no recorded order' : 'last order $daysSinceOrder days ago'}.',
          recommendedAction:
              'Schedule a visit this week and confirm restock requirements.',
          isOverdue: (daysSinceVisit ?? 0) >= 21 || (daysSinceOrder ?? 0) >= 30,
        ),
      );
    }
    items.sort((_RetailerFollowUp a, _RetailerFollowUp b) {
      final int aAge = a.daysSinceVisit ?? a.daysSinceOrder ?? 0;
      final int bAge = b.daysSinceVisit ?? b.daysSinceOrder ?? 0;
      return bAge.compareTo(aAge);
    });
    return items;
  }
}

enum _VisitRange { today, week, month, custom }

class _LatestVisitsTab extends StatefulWidget {
  const _LatestVisitsTab({
    required this.visits,
    required this.repository,
    required this.currentUser,
  });

  final List<Map<String, dynamic>> visits;
  final CmsRepository repository;
  final UserProfile currentUser;

  @override
  State<_LatestVisitsTab> createState() => _LatestVisitsTabState();
}

class _LatestVisitsTabState extends State<_LatestVisitsTab> {
  _VisitRange _range = _VisitRange.today;
  String _salesman = 'all';
  String _retailer = 'all';
  int _pagesLoaded = 1;

  DateTimeRange? _customRange;
  VisitWindowRead? _customRead;
  List<Map<String, dynamic>> _customRows = const <Map<String, dynamic>>[];
  List<_PersonRangeSummary> _customSummary = const <_PersonRangeSummary>[];
  bool _customLoading = false;
  bool _customFailed = false;
  int _customDocumentsRead = 0;
  int _customLoadId = 0;

  List<Map<String, dynamic>> get _sourceVisits =>
      _range == _VisitRange.custom ? _customRows : widget.visits;

  @override
  Widget build(BuildContext context) {
    final List<Map<String, dynamic>> filtered = _filteredVisits();
    final bool custom = _range == _VisitRange.custom;
    final List<String> salesmen = _unique(_sourceVisits.map(_displaySalesman));
    final List<String> retailers = _unique(
      _sourceVisits.map(
        (Map<String, dynamic> row) => _safeText(
          row['retailerName'] ?? row['retailer_id'],
          fallback: 'Retailer',
        ),
      ),
    );
    final bool anyFilter = _salesman != 'all' || _retailer != 'all';
    final String when = switch (_range) {
      _VisitRange.today => 'today',
      _VisitRange.week => 'this week',
      _VisitRange.month => 'this month',
      _VisitRange.custom => 'in this range',
    };
    final int people = filtered.map(_displaySalesman).toSet().length;
    final int shops = filtered
        .map(
          (Map<String, dynamic> row) => _safeText(
            row['retailerName'] ?? row['retailer_id'],
            fallback: 'Retailer',
          ),
        )
        .toSet()
        .length;
    final String summary =
        '${filtered.length} visit${filtered.length == 1 ? '' : 's'} $when · '
        '$people salesperson${people == 1 ? '' : 's'} · '
        '$shops retailer${shops == 1 ? '' : 's'}';
    final bool emptyToday =
        _range == _VisitRange.today && !anyFilter && filtered.isEmpty;

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            for (final (String label, _VisitRange range)
                in <(String, _VisitRange)>[
                  ('Today', _VisitRange.today),
                  ('This week', _VisitRange.week),
                  ('This month', _VisitRange.month),
                ])
              PageFilterChip(
                label: label,
                selected: _range == range,
                onTap: () => _setRange(range),
              ),
            PageFilterChip(
              icon: ScootIcons.calendar,
              label: custom && _customRange != null
                  ? 'Custom: ${_dayLabel(_customRange!.start)} - ${_dayLabel(_customRange!.end)}'
                  : 'Custom',
              selected: custom,
              onTap: _pickRange,
            ),
            if (custom)
              OutlinedButton.icon(
                onPressed: _customLoading ? null : _loadCustom,
                icon: const Icon(ScootIcons.refresh, size: 18),
                label: const Text('Refresh'),
              ),
            PageFilterMenu(
              label: 'Salesperson',
              value: _salesman,
              options: <String, String>{
                'all': 'All',
                for (final String v in salesmen.take(80)) v: v,
              },
              onChanged: (String value) => setState(() {
                _salesman = value;
                _pagesLoaded = 1;
              }),
            ),
            PageFilterMenu(
              label: 'Retailer',
              value: _retailer,
              options: <String, String>{
                'all': 'All',
                for (final String v in retailers.take(80)) v: v,
              },
              onChanged: (String value) => setState(() {
                _retailer = value;
                _pagesLoaded = 1;
              }),
            ),
            OutlinedButton.icon(
              onPressed: () => _exportCsv(filtered),
              icon: const Icon(ScootIcons.download, size: 18),
              label: const Text('Export CSV'),
            ),
          ],
        ),
        if (custom && _customLoading) ...<Widget>[
          const SizedBox(height: 12),
          ScootNotice(
            tone: ScootTone.info,
            icon: ScootIcons.hourglass,
            message: 'Reading visits. $_customDocumentsRead read.',
            liveRegion: true,
          ),
        ],
        if (custom && !_customLoading) ..._customNotices(),
        if (_cutNotice() case final String cut)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ScootNotice(
              key: const ValueKey<String>('visit-window-incomplete'),
              tone: ScootTone.warning,
              message:
                  '$cut This list and its totals are incomplete. Choose Custom to read an older range.',
            ),
          ),
        if (custom && !_customLoading && _customSummary.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(top: 12),
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 96),
              child: SingleChildScrollView(
                child: Align(
                  alignment: Alignment.centerLeft,
                  child: Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: <Widget>[
                      for (final _PersonRangeSummary item in _customSummary)
                        _InfoPill(label: item.code, value: item.text),
                    ],
                  ),
                ),
              ),
            ),
          ),
        const SizedBox(height: 12),
        Expanded(
          child: VisitsTableCard(
            phase: custom && _customLoading
                ? ScootLoadPhase.loading
                : ScootLoadPhase.ready,
            rows: <VisitRowData>[
              for (final Map<String, dynamic> log in filtered)
                VisitRowData(
                  retailer: _safeText(
                    log['retailerName'] ?? log['retailer_id'],
                    fallback: 'Retailer',
                  ),
                  salesperson: _displaySalesman(log),
                  arrived: _toDateTime(
                    log['arrivalTime'] ?? log['arrival_time'],
                  ),
                  left: _toDateTime(
                    log['departureTime'] ?? log['departure_time'],
                  ),
                  assignedRoute: log['source'] == assignedRouteVisitSource,
                  status: _visitStatus(log).replaceAll(' ', '_'),
                ),
            ],
            onRetry: _loadCustom,
            emptyTitle: emptyToday
                ? 'No visits recorded today'
                : 'No visits match this filter',
            emptyMessage: emptyToday
                ? 'Visits appear when a salesperson arrives at a retailer.'
                : 'Try a wider date range or clear the salesperson and retailer filters.',
            emptyAction: emptyToday
                ? OutlinedButton(
                    key: const ValueKey<String>('visit-show-week'),
                    onPressed: () => _setRange(_VisitRange.week),
                    child: const Text('Show this week'),
                  )
                : null,
            summary: summary,
            showDate: _range != _VisitRange.today,
            pagesLoaded: _pagesLoaded,
            hasMore: filtered.length > _pagesLoaded * ScootPaging.pageSize,
            onLoadMore: () => setState(() => _pagesLoaded++),
          ),
        ),
      ],
    );
  }

  String? _cutNotice() {
    if (_range == _VisitRange.custom) return null;
    final DateTime now = DateTime.now().toUtc().add(const Duration(hours: 8));
    return newestWindowNotice(widget.visits, switch (_range) {
      _VisitRange.week => kuchingDayStartUtc(
        now.year,
        now.month,
        now.day - (now.weekday - 1),
      ),
      _VisitRange.month => kuchingDayStartUtc(now.year, now.month, 1),
      _ => kuchingDayStartUtc(now.year, now.month, now.day),
    }, what: 'visits');
  }

  void _setRange(_VisitRange range) {
    setState(() {
      _range = range;
      _pagesLoaded = 1;
    });
  }

  Future<void> _pickRange() async {
    final DateTime kuchingNow = DateTime.now().toUtc().add(
      const Duration(hours: 8),
    );
    final DateTime today = DateTime(
      kuchingNow.year,
      kuchingNow.month,
      kuchingNow.day,
    );
    final DateTimeRange? picked = await showDateRangePicker(
      context: context,
      firstDate: DateTime(today.year - 2, today.month, today.day),
      lastDate: today,
      initialDateRange: _customRange,
    );
    if (picked == null || !mounted) return;
    setState(() {
      _range = _VisitRange.custom;
      _customRange = picked;
      _pagesLoaded = 1;
    });
    await _loadCustom();
  }

  Future<void> _loadCustom() async {
    final DateTimeRange? range = _customRange;
    if (range == null) return;
    final int loadId = ++_customLoadId;
    setState(() {
      _customLoading = true;
      _customFailed = false;
      _customDocumentsRead = 0;
    });
    final DateTime start = kuchingDayStartUtc(
      range.start.year,
      range.start.month,
      range.start.day,
    );
    final DateTime end = kuchingDayStartUtc(
      range.end.year,
      range.end.month,
      range.end.day + 1,
    );
    try {
      final Future<VisitWindowRead> visitsRead = widget.repository
          .getVisitsBetween(
            start: start,
            end: end,
            onProgress: (int documentsRead) {
              if (mounted && loadId == _customLoadId) {
                setState(() => _customDocumentsRead = documentsRead);
              }
            },
          );
      final Future<OrderWindowRead?> ordersRead = widget.repository
          .getOrdersSubmittedBetween(start: start, end: end)
          .then<OrderWindowRead?>((OrderWindowRead orders) => orders)
          .onError<Object>((Object _, StackTrace _) => null);
      final VisitWindowRead read = await visitsRead;
      final OrderWindowRead? orders = await ordersRead;
      if (!mounted || loadId != _customLoadId) return;
      setState(() {
        _customRead = read;
        _customRows = TeamScope.filter(widget.currentUser, read.rows).toList()
          ..sort(
            (Map<String, dynamic> a, Map<String, dynamic> b) =>
                _sortTimeValue(b).compareTo(_sortTimeValue(a)),
          );
        _customSummary = _summariseRange(
          TeamScope.filter(widget.currentUser, read.routeStopRows).toList(),
          orders?.rows,
        );
        _customLoading = false;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'visit_logs_range_read_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || loadId != _customLoadId) return;
      setState(() {
        _customFailed = true;
        _customLoading = false;
        _customRead = null;
        _customRows = const <Map<String, dynamic>>[];
        _customSummary = const <_PersonRangeSummary>[];
      });
    }
  }

  List<Widget> _customNotices() {
    final VisitWindowRead? read = _customRead;
    final List<(ScootTone, String)> notices = <(ScootTone, String)>[
      if (_customFailed)
        (
          ScootTone.danger,
          'Visits for this range could not be loaded. Check your connection and press Refresh.',
        ),
      if (!_customFailed && read != null && read.truncated)
        (
          ScootTone.warning,
          'This range has more ${read.visitLogsTruncated && read.routeStopsTruncated
                  ? 'visit logs and assigned-route stops'
                  : read.visitLogsTruncated
                  ? 'visit logs'
                  : 'assigned-route stops'} '
              'than are read at once, so the oldest are missing. Choose a shorter range.',
        ),
      if (!_customFailed && read != null && read.rowsWithoutTimestamp > 0)
        (
          ScootTone.info,
          read.rowsWithoutTimestamp == 1
              ? '1 row has no timestamp arrival and is not in this range.'
              : '${read.rowsWithoutTimestamp} rows have no timestamp arrival and are not in this range.',
        ),
    ];
    return <Widget>[
      for (final (ScootTone tone, String message) in notices)
        Padding(
          padding: const EdgeInsets.only(top: 12),
          child: ScootNotice(tone: tone, message: message),
        ),
    ];
  }

  void _exportCsv(List<Map<String, dynamic>> filtered) {
    if (filtered.isEmpty) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Nothing to export for the current filters.'),
        ),
      );
      return;
    }

    const List<String> header = <String>[
      'Arrival',
      'Departure',
      'Salesman',
      'Retailer',
      'Status',
      'Source',
      'Arrival mode',
      'Arrival distance (m)',
    ];
    final List<List<Object?>> rows = filtered
        .map((Map<String, dynamic> log) {
          return <Object?>[
            _formatKualaLumpurTime(log['arrivalTime'] ?? log['arrival_time']),
            _formatKualaLumpurTime(
              log['departureTime'] ?? log['departure_time'],
              fallback: 'In progress',
            ),
            _displaySalesman(log),
            _safeText(
              log['retailerName'] ?? log['retailer_id'],
              fallback: 'Retailer',
            ),
            _visitStatus(log),
            log['source'] == assignedRouteVisitSource ? 'Assigned route' : '',
            _safeText(log['arrivalMode'], fallback: ''),
            _safeText(log['arrivalDistanceMeters'], fallback: ''),
          ];
        })
        .toList(growable: false);

    final DateTime now = DateTime.now();
    final String stamp =
        '${now.year.toString().padLeft(4, '0')}${_twoDigits(now.month)}${_twoDigits(now.day)}'
        '_${_twoDigits(now.hour)}${_twoDigits(now.minute)}';
    final bool ok = downloadCsv(
      filename: 'visit_logs_export_$stamp.csv',
      csv: buildCsv(header, <List<Object?>>[
        ...rows,
        if (_cutNotice() case final String cut)
          <Object?>[
            '$cut This export is incomplete.',
            ...List<Object?>.filled(header.length - 1, ''),
          ],
      ]),
    );
    if (!ok && mounted) {
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Export is only available in the web build.'),
        ),
      );
    }
  }

  List<Map<String, dynamic>> _filteredVisits() {
    return _sourceVisits
        .where((Map<String, dynamic> row) {
          final DateTime? date = visitDateFromRow(row);
          if (date == null || !_inSelectedRange(date)) return false;
          if (_salesman != 'all' && _displaySalesman(row) != _salesman) {
            return false;
          }
          if (_retailer != 'all' &&
              _safeText(
                    row['retailerName'] ?? row['retailer_id'],
                    fallback: 'Retailer',
                  ) !=
                  _retailer) {
            return false;
          }
          return true;
        })
        .toList(growable: false);
  }

  bool _inSelectedRange(DateTime date) {
    final DateTime now = DateTime.now().toUtc().add(const Duration(hours: 8));
    final DateTime local = date.toUtc().add(const Duration(hours: 8));
    final DateTime today = DateTime.utc(now.year, now.month, now.day);
    final DateTime localDay = DateTime.utc(local.year, local.month, local.day);
    switch (_range) {
      case _VisitRange.today:
        return localDay == today;
      case _VisitRange.week:
        return !localDay.isBefore(
          today.subtract(Duration(days: today.weekday - 1)),
        );
      case _VisitRange.month:
        return local.year == now.year && local.month == now.month;
      case _VisitRange.custom:
        final DateTimeRange range = _customRange!;
        return !localDay.isBefore(
              DateTime.utc(
                range.start.year,
                range.start.month,
                range.start.day,
              ),
            ) &&
            !localDay.isAfter(
              DateTime.utc(range.end.year, range.end.month, range.end.day),
            );
    }
  }
}

class _PersonRangeSummary {
  const _PersonRangeSummary({
    required this.code,
    required this.arrived,
    required this.skipped,
    required this.onSite,
    required this.orders,
  });

  final String code;
  final int arrived;
  final int skipped;
  final int onSite;
  final int? orders;

  String get text =>
      '$arrived arrived, $skipped skipped after arrival, '
      '${arrived == 0 ? '-' : '${(onSite * 100 / arrived).round()}%'} on-site GPS'
      '${orders == null ? '' : ', $orders orders'}';
}

List<_PersonRangeSummary> _summariseRange(
  List<Map<String, dynamic>> routeStops,
  List<Map<String, dynamic>>? orders,
) {
  final Map<String, List<int>> counts = <String, List<int>>{};
  List<int> slot(String code) =>
      counts.putIfAbsent(code, () => <int>[0, 0, 0, 0]);
  for (final Map<String, dynamic> row in routeStops) {
    final String code = TeamScope.salesmanCodeOf(row);
    if (code.isEmpty) continue;
    final List<int> counter = slot(code);
    if (row['arrivalTime'] != null) {
      counter[0]++;
      if (row['arrivalMode'] == 'location_verified') counter[2]++;
      if (row['status'] == 'skipped') counter[1]++;
    }
  }
  for (final Map<String, dynamic> order
      in orders ?? const <Map<String, dynamic>>[]) {
    final String code = TeamScope.salesmanCodeOf(order);
    if (code.isNotEmpty && !isDemoRow(order) && orderCountsAsSale(order)) {
      slot(code)[3]++;
    }
  }
  return counts.entries
      .map(
        (MapEntry<String, List<int>> entry) => _PersonRangeSummary(
          code: entry.key,
          arrived: entry.value[0],
          skipped: entry.value[1],
          onSite: entry.value[2],
          orders: orders == null ? null : entry.value[3],
        ),
      )
      .toList(growable: false)
    ..sort(
      (_PersonRangeSummary a, _PersonRangeSummary b) =>
          a.code.compareTo(b.code),
    );
}

class _PlannedVisitsTab extends StatelessWidget {
  const _PlannedVisitsTab({required this.stream});

  final Stream<List<Map<String, dynamic>>> stream;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: stream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snap,
          ) {
            final List<Map<String, dynamic>> rows =
                (snap.data ?? <Map<String, dynamic>>[]).toList()..sort(
                  (Map<String, dynamic> a, Map<String, dynamic> b) =>
                      '${b['date']} ${b['time']}'.compareTo(
                        '${a['date']} ${a['time']}',
                      ),
                );
            final Widget body;
            if (snap.hasError) {
              body = const Center(
                child: ScootEmptyState(
                  icon: ScootIcons.cloudOff,
                  title: 'Planned visits could not be loaded',
                  message: 'Try again in a moment.',
                ),
              );
            } else if (!snap.hasData) {
              body = SingleChildScrollView(
                physics: const NeverScrollableScrollPhysics(),
                padding: const EdgeInsets.all(ScootSpace.lg),
                child: Column(
                  children: <Widget>[
                    for (int i = 0; i < 5; i++)
                      const Padding(
                        padding: EdgeInsets.only(bottom: 12),
                        child: ScootSkeleton(height: 48, radius: 10),
                      ),
                  ],
                ),
              );
            } else if (rows.isEmpty) {
              body = const Center(
                child: ScootEmptyState(
                  icon: ScootIcons.calendar,
                  title: 'No planned visits',
                  message: 'Visits salespeople plan in the app appear here.',
                ),
              );
            } else {
              body = ListView.separated(
                itemCount: rows.length,
                separatorBuilder: (_, _) => Divider(height: 1, color: c.hair),
                itemBuilder: (BuildContext context, int index) {
                  final Map<String, dynamic> row = rows[index];
                  final String purpose = _safeText(
                    row['purpose'],
                    fallback: '',
                  );
                  return Padding(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 12,
                    ),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              ScootLongText(
                                _safeText(
                                  row['marketplace'],
                                  fallback: 'Retailer',
                                ),
                                maxLines: 1,
                                style: ScootType.bodyStrong.copyWith(
                                  color: c.ink,
                                ),
                              ),
                              ScootLongText(
                                '${_safeText(row['salesmanCode'], fallback: '-')}'
                                '${purpose.isEmpty ? '' : ' · $purpose'}',
                                maxLines: 1,
                                style: ScootType.small.copyWith(color: c.muted),
                              ),
                            ],
                          ),
                        ),
                        Text(
                          '${_safeText(row['date'], fallback: '-')} ${_safeText(row['time'], fallback: '')}'
                              .trim(),
                          style: ScootType.small.copyWith(color: c.text2),
                        ),
                      ],
                    ),
                  );
                },
              );
            }
            return Container(
              clipBehavior: Clip.antiAlias,
              decoration: BoxDecoration(
                color: c.card,
                border: Border.all(color: c.line),
                borderRadius: ScootRadius.cardAll,
              ),
              child: body,
            );
          },
    );
  }
}

class _RetailerVisitSummaryBuilder {
  _RetailerVisitSummaryBuilder({
    required this.retailerId,
    required this.retailerName,
  });

  final String retailerId;
  final String retailerName;
  String salesmanName = '';
  String assignedSalesman = '';
  DateTime? lastVisitDate;
  DateTime? lastDepartureDate;
  DateTime? lastOrderDate;
  int visitRows = 0;
  double orderRevenue = 0;
  List<String> lastOrderItems = <String>[];

  _RetailerVisitSummary build(int assignedProductCount) {
    return _RetailerVisitSummary(
      retailerId: retailerId,
      retailerName: retailerName.isEmpty ? retailerId : retailerName,
      salesmanName: salesmanName,
      assignedSalesman: assignedSalesman,
      lastVisitDate: lastVisitDate,
      lastDepartureDate: lastDepartureDate,
      lastOrderDate: lastOrderDate,
      visitRows: visitRows,
      orderRevenue: orderRevenue,
      assignedProductCount: assignedProductCount,
      lastOrderItems: lastOrderItems,
    );
  }
}

class _RetailerVisitSummary {
  const _RetailerVisitSummary({
    required this.retailerId,
    required this.retailerName,
    required this.salesmanName,
    required this.assignedSalesman,
    required this.lastVisitDate,
    required this.lastDepartureDate,
    required this.lastOrderDate,
    required this.visitRows,
    required this.orderRevenue,
    required this.assignedProductCount,
    required this.lastOrderItems,
  });

  final String retailerId;
  final String retailerName;
  final String salesmanName;
  final String assignedSalesman;
  final DateTime? lastVisitDate;
  final DateTime? lastDepartureDate;
  final DateTime? lastOrderDate;
  final int visitRows;
  final double orderRevenue;
  final int assignedProductCount;
  final List<String> lastOrderItems;
}

class _RetailerFollowUp {
  const _RetailerFollowUp({
    required this.retailerName,
    required this.lastVisitDate,
    required this.lastOrderDate,
    required this.assignedSalesman,
    required this.reason,
    required this.recommendedAction,
    required this.isOverdue,
  });

  final String retailerName;
  final DateTime? lastVisitDate;
  final DateTime? lastOrderDate;
  final String assignedSalesman;
  final String reason;
  final String recommendedAction;
  final bool isOverdue;

  int? get daysSinceVisit => lastVisitDate == null
      ? null
      : DateTime.now().difference(lastVisitDate!).inDays;
  int? get daysSinceOrder => lastOrderDate == null
      ? null
      : DateTime.now().difference(lastOrderDate!).inDays;
}

List<String> _unique(Iterable<String> values) {
  final List<String> items =
      values
          .where((String value) => value.trim().isNotEmpty)
          .toSet()
          .toList(growable: false)
        ..sort();
  return items;
}

String _retailerKey(Map<String, dynamic> item) {
  return _safeText(
    item['retailerId'] ??
        item['retailer_id'] ??
        item['retailerCode'] ??
        item['retailer_code'] ??
        item['docId'] ??
        item['retailerName'],
    fallback: '',
  );
}

String _retailerName(Map<String, dynamic> item) {
  return _safeText(
    item['retailerName'] ??
        item['retailer_name'] ??
        item['outletName'] ??
        item['storeName'] ??
        item['name'],
    fallback: '',
  );
}

String _displaySalesman(Map<String, dynamic> item) {
  final String name = _safeText(
    item['salesmanName'] ??
        item['salesman_name'] ??
        item['submittedByName'] ??
        item['name'],
    fallback: '',
  );
  if (name.isNotEmpty && !_isUnknown(name)) return name;
  final String id = _safeText(
    item['salesmanId'] ??
        item['salesman_id'] ??
        item['staffId'] ??
        item['employeeCode'],
    fallback: '',
  );
  if (id.isNotEmpty && !_isUnknown(id)) return id;
  return 'Salesman';
}

bool _isUnknown(String value) {
  final String text = value.trim().toLowerCase();
  return text.isEmpty ||
      text == 'unknown' ||
      text == 'unknown salesman' ||
      text == 'null' ||
      text == '-' ||
      text == 'n/a';
}

DateTime? _latestDate(DateTime? a, DateTime? b) {
  if (a == null) return b;
  if (b == null) return a;
  return b.isAfter(a) ? b : a;
}

String _safeText(Object? value, {required String fallback}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  return text.isEmpty || text.toLowerCase() == 'null' ? fallback : text;
}

String _formatKualaLumpurTime(Object? value, {String fallback = '-'}) {
  final DateTime? dateTime = _toDateTime(value);
  if (dateTime == null) return fallback;
  final DateTime klTime = dateTime.toUtc().add(const Duration(hours: 8));
  return '${_twoDigits(klTime.day)}/${_twoDigits(klTime.month)}/${klTime.year} '
      '${_twoDigits(klTime.hour)}:${_twoDigits(klTime.minute)} MYT';
}

String _dateLabel(DateTime? value) {
  if (value == null) return 'No record';
  final DateTime klTime = value.toUtc().add(const Duration(hours: 8));
  return '${_twoDigits(klTime.day)}/${_twoDigits(klTime.month)}/${klTime.year}';
}

String _dayLabel(DateTime day) =>
    '${_twoDigits(day.day)}/${_twoDigits(day.month)}/${day.year}';

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is num) {
    final bool looksLikeMilliseconds = value.abs() > 9999999999;
    return DateTime.fromMillisecondsSinceEpoch(
      looksLikeMilliseconds ? value.round() : (value * 1000).round(),
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

String _sortTimeValue(Map<String, dynamic> item) {
  final DateTime? dateTime = visitDateFromRow(item);
  return dateTime?.toUtc().toIso8601String() ?? '';
}

String _twoDigits(int value) => value.toString().padLeft(2, '0');

class _InfoPill extends StatelessWidget {
  const _InfoPill({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: c.card,
        borderRadius: ScootRadius.pillAll,
        border: Border.all(color: c.line2),
      ),
      child: Text(
        '$label: $value',
        style: ScootType.small.copyWith(color: c.text2),
      ),
    );
  }
}

String _visitStatus(Map<String, dynamic> log) {
  if (log['status'] == 'skipped') return 'skipped';
  return _safeText(
        log['departureTime'] ?? log['departure_time'],
        fallback: '',
      ).isEmpty
      ? 'in progress'
      : 'completed';
}
