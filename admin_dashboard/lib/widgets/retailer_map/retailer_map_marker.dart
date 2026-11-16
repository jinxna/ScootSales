import 'dart:math' as math;

import 'package:flutter/material.dart';

import '../../theme/dso_theme.dart';
import '../../utils/retailer_readiness.dart';

final DsoColors _fixed = DsoColors.light();
Color get retailerVerifiedColor => _fixed.success;
Color get retailerReviewColor => _fixed.warning;

enum RetailerMarkerStyle { filled, hollowRing }

RetailerMarkerStyle markerStyleFor(CoordinateStatus status) =>
    status == CoordinateStatus.verified
    ? RetailerMarkerStyle.filled
    : RetailerMarkerStyle.hollowRing;

class RetailerMarkerGlyph extends StatelessWidget {
  const RetailerMarkerGlyph({
    super.key,
    required this.status,
    this.selected = false,
    this.hovered = false,
  });

  final CoordinateStatus status;
  final bool selected;
  final bool hovered;

  @override
  Widget build(BuildContext context) {
    final double size = selected ? 22 : (hovered ? 18 : 14);
    final bool filled = markerStyleFor(status) == RetailerMarkerStyle.filled;
    final Color color = filled ? retailerVerifiedColor : retailerReviewColor;
    return Container(
      width: size + (selected ? 8 : 0),
      height: size + (selected ? 8 : 0),
      alignment: Alignment.center,
      decoration: selected
          ? BoxDecoration(
              shape: BoxShape.circle,
              color: _fixed.accent.withValues(alpha: 0.22),
            )
          : null,
      child: Container(
        width: size,
        height: size,
        decoration: BoxDecoration(
          shape: BoxShape.circle,
          color: filled ? color : Colors.white,
          border: filled
              ? Border.all(color: Colors.white, width: 2)
              : Border.all(color: color, width: 3),
        ),
        child: filled
            ? null
            : Center(
                child: Container(
                  width: size / 4,
                  height: size / 4,
                  decoration: BoxDecoration(
                    color: color,
                    shape: BoxShape.circle,
                  ),
                ),
              ),
      ),
    );
  }
}

class RetailerClusterBubble extends StatelessWidget {
  const RetailerClusterBubble({
    super.key,
    required this.verified,
    required this.review,
  });

  final int verified;
  final int review;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Cluster of ${verified + review} retailers',
      child: CustomPaint(
        painter: _ClusterRingPainter(verified, review),
        child: Container(
          margin: const EdgeInsets.all(4),
          alignment: Alignment.center,
          decoration: const BoxDecoration(
            color: Colors.white,
            shape: BoxShape.circle,
          ),
          child: Text(
            '${verified + review}',
            style: TextStyle(
              color: _fixed.ink,
              fontSize: 12,
              fontWeight: FontWeight.w700,
              fontFeatures: const <FontFeature>[FontFeature.tabularFigures()],
            ),
          ),
        ),
      ),
    );
  }
}

class _ClusterRingPainter extends CustomPainter {
  _ClusterRingPainter(this.verified, this.review);

  final int verified;
  final int review;

  @override
  void paint(Canvas canvas, Size size) {
    final Rect rect = Offset.zero & size;
    final Paint paint = Paint()..style = PaintingStyle.fill;
    final int total = math.max(1, verified + review);
    final double verifiedSweep = 2 * math.pi * verified / total;
    paint.color = retailerVerifiedColor;
    canvas.drawArc(rect, -math.pi / 2, verifiedSweep, true, paint);
    paint.color = retailerReviewColor;
    canvas.drawArc(
      rect,
      -math.pi / 2 + verifiedSweep,
      2 * math.pi - verifiedSweep,
      true,
      paint,
    );
  }

  @override
  bool shouldRepaint(_ClusterRingPainter old) =>
      old.verified != verified || old.review != review;
}

class RetailerMapLegend extends StatelessWidget {
  const RetailerMapLegend({
    super.key,
    required this.verified,
    required this.review,
  });

  final int verified;
  final int review;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    Widget row(CoordinateStatus status, String label, int count) => Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        SizedBox(
          width: 20,
          child: Center(child: RetailerMarkerGlyph(status: status)),
        ),
        const SizedBox(width: 6),
        Text(
          '$label $count',
          style: TextStyle(
            color: dso.body,
            fontSize: 12,
            fontWeight: FontWeight.w600,
          ),
        ),
      ],
    );
    return DecoratedBox(
      decoration: BoxDecoration(
        color: dso.card,
        border: Border.all(color: dso.hairline),
        borderRadius: BorderRadius.circular(DsoTokens.rMd),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            row(CoordinateStatus.verified, 'Verified', verified),
            const SizedBox(height: 4),
            row(
              CoordinateStatus.needsReview,
              'Candidate / needs review',
              review,
            ),
          ],
        ),
      ),
    );
  }
}
