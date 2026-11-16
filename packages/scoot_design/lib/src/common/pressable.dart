import 'package:flutter/material.dart';

import 'focus_ring.dart';

class ScootPressable extends StatelessWidget {
  const ScootPressable({
    super.key,
    required this.child,
    required this.onTap,
    required this.minSize,
    this.semanticLabel,
    this.selected,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.color,
    this.hoverColor,
    this.focusRingColor,
    this.tooltip,
  });

  final Widget child;
  final VoidCallback? onTap;
  final Size minSize;
  final String? semanticLabel;
  final bool? selected;
  final BorderRadius borderRadius;
  final Color? color;
  final Color? hoverColor;
  final Color? focusRingColor;
  final String? tooltip;

  @override
  Widget build(BuildContext context) {
    Widget result = ScootFocusRing(
      borderRadius: borderRadius,
      color: focusRingColor,
      child: Material(
        color: color ?? Colors.transparent,
        borderRadius: borderRadius,
        child: InkWell(
          onTap: onTap,
          borderRadius: borderRadius,
          hoverColor: hoverColor,
          focusColor: hoverColor,
          child: ConstrainedBox(
            constraints: BoxConstraints(
              minWidth: minSize.width,
              minHeight: minSize.height,
            ),
            child: child,
          ),
        ),
      ),
    );
    if (tooltip != null) {
      result = Tooltip(message: tooltip, child: result);
    }
    return Semantics(
      button: true,
      enabled: onTap != null,
      selected: selected,
      label: semanticLabel,
      excludeSemantics: semanticLabel != null,
      child: result,
    );
  }
}
