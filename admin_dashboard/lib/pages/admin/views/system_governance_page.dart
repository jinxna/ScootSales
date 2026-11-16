import 'package:cloud_firestore/cloud_firestore.dart' show WriteBatch;
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:uuid/uuid.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../repositories/user_management_repository.dart';
import '../../../services/platform_api_client.dart';
import '../../../utils/order_data_utils.dart' show parseFlexibleDate;
import '../../../utils/user_facing_error.dart';
import 'governance_parts.dart';

class SystemGovernancePage extends StatefulWidget {
  const SystemGovernancePage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<SystemGovernancePage> createState() => _SystemGovernancePageState();
}

class _SystemGovernancePageState extends State<SystemGovernancePage> {
  final CmsRepository _repository = CmsRepository();
  final UserManagementRepository _userRepository = UserManagementRepository();
  final TextEditingController _gpsStopController = TextEditingController(
    text: '18:00',
  );
  final TextEditingController _gpsIntervalController = TextEditingController(
    text: '10',
  );

  late Stream<List<Map<String, dynamic>>> _adminStream = _repository
      .watchCollection('users');

  bool _saving = false;
  bool _backfilling = false;
  String _message = '';
  String _csvPreview = '';
  BackfillReport? _lastBackfill;
  String _purgeCollection = purgeableCollections.first;
  bool _loadFailed = false;
  bool _purgeLoading = true;
  bool _purgeBusy = false;
  int _retentionMonths = CmsRepository.orderPurgeDefaultRetentionMonths;
  bool _purgeEnabled = false;
  Map<String, dynamic> _purgeSettings = <String, dynamic>{};

  @override
  void initState() {
    super.initState();
    if (_canManageOrderPurge) {
      _loadOrderPurgeSchedule(runDue: _canUseDeveloperControls);
    }
  }

  @override
  void dispose() {
    _gpsStopController.dispose();
    _gpsIntervalController.dispose();
    super.dispose();
  }

  bool get _canUseDeveloperControls => widget.currentUser.isDeveloper;
  bool get _canManageOrderPurge =>
      widget.currentUser.isActive && widget.currentUser.isAdmin;

  void _applyOrderPurgeSettings(Map<String, dynamic> settings) {
    _purgeSettings = settings;
    _retentionMonths = CmsRepository.orderPurgeRetentionMonths(settings);
    _purgeEnabled = settings['enabled'] == true;
  }

  Future<void> _loadOrderPurgeSchedule({bool runDue = false}) async {
    try {
      if (runDue) {
        try {
          final OrderPurgeResult? result = await _repository.runDueOrderPurge(
            currentUser: widget.currentUser,
          );
          if (mounted && result != null) {
            setState(() => _message = _orderPurgeResultText(result));
          }
        } catch (error) {
          if (mounted) {
            setState(
              () => _message = userFacingError(
                error,
                action: 'run the due order purge',
              ),
            );
          }
        }
      }
      final Map<String, dynamic> settings = await _repository
          .getOrderPurgeSettings();
      if (mounted) {
        setState(() {
          _loadFailed = false;
          _applyOrderPurgeSettings(settings);
        });
      }
    } catch (error) {
      if (mounted) setState(() => _loadFailed = true);
    } finally {
      if (mounted) setState(() => _purgeLoading = false);
    }
  }

  Future<void> _saveOrderPurgeSchedule() async {
    if (!_canManageOrderPurge || _purgeBusy || _purgeLoading) return;
    setState(() => _purgeBusy = true);
    try {
      await _repository.saveOrderPurgeSettings(
        retentionMonths: _retentionMonths,
        enabled: _purgeEnabled,
        currentUser: widget.currentUser,
      );
      await _loadOrderPurgeSchedule();
      if (mounted) {
        setState(() => _message = 'Order retention saved.');
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _message = userFacingError(
            error,
            action: 'save the purge schedule',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _purgeBusy = false);
    }
  }

  Future<void> _runOrderPurgeNow() async {
    if (!_canUseDeveloperControls || _purgeBusy || _purgeLoading) return;
    setState(() => _purgeBusy = true);
    try {
      final OrderPurgeSelection selection = await _repository.prepareOrderPurge(
        currentUser: widget.currentUser,
      );
      if (!mounted) return;
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext context) => AlertDialog(
          title: const Text('Confirm order purge'),
          content: Text(
            '${selection.count} final orders older than ${_purgeDateLabel(selection.cutoff)} '
            'will be exported and removed. Pending orders stay. '
            'Changed orders and orders too large to back up will be kept.',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.pop(context, true),
              child: const Text('Confirm purge'),
            ),
          ],
        ),
      );
      if (confirmed != true || !mounted) return;
      final OrderPurgeResult? result = await _repository.runOrderPurge(
        currentUser: widget.currentUser,
        selection: selection,
      );
      await _loadOrderPurgeSchedule();
      if (mounted && result != null) {
        setState(() => _message = _orderPurgeResultText(result));
      }
    } catch (error) {
      await _loadOrderPurgeSchedule();
      if (mounted) {
        setState(
          () => _message = userFacingError(
            error,
            action: 'purge old final orders',
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _purgeBusy = false);
    }
  }

  static String _orderPurgeResultText(OrderPurgeResult result) =>
      'Order purge removed ${result.removed} orders. '
      '${result.skipped} changed, missing, or oversized orders were kept.';

  static String _purgeDateLabel(DateTime date) =>
      '${date.toUtc().add(const Duration(hours: 8)).toIso8601String().replaceFirst('T', ' ').replaceFirst('Z', '')} MYT';

  Future<void> _saveGpsPolicy() async {
    if (!_canUseDeveloperControls) return;
    setState(() => _saving = true);
    try {
      await _repository.saveSystemPolicy(<String, dynamic>{
        'gpsStopTime': _gpsStopController.text.trim(),
        'gpsTrackingIntervalMinutes':
            int.tryParse(_gpsIntervalController.text.trim()) ?? 10,
        'dailyLocationWipeTime': '00:00',
        'timezone': 'Asia/Kuala_Lumpur',
        'stopTrackingOnLogout': true,
        'markCompletedRetailerLocations': true,
        'updatedBy': widget.currentUser.docId,
      });
      setState(() => _message = 'Tracking times saved.');
    } catch (error) {
      setState(
        () => _message = userFacingError(error, action: 'save the GPS policy'),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<bool> _typedConfirm({
    required String title,
    required String phrase,
    required String actionLabel,
  }) async {
    if (!mounted) return false;
    final TextEditingController typed = TextEditingController();
    final bool? ok = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setLocal) => AlertDialog(
          title: Text(title),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text('Type $phrase to confirm. A CSV copy is saved first.'),
              const SizedBox(height: 12),
              TextField(
                controller: typed,
                autofocus: true,
                onChanged: (_) => setLocal(() {}),
                decoration: const InputDecoration(labelText: 'Name'),
              ),
            ],
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(context, false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: typed.text.trim() == phrase
                  ? () => Navigator.pop(context, true)
                  : null,
              child: Text(actionLabel),
            ),
          ],
        ),
      ),
    );
    typed.dispose();
    return ok == true;
  }

  Future<void> _wipeLocations() async {
    if (!_canUseDeveloperControls) return;
    if (!await _typedConfirm(
      title: 'Wipe live locations?',
      phrase: 'live_tracking',
      actionLabel: 'Export and wipe',
    )) {
      return;
    }
    setState(() => _saving = true);
    try {
      await _repository.wipeSalespersonLiveLocations(
        actor: widget.currentUser.docId,
      );
      setState(
        () => _message = 'Live location collections were exported and wiped.',
      );
    } catch (error) {
      setState(
        () => _message = userFacingError(error, action: 'wipe live locations'),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _purgeWithExport() async {
    if (!_canUseDeveloperControls) return;
    final String collection = _purgeCollection;
    if (!await _typedConfirm(
      title: 'Purge $collection?',
      phrase: collection,
      actionLabel: 'Export and purge',
    )) {
      return;
    }
    setState(() {
      _saving = true;
      _csvPreview = '';
    });
    try {
      final String csv = await _repository.purgeCollectionWithCsvExport(
        collectionName: collection,
        actor: widget.currentUser.docId,
      );
      setState(() {
        _csvPreview = csv.length > 4000
            ? '${csv.substring(0, 4000)}\n... CSV shortened in preview ...'
            : csv;
        _message = '$collection was exported to purge_exports and purged.';
      });
    } catch (error) {
      setState(
        () => _message = userFacingError(error, action: 'purge $collection'),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  Future<void> _runOrderBackfill() async {
    if (!_canUseDeveloperControls) return;
    setState(() {
      _backfilling = true;
      _message = '';
    });
    try {
      final BackfillReport report = await _repository
          .backfillOrderSalesmanNames(actor: widget.currentUser.docId);
      setState(() {
        _lastBackfill = report;
        _message = report.summary;
      });
    } catch (error) {
      setState(
        () => _message = userFacingError(error, action: 'run the backfill'),
      );
    } finally {
      if (mounted) setState(() => _backfilling = false);
    }
  }

  Future<void> _toggleAdmin(Map<String, dynamic> user, bool enabled) async {
    if (!_canUseDeveloperControls) return;
    final String docId = _text(user['docId']);
    if (docId.isEmpty) return;
    try {
      final String uid = _text(user['uid']);
      if (uid.isEmpty) {
        throw StateError('This admin has no sign-in account yet.');
      }
      final PlatformApiClient api = PlatformApiClient();
      if (enabled) {
        await api.reactivateAccount(uid, idempotencyKey: const Uuid().v4());
      } else {
        await api.revokeAccount(uid);
      }
      final WriteBatch batch = _userRepository.createBatch();
      _userRepository.queueUserProfile(batch, docId, <String, dynamic>{
        'adminEnabled': enabled,
      });
      await _userRepository.commit(batch);
    } catch (error) {
      if (!mounted) return;
      setState(
        () => _message = userFacingError(
          error,
          action: enabled ? 'enable the admin' : 'disable the admin',
        ),
      );
    }
  }

  List<AdminAccessRow> _adminRows(List<Map<String, dynamic>> users) {
    final List<AdminAccessRow> rows = <AdminAccessRow>[];
    for (final Map<String, dynamic> user in users) {
      final String role = _text(
        user['role'] ?? user['user_group'],
      ).toLowerCase();
      if (!role.contains('admin') || role.contains('developer')) continue;
      final String name = _text(
        user['name'] ?? user['displayName'] ?? user['email'],
      );
      rows.add(
        AdminAccessRow(
          docId: _text(user['docId']),
          name: name.isEmpty ? 'Admin' : name,
          email: _text(user['email']),
          enabled:
              _text(user['status']).toLowerCase() != 'suspended' &&
              user['adminEnabled'] != false,
          raw: user,
        ),
      );
    }
    return rows;
  }

  Widget _adminAccess() {
    return StreamBuilder<List<Map<String, dynamic>>>(
      stream: _adminStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
          ) {
            final ScootLoadPhase phase = snapshot.hasError
                ? ScootLoadPhase.error
                : snapshot.hasData
                ? ScootLoadPhase.ready
                : ScootLoadPhase.loading;
            return AdminAccessCard(
              phase: phase,
              rows: _adminRows(snapshot.data ?? <Map<String, dynamic>>[]),
              canChange: _canUseDeveloperControls,
              onToggle: (AdminAccessRow row, bool enabled) =>
                  _toggleAdmin(row.raw, enabled),
              onRetry: () => setState(
                () => _adminStream = _repository.watchCollection('users'),
              ),
            );
          },
    );
  }

  Widget _locationTracking() {
    final ScootColors c = ScootColors.of(context);
    return ScootCard(
      title: 'Location tracking',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 16,
            runSpacing: 12,
            children: <Widget>[
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _gpsStopController,
                  decoration: const InputDecoration(
                    labelText: 'Stop tracking at',
                    helperText: 'Malaysia time, for example 18:00',
                  ),
                ),
              ),
              SizedBox(
                width: 200,
                child: TextField(
                  controller: _gpsIntervalController,
                  decoration: const InputDecoration(
                    labelText: 'Record every',
                    helperText: 'Minutes',
                  ),
                ),
              ),
            ],
          ),
          const SizedBox(height: 14),
          Text(
            'Live positions are wiped every night at 00:00. The position saved with an order is kept for 1 year. All other location data is deleted after 30 days.',
            style: ScootType.body.copyWith(color: c.muted),
          ),
          const SizedBox(height: 14),
          FilledButton(
            onPressed: _saving ? null : _saveGpsPolicy,
            child: const Text('Save'),
          ),
        ],
      ),
    );
  }

  Widget _dataRepair() {
    final ScootColors c = ScootColors.of(context);
    final BackfillReport? report = _lastBackfill;
    return ScootCard(
      title: 'Data repair',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Fill missing salesperson on old orders',
            style: ScootType.bodyStrong.copyWith(color: c.ink),
          ),
          const SizedBox(height: 4),
          Text(
            'Matches old orders to users by code. Safe to run again.',
            style: ScootType.body.copyWith(color: c.muted),
          ),
          if (report != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              'Last run: ${report.summary}',
              style: ScootType.small.copyWith(color: c.muted),
            ),
          ],
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: _backfilling ? null : _runOrderBackfill,
            child: Text(_backfilling ? 'Working…' : 'Run'),
          ),
        ],
      ),
    );
  }

  void _retrySchedule() {
    setState(() => _purgeLoading = true);
    _loadOrderPurgeSchedule();
  }

  @override
  Widget build(BuildContext context) {
    if (!_canManageOrderPurge) {
      return const Align(
        alignment: Alignment.topLeft,
        child: ScootNotice(
          tone: ScootTone.neutral,
          icon: ScootIcons.lock,
          title: 'Not an administrator',
          message: 'This account cannot use the protected system controls.',
        ),
      );
    }
    final DateTime? lastRun = parseFlexibleDate(_purgeSettings['lastRunAt']);
    final Widget retention = _purgeLoading
        ? GovernanceLoading(onRetry: _retrySchedule)
        : _loadFailed
        ? GovernanceLoadFailed(onRetry: _retrySchedule)
        : OrderRetentionCard(
            retentionMonths: _retentionMonths,
            enabled: _purgeEnabled,
            busy: _purgeBusy,
            lastRun: lastRun == null ? 'Never' : _purgeDateLabel(lastRun),
            removed: (_purgeSettings['lastRunCount'] as num? ?? 0).toInt(),
            keptCount: (_purgeSettings['lastRunSkippedCount'] as num? ?? 0)
                .toInt(),
            lastRunFailed: _purgeSettings['lastRunStatus'] == 'failed',
            canPurge: _canUseDeveloperControls,
            onMonths: (int value) => setState(() => _retentionMonths = value),
            onEnabled: (bool value) => setState(() => _purgeEnabled = value),
            onSave: _saveOrderPurgeSchedule,
            onRunNow: _runOrderPurgeNow,
          );
    return SingleChildScrollView(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (_message.isNotEmpty) ...<Widget>[
            ScootNotice(
              tone: ScootTone.info,
              message: _message,
              liveRegion: true,
              onDismiss: () => setState(() => _message = ''),
            ),
            const SizedBox(height: 16),
          ],
          retention,
          if (_canUseDeveloperControls) ...<Widget>[
            const SizedBox(height: 16),
            _adminAccess(),
            const SizedBox(height: 16),
            _locationTracking(),
            const SizedBox(height: 16),
            _dataRepair(),
            const SizedBox(height: 16),
            DangerZoneCard(
              busy: _saving,
              collection: _purgeCollection,
              csvPreview: _csvPreview,
              onCollection: (String value) =>
                  setState(() => _purgeCollection = value),
              onWipeLocations: _wipeLocations,
              onPurge: _purgeWithExport,
            ),
          ],
        ],
      ),
    );
  }

  static String _text(Object? value) {
    if (value == null) return '';
    final String text = value.toString().trim();
    return text.toLowerCase() == 'null' ? '' : text;
  }
}
