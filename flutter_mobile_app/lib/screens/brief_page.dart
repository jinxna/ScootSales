import 'package:flutter/material.dart';

import '../models/stop_brief_view.dart';
import '../models/visit_brief.dart';
import '../theme/app_theme.dart';
import '../widgets/follow_up_chips.dart';
import '../widgets/replenishment_suggestions.dart';
import '../widgets/retailer_memory_panel.dart';
import '../widgets/todays_focus.dart';

typedef RecordBriefOutcome =
    void Function(BuildContext pageContext, VisitBriefInsight insight);

class BriefPage extends StatelessWidget {
  const BriefPage({
    super.key,
    required this.brief,
    required this.stopReason,
    required this.salesmanUid,
    required this.canRecord,
    required this.onRecordOutcome,
    required this.loadMemory,
    required this.onMarkFollowUpDone,
  });

  static const String linkLabel = 'Full brief';

  final VisitBrief brief;
  final String stopReason;
  final String salesmanUid;
  final bool canRecord;
  final RecordBriefOutcome? onRecordOutcome;
  final RetailerMemoryLoader loadMemory;
  final MarkFollowUpDone? onMarkFollowUpDone;

  static Future<void> open(
    BuildContext context, {
    required VisitBrief brief,
    required String stopReason,
    required String salesmanUid,
    required bool canRecord,
    required RecordBriefOutcome? onRecordOutcome,
    required RetailerMemoryLoader loadMemory,
    required MarkFollowUpDone? onMarkFollowUpDone,
  }) {
    return Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: const RouteSettings(name: 'brief'),
        builder: (_) => BriefPage(
          brief: brief,
          stopReason: stopReason,
          salesmanUid: salesmanUid,
          canRecord: canRecord,
          onRecordOutcome: onRecordOutcome,
          loadMemory: loadMemory,
          onMarkFollowUpDone: onMarkFollowUpDone,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Scaffold(
      appBar: AppBar(title: const Text(linkLabel)),
      body: SafeArea(
        child: StopBriefBuilder(
          brief: brief,
          stopReason: stopReason,
          salesmanUid: salesmanUid,
          builder: (BuildContext context, StopBriefView view) {
            return ListView(
              padding: const EdgeInsets.all(16),
              children: <Widget>[
                Text(
                  'Brief for ${view.shopName}',
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 4),
                BriefFreshnessLine(view: view),
                if (view.why.isNotEmpty) ...<Widget>[
                  const _Heading('Why this stop'),
                  Text(view.why, style: const TextStyle(fontSize: 13)),
                ],
                if (view.hasFocusSection) ...<Widget>[
                  const SizedBox(height: 16),
                  TodaysFocusCard(
                    view: view,
                    canRecord: canRecord,
                    onRecordOutcome: switch (onRecordOutcome) {
                      null => null,
                      final RecordBriefOutcome record =>
                        (VisitBriefInsight insight) => record(context, insight),
                    },
                    showCharts: true,
                  ),
                ],
                if (view.lastOrderLine.isNotEmpty ||
                    view.usualOrderDayLine.isNotEmpty) ...<Widget>[
                  const _Heading('Last order'),
                  BriefOrderFacts(view: view),
                ],
                if (view.reorders.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  ReplenishmentSuggestionsCard(
                    retailerId: brief.retailerId,
                    reorders: view.reorders,
                  ),
                ],
                if (view.followUp != null) ...<Widget>[
                  const _Heading('Follow-up'),
                  BriefFollowUpLine(view: view, onMarkDone: onMarkFollowUpDone),
                ],
                if (view.shopFacts.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  RetailerMemorySnapshotCard(facts: view.shopFacts),
                ],
                const SizedBox(height: 12),
                RetailerOwnHistoryCard(
                  key: ValueKey<String>(
                    'brief-history:$salesmanUid:${brief.retailerId}',
                  ),
                  identity: '$salesmanUid\u0000${brief.retailerId}',
                  deferInitialLoad: false,
                  hasEmbeddedSnapshot: view.shopFacts.isNotEmpty,
                  loadMemory: loadMemory,
                  productNames: StopBriefView.productNamesOf(brief),
                ),
              ],
            );
          },
        ),
      ),
    );
  }
}

class _Heading extends StatelessWidget {
  const _Heading(this.text);

  final String text;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: 16, bottom: 4),
      child: Text(
        text,
        style: const TextStyle(
          fontSize: 13,
          fontWeight: FontWeight.w700,
          color: Color(0xFF4C1D95),
        ),
      ),
    );
  }
}
