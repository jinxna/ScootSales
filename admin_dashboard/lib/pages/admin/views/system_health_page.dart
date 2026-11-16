import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../app/build_flags.dart';
import '../../../app_runtime.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/forecasting_api_service.dart';
import '../../../utils/geo_field_utils.dart';
import '../../../utils/local_service_guard.dart';
import '../../../utils/price_stamp.dart';
import '../../../utils/ai_data_freshness.dart';
import '../../../widgets/ai_freshness_chip.dart';
import 'system_health_view.dart';

class SystemHealthPage extends StatefulWidget {
  const SystemHealthPage({
    super.key,
    required this.currentUser,
    this.onNavigateRequested,
  });

  final UserProfile currentUser;
  final ValueChanged<String>? onNavigateRequested;

  @override
  State<SystemHealthPage> createState() => _SystemHealthPageState();
}

class _SystemHealthPageState extends State<SystemHealthPage> {
  final CmsRepository _repository = CmsRepository();
  late Future<List<_Diagnostic>> _future;
  List<DateTime?> _aiTimestamps = const <DateTime?>[];
  bool _hasAiData = false;
  bool _hasMissingAiTimestamp = false;
  String? _lastRun;

  @override
  void initState() {
    super.initState();
    _future = _guardedChecks();
  }

  void _refresh() {
    setState(() => _future = _guardedChecks());
  }

  Future<List<_Diagnostic>> _guardedChecks() async {
    final DateTime started = DateTime.now();
    String two(int v) => v.toString().padLeft(2, '0');
    _lastRun = '${two(started.hour)}:${two(started.minute)}';
    try {
      return await _runChecks();
    } catch (error) {
      debugPrint('System health checks failed: $error');
      return const <_Diagnostic>[
        _Diagnostic(
          title: 'Health checks could not complete',
          severity: _Severity.warn,
          description: 'Some checks could not be completed. Press Run again.',
          fixKey: '',
        ),
      ];
    }
  }

  Future<List<_Diagnostic>> _runChecks() async {
    Future<List<Map<String, dynamic>>> advancedGet(
      String collection, {
      String? orderBy,
      bool descending = false,
      int? limit,
    }) => isBasicEdition
        ? Future<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[])
        : _safeGet(
            collection,
            orderBy: orderBy,
            descending: descending,
            limit: limit,
          );
    final List<List<Map<String, dynamic>>>
    data = await Future.wait(<Future<List<Map<String, dynamic>>>>[
      _safeGet('orders', orderBy: 'submittedAt', descending: true, limit: 1000),
      _safeGet('visit_logs', limit: 1000),
      _safeGet('retailers', limit: 2000),
      _safeGet('products', limit: 2000),
      advancedGet('demand_forecasts', limit: 500),
      _safeGet('route_plans', limit: 500),
      _safeGet('score_sheets', limit: 500),
      advancedGet('ai_runs', orderBy: 'startedAt', descending: true, limit: 1),
      advancedGet(
        'weekly_ai_summaries',
        orderBy: 'weekStart',
        descending: true,
        limit: 1,
      ),
    ]);

    final List<Map<String, dynamic>> orders = data[0];
    final List<Map<String, dynamic>> visits = data[1];
    final List<Map<String, dynamic>> retailers = data[2];
    final List<Map<String, dynamic>> products = data[3];
    final List<Map<String, dynamic>> forecasts = data[4];
    final List<Map<String, dynamic>> routePlans = data[5];
    final List<Map<String, dynamic>> scoreSheets = data[6];
    final List<Map<String, dynamic>> aiRuns = data[7];
    final List<Map<String, dynamic>> aiSummaries = data[8];
    final List<Map<String, dynamic>> aiRows = <Map<String, dynamic>>[
      ...forecasts,
      ...aiRuns.map(
        (Map<String, dynamic> row) => <String, dynamic>{
          ...row,
          'generatedAt': row['generatedAt'] ?? row['startedAt'],
        },
      ),
      ...aiSummaries,
    ];
    _aiTimestamps = aiRows.map(aiDataTimestamp).toList(growable: false);
    _hasAiData = aiRows.isNotEmpty;
    _hasMissingAiTimestamp = aiRows.any(
      (Map<String, dynamic> row) => aiDataTimestamp(row) == null,
    );
    final List<_Diagnostic> serviceChecks =
        await Future.wait(<Future<_Diagnostic>>[
          _checkFirebase(),
          _checkRouteEstimation(),
          if (!isBasicEdition) _checkForecastApi(),
        ]);

    return <_Diagnostic>[
      ...serviceChecks,
      _checkRequiredCollections(<String, int>{
        'orders': orders.length,
        'visit_logs': visits.length,
        'retailers': retailers.length,
        'products': products.length,
        'route_plans': routePlans.length,
      }),
      const _Diagnostic.info(
        title: 'Rules and indexes deployment',
        description:
            'Run the repository verification script, then deploy '
            'firestore.rules and firestore.indexes.json to the intended '
            'Firebase project. Local files cannot prove what is currently '
            'deployed.',
        fixKey: 'system_governance',
      ),
      _checkOrderDates(orders),
      _checkVisitFields(visits),
      _checkRetailerCoordinates(retailers),
      _checkProductPrices(products),
      _checkRetailerSalesmen(retailers),
      if (!isBasicEdition) _checkForecasts(forecasts),
      _checkRoutePlans(routePlans),
      _checkScoreSheets(scoreSheets),
      if (!isBasicEdition) _checkAiPipeline(aiRuns, aiSummaries),
    ];
  }

  _Diagnostic _checkAiPipeline(
    List<Map<String, dynamic>> runs,
    List<Map<String, dynamic>> summaries,
  ) {
    if (runs.isEmpty) {
      return const _Diagnostic(
        title: 'AI insight pipeline',
        severity: _Severity.warn,
        description:
            'No AI run history is readable. Run the AI generator before '
            'opening weekly summaries or field Scout briefs.',
        fixKey: 'reports',
      );
    }
    final Map<String, dynamic> latest = runs.first;
    final String status = '${latest['status'] ?? 'unknown'}'.toLowerCase();
    final DateTime? startedAt = _firstDate(latest, const <String>[
      'startedAt',
      'finishedAt',
    ]);
    final int ageHours = startedAt == null
        ? 9999
        : DateTime.now().difference(startedAt).inHours;
    final bool healthy =
        status == 'completed' && ageHours <= 24 * 8 && summaries.isNotEmpty;
    return _Diagnostic(
      title: 'AI insight pipeline',
      severity: healthy ? _Severity.ok : _Severity.warn,
      description: healthy
          ? 'Latest AI run completed and a weekly summary is readable.'
          : 'Latest AI run status is "$status", is older than eight days, or '
                'has no readable weekly summary. Run and inspect the generator.',
      fixKey: 'reports',
    );
  }

  Future<_Diagnostic> _checkFirebase() async {
    if (!AppRuntime.firebaseReady) {
      return const _Diagnostic(
        title: 'Firebase connection',
        severity: _Severity.warn,
        description:
            'Firebase did not initialize. Check the company record and the '
            'company Firebase project.',
        fixKey: 'system_governance',
      );
    }
    try {
      await FirebaseFirestore.instance
          .collection('system_settings')
          .limit(1)
          .get();
      return const _Diagnostic(
        title: 'Firebase connection',
        severity: _Severity.ok,
        description: 'Firebase initialized and Firestore accepted a read.',
        fixKey: 'system_governance',
      );
    } catch (_) {
      return const _Diagnostic(
        title: 'Firebase connection',
        severity: _Severity.warn,
        description:
            'Firebase initialized, but a Firestore read failed. Check network, '
            'authentication, project selection, and deployed rules.',
        fixKey: 'system_governance',
      );
    }
  }

  Future<_Diagnostic> _checkRouteEstimation() async {
    return const _Diagnostic(
      title: 'Route estimation',
      severity: _Severity.ok,
      description:
          'Route planning uses local Haversine nearest-neighbour estimates and '
          'does not require a browser-side routing API key.',
      fixKey: 'route_planner',
    );
  }

  Future<_Diagnostic> _checkForecastApi() async {
    final ForecastingApiService service = ForecastingApiService();
    if (!shouldProbeLocalService(
      service.base,
      explicitlyConfigured: service.base.isNotEmpty,
    )) {
      return const _Diagnostic.info(
        title: 'Forecast API',
        description:
            'Run Forecast needs the forecasting service on the office PC. '
            'The Demand Forecast page still shows the saved forecast.',
        fixKey: 'prediction',
      );
    }
    final bool healthy = await service.isHealthy();
    return _Diagnostic(
      title: 'Forecast API',
      severity: healthy ? _Severity.ok : _Severity.warn,
      description: healthy
          ? 'Forecast API responded at ${service.base}.'
          : 'Forecast API did not respond at ${service.base}. Start the Python '
                'service or check the company record.',
      fixKey: 'prediction',
    );
  }

  _Diagnostic _checkRequiredCollections(Map<String, int> counts) {
    final List<String> empty = counts.entries
        .where((MapEntry<String, int> entry) => entry.value == 0)
        .map((MapEntry<String, int> entry) => entry.key)
        .toList(growable: false);
    return _Diagnostic(
      title: 'Required collection readiness',
      severity: empty.isEmpty ? _Severity.ok : _Severity.warn,
      description: empty.isEmpty
          ? 'Core collections are readable and contain data.'
          : 'No readable rows were found in: ${empty.join(', ')}. Empty may be '
                'valid for a new clone, but also check project selection and '
                'Firestore rules.',
      fixKey: 'system_governance',
    );
  }

  Future<List<Map<String, dynamic>>> _safeGet(
    String collection, {
    String? orderBy,
    bool descending = false,
    int? limit,
  }) async {
    try {
      return await _repository.getCollectionOnce(
        collection,
        orderBy: orderBy,
        descending: descending,
        limit: limit,
      );
    } catch (_) {
      return <Map<String, dynamic>>[];
    }
  }

  _Diagnostic _checkOrderDates(List<Map<String, dynamic>> orders) {
    if (orders.isEmpty) {
      return const _Diagnostic.info(
        title: 'Orders missing a date field',
        description: 'No orders were read, so there is nothing to check yet.',
        fixKey: 'all_orders',
      );
    }
    final int missing = orders.where((Map<String, dynamic> o) {
      return _firstDate(o, const <String>[
            'submittedAt',
            'submitted_at',
            'orderDate',
            'order_date',
            'createdAt',
            'created_at',
            'timestamp',
          ]) ==
          null;
    }).length;
    return _Diagnostic.fromCount(
      title: 'Orders missing a date field',
      total: orders.length,
      count: missing,
      okText: 'Every order has a usable date.',
      warnText:
          '$missing of ${orders.length} orders have no submittedAt/orderDate/'
          'createdAt. They are invisible to date-ordered queries, reports and '
          'the Today dashboard.',
      fixKey: 'all_orders',
    );
  }

  _Diagnostic _checkVisitFields(List<Map<String, dynamic>> visits) {
    if (visits.isEmpty) {
      return const _Diagnostic.info(
        title: 'Visit logs missing date or salesman',
        description: 'No visit logs were read, so there is nothing to check.',
        fixKey: 'visit_logs',
      );
    }
    final int missing = visits.where((Map<String, dynamic> v) {
      final bool noDate =
          _firstDate(v, const <String>[
            'arrivalTime',
            'arrival_time',
            'departureTime',
            'departure_time',
            'timestamp',
            'createdAt',
            'created_at',
          ]) ==
          null;
      final bool noSalesman = _firstText(v, const <String>[
        'salesmanId',
        'salesman_id',
        'salesmanUid',
        'salesman_uid',
        'staffId',
        'staff_id',
        'employeeCode',
        'salesmanName',
        'salesman_name',
        'uid',
      ]).isEmpty;
      return noDate || noSalesman;
    }).length;
    return _Diagnostic.fromCount(
      title: 'Visit logs missing date or salesman',
      total: visits.length,
      count: missing,
      okText: 'Every visit log has a date and a salesman.',
      warnText:
          '$missing of ${visits.length} visit logs are missing a date or a '
          'salesman, so they cannot be attributed or ordered correctly.',
      fixKey: 'visit_logs',
    );
  }

  _Diagnostic _checkRetailerCoordinates(List<Map<String, dynamic>> retailers) {
    if (retailers.isEmpty) {
      return const _Diagnostic.info(
        title: 'Retailers missing coordinates',
        description: 'No retailers were read, so there is nothing to check.',
        fixKey: 'coordinate_review',
      );
    }
    final int missing = retailers
        .where((Map<String, dynamic> r) => readLatLng(r) == null)
        .length;
    return _Diagnostic.fromCount(
      title: 'Retailers missing coordinates',
      total: retailers.length,
      count: missing,
      okText: 'Every retailer has GPS coordinates.',
      warnText:
          '$missing of ${retailers.length} retailers have no latitude/longitude. '
          'They cannot appear on the map or be optimised in a route plan.',
      fixKey: 'coordinate_review',
    );
  }

  _Diagnostic _checkProductPrices(List<Map<String, dynamic>> products) {
    if (products.isEmpty) {
      return const _Diagnostic.info(
        title: 'Products missing a price',
        description: 'No products were read, so there is nothing to check.',
        fixKey: 'product',
      );
    }
    final int missing = products.where((Map<String, dynamic> p) {
      return cataloguePriceOf(p) <= 0;
    }).length;
    return _Diagnostic.fromCount(
      title: 'Products missing a price',
      total: products.length,
      count: missing,
      okText: 'Every product has a usable unit price.',
      warnText:
          '$missing of ${products.length} products have no usable price. Revenue '
          'totals and order values that include them will be understated.',
      fixKey: 'product',
    );
  }

  _Diagnostic _checkRetailerSalesmen(List<Map<String, dynamic>> retailers) {
    if (retailers.isEmpty) {
      return const _Diagnostic.info(
        title: 'Retailers without an assigned salesman',
        description: 'No retailers were read, so there is nothing to check.',
        fixKey: 'retailer',
      );
    }
    final int missing = retailers.where((Map<String, dynamic> r) {
      final Object? codes =
          r['assignedSalesmanCodes'] ?? r['assigned_salesman_codes'];
      if (codes is List && codes.isNotEmpty) return false;
      return _firstText(r, const <String>[
        'assignedSalesmanId',
        'assigned_salesman_id',
        'salesmanId',
        'salesman_id',
        'salesmanCode',
        'salesman_code',
      ]).isEmpty;
    }).length;
    return _Diagnostic.fromCount(
      title: 'Retailers without an assigned salesman',
      total: retailers.length,
      count: missing,
      okText: 'Every retailer is linked to a salesman.',
      warnText:
          '$missing of ${retailers.length} retailers have no assigned salesman, '
          'so they will not be picked up by route planning or team scoping.',
      fixKey: 'retailer',
      severityForCount: _Severity.warn,
    );
  }

  _Diagnostic _checkForecasts(List<Map<String, dynamic>> forecasts) {
    if (forecasts.isEmpty) {
      return const _Diagnostic(
        title: 'Forecast data missing',
        severity: _Severity.warn,
        description:
            'No demand forecasts were found. Run the forecasting pipeline '
            '(Prediction → Run Forecast) so restock and forecast alerts work.',
        fixKey: 'prediction',
      );
    }
    DateTime? newest;
    for (final Map<String, dynamic> f in forecasts) {
      final DateTime? d = _firstDate(f, const <String>[
        'createdAt',
        'created_at',
        'updatedAt',
        'updated_at',
        'runCreatedAt',
        'run_created_at',
      ]);
      if (d != null && (newest == null || d.isAfter(newest))) newest = d;
    }
    if (newest != null && DateTime.now().difference(newest).inDays > 45) {
      final int days = DateTime.now().difference(newest).inDays;
      return _Diagnostic(
        title: 'Forecast data may be stale',
        severity: _Severity.warn,
        description:
            'The latest forecast run is $days days old. Re-run the pipeline to '
            'keep restock recommendations current.',
        fixKey: 'prediction',
      );
    }
    return _Diagnostic(
      title: 'Forecast data present',
      severity: _Severity.ok,
      description:
          '${forecasts.length} forecast rows are available for restock and '
          'demand insights.',
      fixKey: 'prediction',
    );
  }

  _Diagnostic _checkRoutePlans(List<Map<String, dynamic>> plans) {
    if (plans.isEmpty) {
      return const _Diagnostic.info(
        title: 'Route plans missing stops',
        description:
            'No route plans exist yet. Create one in Route Planner once '
            'retailers have coordinates.',
        fixKey: 'route_planner',
      );
    }
    final int emptyPlans = plans.where((Map<String, dynamic> p) {
      final Object? days = p['days'];
      if (days is! List || days.isEmpty) return true;
      for (final Object? day in days) {
        if (day is Map) {
          final Object? stops = day['stops'];
          if (stops is List && stops.isNotEmpty) return false;
        }
      }
      return true;
    }).length;
    return _Diagnostic.fromCount(
      title: 'Route plans missing stops',
      total: plans.length,
      count: emptyPlans,
      okText: 'Every route plan has at least one stop.',
      warnText:
          '$emptyPlans of ${plans.length} route plans have no stops — likely '
          'because their retailers lack coordinates.',
      fixKey: 'route_planner',
    );
  }

  _Diagnostic _checkScoreSheets(List<Map<String, dynamic>> sheets) {
    if (sheets.isEmpty) {
      return const _Diagnostic.info(
        title: 'Score sheet schema mismatch',
        description: 'No master score sheets were read, so nothing to check.',
        fixKey: 'retailer_scoresheets',
      );
    }
    final int malformed = sheets.where((Map<String, dynamic> s) {
      final Object? kind = s['kind'];
      if (kind == 'template' || kind == 'assignment') {
        final Object? productIds = s['productIds'];
        return productIds is! List || productIds.isEmpty;
      }
      final Object? items = s['items'] ?? s['products'] ?? s['rows'];
      final bool hasItems = items is List && items.isNotEmpty;
      final bool hasIdentity = _firstText(s, const <String>[
        'retailerId',
        'retailer_id',
        'templateId',
        'template_id',
        'name',
        'title',
      ]).isNotEmpty;
      return !hasItems || !hasIdentity;
    }).length;
    return _Diagnostic.fromCount(
      title: 'Score sheet schema mismatch',
      total: sheets.length,
      count: malformed,
      okText: 'Every master score sheet has items and an identifier.',
      warnText:
          '$malformed of ${sheets.length} score sheets are missing an item list '
          'or identifier and may not render on the mobile score sheet.',
      fixKey: 'retailer_scoresheets',
    );
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<List<_Diagnostic>>(
      future: _future,
      builder:
          (BuildContext context, AsyncSnapshot<List<_Diagnostic>> snapshot) {
            final bool loading =
                snapshot.connectionState == ConnectionState.waiting;
            final List<_Diagnostic> checks =
                snapshot.data ?? const <_Diagnostic>[];
            return SystemHealthView(
              loading: loading,
              onRun: _refresh,
              lastRun: _lastRun,
              onOpenPage: widget.onNavigateRequested == null
                  ? null
                  : (String key) {
                      if (!isPageHiddenInUserTesting(key)) {
                        widget.onNavigateRequested!(key);
                      }
                    },
              extra: isBasicEdition
                  ? null
                  : Align(
                      alignment: Alignment.centerLeft,
                      child: AiFreshnessChip(
                        hasData: _hasAiData,
                        timestamps: _aiTimestamps,
                        hasMissingTimestamp: _hasMissingAiTimestamp,
                      ),
                    ),
              items: <HealthItem>[
                for (final _Diagnostic d in checks)
                  HealthItem(
                    title: d.title,
                    description: d.description,
                    fixKey: d.fixKey,
                    status: switch (d.severity) {
                      _Severity.ok => HealthStatus.passed,
                      _Severity.warn => HealthStatus.attention,
                      _Severity.info => HealthStatus.info,
                    },
                  ),
              ],
            );
          },
    );
  }
}

enum _Severity { ok, warn, info }

class _Diagnostic {
  const _Diagnostic({
    required this.title,
    required this.severity,
    required this.description,
    required this.fixKey,
  });

  const _Diagnostic.info({
    required this.title,
    required this.description,
    required this.fixKey,
  }) : severity = _Severity.info;

  factory _Diagnostic.fromCount({
    required String title,
    required int total,
    required int count,
    required String okText,
    required String warnText,
    required String fixKey,
    _Severity severityForCount = _Severity.warn,
  }) {
    return _Diagnostic(
      title: title,
      severity: count == 0 ? _Severity.ok : severityForCount,
      description: count == 0 ? okText : warnText,
      fixKey: fixKey,
    );
  }

  final String title;
  final _Severity severity;
  final String description;
  final String fixKey;
}

Object? _first(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    if (!row.containsKey(key)) continue;
    final Object? value = row[key];
    if (value != null && value.toString().trim().isNotEmpty) return value;
  }
  return null;
}

String _firstText(Map<String, dynamic> row, List<String> keys) {
  final Object? value = _first(row, keys);
  if (value == null) return '';
  final String text = value.toString().trim();
  return text.toLowerCase() == 'null' ? '' : text;
}

DateTime? _firstDate(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    final Object? value = row[key];
    if (value == null) continue;
    final DateTime? parsed = _toDate(value);
    if (parsed != null) return parsed;
  }
  return null;
}

DateTime? _toDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  try {
    final dynamic candidate = value;
    final Object? maybe = candidate.toDate();
    if (maybe is DateTime) return maybe;
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
