import 'package:flutter/material.dart';

import '../models/user_profile.dart';
import '../repositories/admin_setup_checklist_repository.dart';
import '../services/forecast_snapshot_storage.dart';
import 'package:scoot_design/scoot_design.dart';
import '../utils/admin_setup_checklist_state.dart';

class AdminSetupChecklist extends StatefulWidget {
  const AdminSetupChecklist({
    super.key,
    required this.currentUser,
    required this.onNavigate,
    this.loadCounts,
    this.repository,
    this.storage,
  });

  static String dismissalStorageKeyFor(String uid) =>
      'fypa.admin_setup_checklist.dismissed.v1.$uid';

  final UserProfile currentUser;
  final ValueChanged<String> onNavigate;
  final Future<AdminSetupChecklistCounts> Function()? loadCounts;
  final AdminSetupChecklistRepository? repository;
  final ForecastSnapshotStorage? storage;

  @override
  State<AdminSetupChecklist> createState() => _AdminSetupChecklistState();
}

const int _collapsedOpenSteps = 3;

class _AdminSetupChecklistState extends State<AdminSetupChecklist> {
  late final ForecastSnapshotStorage _storage =
      widget.storage ?? createForecastSnapshotStorage();
  AdminSetupChecklistCounts? _counts;
  bool _loading = false;
  bool _dismissed = false;
  bool _expanded = false;
  int _loadGeneration = 0;

  String get _userKey {
    final String? uid = widget.currentUser.uid?.trim();
    return AdminSetupChecklist.dismissalStorageKeyFor(
      uid == null || uid.isEmpty ? widget.currentUser.docId : uid,
    );
  }

  @override
  void initState() {
    super.initState();
    if (!widget.currentUser.isAdmin) return;
    _readDismissal();
    if (!_dismissed) _refresh();
  }

  @override
  void didUpdateWidget(covariant AdminSetupChecklist oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_identity(oldWidget.currentUser) == _identity(widget.currentUser)) {
      return;
    }
    _loadGeneration++;
    _counts = null;
    _loading = false;
    _dismissed = false;
    _expanded = false;
    if (!widget.currentUser.isAdmin) return;
    _readDismissal();
    if (!_dismissed) _refresh();
  }

  String _identity(UserProfile user) {
    final String? uid = user.uid?.trim();
    return uid == null || uid.isEmpty ? user.docId : uid;
  }

  void _readDismissal() {
    try {
      _dismissed = _storage.read(_userKey) == 'true';
    } catch (_) {}
  }

  Future<void> _refresh() async {
    final int generation = ++_loadGeneration;
    setState(() => _loading = true);
    try {
      final AdminSetupChecklistCounts counts = widget.loadCounts != null
          ? await widget.loadCounts!()
          : await (widget.repository ?? AdminSetupChecklistRepository())
                .loadCounts();
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _counts = counts;
        _loading = false;
      });
    } catch (_) {
      if (!mounted || generation != _loadGeneration) return;
      setState(() {
        _counts = const AdminSetupChecklistCounts(
          branches: null,
          activeSupervisors: null,
          activeSalespeopleWithBranch: null,
          supervisorsWithAssignedSalespeople: null,
          nonRetiredRetailers: null,
          retailersAssignedToValidSalespeople: null,
          visibleCategorizedProducts: null,
          scoreSheetSettings: null,
          publishedRoutes: null,
          aiRuns: null,
        );
        _loading = false;
      });
    }
  }

  void _dismiss() {
    try {
      _storage.write(_userKey, 'true');
    } catch (_) {}
    setState(() => _dismissed = true);
  }

  void _restore() {
    try {
      _storage.remove(_userKey);
    } catch (_) {}
    setState(() => _dismissed = false);
    _refresh();
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.currentUser.isAdmin) {
      return const SizedBox.shrink();
    }
    if (_dismissed) {
      return Align(
        alignment: Alignment.centerLeft,
        child: TextButton(
          onPressed: _restore,
          child: const Text('Show setup checklist'),
        ),
      );
    }
    final List<AdminSetupChecklistStepState> steps = _counts == null
        ? const <AdminSetupChecklistStepState>[]
        : adminSetupChecklistSteps(_counts!);
    final bool complete =
        _counts != null && adminSetupChecklistRequiredStepsComplete(_counts!);
    final ColorScheme colors = Theme.of(context).colorScheme;

    if (_loading && _counts == null) {
      return Card(
        child: Padding(
          padding: const EdgeInsets.all(18),
          child: Row(
            children: <Widget>[
              const SizedBox(
                width: 18,
                height: 18,
                child: CircularProgressIndicator(strokeWidth: 2),
              ),
              const SizedBox(width: 12),
              Text(
                'Checking setup…',
                style: TextStyle(color: colors.onSurface),
              ),
            ],
          ),
        ),
      );
    }

    if (complete) {
      return Semantics(
        label: 'Setup complete',
        child: Card(
          child: Padding(
            padding: const EdgeInsets.fromLTRB(16, 4, 8, 4),
            child: Row(
              children: <Widget>[
                Icon(Icons.check_circle_outline, color: colors.primary),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    'Setup complete ✓',
                    style: TextStyle(
                      color: colors.onSurface,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
                IconButton(
                  tooltip: 'Dismiss setup checklist',
                  onPressed: _dismiss,
                  icon: const Icon(Icons.close),
                ),
              ],
            ),
          ),
        ),
      );
    }

    final ScootColors sc = ScootColors.of(context);
    final List<AdminSetupChecklistStepState> completed = steps
        .where((s) => s.status == SetupChecklistStepStatus.complete)
        .toList();
    final List<AdminSetupChecklistStepState> open = steps
        .where((s) => s.status != SetupChecklistStepStatus.complete)
        .toList();
    final List<AdminSetupChecklistStepState> visible = _expanded
        ? steps
        : open.take(_collapsedOpenSteps).toList();
    final int hiddenOpen = open.length - _collapsedOpenSteps;

    return ScootCard(
      padding: const EdgeInsets.fromLTRB(20, 12, 20, 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
            alignment: WrapAlignment.spaceBetween,
            crossAxisAlignment: WrapCrossAlignment.center,
            runSpacing: 4,
            children: <Widget>[
              Wrap(
                spacing: 10,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  Container(
                    width: 32,
                    height: 32,
                    decoration: BoxDecoration(
                      color: sc.brandTint,
                      borderRadius: BorderRadius.circular(8),
                    ),
                    child: Icon(ScootIcons.play, size: 16, color: sc.brandText),
                  ),
                  Semantics(
                    header: true,
                    child: Text(
                      'Get set up',
                      maxLines: 1,
                      softWrap: false,
                      style: ScootType.section.copyWith(color: sc.ink),
                    ),
                  ),
                  Text(
                    '${completed.length} of ${steps.length} done',
                    maxLines: 1,
                    softWrap: false,
                    style: ScootType.caption.copyWith(color: sc.muted),
                  ),
                  if (steps.isNotEmpty)
                    SizedBox(
                      width: 90,
                      child: ClipRRect(
                        borderRadius: BorderRadius.circular(999),
                        child: LinearProgressIndicator(
                          value: completed.length / steps.length,
                          minHeight: 4,
                          color: sc.brand,
                          backgroundColor: sc.hair,
                        ),
                      ),
                    ),
                ],
              ),
              Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  if (completed.isNotEmpty && !_expanded)
                    OutlinedButton(
                      onPressed: () => setState(() => _expanded = true),
                      child: Text('Show ${completed.length} done'),
                    ),
                  if (_expanded)
                    OutlinedButton(
                      onPressed: () => setState(() => _expanded = false),
                      child: const Text('Show less'),
                    ),
                  IconButton(
                    tooltip: _loading ? 'Checking\u2026' : 'Refresh checks',
                    onPressed: _loading ? null : _refresh,
                    icon: _loading
                        ? const SizedBox(
                            width: 16,
                            height: 16,
                            child: CircularProgressIndicator(strokeWidth: 2),
                          )
                        : const Icon(ScootIcons.refresh, size: 18),
                  ),
                  IconButton(
                    tooltip: 'Dismiss setup checklist',
                    onPressed: _dismiss,
                    icon: const Icon(ScootIcons.close, size: 18),
                  ),
                ],
              ),
            ],
          ),
          const Divider(height: 1),
          for (final AdminSetupChecklistStepState step in visible)
            _SetupChecklistRow(
              key: ValueKey<String>('setup-step-${step.id.name}'),
              step: step,
              onOpen: () => widget.onNavigate(step.navigationKey),
              onReadRunbook: step.id == SetupChecklistStepId.prepareAi
                  ? _showAiRunbook
                  : null,
            ),
          if (!_expanded && hiddenOpen > 0)
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: () => setState(() => _expanded = true),
                child: Text('$hiddenOpen more open steps'),
              ),
            ),
          if (_counts == null)
            Text(
              'Setup status is unavailable.',
              style: TextStyle(color: colors.onSurfaceVariant),
            ),
        ],
      ),
    );
  }

  Future<void> _showAiRunbook() => showDialog<void>(
    context: context,
    builder: (BuildContext context) => AlertDialog(
      title: const Text('AI data runbook'),
      content: const SingleChildScrollView(
        child: Text(
          'The dashboard reads AI documents already saved in Firestore. '
          'It does not generate AI data from this checklist. '
          'The data is based on existing orders '
          'and may be empty when recent order history is missing.',
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    ),
  );
}

class _SetupChecklistRow extends StatelessWidget {
  const _SetupChecklistRow({
    super.key,
    required this.step,
    required this.onOpen,
    this.onReadRunbook,
  });

  final AdminSetupChecklistStepState step;
  final VoidCallback onOpen;
  final VoidCallback? onReadRunbook;

  @override
  Widget build(BuildContext context) {
    final ScootColors sc = ScootColors.of(context);
    final Widget badge = switch (step.status) {
      SetupChecklistStepStatus.complete => const ScootBadge.approved(
        label: 'Done',
      ),
      SetupChecklistStepStatus.incomplete =>
        step.isRequired
            ? const ScootBadge.attention(label: 'Not done')
            : const ScootBadge(label: 'Optional'),
      SetupChecklistStepStatus.couldNotCheck => const ScootBadge(
        label: 'Couldn\u2019t check',
      ),
    };
    final String title = step.title.replaceFirst(' (optional)', '');
    final Widget text = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(title, style: ScootType.bodyStrong.copyWith(color: sc.ink)),
        Text(
          step.explanation,
          maxLines: 2,
          overflow: TextOverflow.ellipsis,
          style: ScootType.caption.copyWith(color: sc.muted),
        ),
      ],
    );
    final Widget actions = Wrap(
      spacing: 8,
      runSpacing: 8,
      children: <Widget>[
        if (onReadRunbook != null)
          OutlinedButton(
            onPressed: onReadRunbook,
            child: const Text('Read the runbook'),
          ),
        OutlinedButton(onPressed: onOpen, child: const Text('Open')),
      ],
    );
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints constraints) {
          if (constraints.maxWidth < 560) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                badge,
                const SizedBox(height: 6),
                text,
                const SizedBox(height: 8),
                actions,
              ],
            );
          }
          return Row(
            children: <Widget>[
              SizedBox(
                width: 104,
                child: Align(alignment: Alignment.centerLeft, child: badge),
              ),
              Expanded(child: text),
              const SizedBox(width: 12),
              actions,
            ],
          );
        },
      ),
    );
  }
}
