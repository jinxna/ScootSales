import 'package:flutter/material.dart';

const double kMinTapTarget = 44;

class AppIconButton extends StatelessWidget {
  const AppIconButton({
    super.key,
    required this.tooltip,
    required this.onPressed,
    this.icon,
    this.child,
    this.size,
    this.color,
  }) : assert(icon != null || child != null);

  final String tooltip;
  final VoidCallback? onPressed;
  final IconData? icon;
  final Widget? child;
  final double? size;
  final Color? color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      container: true,
      button: true,
      enabled: onPressed != null,
      label: tooltip,
      onTap: onPressed,
      excludeSemantics: true,
      child: IconButton(
        tooltip: tooltip,
        onPressed: onPressed,
        padding: EdgeInsets.zero,
        constraints: const BoxConstraints(
          minWidth: kMinTapTarget,
          minHeight: kMinTapTarget,
        ),
        icon: child ?? Icon(icon, size: size, color: color),
      ),
    );
  }
}
