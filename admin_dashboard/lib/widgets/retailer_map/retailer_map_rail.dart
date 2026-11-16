import 'package:flutter/material.dart';

import '../../theme/dso_colors.dart';
import 'retailer_map_marker.dart';
import '../../utils/retailer_readiness.dart';
import 'retailer_map_models.dart';

class RetailerMapRail extends StatefulWidget {
  const RetailerMapRail({
    super.key,
    required this.points,
    required this.hoveredId,
    required this.selectedId,
    this.onReviewCoordinates,
  });

  final List<RetailerMapPoint> points;
  final ValueNotifier<String?> hoveredId;
  final ValueNotifier<String?> selectedId;
  final ValueChanged<RetailerMapPoint>? onReviewCoordinates;

  @override
  State<RetailerMapRail> createState() => _RetailerMapRailState();
}

class _RetailerMapRailState extends State<RetailerMapRail> {
  static const double _rowHeight = 60;
  final ScrollController _scroll = ScrollController();

  List<RetailerMapPoint> get _plotted =>
      widget.points.where((RetailerMapPoint p) => p.isPlottable).toList();

  @override
  void initState() {
    super.initState();
    widget.selectedId.addListener(_revealSelected);
  }

  @override
  void didUpdateWidget(RetailerMapRail old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId) {
      old.selectedId.removeListener(_revealSelected);
      widget.selectedId.addListener(_revealSelected);
    }
  }

  @override
  void dispose() {
    widget.selectedId.removeListener(_revealSelected);
    _scroll.dispose();
    super.dispose();
  }

  void _revealSelected() {
    final int index = _plotted.indexWhere(
      (RetailerMapPoint p) => p.id == widget.selectedId.value,
    );
    if (index < 0 || !_scroll.hasClients) return;
    final double top = index * _rowHeight;
    final double viewTop = _scroll.offset;
    final double viewBottom = viewTop + _scroll.position.viewportDimension;
    if (top < viewTop || top + _rowHeight > viewBottom) {
      _scroll.animateTo(
        top.clamp(0, _scroll.position.maxScrollExtent).toDouble(),
        duration: const Duration(milliseconds: 200),
        curve: Curves.easeOut,
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final List<RetailerMapPoint> plotted = _plotted;
    final List<RetailerMapPoint> unplotted = widget.points
        .where((RetailerMapPoint p) => !p.isPlottable)
        .toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 14, 16, 8),
          child: Text(
            'Plotted ${plotted.length}',
            style: TextStyle(color: dso.ink, fontWeight: FontWeight.w700),
          ),
        ),
        Expanded(
          child: ListView.builder(
            controller: _scroll,
            itemExtent: _rowHeight,
            itemCount: plotted.length,
            itemBuilder: (BuildContext context, int i) {
              final RetailerMapPoint p = plotted[i];
              return MouseRegion(
                onEnter: (_) => widget.hoveredId.value = p.id,
                onExit: (_) => widget.hoveredId.value = null,
                child: ListenableBuilder(
                  listenable: Listenable.merge(<Listenable>[
                    widget.hoveredId,
                    widget.selectedId,
                  ]),
                  builder: (BuildContext context, Widget? _) {
                    final bool selected = widget.selectedId.value == p.id;
                    final bool hovered = widget.hoveredId.value == p.id;
                    return ListTile(
                      key: ValueKey<String>('rail-${p.id}'),
                      dense: true,
                      selected: selected,
                      selectedTileColor: dso.brandSurface,
                      tileColor: hovered ? dso.surfaceSoft : null,
                      leading: SizedBox(
                        width: 24,
                        child: Center(
                          child: RetailerMarkerGlyph(status: p.status),
                        ),
                      ),
                      title: Text(
                        p.name,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      subtitle: Text(
                        <String>[
                          if (p.code.isNotEmpty) p.code,
                          p.status.label,
                        ].join(' · '),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                      onTap: () => widget.selectedId.value = p.id,
                    );
                  },
                ),
              );
            },
          ),
        ),
        if (unplotted.isNotEmpty)
          Theme(
            data: Theme.of(context).copyWith(dividerColor: Colors.transparent),
            child: ExpansionTile(
              key: const ValueKey<String>('needs-coordinates'),
              title: Text(
                'Needs coordinates ${unplotted.length}',
                style: TextStyle(
                  color: dso.dangerText,
                  fontWeight: FontWeight.w700,
                  fontSize: 14,
                ),
              ),
              children: <Widget>[
                ConstrainedBox(
                  constraints: const BoxConstraints(maxHeight: 220),
                  child: ListView(
                    shrinkWrap: true,
                    children: <Widget>[
                      for (final RetailerMapPoint p in unplotted)
                        ListTile(
                          key: ValueKey<String>('unplotted-${p.id}'),
                          dense: true,
                          title: Text(p.name),
                          subtitle: Text(
                            '${p.status.label} - cannot be plotted',
                          ),
                          trailing: widget.onReviewCoordinates == null
                              ? null
                              : TextButton(
                                  onPressed: () =>
                                      widget.onReviewCoordinates!(p),
                                  child: const Text('Review'),
                                ),
                        ),
                    ],
                  ),
                ),
              ],
            ),
          ),
      ],
    );
  }
}
