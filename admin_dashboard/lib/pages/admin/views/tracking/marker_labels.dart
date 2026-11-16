import 'dart:math' as math;

import 'package:flutter/foundation.dart' show ValueListenable;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../../theme/dso_colors.dart';

Offset clampLabelOrigin({
  required Offset anchor,
  required Size labelSize,
  required Size viewport,
  double gap = 28,
  EdgeInsets safe = const EdgeInsets.all(8),
}) {
  final double minX = safe.left;
  final double maxX = math.max(
    minX,
    viewport.width - safe.right - labelSize.width,
  );
  final double minY = safe.top;
  final double maxY = math.max(
    minY,
    viewport.height - safe.bottom - labelSize.height,
  );
  final double x = (anchor.dx - labelSize.width / 2).clamp(minX, maxX);
  final double above = anchor.dy - gap - labelSize.height;
  final double y = (above >= minY ? above : anchor.dy + gap).clamp(minY, maxY);
  return Offset(x, y);
}

class _LabelDelegate extends SingleChildLayoutDelegate {
  const _LabelDelegate(this.anchor, this.safe);

  final Offset anchor;
  final EdgeInsets safe;

  @override
  BoxConstraints getConstraintsForChild(BoxConstraints constraints) =>
      BoxConstraints(
        maxWidth: math.max(
          0,
          math.min(240, constraints.maxWidth - safe.horizontal),
        ),
      );

  @override
  Offset getPositionForChild(Size size, Size childSize) => clampLabelOrigin(
    anchor: anchor,
    labelSize: childSize,
    viewport: size,
    safe: safe,
  );

  @override
  bool shouldRelayout(_LabelDelegate old) =>
      old.anchor != anchor || old.safe != safe;
}

class MapLabelSpec {
  const MapLabelSpec({
    required this.id,
    required this.point,
    required this.title,
    this.subtitle = '',
    this.accent,
  });

  final String id;
  final LatLng point;
  final String title;
  final String subtitle;
  final Color? accent;
}

class MapLabelLayer extends StatelessWidget {
  const MapLabelLayer({
    super.key,
    required this.labels,
    required this.hoveredId,
    this.pinnedIds = const <String>{},
    this.safe = const EdgeInsets.all(8),
  });

  final List<MapLabelSpec> labels;
  final ValueListenable<String?> hoveredId;
  final Set<String> pinnedIds;
  final EdgeInsets safe;

  @override
  Widget build(BuildContext context) {
    final MapCamera camera = MapCamera.of(context);
    return ValueListenableBuilder<String?>(
      valueListenable: hoveredId,
      builder: (BuildContext context, String? hovered, Widget? _) {
        final List<MapLabelSpec> shown = labels
            .where(
              (MapLabelSpec l) => l.id == hovered || pinnedIds.contains(l.id),
            )
            .toList(growable: false);
        return IgnorePointer(
          child: Stack(
            fit: StackFit.expand,
            children: <Widget>[
              for (final MapLabelSpec label in shown)
                CustomSingleChildLayout(
                  key: ValueKey<String>('map-label-${label.id}'),
                  delegate: _LabelDelegate(
                    camera.latLngToScreenOffset(label.point),
                    safe,
                  ),
                  child: _LabelChip(spec: label),
                ),
            ],
          ),
        );
      },
    );
  }
}

class _LabelChip extends StatelessWidget {
  const _LabelChip({required this.spec});

  final MapLabelSpec spec;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: dso.hairline),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x33000000),
            blurRadius: 12,
            offset: Offset(0, 4),
          ),
        ],
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              spec.title,
              maxLines: 1,
              overflow: TextOverflow.ellipsis,
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w700,
                color: dso.ink,
              ),
            ),
            if (spec.subtitle.isNotEmpty)
              Text(
                spec.subtitle,
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: dso.muted),
              ),
          ],
        ),
      ),
    );
  }
}
