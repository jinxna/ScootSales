import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter/services.dart';

import '../../../models/user_profile.dart';
import '../../../models/weekly_ai_summary.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/audit_log_service.dart';
import '../../../services/forecast_window_service.dart';
import '../../../services/forecasting_api_service.dart';
import '../../../services/forecast_snapshot_cache.dart';
import '../../../services/weekly_ai_report_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/count_label.dart';
import '../../../utils/forecast_catalogue_provenance.dart';
import '../../../utils/local_service_guard.dart';
import '../../../utils/order_data_utils.dart';
import '../../../utils/user_facing_error.dart';
import '../../../utils/ai_data_freshness.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../../../widgets/horizontal_scroll_cue.dart';
import 'prediction_states.dart';

const Color _green = Color(0xFF27AE60);
const int _firestoreForecastRowLimit = 1000;

const int _catalogueRowLimit = 2000;

const String _savedForecastSource = 'Saved forecast';

class PredictionPage extends StatefulWidget {
  const PredictionPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<PredictionPage> createState() => _PredictionPageState();
}

class _PredictionPageState extends State<PredictionPage>
    with SingleTickerProviderStateMixin {
  final CmsRepository _repository = CmsRepository();
  final ForecastingApiService _api = ForecastingApiService();
  final ForecastWindowService _windowService = ForecastWindowService();
  final TextEditingController _windowController = TextEditingController(
    text: '${ForecastWindowService.defaultWeeks}',
  );
  late final ForecastSnapshotCache _forecastCache;
  final WeeklyAiReportService _accuracyService = WeeklyAiReportService();
  late final TabController _tabController;

  late final bool _toolsEnabled;
  late Stream<List<WeeklyAiSummary>> _accuracySummaries;

  bool _loading = true;
  String _error = '';
  bool _noForecast = false;
  String _source = '';
  List<Map<String, dynamic>> _forecasts = <Map<String, dynamic>>[];
  List<Map<String, dynamic>> _runs = <Map<String, dynamic>>[];
  String _statusFilter = 'all';
  String _forecastMethod = 'adaptive';
  int _loadGeneration = 0;
  bool _usingOfflineSnapshot = false;
  DateTime? _snapshotGeneratedAt;
  String _periodStart = '';
  String _dataCutoff = '';
  String _setGeneratedAt = '';
  int? _historyWeeks;
  bool? _windowEvaluated;

  int? _savedWindowWeeks;
  Map<String, dynamic>? _preview;
  bool _previewBusy = false;
  bool _windowSaving = false;

  int _catalogueExcludedCount = 0;
  bool _catalogueVerificationRan = false;
  List<String> _catalogueExcludedSamples = const <String>[];

  bool _serviceOnline = false;
  bool _busy = false;
  String _busyLabel = '';

  @override
  void initState() {
    super.initState();
    _toolsEnabled = _canUseLocalForecast;
    _tabController = TabController(length: _toolsEnabled ? 4 : 3, vsync: this);
    final String accountId = widget.currentUser.uid?.trim().isNotEmpty == true
        ? widget.currentUser.uid!.trim()
        : widget.currentUser.docId.trim();
    final String accountScope =
        '$accountId|${widget.currentUser.role}|${widget.currentUser.branchId}';
    _forecastCache = ForecastSnapshotCache(
      storageKey: ForecastSnapshotCache.storageKeyForScope(accountScope),
    );
    _accuracySummaries = _accuracyService.watchSummaries(widget.currentUser);
    _load();
    if (_toolsEnabled) _loadSavedWindow();
  }

  @override
  void dispose() {
    _windowController.dispose();
    _tabController.dispose();
    super.dispose();
  }

  Future<void> _loadSavedWindow() async {
    try {
      final int? saved = await _windowService.readLiveWeeks();
      if (!mounted) return;
      setState(() {
        _savedWindowWeeks = saved;
        _windowController.text =
            '${saved ?? _historyWeeks ?? ForecastWindowService.defaultWeeks}';
      });
    } catch (_) {}
  }

  bool get _canUseLocalForecast =>
      widget.currentUser.isActive &&
      widget.currentUser.isAdmin &&
      shouldProbeLocalService(
        _api.base,
        explicitlyConfigured: _api.base.isNotEmpty,
      );

  Future<List<Map<String, dynamic>>?> _loadProductCatalogue() async {
    try {
      return await _repository.getCollectionOnce(
        'products',
        limit: _catalogueRowLimit,
        timeout: const Duration(seconds: 10),
      );
    } catch (_) {
      return null;
    }
  }

  Future<void> _load() async {
    final int generation = ++_loadGeneration;
    setState(() {
      _loading = true;
      _error = '';
      _noForecast = false;
    });

    final Future<List<Map<String, dynamic>>?> catalogueFuture =
        _loadProductCatalogue();

    try {
      final bool localReady = _canUseLocalForecast && await _api.isReady();
      if (!mounted || generation != _loadGeneration) return;
      if (localReady != _serviceOnline) {
        setState(() => _serviceOnline = localReady);
      }
      if (localReady) {
        final Future<List<Map<String, dynamic>>> localRunsFuture = _api
            .forecastRuns()
            .catchError((_) => <Map<String, dynamic>>[]);
        final Map<String, dynamic> localSet = await _api.latestForecast();
        if (!mounted || generation != _loadGeneration) return;
        final List<Map<String, dynamic>> local = <Map<String, dynamic>>[
          for (final dynamic row
              in (localSet['rows'] as List<dynamic>? ?? const <dynamic>[]))
            if (row is Map) Map<String, dynamic>.from(row),
        ];
        final List<Map<String, dynamic>> localProduction = local
            .where((Map<String, dynamic> row) => !isDemoRow(row))
            .toList(growable: false);
        if (localProduction.isNotEmpty) {
          final List<Map<String, dynamic>> runs = await localRunsFuture;
          final List<Map<String, dynamic>>? catalogue = await catalogueFuture;
          if (!mounted || generation != _loadGeneration) return;
          _periodStart = _text(localSet['periodStart']);
          _dataCutoff = _text(localSet['dataCutoff']);
          _setGeneratedAt = _text(localSet['generatedAt']);
          _historyWeeks = _optionalRunInt(localSet['historyWeeks']);
          _windowEvaluated = _optionalBool(localSet['windowEvaluated']);
          _forecastCache.save(
            rows: localProduction,
            source: 'Local forecasting service',
          );
          _applyData(
            localProduction,
            runs,
            'Local forecasting service',
            generation: generation,
            catalogue: catalogue,
          );
          return;
        }
      }

      final Future<List<Map<String, dynamic>>> runsFuture = _repository
          .getCollectionOnce(
            'forecast_training_runs',
            orderBy: 'createdAt',
            descending: true,
            limit: 10,
            timeout: const Duration(seconds: 10),
          )
          .catchError((_) => <Map<String, dynamic>>[]);
      final List<Map<String, dynamic>> fromFirestore = await _repository
          .getCollectionOnce(
            'demand_forecasts',
            orderBy: 'forecastMonth',
            descending: true,
            limit: _firestoreForecastRowLimit,
            timeout: const Duration(seconds: 10),
          );
      if (fromFirestore.isNotEmpty) {
        final List<Map<String, dynamic>> productionForecasts =
            selectLatestForecastPeriod(
              fromFirestore
                  .where((Map<String, dynamic> row) => !isDemoRow(row))
                  .toList(growable: false),
            );
        if (productionForecasts.isNotEmpty) {
          final List<Map<String, dynamic>>? catalogue = await catalogueFuture;
          if (!mounted || generation != _loadGeneration) return;
          final Map<String, dynamic> first = productionForecasts.first;
          _periodStart = _text(first['periodStart']);
          _dataCutoff = _text(first['dataCutoff']);
          _setGeneratedAt = _text(first['generatedAt']);
          _historyWeeks = _optionalRunInt(first['historyWeeks']);
          _windowEvaluated = _optionalBool(first['windowEvaluated']);
          final String label =
              productionForecasts.length >= _firestoreForecastRowLimit
              ? '$_savedForecastSource (latest 1,000 rows shown)'
              : _savedForecastSource;
          _forecastCache.save(rows: productionForecasts, source: label);
          _applyData(
            productionForecasts,
            const <Map<String, dynamic>>[],
            label,
            generation: generation,
            catalogue: catalogue,
          );
          final List<Map<String, dynamic>> runs = await runsFuture;
          _applyRuns(runs, generation);
          return;
        }
      }
      await _loadCachedSnapshot(
        generation: generation,
        catalogue: await catalogueFuture,
      );
    } catch (error) {
      await _loadCachedSnapshot(
        generation: generation,
        cause: error,
        catalogue: await catalogueFuture,
      );
    }
  }

  Future<void> _loadCachedSnapshot({
    required int generation,
    Object? cause,
    List<Map<String, dynamic>>? catalogue,
  }) async {
    final ForecastSnapshot? snapshot = _forecastCache.read();
    final ForecastFallback fallback = forecastFallback(
      serviceReady: _serviceOnline,
      hasSavedCopy: snapshot != null,
      readFailed: cause != null,
    );
    if (snapshot != null) {
      if (mounted && generation == _loadGeneration) {
        setState(() => _serviceOnline = fallback.serviceOnline);
      }
      _applyData(
        snapshot.rows,
        const <Map<String, dynamic>>[],
        'Saved offline snapshot',
        generation: generation,
        offlineSnapshotAt: snapshot.generatedAt,
        catalogue: catalogue,
      );
      return;
    }
    if (!mounted || generation != _loadGeneration) return;
    setState(() {
      _loading = false;
      _serviceOnline = fallback.serviceOnline;
      _noForecast = fallback.noForecast;
      if (fallback.loadFailed) {
        _error = 'The forecasts could not be loaded.';
        debugPrint('Forecast load failed: $cause');
      }
    });
  }

  void _applyData(
    List<Map<String, dynamic>> forecasts,
    List<Map<String, dynamic>> runs,
    String source, {
    required int generation,
    DateTime? offlineSnapshotAt,
    List<Map<String, dynamic>>? catalogue,
  }) {
    if (!mounted || generation != _loadGeneration) return;
    final ForecastCatalogueSelection selection = selectCatalogueForecasts(
      forecasts: forecasts,
      catalogue: catalogue,
    );
    final List<Map<String, dynamic>> sortedForecasts = selection.rows
        .map((Map<String, dynamic> row) => Map<String, dynamic>.from(row))
        .toList(growable: true);
    sortedForecasts.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final double aPoint = _predictionNumber(a['point']);
      final double bPoint = _predictionNumber(b['point']);
      if (aPoint != bPoint) return bPoint.compareTo(aPoint);
      return _text(a['productName']).compareTo(_text(b['productName']));
    });
    setState(() {
      _loading = false;
      _forecasts = sortedForecasts;
      _runs = runs;
      _source = source;
      if (_periodStart.isEmpty && sortedForecasts.isNotEmpty) {
        final Map<String, dynamic> first = sortedForecasts.first;
        _periodStart = _text(first['periodStart']);
        _dataCutoff = _text(first['dataCutoff']);
        _setGeneratedAt = _text(first['generatedAt']);
        _historyWeeks = _optionalRunInt(first['historyWeeks']);
        _windowEvaluated = _optionalBool(first['windowEvaluated']);
      }
      _usingOfflineSnapshot = offlineSnapshotAt != null;
      _snapshotGeneratedAt = offlineSnapshotAt;
      _catalogueExcludedCount = selection.excludedCount;
      _catalogueVerificationRan = selection.verificationAvailable;
      _catalogueExcludedSamples = selection.excludedSamples;
    });
  }

  void _applyRuns(List<Map<String, dynamic>> runs, int generation) {
    if (!mounted || generation != _loadGeneration) return;
    setState(() => _runs = runs);
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Align(alignment: Alignment.centerRight, child: _toolbar()),
        const SizedBox(height: 16),
        Expanded(child: _buildBody()),
      ],
    );
  }

  Widget _toolbar() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Wrap(
      alignment: WrapAlignment.end,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 8,
      runSpacing: 4,
      children: <Widget>[
        if (_toolsEnabled) ...<Widget>[
          OutlinedButton.icon(
            onPressed: (_busy || !_serviceOnline || !_canUseLocalForecast)
                ? null
                : _uploadExcel,
            icon: const Icon(ScootIcons.upload, size: 16),
            label: const Text('Import Excel'),
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.onSurface,
              visualDensity: VisualDensity.compact,
              side: BorderSide(color: scheme.outlineVariant),
            ),
          ),
          FilledButton.icon(
            onPressed: (_busy || !_serviceOnline || !_canUseLocalForecast)
                ? null
                : () => _runForecast(),
            icon: _busy
                ? const SizedBox(
                    width: 14,
                    height: 14,
                    child: CircularProgressIndicator(
                      strokeWidth: 2,
                      color: Colors.white,
                    ),
                  )
                : const Icon(Icons.play_arrow_rounded, size: 18),
            label: Text(
              _busy && _busyLabel.isNotEmpty ? _busyLabel : 'Run forecast',
            ),
            style: FilledButton.styleFrom(visualDensity: VisualDensity.compact),
          ),
        ],
        IconButton(
          tooltip: 'Reload forecasts',
          onPressed: (_loading || _busy) ? null : _load,
          icon: const Icon(ScootIcons.refresh, size: 20),
        ),
      ],
    );
  }

  bool _checking = false;

  Future<void> _checkService() async {
    setState(() => _checking = true);
    final bool ready = _canUseLocalForecast && await _api.isReady();
    if (!mounted) return;
    setState(() {
      _serviceOnline = ready;
      _checking = false;
    });
  }

  Future<void> _runForecast() async {
    if (!_canUseLocalForecast || !await _api.isReady()) {
      if (!mounted) return;
      setState(() => _serviceOnline = false);
      _toast(
        'The forecasting service is not available right now. Try again later.',
        error: true,
      );
      return;
    }
    setState(() {
      _busy = true;
      _busyLabel = 'Running…';
      _serviceOnline = true;
    });
    try {
      final Map<String, dynamic> result = await _api.runForecast();
      if (!mounted) return;
      if (_text(result['status']) == 'completed') {
        await AuditLogService.instance.record(
          action: 'updated',
          entityType: 'forecast',
          entityId: _text(result['runId']).isEmpty
              ? 'latest'
              : _text(result['runId']),
          summary: 'Ran demand forecast',
          metadata: <String, dynamic>{
            'forecastedProducts': result['forecastedProducts'] ?? 0,
            'insufficientHistoryProducts':
                result['insufficientHistoryProducts'] ?? 0,
            'productCount': result['productCount'] ?? 0,
            'modelMix': result['modelMix'] ?? const <String, dynamic>{},
            'historyWeeks': result['historyWeeks'],
          },
        );
        _toast('Forecast complete — ${_forecastRunSummary(result)}.');
        setState(() => _preview = null);
        await _load();
      } else {
        _toast(
          'The forecast could not be completed. Please try again later.',
          error: true,
        );
      }
    } catch (error) {
      if (mounted) {
        _toast(userFacingError(error, action: 'run the forecast'), error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  Future<void> _uploadExcel() async {
    if (!_canUseLocalForecast || !await _api.isReady()) {
      if (!mounted) return;
      setState(() => _serviceOnline = false);
      _toast(
        'Forecasting service is offline or this administrator session is unavailable.',
        error: true,
      );
      return;
    }
    final PickedFile? file = await ForecastingApiService.pickSpreadsheet();
    if (file == null) return;
    setState(() {
      _busy = true;
      _busyLabel = 'Importing…';
      _serviceOnline = true;
    });
    try {
      final Map<String, dynamic> result = await _api.importExcel(file);
      if (!mounted) return;
      if (_text(result['status']) != 'ok') {
        _toast('Import failed: ${_text(result['message'])}', error: true);
        return;
      }
      final Map<String, dynamic> summary = Map<String, dynamic>.from(
        result['import'] as Map,
      );
      await AuditLogService.instance.record(
        action: 'imported',
        entityType: 'forecast',
        entityId: file.name,
        summary: 'Imported forecast source file ${file.name}',
        metadata: <String, dynamic>{
          'validRows': summary['validRows'] ?? 0,
          'errorRows': summary['errorRows'] ?? 0,
        },
      );
      await _showImportSummaryDialog(summary);
    } catch (error) {
      if (mounted) {
        _toast(userFacingError(error, action: 'import the file'), error: true);
      }
    } finally {
      if (mounted) {
        setState(() {
          _busy = false;
          _busyLabel = '';
        });
      }
    }
  }

  Future<void> _showImportSummaryDialog(Map<String, dynamic> summary) async {
    final int valid = (summary['validRows'] as num?)?.toInt() ?? 0;
    final int errors = (summary['errorRows'] as num?)?.toInt() ?? 0;
    final int warnings = (summary['warningRows'] as num?)?.toInt() ?? 0;
    final int total = (summary['totalRows'] as num?)?.toInt() ?? 0;
    final List<dynamic> issues =
        (summary['issues'] as List<dynamic>?) ?? <dynamic>[];
    final List<dynamic> unmapped =
        (summary['unmappedRequired'] as List<dynamic>?) ?? <dynamic>[];

    final bool runNow =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) {
            final ColorScheme scheme = Theme.of(context).colorScheme;
            return AlertDialog(
              title: Row(
                children: <Widget>[
                  Icon(
                    valid > 0 ? Icons.task_alt_outlined : Icons.error_outline,
                    color: valid > 0 ? _green : context.dso.dangerText,
                  ),
                  const SizedBox(width: 10),
                  const Expanded(
                    child: Text(
                      'Import summary',
                      style: TextStyle(
                        fontSize: 18,
                        fontWeight: FontWeight.w800,
                      ),
                    ),
                  ),
                ],
              ),
              content: SizedBox(
                width: 460,
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      _text(summary['sourceFile']),
                      style: TextStyle(
                        fontWeight: FontWeight.w700,
                        color: scheme.onSurface,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 10,
                      runSpacing: 10,
                      children: <Widget>[
                        _importStat(
                          'Total rows',
                          '$total',
                          scheme.onSurfaceVariant,
                        ),
                        _importStat('Imported', '$valid', _green),
                        _importStat(
                          'Rejected',
                          '$errors',
                          errors > 0
                              ? context.dso.dangerText
                              : scheme.onSurfaceVariant,
                        ),
                        _importStat(
                          'Warnings',
                          '$warnings',
                          warnings > 0
                              ? context.dso.warningText
                              : scheme.onSurfaceVariant,
                        ),
                      ],
                    ),
                    if (unmapped.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 12),
                      Container(
                        padding: const EdgeInsets.all(10),
                        decoration: BoxDecoration(
                          color: context.dso.dangerSoft,
                          borderRadius: BorderRadius.circular(8),
                        ),
                        child: Text(
                          'Missing required columns: ${unmapped.join(', ')}. '
                          'Add a Date, Product and Quantity column.',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: context.dso.dangerText,
                          ),
                        ),
                      ),
                    ],
                    if (issues.isNotEmpty) ...<Widget>[
                      const SizedBox(height: 14),
                      Text(
                        'First issues',
                        style: TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w800,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      const SizedBox(height: 6),
                      ConstrainedBox(
                        constraints: const BoxConstraints(maxHeight: 160),
                        child: ListView(
                          shrinkWrap: true,
                          children: issues.take(12).map((dynamic raw) {
                            final Map<String, dynamic> issue =
                                Map<String, dynamic>.from(raw as Map);
                            final bool isError =
                                _text(issue['severity']) == 'error';
                            return Padding(
                              padding: const EdgeInsets.only(bottom: 5),
                              child: Row(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Icon(
                                    isError
                                        ? Icons.cancel_outlined
                                        : Icons.warning_amber_outlined,
                                    size: 14,
                                    color: isError
                                        ? context.dso.dangerText
                                        : context.dso.warningText,
                                  ),
                                  const SizedBox(width: 6),
                                  Expanded(
                                    child: Text(
                                      'Row ${issue['row']}: ${_text(issue['issueType'])} — ${_text(issue['detail'])}',
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: scheme.onSurface,
                                        height: 1.4,
                                      ),
                                    ),
                                  ),
                                ],
                              ),
                            );
                          }).toList(),
                        ),
                      ),
                    ],
                  ],
                ),
              ),
              actions: <Widget>[
                TextButton(
                  onPressed: () => Navigator.of(context).pop(false),
                  child: const Text('Close'),
                ),
                FilledButton.icon(
                  onPressed: valid > 0
                      ? () => Navigator.of(context).pop(true)
                      : null,
                  style: FilledButton.styleFrom(backgroundColor: _green),
                  icon: const Icon(Icons.play_arrow_rounded, size: 18),
                  label: const Text('Run both forecasts now'),
                ),
              ],
            );
          },
        ) ??
        false;

    if (runNow) {
      await _runForecast();
    }
  }

  Widget _importStat(String label, String value, Color color) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 18,
              fontWeight: FontWeight.w800,
              color: color,
            ),
          ),
          Text(
            label,
            style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }

  void _toast(String message, {bool error = false}) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: error
            ? context.dso.dangerText
            : const Color(0xFF1A4A3C),
        behavior: SnackBarBehavior.floating,
        duration: Duration(seconds: error ? 6 : 4),
      ),
    );
  }

  String _methodLabel(String method) =>
      method == 'sarima' ? 'SARIMA' : 'Adaptive weekly';

  Map<String, dynamic> _methodRow(Map<String, dynamic> outer, String method) {
    final Object? comparisons = outer['comparisonForecasts'];
    if (comparisons is Map && comparisons[method] is Map) {
      final Map<String, dynamic> row = Map<String, dynamic>.from(
        comparisons[method] as Map,
      );
      if (outer['status'] == 'stale') row['status'] = 'stale';
      return row;
    }
    final String savedModel = _text(outer['model'] ?? outer['modelUsed']);
    const Set<String> weeklyModels = <String>{
      'aggregate',
      'adaptive',
      'theta',
      'croston',
      'tsb',
      'moving_average',
      'naive_last',
    };
    final bool isWeekly =
        weeklyModels.contains(savedModel.toLowerCase()) ||
        (savedModel.isEmpty &&
            _text(outer['modelVersion']).startsWith('ai-forecast-models/'));
    if (method == 'adaptive' && comparisons == null && isWeekly) {
      return outer;
    }
    return <String, dynamic>{
      for (final String field in const <String>[
        'productId',
        'productCode',
        'productName',
        'category',
        'periodStart',
        'periodEnd',
        'forecastMonth',
        'dataCutoff',
        'generatedAt',
      ])
        if (outer.containsKey(field)) field: outer[field],
      'status': 'not_generated',
      'point': null,
      if (comparisons == null && !isWeekly)
        'legacyModel': savedModel.isEmpty ? 'Unrecorded' : savedModel,
    };
  }

  Widget _methodSelector() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        SizedBox(
          width: 300,
          child: DropdownButtonFormField<String>(
            initialValue: _forecastMethod,
            isExpanded: true,
            decoration: const InputDecoration(
              labelText: 'Forecast method',
              border: OutlineInputBorder(),
            ),
            items: const <DropdownMenuItem<String>>[
              DropdownMenuItem(
                value: 'adaptive',
                child: Text('Adaptive weekly'),
              ),
              DropdownMenuItem(value: 'sarima', child: Text('SARIMA')),
              DropdownMenuItem(value: 'compare', child: Text('Compare both')),
            ],
            onChanged: (String? value) {
              if (value != null) setState(() => _forecastMethod = value);
            },
          ),
        ),
        const SizedBox(height: 8),
        if (_forecasts.any(
          (row) => _methodRow(row, 'adaptive').containsKey('legacyModel'),
        ))
          Text(
            'Historical saved models: ${_forecasts.map((row) => _methodRow(row, 'adaptive')['legacyModel']).whereType<String>().toSet().join(', ')}. Run both forecasts to compare; historical estimates are not used for either method.',
          ),
        Text(
          _forecastMethod == 'compare'
              ? 'Same products and forecast week. Each method is summarized separately.'
              : '${_methodLabel(_forecastMethod)} estimates for the selected forecast week.',
        ),
        if (_forecastMethod != 'adaptive') ...<Widget>[
          const SizedBox(height: 4),
          const Text(
            'Historical accuracy is available for Adaptive weekly only; SARIMA has no historical accuracy score here.',
          ),
        ],
      ],
    );
  }

  Widget _methodSummary(String method, List<Map<String, dynamic>> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${_methodLabel(method)} summary',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        const SizedBox(height: 8),
        _summaryCards(rows),
      ],
    );
  }

  Widget _methodTable(String method, List<Map<String, dynamic>> rows) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${_methodLabel(method)} forecasts',
          style: Theme.of(context).textTheme.titleMedium,
        ),
        if (rows.any((row) => row['status'] == 'not_generated')) ...<Widget>[
          const SizedBox(height: 8),
          const Text('Run both forecasts to compare.'),
        ],
        const SizedBox(height: 8),
        LayoutBuilder(
          builder: (context, constraints) {
            return HorizontalScrollCue(
              child: SizedBox(
                width: constraints.maxWidth < 1100
                    ? 1100
                    : constraints.maxWidth,
                child: _forecastTable(rows),
              ),
            );
          },
        ),
      ],
    );
  }

  Widget _buildBody() {
    if (_loading) {
      return SingleChildScrollView(child: ForecastLoading(onRetry: _load));
    }
    if (_error.isNotEmpty || _noForecast) {
      return SingleChildScrollView(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ForecastStatusNotices(
              toolsEnabled: _toolsEnabled,
              hasForecastingService: _api.base.isNotEmpty,
              serviceOnline: _serviceOnline,
              isAdmin: widget.currentUser.isAdmin,
              onCheckAgain: _checkService,
              checking: _checking,
            ),
            ForecastUnavailable(loadFailed: _error.isNotEmpty, onRetry: _load),
          ],
        ),
      );
    }

    final bool compare = _forecastMethod == 'compare';
    final String selectedMethod = compare ? 'adaptive' : _forecastMethod;
    final List<Map<String, dynamic>> selected = _forecasts
        .map((row) => _methodRow(row, selectedMethod))
        .toList(growable: false);
    final List<int> visibleIndexes = <int>[
      for (int i = 0; i < selected.length; i++)
        if (_statusFilter == 'all' ||
            (_statusFilter == 'forecasted'
                ? forecastRowCountsAsForecast(selected[i])
                : !forecastRowCountsAsForecast(selected[i])))
          i,
    ];
    final List<Map<String, dynamic>> visible = <Map<String, dynamic>>[
      for (final int i in visibleIndexes) selected[i],
    ];
    final List<Map<String, dynamic>> sarima = compare
        ? <Map<String, dynamic>>[
            for (final int i in visibleIndexes)
              _methodRow(_forecasts[i], 'sarima'),
          ]
        : const <Map<String, dynamic>>[];

    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final double tabHeight = constraints.hasBoundedHeight
            ? (constraints.maxHeight * 0.62).clamp(460.0, 640.0).toDouble()
            : 560.0;
        return SingleChildScrollView(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ForecastStatusNotices(
                toolsEnabled: _toolsEnabled,
                hasForecastingService: _api.base.isNotEmpty,
                serviceOnline: _serviceOnline,
                isAdmin: widget.currentUser.isAdmin,
                onCheckAgain: _checkService,
                checking: _checking,
                savedForecastLabel: _usingOfflineSnapshot
                    ? _savedForecastLabel()
                    : null,
              ),
              Row(
                children: <Widget>[
                  AiFreshnessChip(
                    hasData: _forecasts.isNotEmpty,
                    timestamps: <DateTime?>[
                      if (_setGeneratedAt.isNotEmpty)
                        aiDataTimestamp(<String, dynamic>{
                          'generatedAt': _setGeneratedAt,
                        }),
                      ..._forecasts.map(
                        (Map<String, dynamic> row) =>
                            aiDataTimestamp(<String, dynamic>{
                              ...row,
                              'generatedAt':
                                  row['generatedAt'] ??
                                  row['runCreatedAt'] ??
                                  row['createdAt'],
                            }),
                      ),
                    ],
                    hasMissingTimestamp: _forecasts.any(
                      (Map<String, dynamic> row) =>
                          aiDataTimestamp(<String, dynamic>{
                            ...row,
                            'generatedAt':
                                row['generatedAt'] ??
                                row['runCreatedAt'] ??
                                row['createdAt'],
                          }) ==
                          null,
                    ),
                  ),
                  const SizedBox(width: 8),
                  if (!_usingOfflineSnapshot && _source.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    _chip(_sourceChipLabel()),
                  ],
                  if (_forecasts.isNotEmpty) ...<Widget>[
                    const SizedBox(width: 8),
                    _chip(forecastFreshnessLabel(_forecasts)),
                  ],
                  const SizedBox(width: 12),
                  Expanded(
                    child: Text(
                      _periodLine(),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      textAlign: TextAlign.right,
                      style: TextStyle(
                        fontSize: 12,
                        color: Theme.of(context).colorScheme.onSurfaceVariant,
                      ),
                    ),
                  ),
                ],
              ),
              if (_catalogueNote() != null) ...<Widget>[
                const SizedBox(height: 12),
                _catalogueNote()!,
              ],
              if (_toolsEnabled) ...<Widget>[
                const SizedBox(height: 16),
                _windowCard(),
              ],
              const SizedBox(height: 16),
              _methodSelector(),
              const SizedBox(height: 16),
              if (_forecastMethod == 'adaptive') ...<Widget>[
                _forecastAccuracyCard(),
                const SizedBox(height: 16),
              ],
              _methodSummary(selectedMethod, visible),
              if (compare) ...<Widget>[
                const SizedBox(height: 16),
                _methodSummary('sarima', sarima),
              ],
              const SizedBox(height: 16),
              TabBar(
                controller: _tabController,
                isScrollable: true,
                tabs: <Tab>[
                  Tab(text: 'Forecast Overview'),
                  Tab(
                    icon: Icon(Icons.inventory_2_outlined),
                    text: 'Restock Recommendations',
                  ),
                  if (_toolsEnabled) const Tab(text: 'Excel Import'),
                  Tab(text: 'Run History'),
                ],
              ),
              const SizedBox(height: 12),
              SizedBox(
                height: tabHeight,
                child: TabBarView(
                  controller: _tabController,
                  children: <Widget>[
                    ListView(
                      padding: EdgeInsets.zero,
                      children: <Widget>[
                        _filterBar(),
                        const SizedBox(height: 12),
                        if (compare) ...<Widget>[
                          const Text(
                            'Filters use Adaptive weekly. Both tables show the same products.',
                          ),
                          const SizedBox(height: 12),
                        ],
                        _methodTable(selectedMethod, visible),
                        if (compare) ...<Widget>[
                          const SizedBox(height: 24),
                          _methodTable('sarima', sarima),
                        ],
                      ],
                    ),
                    Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Padding(
                          padding: const EdgeInsets.only(bottom: 12),
                          child: Text(
                            compare
                                ? 'Restock recommendations use Adaptive weekly.'
                                : 'Restock recommendations use ${_methodLabel(selectedMethod)}.',
                          ),
                        ),
                        Expanded(
                          child: _RestockRecommendationsTab(rows: visible),
                        ),
                      ],
                    ),
                    if (_toolsEnabled)
                      _ExcelImportTab(
                        serviceOnline: _serviceOnline,
                        busy: _busy,
                        busyLabel: _busyLabel,
                        onImportExcel: (_busy || !_serviceOnline)
                            ? null
                            : _uploadExcel,
                        onRunForecast: (_busy || !_serviceOnline)
                            ? null
                            : () => _runForecast(),
                      ),
                    _runs.isEmpty
                        ? _EmptyState(
                            icon: Icons.history,
                            title: 'No forecast run history yet',
                            subtitle:
                                'No forecast has been generated for this company yet.',
                          )
                        : ListView(
                            padding: EdgeInsets.zero,
                            children: <Widget>[_runHistory()],
                          ),
                  ],
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  int? get _typedWindow => int.tryParse(_windowController.text.trim());

  Future<void> _previewWindow() async {
    final int? weeks = _typedWindow;
    final String? problem = ForecastWindowService.validate(weeks);
    if (problem != null) {
      _toast(problem, error: true);
      return;
    }
    setState(() => _previewBusy = true);
    try {
      final Map<String, dynamic> result = await _api.previewForecast(weeks!);
      if (!mounted) return;
      setState(() => _preview = result);
    } catch (error) {
      if (mounted) {
        _toast(
          userFacingError(error, action: 'preview the window'),
          error: true,
        );
      }
    } finally {
      if (mounted) setState(() => _previewBusy = false);
    }
  }

  Future<void> _saveWindow() async {
    final int? weeks = _typedWindow;
    final String? problem = ForecastWindowService.validate(weeks);
    if (problem != null) {
      _toast(problem, error: true);
      return;
    }
    final bool confirmed =
        await showDialog<bool>(
          context: context,
          builder: (BuildContext context) => AlertDialog(
            title: const Text('Set the live window?'),
            content: Text(
              'Every forecast run from now on reads the last $weeks weeks. '
              'Numbers already on screen do not change until the next run.',
            ),
            actions: <Widget>[
              TextButton(
                onPressed: () => Navigator.of(context).pop(false),
                child: const Text('Cancel'),
              ),
              FilledButton(
                onPressed: () => Navigator.of(context).pop(true),
                child: const Text('Save as live window'),
              ),
            ],
          ),
        ) ??
        false;
    if (!confirmed || !mounted) return;
    setState(() => _windowSaving = true);
    try {
      await _windowService.save(weeks: weeks!, actor: widget.currentUser);
      if (!mounted) return;
      setState(() => _savedWindowWeeks = weeks);
      _toast('Live window set to $weeks weeks. It applies from the next run.');
    } catch (error) {
      if (mounted) {
        _toast(userFacingError(error, action: 'save the window'), error: true);
      }
    } finally {
      if (mounted) setState(() => _windowSaving = false);
    }
  }

  Widget _windowCard() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final int? typed = _typedWindow;
    final List<String> warnings =
        typed != null && ForecastWindowService.validate(typed) == null
        ? ForecastWindowService.warnings(typed)
        : const <String>[];
    return Container(
      width: double.infinity,
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Padding(
        padding: const EdgeInsets.all(16),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              'Lookback window',
              style: Theme.of(context).textTheme.titleMedium,
            ),
            const SizedBox(height: 4),
            Text(
              'Live window: ${_savedWindowWeeks ?? ForecastWindowService.defaultWeeks} '
              'weeks${_savedWindowWeeks == null ? ' (default)' : ''}. '
              'A preview changes nothing; Save applies from the next run.',
              style: TextStyle(fontSize: 12.5, color: scheme.onSurfaceVariant),
            ),
            const SizedBox(height: 12),
            Wrap(
              spacing: 12,
              runSpacing: 12,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                SizedBox(
                  width: 160,
                  child: TextField(
                    controller: _windowController,
                    keyboardType: TextInputType.number,
                    inputFormatters: <TextInputFormatter>[
                      FilteringTextInputFormatter.digitsOnly,
                    ],
                    onChanged: (_) => setState(() {}),
                    decoration: const InputDecoration(
                      labelText: 'Weeks of history',
                      border: OutlineInputBorder(),
                      isDense: true,
                    ),
                  ),
                ),
                OutlinedButton(
                  onPressed: _previewBusy || !_serviceOnline
                      ? null
                      : _previewWindow,
                  child: Text(_previewBusy ? 'Previewing…' : 'Preview'),
                ),
                FilledButton(
                  onPressed: _windowSaving ? null : _saveWindow,
                  child: const Text('Save as live window'),
                ),
              ],
            ),
            for (final String warning in warnings) ...<Widget>[
              const SizedBox(height: 6),
              Text(
                warning,
                style: TextStyle(
                  fontSize: 12.5,
                  color: context.dso.warningText,
                ),
              ),
            ],
            if (_preview != null) ...<Widget>[
              const SizedBox(height: 16),
              _previewPanel(_preview!),
            ],
          ],
        ),
      ),
    );
  }

  Widget _previewPanel(Map<String, dynamic> result) {
    final Map<String, dynamic> preview = _mapOf(result['preview']);
    final Map<String, dynamic> baseline = _mapOf(result['baseline']);
    final int? previewWeeks = _optionalRunInt(
      _mapOf(preview['window'])['historyWeeks'],
    );
    final int? liveWeeks = _optionalRunInt(
      _mapOf(baseline['window'])['historyWeeks'],
    );
    final bool? previewEvaluated = _optionalBool(
      _mapOf(preview['window'])['windowEvaluated'],
    );
    Map<String, Map<String, dynamic>> byProduct(Map<String, dynamic> side) => {
      for (final Object? row
          in (_mapOf(side['forecast'])['rows'] as List<dynamic>? ??
              const <dynamic>[]))
        if (row is Map && _text(row['productId']).isNotEmpty)
          _text(row['productId']): Map<String, dynamic>.from(row),
    };
    final Map<String, Map<String, dynamic>> previewRows = byProduct(preview);
    final Map<String, Map<String, dynamic>> liveRows = byProduct(baseline);
    final List<_PreviewChange> changes = <_PreviewChange>[];
    for (final MapEntry<String, Map<String, dynamic>> entry
        in previewRows.entries) {
      final double? after = entry.value['point'] == null
          ? null
          : _predictionNumber(entry.value['point']);
      final Object? liveRow = liveRows[entry.key]?['point'];
      final double? before = liveRow == null
          ? null
          : _predictionNumber(liveRow);
      if (before == after) continue;
      changes.add(
        _PreviewChange(
          name: _text(entry.value['productName']).isEmpty
              ? entry.key
              : _text(entry.value['productName']),
          before: before,
          after: after,
        ),
      );
    }
    changes.sort((a, b) => b.size.compareTo(a.size));
    String cell(double? value) =>
        value == null ? 'No forecast' : value.toStringAsFixed(1);
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Semantics(
                label: 'PREVIEW — not saved',
                child: ExcludeSemantics(
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 8,
                      vertical: 3,
                    ),
                    decoration: BoxDecoration(
                      color: context.dso.warningSoft,
                      borderRadius: BorderRadius.circular(6),
                    ),
                    child: Text(
                      'PREVIEW — not saved',
                      style: TextStyle(
                        fontSize: 11.5,
                        fontWeight: FontWeight.w800,
                        color: context.dso.warningText,
                      ),
                    ),
                  ),
                ),
              ),
              const Spacer(),
              TextButton(
                onPressed: () => setState(() => _preview = null),
                child: const Text('Clear'),
              ),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            'Last $previewWeeks weeks'
            '${previewEvaluated == false ? ' (Not evaluated)' : ''} '
            'against the live ${liveWeeks ?? ForecastWindowService.defaultWeeks} '
            'weeks. ${changes.length} of ${previewRows.length} products change.',
            style: const TextStyle(fontSize: 12.5),
          ),
          const SizedBox(height: 8),
          for (final _PreviewChange change in changes.take(10))
            Semantics(
              label:
                  'Preview row ${change.name}: live ${cell(change.before)}, '
                  'preview ${cell(change.after)}',
              child: ExcludeSemantics(
                child: Padding(
                  padding: const EdgeInsets.symmetric(vertical: 2),
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          change.name,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(
                          cell(change.before),
                          textAlign: TextAlign.right,
                          style: const TextStyle(fontSize: 12.5),
                        ),
                      ),
                      SizedBox(
                        width: 90,
                        child: Text(
                          cell(change.after),
                          textAlign: TextAlign.right,
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ),
          if (changes.length > 10)
            Text(
              '${changes.length - 10} more products change.',
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Map<String, dynamic> _mapOf(Object? value) =>
      value is Map ? Map<String, dynamic>.from(value) : <String, dynamic>{};

  Widget? _catalogueNote() {
    if (!_catalogueVerificationRan) {
      return _cataloguePanel(
        icon: Icons.help_outline_rounded,
        title: 'Forecast rows are not catalogue-verified.',
        message:
            'The master product catalogue could not be read, so these saved rows '
            'were shown without checking them against it. Open Products to confirm '
            'the catalogue is reachable, then reload this page.',
      );
    }
    if (_catalogueExcludedCount <= 0) return null;
    final String samples = _catalogueExcludedSamples.isEmpty
        ? ''
        : ' Examples: ${_catalogueExcludedSamples.join(', ')}.';
    return _cataloguePanel(
      icon: Icons.filter_alt_off_outlined,
      title:
          '$_catalogueExcludedCount saved forecast row(s) belong to products '
          'that are no longer in the current product catalogue.',
      message:
          'These rows are older or test data that no current product matches, '
          'so they are left out of this view. Nothing was deleted.$samples '
          'They are replaced the next time the forecast is run.',
    );
  }

  Widget _cataloguePanel({
    required IconData icon,
    required String title,
    required String message,
  }) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.dso.warningSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: context.dso.warning.withValues(alpha: 0.4)),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 20, color: context.dso.warningText),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w800,
                    color: context.dso.warningText,
                  ),
                ),
                const SizedBox(height: 4),
                Text(
                  message,
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.5,
                    color: context.dso.warningText,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _forecastAccuracyCard() {
    return StreamBuilder<List<WeeklyAiSummary>>(
      stream: _accuracySummaries,
      builder: (BuildContext context, AsyncSnapshot<List<WeeklyAiSummary>> snapshot) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        if (snapshot.hasError) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Historical Adaptive weekly accuracy',
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      const SizedBox(height: 8),
                      Text(
                        'Error loading accuracy data. Check your permissions.',
                        style: TextStyle(
                          fontSize: 12,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                OutlinedButton.icon(
                  onPressed: () {
                    setState(() {
                      _accuracySummaries = _accuracyService.watchSummaries(
                        widget.currentUser,
                      );
                    });
                  },
                  icon: const Icon(Icons.refresh, size: 16),
                  label: const Text('Retry'),
                  style: OutlinedButton.styleFrom(
                    foregroundColor: scheme.onSurface,
                    side: BorderSide(color: scheme.outlineVariant),
                  ),
                ),
              ],
            ),
          );
        }

        final List<WeeklyAiSummary> rows =
            snapshot.data ?? const <WeeklyAiSummary>[];
        if (rows.isEmpty) {
          return Container(
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outlineVariant),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Historical Adaptive weekly accuracy',
                  style: TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: scheme.onSurface,
                  ),
                ),
                SizedBox(height: 8),
                Text(
                  'No evaluated forecasts yet.',
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          );
        }

        final DateTime? latestWeek = rows.first.weekStart;
        final List<WeeklyAiSummary> latest = rows
            .where((WeeklyAiSummary row) => _sameDay(row.weekStart, latestWeek))
            .toList(growable: false);
        final WeeklyAiRollup rollup = WeeklyAiRollup.fromSummaries(latest);

        return Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Historical Adaptive weekly accuracy',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 10),
              Wrap(
                spacing: 12,
                runSpacing: 12,
                children: <Widget>[
                  _accuracyMetricTile(
                    'MAE',
                    rollup.evaluatedForecastCount == 0
                        ? '—'
                        : rollup.meanAbsoluteError.toStringAsFixed(2),
                  ),
                  _accuracyMetricTile(
                    'MAPE',
                    rollup.meanAbsolutePercentageError == null
                        ? 'Not available'
                        : '${rollup.meanAbsolutePercentageError!.toStringAsFixed(1)}%',
                  ),
                  _accuracyMetricTile(
                    'Evaluated forecasts',
                    '${rollup.evaluatedForecastCount}',
                  ),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                'Latest evaluated week only'
                '${latestWeek == null ? '' : ', the week of ${readableForecastDate(latestWeek)}'}: '
                '${countLabel(rollup.evaluatedForecastCount, 'evaluated forecast')}. '
                'Trust & Impact combines every stored week, so its number differs.',
                style: TextStyle(
                  fontSize: 11,
                  color: scheme.onSurfaceVariant,
                  height: 1.4,
                ),
              ),
            ],
          ),
        );
      },
    );
  }

  Widget _accuracyMetricTile(String label, String value) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            value,
            style: TextStyle(
              fontSize: 16,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
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

  Widget _summaryCards(List<Map<String, dynamic>> rows) {
    final ForecastOperationalSummary summary =
        ForecastOperationalSummary.fromRows(rows);

    return Wrap(
      spacing: 12,
      runSpacing: 12,
      children: <Widget>[
        _metricCard(
          'Products in scope',
          '${summary.productCount}',
          Icons.inventory_2_outlined,
          _green,
        ),
        _metricCard(
          'Forecast rows',
          '${summary.rowCount}',
          Icons.table_rows_outlined,
          const Color(0xFF2563EB),
        ),
        if (summary.modelCount > 0)
          _metricCard(
            'Models in use',
            '${summary.modelCount}',
            Icons.show_chart_outlined,
            const Color(0xFF9333EA),
          ),
        _metricCard(
          'With an interval',
          '${summary.intervalCount}',
          Icons.straighten_outlined,
          const Color(0xFFEA580C),
        ),
        _metricCard(
          'Without a forecast',
          '${summary.insufficientHistoryCount}',
          Icons.history_toggle_off_outlined,
          context.dso.warningText,
        ),
        _metricCard(
          'With a forecast',
          '${summary.forecastCount}',
          Icons.trending_up_outlined,
          const Color(0xFF16A34A),
        ),
      ],
    );
  }

  Widget _metricCard(String title, String value, IconData icon, Color accent) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 200,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        children: <Widget>[
          CircleAvatar(
            radius: 18,
            backgroundColor: accent.withValues(alpha: 0.12),
            child: Icon(icon, size: 18, color: accent),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  value,
                  style: TextStyle(
                    fontSize: 20,
                    fontWeight: FontWeight.w800,
                    color: scheme.onSurface,
                  ),
                ),
                Text(
                  title,
                  style: TextStyle(
                    fontSize: 11.5,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }

  String _periodLine() {
    if (_periodStart.isEmpty &&
        _dataCutoff.isEmpty &&
        _setGeneratedAt.isEmpty) {
      return 'Run Forecast to build this week from the live order history.';
    }
    final List<String> parts = <String>[
      if (_periodStart.isNotEmpty) 'Week of $_periodStart',
      if (_dataCutoff.isNotEmpty) 'history to $_dataCutoff',
      if (_historyWeeks != null)
        'Based on the last $_historyWeeks weeks'
            '${_windowEvaluated == false ? ' (Not evaluated)' : ''}',
      if (_setGeneratedAt.isNotEmpty)
        'made ${readableForecastTimeText(_setGeneratedAt)}',
    ];
    return parts.join(' \u00b7 ');
  }

  Widget _filterBar() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Row(
      children: <Widget>[
        Text(
          'Show:',
          style: TextStyle(
            fontSize: 13,
            fontWeight: FontWeight.w600,
            color: scheme.onSurface,
          ),
        ),
        const SizedBox(width: 10),
        DropdownButton<String>(
          value: _statusFilter,
          underline: const SizedBox.shrink(),
          items: <DropdownMenuItem<String>>[
            const DropdownMenuItem<String>(
              value: 'all',
              child: Text('All catalogue products'),
            ),
            const DropdownMenuItem<String>(
              value: 'forecasted',
              child: Text('With a forecast'),
            ),
            const DropdownMenuItem<String>(
              value: 'insufficient_history',
              child: Text('Without a forecast'),
            ),
          ],
          onChanged: (String? value) =>
              setState(() => _statusFilter = value ?? 'all'),
        ),
      ],
    );
  }

  Widget _forecastTable(List<Map<String, dynamic>> rows) {
    if (rows.isEmpty) {
      return const Padding(
        padding: EdgeInsets.all(24),
        child: _EmptyState(
          icon: Icons.insights_outlined,
          title: 'No forecasts for this filter',
          subtitle: 'Choose another month or reload.',
        ),
      );
    }
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        border: Border.all(color: scheme.outlineVariant),
        borderRadius: BorderRadius.circular(14),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          _tableHeader(),
          const Divider(height: 1),
          for (int i = 0; i < rows.length; i++) ...<Widget>[
            _tableRow(rows[i], i.isEven),
            if (i != rows.length - 1) const Divider(height: 1),
          ],
        ],
      ),
    );
  }

  Widget _tableHeader() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle headerStyle = TextStyle(
      fontSize: 12,
      fontWeight: FontWeight.w800,
      color: scheme.onSurfaceVariant,
    );
    return Container(
      color: scheme.surfaceContainerHighest,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Row(
        children: <Widget>[
          Expanded(
            flex: 3,
            child: StickyColumnCell(
              background: scheme.surfaceContainerHighest,
              child: Text('PRODUCT', style: headerStyle),
            ),
          ),
          Expanded(
            flex: 7,
            child: ScrollsBehindStickyColumn(
              child: Row(
                children: <Widget>[
                  Expanded(child: Text('WEEK OF', style: headerStyle)),
                  Expanded(child: Text('EXPECTED', style: headerStyle)),
                  Expanded(child: Text('RANGE', style: headerStyle)),
                  Expanded(child: Text('STATUS', style: headerStyle)),
                  Expanded(child: Text('MODEL', style: headerStyle)),
                  Expanded(
                    flex: 2,
                    child: Text('EVIDENCE', style: headerStyle),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _tableRow(Map<String, dynamic> row, bool even) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool legacyForecast =
        _text(row['status']).isEmpty && forecastRowCountsAsForecast(row);
    final String status = legacyForecast ? 'ok' : _text(row['status']);
    final bool hasForecast = forecastRowHasUsablePoint(row);
    final String period = _text(
      row['periodStart'] ??
          row['period_start'] ??
          row['forecastMonth'] ??
          row['forecast_month'],
    );
    final String dataCutoff = _text(row['dataCutoff'] ?? row['data_cutoff']);
    final Object? point =
        row['point'] ??
        row['predictedQuantity'] ??
        row['predicted_quantity'] ??
        row['forecastQuantity'] ??
        row['forecast_quantity'];
    final Object? lower =
        row['lower'] ?? row['lowerQuantity'] ?? row['lower_quantity'];
    final Object? upper =
        row['upper'] ?? row['upperQuantity'] ?? row['upper_quantity'];
    final String model = _text(row['model'] ?? row['modelUsed']);
    final String demandClass = _text(row['demandClass']);
    final String reference = _text(
      row['referenceUnits'] ??
          row['reference_units'] ??
          row['recentMonthlyAverage'] ??
          row['recent_monthly_average'],
    );
    final int components = _predictionNumber(row['componentCount']).toInt();
    final int modelled = _predictionNumber(
      row['modelledComponentCount'],
    ).toInt();
    final Color rowColor = even
        ? scheme.surface
        : Color.alphaBlend(
            scheme.surfaceContainerHighest.withValues(alpha: 0.35),
            scheme.surface,
          );
    return Container(
      color: rowColor,
      padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Expanded(
                flex: 3,
                child: StickyColumnCell(
                  background: rowColor,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        _text(row['productName']),
                        style: TextStyle(
                          fontSize: 13.5,
                          fontWeight: FontWeight.w700,
                          color: scheme.onSurface,
                        ),
                      ),
                      Text(
                        _text(row['category']),
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ),
              Expanded(
                flex: 7,
                child: ScrollsBehindStickyColumn(
                  child: Row(
                    children: <Widget>[
                      Expanded(
                        child: Text(
                          period.isEmpty ? '—' : period,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          hasForecast
                              ? '${forecastUnitsLabel(point)} units'
                              : '—',
                          style: TextStyle(
                            fontSize: 13.5,
                            fontWeight: FontWeight.w800,
                            color: scheme.onSurface,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Text(
                          lower == null || upper == null
                              ? '—'
                              : '${forecastUnitsLabel(lower)}–'
                                    '${forecastUnitsLabel(upper)}',
                          style: TextStyle(
                            fontSize: 12.5,
                            color: scheme.onSurfaceVariant,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: _statusPill(
                            status == 'ok' && !hasForecast ? '' : status,
                          ),
                        ),
                      ),
                      Expanded(
                        child: Align(
                          alignment: Alignment.centerLeft,
                          child: status == 'not_generated'
                              ? const Text('—')
                              : _modelChip(model.isEmpty ? 'aggregate' : model),
                        ),
                      ),
                      Expanded(
                        flex: 2,
                        child: Text(
                          status == 'not_generated'
                              ? 'Run both forecasts to compare.'
                              : status == 'model_error'
                              ? 'Model fit failed'
                              : hasForecast
                              ? components == 0
                                    ? 'Saved forecast from the legacy pipeline'
                                    : '$modelled of $components outlet series forecast'
                              : (components == 0
                                    ? 'No orders in the window'
                                    : 'Observed only · $reference units/week'),
                          style: const TextStyle(
                            fontSize: 12.5,
                            fontWeight: FontWeight.w600,
                          ),
                        ),
                      ),
                    ],
                  ),
                ),
              ),
            ],
          ),
          if (demandClass.isNotEmpty ||
              reference.isNotEmpty ||
              dataCutoff.isNotEmpty)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Row(
                children: <Widget>[
                  if (demandClass.isNotEmpty) ...<Widget>[
                    _festivalChip(
                      demandClass == 'no_demand'
                          ? 'No demand observed'
                          : '$demandClass demand',
                    ),
                    const SizedBox(width: 8),
                  ],
                  Expanded(
                    child: Text(
                      status == 'not_generated'
                          ? 'Run both forecasts to compare.'
                          : status == 'model_error'
                          ? 'Model fit failed. Run both forecasts again.'
                          : status == 'stale'
                          ? 'This forecast is stale. It covers the week of '
                                '$period with data through $dataCutoff; refresh '
                                'forecasting before using its values.'
                          : hasForecast
                          ? 'Unconditional expected demand for the week of '
                                '$period from the selected model; the interval '
                                'is the observed one-step error of that model. '
                                '${dataCutoff.isEmpty ? '' : 'Data through $dataCutoff.'}'
                          : 'Not enough order history to forecast this '
                                'product; the observed average is $reference '
                                'units per week. '
                                '${dataCutoff.isEmpty ? '' : 'Data through $dataCutoff.'}',
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                        height: 1.4,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _runHistory() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Training run history',
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 10),
          AiFreshnessChip(
            hasData: _runs.isNotEmpty,
            timestamps: _runs
                .take(5)
                .map(
                  (Map<String, dynamic> row) =>
                      aiDataTimestamp(<String, dynamic>{
                        ...row,
                        'generatedAt':
                            row['generatedAt'] ??
                            row['createdAt'] ??
                            row['startedAt'],
                      }),
                ),
            hasMissingTimestamp: _runs
                .take(5)
                .any(
                  (Map<String, dynamic> row) =>
                      aiDataTimestamp(<String, dynamic>{
                        ...row,
                        'generatedAt':
                            row['generatedAt'] ??
                            row['createdAt'] ??
                            row['startedAt'],
                      }) ==
                      null,
                ),
          ),
          const SizedBox(height: 10),
          for (final Map<String, dynamic> run in _runs.take(5))
            Padding(
              padding: const EdgeInsets.only(bottom: 8),
              child: Row(
                children: <Widget>[
                  Icon(Icons.history, size: 16, color: scheme.onSurfaceVariant),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      '${_text(run['runId'])} • ${_text(run['periodStart'])} → ${_text(run['periodEnd'])} • '
                      '${_forecastRunSummary(run)} • '
                      '${_text(run['status'])}',
                      style: TextStyle(
                        fontSize: 12.5,
                        color: scheme.onSurfaceVariant,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  Widget _statusPill(String status) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color background;
    final Color foreground;
    final String label;
    switch (status) {
      case 'ok':
        background = context.dso.successSoft;
        foreground = context.dso.successText;
        label = 'Forecast';
      case 'insufficient_history':
        background = context.dso.warningSoft;
        foreground = context.dso.warningText;
        label = 'Insufficient history';
      case 'not_generated':
        background = scheme.surfaceContainerHighest;
        foreground = scheme.onSurfaceVariant;
        label = 'Not generated';
      case 'model_error':
        background = context.dso.dangerSoft;
        foreground = context.dso.dangerText;
        label = 'Model fit failed';
      case 'stale':
        background = context.dso.warningSoft;
        foreground = context.dso.warningText;
        label = 'Stale';
      default:
        background = scheme.surfaceContainerHighest;
        foreground = scheme.onSurfaceVariant;
        label = status.isEmpty ? '—' : status;
    }
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: foreground,
        ),
      ),
    );
  }

  Widget _modelChip(String model) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final String label = model == 'sarima'
        ? 'SARIMA'
        : (model.isEmpty ? 'aggregate' : model);
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 4),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: scheme.onSurfaceVariant,
        ),
      ),
    );
  }

  Widget _festivalChip(String label) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 3),
      decoration: BoxDecoration(
        color: context.dso.dangerSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w700,
          color: scheme.brightness == Brightness.dark
              ? const Color(0xFFFFB4D2)
              : const Color(0xFFBE123C),
        ),
      ),
    );
  }

  Widget _chip(String label) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: context.dso.successSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: context.dso.successText,
        ),
      ),
    );
  }

  String _sourceChipLabel() {
    if (_usingOfflineSnapshot) return _savedForecastLabel();
    if (!_source.startsWith(_savedForecastSource)) return _source;
    return _source.replaceFirst(_savedForecastSource, _savedForecastLabel());
  }

  String _savedForecastLabel() {
    DateTime? runAt;
    for (final Map<String, dynamic> row in _forecasts) {
      final DateTime? at = aiDataTimestamp(<String, dynamic>{
        'generatedAt':
            row['generatedAt'] ?? row['runCreatedAt'] ?? row['createdAt'],
      });
      if (at != null && (runAt == null || at.isAfter(runAt))) runAt = at;
    }
    runAt ??= _snapshotGeneratedAt;
    return runAt == null
        ? 'Saved forecast'
        : 'Saved forecast of ${_formatSnapshotDate(runAt)}';
  }

  String _text(Object? value) {
    if (value == null) return '';
    final String text = value.toString().trim();
    return text.toLowerCase() == 'null' ? '' : text;
  }

  String _formatSnapshotDate(DateTime value) {
    final DateTime local = value.toLocal();
    final String day = local.day.toString().padLeft(2, '0');
    final String month = local.month.toString().padLeft(2, '0');
    final String hour = local.hour.toString().padLeft(2, '0');
    final String minute = local.minute.toString().padLeft(2, '0');
    return '$day/$month/${local.year} $hour:$minute';
  }

  bool _sameDay(DateTime? left, DateTime? right) =>
      _dayKey(left) == _dayKey(right);

  String _dayKey(DateTime? value) =>
      value == null ? '' : '${value.year}-${value.month}-${value.day}';
}

class _RestockRecommendationsTab extends StatelessWidget {
  const _RestockRecommendationsTab({required this.rows});

  final List<Map<String, dynamic>> rows;

  @override
  Widget build(BuildContext context) {
    if (rows.isEmpty) {
      return _EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No saved forecast found',
        subtitle: 'No forecasts have been published for this company yet.',
      );
    }

    final List<_RestockRecommendation> recommendations =
        rows
            .map(_RestockRecommendation.fromForecast)
            .where((_RestockRecommendation item) => item.shouldShow)
            .toList(growable: false)
          ..sort(
            (_RestockRecommendation a, _RestockRecommendation b) =>
                b.changePercent.compareTo(a.changePercent),
          );

    if (recommendations.isEmpty) {
      return const _EmptyState(
        icon: Icons.inventory_2_outlined,
        title: 'No restock recommendation for this filter',
        subtitle:
            'Forecast rows either need more order history or do not currently indicate a stock action.',
      );
    }

    return ListView.separated(
      padding: EdgeInsets.zero,
      itemCount: recommendations.length,
      separatorBuilder: (_, _) => const SizedBox(height: 10),
      itemBuilder: (BuildContext context, int index) {
        final ColorScheme scheme = Theme.of(context).colorScheme;
        final _RestockRecommendation item = recommendations[index];
        return Container(
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Expanded(
                    child: Text(
                      item.productName,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: TextStyle(
                        fontSize: 14.5,
                        fontWeight: FontWeight.w900,
                        color: scheme.onSurface,
                      ),
                    ),
                  ),
                  _recommendationConfidencePill(context, item.confidence),
                ],
              ),
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  _recommendationMetric(
                    context,
                    'Forecast month',
                    item.forecastMonth,
                  ),
                  _recommendationMetric(
                    context,
                    'Forecast qty',
                    item.forecastQuantityText,
                  ),
                  _recommendationMetric(
                    context,
                    'Historical avg',
                    item.averageText,
                  ),
                  _recommendationMetric(context, 'Change', item.changeText),
                  _recommendationMetric(context, 'Last run', item.lastRunText),
                ],
              ),
              const SizedBox(height: 10),
              Text(
                item.recommendedAdjustment,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w800,
                  color: scheme.onSurface,
                ),
              ),
              const SizedBox(height: 4),
              Text(
                item.reason,
                style: TextStyle(
                  fontSize: 12.5,
                  height: 1.45,
                  color: scheme.onSurfaceVariant,
                ),
              ),
            ],
          ),
        );
      },
    );
  }
}

class _ExcelImportTab extends StatelessWidget {
  const _ExcelImportTab({
    required this.serviceOnline,
    required this.busy,
    required this.busyLabel,
    required this.onImportExcel,
    required this.onRunForecast,
  });

  final bool serviceOnline;
  final bool busy;
  final String busyLabel;
  final VoidCallback? onImportExcel;
  final VoidCallback? onRunForecast;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        Container(
          padding: const EdgeInsets.all(16),
          decoration: BoxDecoration(
            color: scheme.surface,
            borderRadius: BorderRadius.circular(14),
            border: Border.all(color: scheme.outlineVariant),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Row(
                children: <Widget>[
                  Icon(
                    serviceOnline
                        ? Icons.cloud_done_outlined
                        : Icons.cloud_off_outlined,
                    color: serviceOnline ? _green : context.dso.dangerText,
                  ),
                  const SizedBox(width: 10),
                  Text(
                    serviceOnline
                        ? 'Forecasting service online'
                        : 'Forecasting service offline',
                    style: TextStyle(
                      fontSize: 15,
                      fontWeight: FontWeight.w900,
                      color: scheme.onSurface,
                    ),
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Wrap(
                spacing: 10,
                runSpacing: 10,
                children: <Widget>[
                  OutlinedButton.icon(
                    onPressed: onImportExcel,
                    icon: const Icon(Icons.upload_file_outlined, size: 16),
                    label: const Text('Import Excel'),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: scheme.onSurface,
                      side: BorderSide(color: scheme.outlineVariant),
                    ),
                  ),
                  FilledButton.icon(
                    onPressed: onRunForecast,
                    icon: busy
                        ? const SizedBox(
                            width: 14,
                            height: 14,
                            child: CircularProgressIndicator(
                              strokeWidth: 2,
                              color: Colors.white,
                            ),
                          )
                        : const Icon(Icons.play_arrow_rounded, size: 18),
                    label: Text(
                      busy && busyLabel.isNotEmpty
                          ? busyLabel
                          : 'Run both forecasts',
                    ),
                    style: FilledButton.styleFrom(backgroundColor: _green),
                  ),
                ],
              ),
              if (!serviceOnline) ...<Widget>[
                const SizedBox(height: 12),
                Text(
                  'The forecasting service is not available right now. Import and Run Forecast are disabled until it is back.',
                  style: TextStyle(
                    fontSize: 12.5,
                    height: 1.45,
                    color: context.dso.warningText,
                  ),
                ),
              ],
            ],
          ),
        ),
      ],
    );
  }
}

class _RestockRecommendation {
  _RestockRecommendation({
    required this.productName,
    required this.forecastMonth,
    required this.forecastQuantity,
    required this.historicalAverage,
    required this.changePercent,
    required this.recommendedAdjustment,
    required this.reason,
    required this.confidence,
    required this.lastRun,
    required this.shouldShow,
  });

  final String productName;
  final String forecastMonth;
  final double forecastQuantity;
  final double historicalAverage;
  final double changePercent;
  final String recommendedAdjustment;
  final String reason;
  final String confidence;
  final DateTime? lastRun;
  final bool shouldShow;

  String get forecastQuantityText =>
      forecastQuantity <= 0 ? '-' : forecastQuantity.toStringAsFixed(0);
  String get averageText =>
      historicalAverage <= 0 ? '-' : historicalAverage.toStringAsFixed(0);
  String get changeText => changePercent == 0
      ? '-'
      : '${changePercent >= 0 ? '+' : ''}${changePercent.toStringAsFixed(0)}%';
  String get lastRunText => lastRun == null
      ? '-'
      : '${lastRun!.year}-${_two(lastRun!.month)}-${_two(lastRun!.day)}';

  factory _RestockRecommendation.fromForecast(Map<String, dynamic> row) {
    final String product = _predictionText(
      row['productName'] ??
          row['product_name'] ??
          row['productId'] ??
          row['product_id'],
      fallback: 'Product',
    );
    final ForecastRestockSignal signal = forecastRestockSignal(row);
    final double forecast = signal.forecastQuantity;
    final double average = signal.referenceQuantity;
    final double change = signal.changePercent;
    final String action = signal.action;
    final String reason = _predictionText(row['reason']).isNotEmpty
        ? _predictionText(row['reason'])
        : average <= 0 && forecast > 0
        ? 'The forecast identifies a new demand signal for this product.'
        : change > 0
        ? 'Forecast demand is ${change.toStringAsFixed(0)}% higher than the reference average.'
        : 'Saved forecast recommends review for this product.';
    final String adjustment = action.isEmpty
        ? average <= 0 && forecast > 0
              ? 'Plan initial stock toward ${forecast.toStringAsFixed(0)} units for $product.'
              : 'Review procurement quantity for $product.'
        : action;

    return _RestockRecommendation(
      productName: product,
      forecastMonth: _predictionText(
        row['forecastMonth'] ??
            row['forecast_month'] ??
            row['month'] ??
            row['periodStart'] ??
            row['period_start'],
        fallback: '-',
      ),
      forecastQuantity: forecast,
      historicalAverage: average,
      changePercent: change,
      recommendedAdjustment: adjustment,
      reason: reason,
      confidence: _predictionText(row['confidence'], fallback: 'medium'),
      lastRun: _predictionDate(
        row['runCreatedAt'] ??
            row['run_created_at'] ??
            row['createdAt'] ??
            row['created_at'] ??
            row['updatedAt'] ??
            row['generatedAt'] ??
            row['generated_at'],
      ),
      shouldShow: signal.shouldShow,
    );
  }
}

Widget _recommendationMetric(BuildContext context, String label, String value) {
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
        fontSize: 11.5,
        color: scheme.onSurfaceVariant,
        fontWeight: FontWeight.w700,
      ),
    ),
  );
}

Widget _recommendationConfidencePill(BuildContext context, String confidence) {
  final String normalized = confidence.toLowerCase();
  final Color bg = normalized == 'high'
      ? context.dso.successSoft
      : normalized == 'low'
      ? context.dso.warningSoft
      : context.dso.infoSoft;
  final Color fg = normalized == 'high'
      ? context.dso.successText
      : normalized == 'low'
      ? context.dso.warningText
      : context.dso.infoText;
  return Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(
      'Confidence: ${confidence.isEmpty ? 'Medium' : confidence}',
      style: TextStyle(fontSize: 11.5, fontWeight: FontWeight.w800, color: fg),
    ),
  );
}

String _predictionText(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  return text.isEmpty || text.toLowerCase() == 'null' ? fallback : text;
}

String _forecastRunSummary(Map<String, dynamic> run) {
  final int? forecasted = _optionalRunInt(run['forecastedProducts']);
  final int? insufficient = _optionalRunInt(run['insufficientHistoryProducts']);
  if (forecasted != null || insufficient != null) {
    return '${forecasted ?? 0} forecasted / ${insufficient ?? 0} insufficient history';
  }

  return 'Earlier run (no product counts)';
}

int? _optionalRunInt(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toInt();
  return int.tryParse(value.toString().trim());
}

bool? _optionalBool(Object? value) => value is bool ? value : null;

class _PreviewChange {
  const _PreviewChange({
    required this.name,
    required this.before,
    required this.after,
  });

  final String name;
  final double? before;
  final double? after;

  double get size => before == null || after == null
      ? double.infinity
      : (after! - before!).abs();
}

double _predictionNumber(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', '').trim()) ?? 0;
}

DateTime? _predictionDate(Object? value) {
  if (value == null) return null;
  if (value is DateTime) return value;
  try {
    final dynamic dynamicValue = value;
    final Object? date = dynamicValue.toDate();
    if (date is DateTime) return date;
  } catch (_) {}
  return DateTime.tryParse(value.toString().trim());
}

String _two(int value) => value.toString().padLeft(2, '0');

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
    return ScootEmptyState(title: title, message: subtitle);
  }
}
