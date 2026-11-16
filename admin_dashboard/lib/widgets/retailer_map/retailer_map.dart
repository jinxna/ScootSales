import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:flutter_map_marker_cluster/flutter_map_marker_cluster.dart';
import 'package:latlong2/latlong.dart';

import '../../services/geoapify_config.dart';
import '../geoapify_map_attribution.dart';
import 'retailer_map_marker.dart';
import '../../utils/retailer_readiness.dart';
import 'retailer_map_models.dart';

const LatLng _kuching = LatLng(1.5535, 110.3593);

class RetailerMap extends StatefulWidget {
  const RetailerMap({
    super.key,
    required this.points,
    required this.hoveredId,
    required this.selectedId,
  });

  final List<RetailerMapPoint> points;
  final ValueNotifier<String?> hoveredId;
  final ValueNotifier<String?> selectedId;

  @override
  State<RetailerMap> createState() => _RetailerMapState();
}

class _RetailerMapState extends State<RetailerMap> {
  final MapController _controller = MapController();
  bool _ready = false;

  List<RetailerMapPoint> get _plotted =>
      widget.points.where((RetailerMapPoint p) => p.isPlottable).toList();

  @override
  void initState() {
    super.initState();
    widget.selectedId.addListener(_onSelected);
  }

  @override
  void didUpdateWidget(RetailerMap old) {
    super.didUpdateWidget(old);
    if (old.selectedId != widget.selectedId) {
      old.selectedId.removeListener(_onSelected);
      widget.selectedId.addListener(_onSelected);
    }
    if (_ready &&
        !listEquals(
          old.points.map((RetailerMapPoint p) => p.id).toList(),
          widget.points.map((RetailerMapPoint p) => p.id).toList(),
        )) {
      _fitAll();
    }
  }

  @override
  void dispose() {
    widget.selectedId.removeListener(_onSelected);
    super.dispose();
  }

  void _fitAll() {
    final List<LatLng> coords = _plotted
        .map((RetailerMapPoint p) => p.point!)
        .toList();
    if (coords.isEmpty) return;
    if (coords.length == 1) {
      _controller.move(coords.first, 15);
    } else {
      _controller.fitCamera(_fit(coords));
    }
  }

  CameraFit _fit(List<LatLng> coords) => CameraFit.coordinates(
    coordinates: coords,
    padding: const EdgeInsets.all(48),
    maxZoom: 15,
  );

  void _onSelected() {
    final String? id = widget.selectedId.value;
    if (!_ready || id == null) return;
    for (final RetailerMapPoint p in _plotted) {
      if (p.id == id) {
        final double zoom = _controller.camera.zoom;
        _controller.move(p.point!, zoom < 15 ? 15 : zoom);
      }
    }
  }

  @override
  Widget build(BuildContext context) {
    final List<RetailerMapPoint> plotted = _plotted;
    final Map<String, RetailerMapPoint> byId = <String, RetailerMapPoint>{
      for (final RetailerMapPoint p in plotted) p.id: p,
    };
    final List<LatLng> coords = plotted
        .map((RetailerMapPoint p) => p.point!)
        .toList();
    final List<Marker> markers = <Marker>[
      for (final RetailerMapPoint p in plotted)
        Marker(
          key: ValueKey<String>(p.id),
          point: p.point!,
          width: 30,
          height: 30,
          child: Semantics(
            button: true,
            label: 'Retailer marker ${p.name}, ${p.status.label}',
            child: ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                widget.hoveredId,
                widget.selectedId,
              ]),
              builder: (BuildContext context, Widget? _) => RetailerMarkerGlyph(
                key: ValueKey<String>('marker-${p.id}'),
                status: p.status,
                selected: widget.selectedId.value == p.id,
                hovered: widget.hoveredId.value == p.id,
              ),
            ),
          ),
        ),
    ];
    String? idOf(Marker m) => (m.key as ValueKey<String>?)?.value;
    return SelectionContainer.disabled(
      child: FlutterMap(
        mapController: _controller,
        options: MapOptions(
          onMapReady: () => _ready = true,
          initialCenter: coords.isEmpty ? _kuching : coords.first,
          initialZoom: coords.isEmpty ? 12 : 15,
          initialCameraFit: coords.length > 1 ? _fit(coords) : null,
          onTap: (_, _) => widget.selectedId.value = null,
        ),
        children: <Widget>[
          GeoapifyConfig.lightTileLayer(),
          MarkerClusterLayerWidget(
            options: MarkerClusterLayerOptions(
              markers: markers,
              size: const Size(40, 40),
              maxClusterRadius: 45,
              spiderfyCluster: true,
              zoomToBoundsOnClick: true,
              padding: const EdgeInsets.all(48),
              maxZoom: 18,
              onMarkerTap: (Marker m) => widget.selectedId.value = idOf(m),
              onMarkerHoverEnter: (Marker m) =>
                  widget.hoveredId.value = idOf(m),
              onMarkerHoverExit: (Marker m) => widget.hoveredId.value = null,
              builder: (BuildContext context, List<Marker> group) {
                final int verified = group
                    .where((Marker m) => byId[idOf(m)]?.isVerified ?? false)
                    .length;
                return RetailerClusterBubble(
                  verified: verified,
                  review: group.length - verified,
                );
              },
            ),
          ),
          const GeoapifyMapAttribution(),
        ],
      ),
    );
  }
}
