import 'package:flutter/material.dart';

class CountUpText extends StatelessWidget {
  const CountUpText(this.value, {super.key, this.style, this.maxLines = 1});

  final String value;
  final TextStyle? style;
  final int maxLines;

  static const List<FontFeature> _tabular = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  @override
  Widget build(BuildContext context) {
    final TextStyle base = (style ?? DefaultTextStyle.of(context).style)
        .copyWith(fontFeatures: _tabular);
    final int? target = int.tryParse(value);
    final bool still = MediaQuery.maybeOf(context)?.disableAnimations ?? false;
    if (target == null || still) {
      return Text(
        value,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        style: base,
      );
    }
    return Semantics(
      label: value,
      excludeSemantics: true,
      child: TweenAnimationBuilder<double>(
        tween: Tween<double>(begin: 0, end: target.toDouble()),
        duration: const Duration(milliseconds: 600),
        curve: Curves.easeOutCubic,
        builder: (BuildContext context, double shown, Widget? _) => Text(
          '${shown.round()}',
          maxLines: maxLines,
          overflow: TextOverflow.ellipsis,
          style: base,
        ),
      ),
    );
  }
}
