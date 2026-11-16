import 'package:flutter/material.dart';

class HorizontalScrollCue extends StatefulWidget {
  const HorizontalScrollCue({super.key, required this.child, this.controller});

  final Widget child;
  final ScrollController? controller;

  @override
  State<HorizontalScrollCue> createState() => _HorizontalScrollCueState();
}

class _HorizontalScrollCueState extends State<HorizontalScrollCue> {
  ScrollController? _own;
  bool _moreToRight = false;

  ScrollController get _controller =>
      widget.controller ?? (_own ??= ScrollController());

  @override
  void dispose() {
    _own?.dispose();
    super.dispose();
  }

  bool _onNotification(Notification n) {
    final ScrollMetrics metrics;
    if (n is ScrollNotification && n.depth == 0) {
      metrics = n.metrics;
    } else if (n is ScrollMetricsNotification && n.depth == 0) {
      metrics = n.metrics;
    } else {
      return false;
    }
    if (metrics.axis != Axis.horizontal) return false;
    final bool more = metrics.extentAfter > 1;
    if (more != _moreToRight) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) setState(() => _moreToRight = more);
      });
    }
    return false;
  }

  @override
  Widget build(BuildContext context) {
    final Color surface = Theme.of(context).colorScheme.surface;
    return NotificationListener<Notification>(
      onNotification: _onNotification,
      child: Stack(
        children: <Widget>[
          Scrollbar(
            controller: _controller,
            thumbVisibility: true,
            notificationPredicate: (ScrollNotification n) => n.depth == 0,
            child: SingleChildScrollView(
              controller: _controller,
              scrollDirection: Axis.horizontal,
              child: StickyColumnScope(
                controller: _controller,
                child: widget.child,
              ),
            ),
          ),
          Positioned(
            top: 0,
            bottom: 0,
            right: 0,
            width: 36,
            child: IgnorePointer(
              child: AnimatedOpacity(
                opacity: _moreToRight ? 1 : 0,
                duration: const Duration(milliseconds: 150),
                child: DecoratedBox(
                  key: const ValueKey<String>('horizontal-scroll-fade'),
                  decoration: BoxDecoration(
                    gradient: LinearGradient(
                      colors: <Color>[surface.withValues(alpha: 0), surface],
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

class StickyColumnScope extends InheritedWidget {
  const StickyColumnScope({
    super.key,
    required this.controller,
    required super.child,
  });

  final ScrollController controller;

  static ScrollController? maybeOf(BuildContext context) =>
      context.getInheritedWidgetOfExactType<StickyColumnScope>()?.controller;

  @override
  bool updateShouldNotify(StickyColumnScope old) =>
      old.controller != controller;
}

class StickyColumnCell extends StatelessWidget {
  const StickyColumnCell({
    super.key,
    required this.background,
    required this.child,
  });

  final Color background;
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ScrollController? controller = StickyColumnScope.maybeOf(context);
    if (controller == null) return child;
    return AnimatedBuilder(
      animation: controller,
      builder: (BuildContext context, Widget? inner) {
        final double offset = controller.hasClients ? controller.offset : 0;
        return Transform.translate(
          offset: Offset(offset, 0),
          child: ColoredBox(color: background, child: inner),
        );
      },
      child: child,
    );
  }
}

class ScrollsBehindStickyColumn extends StatelessWidget {
  const ScrollsBehindStickyColumn({super.key, required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    final ScrollController? controller = StickyColumnScope.maybeOf(context);
    if (controller == null) return child;
    return ClipRect(clipper: _BehindStickyClipper(controller), child: child);
  }
}

class _BehindStickyClipper extends CustomClipper<Rect> {
  _BehindStickyClipper(this.controller) : super(reclip: controller);

  final ScrollController controller;

  @override
  Rect getClip(Size size) {
    final double offset = controller.hasClients ? controller.offset : 0;
    return Rect.fromLTRB(offset, 0, size.width, size.height);
  }

  @override
  bool shouldReclip(_BehindStickyClipper old) => old.controller != controller;
}
