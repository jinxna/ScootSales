import 'package:flutter/material.dart';

import '../common/pressable.dart';
import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

enum ScootSyncKind { synced, sending, offline, cached, stillLoading }

@immutable
class ScootSyncStatus {
  const ScootSyncStatus._(this.kind, this.word, this.detail);

  const ScootSyncStatus.synced(String time)
    : this._(ScootSyncKind.synced, 'Synced', time);

  const ScootSyncStatus.sending(int count)
    : this._(
        ScootSyncKind.sending,
        'Sending',
        count == 1 ? '1 update' : '$count updates',
      );

  const ScootSyncStatus.offline(String kept)
    : this._(ScootSyncKind.offline, 'Offline.', kept);

  const ScootSyncStatus.cached(String time)
    : this._(ScootSyncKind.cached, 'Saved data', 'from $time');

  const ScootSyncStatus.stillLoading()
    : this._(
        ScootSyncKind.stillLoading,
        'Still loading.',
        'Showing saved data.',
      );

  final ScootSyncKind kind;
  final String word;
  final String detail;
}

enum ScootGpsKind { good, weak, off, workNotStarted, unknown }

@immutable
class ScootGpsStatus {
  const ScootGpsStatus._(this.kind, this.accuracyMeters);

  factory ScootGpsStatus.fix(int accuracyMeters) {
    if (accuracyMeters <= 0) {
      return const ScootGpsStatus._(ScootGpsKind.unknown, 0);
    }
    return ScootGpsStatus._(
      accuracyMeters > weakAboveMeters ? ScootGpsKind.weak : ScootGpsKind.good,
      accuracyMeters,
    );
  }

  const ScootGpsStatus.off() : this._(ScootGpsKind.off, 0);

  const ScootGpsStatus.workNotStarted()
    : this._(ScootGpsKind.workNotStarted, 0);

  static const int weakAboveMeters = 50;

  final ScootGpsKind kind;
  final int accuracyMeters;

  String get label {
    switch (kind) {
      case ScootGpsKind.good:
        return 'GPS ±$accuracyMeters m';
      case ScootGpsKind.weak:
        return 'GPS weak ±$accuracyMeters m';
      case ScootGpsKind.off:
        return 'GPS off';
      case ScootGpsKind.workNotStarted:
        return 'Work not started';
      case ScootGpsKind.unknown:
        return 'GPS accuracy unknown';
    }
  }

  ScootTone get tone {
    switch (kind) {
      case ScootGpsKind.good:
        return ScootTone.success;
      case ScootGpsKind.weak:
      case ScootGpsKind.workNotStarted:
        return ScootTone.warning;
      case ScootGpsKind.off:
        return ScootTone.danger;
      case ScootGpsKind.unknown:
        return ScootTone.neutral;
    }
  }

  IconData get icon {
    switch (kind) {
      case ScootGpsKind.good:
        return ScootIcons.locationFixed;
      case ScootGpsKind.weak:
        return ScootIcons.locationSearching;
      case ScootGpsKind.off:
        return ScootIcons.locationOff;
      case ScootGpsKind.workNotStarted:
        return ScootIcons.play;
      case ScootGpsKind.unknown:
        return ScootIcons.help;
    }
  }
}

class ScootStatusStrip extends StatelessWidget {
  const ScootStatusStrip({
    super.key,
    required this.sync,
    required this.gps,
    required this.onTap,
    this.onRetry,
  });

  final ScootSyncStatus sync;
  final ScootGpsStatus gps;
  final VoidCallback onTap;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Color bg;
    final Color fg;
    final Color iconColor;
    final Color border;
    final IconData icon;
    switch (sync.kind) {
      case ScootSyncKind.synced:
        bg = c.card;
        fg = c.ink;
        iconColor = c.success.foreground;
        border = c.line;
        icon = ScootIcons.cloudDone;
      case ScootSyncKind.sending:
        bg = c.info.background;
        fg = c.info.foreground;
        iconColor = c.info.foreground;
        border = c.info.border;
        icon = ScootIcons.cloudUpload;
      case ScootSyncKind.offline:
        bg = c.warning.noteBackground;
        fg = c.warning.noteText;
        iconColor = c.warning.noteText;
        border = c.warning.border;
        icon = ScootIcons.cloudOff;
      case ScootSyncKind.cached:
        bg = c.neutral.background;
        fg = c.neutral.foreground;
        iconColor = c.neutral.foreground;
        border = c.line;
        icon = ScootIcons.history;
      case ScootSyncKind.stillLoading:
        bg = c.neutral.background;
        fg = c.neutral.foreground;
        iconColor = c.neutral.foreground;
        border = c.line;
        icon = ScootIcons.hourglass;
    }
    final bool showRetry =
        sync.kind == ScootSyncKind.stillLoading && onRetry != null;
    return Container(
      constraints: const BoxConstraints(minHeight: ScootSize.statusStrip),
      decoration: BoxDecoration(
        color: bg,
        border: Border(bottom: BorderSide(color: border)),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: ScootPressable(
              onTap: onTap,
              borderRadius: BorderRadius.zero,
              minSize: const Size(0, ScootSize.statusStrip - 1),
              semanticLabel:
                  'Sync and location. ${sync.word} ${sync.detail}${showRetry ? '' : '. ${gps.label}'}',
              child: Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: ScootSpace.phoneGutter,
                  vertical: 6,
                ),
                child: Row(
                  children: <Widget>[
                    Icon(icon, size: 18, color: iconColor),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: sync.word,
                              style: TextStyle(
                                fontWeight: FontWeight.w700,
                                color: sync.kind == ScootSyncKind.synced
                                    ? c.brandText
                                    : null,
                              ),
                            ),
                            TextSpan(text: ' ${sync.detail}'),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                        style: ScootType.small.copyWith(color: fg),
                      ),
                    ),
                    if (!showRetry) ...<Widget>[
                      const SizedBox(width: 8),
                      ScootGpsChip(status: gps),
                    ],
                  ],
                ),
              ),
            ),
          ),
          if (showRetry)
            Padding(
              padding: const EdgeInsets.only(right: 8),
              child: ScootPressable(
                onTap: onRetry,
                minSize: const Size.square(ScootSize.phoneTarget),
                borderRadius: ScootRadius.pillAll,
                semanticLabel: 'Retry loading',
                child: SizedBox(
                  height: ScootSize.statusStrip - 1,
                  child: Center(
                    widthFactor: 1,
                    child: Container(
                      height: ScootSize.gpsChip + 2,
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      decoration: BoxDecoration(
                        color: c.card,
                        border: Border.all(color: c.line2),
                        borderRadius: ScootRadius.pillAll,
                      ),
                      child: Row(
                        mainAxisSize: MainAxisSize.min,
                        children: <Widget>[
                          Icon(ScootIcons.refresh, size: 16, color: c.ink),
                          const SizedBox(width: 6),
                          Text(
                            'Retry',
                            style: ScootType.smallStrong.copyWith(color: c.ink),
                          ),
                        ],
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class ScootGpsChip extends StatelessWidget {
  const ScootGpsChip({super.key, required this.status});

  final ScootGpsStatus status;

  @override
  Widget build(BuildContext context) {
    final ScootToneColors t = ScootColors.of(context).tone(status.tone);
    return Container(
      height: ScootSize.gpsChip,
      padding: const EdgeInsets.symmetric(horizontal: 10),
      decoration: BoxDecoration(
        color: t.background,
        borderRadius: ScootRadius.pillAll,
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(status.icon, size: 14, color: t.foreground),
          const SizedBox(width: 6),
          Text(
            status.label,
            style: ScootType.caption.copyWith(
              color: t.foreground,
              fontWeight: FontWeight.w700,
            ),
          ),
        ],
      ),
    );
  }
}
