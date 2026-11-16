import 'package:flutter/material.dart';

import '../common/badges.dart';
import '../common/pressable.dart';
import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

enum ScootBannerPriority {
  companyPaused,
  locationOff,
  preciseLocationOff,
  workNotStarted,
  rejectedOrder,
  workNeedsAttention,
  companyActiveAgain,
  clockWrong,
  batterySaver,
  gpsBacklog,
}

@immutable
class ScootActionBannerData {
  const ScootActionBannerData({
    required this.priority,
    required this.title,
    this.message,
    this.actionLabel,
    this.onAction,
  });

  final ScootBannerPriority priority;
  final String title;
  final String? message;
  final String? actionLabel;
  final VoidCallback? onAction;

  ScootTone get tone {
    switch (priority) {
      case ScootBannerPriority.companyPaused:
      case ScootBannerPriority.locationOff:
      case ScootBannerPriority.rejectedOrder:
        return ScootTone.danger;
      case ScootBannerPriority.preciseLocationOff:
      case ScootBannerPriority.workNotStarted:
      case ScootBannerPriority.workNeedsAttention:
      case ScootBannerPriority.clockWrong:
      case ScootBannerPriority.batterySaver:
      case ScootBannerPriority.gpsBacklog:
        return ScootTone.warning;
      case ScootBannerPriority.companyActiveAgain:
        return ScootTone.success;
    }
  }

  IconData get icon {
    switch (priority) {
      case ScootBannerPriority.companyPaused:
        return ScootIcons.paused;
      case ScootBannerPriority.locationOff:
        return ScootIcons.locationOff;
      case ScootBannerPriority.preciseLocationOff:
        return ScootIcons.locationSearching;
      case ScootBannerPriority.workNotStarted:
        return ScootIcons.play;
      case ScootBannerPriority.rejectedOrder:
        return ScootIcons.rejected;
      case ScootBannerPriority.workNeedsAttention:
        return ScootIcons.paused;
      case ScootBannerPriority.companyActiveAgain:
        return ScootIcons.success;
      case ScootBannerPriority.clockWrong:
        return ScootIcons.clock;
      case ScootBannerPriority.batterySaver:
        return ScootIcons.battery;
      case ScootBannerPriority.gpsBacklog:
        return ScootIcons.locationOff;
    }
  }
}

class ScootActionBanner extends StatelessWidget {
  const ScootActionBanner({super.key, required this.data});

  final ScootActionBannerData data;

  static ScootActionBannerData? pick(Iterable<ScootActionBannerData> active) {
    ScootActionBannerData? best;
    for (final ScootActionBannerData item in active) {
      if (best == null || item.priority.index < best.priority.index) {
        best = item;
      }
    }
    return best;
  }

  @override
  Widget build(BuildContext context) {
    final ScootToneColors t = ScootColors.of(context).tone(data.tone);
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
        decoration: BoxDecoration(
          color: t.background,
          border: Border.all(color: t.border),
          borderRadius: ScootRadius.cardAll,
        ),
        child: Row(
          crossAxisAlignment: CrossAxisAlignment.center,
          children: <Widget>[
            Icon(data.icon, size: 18, color: t.foreground),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  Text(
                    data.title,
                    style: ScootType.bodyStrong.copyWith(color: t.foreground),
                  ),
                  if (data.message != null)
                    Text(
                      data.message!,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ScootType.body.copyWith(color: t.noteText),
                    ),
                ],
              ),
            ),
            if (data.actionLabel != null && data.onAction != null) ...<Widget>[
              const SizedBox(width: 10),
              OutlinedButton(
                onPressed: data.onAction,
                style: OutlinedButton.styleFrom(
                  foregroundColor: t.foreground,
                  side: BorderSide(color: t.foreground),
                ),
                child: Text(data.actionLabel!),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

enum ScootPhoneTab { home, route, orders, profile }

class ScootBottomNav extends StatelessWidget {
  const ScootBottomNav({
    super.key,
    required this.current,
    required this.onSelect,
    this.ordersWaiting = 0,
  });

  final ScootPhoneTab current;
  final ValueChanged<ScootPhoneTab> onSelect;
  final int ordersWaiting;

  static const Map<ScootPhoneTab, String> labels = <ScootPhoneTab, String>{
    ScootPhoneTab.home: 'Home',
    ScootPhoneTab.route: 'Route',
    ScootPhoneTab.orders: 'Orders',
    ScootPhoneTab.profile: 'Profile',
  };

  static const Map<ScootPhoneTab, IconData> icons = <ScootPhoneTab, IconData>{
    ScootPhoneTab.home: ScootIcons.home,
    ScootPhoneTab.route: ScootIcons.route,
    ScootPhoneTab.orders: ScootIcons.orders,
    ScootPhoneTab.profile: ScootIcons.person,
  };

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      padding: EdgeInsets.only(
        bottom: MediaQuery.viewPaddingOf(context).bottom,
      ),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: ScootSize.bottomNav - 1),
        child: Row(
          children: <Widget>[
            for (final ScootPhoneTab tab in ScootPhoneTab.values)
              Expanded(child: _item(c, tab)),
          ],
        ),
      ),
    );
  }

  Widget _item(ScootColors c, ScootPhoneTab tab) {
    final bool active = tab == current;
    final Color fg = active ? c.success.foreground : c.muted;
    final bool showCount = tab == ScootPhoneTab.orders && ordersWaiting > 0;
    final String waiting = ordersWaiting == 1
        ? '1 order waiting to send'
        : '$ordersWaiting orders waiting to send';
    return ScootPressable(
      onTap: () => onSelect(tab),
      selected: active,
      borderRadius: ScootRadius.controlAll,
      minSize: const Size(ScootSize.phoneTarget, ScootSize.bottomNav - 1),
      semanticLabel:
          '${labels[tab]}${showCount ? ', $waiting' : ''}${active ? ', current tab' : ''}',
      child: Center(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Stack(
              clipBehavior: Clip.none,
              children: <Widget>[
                Container(
                  width: 56,
                  height: 30,
                  decoration: BoxDecoration(
                    color: active ? c.success.background : Colors.transparent,
                    borderRadius: ScootRadius.pillAll,
                  ),
                  child: Icon(icons[tab], size: ScootSize.phoneIcon, color: fg),
                ),
                if (showCount)
                  Positioned(
                    top: -4,
                    right: 2,
                    child: ScootCountBadge(
                      count: ordersWaiting,
                      semanticLabel: waiting,
                    ),
                  ),
              ],
            ),
            const SizedBox(height: 4),
            Text(
              labels[tab]!,
              style: ScootType.phoneNav.copyWith(
                color: fg,
                fontWeight: active ? FontWeight.w600 : FontWeight.w500,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class ScootPrimaryActionBar extends StatelessWidget {
  const ScootPrimaryActionBar({
    super.key,
    required this.label,
    required this.onPressed,
    this.icon,
    this.note,
    this.disabledReason,
    this.secondaryLabel,
    this.onSecondary,
    this.aboveHomeIndicator = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final IconData? icon;
  final String? note;
  final String? disabledReason;
  final String? secondaryLabel;
  final VoidCallback? onSecondary;
  final bool aboveHomeIndicator;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final String? line = onPressed == null ? (disabledReason ?? note) : note;
    final double bottomInset = aboveHomeIndicator
        ? MediaQuery.viewPaddingOf(context).bottom
        : 0;
    final TextStyle buttonText = Theme.of(
      context,
    ).textTheme.labelLarge!.merge(ScootType.phoneButton);
    final ButtonStyle big = FilledButton.styleFrom(
      minimumSize: const Size.fromHeight(ScootSize.primaryButton),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      textStyle: buttonText,
    );
    return Container(
      padding: EdgeInsets.fromLTRB(16, 12, 16, 12 + bottomInset),
      decoration: BoxDecoration(
        color: c.card,
        border: Border(top: BorderSide(color: c.line)),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (line != null) ...<Widget>[
            if (onPressed == null && disabledReason != null)
              Row(
                children: <Widget>[
                  Icon(ScootIcons.info, size: 16, color: c.warning.noteText),
                  const SizedBox(width: 8),
                  Expanded(
                    child: Text(
                      line,
                      style: ScootType.small.copyWith(
                        color: c.warning.noteText,
                      ),
                    ),
                  ),
                ],
              )
            else
              Text(line, style: ScootType.small.copyWith(color: c.text2)),
            const SizedBox(height: 8),
          ],
          Row(
            children: <Widget>[
              if (secondaryLabel != null && onSecondary != null) ...<Widget>[
                Flexible(
                  flex: 4,
                  child: OutlinedButton(
                    onPressed: onSecondary,
                    style: OutlinedButton.styleFrom(
                      minimumSize: const Size(96, ScootSize.primaryButton),
                      padding: const EdgeInsets.symmetric(horizontal: 12),
                      textStyle: buttonText,
                    ),
                    child: Text(
                      secondaryLabel!,
                      maxLines: 2,
                      textAlign: TextAlign.center,
                    ),
                  ),
                ),
                const SizedBox(width: 12),
              ],
              Expanded(
                flex: 5,
                child: icon == null
                    ? FilledButton(
                        onPressed: onPressed,
                        style: big,
                        child: Text(
                          label,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                        ),
                      )
                    : FilledButton.icon(
                        onPressed: onPressed,
                        style: big,
                        icon: Icon(icon, size: 20),
                        label: Text(
                          label,
                          maxLines: 2,
                          textAlign: TextAlign.center,
                        ),
                      ),
              ),
            ],
          ),
        ],
      ),
    );
  }
}

class ScootStepBar extends StatelessWidget {
  const ScootStepBar({
    super.key,
    required this.current,
    this.steps = const <String>['Select', 'Count', 'Sign'],
  }) : assert(current >= 0);

  final List<String> steps;
  final int current;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      label: 'Step ${current + 1} of ${steps.length}, ${steps[current]}',
      excludeSemantics: true,
      child: Container(
        height: ScootSize.stepBar,
        decoration: BoxDecoration(
          color: c.card,
          border: Border(bottom: BorderSide(color: c.line)),
        ),
        child: Row(
          children: <Widget>[
            for (int i = 0; i < steps.length; i++)
              Expanded(child: _segment(c, i)),
          ],
        ),
      ),
    );
  }

  Widget _segment(ScootColors c, int index) {
    final bool done = index < current;
    final bool now = index == current;
    final Color fg = done
        ? c.success.foreground
        : now
        ? c.brandText
        : c.muted;
    final Widget marker = done
        ? Container(
            width: 20,
            height: 20,
            decoration: BoxDecoration(
              color: c.success.background,
              shape: BoxShape.circle,
            ),
            child: Icon(ScootIcons.check, size: 14, color: fg),
          )
        : Container(
            width: 20,
            height: 20,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: now ? c.brand : Colors.transparent,
              shape: BoxShape.circle,
              border: now ? null : Border.all(color: c.muted, width: 1.5),
            ),
            child: Text(
              '${index + 1}',
              style: ScootType.caption.copyWith(
                fontSize: 11,
                color: now ? c.onBrand : c.muted,
                fontWeight: FontWeight.w700,
              ),
            ),
          );
    return Stack(
      children: <Widget>[
        Center(
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              marker,
              const SizedBox(width: 8),
              Flexible(
                child: Text(
                  steps[index],
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.body.copyWith(
                    color: fg,
                    fontWeight: now || done ? FontWeight.w600 : FontWeight.w400,
                  ),
                ),
              ),
            ],
          ),
        ),
        if (now)
          Positioned(
            left: 12,
            right: 12,
            bottom: 0,
            child: Container(
              height: 3,
              decoration: BoxDecoration(
                color: c.brand,
                borderRadius: const BorderRadius.vertical(
                  top: Radius.circular(3),
                ),
              ),
            ),
          ),
      ],
    );
  }
}

class ScootPhoneScaffold extends StatelessWidget {
  const ScootPhoneScaffold({
    super.key,
    required this.appBar,
    required this.body,
    this.statusStrip,
    this.stepBar,
    this.banner,
    this.primaryAction,
    this.bottomNav,
  });

  final PreferredSizeWidget appBar;
  final Widget body;
  final Widget? statusStrip;
  final Widget? stepBar;
  final ScootActionBannerData? banner;
  final Widget? primaryAction;
  final Widget? bottomNav;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Widget? bottom = primaryAction == null && bottomNav == null
        ? null
        : Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[?primaryAction, ?bottomNav],
          );
    final Widget? safeBottom = bottom == null
        ? null
        : SafeArea(top: false, bottom: false, child: bottom);
    return Scaffold(
      backgroundColor: c.page,
      appBar: appBar,
      bottomNavigationBar: safeBottom,
      body: SafeArea(
        top: false,
        bottom: false,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            ?stepBar,
            ?statusStrip,
            if (banner != null)
              Padding(
                padding: const EdgeInsets.fromLTRB(
                  ScootSpace.phoneGutter,
                  12,
                  ScootSpace.phoneGutter,
                  0,
                ),
                child: ScootActionBanner(data: banner!),
              ),
            Expanded(child: body),
          ],
        ),
      ),
    );
  }
}
