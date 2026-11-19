import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../../../../models/route_plan.dart';
import '../../../../services/geoapify_config.dart';
import '../../../../theme/dso_colors.dart';
import '../../../../widgets/geoapify_map_attribution.dart';

List<LatLng> routeDayMapFitPoints(RouteDay day, {RouteStartPoint? start}) {
  final List<LatLng> points = day.stops
      .map((RouteStop stop) => LatLng(stop.lat, stop.lng))
      .toList();
  if (points.isNotEmpty && start != null) {
    points.add(LatLng(start.lat, start.lng));
  }
  points.addAll(routeDayRoadLine(day, start: start));
  return points;
}

List<LatLng> routeDayStraightLine(RouteDay day, {RouteStartPoint? start}) {
  final LatLng? origin = start == null ? null : LatLng(start.lat, start.lng);
  if (day.stops.isEmpty) return const <LatLng>[];
  return <LatLng>[
    if (origin != null) origin,
    for (final RouteStop stop in day.stops) LatLng(stop.lat, stop.lng),
    if (origin != null) origin,
  ];
}

List<LatLng> routeDayRoadLine(RouteDay day, {RouteStartPoint? start}) {
  if (!isProviderRoadGeometry(day.geometrySource) ||
      day.geometry.length < 2 ||
      day.stops.isEmpty) {
    return const <LatLng>[];
  }
  final List<LatLng> road = day.geometry
      .map((List<double> point) => LatLng(point[0], point[1]))
      .toList(growable: false);
  if (start != null) return road;
  if (day.stops.length < 2) return const <LatLng>[];
  const Distance distance = DistanceHaversine(roundResult: false);
  int nearestTo(RouteStop stop) {
    final LatLng target = LatLng(stop.lat, stop.lng);
    int nearest = 0;
    double nearestMeters = double.infinity;
    for (int i = 0; i < road.length; i++) {
      final double meters = distance.as(LengthUnit.Meter, road[i], target);
      if (meters < nearestMeters) {
        nearestMeters = meters;
        nearest = i;
      }
    }
    return nearest;
  }

  final int first = nearestTo(day.stops.first);
  final int last = nearestTo(day.stops.last);
  return first < last ? road.sublist(first, last + 1) : road;
}

class RouteDayMapView extends StatefulWidget {
  const RouteDayMapView({
    super.key,
    required this.day,
    required this.color,
    required this.hoveredSequence,
    required this.onHover,
    required this.onStopTap,
    this.start,
    this.focusedSequence,
  });

  final RouteDay day;
  final RouteStartPoint? start;
  final Color color;

  final ValueListenable<int?> hoveredSequence;
  final ValueChanged<int?> onHover;
  final ValueChanged<int> onStopTap;

  final int? focusedSequence;

  @override
  State<RouteDayMapView> createState() => _RouteDayMapViewState();
}

class _RouteDayMapViewState extends State<RouteDayMapView> {
  final MapController _controller = MapController();
  bool _showMap = false;
  bool _ready = false;
  bool _timedOut = false;
  Timer? _timer;

  List<LatLng> get _points => widget.day.stops
      .map((RouteStop s) => LatLng(s.lat, s.lng))
      .toList(growable: false);

  List<LatLng> get _fitPoints =>
      routeDayMapFitPoints(widget.day, start: widget.start);

  List<LatLng> get _roadPoints =>
      routeDayRoadLine(widget.day, start: widget.start);

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void didUpdateWidget(RouteDayMapView old) {
    super.didUpdateWidget(old);
    final bool fitPointsChanged = !listEquals(
      routeDayMapFitPoints(old.day, start: old.start),
      _fitPoints,
    );
    final int? seq = widget.focusedSequence;
    if (seq != null && seq != old.focusedSequence && _ready) {
      for (final RouteStop s in widget.day.stops) {
        if (s.sequence == seq) {
          _controller.move(
            LatLng(s.lat, s.lng),
            _controller.camera.zoom < 14 ? 14 : _controller.camera.zoom,
          );
        }
      }
    } else if (fitPointsChanged && _ready) {
      _fit();
    }
  }

  void _begin() {
    _timer?.cancel();
    _showMap = false;
    _ready = false;
    _timedOut = false;
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      if (!mounted) return;
      setState(() => _showMap = true);
    });
    _timer = Timer(const Duration(seconds: 2), () {
      if (!mounted || _ready) return;
      setState(() => _timedOut = true);
    });
  }

  void _onReady() {
    _timer?.cancel();
    if (!mounted || (_ready && !_timedOut)) return;
    setState(() {
      _ready = true;
      _timedOut = false;
    });
  }

  void _fit() {
    final List<LatLng> pts = _fitPoints;
    if (pts.isEmpty) return;
    if (pts.length == 1) {
      _controller.move(pts.first, 14);
      return;
    }
    _controller.fitCamera(
      CameraFit.coordinates(
        coordinates: pts,
        padding: const EdgeInsets.all(56),
        maxZoom: 15,
      ),
    );
  }

  void _zoom(double delta) {
    final MapCamera cam = _controller.camera;
    _controller.move(cam.center, (cam.zoom + delta).clamp(3, 19));
  }

  @override
  void dispose() {
    _timer?.cancel();
    _controller.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final List<LatLng> points = _points;
    if (points.isEmpty) {
      return _Frame(
        child: _MapNote(
          icon: ScootIcons.map,
          title: 'Nothing to map',
          body: 'This day has no stops with coordinates.',
        ),
      );
    }
    final List<LatLng> fitPoints = _fitPoints;
    if (_timedOut && !_ready) {
      return _Frame(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    'Map is still loading',
                    style: TextStyle(
                      fontWeight: FontWeight.w800,
                      color: dso.ink,
                    ),
                  ),
                ),
                FilledButton.tonalIcon(
                  onPressed: () => setState(_begin),
                  icon: const Icon(ScootIcons.refresh, size: 16),
                  label: const Text('Retry map'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            Expanded(
              child: ListView(
                children: <Widget>[
                  for (final RouteStop s in widget.day.stops)
                    Padding(
                      padding: const EdgeInsets.symmetric(vertical: 4),
                      child: Text(
                        '${s.sequence}. ${s.retailerName} - '
                        '${s.lat.toStringAsFixed(4)}, ${s.lng.toStringAsFixed(4)}',
                        style: TextStyle(fontSize: 12, color: dso.body),
                      ),
                    ),
                ],
              ),
            ),
          ],
        ),
      );
    }
    final List<LatLng> roadPoints = _roadPoints;
    final bool roadGeometry = roadPoints.isNotEmpty;
    final List<LatLng> line = roadGeometry
        ? roadPoints
        : routeDayStraightLine(widget.day, start: widget.start);
    return ClipRRect(
      borderRadius: BorderRadius.circular(16),
      child: Stack(
        fit: StackFit.expand,
        children: <Widget>[
          if (_showMap)
            SelectionContainer.disabled(
              child: FlutterMap(
                mapController: _controller,
                options: MapOptions(
                  onMapReady: _onReady,
                  interactionOptions: const InteractionOptions(
                    flags:
                        InteractiveFlag.all & ~InteractiveFlag.scrollWheelZoom,
                  ),
                  initialCenter: fitPoints.first,
                  initialZoom: 12,
                  initialCameraFit: fitPoints.length > 1
                      ? CameraFit.coordinates(
                          coordinates: fitPoints,
                          padding: const EdgeInsets.all(56),
                          maxZoom: 15,
                        )
                      : null,
                ),
                children: <Widget>[
                  GeoapifyConfig.lightTileLayer(),
                  if (line.length >= 2)
                    PolylineLayer<Object>(
                      polylines: <Polyline<Object>>[
                        Polyline<Object>(
                          points: line,
                          strokeWidth: 8,
                          color: Colors.white.withValues(alpha: 0.9),
                          strokeCap: StrokeCap.round,
                          strokeJoin: StrokeJoin.round,
                        ),
                        Polyline<Object>(
                          points: line,
                          strokeWidth: 4,
                          color: widget.color,
                          strokeCap: StrokeCap.round,
                          strokeJoin: StrokeJoin.round,
                          pattern: roadGeometry
                              ? const StrokePattern.solid()
                              : StrokePattern.dashed(
                                  segments: const <double>[10, 8],
                                ),
                        ),
                      ],
                    ),
                  ValueListenableBuilder<int?>(
                    valueListenable: widget.hoveredSequence,
                    builder: (BuildContext context, int? hovered, _) {
                      return MarkerLayer(
                        markers: <Marker>[
                          if (widget.start != null)
                            Marker(
                              point: LatLng(
                                widget.start!.lat,
                                widget.start!.lng,
                              ),
                              width: 44,
                              height: 44,
                              child: _StartMarker(
                                name: widget.start!.name,
                                color: widget.color,
                              ),
                            ),
                          for (final RouteStop s in widget.day.stops)
                            Marker(
                              point: LatLng(s.lat, s.lng),
                              width: 44,
                              height: 44,
                              child: _StopMarker(
                                stop: s,
                                color: widget.color,
                                active: hovered == s.sequence,
                                onHover: widget.onHover,
                                onTap: () => widget.onStopTap(s.sequence),
                              ),
                            ),
                        ],
                      );
                    },
                  ),
                  const GeoapifyMapAttribution(includeOpenMapTiles: false),
                ],
              ),
            ),
          if (!_ready)
            ColoredBox(
              color: dso.surfaceSoft,
              child: Center(
                child: CircularProgressIndicator(
                  strokeWidth: 3,
                  color: dso.accent,
                ),
              ),
            ),
          if (_ready) ...<Widget>[
            Positioned(
              right: 12,
              top: 12,
              child: Column(
                children: <Widget>[
                  _MapButton(
                    icon: Icons.fit_screen_outlined,
                    tooltip: 'Fit day to map',
                    onTap: _fit,
                  ),
                  const SizedBox(height: 6),
                  _MapButton(
                    icon: ScootIcons.add,
                    tooltip: 'Zoom in',
                    onTap: () => _zoom(1),
                  ),
                  const SizedBox(height: 6),
                  _MapButton(
                    icon: Icons.remove,
                    tooltip: 'Zoom out',
                    onTap: () => _zoom(-1),
                  ),
                ],
              ),
            ),
          ],
        ],
      ),
    );
  }
}

class _StopMarker extends StatelessWidget {
  const _StopMarker({
    required this.stop,
    required this.color,
    required this.active,
    required this.onHover,
    required this.onTap,
  });

  final RouteStop stop;
  final Color color;
  final bool active;
  final ValueChanged<int?> onHover;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final double size = active ? 40 : 30;
    return Semantics(
      button: true,
      label: 'Stop ${stop.sequence}, ${stop.retailerName}',
      child: MouseRegion(
        cursor: SystemMouseCursors.click,
        onEnter: (_) => onHover(stop.sequence),
        onExit: (_) => onHover(null),
        child: GestureDetector(
          onTap: onTap,
          child: Center(
            child: AnimatedContainer(
              duration: const Duration(milliseconds: 140),
              curve: Curves.easeOutCubic,
              width: size,
              height: size,
              alignment: Alignment.center,
              decoration: BoxDecoration(
                color: color,
                shape: BoxShape.circle,
                border: Border.all(color: Colors.white, width: 2.5),
                boxShadow: <BoxShadow>[
                  BoxShadow(
                    color: Colors.black.withValues(alpha: active ? 0.4 : 0.25),
                    blurRadius: active ? 12 : 5,
                    offset: const Offset(0, 2),
                  ),
                ],
              ),
              child: Text(
                '${stop.sequence}',
                style: TextStyle(
                  color: Colors.white,
                  fontSize: active ? 15 : 12.5,
                  fontWeight: FontWeight.w800,
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _StartMarker extends StatelessWidget {
  const _StartMarker({required this.name, required this.color});

  final String name;
  final Color color;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: 'Start and end, $name',
      child: Tooltip(
        message: 'Start and end: $name',
        child: Center(
          child: Container(
            width: 30,
            height: 30,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: color, width: 3),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Colors.black38,
                  blurRadius: 5,
                  offset: Offset(0, 2),
                ),
              ],
            ),
            child: Text(
              'S',
              style: TextStyle(
                color: color,
                fontSize: 14,
                fontWeight: FontWeight.w800,
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _MapButton extends StatelessWidget {
  const _MapButton({
    required this.icon,
    required this.tooltip,
    required this.onTap,
  });

  final IconData icon;
  final String tooltip;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Tooltip(
      message: tooltip,
      child: Material(
        color: dso.card,
        elevation: 2,
        shadowColor: Colors.black38,
        borderRadius: BorderRadius.circular(10),
        child: InkWell(
          borderRadius: BorderRadius.circular(10),
          onTap: onTap,
          child: SizedBox(
            width: 36,
            height: 36,
            child: Icon(icon, size: 18, color: dso.ink),
          ),
        ),
      ),
    );
  }
}

class _Frame extends StatelessWidget {
  const _Frame({required this.child});
  final Widget child;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: dso.surfaceSoft,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      child: child,
    );
  }
}

class _MapNote extends StatelessWidget {
  const _MapNote({required this.icon, required this.title, required this.body});
  final IconData icon;
  final String title;
  final String body;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Center(
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Icon(icon, size: 36, color: dso.subtle),
          const SizedBox(height: 8),
          Text(
            title,
            style: TextStyle(fontWeight: FontWeight.w700, color: dso.ink),
          ),
          const SizedBox(height: 4),
          Text(body, style: TextStyle(fontSize: 12.5, color: dso.muted)),
        ],
      ),
    );
  }
}
