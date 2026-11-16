import 'package:flutter/material.dart';

import '../../../models/ai_insight.dart';
import '../../../models/conversation_outcome.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/ai_insight_service.dart';
import '../../../services/outcome_review_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/insight_lifecycle.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../../../widgets/count_up_text.dart';
import '../widgets/cms_panel.dart';
import '../../../utils/money_format.dart';
import '../../../widgets/slow_loading.dart';

class ManagementActionCenterPanel extends StatefulWidget {
  const ManagementActionCenterPanel({
    super.key,
    required this.currentUser,
    this.onNavigateRequested,
  });

  final UserProfile currentUser;
  final ValueChanged<String>? onNavigateRequested;

  @override
  State<ManagementActionCenterPanel> createState() =>
      _ManagementActionCenterPanelState();
}

class _ManagementActionCenterPanelState
    extends State<ManagementActionCenterPanel> {
  final AiInsightService _service = AiInsightService();
  final OutcomeReviewService _outcomeService = OutcomeReviewService();
  final CmsRepository _repository = CmsRepository();
  late Stream<List<AiInsight>> _stream;
  late Stream<List<ConversationOutcome>> _outcomeStream;
  String _priority = 'all';
  String _type = 'all';
  String _status = 'active';

  Map<String, Map<String, dynamic>> _myStatuses =
      <String, Map<String, dynamic>>{};
  bool _hideClosedByMe = true;

  @override
  void initState() {
    super.initState();
    _stream = _service.watchInsights(widget.currentUser);
    _outcomeStream = _outcomeService.watchOutcomes(widget.currentUser);
    _loadMyStatuses();
  }

  Future<void> _loadMyStatuses() async {
    final String uid = widget.currentUser.uid ?? '';
    if (uid.isEmpty) return;
    final Map<String, Map<String, dynamic>> statuses = await _repository
        .getActionCentreUserStatuses(uid);
    if (!mounted) return;
    setState(() => _myStatuses = statuses);
  }

  String _actionIdFor(AiInsight insight) => 'insight_${insight.id}';

  String _myStatusFor(AiInsight insight) =>
      (_myStatuses[_actionIdFor(insight)]?['status'] ?? '').toString();

  Future<void> _setMyStatus(AiInsight insight, String status) async {
    final String uid = widget.currentUser.uid ?? '';
    if (uid.isEmpty) return;
    final String actionId = _actionIdFor(insight);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await _repository.setActionCentreUserStatus(
        uid: uid,
        actionId: actionId,
        status: status,
      );
      if (!mounted) return;
      setState(() {
        _myStatuses = <String, Map<String, dynamic>>{
          ..._myStatuses,
          actionId: <String, dynamic>{'actionId': actionId, 'status': status},
        };
      });
      messenger.showSnackBar(
        const SnackBar(content: Text('Saved to your triage.')),
      );
    } catch (_) {
      if (!mounted) return;
      messenger.showSnackBar(
        const SnackBar(content: Text('Could not save your triage status.')),
      );
      await _loadMyStatuses();
    }
  }

  @override
  void didUpdateWidget(ManagementActionCenterPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.uid != widget.currentUser.uid ||
        oldWidget.currentUser.role != widget.currentUser.role ||
        oldWidget.currentUser.branchId != widget.currentUser.branchId ||
        oldWidget.currentUser.assignedSalesmanCodes.join('|') !=
            widget.currentUser.assignedSalesmanCodes.join('|')) {
      _stream = _service.watchInsights(widget.currentUser);
      _outcomeStream = _outcomeService.watchOutcomes(widget.currentUser);
      _myStatuses = <String, Map<String, dynamic>>{};
      _loadMyStatuses();
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<AiInsight>>(
      stream: _stream,
      builder: (BuildContext context, AsyncSnapshot<List<AiInsight>> snapshot) {
        final List<AiInsight> all = snapshot.data ?? const <AiInsight>[];
        final int highPriority = all
            .where(
              (AiInsight insight) =>
                  insight.priority == 'high' && insight.isActive,
            )
            .length;
        final List<AiInsight> active = all
            .where((AiInsight insight) => insight.isActive)
            .toList(growable: false);
        final int atRiskRetailers = active
            .map((AiInsight insight) => insight.retailerId)
            .where((String retailerId) => retailerId.isNotEmpty)
            .toSet()
            .length;
        final double valueAtRisk = active.fold<double>(
          0,
          (double total, AiInsight insight) => total + insight.valueAtRiskRm,
        );
        final int followUps = active
            .where((AiInsight insight) => insight.needsFollowUp)
            .length;
        final int captured = all
            .where((AiInsight insight) => insight.hasCapturedOutcome)
            .length;
        return StreamBuilder<List<ConversationOutcome>>(
          stream: _outcomeStream,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<ConversationOutcome>> outcomeSnapshot,
              ) {
                final List<ConversationOutcome> outcomes =
                    outcomeSnapshot.data ?? const <ConversationOutcome>[];
                final OutcomeOperationsSummary operations =
                    OutcomeOperationsSummary.build(
                      insights: all,
                      outcomes: outcomes,
                    );
                return CmsPanel(
                  title: widget.currentUser.isSupervisor
                      ? 'Supervisor Action Center'
                      : 'Management Action Center',
                  trailing: _CountBadge(
                    label: '$highPriority high',
                    active: highPriority > 0,
                  ),
                  child: ListView(
                    padding: EdgeInsets.zero,
                    children: <Widget>[
                      if (snapshot.hasData)
                        Padding(
                          padding: const EdgeInsets.all(12),
                          child: AiFreshnessChip(
                            hasData: all.isNotEmpty,
                            timestamps: all.map(
                              (AiInsight insight) => insight.freshnessAt,
                            ),
                            hasMissingTimestamp: all.any(
                              (AiInsight insight) =>
                                  insight.freshnessAt == null,
                            ),
                          ),
                        ),
                      _SummaryStrip(
                        highPriority: highPriority,
                        atRiskRetailers: atRiskRetailers,
                        valueAtRisk: valueAtRisk,
                        followUps: followUps,
                        captured: captured,
                      ),
                      const Divider(height: 1),
                      _OutcomeOperationsPanel(
                        outcomes: outcomes,
                        summary: operations,
                        loading:
                            outcomeSnapshot.connectionState ==
                                ConnectionState.waiting &&
                            !outcomeSnapshot.hasData,
                        hasError: outcomeSnapshot.hasError,
                      ),
                      const Divider(height: 1),
                      _Filters(
                        insights: all,
                        priority: _priority,
                        type: _type,
                        status: _status,
                        hideClosedByMe: _hideClosedByMe,
                        hiddenByMe: _hiddenByMeCount(all),
                        onPriorityChanged: (String value) =>
                            setState(() => _priority = value),
                        onTypeChanged: (String value) =>
                            setState(() => _type = value),
                        onStatusChanged: (String value) =>
                            setState(() => _status = value),
                        onHideClosedByMeChanged: (bool value) =>
                            setState(() => _hideClosedByMe = value),
                      ),
                      const Divider(height: 1),
                      _buildBody(snapshot: snapshot, insights: _filtered(all)),
                    ],
                  ),
                );
              },
        );
      },
    );
  }

  Widget _buildBody({
    required AsyncSnapshot<List<AiInsight>> snapshot,
    required List<AiInsight> insights,
  }) {
    if (snapshot.connectionState == ConnectionState.waiting &&
        !snapshot.hasData) {
      return const SizedBox(
        height: 220,
        child: SlowLoading(),
      );
    }
    if (snapshot.hasError) {
      return const SizedBox(
        height: 220,
        child: _PanelMessage(
          icon: Icons.cloud_off_outlined,
          title: 'Insights unavailable',
          subtitle: 'AI suggestions are not available yet.',
        ),
      );
    }
    if (insights.isEmpty) {
      return const SizedBox(
        height: 220,
        child: _PanelMessage(
          icon: Icons.task_alt_outlined,
          title: 'No matching insights',
          subtitle: 'Try changing the filters.',
        ),
      );
    }

    final Map<String, List<AiInsight>> grouped = <String, List<AiInsight>>{};
    for (final AiInsight insight in insights) {
      grouped.putIfAbsent(insight.typeLabel, () => <AiInsight>[]).add(insight);
    }
    return Padding(
      padding: const EdgeInsets.all(14),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: grouped.entries
            .map(
              (MapEntry<String, List<AiInsight>> entry) => Padding(
                padding: const EdgeInsets.only(bottom: 14),
                child: _InsightGroup(
                  title: entry.key,
                  insights: entry.value,
                  onOpenFix: _openFix,
                  canOpenFix: _canOpenFix,
                  onOpenTimeline: _openTimeline,
                  myStatusFor: _myStatusFor,
                  onSetMyStatus: _setMyStatus,
                ),
              ),
            )
            .toList(growable: false),
      ),
    );
  }

  List<AiInsight> _filtered(List<AiInsight> insights) {
    return insights
        .where((AiInsight insight) {
          if (_priority != 'all' && insight.priority != _priority) return false;
          if (_type != 'all' && insight.type != _type) return false;
          if (_status == 'active' && !insight.isActive) return false;
          if (_status == 'closed' && insight.isActive) return false;
          if (_status == 'follow_up' && !insight.needsFollowUp) return false;
          if (_status == 'with_outcome' && !insight.hasCapturedOutcome) {
            return false;
          }
          if (_hideClosedByMe && _isHandledByMe(insight)) return false;
          return true;
        })
        .toList(growable: false);
  }

  bool _isHandledByMe(AiInsight insight) {
    final String mine = _myStatusFor(insight);
    return mine == 'resolved' || mine == 'ignored';
  }

  int _hiddenByMeCount(List<AiInsight> insights) {
    if (!_hideClosedByMe) return 0;
    return insights.where((AiInsight insight) {
      if (_priority != 'all' && insight.priority != _priority) return false;
      if (_type != 'all' && insight.type != _type) return false;
      if (_status == 'active' && !insight.isActive) return false;
      if (_status == 'closed' && insight.isActive) return false;
      if (_status == 'follow_up' && !insight.needsFollowUp) return false;
      if (_status == 'with_outcome' && !insight.hasCapturedOutcome) {
        return false;
      }
      return _isHandledByMe(insight);
    }).length;
  }

  void _openFix(AiInsight insight) {
    final String pageKey = insight.fixPageKey;
    if (pageKey.isEmpty || widget.onNavigateRequested == null) return;
    widget.onNavigateRequested!(pageKey);
  }

  void _openTimeline(AiInsight insight) {
    final Future<List<ConversationOutcome>?> outcomesFuture =
        insight.issueKey.isEmpty
        ? Future<List<ConversationOutcome>?>.value(
            const <ConversationOutcome>[],
          )
        : _outcomeService.loadOutcomesForIssueKey(
            widget.currentUser,
            issueKey: insight.issueKey,
          );
    showDialog<void>(
      context: context,
      builder: (BuildContext context) => _InsightTimelineDialog(
        insight: insight,
        outcomesFuture: outcomesFuture,
      ),
    );
  }

  bool _canOpenFix(AiInsight insight) {
    if (widget.onNavigateRequested == null || insight.fixPageKey.isEmpty) {
      return false;
    }
    return widget.currentUser.isAdmin;
  }
}

class _OutcomeOperationsPanel extends StatelessWidget {
  const _OutcomeOperationsPanel({
    required this.outcomes,
    required this.summary,
    required this.loading,
    required this.hasError,
  });

  final List<ConversationOutcome> outcomes;
  final OutcomeOperationsSummary summary;
  final bool loading;
  final bool hasError;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<ConversationOutcome> lowQuality = outcomes
        .where((ConversationOutcome outcome) => outcome.isLowQuality)
        .take(4)
        .toList(growable: false);
    final List<ConversationOutcome> followUps = outcomes
        .where((ConversationOutcome outcome) => outcome.needsFollowUp)
        .take(4)
        .toList(growable: false);
    final List<ConversationOutcome> datedFollowUps =
        outcomes
            .where(
              (ConversationOutcome outcome) => outcome.hasOpenDatedFollowUp,
            )
            .toList(growable: false)
          ..sort((ConversationOutcome left, ConversationOutcome right) {
            final int byDate = left.followUpDate.compareTo(right.followUpDate);
            if (byDate != 0) return byDate;
            return left.followUpTime.compareTo(right.followUpTime);
          });
    final List<MapEntry<String, int>> topReasons = summary.reasonCounts.entries
        .take(4)
        .toList(growable: false);
    return ExpansionTile(
      initiallyExpanded: true,
      tilePadding: const EdgeInsets.symmetric(horizontal: 14),
      childrenPadding: const EdgeInsets.fromLTRB(14, 0, 14, 14),
      title: const Text(
        'Outcome review',
        style: TextStyle(fontSize: 13, fontWeight: FontWeight.w800),
      ),
      subtitle: Text(
        loading
            ? 'Loading latest outcomes...'
            : hasError
            ? 'Outcomes unavailable for this scope.'
            : '${outcomes.length} latest outcomes (max 120)',
        style: const TextStyle(fontSize: 11.5),
      ),
      children: <Widget>[
        Wrap(
          spacing: 9,
          runSpacing: 9,
          children: <Widget>[
            _SummaryMetric(
              label: 'Capture rate',
              value:
                  '${(summary.complianceRate * 100).round()}% '
                  '(${summary.capturedInsights}/${summary.eligibleInsights})',
              danger:
                  summary.eligibleInsights > 0 && summary.complianceRate < 0.7,
            ),
            _SummaryMetric(
              label: 'Avg quality',
              value: '${summary.averageQuality}/100',
              danger: outcomes.isNotEmpty && summary.averageQuality < 60,
            ),
            _SummaryMetric(
              label: 'Low quality',
              value: '${summary.lowQualityOutcomes}',
              danger: summary.lowQualityOutcomes > 0,
            ),
            _SummaryMetric(
              label: 'Follow-ups',
              value: '${summary.followUpOutcomes}',
              danger: summary.followUpOutcomes > 0,
            ),
            _SummaryMetric(
              label: 'Dated open',
              value:
                  '${outcomes.where((ConversationOutcome outcome) => outcome.hasOpenDatedFollowUp).length}',
              danger: outcomes.any(
                (ConversationOutcome outcome) => outcome.isOverdueDatedFollowUp,
              ),
            ),
          ],
        ),
        if (!loading && !hasError) ...<Widget>[
          const SizedBox(height: 12),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              final List<Widget> queues = <Widget>[
                _OutcomeQueue(
                  title: 'Low quality',
                  emptyLabel: 'No low-quality outcomes.',
                  outcomes: lowQuality,
                  showQuality: true,
                ),
                _OutcomeQueue(
                  title: 'Follow-ups',
                  emptyLabel: 'No follow-ups due.',
                  outcomes: followUps,
                  showQuality: false,
                ),
              ];
              if (constraints.maxWidth < 620) {
                return Column(
                  children: <Widget>[
                    queues[0],
                    const SizedBox(height: 10),
                    queues[1],
                  ],
                );
              }
              return Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(child: queues[0]),
                  const SizedBox(width: 10),
                  Expanded(child: queues[1]),
                ],
              );
            },
          ),
          const SizedBox(height: 12),
          Text(
            'Scheduled callbacks',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 4),
          if (datedFollowUps.isEmpty)
            Text(
              'No dated callback reminders.',
              style: TextStyle(fontSize: 11.5, color: scheme.onSurfaceVariant),
            )
          else
            for (final ConversationOutcome outcome in datedFollowUps.take(
              5,
            )) ...<Widget>[
              Builder(
                builder: (BuildContext context) {
                  final bool overdue = outcome.isOverdueDatedFollowUp;
                  final String retailer = outcome.retailerName.trim().isEmpty
                      ? outcome.retailerId
                      : outcome.retailerName;
                  return ListTile(
                    dense: true,
                    contentPadding: EdgeInsets.zero,
                    title: Text(retailer),
                    subtitle: Text(
                      'Due ${outcome.followUpDate}'
                      '${outcome.followUpTime.isEmpty ? '' : ' · ${outcome.followUpTime}'}'
                      '${outcome.salesmanCode.isEmpty ? '' : ' · ${outcome.salesmanCode}'}',
                    ),
                    trailing: overdue
                        ? const _Pill(
                            label: 'Overdue',
                            foreground: Color(0xFFB42318),
                            background: Color(0xFFFEE4E2),
                          )
                        : const _Pill(
                            label: 'Open',
                            foreground: Color(0xFF175CD3),
                            background: Color(0xFFEFF8FF),
                          ),
                  );
                },
              ),
            ],
          if (topReasons.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Align(
              alignment: Alignment.centerLeft,
              child: Wrap(
                spacing: 7,
                runSpacing: 7,
                children: <Widget>[
                  Text(
                    'Top reasons:',
                    style: TextStyle(
                      fontSize: 11,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                  ...topReasons.map(
                    (MapEntry<String, int> entry) => _Pill(
                      label:
                          '${entry.key.replaceAll('_', ' ')} - ${entry.value}',
                      foreground: scheme.onSurfaceVariant,
                      background: scheme.surfaceContainerHighest,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ],
      ],
    );
  }
}

class _OutcomeQueue extends StatelessWidget {
  const _OutcomeQueue({
    required this.title,
    required this.emptyLabel,
    required this.outcomes,
    required this.showQuality,
  });

  final String title;
  final String emptyLabel;
  final List<ConversationOutcome> outcomes;
  final bool showQuality;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 7),
          if (outcomes.isEmpty)
            Text(
              emptyLabel,
              style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
            )
          else
            ...outcomes.map(
              (ConversationOutcome outcome) => Padding(
                padding: const EdgeInsets.only(bottom: 7),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Expanded(
                      child: Text(
                        '${outcome.salesmanCode.isEmpty ? 'Unassigned' : outcome.salesmanCode}'
                        ' - ${outcome.retailerName} - ${outcome.reasonLabel}',
                        style: TextStyle(
                          fontSize: 11,
                          height: 1.35,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ),
                    if (showQuality)
                      Text(
                        '${outcome.qualityScore}/100',
                        style: TextStyle(
                          fontSize: 10.5,
                          fontWeight: FontWeight.w800,
                          color: context.dso.dangerText,
                        ),
                      ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _SummaryStrip extends StatelessWidget {
  const _SummaryStrip({
    required this.highPriority,
    required this.atRiskRetailers,
    required this.valueAtRisk,
    required this.followUps,
    required this.captured,
  });

  final int highPriority;
  final int atRiskRetailers;
  final double valueAtRisk;
  final int followUps;
  final int captured;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Wrap(
        spacing: 9,
        runSpacing: 9,
        children: <Widget>[
          _SummaryMetric(
            label: 'High',
            value: '$highPriority',
            danger: highPriority > 0,
          ),
          _SummaryMetric(label: 'At risk', value: '$atRiskRetailers'),
          _SummaryMetric(label: 'Risk', value: formatRm(valueAtRisk)),
          _SummaryMetric(label: 'Follow-up', value: '$followUps'),
          _SummaryMetric(label: 'Captured', value: '$captured'),
        ],
      ),
    );
  }
}

class _SummaryMetric extends StatelessWidget {
  const _SummaryMetric({
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
      constraints: const BoxConstraints(minWidth: 128),
      padding: const EdgeInsets.symmetric(horizontal: 11, vertical: 9),
      decoration: BoxDecoration(
        color: danger ? context.dso.dangerSoft : scheme.surfaceContainerHighest,
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
          CountUpText(
            value,
            style: TextStyle(
              fontSize: 15,
              fontWeight: FontWeight.w800,
              color: danger ? context.dso.dangerText : scheme.onSurface,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            label,
            style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
          ),
        ],
      ),
    );
  }
}

class _Filters extends StatelessWidget {
  const _Filters({
    required this.insights,
    required this.priority,
    required this.type,
    required this.status,
    required this.hideClosedByMe,
    required this.hiddenByMe,
    required this.onPriorityChanged,
    required this.onTypeChanged,
    required this.onStatusChanged,
    required this.onHideClosedByMeChanged,
  });

  final List<AiInsight> insights;
  final String priority;
  final String type;
  final String status;
  final bool hideClosedByMe;
  final int hiddenByMe;
  final ValueChanged<String> onPriorityChanged;
  final ValueChanged<String> onTypeChanged;
  final ValueChanged<String> onStatusChanged;
  final ValueChanged<bool> onHideClosedByMeChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final List<AiInsight> sorted = List<AiInsight>.from(insights)
      ..sort(
        (AiInsight left, AiInsight right) =>
            left.typeLabel.compareTo(right.typeLabel),
      );
    final Map<String, String> typeOptions = <String, String>{
      'all': 'All types',
      for (final AiInsight insight in sorted) insight.type: insight.typeLabel,
    };
    return Padding(
      padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
      child: Wrap(
        spacing: 10,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          _FilterDropdown(
            value: priority,
            items: const <String, String>{
              'all': 'All priorities',
              'high': 'High',
              'medium': 'Medium',
              'low': 'Low',
            },
            onChanged: onPriorityChanged,
          ),
          _FilterDropdown(
            value: typeOptions.containsKey(type) ? type : 'all',
            items: typeOptions,
            onChanged: onTypeChanged,
          ),
          _FilterDropdown(
            value: status,
            items: const <String, String>{
              'active': 'Active',
              'follow_up': 'Follow-up needed',
              'with_outcome': 'Outcome captured',
              'closed': 'Closed',
              'all': 'All statuses',
            },
            onChanged: onStatusChanged,
          ),
          FilterChip(
            label: const Text('Hide handled by me'),
            selected: hideClosedByMe,
            onSelected: onHideClosedByMeChanged,
          ),
          Text(
            hideClosedByMe && hiddenByMe > 0
                ? '${insights.length} insights · $hiddenByMe handled by me hidden'
                : '${insights.length} insights',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: scheme.onSurfaceVariant,
            ),
          ),
        ],
      ),
    );
  }
}

class _FilterDropdown extends StatelessWidget {
  const _FilterDropdown({
    required this.value,
    required this.items,
    required this.onChanged,
  });

  final String value;
  final Map<String, String> items;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 38,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: DropdownButtonHideUnderline(
        child: DropdownButton<String>(
          value: value,
          isDense: true,
          items: items.entries
              .map(
                (MapEntry<String, String> entry) => DropdownMenuItem<String>(
                  value: entry.key,
                  child: Text(entry.value),
                ),
              )
              .toList(growable: false),
          onChanged: (String? next) {
            if (next != null) onChanged(next);
          },
        ),
      ),
    );
  }
}

class _InsightGroup extends StatelessWidget {
  const _InsightGroup({
    required this.title,
    required this.insights,
    required this.onOpenFix,
    required this.canOpenFix,
    required this.onOpenTimeline,
    required this.myStatusFor,
    required this.onSetMyStatus,
  });

  final String title;
  final List<AiInsight> insights;
  final ValueChanged<AiInsight> onOpenFix;
  final bool Function(AiInsight) canOpenFix;
  final ValueChanged<AiInsight> onOpenTimeline;
  final String Function(AiInsight) myStatusFor;
  final void Function(AiInsight, String) onSetMyStatus;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Row(
          children: <Widget>[
            Text(
              title,
              style: TextStyle(
                fontSize: 13,
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(width: 8),
            _CountBadge(label: '${insights.length}', active: false),
          ],
        ),
        const SizedBox(height: 8),
        ...insights.map(
          (AiInsight insight) => Padding(
            padding: const EdgeInsets.only(bottom: 9),
            child: _InsightCard(
              insight: insight,
              onOpenFix: () => onOpenFix(insight),
              showFix: canOpenFix(insight),
              onOpenTimeline: () => onOpenTimeline(insight),
              myStatus: myStatusFor(insight),
              onSetMyStatus: (String status) => onSetMyStatus(insight, status),
            ),
          ),
        ),
      ],
    );
  }
}

class _InsightCard extends StatelessWidget {
  const _InsightCard({
    required this.insight,
    required this.onOpenFix,
    required this.showFix,
    required this.onOpenTimeline,
    this.myStatus = '',
    this.onSetMyStatus,
  });

  final AiInsight insight;
  final VoidCallback onOpenFix;
  final bool showFix;
  final VoidCallback onOpenTimeline;
  final String myStatus;
  final ValueChanged<String>? onSetMyStatus;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool dark = scheme.brightness == Brightness.dark;
    final Color priorityColor = switch (insight.priority) {
      'high' => context.dso.dangerText,
      'medium' => context.dso.warningText,
      _ => context.dso.infoText,
    };
    final Color priorityBackground = switch (insight.priority) {
      'high' => context.dso.dangerSoft,
      'medium' => context.dso.warningSoft,
      _ => context.dso.infoSoft,
    };
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(13),
      decoration: BoxDecoration(
        color: scheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 7,
            runSpacing: 7,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _Pill(
                label: insight.priority.toUpperCase(),
                foreground: priorityColor,
                background: priorityBackground,
              ),
              _Pill(
                label: '${insight.confidence} confidence',
                foreground: scheme.onSurfaceVariant,
                background: scheme.surfaceContainerHighest,
              ),
              if (insight.needsFollowUp) ...<Widget>[
                _Pill(
                  label: 'FOLLOW UP',
                  foreground: context.dso.warningText,
                  background: context.dso.warningSoft,
                ),
              ],
              if (insight.hasCapturedOutcome) ...<Widget>[
                _Pill(
                  label: '${insight.outcomeCount} OUTCOME',
                  foreground: context.dso.successText,
                  background: context.dso.successSoft,
                ),
              ],
              if (_myStatusLabel(myStatus) != null) ...<Widget>[
                _Pill(
                  label: 'Mine: ${_myStatusLabel(myStatus)}',
                  foreground: dark
                      ? const Color(0xFFC4B5FD)
                      : const Color(0xFF6941C6),
                  background: context.dso.violetSoft,
                ),
              ],
              Text(
                _formatDate(insight.updatedAt),
                style: TextStyle(fontSize: 11, color: scheme.onSurfaceVariant),
              ),
            ],
          ),
          const SizedBox(height: 9),
          Text(
            '${insight.retailerName} - ${insight.productName}',
            style: TextStyle(
              fontSize: 14,
              fontWeight: FontWeight.w800,
              color: scheme.onSurface,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            insight.reason,
            style: TextStyle(
              fontSize: 12,
              height: 1.45,
              color: scheme.onSurfaceVariant,
            ),
          ),
          if (insight.recommendation.isNotEmpty) ...<Widget>[
            const SizedBox(height: 7),
            Text(
              insight.recommendation,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w700,
                color: scheme.onSurface,
              ),
            ),
          ],
          const SizedBox(height: 9),
          Wrap(
            spacing: 14,
            runSpacing: 6,
            children: <Widget>[
              _Metric(
                label: 'Value at risk',
                value: formatRm(insight.valueAtRiskRm),
              ),
              if (insight.isCadenceInsight) ...<Widget>[
                _Metric(
                  label: 'Reorder interval',
                  value: '${insight.reorderIntervalDays.toStringAsFixed(0)}d',
                ),
                _Metric(
                  label: 'Days since order',
                  value: '${insight.daysSinceLastOrder}d',
                ),
                _Metric(
                  label: 'Overdue by',
                  value: '${insight.overdueByDays.toStringAsFixed(0)}d',
                ),
              ] else ...<Widget>[
                _Metric(
                  label: 'Next week',
                  value: insight.forecastNextWeek.toStringAsFixed(1),
                ),
                _Metric(
                  label: 'Anomaly',
                  value: '${(insight.anomalyScore * 100).round()}%',
                ),
              ],
            ],
          ),
          if (insight.questions.isNotEmpty) ...<Widget>[
            const SizedBox(height: 9),
            Text(
              'Ask: ${insight.questions.first}',
              style: TextStyle(
                fontSize: 12,
                fontStyle: FontStyle.italic,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
          const SizedBox(height: 8),
          Align(
            alignment: Alignment.centerRight,
            child: Wrap(
              alignment: WrapAlignment.end,
              spacing: 4,
              children: <Widget>[
                TextButton.icon(
                  onPressed: onOpenTimeline,
                  icon: const Icon(Icons.timeline_outlined, size: 16),
                  label: const Text('Timeline'),
                ),
                if (onSetMyStatus != null)
                  PopupMenuButton<String>(
                    tooltip: 'My triage',
                    icon: const Icon(Icons.how_to_reg_outlined, size: 18),
                    onSelected: onSetMyStatus,
                    itemBuilder: (BuildContext context) =>
                        <PopupMenuEntry<String>>[
                          const PopupMenuItem<String>(
                            value: 'in_review',
                            child: Text('Mark in review'),
                          ),
                          const PopupMenuItem<String>(
                            value: 'resolved',
                            child: Text('Mark resolved'),
                          ),
                          const PopupMenuItem<String>(
                            value: 'ignored',
                            child: Text('Ignore'),
                          ),
                          if (myStatus.isNotEmpty && myStatus != 'new')
                            const PopupMenuItem<String>(
                              value: 'new',
                              child: Text('Clear my status'),
                            ),
                        ],
                  ),
                if (showFix)
                  TextButton.icon(
                    onPressed: onOpenFix,
                    icon: const Icon(Icons.build_outlined, size: 16),
                    label: Text(
                      insight.fixTarget == 'product'
                          ? 'Open product editor'
                          : 'Open data-quality fix',
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

class _InsightTimelineDialog extends StatelessWidget {
  const _InsightTimelineDialog({
    required this.insight,
    required this.outcomesFuture,
  });

  final AiInsight insight;
  final Future<List<ConversationOutcome>?> outcomesFuture;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return AlertDialog(
      title: Text(
        '${insight.retailerName} — ${insight.productName}',
        style: const TextStyle(fontSize: 16, fontWeight: FontWeight.w800),
      ),
      content: SizedBox(
        width: 480,
        child: FutureBuilder<List<ConversationOutcome>?>(
          future: outcomesFuture,
          builder:
              (
                BuildContext context,
                AsyncSnapshot<List<ConversationOutcome>?> snapshot,
              ) {
                if (snapshot.connectionState != ConnectionState.done) {
                  return const SizedBox(
                    height: 140,
                    child: SlowLoading(),
                  );
                }
                final List<ConversationOutcome>? outcomes = snapshot.data;
                final bool loadFailed = outcomes == null;
                final List<InsightLifecycleEvent> events =
                    buildInsightLifecycle(
                      raisedAt: insight.createdAt,
                      lastObservedWeekStart: insight.lastObservedWeekStart,
                      status: insight.status,
                      autoState: insight.autoState,
                      autoSuppressedAt: insight.autoSuppressedAt,
                      autoSuppressionReason: insight.autoSuppressionReason,
                      valueAtRiskRm: insight.valueAtRiskRm,
                      outcomes: (outcomes ?? const <ConversationOutcome>[])
                          .map(
                            (ConversationOutcome outcome) => LifecycleOutcome(
                              reasonCode: outcome.reasonCode,
                              salesmanCode: outcome.salesmanCode,
                              qualityScore: outcome.qualityScore,
                              at: outcome.submittedAt,
                              isDemo: outcome.isDemo,
                            ),
                          )
                          .toList(growable: false),
                    );
                final bool waitingOnVisit =
                    !loadFailed && outcomes.isEmpty && insight.isActive;
                return SingleChildScrollView(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Wrap(
                        spacing: 7,
                        runSpacing: 7,
                        children: <Widget>[
                          _Pill(
                            label: 'Status: ${insight.status}',
                            foreground: scheme.onSurfaceVariant,
                            background: scheme.surfaceContainerHighest,
                          ),
                          _Pill(
                            label: 'Loop: ${insight.autoState}',
                            foreground: scheme.onSurfaceVariant,
                            background: scheme.surfaceContainerHighest,
                          ),
                          if (insight.valueAtRiskRm > 0)
                            _Pill(
                              label:
                                  '${formatRm(insight.valueAtRiskRm)} at risk',
                              foreground: insight.isActive
                                  ? context.dso.dangerText
                                  : context.dso.successText,
                              background: insight.isActive
                                  ? context.dso.dangerSoft
                                  : context.dso.successSoft,
                            ),
                        ],
                      ),
                      if (loadFailed) ...<Widget>[
                        const SizedBox(height: 10),
                        Text(
                          'Could not load recorded outcomes — showing insight facts only.',
                          style: TextStyle(fontSize: 12, color: scheme.error),
                        ),
                      ],
                      const SizedBox(height: 12),
                      for (int i = 0; i < events.length; i++)
                        _TimelineRow(
                          event: events[i],
                          isLast: i == events.length - 1,
                        ),
                      if (waitingOnVisit)
                        Padding(
                          padding: const EdgeInsets.only(top: 4),
                          child: Text(
                            'No outcomes recorded yet — the loop is waiting on a visit.',
                            style: TextStyle(
                              fontSize: 12,
                              fontStyle: FontStyle.italic,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                        ),
                    ],
                  ),
                );
              },
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}

class _TimelineRow extends StatelessWidget {
  const _TimelineRow({required this.event, required this.isLast});

  final InsightLifecycleEvent event;
  final bool isLast;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final Color infoColor = context.dso.infoText;
    final Color okColor = context.dso.successText;
    final Color warnColor = context.dso.warningText;
    final (IconData icon, Color color) = switch (event.kind) {
      LifecycleEventKind.raised => (Icons.flag_outlined, infoColor),
      LifecycleEventKind.evidenceWindow => (
        Icons.query_stats_outlined,
        scheme.onSurfaceVariant,
      ),
      LifecycleEventKind.outcomeRecorded => (Icons.chat_outlined, okColor),
      LifecycleEventKind.followUpFlagged => (
        Icons.schedule_outlined,
        warnColor,
      ),
      LifecycleEventKind.suppressed => (Icons.check_circle_outline, okColor),
      LifecycleEventKind.humanClosed => (
        Icons.how_to_reg_outlined,
        scheme.onSurfaceVariant,
      ),
    };
    return IntrinsicHeight(
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Column(
            children: <Widget>[
              Icon(icon, size: 18, color: color),
              if (!isLast)
                Expanded(
                  child: Container(width: 2, color: scheme.outlineVariant),
                ),
            ],
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Padding(
              padding: EdgeInsets.only(bottom: isLast ? 0 : 14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    event.title,
                    style: TextStyle(
                      fontSize: 12.5,
                      fontWeight: FontWeight.w700,
                      color: scheme.onSurface,
                    ),
                  ),
                  if (event.detail.isNotEmpty)
                    Text(
                      event.detail,
                      style: TextStyle(
                        fontSize: 12,
                        color: scheme.onSurfaceVariant,
                      ),
                    ),
                  Text(
                    event.at == null
                        ? 'time not recorded'
                        : _formatDate(event.at),
                    style: TextStyle(
                      fontSize: 11,
                      color: scheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Text(
      '$label: $value',
      style: TextStyle(
        fontSize: 11,
        fontWeight: FontWeight.w700,
        color: scheme.onSurfaceVariant,
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({
    required this.label,
    required this.foreground,
    required this.background,
  });

  final String label;
  final Color foreground;
  final Color background;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: background,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 10,
          fontWeight: FontWeight.w800,
          color: foreground,
        ),
      ),
    );
  }
}

class _CountBadge extends StatelessWidget {
  const _CountBadge({required this.label, required this.active});

  final String label;
  final bool active;

  @override
  Widget build(BuildContext context) {
    return _Pill(
      label: label,
      foreground: active ? context.dso.dangerText : context.dso.body,
      background: active ? context.dso.dangerSoft : context.dso.surfaceSoft,
    );
  }
}

class _PanelMessage extends StatelessWidget {
  const _PanelMessage({
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
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 34, color: scheme.onSurfaceVariant),
            const SizedBox(height: 10),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontWeight: FontWeight.w800,
                color: scheme.onSurface,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                color: scheme.onSurfaceVariant,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

String? _myStatusLabel(String status) {
  switch (status) {
    case 'in_review':
      return 'In review';
    case 'resolved':
      return 'Resolved';
    case 'ignored':
      return 'Ignored';
    default:
      return null;
  }
}

String _formatDate(DateTime? value) {
  if (value == null) return '';
  final DateTime local = value.toLocal();
  return '${local.day.toString().padLeft(2, '0')}/'
      '${local.month.toString().padLeft(2, '0')} '
      '${local.hour.toString().padLeft(2, '0')}:'
      '${local.minute.toString().padLeft(2, '0')}';
}
