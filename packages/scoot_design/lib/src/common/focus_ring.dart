import 'package:flutter/material.dart';

import '../tokens/colors.dart';

class ScootFocusRing extends StatefulWidget {
  const ScootFocusRing({
    super.key,
    required this.child,
    this.borderRadius = const BorderRadius.all(Radius.circular(8)),
    this.color,
  });

  final Widget child;
  final BorderRadius borderRadius;
  final Color? color;

  @override
  State<ScootFocusRing> createState() => _ScootFocusRingState();
}

class _ScootFocusRingState extends State<ScootFocusRing> {
  bool _focused = false;

  @override
  Widget build(BuildContext context) {
    final Color ring = widget.color ?? ScootColors.of(context).focus;
    return Focus(
      canRequestFocus: false,
      skipTraversal: true,
      onFocusChange: (bool value) => setState(() => _focused = value),
      child: CustomPaint(
        foregroundPainter: _focused
            ? _RingPainter(color: ring, radius: widget.borderRadius)
            : null,
        child: widget.child,
      ),
    );
  }
}

class _RingPainter extends CustomPainter {
  const _RingPainter({required this.color, required this.radius});

  final Color color;
  final BorderRadius radius;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = (Offset.zero & size).inflate(3);
    final RRect rrect = (radius + const BorderRadius.all(Radius.circular(3)))
        .toRRect(rect);
    canvas.drawRRect(
      rrect,
      Paint()
        ..color = color
        ..style = PaintingStyle.stroke
        ..strokeWidth = 2,
    );
  }

  @override
  bool shouldRepaint(_RingPainter oldDelegate) =>
      oldDelegate.color != color || oldDelegate.radius != radius;
}
