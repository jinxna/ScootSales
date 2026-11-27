import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../utils/count_label.dart';

class WeeklyQuantity {
  const WeeklyQuantity({required this.weekStart, required this.quantity});

  final DateTime weekStart;
  final double quantity;
}

String weeklyChartDayLabel(DateTime day) {
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${day.day} ${months[day.month - 1]}';
}

String weeklyChartQuantityLabel(double quantity) {
  return quantity == quantity.roundToDouble()
      ? quantity.round().toString()
      : quantity.toStringAsFixed(1);
}

String weeklyChartBarSemantics(
  WeeklyQuantity week,
  String unit, {
  String unitOne = 'carton',
}) {
  final String value = weeklyChartQuantityLabel(week.quantity);
  return 'Week of ${weeklyChartDayLabel(week.weekStart)}: '
      '$value ${value == '1' ? unitOne : unit}';
}

String weeklyChartRangeLabel(List<WeeklyQuantity> shown) {
  if (shown.isEmpty) return 'No weeks stored';
  final DateTime first = shown.first.weekStart;
  final DateTime last = shown.last.weekStart;
  final String firstLabel = first.year == last.year
      ? weeklyChartDayLabel(first)
      : '${weeklyChartDayLabel(first)} ${first.year}';
  return 'Weeks of $firstLabel to ${weeklyChartDayLabel(last)} ${last.year}';
}

String? weeklyChartStaleNote(List<WeeklyQuantity> shown, DateTime now) {
  if (shown.isEmpty) return null;
  final DateTime lastDay = shown.last.weekStart.add(const Duration(days: 6));
  final DateTime today = DateTime(now.year, now.month, now.day);
  if (today.difference(lastDay).inDays <= 14) return null;
  return 'These numbers end on ${weeklyChartDayLabel(lastDay)} '
      '${lastDay.year}. No newer weeks are stored.';
}

class WeeklyBarChart extends StatelessWidget {
  const WeeklyBarChart({
    super.key,
    required this.weeks,
    required this.title,
    this.unit = 'cartons',
    this.maxWeeks = 8,
    this.barAreaHeight = 140,
    this.now,
  });

  final DateTime? now;
  final List<WeeklyQuantity> weeks;
  final String title;
  final String unit;
  final int maxWeeks;
  final double barAreaHeight;

  List<WeeklyQuantity> get _shown {
    final List<WeeklyQuantity> sorted = List<WeeklyQuantity>.of(weeks)
      ..sort(
        (WeeklyQuantity a, WeeklyQuantity b) =>
            a.weekStart.compareTo(b.weekStart),
      );
    return sorted.length > maxWeeks
        ? sorted.sublist(sorted.length - maxWeeks)
        : sorted;
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final List<WeeklyQuantity> shown = _shown;
    final int emptyWeeks = shown
        .where((WeeklyQuantity w) => w.quantity <= 0)
        .length;
    final double peak = shown.fold<double>(
      0,
      (double a, WeeklyQuantity w) => w.quantity > a ? w.quantity : a,
    );
    final Color danger = c.tone(ScootTone.danger).foreground;
    final Color dangerFill = c.tone(ScootTone.danger).background;
    final String range = weeklyChartRangeLabel(shown);
    final String? staleNote = weeklyChartStaleNote(
      shown,
      now ?? DateTime.now(),
    );
    return Semantics(
      container: true,
      label: '$title. $range.',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Text(
            title,
            style: ScootType.caption.copyWith(
              color: c.muted,
              fontWeight: FontWeight.w600,
            ),
          ),
          ExcludeSemantics(
            child: Text(
              range,
              style: ScootType.caption.copyWith(color: c.muted),
            ),
          ),
          if (staleNote != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Text(
                staleNote,
                key: const ValueKey<String>('weekly-chart-stale'),
                style: ScootType.caption.copyWith(color: c.ink),
              ),
            ),
          const SizedBox(height: 10),
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints box) {
              final int slots = shown.isEmpty ? 1 : shown.length;
              final double slot = box.maxWidth / slots;
              final double barWidth = (slot * 0.62).clamp(10.0, 56.0);
              final double usable = barAreaHeight - 22;
              final TextStyle labelStyle = ScootType.caption.copyWith(
                color: c.muted,
                fontSize: 11,
              );
              final List<String> labels = <String>[
                for (final WeeklyQuantity w in shown)
                  weeklyChartDayLabel(w.weekStart),
              ];
              final double oneLineWidth = _widest(context, labels, labelStyle);
              final bool stacked = oneLineWidth > slot - 2;
              final double stackedWidth = _widest(context, <String>[
                for (final String l in labels) ...l.split(' '),
              ], labelStyle);
              final bool everyOther = stacked && stackedWidth > slot - 2;
              bool showLabel(int index) => !everyOther || index.isEven;
              return SizedBox(
                height: barAreaHeight + 24 + (stacked ? 13 : 0),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    for (final WeeklyQuantity week in shown)
                      SizedBox(
                        width: slot,
                        child: Semantics(
                          container: true,
                          label: weeklyChartBarSemantics(week, unit),
                          child: ExcludeSemantics(
                            child: Column(
                              mainAxisAlignment: MainAxisAlignment.end,
                              children: <Widget>[
                                Text(
                                  weeklyChartQuantityLabel(week.quantity),
                                  style: ScootType.caption.copyWith(
                                    color: week.quantity <= 0 ? danger : c.ink,
                                    fontWeight: FontWeight.w700,
                                  ),
                                ),
                                const SizedBox(height: 3),
                                Container(
                                  width: barWidth,
                                  height: week.quantity <= 0 || peak <= 0
                                      ? 6
                                      : (usable * week.quantity / peak).clamp(
                                          6.0,
                                          usable,
                                        ),
                                  decoration: BoxDecoration(
                                    color: week.quantity <= 0
                                        ? dangerFill
                                        : c.brand,
                                    border: week.quantity <= 0
                                        ? Border.all(color: danger)
                                        : null,
                                    borderRadius: const BorderRadius.vertical(
                                      top: Radius.circular(3),
                                    ),
                                  ),
                                ),
                                const SizedBox(height: 4),
                                if (!stacked)
                                  Text(
                                    weeklyChartDayLabel(week.weekStart),
                                    maxLines: 1,
                                    softWrap: false,
                                    style: labelStyle,
                                  )
                                else
                                  SizedBox(
                                    height: 28,
                                    child: showLabel(shown.indexOf(week))
                                        ? Text(
                                            weeklyChartDayLabel(
                                              week.weekStart,
                                            ).replaceFirst(' ', '\n'),
                                            textAlign: TextAlign.center,
                                            maxLines: 2,
                                            softWrap: false,
                                            style: labelStyle,
                                          )
                                        : null,
                                  ),
                              ],
                            ),
                          ),
                        ),
                      ),
                  ],
                ),
              );
            },
          ),
          Container(height: 1, color: c.line),
          const SizedBox(height: 8),
          Wrap(
            spacing: 14,
            runSpacing: 4,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              _legendDot(c.brand, '$unit ordered, week starting on the date'),
              if (emptyWeeks > 0)
                _legendDot(
                  danger,
                  'No orders (${countLabel(emptyWeeks, 'week')})',
                ),
            ],
          ),
        ],
      ),
    );
  }

  double _widest(BuildContext context, List<String> texts, TextStyle style) {
    final TextScaler scaler = MediaQuery.textScalerOf(context);
    double widest = 0;
    for (final String text in texts) {
      final TextPainter painter = TextPainter(
        text: TextSpan(text: text, style: style),
        textDirection: TextDirection.ltr,
        textScaler: scaler,
        maxLines: 1,
      )..layout();
      if (painter.width > widest) widest = painter.width;
      painter.dispose();
    }
    return widest;
  }

  Widget _legendDot(Color color, String label) {
    return Builder(
      builder: (BuildContext context) {
        final ScootColors c = ScootColors.of(context);
        return Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 10,
              height: 10,
              decoration: BoxDecoration(
                color: color,
                borderRadius: BorderRadius.circular(2),
              ),
            ),
            const SizedBox(width: 6),
            Flexible(
              child: Text(
                label,
                style: ScootType.caption.copyWith(color: c.muted),
              ),
            ),
          ],
        );
      },
    );
  }
}
