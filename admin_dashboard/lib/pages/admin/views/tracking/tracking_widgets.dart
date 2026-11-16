import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../../theme/dso_colors.dart';

class TrackingGlass extends StatelessWidget {
  const TrackingGlass({
    super.key,
    required this.child,
    this.padding = const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
    this.radius = 16,
  });

  final Widget child;
  final EdgeInsetsGeometry padding;
  final double radius;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return ClipRRect(
      borderRadius: BorderRadius.circular(radius),
      child: BackdropFilter(
        filter: ImageFilter.blur(sigmaX: 14, sigmaY: 14),
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: dso.card.withValues(alpha: 0.88),
            borderRadius: BorderRadius.circular(radius),
            border: Border.all(color: dso.hairline.withValues(alpha: 0.9)),
            boxShadow: const <BoxShadow>[
              BoxShadow(
                color: Color(0x24000000),
                blurRadius: 18,
                offset: Offset(0, 6),
              ),
            ],
          ),
          child: Padding(padding: padding, child: child),
        ),
      ),
    );
  }
}

class TrackingKpi {
  const TrackingKpi({
    required this.label,
    required this.value,
    required this.icon,
  });

  final String label;
  final int value;
  final IconData icon;
}

class TrackingKpiStrip extends StatelessWidget {
  const TrackingKpiStrip({super.key, required this.kpis});

  final List<TrackingKpi> kpis;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints constraints) {
        final bool compact = constraints.maxWidth < 420;
        return TrackingGlass(
          padding: EdgeInsets.symmetric(
            horizontal: compact ? 4 : 8,
            vertical: 8,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              for (int i = 0; i < kpis.length; i++) ...<Widget>[
                if (i > 0)
                  Container(
                    width: 1,
                    height: 28,
                    margin: const EdgeInsets.symmetric(horizontal: 4),
                    color: dso.hairline,
                  ),
                Flexible(
                  child: Semantics(
                    container: true,
                    label: '${kpis[i].label}: ${kpis[i].value}',
                    child: ExcludeSemantics(
                      child: Padding(
                        padding: EdgeInsets.symmetric(
                          horizontal: compact ? 6 : 12,
                        ),
                        child: Row(
                          mainAxisSize: MainAxisSize.min,
                          children: <Widget>[
                            if (!compact) ...<Widget>[
                              Icon(
                                kpis[i].icon,
                                size: 18,
                                color: dso.accentText,
                              ),
                              const SizedBox(width: 8),
                            ],
                            Flexible(
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Text(
                                    '${kpis[i].value}',
                                    style: TextStyle(
                                      fontSize: 20,
                                      height: 1.1,
                                      fontWeight: FontWeight.w800,
                                      color: dso.ink,
                                    ),
                                  ),
                                  Text(
                                    kpis[i].label,
                                    maxLines: 1,
                                    overflow: TextOverflow.ellipsis,
                                    style: TextStyle(
                                      fontSize: 12,
                                      color: dso.muted,
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ],
                        ),
                      ),
                    ),
                  ),
                ),
              ],
            ],
          ),
        );
      },
    );
  }
}

class TrackingMarkerButton extends StatefulWidget {
  const TrackingMarkerButton({
    super.key,
    required this.semanticLabel,
    required this.child,
    required this.onHover,
    this.onTap,
    this.selected = false,
  });

  final String semanticLabel;
  final Widget child;
  final ValueChanged<bool> onHover;
  final VoidCallback? onTap;
  final bool selected;

  @override
  State<TrackingMarkerButton> createState() => _TrackingMarkerButtonState();
}

class _TrackingMarkerButtonState extends State<TrackingMarkerButton> {
  bool _hovered = false;
  bool _focused = false;

  void _sync() => widget.onHover(_hovered || _focused);

  @override
  Widget build(BuildContext context) {
    return Semantics(
      button: widget.onTap != null,
      selected: widget.selected,
      label: widget.semanticLabel,
      excludeSemantics: true,
      onTap: widget.onTap,
      child: Material(
        type: MaterialType.transparency,
        child: InkResponse(
          onTap: widget.onTap,
          onHover: (bool value) {
            _hovered = value;
            _sync();
          },
          onFocusChange: (bool value) {
            _focused = value;
            _sync();
          },
          customBorder: const CircleBorder(),
          highlightShape: BoxShape.circle,
          child: widget.child,
        ),
      ),
    );
  }
}

class VehicleBadge extends StatefulWidget {
  const VehicleBadge({
    super.key,
    required this.color,
    required this.live,
    required this.selected,
  });

  final Color color;
  final bool live;
  final bool selected;

  @override
  State<VehicleBadge> createState() => _VehicleBadgeState();
}

class _VehicleBadgeState extends State<VehicleBadge>
    with SingleTickerProviderStateMixin {
  late final AnimationController _pulse = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 2200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(VehicleBadge old) {
    super.didUpdateWidget(old);
    if (old.live != widget.live) _syncPulse();
  }

  void _syncPulse() {
    final bool still = MediaQuery.maybeDisableAnimationsOf(context) ?? false;
    if (widget.live && !still) {
      if (!_pulse.isAnimating) _pulse.repeat();
    } else {
      _pulse.stop();
    }
  }

  @override
  void dispose() {
    _pulse.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final double size = widget.selected ? 40 : 34;
    final Color status = widget.live ? dso.success : dso.warning;
    return SizedBox(
      width: 56,
      height: 56,
      child: Stack(
        alignment: Alignment.center,
        children: <Widget>[
          if (widget.live)
            AnimatedBuilder(
              animation: _pulse,
              builder: (BuildContext context, Widget? child) {
                final double t = _pulse.isAnimating ? _pulse.value : 0.35;
                return Container(
                  width: 34 + 22 * t,
                  height: 34 + 22 * t,
                  decoration: BoxDecoration(
                    shape: BoxShape.circle,
                    color: status.withValues(alpha: 0.32 * (1 - t)),
                  ),
                );
              },
            ),
          AnimatedContainer(
            duration: const Duration(milliseconds: 180),
            width: size,
            height: size,
            decoration: BoxDecoration(
              color: widget.color,
              shape: BoxShape.circle,
              border: Border.all(color: Colors.white, width: 3),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.30),
                  blurRadius: 8,
                  offset: const Offset(0, 2),
                ),
              ],
            ),
            child: Icon(
              ScootIcons.delivery,
              size: widget.selected ? 20 : 17,
              color: Colors.white,
            ),
          ),
          Positioned(
            right: 8,
            bottom: 8,
            child: Container(
              width: 12,
              height: 12,
              decoration: BoxDecoration(
                color: status,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2),
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class StopBadge extends StatelessWidget {
  const StopBadge({
    super.key,
    required this.color,
    this.number,
    this.icon,
    this.size = 26,
  });

  final Color color;
  final int? number;
  final IconData? icon;
  final double size;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: size,
      height: size,
      alignment: Alignment.center,
      decoration: BoxDecoration(
        color: color,
        shape: BoxShape.circle,
        border: Border.all(color: Colors.white, width: 2),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Colors.black.withValues(alpha: 0.28),
            blurRadius: 6,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: number != null
          ? Text(
              '$number',
              style: const TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w800,
                color: Colors.white,
              ),
            )
          : Icon(icon, size: 14, color: Colors.white),
    );
  }
}
