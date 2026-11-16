import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

String homeGreeting(int klHour) {
  if (klHour < 12) return 'Good morning';
  if (klHour < 18) return 'Good afternoon';
  return 'Good evening';
}

String homeDateLabel(DateTime kl, {bool weekday = true}) {
  const List<String> weekdays = <String>[
    'Monday',
    'Tuesday',
    'Wednesday',
    'Thursday',
    'Friday',
    'Saturday',
    'Sunday',
  ];
  const List<String> months = <String>[
    'January',
    'February',
    'March',
    'April',
    'May',
    'June',
    'July',
    'August',
    'September',
    'October',
    'November',
    'December',
  ];
  final String date = '${kl.day} ${months[kl.month - 1]} ${kl.year}';
  return weekday ? '${weekdays[kl.weekday - 1]}, $date' : date;
}

String homeClock(DateTime? value) {
  if (value == null) return '--:--';
  final DateTime kl = value.toUtc().add(const Duration(hours: 8));
  return '${kl.hour.toString().padLeft(2, '0')}:'
      '${kl.minute.toString().padLeft(2, '0')}';
}

class HomePeriodSwitch<T> extends StatelessWidget {
  const HomePeriodSwitch({
    super.key,
    required this.values,
    required this.labels,
    required this.selected,
    required this.onChanged,
  });

  final List<T> values;
  final List<String> labels;
  final T selected;
  final ValueChanged<T> onChanged;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Container(
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line2),
        borderRadius: ScootRadius.controlAll,
      ),
      clipBehavior: Clip.antiAlias,
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          for (int i = 0; i < values.length; i++)
            Semantics(
              button: true,
              selected: values[i] == selected,
              label: labels[i],
              excludeSemantics: true,
              child: InkWell(
                onTap: () => onChanged(values[i]),
                child: Container(
                  height: 38,
                  padding: const EdgeInsets.symmetric(horizontal: 14),
                  alignment: Alignment.center,
                  color: values[i] == selected ? c.navBg : null,
                  child: Text(
                    labels[i],
                    style: ScootType.smallStrong.copyWith(
                      color: values[i] == selected ? Colors.white : c.text2,
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

enum HomeLoad { loading, ready, failed }

class HomeKpiTile extends StatelessWidget {
  const HomeKpiTile({
    super.key,
    required this.label,
    required this.value,
    required this.sub,
    this.delta,
    this.deltaLabel = 'last 7 days vs the 7 before',
    this.load = HomeLoad.ready,
    this.incomplete = false,
    this.onRetry,
    this.action,
    this.onAction,
  });

  static const double height = 148;

  final String label;
  final String value;
  final String sub;
  final double? delta;
  final String deltaLabel;
  final HomeLoad load;
  final bool incomplete;
  final VoidCallback? onRetry;
  final String? action;
  final VoidCallback? onAction;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final bool ready = load == HomeLoad.ready && !incomplete;
    final String shownValue = load == HomeLoad.failed
        ? '—'
        : incomplete
        ? 'Incomplete'
        : value;
    final String shownSub = load == HomeLoad.failed
        ? 'Could not load. Check your connection.'
        : incomplete
        ? 'More rows than the page reads. Totals are held back.'
        : sub;
    return Semantics(
      container: true,
      label: load == HomeLoad.loading
          ? '$label: loading'
          : '$label: $shownValue. $shownSub',
      child: ExcludeSemantics(
        child: Container(
          height: height,
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 12),
          decoration: BoxDecoration(
            color: c.card,
            border: Border.all(color: c.line),
            borderRadius: ScootRadius.cardAll,
          ),
          child: load == HomeLoad.loading
              ? const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    ScootSkeleton(width: 90, height: 12),
                    SizedBox(height: 14),
                    ScootSkeleton(width: 60, height: 28),
                    SizedBox(height: 14),
                    ScootSkeleton(width: 130, height: 12),
                  ],
                )
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      label,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ScootType.caption.copyWith(color: c.muted),
                    ),
                    const SizedBox(height: 6),
                    FittedBox(
                      fit: BoxFit.scaleDown,
                      alignment: Alignment.centerLeft,
                      child: Text(
                        shownValue,
                        maxLines: 1,
                        style: ScootType.kpi.copyWith(color: c.ink),
                      ),
                    ),
                    const SizedBox(height: 4),
                    Text(
                      shownSub,
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      style: ScootType.caption.copyWith(color: c.muted),
                    ),
                    const Spacer(),
                    if (load == HomeLoad.failed && onRetry != null)
                      _LinkButton(label: 'Retry', onTap: onRetry!)
                    else if (ready && delta != null)
                      Text.rich(
                        TextSpan(
                          children: <InlineSpan>[
                            TextSpan(
                              text: _signed(delta!),
                              style: ScootType.caption.copyWith(
                                fontWeight: FontWeight.w700,
                                color: delta! >= 0
                                    ? c.success.foreground
                                    : c.danger.foreground,
                              ),
                            ),
                            TextSpan(
                              text: ' $deltaLabel',
                              style: ScootType.caption.copyWith(
                                color: c.muted,
                              ),
                            ),
                          ],
                        ),
                        maxLines: 2,
                        overflow: TextOverflow.ellipsis,
                      )
                    else if (ready && action != null && onAction != null)
                      _LinkButton(label: action!, onTap: onAction!),
                  ],
                ),
        ),
      ),
    );
  }

  static String _signed(double value) {
    final String text = value.abs().toStringAsFixed(0);
    return value >= 0 ? '+$text %' : '-$text %';
  }
}

class _LinkButton extends StatelessWidget {
  const _LinkButton({required this.label, required this.onTap});

  final String label;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Align(
      alignment: Alignment.centerLeft,
      child: InkWell(
        onTap: onTap,
        child: Text(
          label,
          style: ScootType.caption.copyWith(
            color: c.brandText,
            fontWeight: FontWeight.w700,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}

class HomeTileGrid extends StatelessWidget {
  const HomeTileGrid({
    super.key,
    required this.tiles,
    required this.columns,
    this.gap = 14,
  });

  final List<Widget> tiles;
  final int columns;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final int fits = ((box.maxWidth + gap) / (170 + gap)).floor();
        final int capped = columns < fits ? columns : fits;
        final int count = tiles.isEmpty
            ? 1
            : (capped < tiles.length ? capped : tiles.length).clamp(1, 12);
        final double width = (box.maxWidth - gap * (count - 1)) / count;
        return Wrap(
          spacing: gap,
          runSpacing: gap,
          children: <Widget>[
            for (final Widget tile in tiles) SizedBox(width: width, child: tile),
          ],
        );
      },
    );
  }
}

class HomeStillLoading extends StatelessWidget {
  const HomeStillLoading({super.key, required this.onRetry});

  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    return ScootLoadingState(
      skeleton: const SizedBox.shrink(),
      onRetry: onRetry,
      semanticLabel: 'Loading the home page',
    );
  }
}

class HomeRowAction extends StatelessWidget {
  const HomeRowAction({
    super.key,
    required this.label,
    required this.onPressed,
    this.primary = false,
  });

  final String label;
  final VoidCallback? onPressed;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    return primary
        ? FilledButton(onPressed: onPressed, child: Text(label))
        : OutlinedButton(onPressed: onPressed, child: Text(label));
  }
}

class HomeNeedRow extends StatelessWidget {
  const HomeNeedRow({
    super.key,
    required this.count,
    required this.tone,
    required this.title,
    required this.detail,
    required this.action,
    required this.onAction,
    this.primary = false,
  });

  final int count;
  final ScootTone tone;
  final String title;
  final String detail;
  final String action;
  final VoidCallback? onAction;
  final bool primary;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final ScootToneColors t = c.tone(tone);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Container(
            width: 36,
            height: 36,
            decoration: BoxDecoration(
              color: t.background,
              borderRadius: BorderRadius.circular(8),
            ),
            alignment: Alignment.center,
            child: Text(
              '$count',
              style: ScootType.bodyStrong.copyWith(color: t.foreground),
            ),
          ),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
                const SizedBox(height: 2),
                Text(
                  detail,
                  maxLines: 2,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.caption.copyWith(color: c.muted),
                ),
              ],
            ),
          ),
          const SizedBox(width: 12),
          HomeRowAction(
            label: action,
            onPressed: onAction,
            primary: primary,
          ),
        ],
      ),
    );
  }
}

class HomeRowSkeletons extends StatelessWidget {
  const HomeRowSkeletons({super.key, this.rows = 3, this.rowHeight = 60});

  final int rows;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Loading',
      excludeSemantics: true,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows; i++)
            SizedBox(
              height: rowHeight,
              child: const Row(
                children: <Widget>[
                  ScootSkeleton(width: 36, height: 36, radius: 8),
                  SizedBox(width: 14),
                  Expanded(child: ScootSkeletonLines(widthFactors: <double>[0.7, 0.45])),
                ],
              ),
            ),
        ],
      ),
    );
  }
}

class HomeCardLink extends StatelessWidget {
  const HomeCardLink({super.key, required this.label, required this.onTap});

  final String label;
  final VoidCallback? onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return InkWell(
      onTap: onTap,
      child: Padding(
        padding: const EdgeInsets.symmetric(vertical: 6),
        child: Text(
          label,
          style: ScootType.smallStrong.copyWith(
            color: c.brandText,
            decoration: TextDecoration.underline,
          ),
        ),
      ),
    );
  }
}

class HomeFieldRow extends StatelessWidget {
  const HomeFieldRow({
    super.key,
    required this.lead,
    required this.title,
    required this.sub,
    this.badge,
  });

  final String lead;
  final String title;
  final String sub;
  final Widget? badge;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 11),
      child: Row(
        children: <Widget>[
          SizedBox(
            width: 82,
            child: Text(
              lead,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: ScootType.caption.copyWith(
                color: c.muted,
                fontFeatures: ScootType.tabular,
              ),
            ),
          ),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  title,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
                Text(
                  sub,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.caption.copyWith(color: c.muted),
                ),
              ],
            ),
          ),
          if (badge != null) ...<Widget>[const SizedBox(width: 10), badge!],
        ],
      ),
    );
  }
}

class HomeDivided extends StatelessWidget {
  const HomeDivided({super.key, required this.children});

  final List<Widget> children;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Column(
      children: <Widget>[
        for (int i = 0; i < children.length; i++) ...<Widget>[
          if (i > 0) Divider(height: 1, thickness: 1, color: c.hair),
          children[i],
        ],
      ],
    );
  }
}

class HomeMiniColumn<T> {
  const HomeMiniColumn({
    required this.label,
    required this.cell,
    this.flex = 1,
    this.numeric = false,
  });

  final String label;
  final Widget Function(BuildContext context, T row) cell;
  final int flex;
  final bool numeric;
}

class HomeMiniTable<T> extends StatelessWidget {
  const HomeMiniTable({
    super.key,
    required this.columns,
    required this.rows,
    this.rowHeight = 56,
  });

  final List<HomeMiniColumn<T>> columns;
  final List<T> rows;
  final double rowHeight;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    Widget cell(HomeMiniColumn<T> column, Widget child) => Expanded(
      flex: column.flex,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12),
        child: Align(
          alignment: column.numeric
              ? Alignment.centerRight
              : Alignment.centerLeft,
          child: child,
        ),
      ),
    );
    return Column(
      children: <Widget>[
        Container(
          height: ScootSize.tableHeader,
          color: c.tableHead,
          child: Row(
            children: <Widget>[
              for (final HomeMiniColumn<T> column in columns)
                cell(
                  column,
                  Text(
                    column.label,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: ScootType.tableHead.copyWith(color: c.tableHeadText),
                  ),
                ),
            ],
          ),
        ),
        for (final T row in rows)
          Container(
            height: rowHeight,
            decoration: BoxDecoration(
              border: Border(top: BorderSide(color: c.hair)),
            ),
            child: Row(
              children: <Widget>[
                for (final HomeMiniColumn<T> column in columns)
                  cell(
                    column,
                    DefaultTextStyle.merge(
                      style: ScootType.body.copyWith(color: c.ink),
                      maxLines: 2,
                      overflow: TextOverflow.ellipsis,
                      child: column.cell(context, row),
                    ),
                  ),
              ],
            ),
          ),
      ],
    );
  }
}
