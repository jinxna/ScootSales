import 'package:flutter/material.dart';

import '../../theme/dso_theme.dart';
import 'retailer_map.dart';
import 'retailer_map_marker.dart';
import '../../utils/retailer_readiness.dart';
import 'retailer_map_models.dart';
import 'retailer_map_rail.dart';

class RetailerMapView extends StatelessWidget {
  const RetailerMapView({
    super.key,
    required this.points,
    required this.hoveredId,
    required this.selectedId,
    this.lastVisitByRetailer = const <String, DateTime>{},
    this.nextPlannedByRetailer = const <String, DateTime>{},
    this.onReviewCoordinates,
    this.onOpenCoordinateReview,
    this.onOpenRoutePlanner,
    this.compact = false,
  });

  final List<RetailerMapPoint> points;
  final ValueNotifier<String?> hoveredId;
  final ValueNotifier<String?> selectedId;
  final Map<String, DateTime> lastVisitByRetailer;
  final Map<String, DateTime> nextPlannedByRetailer;
  final ValueChanged<RetailerMapPoint>? onReviewCoordinates;

  final VoidCallback? onOpenCoordinateReview;
  final VoidCallback? onOpenRoutePlanner;
  final bool compact;

  @override
  Widget build(BuildContext context) {
    final List<RetailerMapPoint> plotted = points
        .where((RetailerMapPoint p) => p.isPlottable)
        .toList();
    final int missing = points.length - plotted.length;
    final Widget map = plotted.isEmpty
        ? _EmptyState(
            missing: missing,
            onOpenCoordinateReview: onOpenCoordinateReview,
          )
        : _MapStack(view: this, plotted: plotted);
    if (compact) return map;
    return Row(
      children: <Widget>[
        SizedBox(
          width: 320,
          child: RetailerMapRail(
            points: points,
            hoveredId: hoveredId,
            selectedId: selectedId,
            onReviewCoordinates: onReviewCoordinates,
          ),
        ),
        VerticalDivider(width: 1, color: context.dso.hairline),
        Expanded(child: map),
      ],
    );
  }
}

class _MapStack extends StatelessWidget {
  const _MapStack({required this.view, required this.plotted});

  final RetailerMapView view;
  final List<RetailerMapPoint> plotted;

  @override
  Widget build(BuildContext context) {
    final int verified = plotted
        .where((RetailerMapPoint p) => p.isVerified)
        .length;
    return Stack(
      children: <Widget>[
        Positioned.fill(
          child: RetailerMap(
            points: plotted,
            hoveredId: view.hoveredId,
            selectedId: view.selectedId,
          ),
        ),
        Positioned(
          left: 12,
          bottom: 12,
          child: RetailerMapLegend(
            verified: verified,
            review: plotted.length - verified,
          ),
        ),
        if (!view.compact)
          Positioned(
            right: 12,
            top: 12,
            child: ValueListenableBuilder<String?>(
              valueListenable: view.selectedId,
              builder: (BuildContext context, String? id, Widget? _) {
                final RetailerMapPoint? p = plotted
                    .where((RetailerMapPoint p) => p.id == id)
                    .firstOrNull;
                if (p == null) return const SizedBox.shrink();
                return _DetailCard(
                  point: p,
                  lastVisit: view.lastVisitByRetailer[p.id],
                  nextPlanned: view.nextPlannedByRetailer[p.id],
                  onClose: () => view.selectedId.value = null,
                  onReview: view.onReviewCoordinates == null
                      ? null
                      : () => view.onReviewCoordinates!(p),
                  onOpenRoutePlanner: view.onOpenRoutePlanner,
                );
              },
            ),
          ),
      ],
    );
  }
}

class _DetailCard extends StatelessWidget {
  const _DetailCard({
    required this.point,
    required this.lastVisit,
    required this.nextPlanned,
    required this.onClose,
    required this.onReview,
    required this.onOpenRoutePlanner,
  });

  final RetailerMapPoint point;
  final DateTime? lastVisit;
  final DateTime? nextPlanned;
  final VoidCallback onClose;
  final VoidCallback? onReview;
  final VoidCallback? onOpenRoutePlanner;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    String date(DateTime d) =>
        '${d.year}-${d.month.toString().padLeft(2, '0')}-${d.day.toString().padLeft(2, '0')}';
    Widget line(String label, String value) => Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Text(
        '$label: $value',
        style: TextStyle(color: dso.body, fontSize: 12),
      ),
    );
    return Container(
      key: const ValueKey<String>('retailer-detail-card'),
      width: 280,
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dso.card,
        border: Border.all(color: dso.hairline),
        borderRadius: BorderRadius.circular(DsoTokens.rMd),
      ),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            children: <Widget>[
              RetailerMarkerGlyph(status: point.status),
              const SizedBox(width: 8),
              Expanded(
                child: Text(
                  point.name,
                  style: TextStyle(color: dso.ink, fontWeight: FontWeight.w700),
                ),
              ),
              IconButton(
                tooltip: 'Close',
                visualDensity: VisualDensity.compact,
                onPressed: onClose,
                icon: const Icon(Icons.close, size: 16),
              ),
            ],
          ),
          line(
            'Code',
            <String>[
              if (point.code.isNotEmpty) point.code,
              if (point.region.isNotEmpty) point.region,
            ].join(' · '),
          ),
          line('Coordinates', point.status.label),
          if (point.salesman.isNotEmpty) line('Salesman', point.salesman),
          if (point.address.isNotEmpty) line('Address', point.address),
          line(
            'Last visit',
            lastVisit == null ? 'Not recorded' : date(lastVisit!),
          ),
          line(
            'Next planned',
            nextPlanned == null ? 'Not planned' : date(nextPlanned!),
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 8,
            children: <Widget>[
              if (onReview != null)
                OutlinedButton(
                  onPressed: onReview,
                  child: const Text('Review coordinates'),
                ),
              if (onOpenRoutePlanner != null)
                TextButton(
                  onPressed: onOpenRoutePlanner,
                  child: const Text('Open route planner'),
                ),
            ],
          ),
        ],
      ),
    );
  }
}

class _EmptyState extends StatelessWidget {
  const _EmptyState({
    required this.missing,
    required this.onOpenCoordinateReview,
  });

  final int missing;
  final VoidCallback? onOpenCoordinateReview;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            'No retailers with coordinates',
            style: TextStyle(color: dso.ink, fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 6),
          Text(
            missing == 0
                ? 'There is nothing to plot yet.'
                : '$missing retailers need coordinates before they can be mapped.',
            style: TextStyle(color: dso.muted),
          ),
          if (onOpenCoordinateReview != null) ...<Widget>[
            const SizedBox(height: 12),
            FilledButton(
              onPressed: onOpenCoordinateReview,
              child: const Text('Review coordinates'),
            ),
          ],
        ],
      ),
    );
  }
}
