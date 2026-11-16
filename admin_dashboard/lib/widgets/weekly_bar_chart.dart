import 'package:flutter/material.dart';

import '../theme/dso_theme.dart';

class WeeklyBar {
  const WeeklyBar(this.label, this.value, {this.highlight = false});

  final String label;
  final double value;
  final bool highlight;
}

class WeeklyBarChart extends StatelessWidget {
  const WeeklyBarChart({super.key, required this.data, this.height = 120});

  final List<WeeklyBar> data;
  final double height;

  @override
  Widget build(BuildContext context) {
    final Color labelColor = Theme.of(context).colorScheme.onSurfaceVariant;
    final double maxValue = data
        .map((WeeklyBar item) => item.value)
        .fold<double>(1, (double a, double b) => a > b ? a : b);

    return SizedBox(
      height: height,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.end,
        children: <Widget>[
          for (final WeeklyBar item in data)
            Expanded(
              child: Column(
                mainAxisAlignment: MainAxisAlignment.end,
                children: <Widget>[
                  Text(
                    item.value.toStringAsFixed(0),
                    style: TextStyle(
                      fontSize: 12,
                      fontWeight: FontWeight.w600,
                      color: labelColor,
                    ),
                  ),
                  const SizedBox(height: 8),
                  Expanded(
                    child: Align(
                      alignment: Alignment.bottomCenter,
                      child: FractionallySizedBox(
                        heightFactor: (item.value / maxValue).clamp(0.04, 1),
                        child: Container(
                          width: 22,
                          decoration: BoxDecoration(
                            color: item.highlight
                                ? DsoTokens.green600
                                : DsoTokens.green500.withValues(alpha: 0.55),
                            borderRadius: const BorderRadius.vertical(
                              top: Radius.circular(6),
                              bottom: Radius.circular(3),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                  const SizedBox(height: 8),
                  Text(
                    item.label,
                    style: TextStyle(fontSize: 12, color: labelColor),
                  ),
                ],
              ),
            ),
        ],
      ),
    );
  }
}
