import 'package:flutter/material.dart';

import '../theme/dso_theme.dart';
import 'ai_freshness_chip.dart';

enum ActionSeverity { danger, warning, neutral }

class ActionCenterTile extends StatelessWidget {
  const ActionCenterTile({
    super.key,
    required this.icon,
    required this.title,
    required this.meta,
    required this.action,
    this.risk,
    this.severity = ActionSeverity.neutral,
    this.onAction,
    this.showDivider = true,
    this.showAiFreshness = false,
    this.freshnessTimestamp,
  });

  final IconData icon;
  final String title;
  final String meta;
  final String? risk;
  final String action;
  final ActionSeverity severity;
  final VoidCallback? onAction;
  final bool showDivider;
  final bool showAiFreshness;
  final DateTime? freshnessTimestamp;

  Color _iconBackground(BuildContext context) {
    return switch (severity) {
      ActionSeverity.danger => context.dso.dangerSoft,
      ActionSeverity.warning => context.dso.warningSoft,
      ActionSeverity.neutral => context.dso.surfaceSoft,
    };
  }

  Color _iconForeground(BuildContext context) {
    return switch (severity) {
      ActionSeverity.danger => context.dso.dangerText,
      ActionSeverity.warning => context.dso.warningText,
      ActionSeverity.neutral => context.dso.muted,
    };
  }

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 18, vertical: 15),
      decoration: BoxDecoration(
        border: showDivider
            ? Border(bottom: BorderSide(color: scheme.outlineVariant))
            : null,
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 38,
            height: 38,
            decoration: BoxDecoration(
              color: _iconBackground(context),
              borderRadius: BorderRadius.circular(11),
            ),
            child: Icon(icon, size: 20, color: _iconForeground(context)),
          ),
          const SizedBox(width: 13),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w600,
                    color: scheme.onSurface,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  meta,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: TextStyle(
                    fontSize: 12,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                if (showAiFreshness) ...<Widget>[
                  const SizedBox(height: 5),
                  AiFreshnessChip(
                    hasData: true,
                    timestamps: <DateTime?>[freshnessTimestamp],
                    hasMissingTimestamp: freshnessTimestamp == null,
                  ),
                ],
              ],
            ),
          ),
          if (risk != null) ...<Widget>[
            const SizedBox(width: 12),
            Column(
              crossAxisAlignment: CrossAxisAlignment.end,
              children: <Widget>[
                Text(
                  'AT RISK',
                  style: TextStyle(
                    fontSize: 10,
                    letterSpacing: 0.4,
                    color: scheme.onSurfaceVariant,
                  ),
                ),
                Text(
                  risk!,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: const TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: DsoTokens.danger,
                  ),
                ),
              ],
            ),
          ],
          const SizedBox(width: 12),
          OutlinedButton(
            onPressed: onAction,
            style: OutlinedButton.styleFrom(
              foregroundColor: scheme.onSurface,
              side: BorderSide(color: scheme.outlineVariant),
              padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
              shape: RoundedRectangleBorder(
                borderRadius: BorderRadius.circular(9),
              ),
              textStyle: const TextStyle(
                fontSize: 12.5,
                fontWeight: FontWeight.w600,
              ),
            ),
            child: Text(action),
          ),
        ],
      ),
    );
  }
}
