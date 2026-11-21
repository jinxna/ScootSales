import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/visit_brief.dart';
import '../theme/app_theme.dart';
import '../utils/retailer_memory.dart';

typedef RetailerMemoryLoader =
    Future<RetailerMemory?> Function({required bool refresh});

bool hasUsableRetailerMemorySnapshot(RetailerMemoryContext? memory) {
  if (memory == null || !memory.isActive) return false;
  return memory.commonReasonCodes.isNotEmpty ||
      memory.replacementProductIds.isNotEmpty ||
      memory.priceSensitivityScore > 0 ||
      memory.seasonalityScore > 0;
}

class RetailerMemorySnapshotCard extends StatelessWidget {
  const RetailerMemorySnapshotCard({super.key, required this.facts});

  static const String title = 'What we know about this shop';

  final List<String> facts;

  @override
  Widget build(BuildContext context) {
    if (facts.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE9FE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4C1D95),
            ),
          ),
          for (final String fact in facts) ...<Widget>[
            const SizedBox(height: 4),
            Text(fact, style: const TextStyle(fontSize: 12)),
          ],
        ],
      ),
    );
  }
}

class RetailerOwnHistoryCard extends StatefulWidget {
  const RetailerOwnHistoryCard({
    super.key,
    required this.identity,
    required this.deferInitialLoad,
    required this.hasEmbeddedSnapshot,
    required this.loadMemory,
    this.productNames = const <String, String>{},
  });

  final Map<String, String> productNames;
  final String identity;
  final bool deferInitialLoad;
  final bool hasEmbeddedSnapshot;
  final RetailerMemoryLoader loadMemory;

  @override
  State<RetailerOwnHistoryCard> createState() => _RetailerOwnHistoryCardState();
}

class _RetailerOwnHistoryCardState extends State<RetailerOwnHistoryCard> {
  RetailerMemory? _memory;
  bool _expanded = false;
  bool _isLoading = false;
  bool _loadFailed = false;
  int _requestGeneration = 0;

  @override
  void initState() {
    super.initState();
    _resetAndMaybeLoad();
  }

  @override
  void didUpdateWidget(covariant RetailerOwnHistoryCard oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.identity != widget.identity) {
      _requestGeneration += 1;
      _resetAndMaybeLoad();
    } else if (oldWidget.deferInitialLoad && !widget.deferInitialLoad) {
      _expanded = true;
      _startLoad(refresh: false, notify: false);
    }
  }

  void _resetAndMaybeLoad() {
    _memory = null;
    _loadFailed = false;
    _isLoading = false;
    _expanded = !widget.deferInitialLoad;
    if (_expanded) _startLoad(refresh: false, notify: false);
  }

  Future<void> _startLoad({required bool refresh, bool notify = true}) async {
    final int generation = ++_requestGeneration;
    void markLoading() {
      _expanded = true;
      _isLoading = true;
      _loadFailed = false;
    }

    if (notify) {
      setState(markLoading);
    } else {
      markLoading();
    }

    RetailerMemory? result;
    try {
      result = await widget.loadMemory(refresh: refresh);
    } catch (_) {
      result = null;
    }
    if (!mounted || generation != _requestGeneration) return;
    setState(() {
      _isLoading = false;
      if (result == null) {
        _loadFailed = true;
      } else {
        _memory = result;
        _loadFailed = false;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    if (!_expanded) {
      return _historyShell(
        child: Row(
          children: <Widget>[
            const Expanded(
              child: Text(
                'See what you recorded at this shop before.',
                style: TextStyle(fontSize: 12, color: AppColors.textGrey),
              ),
            ),
            const SizedBox(width: 8),
            TextButton(
              onPressed: () => _startLoad(refresh: false),
              child: const Text('Show your visit history'),
            ),
          ],
        ),
      );
    }

    final RetailerMemory? memory = _memory;
    if (memory == null) {
      if (_isLoading) {
        return _historyShell(
          child: const _HistoryStatus(
            icon: Icons.sync,
            message: 'Loading your visit history…',
          ),
        );
      }
      return _historyShell(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              widget.hasEmbeddedSnapshot
                  ? 'Could not refresh your visit history. The brief is still shown.'
                  : 'Could not load your visit history for this retailer.',
              style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
            ),
            const SizedBox(height: 4),
            TextButton(
              onPressed: () => _startLoad(refresh: false),
              child: const Text('Retry'),
            ),
          ],
        ),
      );
    }

    return _historyShell(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              const Icon(
                Icons.history_outlined,
                size: 16,
                color: Color(0xFF175CD3),
              ),
              const SizedBox(width: 6),
              const Expanded(
                child: Text(
                  'Your visit history',
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: Color(0xFF175CD3),
                  ),
                ),
              ),
              TextButton(
                onPressed: _isLoading ? null : () => _startLoad(refresh: true),
                child: Text(_isLoading ? 'Refreshing…' : 'Refresh'),
              ),
            ],
          ),
          if (_loadFailed) ...<Widget>[
            const SizedBox(height: 2),
            const Text(
              'Refresh failed — showing last loaded history.',
              style: TextStyle(fontSize: 11, color: Color(0xFFB45309)),
            ),
          ],
          if (memory.isEmpty)
            const Padding(
              padding: EdgeInsets.only(top: 4),
              child: Text(
                'No recorded outcomes for this retailer yet.',
                style: TextStyle(fontSize: 12, color: AppColors.textGrey),
              ),
            )
          else
            _PopulatedHistory(
              memory: memory,
              productNames: widget.productNames,
            ),
        ],
      ),
    );
  }

  Widget _historyShell({required Widget child}) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF8FF),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFB2DDFF)),
      ),
      child: child,
    );
  }
}

class _HistoryStatus extends StatelessWidget {
  const _HistoryStatus({required this.icon, required this.message});

  final IconData icon;
  final String message;

  @override
  Widget build(BuildContext context) {
    return Row(
      children: <Widget>[
        Icon(icon, size: 16, color: const Color(0xFF175CD3)),
        const SizedBox(width: 6),
        Text(
          message,
          style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
        ),
      ],
    );
  }
}

class _PopulatedHistory extends StatelessWidget {
  const _PopulatedHistory({required this.memory, required this.productNames});

  final RetailerMemory memory;
  final Map<String, String> productNames;

  @override
  Widget build(BuildContext context) {
    final List<String> signals = <String>[
      for (final ReasonStat reason in memory.topReasons.take(2))
        '${reasonCodeLabel(reason.reasonCode)} ×${reason.count}',
      if (memory.isPriceSensitive) 'Price sensitive',
      if (memory.hasSeasonalitySignal) 'Seasonal pattern',
      for (final ReplacementStat replacement in memory.commonReplacements.take(
        1,
      ))
        if (productNames[replacement.productId] case final String name)
          'Switched to $name',
    ];
    final IssueMemory? lastIssue = memory.lastIssues.isEmpty
        ? null
        : memory.lastIssues.first;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${memory.confidenceLabel} confidence',
          style: const TextStyle(fontSize: 11, color: AppColors.textGrey),
        ),
        if (signals.isNotEmpty) ...<Widget>[
          const SizedBox(height: 5),
          Text(signals.join(' • '), style: const TextStyle(fontSize: 12)),
        ],
        if (lastIssue != null) ...<Widget>[
          const SizedBox(height: 3),
          Text(
            'Last issue: ${lastIssue.productName.isEmpty ? lastIssue.issueKey : lastIssue.productName}'
            ' — ${reasonCodeLabel(lastIssue.reasonCode)}'
            '${lastIssue.needsFollowUp ? ' (follow-up pending)' : ''}',
            style: const TextStyle(fontSize: 12),
          ),
        ],
        const SizedBox(height: 5),
        Text(
          'Based on ${memory.outcomeCount} outcome(s)'
          '${memory.mostRecentAt == null ? '' : ' • most recent ${DateFormat('d MMM').format(memory.mostRecentAt!)}'}',
          style: const TextStyle(fontSize: 11, color: AppColors.textGrey),
        ),
      ],
    );
  }
}
