import 'package:flutter/material.dart';

import '../../theme/dso_colors.dart';
import 'copilot_widgets.dart';
import 'order_search_session.dart';

class CopilotOrderResultsView extends StatelessWidget {
  const CopilotOrderResultsView({
    super.key,
    required this.card,
    required this.onOpen,
    required this.onOpenAllOrders,
  });

  final OrderResultsCard card;

  final ValueChanged<int> onOpen;
  final VoidCallback onOpenAllOrders;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 6,
            runSpacing: 6,
            children: <Widget>[
              for (final String chip in card.chips)
                Container(
                  padding: const EdgeInsets.symmetric(
                    horizontal: 8,
                    vertical: 2,
                  ),
                  decoration: BoxDecoration(
                    color: dso.brandSurface,
                    borderRadius: BorderRadius.circular(999),
                  ),
                  child: Text(
                    chip,
                    style: TextStyle(fontSize: 12, color: dso.accentText),
                  ),
                ),
            ],
          ),
          if (card.rows.isNotEmpty)
            Container(
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: dso.card,
                border: Border.all(color: dso.hairline),
                borderRadius: BorderRadius.circular(10),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < card.rows.length; i++)
                    InkWell(
                      onTap: () => onOpen(i + 1),
                      child: Container(
                        width: double.infinity,
                        padding: const EdgeInsets.symmetric(
                          horizontal: 10,
                          vertical: 9,
                        ),
                        decoration: BoxDecoration(
                          border: i == 0
                              ? null
                              : Border(top: BorderSide(color: dso.hairline)),
                        ),
                        child: card.rowIds == null
                            ? Text(
                                card.rows[i],
                                style: TextStyle(fontSize: 12, color: dso.body),
                              )
                            : Row(
                                children: <Widget>[
                                  Expanded(
                                    child: Text(
                                      card.rows[i],
                                      style: TextStyle(
                                        fontSize: 12,
                                        color: dso.body,
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: () => onOpen(i + 1),
                                    style: TextButton.styleFrom(
                                      foregroundColor: dso.accentText,
                                      padding: const EdgeInsets.symmetric(
                                        horizontal: 6,
                                      ),
                                      minimumSize: const Size(0, 28),
                                    ),
                                    child: Text(
                                      'Open order ${card.rowIds![i]}',
                                      style: const TextStyle(fontSize: 11),
                                    ),
                                  ),
                                ],
                              ),
                      ),
                    ),
                ],
              ),
            ),
          if (card.total > card.shown)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Wrap(
                crossAxisAlignment: WrapCrossAlignment.center,
                spacing: 8,
                children: <Widget>[
                  Text(
                    'Showing ${card.shown} of ${card.total}',
                    style: TextStyle(fontSize: 12, color: dso.muted),
                  ),
                  TextButton(
                    onPressed: onOpenAllOrders,
                    style: TextButton.styleFrom(
                      foregroundColor: dso.accentText,
                      padding: const EdgeInsets.symmetric(horizontal: 6),
                      minimumSize: const Size(0, 28),
                    ),
                    child: const Text('Open All Orders'),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class CopilotChoiceView extends StatelessWidget {
  const CopilotChoiceView({
    super.key,
    required this.card,
    required this.enabled,
    required this.onPick,
  });

  final ChoiceCard card;
  final bool enabled;
  final ValueChanged<int> onPick;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: dso.card,
        border: Border.all(color: dso.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < card.choices.length; i++)
            InkWell(
              onTap: enabled ? () => onPick(i + 1) : null,
              child: Container(
                width: double.infinity,
                padding: const EdgeInsets.symmetric(
                  horizontal: 10,
                  vertical: 10,
                ),
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : Border(top: BorderSide(color: dso.hairline)),
                ),
                child: Text(
                  card.choices[i],
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: dso.ink,
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class CopilotExportView extends StatelessWidget {
  const CopilotExportView({
    super.key,
    required this.card,
    required this.live,
    required this.busy,
    required this.expiresAt,
    required this.onConfirm,
    required this.onCancel,
  });

  final ExportCard card;

  final bool live;
  final bool busy;
  final DateTime? expiresAt;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    if (!live) return const SizedBox.shrink();
    return Container(
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: dso.warningSoft,
        border: Border.all(color: dso.warning.withValues(alpha: 0.6)),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              Icon(Icons.download_outlined, size: 14, color: dso.warningText),
              const SizedBox(width: 6),
              Text(
                'Confirm download',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                  color: dso.warningText,
                ),
              ),
            ],
          ),
          const SizedBox(height: 6),
          Text(card.filename, style: TextStyle(fontSize: 12, color: dso.body)),
          if (card.truncatedWarning != null) ...<Widget>[
            const SizedBox(height: 6),
            Text(
              card.truncatedWarning!,
              style: TextStyle(fontSize: 12, color: dso.warningText),
            ),
          ],
          const SizedBox(height: 10),
          Row(
            children: <Widget>[
              FilledButton(
                onPressed: busy ? null : onConfirm,
                style: FilledButton.styleFrom(
                  backgroundColor: dso.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Download CSV'),
              ),
              const SizedBox(width: 4),
              TextButton(
                onPressed: busy ? null : onCancel,
                style: TextButton.styleFrom(foregroundColor: dso.body),
                child: const Text('Cancel'),
              ),
              const Spacer(),
              if (expiresAt != null) CopilotCountdown(expiresAt: expiresAt!),
            ],
          ),
        ],
      ),
    );
  }
}
