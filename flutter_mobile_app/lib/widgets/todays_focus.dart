import 'dart:async';

import 'package:flutter/material.dart';

import '../models/stop_brief_view.dart';
import '../models/visit_brief.dart';
import '../services/follow_up_service.dart';
import '../services/last_order_service.dart';
import '../theme/app_theme.dart';
import 'brief_weekly_chart.dart';

typedef StopBriefWidgetBuilder =
    Widget Function(BuildContext context, StopBriefView view);

class StopBriefBuilder extends StatefulWidget {
  const StopBriefBuilder({
    super.key,
    required this.brief,
    required this.stopReason,
    required this.salesmanUid,
    required this.builder,
  });

  final VisitBrief brief;
  final String stopReason;
  final String salesmanUid;
  final StopBriefWidgetBuilder builder;

  @override
  State<StopBriefBuilder> createState() => _StopBriefBuilderState();
}

class _StopBriefBuilderState extends State<StopBriefBuilder> {
  StreamSubscription<LastOrder?>? _subscription;
  LastOrder? _lastOrder;
  ShopFollowUp? _followUp;
  int _followUpRead = 0;

  @override
  void initState() {
    super.initState();
    _listen();
    FollowUpService.changes.addListener(_readFollowUp);
    _readFollowUp();
  }

  Future<void> _readFollowUp() async {
    final int read = ++_followUpRead;
    final ShopFollowUp? followUp;
    try {
      followUp = await FollowUpService().forShop(
        uid: widget.salesmanUid,
        retailerId: widget.brief.retailerId,
      );
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'follow-up',
        ),
      );
      return;
    }
    if (mounted && read == _followUpRead) {
      setState(() => _followUp = followUp);
    }
  }

  @override
  void didUpdateWidget(covariant StopBriefBuilder oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.salesmanUid != widget.salesmanUid ||
        oldWidget.brief.retailerId != widget.brief.retailerId) {
      _lastOrder = null;
      _followUp = null;
      _listen();
      _readFollowUp();
    }
  }

  void _listen() {
    unawaited(_subscription?.cancel());
    _subscription = LastOrderService()
        .watch(uid: widget.salesmanUid, retailerId: widget.brief.retailerId)
        .listen(
          (LastOrder? order) {
            if (mounted) setState(() => _lastOrder = order);
          },
          onError: (Object error, StackTrace stack) {
            FlutterError.reportError(
              FlutterErrorDetails(
                exception: error,
                stack: stack,
                library: 'last order',
              ),
            );
          },
        );
  }

  @override
  void dispose() {
    FollowUpService.changes.removeListener(_readFollowUp);
    unawaited(_subscription?.cancel());
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return widget.builder(
      context,
      StopBriefView.build(
        brief: widget.brief,
        stopReason: widget.stopReason,
        lastOrder: _lastOrder,
        now: DateTime.now(),
        followUp: _followUp?.promise,
        laterOutcomeAt: _followUp?.laterOutcomeAt,
      ),
    );
  }
}

class BriefFreshnessLine extends StatelessWidget {
  const BriefFreshnessLine({super.key, required this.view});

  final StopBriefView view;

  @override
  Widget build(BuildContext context) {
    if (view.freshnessLine.isEmpty) return const SizedBox.shrink();
    return Text(
      view.freshnessLine,
      style: TextStyle(
        fontSize: 12,
        fontWeight: view.isStale ? FontWeight.w700 : FontWeight.w400,
        color: view.isStale ? const Color(0xFFB54708) : AppColors.textGrey,
      ),
    );
  }
}

class BriefOrderFacts extends StatelessWidget {
  const BriefOrderFacts({super.key, required this.view});

  final StopBriefView view;

  @override
  Widget build(BuildContext context) {
    final List<String> lines = <String>[
      if (view.lastOrderLine.isNotEmpty) view.lastOrderLine,
      if (view.usualOrderDayLine.isNotEmpty) view.usualOrderDayLine,
    ];
    if (lines.isEmpty) return const SizedBox.shrink();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final String line in lines)
          Padding(
            padding: const EdgeInsets.only(bottom: 4),
            child: Text(line, style: const TextStyle(fontSize: 12)),
          ),
      ],
    );
  }
}

class TodaysFocusCard extends StatelessWidget {
  const TodaysFocusCard({
    super.key,
    required this.view,
    this.canRecord = false,
    this.onRecordOutcome,
    this.showCharts = false,
  });

  static const String title = "TODAY'S FOCUS";
  static const String recordBlockedReason =
      'Mark this stop arrived first. Then you can record the outcome.';

  final StopBriefView view;
  final bool canRecord;
  final ValueChanged<VisitBriefInsight>? onRecordOutcome;
  final bool showCharts;

  @override
  Widget build(BuildContext context) {
    if (!view.hasFocusSection) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDD6FE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
              color: Color(0xFF4C1D95),
            ),
          ),
          const SizedBox(height: 6),
          FocusItemsList(
            view: view,
            canRecord: canRecord,
            onRecordOutcome: onRecordOutcome,
            showCharts: showCharts,
          ),
        ],
      ),
    );
  }
}

class FocusItemsList extends StatelessWidget {
  const FocusItemsList({
    super.key,
    required this.view,
    this.canRecord = false,
    this.onRecordOutcome,
    this.showCharts = false,
  });

  final StopBriefView view;
  final bool canRecord;
  final ValueChanged<VisitBriefInsight>? onRecordOutcome;
  final bool showCharts;

  @override
  Widget build(BuildContext context) {
    if (view.focus.isEmpty) {
      return Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            view.noFocusHeadline,
            style: const TextStyle(fontWeight: FontWeight.w600),
          ),
          const SizedBox(height: 2),
          Text(
            view.noFocusBody,
            style: TextStyle(fontSize: 12, color: Colors.deepPurple.shade700),
          ),
        ],
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        for (final BriefFocusView focus in view.focus) ...<Widget>[
          if (focus.position > 1) const Divider(height: 14),
          FocusItemTile(
            focus: focus,
            canRecord: canRecord,
            onRecordOutcome: onRecordOutcome,
            showChart: showCharts,
          ),
        ],
      ],
    );
  }
}

class FocusItemTile extends StatelessWidget {
  const FocusItemTile({
    super.key,
    required this.focus,
    this.canRecord = false,
    this.onRecordOutcome,
    this.showChart = false,
  });

  final BriefFocusView focus;
  final bool canRecord;
  final ValueChanged<VisitBriefInsight>? onRecordOutcome;
  final bool showChart;

  @override
  Widget build(BuildContext context) {
    final VisitFocusItem item = focus.item;
    final VisitBriefInsight? recordable = focus.recordable;
    final ValueChanged<VisitBriefInsight>? record = onRecordOutcome;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '${focus.position}. ${focus.title}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (item.signal.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(item.signal, style: const TextStyle(fontSize: 12)),
        ],
        if (focus.moneyLine.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            focus.moneyLine,
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w700,
              color: Color(0xFFB54708),
            ),
          ),
        ],
        if (focus.previousLine.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            focus.previousLine,
            style: TextStyle(fontSize: 12, color: Colors.deepPurple.shade400),
          ),
        ],
        if (item.action.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            'Action: ${item.action}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4C1D95),
            ),
          ),
        ],
        for (final String question in focus.questions) ...<Widget>[
          const SizedBox(height: 4),
          Text('• $question', style: const TextStyle(fontSize: 12)),
        ],
        if (showChart && focus.weeks.isNotEmpty) ...<Widget>[
          const SizedBox(height: 10),
          BriefWeeklyChart(weeks: focus.weeks, unit: focus.unit),
        ],
        if (record != null && recordable != null) ...<Widget>[
          const SizedBox(height: 4),
          Align(
            alignment: Alignment.centerRight,
            child: TextButton.icon(
              onPressed: canRecord ? () => record(recordable) : null,
              icon: const Icon(Icons.fact_check_outlined, size: 17),
              label: const Text('Record outcome'),
            ),
          ),
          if (!canRecord)
            const Align(
              alignment: Alignment.centerRight,
              child: Text(
                TodaysFocusCard.recordBlockedReason,
                textAlign: TextAlign.right,
                style: TextStyle(fontSize: 11, color: AppColors.textGrey),
              ),
            ),
        ],
      ],
    );
  }
}
