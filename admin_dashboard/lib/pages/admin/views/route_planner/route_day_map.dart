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

List<LatLng> routeDayMapFitPoints(RouteDay day) {
  final List<LatLng> points = day.stops
      .map((RouteStop stop) => LatLng(stop.lat, stop.lng))
      .toList();
  if (isProviderRoadGeometry(day.geometrySource) && day.geometry.length >= 2) {
    points.addAll(
      day.geometry.map((List<double> point) => LatLng(point[0], point[1])),
    );
  }
  return points;
}

class RouteDayMapView extends StatefulWidget {
  const RouteDayMapView({
    super.key,
    required this.day,
    required this.color,
    required this.hoveredSequence,
    required this.onHover,
    required this.onStopTap,
    this.focusedSequence,
  });

  final RouteDay day;
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

  List<LatLng> get _fitPoints => routeDayMapFitPoints(widget.day);

  List<LatLng> get _roadPoints =>
      isProviderRoadGeometry(widget.day.geometrySource) &&
          widget.day.geometry.length >= 2
      ? widget.day.geometry
            .map((List<double> p) => LatLng(p[0], p[1]))
            .toList(growable: false)
      : const <LatLng>[];

  @override
  void initState() {
    super.initState();
    _begin();
  }

  @override
  void didUpdateWidget(RouteDayMapView old) {
    super.didUpdateWidget(old);
    final bool fitPointsChanged = !listEquals(
      routeDayMapFitPoints(old.day),
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
    final List<LatLng> line = roadGeometry ? roadPoints : points;
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
              left: 12,
              top: 12,
              child: _LegendPill(
                color: widget.color,
                solid: roadGeometry,
                label: roadGeometry ? 'Road route' : 'Straight legs (estimate)',
              ),
            ),
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

class _LegendPill extends StatelessWidget {
  const _LegendPill({
    required this.color,
    required this.solid,
    required this.label,
  });

  final Color color;
  final bool solid;
  final String label;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 6),
      decoration: BoxDecoration(
        color: dso.card.withValues(alpha: 0.94),
        borderRadius: BorderRadius.circular(999),
        boxShadow: const <BoxShadow>[
          BoxShadow(color: Colors.black26, blurRadius: 4, offset: Offset(0, 1)),
        ],
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          SizedBox(
            width: 22,
            height: 4,
            child: CustomPaint(painter: _LegendStroke(color, solid)),
          ),
          const SizedBox(width: 8),
          Text(
            label,
            style: TextStyle(
              fontSize: 11.5,
              fontWeight: FontWeight.w600,
              color: dso.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _LegendStroke extends CustomPainter {
  const _LegendStroke(this.color, this.solid);
  final Color color;
  final bool solid;

  @override
  void paint(Canvas canvas, Size size) {
    final Paint p = Paint()
      ..color = color
      ..strokeWidth = 3
      ..strokeCap = StrokeCap.round;
    if (solid) {
      canvas.drawLine(
        Offset(0, size.height / 2),
        Offset(size.width, size.height / 2),
        p,
      );
      return;
    }
    for (double x = 0; x < size.width; x += 7) {
      canvas.drawLine(
        Offset(x, size.height / 2),
        Offset(x + 4, size.height / 2),
        p,
      );
    }
  }

  @override
  bool shouldRepaint(_LegendStroke old) =>
      old.color != color || old.solid != solid;
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
