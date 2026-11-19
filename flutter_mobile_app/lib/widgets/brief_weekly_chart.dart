import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/stop_brief_view.dart';
import '../models/visit_brief.dart';
import '../theme/app_theme.dart';

String briefWeekSemantics(BriefWeek week, String unit) =>
    'Week of ${DateFormat('d MMM').format(week.weekStart)}: '
    '${briefQuantity(week.quantity, unit)}';

class BriefWeeklyChart extends StatelessWidget {
  const BriefWeeklyChart({super.key, required this.weeks, required this.unit});

  static const double _barArea = 72;
  static const Color _bar = Color(0xFF6D28D9);
  static const Color _empty = Color(0xFFB42318);

  final List<BriefWeek> weeks;
  final String unit;

  @override
  Widget build(BuildContext context) {
    if (weeks.isEmpty) return const SizedBox.shrink();
    final double peak = weeks.fold<double>(
      0,
      (double top, BriefWeek week) => week.quantity > top ? week.quantity : top,
    );
    final String plural = briefUnitPlural(unit);
    final String legend = plural.isEmpty
        ? 'Units ordered each week'
        : '${plural.substring(0, 1).toUpperCase()}${plural.substring(1)} '
              'ordered each week';
    const TextStyle small = TextStyle(fontSize: 10, color: AppColors.textGrey);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          crossAxisAlignment: CrossAxisAlignment.end,
          children: <Widget>[
            for (final BriefWeek week in weeks)
              Expanded(
                child: Semantics(
                  container: true,
                  label: briefWeekSemantics(week, unit),
                  child: ExcludeSemantics(
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            briefQuantity(week.quantity, ''),
                            style: TextStyle(
                              fontSize: 11,
                              fontWeight: FontWeight.w700,
                              color: week.quantity <= 0
                                  ? _empty
                                  : AppColors.textPrimary,
                            ),
                          ),
                        ),
                        const SizedBox(height: 2),
                        FractionallySizedBox(
                          widthFactor: 0.6,
                          child: Container(
                            height: week.quantity <= 0 || peak <= 0
                                ? 6
                                : (_barArea * week.quantity / peak).clamp(
                                    6.0,
                                    _barArea,
                                  ),
                            decoration: BoxDecoration(
                              color: week.quantity <= 0
                                  ? const Color(0xFFFEE4E2)
                                  : _bar,
                              border: week.quantity <= 0
                                  ? Border.all(color: _empty)
                                  : null,
                              borderRadius: const BorderRadius.vertical(
                                top: Radius.circular(3),
                              ),
                            ),
                          ),
                        ),
                        const SizedBox(height: 3),
                        FittedBox(
                          fit: BoxFit.scaleDown,
                          child: Text(
                            DateFormat('d\nMMM').format(week.weekStart),
                            textAlign: TextAlign.center,
                            style: small,
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
          ],
        ),
        const Divider(height: 8),
        Text('$legend. The date is the first day of the week.', style: small),
      ],
    );
  }
}
