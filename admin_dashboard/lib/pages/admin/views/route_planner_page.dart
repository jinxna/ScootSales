import '../../../utils/collection_rows.dart';
import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:latlong2/latlong.dart';

import '../../../app/build_flags.dart';
import '../../../models/route_plan.dart';
import '../../../models/retailer_segment.dart';
import '../../../models/user_profile.dart';
import '../../../widgets/page_snack_bars.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/geoapify_routing_client.dart';
import '../../../services/route_planning_service.dart';
import '../../../services/retailer_segment_service.dart';
import '../../../services/outcome_review_service.dart';
import '../../../services/visit_priority_service.dart';
import '../../../models/retailer_priority_ranking.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../../../widgets/dso_filter_controls.dart';
import '../../../utils/app_logger.dart';
import '../../../utils/firestore_value_equality.dart';
import '../../../utils/geo_field_utils.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/retailer_readiness.dart';
import '../../../utils/route_execution.dart';
import '../../../utils/route_assignment_status.dart';
import '../../../utils/route_regions.dart';
import '../../../utils/visit_priority.dart';
import '../../../utils/route_travel_time.dart';
import '../../../utils/user_facing_error.dart';
import '../../../theme/dso_colors.dart';
import '../widgets/cms_panel.dart';
import 'route_planner/route_plan_workspace.dart';

enum _PlannerWorkspace { plan, priorities, savedPlans, health }

class RoutePlannerPage extends StatefulWidget {
  const RoutePlannerPage({
    super.key,
    required this.currentUser,
    this.onNavigateRequested,
    this.initialSalesmanUid,
    this.initialWeekStart,
  });

  final UserProfile currentUser;
  final ValueChanged<String>? onNavigateRequested;

  final String? initialSalesmanUid;
  final DateTime? initialWeekStart;

  @override
  State<RoutePlannerPage> createState() => _RoutePlannerPageState();
}

@visibleForTesting
int plannerInitialSalesmanIndex(List<String> uids, String? wantedUid) {
  final int i = wantedUid == null ? -1 : uids.indexOf(wantedUid);
  return i < 0 ? 0 : i;
}

@visibleForTesting
DateTime plannerInitialWeekStart(DateTime? requested, DateTime fallback) =>
    requested == null ? fallback : _mondayOf(requested);

@visibleForTesting
String? plannerStartedWeekWarning(DateTime weekStart, DateTime now) {
  final DateTime nowKl = now.toUtc().add(const Duration(hours: 8));
  final DateTime today = DateTime(nowKl.year, nowKl.month, nowKl.day);
  final DateTime monday = _mondayOf(weekStart);
  if (monday.isAfter(today)) return null;
  return 'This week has already started. The salesperson sees the route '
      'straight away, and days that have passed cannot be worked.';
}

@visibleForTesting
RoutePlan? plannerPlanToOpen(List<RoutePlan> plans, DateTime weekStart) {
  final DateTime monday = _mondayOf(weekStart);
  RoutePlan? latestPublished;
  for (final RoutePlan plan in plans) {
    if (_mondayOf(plan.weekStart) == monday) return plan;
    if (plan.status.toLowerCase() != 'published') continue;
    if (latestPublished == null ||
        plan.weekStart.isAfter(latestPublished.weekStart)) {
      latestPublished = plan;
    }
  }
  return latestPublished;
}

bool shouldShowPrioritiesFreshnessChip({required String? salesmanUid}) =>
    salesmanUid?.trim().isNotEmpty ?? false;

class _RoutePlannerPageState extends State<RoutePlannerPage>
    with PageSnackBars<RoutePlannerPage> {
  final CmsRepository _repository = CmsRepository();
  final RoutePlanningService _service = RoutePlanningService();
  final RetailerSegmentService _segmentService = RetailerSegmentService();
  final OutcomeReviewService _outcomeService = OutcomeReviewService();
  final VisitPriorityService _priorityService = VisitPriorityService();

  static const Duration _loadTimeout = Duration(seconds: 12);

  bool _loading = true;
  bool _loadError = false;
  List<_Salesman> _salesmen = <_Salesman>[];
  List<Map<String, dynamic>> _retailers = <Map<String, dynamic>>[];
  Map<String, RetailerSegment> _segments = <String, RetailerSegment>{};

  _Salesman? _selectedSalesman;
  DateTime _weekStart = _mondayOf(DateTime.now().add(const Duration(days: 7)));
  int _maxPerDay = 6;
  int _serviceMinutes = 20;
  final Set<String> _excludedRetailerIds = <String>{};
  bool _showRetailerPicker = false;
  bool _showSettings = true;

  bool _verifiedOnly = false;

  bool _generating = false;
  RoutePlan? _plan;

  List<String> _roadNotes = <String>[];

  final Set<String> _manuallyRecomputedDayIds = <String>{};

  _PlannerWorkspace _workspace = _PlannerWorkspace.plan;

  int _selectedDay = 0;
  bool _saving = false;

  List<RoutePlan> _existingPlans = <RoutePlan>[];

  Set<String> _dueFollowUpRetailerIds = <String>{};

  Map<String, ServiceTimeStat> _learnedServiceTimesForPlan =
      const <String, ServiceTimeStat>{};

  StreamSubscription<List<Map<String, dynamic>>>? _progressSubscription;
  int _progressEmission = 0;

  final Map<String, Map<String, dynamic>> _stopHistoryProgress =
      <String, Map<String, dynamic>>{};
  StreamSubscription<List<Map<String, dynamic>>>? _retailerSubscription;
  List<Map<String, dynamic>> _progressDocs = <Map<String, dynamic>>[];

  Map<String, List<Map<String, dynamic>>> _stopArrivalByPlan =
      <String, List<Map<String, dynamic>>>{};
  bool _progressLoading = false;
  bool _progressHasError = false;

  VisitPriorityInputs _priorityInputs = VisitPriorityInputs.empty;
  bool _prioritiesLoading = true;
  bool _prioritiesError = false;
  bool _prioritiesExpanded = true;

  int _prioritiesLoadSeq = 0;

  List<VisitPriority>? _prioritiesCache;
  VisitPriorityInputs? _prioritiesCacheInputs;
  List<Map<String, dynamic>>? _prioritiesCacheProgressDocs;
  List<Map<String, dynamic>>? _prioritiesCacheRetailers;
  _Salesman? _prioritiesCacheSalesman;
  _WeeklyPriorities? _weeklyPrioritiesCache;

  String get _branchManagerReadScope =>
      widget.currentUser.isBranchManager ? widget.currentUser.branchId : '';

  bool get _readOnly => widget.currentUser.isBranchManager;

  bool get _queryByUid => !widget.currentUser.isSupervisor;

  void _subscribeProgress() {
    _progressSubscription?.cancel();
    _progressSubscription = null;
    _progressEmission++;
    _stopHistoryProgress.clear();
    final _Salesman? s = _selectedSalesman;
    setState(() {
      _progressDocs = <Map<String, dynamic>>[];
      _stopArrivalByPlan = <String, List<Map<String, dynamic>>>{};
      _progressLoading = s != null;
      _progressHasError = false;
    });
    if (s == null) return;
    _progressSubscription = _service
        .watchProgressForSalesman(
          s.uid,
          salesmanCode: s.code,
          branchId: _branchManagerReadScope,
          queryByUid: _queryByUid,
        )
        .listen(
          (List<Map<String, dynamic>> docs) async {
            if (!mounted) return;
            final int emission = ++_progressEmission;
            final Map<String, Map<String, dynamic>> progressByPlan =
                <String, Map<String, dynamic>>{
                  for (final Map<String, dynamic> doc in docs)
                    if ((doc['planId'] ?? '').toString().trim().isNotEmpty)
                      (doc['planId'] ?? '').toString().trim(): doc,
                };
            final List<String> changed = <String>[
              for (final MapEntry<String, Map<String, dynamic>> entry
                  in progressByPlan.entries)
                if (!sameFirestoreValue(
                  _stopHistoryProgress[entry.key],
                  entry.value,
                ))
                  entry.key,
            ];
            final Map<String, List<Map<String, dynamic>>> stopsByPlan =
                <String, List<Map<String, dynamic>>>{
                  for (final String planId in progressByPlan.keys)
                    if (_stopArrivalByPlan.containsKey(planId))
                      planId: _stopArrivalByPlan[planId]!,
                };
            bool loaded = false;
            try {
              if (changed.isNotEmpty) {
                final List<Map<String, dynamic>> stops = await _service
                    .loadStopArrivalDocuments(
                      planIds: changed,
                      salesmanCode: s.code,
                      branchId: _branchManagerReadScope,
                    );
                for (final String planId in changed) {
                  stopsByPlan.remove(planId);
                }
                for (final Map<String, dynamic> stop in stops) {
                  final String planId = (stop['planId'] ?? '')
                      .toString()
                      .trim();
                  if (planId.isEmpty) continue;
                  stopsByPlan
                      .putIfAbsent(planId, () => <Map<String, dynamic>>[])
                      .add(stop);
                }
              }
              loaded = true;
            } catch (_) {}
            if (!mounted || emission != _progressEmission) return;
            if (loaded) {
              _stopHistoryProgress
                ..removeWhere(
                  (String planId, _) => !progressByPlan.containsKey(planId),
                )
                ..addAll(<String, Map<String, dynamic>>{
                  for (final String planId in changed)
                    planId: progressByPlan[planId]!,
                });
            }
            setState(() {
              _progressDocs = docs;
              _stopArrivalByPlan = stopsByPlan;
              _progressLoading = false;
              _progressHasError = !loaded || !collectionRowsComplete(docs);
            });
          },
          onError: (Object _, StackTrace _) {
            if (!mounted) return;
            setState(() {
              _progressLoading = false;
              _progressHasError = true;
            });
          },
        );
  }

  @override
  void initState() {
    super.initState();
    _weekStart = plannerInitialWeekStart(widget.initialWeekStart, _weekStart);
    _loadData();
  }

  @override
  void didUpdateWidget(RoutePlannerPage old) {
    super.didUpdateWidget(old);
    if (old.initialSalesmanUid == widget.initialSalesmanUid &&
        old.initialWeekStart == widget.initialWeekStart) {
      return;
    }
    if (_loading || _salesmen.isEmpty) return;
    final _Salesman next =
        _salesmen[plannerInitialSalesmanIndex(
          _salesmen.map((_Salesman s) => s.uid).toList(),
          widget.initialSalesmanUid,
        )];
    final bool salesmanChanged = next.uid != _selectedSalesman?.uid;
    setState(() {
      _selectedSalesman = next;
      _weekStart = plannerInitialWeekStart(widget.initialWeekStart, _weekStart);
      if (salesmanChanged) _plan = null;
    });
    if (salesmanChanged) {
      _subscribeProgress();
      _loadExistingPlans();
      _loadFollowUps();
      _loadAssignedRetailers();
    }
  }

  @override
  void dispose() {
    _progressSubscription?.cancel();
    _retailerSubscription?.cancel();
    _assignedSubscription?.cancel();
    super.dispose();
  }

  void _subscribeRetailers({
    Completer<List<Map<String, dynamic>>>? firstEmission,
  }) {
    _retailerSubscription?.cancel();
    _retailerSubscription = _repository
        .watchCollectionRaw('retailers', limit: 3000)
        .listen(
          (List<Map<String, dynamic>> rows) {
            if (!mounted) return;
            final List<Map<String, dynamic>> scoped = _scopeRetailers(rows);
            final Set<String> currentIds = scoped
                .map(_retailerId)
                .where((String id) => id.isNotEmpty)
                .toSet();
            if (firstEmission != null && !firstEmission.isCompleted) {
              firstEmission.complete(scoped);
            }
            setState(() {
              _retailers = scoped;
              _excludedRetailerIds.removeWhere(
                (String id) => !currentIds.contains(id),
              );
            });
          },
          onError: (Object error, StackTrace stackTrace) {
            if (firstEmission != null && !firstEmission.isCompleted) {
              firstEmission.completeError(error, stackTrace);
            }
            AppLogger.error(
              'route_planner_retailer_watch_failed',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
  }

  Future<void> _loadData() async {
    setState(() {
      _loading = true;
      _loadError = false;
    });
    try {
      final Completer<List<Map<String, dynamic>>> firstRetailers =
          Completer<List<Map<String, dynamic>>>();
      _subscribeRetailers(firstEmission: firstRetailers);
      final Future<Map<String, RetailerSegment>> segmentsFuture = isBasicEdition
          ? Future<Map<String, RetailerSegment>>.value(
              <String, RetailerSegment>{},
            )
          : _segmentService
                .loadSegments(widget.currentUser)
                .timeout(_loadTimeout)
                .catchError((Object _) => <String, RetailerSegment>{});
      final List<List<Map<String, dynamic>>> data =
          await Future.wait(<Future<List<Map<String, dynamic>>>>[
            _repository.getCollectionOnce(
              'users',
              limit: 3000,
              timeout: _loadTimeout,
            ),
            firstRetailers.future.timeout(_loadTimeout),
          ], eagerError: true);
      final List<_Salesman> salesmen = _scopeSalesmen(data[0]);
      final List<Map<String, dynamic>> retailers = data[1];
      final Map<String, RetailerSegment> segments = await segmentsFuture;
      if (!mounted) return;
      setState(() {
        _salesmen = salesmen;
        _retailers = retailers;
        _segments = segments;
        _selectedSalesman = salesmen.isNotEmpty
            ? salesmen[plannerInitialSalesmanIndex(
                salesmen.map((_Salesman s) => s.uid).toList(),
                widget.initialSalesmanUid,
              )]
            : null;
        _loading = false;
      });
      _subscribeProgress();
      if (!isBasicEdition) _loadPriorityInputs();
      if (_selectedSalesman != null) {
        _loadAssignedRetailers();
        unawaited(_loadFollowUps());
        await _loadExistingPlans();
      }
    } catch (error, stackTrace) {
      AppLogger.error(
        'route_planner_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() {
        _loadError = true;
        _loading = false;
      });
    }
  }

  Future<void> _loadExistingPlans() async {
    final _Salesman? s = _selectedSalesman;
    if (s == null) return;
    final List<RoutePlan> plans = await _service.loadPlansForSalesman(
      s.uid,
      salesmanCode: s.code,
      branchId: _branchManagerReadScope,
      queryByUid: _queryByUid,
    );
    if (!mounted || _selectedSalesman?.uid != s.uid) return;
    final List<RoutePlan> visible = plans
        .where(
          (RoutePlan plan) =>
              !plan.isDemo &&
              plan.metricSourceMethod.toLowerCase() != 'demo' &&
              plan.status.toLowerCase() != 'archived',
        )
        .toList(growable: false);
    setState(() {
      _existingPlans = visible;
      if (_readOnly && widget.initialWeekStart == null && _plan == null) {
        final RoutePlan? open = plannerPlanToOpen(visible, _weekStart);
        if (open != null) {
          _weekStart = _mondayOf(open.weekStart);
          _plan = open;
          _selectedDay = _firstNonEmptyDay(open);
        }
      }
    });
  }

  Future<void> _loadFollowUps() async {
    final _Salesman? s = _selectedSalesman;
    if (s == null) {
      if (mounted) setState(() => _dueFollowUpRetailerIds = <String>{});
      return;
    }
    final Set<String> ids = await _outcomeService.loadDueFollowUpRetailerIds(
      widget.currentUser,
      salesmanUid: s.uid,
      salesmanCode: s.code,
    );
    if (!mounted || _selectedSalesman?.uid != s.uid) return;
    setState(() => _dueFollowUpRetailerIds = ids);
  }

  Future<void> _loadPriorityInputs() async {
    final int seq = ++_prioritiesLoadSeq;
    setState(() {
      _prioritiesLoading = true;
      _prioritiesError = false;
    });
    try {
      final VisitPriorityInputs inputs = await _priorityService.loadInputs(
        widget.currentUser,
      );
      if (!mounted || seq != _prioritiesLoadSeq) return;
      setState(() {
        _priorityInputs = inputs;
        _prioritiesLoading = false;
        _prioritiesError = inputs.allSourcesFailed;
      });
    } catch (error, stackTrace) {
      AppLogger.error(
        'route_planner_priorities_load_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted || seq != _prioritiesLoadSeq) return;
      setState(() {
        _prioritiesLoading = false;
        _prioritiesError = true;
      });
    }
  }

  List<_Salesman> _scopeSalesmen(List<Map<String, dynamic>> users) {
    final List<_Salesman> all = <_Salesman>[];
    for (final Map<String, dynamic> u in users) {
      final String role = _text(u['role'] ?? u['user_group']).toLowerCase();
      if (!role.contains('salesman') && !role.contains('sales')) continue;
      final String status = _text(u['status']).toLowerCase();
      if (status == 'suspended' || status == 'inactive') continue;
      final String code = _text(
        _first(u, const <String>[
          'employeeCode',
          'employee_code',
          'staffId',
          'staff_id',
          'salesmanId',
          'salesman_id',
        ]),
      );
      all.add(
        _Salesman(
          uid: _text(_first(u, const <String>['uid', 'docId'])),
          name: _text(
            _first(u, const <String>['name', 'displayName', 'display_name']),
            fallback: code.isEmpty ? 'Salesman' : code,
          ),
          code: code,
          branchId: _text(u['branchId'] ?? u['branch_id']),
        ),
      );
    }

    if (widget.currentUser.isSupervisor) {
      final List<String> assigned = widget.currentUser.assignedSalesmanCodes;
      return all
          .where(
            (_Salesman s) =>
                assigned.contains(s.code) || assigned.contains(s.uid),
          )
          .toList();
    }
    if (widget.currentUser.isBranchManager &&
        widget.currentUser.branchId.isNotEmpty) {
      return all
          .where((_Salesman s) => s.branchId == widget.currentUser.branchId)
          .toList();
    }
    return all;
  }

  List<Map<String, dynamic>> _scopeRetailers(
    List<Map<String, dynamic>> retailers,
  ) {
    if (widget.currentUser.isBranchManager &&
        widget.currentUser.branchId.isNotEmpty) {
      return retailers
          .where(
            (Map<String, dynamic> r) =>
                _text(r['branchId'] ?? r['branch_id']) ==
                widget.currentUser.branchId,
          )
          .toList();
    }
    return retailers;
  }

  List<Map<String, dynamic>> get _visibleRetailers {
    final Set<String> loaded = _retailers.map(_retailerId).toSet();
    return <Map<String, dynamic>>[
      ..._retailers,
      ..._scopeRetailers(
        _assignedRetailers,
      ).where((Map<String, dynamic> r) => !loaded.contains(_retailerId(r))),
    ].where(isOperationalRetailerRecord).toList(growable: false);
  }

  List<Map<String, dynamic>> _assignedRetailers = <Map<String, dynamic>>[];

  StreamSubscription<List<Map<String, dynamic>>>? _assignedSubscription;

  void _loadAssignedRetailers() {
    _assignedSubscription?.cancel();
    final _Salesman? s = _selectedSalesman;
    if (s == null) {
      if (mounted) {
        setState(() => _assignedRetailers = <Map<String, dynamic>>[]);
      }
      return;
    }
    _assignedSubscription = _service
        .watchRetailersAssignedTo(
          salesmanCode: s.code,
          salesmanUid: s.uid,
          branchId: widget.currentUser.isAdmin
              ? ''
              : widget.currentUser.branchId,
        )
        .listen(
          (List<Map<String, dynamic>> rows) {
            if (!mounted || _selectedSalesman?.uid != s.uid) return;
            setState(() => _assignedRetailers = rows);
          },
          onError: (Object error, StackTrace stackTrace) {
            AppLogger.error(
              'route_planner_assigned_retailers_failed',
              error: error,
              stackTrace: stackTrace,
            );
          },
        );
  }

  List<Map<String, dynamic>> _candidateRetailers() {
    final _Salesman? s = _selectedSalesman;
    if (s == null) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> visible = _visibleRetailers;
    final List<Map<String, dynamic>> assigned = visible.where((
      Map<String, dynamic> r,
    ) {
      final Object? codes =
          r['assignedSalesmanCodes'] ?? r['assigned_salesman_codes'];
      if (codes is List && (codes.contains(s.code) || codes.contains(s.uid))) {
        return true;
      }
      final Object? assignedUsers =
          r['assignedUsers'] ?? r['assigned_users'] ?? r['assignedTo'];
      if (assignedUsers is List &&
          (assignedUsers.contains(s.code) || assignedUsers.contains(s.uid))) {
        return true;
      }
      final Object? snakeAssigned =
          r['assigned_salesmen'] ?? r['assignedSalesmen'];
      if (snakeAssigned is List &&
          (snakeAssigned.contains(s.code) || snakeAssigned.contains(s.uid))) {
        return true;
      }
      final String single = _text(
        _first(r, const <String>[
          'assignedSalesmanUid',
          'assigned_salesman_uid',
          'assignedSalesmanId',
          'assigned_salesman_id',
          'assignedSalesmanCode',
          'assigned_salesman_code',
          'salesmanId',
          'salesman_id',
          'salesmanUid',
          'salesman_uid',
          'salesmanCode',
          'salesman_code',
          'assignedSalesman',
          'assigned_salesman',
          'assignedTo',
        ]),
      );
      if (single.isNotEmpty && (single == s.code || single == s.uid)) {
        return true;
      }
      return false;
    }).toList();
    return assigned;
  }

  bool get _usingFallbackRetailers {
    final _Salesman? s = _selectedSalesman;
    if (s == null) return false;
    final List<Map<String, dynamic>> cands = _candidateRetailers();
    final List<Map<String, dynamic>> visible = _visibleRetailers;
    return cands.length == visible.length && visible.isNotEmpty;
  }

  List<Map<String, dynamic>> _withCoordinates(List<Map<String, dynamic>> rows) {
    return rows.where(hasLatLng).toList();
  }

  List<Map<String, dynamic>> _selectedRetailers() {
    final Iterable<Map<String, dynamic>> base = _verifiedOnly
        ? _candidateRetailers().where(isRetailerRouteReady)
        : _withCoordinates(_candidateRetailers());
    return base
        .where(
          (Map<String, dynamic> r) =>
              !_excludedRetailerIds.contains(_retailerId(r)),
        )
        .toList();
  }

  Future<void> _generate() async {
    final _Salesman? s = _selectedSalesman;
    if (s == null) return;
    final List<Map<String, dynamic>> retailers = _selectedRetailers();
    if (retailers.isEmpty) {
      showPageSnackBar(
        _verifiedOnly
            ? 'No retailers with verified coordinates. Turn off "Verified only" or verify coordinates first.'
            : 'No retailers with coordinates are available for this salesman.',
      );
      return;
    }
    setState(() => _generating = true);
    try {
      final Map<String, ServiceTimeStat> learnedServiceTimes = await _service
          .loadLearnedServiceTimes(
            salesmanUid: s.uid,
            salesmanCode: s.code,
            branchId: _branchManagerReadScope,
            queryByUid: _queryByUid,
          );
      final RoutePlan plan = await _service.generateWeeklyRoute(
        salesmanUid: s.uid,
        salesmanCode: s.code,
        salesmanName: s.name,
        weekStart: _weekStart,
        retailers: retailers,
        branchId: s.branchId.isNotEmpty
            ? s.branchId
            : widget.currentUser.branchId,
        createdByUid: widget.currentUser.uid ?? '',
        createdByRole: widget.currentUser.role,
        maxPerDay: _maxPerDay,
        serviceMinutes: _serviceMinutes,
        learnedServiceTimes: learnedServiceTimes,
        lastVisitByRetailer: resolveLastVisitByRetailer(
          progressDocs: _progressDocs,
          visitLogRows: _priorityInputs.visitLogRows,
        ),
      );
      if (!mounted) return;
      setState(() {
        _plan = plan;
        _roadNotes = plan.roadRouteNotes;
        _manuallyRecomputedDayIds.clear();
        _learnedServiceTimesForPlan = learnedServiceTimes;
        _selectedDay = _firstNonEmptyDay(plan);
        _showSettings = false;
        _generating = false;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _generating = false);
      showPageSnackBar('Could not generate the route plan.');
    }
  }

  Future<void> _save({String? status}) async {
    final RoutePlan? plan = _plan;
    if (plan == null) return;
    setState(() => _saving = true);
    try {
      final RoutePlan toSave = status == null
          ? plan
          : plan.copyWith(status: status);
      final String id = await _service.savePlan(toSave);
      if (!mounted) return;
      setState(() {
        _plan = RoutePlan(
          id: id,
          weekStart: toSave.weekStart,
          weekEnd: toSave.weekEnd,
          status: toSave.status,
          branchId: toSave.branchId,
          createdByUid: toSave.createdByUid,
          createdByRole: toSave.createdByRole,
          salesmanUid: toSave.salesmanUid,
          salesmanCode: toSave.salesmanCode,
          salesmanName: toSave.salesmanName,
          source: toSave.source,
          planVersion: toSave.planVersion,
          isDemo: toSave.isDemo,
          optimisationMethod: toSave.optimisationMethod,
          days: toSave.days,
          approvedAt: toSave.approvedAt,
          publishedAt: toSave.publishedAt,
          createdAt: toSave.createdAt,
          updatedAt: toSave.updatedAt,
        );
        _saving = false;
      });
      unawaited(_loadExistingPlans());
      if (!mounted) return;
      final RouteAssignmentStatus assignment = routeAssignmentStatus(
        status: toSave.status,
        salesmanName: toSave.salesmanName,
      );
      showPageSnackBar(assignment.message);
    } catch (error, stackTrace) {
      AppLogger.error(
        'route_plan_save_failed',
        error: error,
        stackTrace: stackTrace,
      );
      if (!mounted) return;
      setState(() => _saving = false);
      final String errorText = error.toString();
      final bool duplicate = errorText.contains(
        'published route already exists',
      );
      showPageSnackBar(
        duplicate
            ? 'Publishing blocked: a published route already exists for this salesman and week.'
            : userFacingError(error, action: 'save the plan'),
      );
    }
  }

  Future<String?> _refreshRoadRoute(int dayIndex) async {
    final RoutePlan? plan = _plan;
    if (plan == null || plan.status == 'published') {
      return 'Published plans are locked.';
    }
    final RouteDay day = plan.days[dayIndex];
    if (day.stops.isEmpty) return 'This day has no stops.';
    final List<RouteStop> all = <RouteStop>[
      for (final RouteDay d in plan.days) ...d.stops,
    ];
    final LatLng anchor = LatLng(
      all.fold<double>(0, (double a, RouteStop s) => a + s.lat) / all.length,
      all.fold<double>(0, (double a, RouteStop s) => a + s.lng) / all.length,
    );
    try {
      final RouteDay refreshed = await _service.refreshRoadGeometry(
        day,
        anchor: anchor,
        serviceMinutes: _serviceMinutes,
        learnedServiceTimes: _learnedServiceTimesForPlan,
      );
      if (!mounted) return null;
      if (!identical(_plan, plan)) {
        return 'The plan changed while routing. Try again.';
      }
      final List<RouteDay> days = List<RouteDay>.of(plan.days);
      days[dayIndex] = refreshed;
      _manuallyRecomputedDayIds.remove(day.dayId);
      setState(() => _plan = plan.copyWith(days: days));
      return null;
    } on GeoapifyRoutingException catch (error) {
      return error.message;
    } catch (_) {
      return 'Road route unavailable.';
    }
  }

  void _removeStop(int dayIndex, RouteStop stop) {
    final RoutePlan? plan = _plan;
    if (plan == null) return;
    final List<RouteDay> days = List<RouteDay>.of(plan.days);
    final RouteDay day = days[dayIndex];
    final List<RouteStop> remaining = day.stops
        .where((RouteStop s) => s.retailerId != stop.retailerId)
        .toList();
    days[dayIndex] = _service.recomputeDay(
      day.copyWith(stops: remaining),
      serviceMinutes: _serviceMinutes,
      learnedServiceTimes: _learnedServiceTimesForPlan,
    );
    if (_isRoadTimingMethod(plan.metricSourceMethod)) {
      _manuallyRecomputedDayIds.add(day.dayId);
    }
    setState(
      () => _plan = plan.copyWith(
        days: days,
        optimisationMethod: _methodAfterManualEdit(plan, days),
      ),
    );
  }

  void _reorderStop(int dayIndex, int oldIndex, int newIndex) {
    final RoutePlan? plan = _plan;
    if (plan == null || plan.status != 'draft') return;
    if (newIndex > oldIndex) newIndex -= 1;
    if (oldIndex == newIndex) return;
    final List<RouteDay> days = List<RouteDay>.of(plan.days);
    final RouteDay day = days[dayIndex];
    final List<RouteStop> stops = List<RouteStop>.of(day.stops);
    stops.insert(newIndex, stops.removeAt(oldIndex));
    days[dayIndex] = _service.recomputeDay(
      day.copyWith(stops: stops),
      serviceMinutes: _serviceMinutes,
      learnedServiceTimes: _learnedServiceTimesForPlan,
    );
    if (_isRoadTimingMethod(plan.metricSourceMethod)) {
      _manuallyRecomputedDayIds.add(day.dayId);
    }
    setState(
      () => _plan = plan.copyWith(
        days: days,
        optimisationMethod: _methodAfterManualEdit(plan, days),
      ),
    );
  }

  String _methodAfterManualEdit(RoutePlan plan, List<RouteDay> days) {
    final String original = plan.metricSourceMethod;
    if (!_isRoadTimingMethod(original)) return original;
    final Set<String> populatedDayIds = days
        .where((RouteDay day) => day.stops.isNotEmpty)
        .map((RouteDay day) => day.dayId)
        .toSet();
    if (populatedDayIds.isEmpty) return original;
    final bool everyPopulatedDayEdited = populatedDayIds.every(
      _manuallyRecomputedDayIds.contains,
    );
    if (everyPopulatedDayEdited) return 'ManualHaversineRecompute';
    if (original == 'GeoapifyRouteMatrix') {
      return 'GeoapifyRouteMatrixMixedHaversineFallback';
    }
    if (original == 'GeoapifyRouting') {
      return 'GeoapifyRoutingMixedHaversineFallback';
    }
    if (original == 'GeoapifyRoadMixedSources') {
      return 'GeoapifyRoadMixedHaversineFallback';
    }
    return original == 'OSRMTable'
        ? 'OSRMTableMixedHaversineFallback'
        : original;
  }

  Future<void> _pickWeek() async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _weekStart,
      firstDate: DateTime(2023),
      lastDate: DateTime(2030),
      helpText: 'Pick any day in the target week',
    );
    if (picked == null) return;
    setState(() => _weekStart = _mondayOf(picked));
  }

  @override
  Widget build(BuildContext context) {
    if (_loading) {
      return const Center(
        child: Padding(
          padding: EdgeInsets.all(40),
          child: CircularProgressIndicator(),
        ),
      );
    }
    if (_loadError) {
      return _panel(
        'Route Planner',
        Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const _Empty(
              icon: ScootIcons.error,
              title: 'Could not load planning data',
              subtitle:
                  'Users and retailers could not be read. Check your connection and retry.',
            ),
            const SizedBox(height: 4),
            FilledButton.icon(
              onPressed: _loadData,
              icon: const Icon(ScootIcons.refresh, size: 18),
              label: const Text('Retry'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      );
    }
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        if (_workspace == _PlannerWorkspace.plan &&
            box.hasBoundedHeight &&
            box.maxWidth >= 720) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              _workspaceSwitcher(),
              const SizedBox(height: 12),
              Expanded(child: _planWorkspace(pinned: true)),
            ],
          );
        }
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              _workspaceSwitcher(),
              const SizedBox(height: 16),
              ..._workspacePanels(),
            ],
          ),
        );
      },
    );
  }

  Widget _workspaceSwitcher() {
    final List<(_PlannerWorkspace, String, IconData)> workspaces =
        <(_PlannerWorkspace, String, IconData)>[
          (_PlannerWorkspace.plan, 'Plan', Icons.alt_route),
          if (!isBasicEdition)
            (_PlannerWorkspace.priorities, 'Priorities', ScootIcons.reports),
          (
            _PlannerWorkspace.savedPlans,
            'Saved plans',
            Icons.event_note_outlined,
          ),
          (
            _PlannerWorkspace.health,
            'Coverage & health',
            Icons.monitor_heart_outlined,
          ),
        ];
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        if (constraints.maxWidth < 640) {
          return Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final (_PlannerWorkspace value, String label, IconData icon)
                  in workspaces)
                ChoiceChip(
                  avatar: Icon(icon, size: 18),
                  label: Text(label),
                  selected: _workspace == value,
                  showCheckmark: false,
                  onSelected: (_) => setState(() => _workspace = value),
                ),
            ],
          );
        }
        return SizedBox(
          width: double.infinity,
          child: SingleChildScrollView(
            scrollDirection: Axis.horizontal,
            child: SegmentedButton<_PlannerWorkspace>(
              segments: <ButtonSegment<_PlannerWorkspace>>[
                for (final (
                      _PlannerWorkspace value,
                      String label,
                      IconData icon,
                    )
                    in workspaces)
                  ButtonSegment<_PlannerWorkspace>(
                    value: value,
                    label: Text(label),
                    icon: Icon(icon, size: 18),
                  ),
              ],
              selected: <_PlannerWorkspace>{_workspace},
              showSelectedIcon: false,
              onSelectionChanged: (Set<_PlannerWorkspace> selection) {
                if (selection.isEmpty) return;
                setState(() => _workspace = selection.first);
              },
            ),
          ),
        );
      },
    );
  }

  List<Widget> _workspacePanels() {
    switch (_workspace) {
      case _PlannerWorkspace.priorities:
        return <Widget>[_weeklyPrioritiesPanel()];
      case _PlannerWorkspace.savedPlans:
        return <Widget>[_existingPlansPanel()];
      case _PlannerWorkspace.health:
        return <Widget>[
          _healthPanel(),
          const SizedBox(height: 16),
          _executionIntelligencePanel(),
        ];
      case _PlannerWorkspace.plan:
        return <Widget>[_planWorkspace(pinned: false)];
    }
  }

  Widget _planWorkspace({required bool pinned}) {
    final RoutePlan? plan = _plan;
    final Widget body = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        AnimatedSize(
          duration: const Duration(milliseconds: 220),
          curve: Curves.easeOutCubic,
          alignment: Alignment.topCenter,
          child: _showSettings && !_readOnly
              ? Padding(
                  padding: const EdgeInsets.only(bottom: 12),
                  child: _planSettings(),
                )
              : const SizedBox(width: double.infinity),
        ),
        if (_generating)
          _generatingState()
        else if (plan != null)
          _planResult(plan)
        else
          _emptyPlanState(),
      ],
    );
    final Widget? footer = plan == null || _generating
        ? null
        : _planFooter(plan);
    if (!pinned) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _commandBar(plan),
          const SizedBox(height: 12),
          body,
          if (footer != null) ...<Widget>[const SizedBox(height: 12), footer],
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _commandBar(plan),
        const SizedBox(height: 12),
        Expanded(child: SingleChildScrollView(child: body)),
        if (footer != null) ...<Widget>[const SizedBox(height: 12), footer],
      ],
    );
  }

  bool _planUsesRoadTiming(RoutePlan? plan) => plan == null
      ? _service.isRoadRoutingConfigured
      : _isRoadTimingMethod(plan.metricSourceMethod) &&
            plan.metricSourceMethod != 'ManualHaversineRecompute';

  Widget _commandBar(RoutePlan? plan) {
    final DsoColors dso = context.dso;
    final int selectedCount = _selectedRetailers().length;
    final bool canGenerate = _selectedSalesman != null && selectedCount > 0;
    return Container(
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) => Wrap(
          spacing: 12,
          runSpacing: 10,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            SizedBox(
              width: constraints.maxWidth < 230 ? constraints.maxWidth : 230,
              height: 40,
              child: Semantics(
                label: 'Salesman',
                child: DropdownButtonFormField<String>(
                  initialValue: _selectedSalesman?.uid,
                  isExpanded: true,
                  style: TextStyle(
                    fontSize: DsoFilterMetrics.fontSize,
                    color: dso.body,
                  ),
                  hint: const Text('Salesman'),
                  decoration: dsoFilterDropdownDecoration(
                    context,
                    prefixIcon: const Icon(
                      ScootIcons.person,
                      size: DsoFilterMetrics.iconSize,
                    ),
                  ),
                  items: _salesmen
                      .map(
                        (_Salesman s) => DropdownMenuItem<String>(
                          value: s.uid,
                          child: Text(s.name, overflow: TextOverflow.ellipsis),
                        ),
                      )
                      .toList(),
                  onChanged: (String? uid) {
                    final _Salesman? s = _salesmen
                        .where((_Salesman e) => e.uid == uid)
                        .cast<_Salesman?>()
                        .firstWhere((_) => true, orElse: () => null);
                    setState(() {
                      _selectedSalesman = s;
                      _excludedRetailerIds.clear();
                      _plan = null;
                      _learnedServiceTimesForPlan =
                          const <String, ServiceTimeStat>{};
                      _dueFollowUpRetailerIds = <String>{};
                    });
                    _subscribeProgress();
                    _loadExistingPlans();
                    _loadFollowUps();
                    _loadAssignedRetailers();
                  },
                ),
              ),
            ),
            _weekSwitcher(),
            _estimateChip(plan),
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                if (!_readOnly)
                  OutlinedButton.icon(
                    onPressed: () =>
                        setState(() => _showSettings = !_showSettings),
                    icon: Icon(
                      _showSettings ? Icons.expand_less : ScootIcons.settings,
                      size: 18,
                    ),
                    label: Text(
                      _showSettings ? 'Hide settings' : 'Plan settings',
                    ),
                  ),
                if (!_readOnly)
                  FilledButton.icon(
                    onPressed: canGenerate && !_generating ? _generate : null,
                    icon: const Icon(Icons.auto_awesome_outlined, size: 18),
                    label: Text(
                      plan == null
                          ? 'Generate draft route'
                          : 'Regenerate draft route',
                    ),
                  ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _weekSwitcher() {
    final DsoColors dso = context.dso;
    final DateTime end = _weekStart.add(const Duration(days: 5));
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = MediaQuery.sizeOf(context).width < 600;
        final Widget previousWeek = IconButton(
          tooltip: 'Previous week',
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(
            () => _weekStart = _weekStart.subtract(const Duration(days: 7)),
          ),
          icon: const Icon(Icons.chevron_left, size: 20),
        );
        final Widget dateButton = TextButton.icon(
          onPressed: _pickWeek,
          icon: const Icon(ScootIcons.calendar, size: 15),
          label: Text(
            '${_fmtDate(_weekStart)} – ${_fmtDate(end)}',
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
          ),
        );
        final Widget nextWeek = IconButton(
          tooltip: 'Next week',
          visualDensity: VisualDensity.compact,
          onPressed: () => setState(
            () => _weekStart = _weekStart.add(const Duration(days: 7)),
          ),
          icon: const Icon(ScootIcons.chevronRight, size: 20),
        );

        return Container(
          width: compact && constraints.hasBoundedWidth
              ? constraints.maxWidth
              : null,
          decoration: BoxDecoration(
            border: Border.all(color: dso.hairline),
            borderRadius: BorderRadius.circular(10),
          ),
          child: Row(
            mainAxisSize: compact ? MainAxisSize.max : MainAxisSize.min,
            children: <Widget>[
              previousWeek,
              if (compact) Expanded(child: dateButton) else dateButton,
              nextWeek,
            ],
          ),
        );
      },
    );
  }

  Widget _estimateChip(RoutePlan? plan) {
    final DsoColors dso = context.dso;
    final bool road = _planUsesRoadTiming(plan);
    final String label = plan == null
        ? road
              ? 'Road estimate'
              : 'Haversine estimate'
        : _methodLabel(plan.metricSourceMethod);
    final String detail = road
        ? 'Distance and travel-time provenance comes from each route day. '
              'Geoapify road routing or matrix metrics are labelled as road '
              'estimates; days without road data use straight-line Haversine '
              'fallbacks.'
        : 'Distances are straight-line (Haversine) with an average driving '
              'speed, so real road distance and time will be longer. Configure '
              'Geoapify to use road travel times.';
    final Color fg = road ? dso.successText : dso.warningText;
    return Tooltip(
      message: plan == null
          ? detail
          : '$detail\nThis plan: ${_methodLabel(plan.metricSourceMethod)}.',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
        decoration: BoxDecoration(
          color: road ? dso.successSoft : dso.warningSoft,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(
              road ? Icons.alt_route : Icons.straighten,
              size: 15,
              color: fg,
            ),
            const SizedBox(width: 6),
            Text(
              label,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
            const SizedBox(width: 4),
            Icon(ScootIcons.info, size: 13, color: fg),
          ],
        ),
      ),
    );
  }

  Widget _planSettings() {
    final DsoColors dso = context.dso;
    final List<Map<String, dynamic>> candidateCoords = _withCoordinates(
      _candidateRetailers(),
    );
    final int missingCoordinateCount =
        _candidateRetailers().length - candidateCoords.length;
    final List<Map<String, dynamic>> selectedRetailers = _selectedRetailers();
    final int selectedCount = selectedRetailers.length;
    final int verifiedCount = _candidateRetailers()
        .where(isRetailerRouteReady)
        .length;
    final int unverifiedSelected = selectedRetailers
        .where((Map<String, dynamic> r) => !isRetailerRouteReady(r))
        .length;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 24,
            runSpacing: 14,
            crossAxisAlignment: WrapCrossAlignment.start,
            children: <Widget>[
              _field(
                'Max stops / day',
                _stepper(
                  label: 'max stops per day',
                  value: _maxPerDay,
                  min: 3,
                  max: 12,
                  onChanged: (int v) => setState(() => _maxPerDay = v),
                ),
              ),
              _field(
                'Service (min)',
                _stepper(
                  label: 'service minutes',
                  value: _serviceMinutes,
                  min: 5,
                  max: 60,
                  step: 5,
                  onChanged: (int v) => setState(() => _serviceMinutes = v),
                ),
              ),
              _field(
                'Coordinates',
                SizedBox(
                  width: 210,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      Switch(
                        value: _verifiedOnly,
                        onChanged: (bool v) =>
                            setState(() => _verifiedOnly = v),
                      ),
                      const SizedBox(width: 4),
                      Expanded(
                        child: Text(
                          'Verified only ($verifiedCount)',
                          style: TextStyle(fontSize: 12.5, color: dso.body),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final Widget coordinateIcon = Icon(
                ScootIcons.store,
                size: 18,
                color: candidateCoords.isEmpty ? dso.danger : dso.muted,
              );
              final Widget coordinateSummary = Text(
                '${candidateCoords.length} retailer(s) with coordinates · '
                '$selectedCount selected'
                '${_usingFallbackRetailers ? ' · no explicit assignment, showing all visible retailers' : ''}',
                style: TextStyle(fontSize: 12.5, color: dso.muted),
              );
              final Widget chooseRetailers = TextButton.icon(
                onPressed: candidateCoords.isEmpty
                    ? null
                    : () => setState(
                        () => _showRetailerPicker = !_showRetailerPicker,
                      ),
                icon: Icon(
                  _showRetailerPicker
                      ? Icons.expand_less
                      : Icons.checklist_outlined,
                  size: 18,
                ),
                label: Text(_showRetailerPicker ? 'Hide' : 'Choose retailers'),
              );

              if (constraints.maxWidth < 320) {
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    Row(
                      children: <Widget>[
                        coordinateIcon,
                        const SizedBox(width: 8),
                        Expanded(child: coordinateSummary),
                      ],
                    ),
                    Align(
                      alignment: Alignment.centerRight,
                      child: chooseRetailers,
                    ),
                  ],
                );
              }

              return Row(
                children: <Widget>[
                  coordinateIcon,
                  const SizedBox(width: 8),
                  Expanded(child: coordinateSummary),
                  chooseRetailers,
                ],
              );
            },
          ),
          if (_selectedSalesman != null && _candidateRetailers().isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: _WarningNote(
                text:
                    'No retailers are assigned to this salesman. Assign '
                    'retailers in Retailer Management first, then generate '
                    'the route.',
              ),
            )
          else if (candidateCoords.isEmpty && _candidateRetailers().isNotEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: _WarningNote(
                text:
                    'Retailers missing coordinates. Route planner needs GPS fields to generate routes.',
              ),
            )
          else if (missingCoordinateCount > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _WarningNote(
                text:
                    '$missingCoordinateCount visible retailer(s) are missing usable coordinates and were excluded.',
              ),
            ),
          if (!_verifiedOnly && unverifiedSelected > 0)
            Padding(
              padding: const EdgeInsets.only(top: 10),
              child: _WarningNote(
                text:
                    '$unverifiedSelected selected retailer(s) have unverified '
                    'coordinates. Routes still generate; verify them in '
                    'Coordinate Review for confident routing.',
              ),
            ),
          if (_verifiedOnly && verifiedCount == 0)
            const Padding(
              padding: EdgeInsets.only(top: 10),
              child: _WarningNote(
                text:
                    'Verified only is on but no retailer has verified '
                    'coordinates yet — nothing to route. Verify coordinates or '
                    'turn this off to plan on unverified data.',
              ),
            ),
          if (_showRetailerPicker) _retailerPicker(candidateCoords),
        ],
      ),
    );
  }

  Widget _generatingState() {
    final DsoColors dso = context.dso;
    return Container(
      height: 360,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      child: Semantics(
        liveRegion: true,
        label: 'Generating route plan',
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            SizedBox(
              width: 36,
              height: 36,
              child: CircularProgressIndicator(
                strokeWidth: 3,
                color: dso.accent,
              ),
            ),
            const SizedBox(height: 16),
            Text(
              'Building the week',
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w800,
                color: dso.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Sequencing stops and estimating travel times…',
              style: TextStyle(fontSize: 12.5, color: dso.muted),
            ),
          ],
        ),
      ),
    );
  }

  Widget _emptyPlanState() {
    final DsoColors dso = context.dso;
    const List<String> days = <String>[
      'Mon',
      'Tue',
      'Wed',
      'Thu',
      'Fri',
      'Sat',
    ];
    return Container(
      padding: const EdgeInsets.fromLTRB(24, 28, 24, 28),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      child: Column(
        children: <Widget>[
          Wrap(
            spacing: 10,
            runSpacing: 10,
            alignment: WrapAlignment.center,
            children: <Widget>[
              for (int i = 0; i < days.length; i++)
                Container(
                  width: 112,
                  padding: const EdgeInsets.all(12),
                  decoration: BoxDecoration(
                    color: dso.surfaceSoft,
                    borderRadius: BorderRadius.circular(14),
                  ),
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Container(
                            width: 8,
                            height: 8,
                            decoration: BoxDecoration(
                              color: routeDayColor(i).withValues(alpha: 0.7),
                              shape: BoxShape.circle,
                            ),
                          ),
                          const SizedBox(width: 6),
                          Text(
                            days[i],
                            style: TextStyle(
                              fontWeight: FontWeight.w800,
                              color: dso.muted,
                            ),
                          ),
                        ],
                      ),
                      const SizedBox(height: 10),
                      ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: 0,
                          minHeight: 5,
                          backgroundColor: dso.hairline,
                        ),
                      ),
                    ],
                  ),
                ),
            ],
          ),
          const SizedBox(height: 24),
          Text(
            'No plan generated yet',
            style: TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w800,
              color: dso.ink,
            ),
          ),
          const SizedBox(height: 6),
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 480),
            child: Text(
              _readOnly
                  ? 'Choose a salesman to view the routes planned for them. '
                        'Branch managers have view-only access; a supervisor '
                        'or administrator plans and publishes routes.'
                  : 'Choose a salesman and week, then generate a draft '
                        'Monday–Saturday route. You can reorder or remove stops before '
                        'you approve and publish it.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, height: 1.5, color: dso.muted),
            ),
          ),
        ],
      ),
    );
  }

  Widget _planResult(RoutePlan plan) {
    final Map<String, CoordinateStatus> statuses = <String, CoordinateStatus>{
      for (final Map<String, dynamic> r in _retailers)
        _retailerId(r): retailerCoordinateStatus(r),
    };
    CoordinateStatus? statusFor(RouteStop s) {
      final CoordinateStatus? known = statuses[s.retailerId];
      if (known != null) return known;
      final Map<String, dynamic>? snapshot = s.retailerCoordinateSnapshot;
      return snapshot == null ? null : retailerCoordinateStatus(snapshot);
    }

    return RoutePlanWorkspace(
      plan: plan,
      selectedDay: _selectedDay,
      onSelectDay: (int i) => setState(() => _selectedDay = i),
      editable: plan.status == 'draft' && !_readOnly,
      maxPerDay: _maxPerDay,
      coordinateStatusFor: statusFor,
      segmentBadgeFor: _segmentBadgeFor,
      onRemoveStop: _removeStop,
      onReorderStop: _reorderStop,
      roadNotes: _roadNotes,
      onDismissRoadNotes: () => setState(() => _roadNotes = <String>[]),
      roadRoutingConfigured: _service.isRoadRoutingConfigured,
      onRefreshRoadRoute: _readOnly ? null : _refreshRoadRoute,
    );
  }

  Widget _planFooter(RoutePlan plan) {
    final RouteAssignmentStatus assignment = routeAssignmentStatus(
      status: plan.status,
      salesmanName: plan.salesmanName,
    );
    return RoutePlanFooter(
      status: plan.status,
      title: assignment.title,
      message: assignment.message,
      saved: plan.id.isNotEmpty,
      saving: _saving,
      readOnly: _readOnly,
      onSave: () => _save(status: 'draft'),
      onApprove: () => _save(status: 'approved'),
      onPublish: () => _confirmPublish(plan),
      onWithdraw: () => _withdraw(plan),
      onBackToDraft: () => _backToDraft(plan),
    );
  }

  Widget _retailerPicker(List<Map<String, dynamic>> candidates) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      margin: const EdgeInsets.only(top: 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(12, 8, 8, 4),
            child: Row(
              children: <Widget>[
                const Expanded(
                  child: Text(
                    'Include retailers',
                    style: TextStyle(fontWeight: FontWeight.w700, fontSize: 13),
                  ),
                ),
                TextButton(
                  onPressed: () => setState(() => _excludedRetailerIds.clear()),
                  child: const Text('Select all'),
                ),
                TextButton(
                  onPressed: () => setState(() {
                    _excludedRetailerIds
                      ..clear()
                      ..addAll(candidates.map(_retailerId));
                  }),
                  child: const Text('Clear'),
                ),
              ],
            ),
          ),
          ConstrainedBox(
            constraints: const BoxConstraints(maxHeight: 220),
            child: ListView.builder(
              shrinkWrap: true,
              padding: EdgeInsets.zero,
              itemCount: candidates.length,
              itemBuilder: (BuildContext context, int index) {
                final Map<String, dynamic> r = candidates[index];
                final String id = _retailerId(r);
                final bool included = !_excludedRetailerIds.contains(id);
                return CheckboxListTile(
                  dense: true,
                  controlAffinity: ListTileControlAffinity.leading,
                  value: included,
                  title: Text(
                    _text(
                      _first(r, const <String>[
                        'name',
                        'retailerName',
                        'retailer_name',
                      ]),
                      fallback: id,
                    ),
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: const TextStyle(fontSize: 13),
                  ),
                  subtitle: _segmentBadgeFor(id),
                  onChanged: (bool? v) {
                    setState(() {
                      if (v == true) {
                        _excludedRetailerIds.remove(id);
                      } else {
                        _excludedRetailerIds.add(id);
                      }
                    });
                  },
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _existingPlansPanel() {
    return CmsPanel(
      title: 'Saved plans for this salesman',
      expandBody: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: _existingPlans.isEmpty
            ? const _Empty(
                icon: Icons.history_outlined,
                title: 'No saved plans yet',
                subtitle: 'Generated plans you save will appear here.',
              )
            : Builder(
                builder: (BuildContext context) {
                  final Map<String, Map<String, dynamic>> progressByPlan =
                      <String, Map<String, dynamic>>{};
                  for (final Map<String, dynamic> row in _progressDocs) {
                    final String planId = _text(row['planId']);
                    if (planId.isNotEmpty) progressByPlan[planId] = row;
                  }
                  return Column(
                    children: <Widget>[
                      for (final RoutePlan p in _existingPlans)
                        ListTile(
                          contentPadding: EdgeInsets.zero,
                          leading: const Icon(Icons.route_outlined),
                          title: Text(
                            '${_fmtDate(p.weekStart)} - ${_fmtDate(p.weekEnd)}',
                            style: const TextStyle(fontWeight: FontWeight.w700),
                          ),
                          subtitle: Text(
                            '${p.totalStops} stops | ${p.totalDistanceKm.toStringAsFixed(1)} km | ${_methodLabel(p.metricSourceMethod)}\n'
                            '${_progressSummary(p, progressByPlan[p.id])}',
                          ),
                          trailing: Wrap(
                            spacing: 8,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              _statusChip(p.status),
                              TextButton(
                                onPressed: () => setState(() {
                                  _plan = p;
                                  _weekStart = _mondayOf(p.weekStart);
                                  _roadNotes = <String>[];
                                  _manuallyRecomputedDayIds.clear();
                                  _learnedServiceTimesForPlan =
                                      const <String, ServiceTimeStat>{};
                                  _selectedDay = _firstNonEmptyDay(p);
                                }),
                                child: const Text('View'),
                              ),
                            ],
                          ),
                        ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  String _progressSummary(RoutePlan plan, Map<String, dynamic>? progress) {
    if (progress == null) return 'No mobile progress yet';
    final String status = _text(progress['status'], fallback: 'assigned');
    final Map<String, String> statusByStop = <String, String>{
      for (final Map<String, dynamic> stop
          in _stopArrivalByPlan[plan.id] ?? const <Map<String, dynamic>>[])
        _text(stop['stopId'], fallback: _text(stop['docId'])): _text(
          stop['status'],
        ).toLowerCase(),
    };
    final int completed = statusByStop.values
        .where((String stopStatus) => stopStatus == 'completed')
        .length;
    final int skipped = statusByStop.values
        .where((String stopStatus) => stopStatus == 'skipped')
        .length;
    final String updated = _formatRelative(
      progress['updatedAt'] ?? progress['lastSyncedAt'],
    );
    return 'Mobile status: ${_titleCase(status)} | completed $completed/${plan.totalStops} | skipped $skipped | updated $updated';
  }

  Widget _weeklyPrioritiesPanel() {
    final _Salesman? salesman = _selectedSalesman;
    final RetailerPriorityRanking? ranking = salesman == null
        ? null
        : RetailerPriorityRanking.newestActive(
            _priorityInputs.priorityRankings,
            salesmanUid: salesman.uid,
            salesmanCode: salesman.code,
          );
    Widget body;
    if (!_prioritiesExpanded) {
      body = const SizedBox.shrink();
    } else if (salesman == null) {
      body = const _Empty(
        icon: Icons.flag_outlined,
        title: 'Select a salesman',
        subtitle:
            'Priorities are ranked over that salesman\'s candidate retailers.',
      );
    } else if (_prioritiesLoading ||
        (_progressLoading && _progressDocs.isEmpty)) {
      body = const Padding(
        padding: EdgeInsets.all(12),
        child: Center(child: CircularProgressIndicator()),
      );
    } else if (_prioritiesError) {
      body = Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const _Empty(
            icon: ScootIcons.error,
            title: 'Could not load priority signals',
            subtitle:
                'Insights, briefs, memory and products could not be read. '
                'Check your connection and access, then retry.',
          ),
          const SizedBox(height: 4),
          FilledButton.icon(
            onPressed: _loadPriorityInputs,
            icon: const Icon(ScootIcons.refresh, size: 18),
            label: const Text('Retry'),
          ),
          const SizedBox(height: 8),
        ],
      );
    } else {
      body = _prioritiesBody();
    }
    return CmsPanel(
      title: salesman == null
          ? 'This week\'s priorities'
          : 'This week\'s priorities for ${salesman.name}',
      expandBody: false,
      trailing: IconButton(
        tooltip: _prioritiesExpanded ? 'Collapse' : 'Expand',
        visualDensity: VisualDensity.compact,
        onPressed: () =>
            setState(() => _prioritiesExpanded = !_prioritiesExpanded),
        icon: Icon(
          _prioritiesExpanded ? Icons.expand_less : ScootIcons.expandMore,
          size: 20,
        ),
      ),
      child: Padding(
        padding: _prioritiesExpanded
            ? const EdgeInsets.all(16)
            : const EdgeInsets.symmetric(horizontal: 16, vertical: 6),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            if (shouldShowPrioritiesFreshnessChip(
              salesmanUid: salesman?.uid,
            )) ...<Widget>[
              AiFreshnessChip(
                hasData:
                    ranking != null ||
                    _priorityInputs.aiSalesmanCodesWithData.contains(
                      salesman?.code,
                    ),
                timestamps: <DateTime?>[
                  ranking != null
                      ? ranking.freshnessAt
                      : _priorityInputs.aiTimestampBySalesmanCode[salesman
                            ?.code],
                ],
                hasMissingTimestamp:
                    ranking == null &&
                    _priorityInputs.aiSalesmanCodesWithMissingTimestamp
                        .contains(salesman?.code),
              ),
              const SizedBox(height: 8),
            ],
            body,
          ],
        ),
      ),
    );
  }

  List<VisitPriority> _currentPriorities() {
    if (_prioritiesCache != null &&
        identical(_prioritiesCacheInputs, _priorityInputs) &&
        identical(_prioritiesCacheProgressDocs, _progressDocs) &&
        identical(_prioritiesCacheRetailers, _retailers) &&
        identical(_prioritiesCacheSalesman, _selectedSalesman)) {
      return _prioritiesCache!;
    }
    final List<VisitPriority> derived = _derivePriorities();
    _prioritiesCache = derived;
    _prioritiesCacheInputs = _priorityInputs;
    _prioritiesCacheProgressDocs = _progressDocs;
    _prioritiesCacheRetailers = _retailers;
    _prioritiesCacheSalesman = _selectedSalesman;
    return derived;
  }

  List<VisitPriority> _derivePriorities() {
    final List<Map<String, dynamic>> candidates = _candidateRetailers();
    if (candidates.isEmpty) return const <VisitPriority>[];
    final List<StopExecutionEvent> events = <StopExecutionEvent>[
      for (final Map<String, dynamic> doc in _progressDocs)
        ...mapProgressDocToEvents(
          doc,
          stopDocuments:
              _stopArrivalByPlan[(doc['planId'] ?? '').toString().trim()] ??
              const <Map<String, dynamic>>[],
        ),
    ];
    return deriveVisitPriorities(
      retailers: <RetailerRef>[
        for (final Map<String, dynamic> r in candidates)
          RetailerRef(
            id: _retailerId(r),
            name: _text(
              _first(r, const <String>[
                'name',
                'retailerName',
                'retailer_name',
              ]),
              fallback: _retailerId(r),
            ),
          ),
      ],
      insights: _priorityInputs.openInsights,
      replenishmentValueByRetailer:
          _priorityInputs.replenishmentValueByRetailer,
      memoryConfidenceByRetailer: _priorityInputs.memoryConfidenceByRetailer,
      lastVisitByRetailer: resolveLastVisitByRetailer(
        progressDocs: _progressDocs,
        visitLogRows: _priorityInputs.visitLogRows,
      ),
      serviceMinutesByRetailer: highConfidenceServiceMinutes(
        deriveServiceTimes(events),
      ),
      now: DateTime.now(),
    ).where((VisitPriority p) => p.score > 0).toList(growable: false);
  }

  _WeeklyPriorities _weeklyPriorities() {
    if (_weeklyPrioritiesCache != null &&
        identical(_weeklyPrioritiesCache!.inputs, _priorityInputs) &&
        identical(_weeklyPrioritiesCache!.retailers, _retailers) &&
        identical(_weeklyPrioritiesCache!.salesman, _selectedSalesman)) {
      return _weeklyPrioritiesCache!;
    }
    final _Salesman? salesman = _selectedSalesman;
    final RetailerPriorityRanking? ranking =
        salesman == null || _priorityInputs.priorityRankings.isEmpty
        ? null
        : RetailerPriorityRanking.newestActive(
            _priorityInputs.priorityRankings,
            salesmanUid: salesman.uid,
            salesmanCode: salesman.code,
          );
    final Set<String> candidateIds = <String>{
      for (final Map<String, dynamic> row in _candidateRetailers())
        _retailerId(row),
    };
    final List<_WeeklyPriorityItem> items = <_WeeklyPriorityItem>[];
    final String source;
    final String note;
    if (ranking != null) {
      source = _WeeklyPriorities.sourceAuthoritative;
      note =
          'Ranked by expected order-value opportunity per route-day (RM/day), '
          'from the AI update for week ${ranking.weekKey}. '
          '${ranking.coverageBasis == 'last_observed_order' ? 'Recency uses the last observed order, not a recorded visit. ' : ''}'
          'Exploration picks are drawn from a score band around the cut-off.';
      for (final RankedRetailerOpportunity row in ranking.ranking) {
        if (row.retailerId.trim().isEmpty) continue;
        items.add(
          _WeeklyPriorityItem(
            retailerId: row.retailerId,
            retailerName: row.retailerName,
            rank: row.rank,
            expectedOrderValueRm: row.expectedOrderValueRm,
            opportunityPerRouteDay: row.opportunityPerRouteDay,
            chosen: row.chosen,
            exploitOrExplore: row.exploitOrExplore,
            selectionProbability: row.selectionProbability,
            daysSinceLastVisit: row.daysSinceLastVisit,
            reason: _authoritativeReason(row),
            scoreSteps: rankingScoreSteps(row),
          ),
        );
      }
    } else {
      final List<VisitPriority> legacy = _currentPriorities()
          .where((VisitPriority p) => p.score > 0)
          .toList(growable: false);
      source = legacy.isEmpty
          ? _WeeklyPriorities.sourceNone
          : _WeeklyPriorities.sourceLegacy;
      note = legacy.isEmpty
          ? 'No RM/day ranking has been published for this salesman, and no '
                'legacy priority signals are available either.'
          : 'No RM/day ranking has been published for this salesman yet. The '
                'list below is the legacy 0..1 composite and is NOT the '
                'authoritative business ranking.';
      for (int index = 0; index < legacy.length; index++) {
        final VisitPriority row = legacy[index];
        if (!candidateIds.contains(row.retailerId)) continue;
        items.add(
          _WeeklyPriorityItem(
            retailerId: row.retailerId,
            retailerName: row.retailerName,
            rank: index + 1,
            expectedOrderValueRm: row.replenishmentValueRm,
            opportunityPerRouteDay: null,
            chosen: false,
            exploitOrExplore: 'not_selected',
            selectionProbability: 0,
            daysSinceLastVisit: row.daysSinceLastVisit?.toDouble(),
            reason:
                'Legacy composite ${(row.score * 100).round()}/100 - '
                '${row.reason}',
            legacy: row,
          ),
        );
      }
    }
    final _WeeklyPriorities result = _WeeklyPriorities(
      items: items,
      source: source,
      note: note,
      weekKey: ranking?.weekKey ?? '',
      policyVersion: ranking?.policyVersion ?? '',
      inputs: _priorityInputs,
      retailers: _retailers,
      salesman: salesman,
    );
    _weeklyPrioritiesCache = result;
    return result;
  }

  String _authoritativeReason(RankedRetailerOpportunity row) {
    final List<String> parts = <String>[
      'RM${row.expectedOrderValueRm.toStringAsFixed(0)} expected this week',
      'RM${row.opportunityPerRouteDay.toStringAsFixed(0)} per route-day',
    ];
    if (row.daysSinceLastVisit != null) {
      parts.add('${row.daysSinceLastVisit!.round()} days since last contact');
    } else {
      parts.add('no contact on record');
    }
    if (row.forecastPairCount > 0) {
      parts.add('${row.forecastPairCount} forecast pair(s)');
    }
    if (row.observedBaselinePairCount > 0) {
      parts.add('${row.observedBaselinePairCount} from observed baseline');
    }
    if (row.selectionProbability > 0 && row.selectionProbability < 1) {
      parts.add(
        'selection probability '
        '${(row.selectionProbability * 100).round()}%',
      );
    }
    if (row.isExploration) parts.add('exploration pick');
    return parts.join(' | ');
  }

  Widget _prioritiesBody() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_priorityInputs.failedSources.isNotEmpty ||
        _priorityInputs.incompleteSources.isNotEmpty ||
        _progressHasError) {
      return const _Empty(
        icon: ScootIcons.info,
        title: 'Incomplete priority data',
        subtitle:
            'Visit history or ranking inputs could not be verified. Retry before applying priorities.',
      );
    }
    final _WeeklyPriorities weekly = _weeklyPriorities();
    final List<_WeeklyPriorityItem> top = weekly.items
        .take(10)
        .toList(growable: false);
    if (top.isEmpty) {
      return _Empty(
        icon: Icons.flag_outlined,
        title:
            'No ranking for ${_selectedSalesman?.name ?? 'this salesman'} yet',
        subtitle:
            'No ranking has been published for this salesman, '
            'and there are no other priority signals to rank. To see another '
            'salesman, choose one in the Salesman box on the Plan tab.',
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                'Top ${top.length} of ${_candidateRetailers().length} candidate '
                'retailer(s). ${weekly.note}',
                style: TextStyle(
                  fontSize: 12.5,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ),
            const SizedBox(width: 8),
            FilledButton.tonalIcon(
              onPressed: () => _seedSelectionFromPriorities(top),
              icon: const Icon(Icons.playlist_add_check_outlined, size: 18),
              label: const Text('Apply priorities'),
            ),
          ],
        ),
        if (!weekly.isAuthoritative)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _WarningNote(
              text:
                  'Estimated ranking: no RM/day ranking has been published for '
                  'this salesman, so a simpler score is shown.',
            ),
          ),
        if (_priorityInputs.failedSources.isNotEmpty || _progressHasError)
          Padding(
            padding: const EdgeInsets.only(top: 8),
            child: _WarningNote(
              text:
                  'Some signals could not be read '
                  '(${<String>[..._priorityInputs.failedSources, if (_progressHasError) 'visit progress'].join(', ')}) — the ranking '
                  'runs on the remaining signals only.',
            ),
          ),
        const SizedBox(height: 10),
        for (int i = 0; i < top.length; i++) _PriorityRow(item: top[i]),
      ],
    );
  }

  void _seedSelectionFromPriorities(List<_WeeklyPriorityItem> top) {
    final Set<String> keep = top
        .map((_WeeklyPriorityItem p) => p.retailerId)
        .toSet();
    final List<Map<String, dynamic>> candidates = _candidateRetailers();
    setState(() {
      _excludedRetailerIds
        ..clear()
        ..addAll(
          candidates.map(_retailerId).where((String id) => !keep.contains(id)),
        );
      _showRetailerPicker = true;
      _workspace = _PlannerWorkspace.plan;
    });
    final int routable = _selectedRetailers().length;
    showPageSnackBar(
      'Selection updated with ${keep.length} priority retailer(s)'
      '${routable < keep.length ? ' ($routable routable — the rest lack usable coordinates)' : ''}. '
      'Review and Generate — nothing is saved or published.',
    );
  }

  Widget _executionIntelligencePanel() {
    final _Salesman? salesman = _selectedSalesman;
    return CmsPanel(
      title: 'Execution intelligence',
      expandBody: false,
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: salesman == null
            ? const _Empty(
                icon: ScootIcons.reports,
                title: 'Select a salesman',
                subtitle:
                    'Learned service times, adherence and chronic-skip '
                    'patterns are derived from that salesman\'s mobile '
                    'progress across their saved plans.',
              )
            : _progressLoading && _progressDocs.isEmpty
            ? const Padding(
                padding: EdgeInsets.all(12),
                child: Center(child: CircularProgressIndicator()),
              )
            : _progressHasError
            ? const _Empty(
                icon: ScootIcons.error,
                title: 'Execution data unavailable',
                subtitle:
                    'Could not read mobile progress. Check your '
                    'connection and access.',
              )
            : Builder(
                builder: (BuildContext context) {
                  final List<Map<String, dynamic>> progressDocs = _progressDocs;
                  final List<StopExecutionEvent> allEvents =
                      <StopExecutionEvent>[
                        for (final Map<String, dynamic> doc in progressDocs)
                          ...mapProgressDocToEvents(
                            doc,
                            stopDocuments:
                                _stopArrivalByPlan[(doc['planId'] ?? '')
                                    .toString()
                                    .trim()] ??
                                const <Map<String, dynamic>>[],
                          ),
                      ];
                  if (allEvents.isEmpty) {
                    return const _Empty(
                      icon: ScootIcons.reports,
                      title: 'No execution data yet',
                      subtitle:
                          'Once this salesman starts completing or '
                          'skipping stops on mobile, learned service '
                          'times, adherence and chronic-skip patterns '
                          'will appear here.',
                    );
                  }
                  final Map<String, ServiceTimeStat> serviceTimes =
                      deriveServiceTimes(allEvents);
                  final Map<String, SkipPattern> skipPatterns =
                      deriveSkipPatterns(allEvents);
                  final List<_PlanAdherence> perPlan = _perPlanAdherence(
                    progressDocs,
                  );
                  return Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      _ExecutionSection(
                        title: 'Adherence & completion',
                        child: _AdherenceSummary(perPlan: perPlan),
                      ),
                      const SizedBox(height: 12),
                      _ExecutionSection(
                        title: 'Learned service time per retailer',
                        child: _ServiceTimeList(
                          serviceTimes: serviceTimes,
                          retailerName: _retailerNameLookup,
                        ),
                      ),
                      const SizedBox(height: 12),
                      _ExecutionSection(
                        title: 'Chronic skip risk',
                        child: _SkipPatternList(
                          skipPatterns: skipPatterns,
                          retailerName: _retailerNameLookup,
                        ),
                      ),
                    ],
                  );
                },
              ),
      ),
    );
  }

  List<_PlanAdherence> _perPlanAdherence(
    List<Map<String, dynamic>> progressDocs,
  ) {
    final List<_PlanAdherence> result = <_PlanAdherence>[];
    for (final Map<String, dynamic> doc in progressDocs) {
      final String planId = _text(doc['planId']);
      if (planId.isEmpty) continue;
      RoutePlan? plan;
      for (final RoutePlan candidate in _existingPlans) {
        if (candidate.id == planId) {
          plan = candidate;
          break;
        }
      }
      if (plan == null) continue;
      final List<String> plannedIds = <String>[
        for (final RouteDay day in plan.days)
          ...(List<RouteStop>.from(day.stops)..sort(
                (RouteStop a, RouteStop b) => a.sequence.compareTo(b.sequence),
              ))
              .map((RouteStop s) => s.stopId),
      ];
      final AdherenceResult adherence = deriveAdherence(
        plannedIds,
        mapProgressDocToEvents(
          doc,
          planId: planId,
          stopDocuments:
              _stopArrivalByPlan[planId.trim()] ??
              const <Map<String, dynamic>>[],
        ),
      );
      result.add(_PlanAdherence(plan: plan, adherence: adherence));
    }
    result.sort(
      (_PlanAdherence a, _PlanAdherence b) =>
          b.plan.weekStart.compareTo(a.plan.weekStart),
    );
    return result;
  }

  String _retailerNameLookup(String retailerId) {
    for (final Map<String, dynamic> r in _retailers) {
      if (_retailerId(r) == retailerId) {
        return _text(r['retailerName'] ?? r['name'], fallback: retailerId);
      }
    }
    return retailerId;
  }

  Widget _healthPanel() {
    final _Health health = _computeHealth();
    final RoutePlan? plan = _plan;
    final List<Map<String, dynamic>> candidates = _candidateRetailers();
    final int withCoords = _withCoordinates(candidates).length;
    final int missing = candidates.length - withCoords;
    final int verifiedCoords = candidates.where(isRetailerRouteReady).length;
    final List<Map<String, dynamic>> selectedRetailers = _selectedRetailers();
    final int selected = selectedRetailers.length;
    final int dueFollowUpTotal = _dueFollowUpRetailerIds.length;
    final int dueFollowUpRoutable = selectedRetailers
        .where(
          (Map<String, dynamic> r) =>
              _dueFollowUpRetailerIds.contains(_retailerId(r)),
        )
        .length;
    final RoutePlan? duplicate = _existingPlanForSelectedWeek();
    final _RouteQuality quality = _routeQuality(
      plan: plan,
      missingCoordinates: missing,
      duplicate: duplicate != null,
    );
    final bool canFixCoords =
        missing > 0 &&
        widget.currentUser.isAdmin &&
        widget.onNavigateRequested != null;

    return CmsPanel(
      title: 'Route health & stats',
      expandBody: false,
      trailing: _healthChip(health.level),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Wrap(
              spacing: 12,
              runSpacing: 12,
              children: <Widget>[
                _statTile('Retailers in scope', '${candidates.length}'),
                _statTile('With coordinates', '$withCoords'),
                _statTile(
                  'Missing coordinates',
                  '$missing',
                  danger: missing > 0,
                ),
                _statTile('Verified coords', '$verifiedCoords'),
                _statTile('Selected', '$selected'),
                if (dueFollowUpTotal > 0)
                  _statTile(
                    'Follow-ups due',
                    '$dueFollowUpRoutable/$dueFollowUpTotal',
                    danger: dueFollowUpRoutable < dueFollowUpTotal,
                  ),
                _statTile('Routing', _routingStatusText()),
                if (plan != null)
                  _statTile('Plan status', _titleCase(plan.status)),
                if (plan != null)
                  _statTile('Route days', '${plan.totalStops} stops'),
                if (plan != null)
                  _statTile(
                    'Quality score',
                    '${quality.score}/100',
                    danger: quality.score < 60,
                  ),
                if (plan != null)
                  _statTile(
                    'Estimated duration',
                    _formatDuration(quality.estimatedMinutes),
                  ),
                if (plan != null)
                  _statTile(
                    'Day balance',
                    quality.balanceLabel,
                    danger: quality.workloadSpread > 3,
                  ),
                if (plan != null)
                  _statTile(
                    'Fallback usage',
                    quality.usedFallback ? 'Yes' : 'No',
                    danger: quality.usedFallback,
                  ),
              ],
            ),
            const SizedBox(height: 14),
            for (final String msg in health.messages)
              Padding(
                padding: const EdgeInsets.only(bottom: 6),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Padding(
                      padding: const EdgeInsets.only(top: 4),
                      child: Icon(
                        Icons.circle,
                        size: 8,
                        color: health.level.color,
                      ),
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        msg,
                        style: TextStyle(
                          fontSize: 12.5,
                          color: context.dso.body,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            if (canFixCoords)
              Align(
                alignment: Alignment.centerLeft,
                child: TextButton.icon(
                  onPressed: () =>
                      widget.onNavigateRequested!.call('coordinate_review'),
                  icon: const Icon(Icons.build_outlined, size: 16),
                  label: const Text('Open Coordinate Review'),
                ),
              ),
            if (duplicate != null)
              Padding(
                padding: const EdgeInsets.only(top: 4),
                child: _WarningNote(
                  text:
                      'A ${duplicate.status} plan already exists for this week '
                      '(${duplicate.totalStops} stops). Saving adds a separate '
                      'plan — review before publishing to avoid duplicates.',
                ),
              ),
          ],
        ),
      ),
    );
  }

  _Health _computeHealth() {
    final List<Map<String, dynamic>> candidates = _candidateRetailers();
    final int withCoords = _withCoordinates(candidates).length;
    final List<Map<String, dynamic>> selectedList = _selectedRetailers();
    final int selected = selectedList.length;
    final int selectedUnverified = selectedList
        .where((Map<String, dynamic> r) => !isRetailerRouteReady(r))
        .length;
    final int verifiedCoords = candidates.where(isRetailerRouteReady).length;
    final RoutePlan? plan = _plan;
    final List<String> messages = <String>[];
    _HealthLevel level = _HealthLevel.green;
    void down(_HealthLevel l) {
      if (l.index > level.index) level = l;
    }

    if (candidates.isEmpty) {
      down(_HealthLevel.red);
      messages.add('No retailers are in scope for this salesman.');
    } else if (withCoords == 0) {
      down(_HealthLevel.red);
      messages.add(
        'No retailers have usable coordinates — geocode them first.',
      );
    } else if (withCoords < candidates.length) {
      down(_HealthLevel.yellow);
      messages.add(
        '${candidates.length - withCoords} retailer(s) missing coordinates were excluded.',
      );
    } else {
      messages.add('All in-scope retailers have coordinates.');
    }

    if (_verifiedOnly && verifiedCoords == 0 && withCoords > 0) {
      down(_HealthLevel.red);
      messages.add(
        'Verified only is on but no retailer is coordinate-verified yet.',
      );
    } else if (!_verifiedOnly && selectedUnverified > 0) {
      down(_HealthLevel.yellow);
      messages.add(
        '$selectedUnverified selected retailer(s) use unverified coordinates.',
      );
    }

    if (selected > 0) {
      final Map<String, int> regions = <String, int>{};
      for (final Map<String, dynamic> r in selectedList) {
        final String region = resolveRetailerRegion(r);
        regions[region] = (regions[region] ?? 0) + 1;
      }
      final bool meaningful =
          regions.length > 1 || !regions.containsKey(kUnzonedRegion);
      if (meaningful) {
        final List<MapEntry<String, int>> entries = regions.entries.toList()
          ..sort(
            (MapEntry<String, int> a, MapEntry<String, int> b) =>
                b.value.compareTo(a.value),
          );
        messages.add(
          'Plan groups by region: '
          '${entries.map((MapEntry<String, int> e) => '${e.key} (${e.value})').join(' · ')}.',
        );
      }
    }

    if (_dueFollowUpRetailerIds.isNotEmpty) {
      final int routable = selectedList
          .where(
            (Map<String, dynamic> r) =>
                _dueFollowUpRetailerIds.contains(_retailerId(r)),
          )
          .length;
      messages.add(
        '$routable of ${_dueFollowUpRetailerIds.length} retailer(s) with a '
        'pending follow-up are included as suggestions.',
      );
      if (routable < _dueFollowUpRetailerIds.length) {
        down(_HealthLevel.yellow);
        messages.add(
          '${_dueFollowUpRetailerIds.length - routable} follow-up retailer(s) '
          'can\'t be routed yet (not assigned here or missing coordinates).',
        );
      }
    }

    if (withCoords > 0 && selected == 0) {
      down(_HealthLevel.red);
      messages.add('No retailers selected — choose at least one.');
    }

    if (plan == null) {
      down(_HealthLevel.yellow);
      messages.add('No route generated yet.');
    } else {
      final String method = plan.metricSourceMethod;
      if (plan.isDemo || method == 'Demo') {
        down(_HealthLevel.yellow);
        messages.add('This plan is unavailable for production use.');
      } else if (_isLegacyOrsMethod(method)) {
        messages.add('Saved plan uses a legacy external-route method label.');
      } else if (method == 'GeoapifyRouteMatrix' ||
          method == 'GeoapifyRouting' ||
          method == 'GeoapifyRoadMixedSources') {
        messages.add(
          'Distance and travel-time metrics use the Geoapify road source recorded for each day.',
        );
      } else if (method == 'OSRMTable') {
        messages.add(
          'Road travel times supplied by the configured OSRM service.',
        );
      } else if (_usesHaversineFallback(method)) {
        down(_HealthLevel.yellow);
        messages.add(
          method.contains('Mixed')
              ? 'Part of this plan used local Haversine estimates (not exact).'
              : 'Haversine estimate used (not exact).',
        );
      } else if (method.isEmpty) {
        down(_HealthLevel.yellow);
        messages.add('No routing method recorded for this plan.');
      } else {
        messages.add('Routing method: ${_methodLabel(method)}.');
      }
      if (plan.id.isEmpty) {
        down(_HealthLevel.yellow);
        messages.add('Plan not saved yet.');
      } else if (plan.status != 'published') {
        down(_HealthLevel.yellow);
        messages.add('Saved as ${plan.status} — publish to send to mobile.');
      } else {
        messages.add(
          'Published — visible on the assigned salesman mobile app.',
        );
      }
    }
    return _Health(level, messages);
  }

  String _routingStatusText() {
    final RoutePlan? plan = _plan;
    if (plan == null) {
      return _service.isRoadRoutingConfigured
          ? 'Not run (Geoapify configured)'
          : 'Not run (local estimate)';
    }
    final String method = plan.metricSourceMethod;
    if (plan.isDemo || method == 'Demo') {
      return 'Unavailable';
    }
    if (_isLegacyOrsMethod(method)) return 'Legacy';
    switch (method) {
      case 'GeoapifyRouteMatrix':
        return 'Road (Geoapify)';
      case 'GeoapifyRouting':
        return 'Road (Geoapify routing)';
      case 'GeoapifyRouteMatrixMixedHaversineFallback':
      case 'GeoapifyRoutingMixedHaversineFallback':
      case 'GeoapifyRoadMixedHaversineFallback':
        return 'Road (partial)';
      case 'GeoapifyRoadMixedSources':
        return 'Road (mixed Geoapify sources)';
      case 'GeoapifyConfiguredHaversineFallback':
        return 'Geoapify failed — local estimate';
      case 'OSRMTable':
        return 'Road (OSRM)';
      case 'OSRMTableMixedHaversineFallback':
        return 'Road (partial)';
      case 'OSRMConfiguredHaversineFallback':
        return 'OSRM failed — local estimate';
      case 'ManualHaversineRecompute':
        return 'Local estimate (manual edits)';
      case 'HaversineNearestNeighbour':
        return 'Local estimate';
      default:
        return method.isEmpty ? 'Local estimate' : method;
    }
  }

  _RouteQuality _routeQuality({
    required RoutePlan? plan,
    required int missingCoordinates,
    required bool duplicate,
  }) {
    if (plan == null) {
      return const _RouteQuality(
        score: 0,
        estimatedMinutes: 0,
        workloadSpread: 0,
        usedFallback: false,
        balanceLabel: 'Not generated',
      );
    }

    final List<int> activeLoads = plan.days
        .where((RouteDay day) => day.stops.isNotEmpty)
        .map((RouteDay day) => day.stops.length)
        .toList(growable: false);
    final int maxLoad = activeLoads.isEmpty
        ? 0
        : activeLoads.reduce((int a, int b) => a > b ? a : b);
    final int minLoad = activeLoads.isEmpty
        ? 0
        : activeLoads.reduce((int a, int b) => a < b ? a : b);
    final int spread = maxLoad - minLoad;
    final bool fallback = _usesHaversineFallback(plan.metricSourceMethod);
    final int serviceMinutes = plan.days.fold<int>(
      0,
      (int sum, RouteDay day) => sum + day.estimatedServiceMinutes,
    );
    final int travelMinutes = estimateRouteTravelMinutes(plan.totalDistanceKm);

    int score = 100;
    if (plan.totalStops == 0) score -= 60;
    score -= (missingCoordinates * 3).clamp(0, 24);
    if (fallback) score -= 12;
    if (duplicate) score -= 25;
    score -= (spread * 4).clamp(0, 20);
    if (activeLoads.any((int load) => load > 10)) score -= 10;
    score = score.clamp(0, 100);

    final String balance = activeLoads.isEmpty
        ? 'No active days'
        : spread <= 1
        ? 'Balanced'
        : spread <= 3
        ? 'Moderate ($minLoad–$maxLoad)'
        : 'Uneven ($minLoad–$maxLoad)';
    return _RouteQuality(
      score: score,
      estimatedMinutes: serviceMinutes + travelMinutes,
      workloadSpread: spread,
      usedFallback: fallback,
      balanceLabel: balance,
    );
  }

  RoutePlan? _existingPlanForSelectedWeek() {
    final DateTime monday = _mondayOf(_weekStart);
    for (final RoutePlan p in _existingPlans) {
      if (_mondayOf(p.weekStart) == monday &&
          (_plan == null || p.id != _plan!.id)) {
        return p;
      }
    }
    return null;
  }

  Future<void> _withdraw(RoutePlan plan) async {
    setState(() => _saving = true);
    String message =
        'Route withdrawn. Edit it, then approve and publish again.';
    bool askReplace = false;
    try {
      await _service.withdrawPlan(plan);
      if (!mounted) return;
      setState(() => _plan = plan.copyWith(status: 'draft'));
      await _loadExistingPlans();
    } on RouteAlreadyAcceptedException {
      askReplace = true;
    } catch (error, stackTrace) {
      AppLogger.error(
        'route_plan_withdraw_failed',
        error: error,
        stackTrace: stackTrace,
      );
      message = userFacingError(error, action: 'withdraw the route');
    }
    if (!mounted) return;
    setState(() => _saving = false);
    if (askReplace) {
      await _confirmReplace(plan);
      return;
    }
    showPageSnackBar(message);
  }

  Future<void> _confirmReplace(RoutePlan plan) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Replace this route?'),
        content: Text(
          '${plan.salesmanName} may already have opened this route, so it '
          'cannot go back to draft. Replacing closes it and opens a new draft '
          'copy for you to correct. The work already recorded stays in the '
          'history. ${plan.salesmanName} sees the new route after you '
          'approve and publish it.',
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Replace route'),
          ),
        ],
      ),
    );
    if (confirmed != true || !mounted) return;
    setState(() => _saving = true);
    String message =
        'Route replaced. Correct the new draft, then approve and publish it.';
    try {
      final String newId = await _service.replacePublishedPlan(plan);
      if (!mounted) return;
      setState(() => _plan = _draftCopyOf(plan, newId));
      await _loadExistingPlans();
    } catch (error, stackTrace) {
      AppLogger.error(
        'route_plan_replace_failed',
        error: error,
        stackTrace: stackTrace,
      );
      message = userFacingError(error, action: 'replace the route');
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showPageSnackBar(message);
  }

  RoutePlan _draftCopyOf(RoutePlan plan, String id) => RoutePlan(
    id: id,
    weekStart: plan.weekStart,
    weekEnd: plan.weekEnd,
    status: 'draft',
    branchId: plan.branchId,
    createdByUid: FirebaseAuth.instance.currentUser?.uid ?? plan.createdByUid,
    createdByRole: plan.createdByRole,
    salesmanUid: plan.salesmanUid,
    salesmanCode: plan.salesmanCode,
    salesmanName: plan.salesmanName,
    source: plan.source,
    planVersion: plan.planVersion,
    isDemo: plan.isDemo,
    optimisationMethod: plan.optimisationMethod,
    days: plan.days,
    roadRouteNotes: plan.roadRouteNotes,
  );

  Future<void> _backToDraft(RoutePlan plan) async {
    setState(() => _saving = true);
    String message = 'Route is a draft again. Edit it, then approve it.';
    try {
      await _service.updateStatus(plan.id, 'draft');
      if (!mounted) return;
      setState(() => _plan = plan.copyWith(status: 'draft'));
      await _loadExistingPlans();
    } catch (error, stackTrace) {
      AppLogger.error(
        'route_plan_back_to_draft_failed',
        error: error,
        stackTrace: stackTrace,
      );
      message = userFacingError(error, action: 'move the route back to draft');
    }
    if (!mounted) return;
    setState(() => _saving = false);
    showPageSnackBar(message);
  }

  Future<void> _confirmPublish(RoutePlan plan) async {
    final RoutePlan? duplicate = _existingPlanForSelectedWeek();
    final String? startedWeekWarning = plannerStartedWeekWarning(
      plan.weekStart,
      DateTime.now(),
    );
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Publish this route?'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            _confirmRow('Salesman', plan.salesmanName),
            _confirmRow(
              'Week',
              '${_fmtDate(plan.weekStart)} – ${_fmtDate(plan.weekEnd)}',
            ),
            _confirmRow('Stops', '${plan.totalStops}'),
            _confirmRow(
              'Distance',
              '${plan.totalDistanceKm.toStringAsFixed(1)} km (estimated)',
            ),
            _confirmRow('Method', _methodLabel(plan.metricSourceMethod)),
            if (duplicate != null) ...<Widget>[
              const SizedBox(height: 10),
              _WarningNote(
                text:
                    'A ${duplicate.status} plan already exists for this week. '
                    'Publishing may create a duplicate assigned route.',
              ),
            ],
            if (startedWeekWarning != null) ...<Widget>[
              const SizedBox(height: 10),
              _WarningNote(text: startedWeekWarning),
            ],
          ],
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialogContext, false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext, true),
            child: const Text('Publish'),
          ),
        ],
      ),
    );
    if (confirmed == true) {
      await _save(status: 'published');
    }
  }

  Widget _confirmRow(String label, String value) {
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 3),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 92,
            child: Text(
              label,
              style: TextStyle(fontSize: 12.5, color: context.dso.muted),
            ),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontSize: 13, fontWeight: FontWeight.w700),
            ),
          ),
        ],
      ),
    );
  }

  Widget _statTile(String label, String value, {bool danger = false}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 150,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: danger ? context.dso.dangerSoft : scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: danger ? context.dso.danger : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              color: danger ? context.dso.dangerText : scheme.onSurfaceVariant,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            value,
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: danger ? context.dso.dangerText : scheme.onSurface,
            ),
          ),
        ],
      ),
    );
  }

  Widget _healthChip(_HealthLevel level) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: level.color.withValues(alpha: 0.14),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(Icons.circle, size: 8, color: level.color),
          const SizedBox(width: 6),
          Text(
            level.label,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: level.color,
            ),
          ),
        ],
      ),
    );
  }

  Widget _panel(String title, Widget child) => CmsPanel(
    title: title,
    expandBody: false,
    child: Padding(padding: const EdgeInsets.all(16), child: child),
  );

  Widget _field(String label, Widget child) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          label,
          style: TextStyle(
            fontSize: 12,
            fontWeight: FontWeight.w700,
            color: context.dso.body,
          ),
        ),
        const SizedBox(height: 6),
        child,
      ],
    );
  }

  Widget _stepper({
    required String label,
    required int value,
    required int min,
    required int max,
    int step = 1,
    required ValueChanged<int> onChanged,
  }) {
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: context.dso.hairline),
        borderRadius: BorderRadius.circular(8),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'Fewer $label',
            onPressed: value > min ? () => onChanged(value - step) : null,
            icon: const Icon(Icons.remove, size: 18),
          ),
          SizedBox(
            width: 34,
            child: Text(
              '$value',
              textAlign: TextAlign.center,
              style: const TextStyle(fontWeight: FontWeight.w700),
            ),
          ),
          IconButton(
            visualDensity: VisualDensity.compact,
            tooltip: 'More $label',
            onPressed: value < max ? () => onChanged(value + step) : null,
            icon: const Icon(ScootIcons.add, size: 18),
          ),
        ],
      ),
    );
  }

  Widget _statusChip(String status) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    final (Color fg, Color bg) = switch (status) {
      'published' => (
        dark ? const Color(0xFF7EE2A8) : const Color(0xFF027A48),
        dark ? const Color(0xFF153D2C) : const Color(0xFFECFDF3),
      ),
      'approved' => (
        dark ? const Color(0xFF93C5FD) : const Color(0xFF1D4ED8),
        dark ? const Color(0xFF1E335C) : const Color(0xFFEFF6FF),
      ),
      _ => (scheme.onSurfaceVariant, scheme.surfaceContainerHighest),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 5),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        status[0].toUpperCase() + status.substring(1),
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w700, color: fg),
      ),
    );
  }

  int _firstNonEmptyDay(RoutePlan plan) {
    for (int i = 0; i < plan.days.length; i++) {
      if (plan.days[i].stops.isNotEmpty) return i;
    }
    return 0;
  }

  String _retailerId(Map<String, dynamic> r) => _text(
    _first(r, const <String>[
      'docId',
      'retailerId',
      'retailer_id',
      'id',
      'code',
      'retailerCode',
      'retailer_code',
      'customerCode',
      'customer_code',
      'storeCode',
      'store_code',
      'name',
    ]),
  );

  RetailerSegment? _segmentForRetailer(String retailerId) {
    return _segments[retailerId.trim()];
  }

  Widget? _segmentBadgeFor(String retailerId) {
    final RetailerSegment? segment = _segmentForRetailer(retailerId);
    return segment == null ? null : _AiSegmentBadge(segment: segment);
  }
}

class _Salesman {
  const _Salesman({
    required this.uid,
    required this.name,
    required this.code,
    required this.branchId,
  });
  final String uid;
  final String name;
  final String code;
  final String branchId;
}

class _PlanAdherence {
  const _PlanAdherence({required this.plan, required this.adherence});
  final RoutePlan plan;
  final AdherenceResult adherence;
}

class _WeeklyPriorityItem {
  const _WeeklyPriorityItem({
    required this.retailerId,
    required this.retailerName,
    required this.rank,
    required this.expectedOrderValueRm,
    required this.opportunityPerRouteDay,
    required this.chosen,
    required this.exploitOrExplore,
    required this.selectionProbability,
    required this.daysSinceLastVisit,
    required this.reason,
    this.scoreSteps = const <String>[],
    this.legacy,
  });

  final String retailerId;
  final String retailerName;
  final int rank;
  final double expectedOrderValueRm;

  final double? opportunityPerRouteDay;

  final bool chosen;
  final String exploitOrExplore;
  final double selectionProbability;
  final double? daysSinceLastVisit;
  final String reason;

  final List<String> scoreSteps;
  final VisitPriority? legacy;

  bool get isAuthoritative => legacy == null;
  bool get isExploration => exploitOrExplore == 'explore';
}

class _WeeklyPriorities {
  const _WeeklyPriorities({
    required this.items,
    required this.source,
    required this.note,
    required this.weekKey,
    required this.policyVersion,
    required this.inputs,
    required this.retailers,
    required this.salesman,
  });

  static const String sourceAuthoritative = 'authoritative';
  static const String sourceLegacy = 'legacyFallback';
  static const String sourceNone = 'none';

  final List<_WeeklyPriorityItem> items;
  final String source;
  final String note;
  final String weekKey;
  final String policyVersion;
  final VisitPriorityInputs inputs;
  final List<Map<String, dynamic>> retailers;
  final _Salesman? salesman;

  bool get isAuthoritative => source == sourceAuthoritative;
}

class _PriorityRow extends StatefulWidget {
  const _PriorityRow({required this.item});

  final _WeeklyPriorityItem item;

  @override
  State<_PriorityRow> createState() => _PriorityRowState();
}

class _PriorityRowState extends State<_PriorityRow> {
  bool _expanded = false;

  static const Map<String, String> _factorLabels = <String, String>{
    'openInsights': 'Open insights',
    'replenishmentValue': 'Expected reorder value',
    'visitRecency': 'Visit recency',
    'memoryConfidence': 'Low memory confidence',
    'serviceCost': 'Service cost (shorter stop)',
  };

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    final Color accent = dark
        ? const Color(0xFF7FD9AF)
        : const Color(0xFF3A7D5C);
    final _WeeklyPriorityItem item = widget.item;
    final VisitPriority? legacy = item.legacy;
    return Container(
      margin: const EdgeInsets.only(bottom: 8),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          InkWell(
            borderRadius: BorderRadius.circular(8),
            onTap: () => setState(() => _expanded = !_expanded),
            child: Row(
              children: <Widget>[
                CircleAvatar(
                  radius: 12,
                  backgroundColor: accent,
                  child: Text(
                    '${item.rank}',
                    style: TextStyle(
                      fontSize: 11.5,
                      fontWeight: FontWeight.w800,
                      color: dark ? const Color(0xFF10241B) : Colors.white,
                    ),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        item.retailerName,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 13,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 4),
                      Text(
                        item.reason,
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 8),
                if (item.opportunityPerRouteDay != null)
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.end,
                    children: <Widget>[
                      Text(
                        'RM${item.opportunityPerRouteDay!.round()}',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: accent,
                        ),
                      ),
                      Text(
                        'per route-day',
                        style: TextStyle(
                          fontSize: 10,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  )
                else
                  Text(
                    'no RM/day',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w600,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                Icon(
                  _expanded ? Icons.expand_less : ScootIcons.expandMore,
                  size: 18,
                  color: scheme.onSurfaceVariant,
                ),
              ],
            ),
          ),
          if (_expanded)
            Padding(
              padding: const EdgeInsets.only(left: 34, top: 8),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (item.isExploration)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Exploration pick - chosen from the score band around '
                        'the selection cut-off, not on rank alone.',
                        style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (item.isAuthoritative)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 6),
                      child: Text(
                        'Authoritative RM/day ranking. The decision log for '
                        'this week records every candidate considered.',
                        style: TextStyle(
                          fontSize: 11,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  if (item.scoreSteps.isNotEmpty) ...<Widget>[
                    Text(
                      'Why this rank',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 2),
                    for (final String step in item.scoreSteps)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 1),
                        child: Text(
                          step,
                          style: TextStyle(
                            fontSize: 11,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                    Padding(
                      padding: const EdgeInsets.only(top: 4, bottom: 6),
                      child: Text(
                        rankingScoreNote,
                        style: TextStyle(
                          fontSize: 11,
                          fontStyle: FontStyle.italic,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                  ],
                  for (final MapEntry<String, double> factor
                      in priorityWeights.entries)
                    if (legacy != null)
                      Padding(
                        padding: const EdgeInsets.symmetric(vertical: 2),
                        child: Row(
                          children: <Widget>[
                            SizedBox(
                              width: 190,
                              child: Text(
                                _factorLabels[factor.key] ?? factor.key,
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: scheme.onSurfaceVariant,
                                ),
                              ),
                            ),
                            Expanded(
                              child: ClipRRect(
                                borderRadius: BorderRadius.circular(999),
                                child: LinearProgressIndicator(
                                  value: factor.value <= 0
                                      ? 0
                                      : ((legacy.contributions[factor.key] ??
                                                    0) /
                                                factor.value)
                                            .clamp(0.0, 1.0),
                                  minHeight: 4,
                                  color: accent,
                                  backgroundColor: scheme.outlineVariant,
                                ),
                              ),
                            ),
                            const SizedBox(width: 8),
                            Text(
                              '+${(legacy.contributions[factor.key] ?? 0).toStringAsFixed(2)}'
                              ' / ${factor.value.toStringAsFixed(2)}',
                              style: TextStyle(
                                fontSize: 11,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ),
                      ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class _ExecutionSection extends StatelessWidget {
  const _ExecutionSection({required this.title, required this.child});

  final String title;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 8),
          child,
        ],
      ),
    );
  }
}

class _AdherenceSummary extends StatelessWidget {
  const _AdherenceSummary({required this.perPlan});

  final List<_PlanAdherence> perPlan;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (perPlan.isEmpty) {
      return Text(
        'No saved plan matched this salesman\'s progress yet.',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }
    final List<double> scored = perPlan
        .where((_PlanAdherence p) => p.adherence.hasScore)
        .map((_PlanAdherence p) => p.adherence.score!)
        .toList(growable: false);
    final double? avgScore = scored.isEmpty
        ? null
        : scored.reduce((double a, double b) => a + b) / scored.length;
    final double avgCompletion =
        perPlan
            .map((_PlanAdherence p) => p.adherence.completionRate)
            .reduce((double a, double b) => a + b) /
        perPlan.length;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: <Widget>[
            _ExecutionMetric(
              label:
                  'Avg adherence (${scored.length}/${perPlan.length} scored)',
              value: avgScore == null
                  ? 'Not enough data'
                  : '${(avgScore * 100).round()}%',
            ),
            _ExecutionMetric(
              label: 'Avg completion rate',
              value: '${(avgCompletion * 100).round()}%',
              danger: avgCompletion < 0.5,
            ),
          ],
        ),
        const SizedBox(height: 8),
        for (final _PlanAdherence p in perPlan.take(6))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${_fmtDate(p.plan.weekStart)} - ${_fmtDate(p.plan.weekEnd)}',
                    style: TextStyle(fontSize: 12, color: scheme.onSurface),
                  ),
                ),
                Text(
                  p.adherence.hasScore
                      ? '${(p.adherence.score! * 100).round()}% order · '
                            '${(p.adherence.completionRate * 100).round()}% done'
                      : 'Order unknown · '
                            '${(p.adherence.completionRate * 100).round()}% done',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ServiceTimeList extends StatelessWidget {
  const _ServiceTimeList({
    required this.serviceTimes,
    required this.retailerName,
  });

  final Map<String, ServiceTimeStat> serviceTimes;
  final String Function(String retailerId) retailerName;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<ServiceTimeStat> withEstimate =
        serviceTimes.values.where((ServiceTimeStat s) => s.hasEstimate).toList()
          ..sort(
            (ServiceTimeStat a, ServiceTimeStat b) =>
                b.sampleCount.compareTo(a.sampleCount),
          );
    if (withEstimate.isEmpty) {
      return Text(
        'Not enough completed visits yet to learn service times '
        '(${serviceTimes.length} retailer(s) tracked, none with a clean '
        'arrived → completed sample).',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }
    final bool dark = scheme.brightness == Brightness.dark;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final ServiceTimeStat s in withEstimate.take(8))
          Padding(
            padding: const EdgeInsets.symmetric(vertical: 3),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    retailerName(s.retailerId),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12,
                      color: s.usedInPlanning
                          ? scheme.onSurface
                          : scheme.onSurfaceVariant,
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${s.meanServiceMinutes!.toStringAsFixed(0)} min '
                  '(${s.sampleCount} visit${s.sampleCount == 1 ? '' : 's'}, '
                  '${s.confidenceLabel.toLowerCase()} confidence)',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                const SizedBox(width: 8),
                if (s.usedInPlanning)
                  Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: dark
                          ? const Color(0xFF16342A)
                          : const Color(0xFFE6F2EC),
                      borderRadius: BorderRadius.circular(999),
                      border: Border.all(
                        color: dark
                            ? const Color(0xFF3A7D5C)
                            : const Color(0xFFBEDECE),
                      ),
                    ),
                    child: Text(
                      'Used in planning',
                      style: TextStyle(
                        fontSize: 10.5,
                        fontWeight: FontWeight.w700,
                        color: dark
                            ? const Color(0xFF7FD9AF)
                            : const Color(0xFF3A7D5C),
                      ),
                    ),
                  )
                else
                  Text(
                    'Needs more visits',
                    style: TextStyle(
                      fontSize: 10.5,
                      fontStyle: FontStyle.italic,
                      color: scheme.onSurfaceVariant.withValues(alpha: 0.8),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}

class _SkipPatternList extends StatelessWidget {
  const _SkipPatternList({
    required this.skipPatterns,
    required this.retailerName,
  });

  final Map<String, SkipPattern> skipPatterns;
  final String Function(String retailerId) retailerName;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    final List<SkipPattern> chronic =
        skipPatterns.values.where((SkipPattern p) => p.isChronic).toList()
          ..sort(
            (SkipPattern a, SkipPattern b) => b.skipRate.compareTo(a.skipRate),
          );
    if (chronic.isEmpty) {
      return Text(
        'No chronic-skip retailers detected for this salesman.',
        style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final SkipPattern p in chronic.take(8))
          Container(
            margin: const EdgeInsets.only(bottom: 6),
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            decoration: BoxDecoration(
              color: dark ? const Color(0xFF3B1717) : const Color(0xFFFEF3F2),
              borderRadius: BorderRadius.circular(10),
              border: Border.all(
                color: dark ? const Color(0xFF7F1D1D) : const Color(0xFFFECDCA),
              ),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    retailerName(p.retailerId),
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: dark
                          ? const Color(0xFFFCA5A5)
                          : const Color(0xFFB42318),
                    ),
                  ),
                ),
                const SizedBox(width: 8),
                Text(
                  '${p.skipCount}/${p.totalPlanned} skipped'
                  '${p.lastSkipReason != null ? ' · ${p.lastSkipReason}' : ''}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w600,
                    color: dark
                        ? const Color(0xFFFCA5A5)
                        : const Color(0xFFB42318),
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}

class _ExecutionMetric extends StatelessWidget {
  const _ExecutionMetric({
    required this.label,
    required this.value,
    this.danger = false,
  });

  final String label;
  final String value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    return Container(
      constraints: const BoxConstraints(minWidth: 150),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: danger
            ? (dark ? const Color(0xFF3B1717) : const Color(0xFFFEF3F2))
            : scheme.surface,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: danger
              ? (dark ? const Color(0xFF7F1D1D) : const Color(0xFFFECDCA))
              : scheme.outlineVariant,
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: danger
                  ? (dark ? const Color(0xFFFCA5A5) : const Color(0xFFB42318))
                  : scheme.onSurface,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Empty extends StatelessWidget {
  const _Empty({
    required this.icon,
    required this.title,
    required this.subtitle,
  });
  final IconData icon;
  final String title;
  final String subtitle;
  @override
  Widget build(BuildContext context) {
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 40, color: context.dso.subtle),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: context.dso.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12.5,
                height: 1.5,
                color: context.dso.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

DateTime _mondayOf(DateTime d) {
  final DateTime day = DateTime(d.year, d.month, d.day);
  return day.subtract(Duration(days: day.weekday - 1));
}

String _fmtDate(DateTime d) {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${d.day} ${months[d.month - 1]}';
}

String _methodLabel(String method) {
  switch (method) {
    case 'ORS_TSP':
      return 'Legacy route optimised';
    case 'ORS_ESTIMATED':
      return 'Legacy route estimated';
    case 'GeoapifyRouteMatrix':
      return 'Geoapify road travel times';
    case 'GeoapifyRouting':
      return 'Geoapify road routing';
    case 'GeoapifyRouteMatrixMixedHaversineFallback':
      return 'Geoapify road (part falls back on estimate)';
    case 'GeoapifyRoutingMixedHaversineFallback':
      return 'Geoapify road routing (part falls back on estimate)';
    case 'GeoapifyRoadMixedSources':
      return 'Geoapify road metrics (matrix and routing)';
    case 'GeoapifyRoadMixedHaversineFallback':
      return 'Geoapify road metrics (part falls back on estimate)';
    case 'GeoapifyConfiguredHaversineFallback':
      return 'Geoapify unavailable — local estimate';
    case 'OSRMTable':
      return 'OSRM road travel times';
    case 'OSRMTableMixedHaversineFallback':
      return 'OSRM road (part falls back on estimate)';
    case 'OSRMConfiguredHaversineFallback':
      return 'OSRM unavailable — local estimate';
    case 'ManualHaversineRecompute':
      return 'Local estimate (manual edits)';
    case 'HaversineNearestNeighbour':
      return 'Haversine estimate';
    case 'Demo':
      return 'Unavailable';
    default:
      return method.isEmpty ? 'Estimated' : method;
  }
}

bool _isLegacyOrsMethod(String method) =>
    method == 'ORS_TSP' || method == 'ORS_ESTIMATED';

bool _usesHaversineFallback(String method) => method.contains('Haversine');

bool _isRoadTimingMethod(String method) =>
    method == 'GeoapifyRouteMatrix' ||
    method == 'GeoapifyRouteMatrixMixedHaversineFallback' ||
    method == 'GeoapifyRouting' ||
    method == 'GeoapifyRoutingMixedHaversineFallback' ||
    method == 'GeoapifyRoadMixedSources' ||
    method == 'GeoapifyRoadMixedHaversineFallback' ||
    method == 'OSRMTable' ||
    method == 'OSRMTableMixedHaversineFallback' ||
    method == 'ManualHaversineRecompute';

String _formatDuration(int minutes) {
  if (minutes <= 0) return '0 min';
  final int h = minutes ~/ 60;
  final int m = minutes % 60;
  if (h == 0) return '$m min';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

enum _HealthLevel {
  green,
  yellow,
  red;

  Color get color => switch (this) {
    _HealthLevel.green => const Color(0xFF12B76A),
    _HealthLevel.yellow => const Color(0xFFF79009),
    _HealthLevel.red => const Color(0xFFF04438),
  };

  String get label => switch (this) {
    _HealthLevel.green => 'Healthy',
    _HealthLevel.yellow => 'Needs attention',
    _HealthLevel.red => 'Blocked',
  };
}

class _Health {
  const _Health(this.level, this.messages);
  final _HealthLevel level;
  final List<String> messages;
}

class _RouteQuality {
  const _RouteQuality({
    required this.score,
    required this.estimatedMinutes,
    required this.workloadSpread,
    required this.usedFallback,
    required this.balanceLabel,
  });

  final int score;
  final int estimatedMinutes;
  final int workloadSpread;
  final bool usedFallback;
  final String balanceLabel;
}

class _AiSegmentBadge extends StatelessWidget {
  const _AiSegmentBadge({required this.segment});

  final RetailerSegment segment;

  @override
  Widget build(BuildContext context) {
    final bool attention = segment.needsAttention;
    final DsoColors dso = context.dso;
    return Align(
      alignment: Alignment.centerLeft,
      child: Wrap(
        spacing: 6,
        runSpacing: 4,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
            decoration: BoxDecoration(
              color: attention ? dso.warningSoft : dso.infoSoft,
              borderRadius: BorderRadius.circular(999),
              border: Border.all(
                color: (attention ? dso.warning : dso.info).withValues(
                  alpha: 0.4,
                ),
              ),
            ),
            child: Text(
              '${segment.label} · ${segment.attentionScore}/100',
              style: TextStyle(
                fontSize: 10,
                fontWeight: FontWeight.w800,
                color: attention ? dso.warningText : dso.infoText,
              ),
            ),
          ),
          AiFreshnessChip(
            hasData: true,
            timestamps: <DateTime?>[segment.freshnessAt],
          ),
        ],
      ),
    );
  }
}

Object? _first(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    if (!row.containsKey(key)) continue;
    final Object? value = row[key];
    if (value != null && value.toString().trim().isNotEmpty) return value;
  }
  return null;
}

String _text(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

String _titleCase(String value) {
  final String cleaned = value.replaceAll('_', ' ').trim();
  if (cleaned.isEmpty) return 'Unknown';
  return cleaned
      .split(RegExp(r'\s+'))
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            part[0].toUpperCase() + part.substring(1).toLowerCase(),
      )
      .join(' ');
}

String _formatRelative(Object? raw) {
  final DateTime? date = _dateFromAny(raw);
  if (date == null) return 'not synced';
  final Duration age = DateTime.now().difference(date);
  if (age.inMinutes < 1) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes}m ago';
  if (age.inHours < 24) return '${age.inHours}h ago';
  if (age.inDays < 7) return '${age.inDays}d ago';
  return _fmtDate(date);
}

DateTime? _dateFromAny(Object? raw) {
  if (raw == null) return null;
  if (raw is DateTime) return raw;
  if (raw is num) {
    final int value = raw.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      value < 10000000000 ? value * 1000 : value,
    );
  }
  try {
    final dynamic dynamicValue = raw;
    final Object? converted = dynamicValue.toDate();
    if (converted is DateTime) return converted;
  } catch (_) {}
  return DateTime.tryParse(raw.toString());
}

class _WarningNote extends StatelessWidget {
  const _WarningNote({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dark ? const Color(0xFF4A3410) : const Color(0xFFFFF7ED),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(
          color: dark ? const Color(0xFF8A6A2B) : const Color(0xFFFDBA74),
        ),
      ),
      child: Row(
        children: <Widget>[
          Icon(
            Icons.warning_amber_outlined,
            size: 18,
            color: dark ? const Color(0xFFFFD166) : const Color(0xFFC2410C),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12.5,
                color: dark ? const Color(0xFFFFD166) : const Color(0xFF9A3412),
                fontWeight: FontWeight.w600,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
