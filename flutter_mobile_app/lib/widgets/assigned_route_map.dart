import 'dart:async';
import 'dart:math' as math;

import 'package:flutter/foundation.dart' show listEquals;
import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:latlong2/latlong.dart';

import '../utils/location_evidence.dart' show kLocationFixMaxAge;

const String _tileUrl = 'https://tile.openstreetmap.org/{z}/{x}/{y}.png';
const String _tileAttribution = '© OpenStreetMap contributors';
const String _mobileApplicationId = 'my.scootsales.app';
const double _webMercatorLatitudeLimit = 85.05112878;
const double _markerOverlapDistance = 48;

class AssignedRouteMapStop {
  const AssignedRouteMapStop({
    required this.stopId,
    required this.retailerName,
    required this.plannedOrder,
    required this.status,
    required this.latitude,
    required this.longitude,
    required this.coordinatesVerified,
    this.coordinateRevision = '',
    this.address = '',
    this.plannedTime = '',
  });

  final String stopId;
  final String retailerName;
  final int plannedOrder;
  final String status;
  final double? latitude;
  final double? longitude;
  final bool coordinatesVerified;
  final String coordinateRevision;
  final String address;
  final String plannedTime;
}

class AssignedRouteMapLocation {
  const AssignedRouteMapLocation({
    required this.latitude,
    required this.longitude,
    required this.capturedAt,
    this.accuracyMeters,
  });

  final double latitude;
  final double longitude;
  final DateTime capturedAt;
  final double? accuracyMeters;
}

List<LatLng> assignedRouteMapFitPoints({
  required List<AssignedRouteMapStop> stops,
  List<LatLng>? roadGeometry,
  LatLng? ownLocation,
}) {
  final List<LatLng> points = <LatLng>[];
  for (final AssignedRouteMapStop stop in stops) {
    if (stop.stopId.trim().isEmpty ||
        !_isValidCoordinates(stop.latitude, stop.longitude)) {
      continue;
    }
    points.add(LatLng(stop.latitude!, stop.longitude!));
  }
  if (ownLocation != null &&
      _isValidCoordinates(ownLocation.latitude, ownLocation.longitude)) {
    points.add(ownLocation);
  }
  if (roadGeometry != null && _isValidRoadGeometry(roadGeometry)) {
    points.addAll(roadGeometry);
  }
  return points;
}

class AssignedRouteMap extends StatefulWidget {
  const AssignedRouteMap({
    super.key,
    required this.stops,
    required this.selectedStopId,
    required this.onStopSelected,
    this.ownLocation,
    this.validatedRoadGeometry,
    this.showSelectedStopSummary = true,
    this.onTileFailure,
    this.height = 360,
  });

  final List<AssignedRouteMapStop> stops;
  final String? selectedStopId;
  final AssignedRouteMapLocation? ownLocation;
  final List<LatLng>? validatedRoadGeometry;
  final bool showSelectedStopSummary;
  final VoidCallback? onTileFailure;
  final ValueChanged<String> onStopSelected;

  final double height;

  @override
  State<AssignedRouteMap> createState() => _AssignedRouteMapState();
}

class _AssignedRouteMapState extends State<AssignedRouteMap> {
  final MapController _mapController = MapController();
  Timer? _locationAgeTimer;
  bool _mapReady = false;
  bool _hasTileFailure = false;
  double? _lastClusterZoom;

  @override
  void initState() {
    super.initState();
    _scheduleLocationAgeRefresh();
  }

  @override
  void didUpdateWidget(covariant AssignedRouteMap oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (_locationSignature(oldWidget.ownLocation) !=
        _locationSignature(widget.ownLocation)) {
      _scheduleLocationAgeRefresh();
    }
    if (_stopCoordinateSignature(oldWidget.stops) !=
            _stopCoordinateSignature(widget.stops) ||
        !listEquals(
          oldWidget.validatedRoadGeometry,
          widget.validatedRoadGeometry,
        )) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && _mapReady) _fitMapToContent();
      });
    }
  }

  @override
  void dispose() {
    _locationAgeTimer?.cancel();
    _mapController.dispose();
    super.dispose();
  }

  void _scheduleLocationAgeRefresh() {
    _locationAgeTimer?.cancel();
    if (widget.ownLocation == null) return;

    _locationAgeTimer = Timer.periodic(const Duration(seconds: 30), (_) {
      if (mounted) setState(() {});
    });
  }

  String _locationSignature(AssignedRouteMapLocation? location) {
    if (location == null) return '';
    return '${location.latitude}|${location.longitude}|'
        '${location.capturedAt.toIso8601String()}|${location.accuracyMeters}';
  }

  String _stopCoordinateSignature(List<AssignedRouteMapStop> stops) =>
      stops
          .map(
            (AssignedRouteMapStop stop) =>
                '${stop.stopId}|${stop.latitude}|${stop.longitude}',
          )
          .join('\u001e');

  @override
  Widget build(BuildContext context) {
    final DateTime now = DateTime.now();
    final _LocationPresentation location =
        _LocationPresentation.from(widget.ownLocation, now);
    final List<LatLng> mapPoints = _mapPoints(location);
    final AssignedRouteMapStop? selectedStop = _selectedStop;
    final ThemeData theme = Theme.of(context);

    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _buildLocationStatus(theme, location),
        const SizedBox(height: 8),
        ClipRRect(
          borderRadius: BorderRadius.circular(16),
          child: SizedBox(
            height: widget.height,
            child: mapPoints.isEmpty
                ? _buildEmptyMap(theme)
                : _buildMap(theme, mapPoints, location),
          ),
        ),
        if (selectedStop != null && widget.showSelectedStopSummary) ...<Widget>[
          const SizedBox(height: 8),
          _buildSelectedStopSummary(theme, selectedStop),
        ],
      ],
    );
  }

  AssignedRouteMapStop? get _selectedStop {
    final String? selectedId = widget.selectedStopId;
    if (selectedId == null || selectedId.trim().isEmpty) return null;
    for (final AssignedRouteMapStop stop in widget.stops) {
      if (stop.stopId == selectedId) return stop;
    }
    return null;
  }

  List<LatLng> _mapPoints(_LocationPresentation location) {
    return assignedRouteMapFitPoints(
      stops: widget.stops,
      roadGeometry: widget.validatedRoadGeometry,
      ownLocation: location.isAvailable ? location.point : null,
    );
  }

  Widget _buildLocationStatus(
    ThemeData theme,
    _LocationPresentation location,
  ) {
    final Color foreground = switch (location.freshness) {
      _LocationFreshness.fresh => const Color(0xFF155EAA),
      _LocationFreshness.stale => const Color(0xFF596579),
      _LocationFreshness.unavailable => theme.colorScheme.onSurfaceVariant,
    };
    final Color background = switch (location.freshness) {
      _LocationFreshness.fresh => const Color(0xFFEAF3FF),
      _LocationFreshness.stale => const Color(0xFFF0F2F5),
      _LocationFreshness.unavailable => theme.colorScheme.surfaceContainer,
    };
    final IconData icon = switch (location.freshness) {
      _LocationFreshness.fresh => Icons.my_location,
      _LocationFreshness.stale => Icons.history_toggle_off,
      _LocationFreshness.unavailable => Icons.location_disabled_outlined,
    };

    return Semantics(
      label: location.statusText,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(12),
          ),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
            child: Row(
              children: <Widget>[
                Icon(icon, size: 18, color: foreground),
                const SizedBox(width: 8),
                Expanded(
                  child: Text(
                    location.statusText,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: foreground,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _buildEmptyMap(ThemeData theme) => DecoratedBox(
    decoration: BoxDecoration(color: theme.colorScheme.surfaceContainerHigh),
    child: Stack(
      children: <Widget>[
        Center(
          child: Padding(
            padding: const EdgeInsets.all(24),
            child: Text(
              'No valid stop or current-location coordinates are available '
              'to show on the map.',
              textAlign: TextAlign.center,
              style: theme.textTheme.bodyMedium?.copyWith(
                color: theme.colorScheme.onSurfaceVariant,
              ),
            ),
          ),
        ),
        _buildAttribution(),
      ],
    ),
  );

  Widget _buildMap(
    ThemeData theme,
    List<LatLng> mapPoints,
    _LocationPresentation location,
  ) {
    final List<LatLng> uniquePoints = _uniquePoints(mapPoints);
    final LatLng initialCenter = _initialCenter(location);
    final CameraFit? initialFit = uniquePoints.length > 1
        ? _boundsFit(uniquePoints)
        : null;
    final List<LatLng>? roadGeometry = widget.validatedRoadGeometry;
    final bool showRoadGeometry =
        roadGeometry != null && _isValidRoadGeometry(roadGeometry);

    return Stack(
      fit: StackFit.expand,
      children: <Widget>[
        FlutterMap(
          mapController: _mapController,
          options: MapOptions(
            initialCenter: initialCenter,
            initialZoom: 14,
            initialCameraFit: initialFit,
            minZoom: 3,
            maxZoom: 19,
            onMapReady: _onMapReady,
            onPositionChanged: _onPositionChanged,
          ),
          children: <Widget>[
            TileLayer(
              urlTemplate: _tileUrl,
              subdomains: const <String>[],
              retinaMode: RetinaMode.isHighDensity(context),
              userAgentPackageName: _mobileApplicationId,
              maxNativeZoom: 19,
              maxZoom: 19,
              panBuffer: 0,
              keepBuffer: 0,
              errorTileCallback: _onTileError,
            ),
            if (showRoadGeometry)
              PolylineLayer<Object>(
                polylines: <Polyline<Object>>[
                  Polyline<Object>(
                    points: roadGeometry,
                    strokeWidth: 4,
                    color: const Color(0xFF365FC7),
                  ),
                ],
              ),
            if (location.isAvailable &&
                location.accuracyMeters != null &&
                location.accuracyMeters! > 0)
              CircleLayer(
                circles: <CircleMarker>[
                  CircleMarker(
                    point: location.point!,
                    radius: location.accuracyMeters!,
                    useRadiusInMeter: true,
                    color: location.markerColor.withValues(alpha: 0.16),
                    borderColor: location.markerColor.withValues(alpha: 0.5),
                    borderStrokeWidth: 1.5,
                  ),
                ],
              ),
            MarkerLayer(markers: _buildStopMarkers(theme)),
            if (location.isAvailable)
              MarkerLayer(markers: <Marker>[_buildOwnLocationMarker(location)]),
          ],
        ),
        if (_hasTileFailure)
          Positioned(
            top: 12,
            left: 12,
            right: 12,
            child: IgnorePointer(
              child: Semantics(
                liveRegion: true,
                label: 'Map unavailable. Map tiles could not be loaded. '
                    'Stop markers remain selectable where available.',
                child: DecoratedBox(
                  decoration: BoxDecoration(
                    color: theme.colorScheme.errorContainer,
                    borderRadius: BorderRadius.circular(12),
                    boxShadow: const <BoxShadow>[
                      BoxShadow(color: Color(0x22000000), blurRadius: 8),
                    ],
                  ),
                  child: Padding(
                    padding: const EdgeInsets.all(10),
                    child: Row(
                      children: <Widget>[
                        Icon(
                          Icons.map_outlined,
                          color: theme.colorScheme.onErrorContainer,
                        ),
                        const SizedBox(width: 8),
                        Expanded(
                          child: Text(
                            'Map unavailable · tiles could not be loaded. '
                            'Stop markers remain selectable where available.',
                            style: theme.textTheme.bodySmall?.copyWith(
                              color: theme.colorScheme.onErrorContainer,
                              fontWeight: FontWeight.w600,
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        _buildAttribution(),
      ],
    );
  }

  Widget _buildAttribution() => Positioned(
    right: 8,
    bottom: 8,
    child: IgnorePointer(
      child: Semantics(
        label: 'Map data $_tileAttribution',
        child: ExcludeSemantics(
          child: DecoratedBox(
            decoration: BoxDecoration(
              color: Colors.white.withValues(alpha: 0.94),
              borderRadius: BorderRadius.circular(4),
            ),
            child: const Padding(
              padding: EdgeInsets.symmetric(horizontal: 6, vertical: 4),
              child: Text(
                _tileAttribution,
                style: TextStyle(
                  color: Color(0xFF252525),
                  fontSize: 11,
                  fontWeight: FontWeight.w500,
                ),
              ),
            ),
          ),
        ),
      ),
    ),
  );

  Widget _buildSelectedStopSummary(
    ThemeData theme,
    AssignedRouteMapStop stop,
  ) {
    final String coordinateText = !_isValidCoordinates(
      stop.latitude,
      stop.longitude,
    )
        ? 'No usable map coordinates'
        : stop.coordinatesVerified
        ? 'Verified retailer pin'
        : 'Unverified retailer pin';

    return DecoratedBox(
      decoration: BoxDecoration(
        color: theme.colorScheme.surface,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: theme.colorScheme.outlineVariant),
      ),
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 10),
        child: Row(
          children: <Widget>[
            Icon(Icons.flag_outlined, color: theme.colorScheme.primary),
            const SizedBox(width: 10),
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    stop.retailerName.trim().isEmpty
                        ? 'Retailer'
                        : stop.retailerName,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodyMedium?.copyWith(
                      fontWeight: FontWeight.w700,
                    ),
                  ),
                  const SizedBox(height: 2),
                  Text(
                    <String>[
                      'Stop ${_orderText(stop)}',
                      _humanizeStatus(stop.status),
                      coordinateText,
                      if (stop.coordinateRevision.isNotEmpty)
                        'Published revision ${stop.coordinateRevision}',
                      if (stop.plannedTime.isNotEmpty)
                        'Planned ${stop.plannedTime}',
                    ].join(' · '),
                    maxLines: 2,
                    overflow: TextOverflow.ellipsis,
                    style: theme.textTheme.bodySmall?.copyWith(
                      color: theme.colorScheme.onSurfaceVariant,
                    ),
                  ),
                ],
              ),
            ),
          ],
        ),
      ),
    );
  }

  List<Marker> _buildStopMarkers(ThemeData theme) =>
      _clusterStops().map((_StopCluster cluster) {
        final AssignedRouteMapStop representative = cluster.stops.first;
        final bool selected = cluster.stops.any(
          (AssignedRouteMapStop stop) => stop.stopId == widget.selectedStopId,
        );
        final bool allVerified = cluster.stops.every(
          (AssignedRouteMapStop stop) => stop.coordinatesVerified,
        );
        final String label = _clusterLabel(cluster);

        return Marker(
          point: cluster.point,
          width: 56,
          height: 56,
          child: Semantics(
            button: true,
            label: label,
            onTap: () => _activateCluster(context, cluster),
            child: ExcludeSemantics(
              child: Tooltip(
                message: label,
                child: InkWell(
                  customBorder: const CircleBorder(),
                  onTap: () => _activateCluster(context, cluster),
                  child: SizedBox(
                    width: 56,
                    height: 56,
                    child: Stack(
                      clipBehavior: Clip.none,
                      alignment: Alignment.center,
                      children: <Widget>[
                        Container(
                          width: selected ? 48 : 44,
                          height: selected ? 48 : 44,
                          alignment: Alignment.center,
                          decoration: BoxDecoration(
                            shape: BoxShape.circle,
                            color: allVerified
                                ? const Color(0xFF19734A)
                                : const Color(0xFFFFE7AE),
                            border: Border.all(
                              color: selected
                                  ? theme.colorScheme.tertiary
                                  : Colors.white,
                              width: selected ? 4 : 3,
                            ),
                            boxShadow: <BoxShadow>[
                              BoxShadow(
                                color: Colors.black.withValues(alpha: 0.24),
                                blurRadius: selected ? 8 : 5,
                                offset: const Offset(0, 2),
                              ),
                            ],
                          ),
                          child: Text(
                            cluster.stops.length == 1
                                ? _orderText(representative)
                                : '${cluster.stops.length}',
                            style: TextStyle(
                              color: allVerified
                                  ? Colors.white
                                  : const Color(0xFF5B3A00),
                              fontWeight: FontWeight.w800,
                              fontSize: cluster.stops.length == 1 ? 14 : 16,
                            ),
                          ),
                        ),
                        Positioned(
                          right: 0,
                          bottom: 0,
                          child: DecoratedBox(
                            decoration: BoxDecoration(
                              color: Colors.white,
                              shape: BoxShape.circle,
                              border: Border.all(
                                color: Colors.white,
                                width: 1,
                              ),
                            ),
                            child: Padding(
                              padding: const EdgeInsets.all(2),
                              child: Icon(
                                cluster.stops.length > 1
                                    ? Icons.layers_outlined
                                    : _statusIcon(representative.status),
                                size: 14,
                                color: cluster.stops.length > 1
                                    ? theme.colorScheme.primary
                                    : _statusColor(representative.status),
                              ),
                            ),
                          ),
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
          ),
        );
      }).toList();

  Marker _buildOwnLocationMarker(_LocationPresentation location) => Marker(
    point: location.point!,
    width: 48,
    height: 48,
    child: Semantics(
      label: location.statusText,
      child: ExcludeSemantics(
        child: DecoratedBox(
          decoration: BoxDecoration(
            color: location.markerColor,
            shape: BoxShape.circle,
            border: Border.all(color: Colors.white, width: 3),
            boxShadow: const <BoxShadow>[
              BoxShadow(color: Color(0x33000000), blurRadius: 6),
            ],
          ),
          child: Icon(
            Icons.person_pin_circle,
            color: Colors.white,
            size: 30,
          ),
        ),
      ),
    ),
  );

  List<_StopCluster> _clusterStops() {
    final List<AssignedRouteMapStop> stops = widget.stops
        .where(
          (AssignedRouteMapStop stop) =>
              stop.stopId.trim().isNotEmpty &&
              _isValidCoordinates(stop.latitude, stop.longitude),
        )
        .toList()
      ..sort((AssignedRouteMapStop a, AssignedRouteMapStop b) {
        final int orderComparison = a.plannedOrder.compareTo(b.plannedOrder);
        return orderComparison != 0
            ? orderComparison
            : a.stopId.compareTo(b.stopId);
      });

    final List<_MutableStopCluster> clusters = <_MutableStopCluster>[];
    final MapCamera? camera = _mapReady ? _mapController.camera : null;
    for (final AssignedRouteMapStop stop in stops) {
      final LatLng point = LatLng(stop.latitude!, stop.longitude!);
      final Offset? projected = camera?.projectAtZoom(point);
      _MutableStopCluster? overlappingCluster;

      for (final _MutableStopCluster cluster in clusters) {
        if (cluster.point == point ||
            (projected != null &&
                cluster.projectedPoint != null &&
                (projected - cluster.projectedPoint!).distance <=
                    _markerOverlapDistance)) {
          overlappingCluster = cluster;
          break;
        }
      }

      if (overlappingCluster == null) {
        clusters.add(
          _MutableStopCluster(
            point: point,
            projectedPoint: projected,
            stops: <AssignedRouteMapStop>[stop],
          ),
        );
      } else {
        overlappingCluster.stops.add(stop);
      }
    }

    return clusters
        .map(
          (_MutableStopCluster cluster) => _StopCluster(
            point: cluster.point,
            stops: List<AssignedRouteMapStop>.unmodifiable(cluster.stops),
          ),
        )
        .toList();
  }

  String _clusterLabel(_StopCluster cluster) {
    final List<String> details = cluster.stops
        .map(_stopAccessibleLabel)
        .toList();
    if (details.length == 1) return details.single;
    return '${details.length} overlapping stop markers. '
        'Activate to choose: ${details.join('; ')}.';
  }

  String _stopAccessibleLabel(AssignedRouteMapStop stop) =>
      '${stop.retailerName.trim().isEmpty ? 'Retailer' : stop.retailerName}, '
      'stop ${_orderText(stop)}, status ${_humanizeStatus(stop.status)}, '
      'coordinates ${stop.coordinatesVerified ? 'verified' : 'unverified'}';

  Future<void> _activateCluster(
    BuildContext context,
    _StopCluster cluster,
  ) async {
    if (cluster.stops.length == 1) {
      widget.onStopSelected(cluster.stops.single.stopId);
      return;
    }

    final AssignedRouteMapStop? chosenStop =
        await showModalBottomSheet<AssignedRouteMapStop>(
          context: context,
          useSafeArea: true,
          isScrollControlled: true,
          showDragHandle: true,
          builder: (BuildContext sheetContext) {
            final double listHeight = math.min(
              420,
              MediaQuery.sizeOf(sheetContext).height * 0.55,
            ).toDouble();
            return Padding(
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  Text(
                    'Stops at this location',
                    style: Theme.of(sheetContext).textTheme.titleMedium,
                  ),
                  const SizedBox(height: 8),
                  SizedBox(
                    height: listHeight,
                    child: ListView.separated(
                      itemCount: cluster.stops.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final AssignedRouteMapStop stop =
                            cluster.stops[index];
                        final bool isSelected =
                            stop.stopId == widget.selectedStopId;
                        return ListTile(
                          leading: CircleAvatar(
                            backgroundColor: stop.coordinatesVerified
                                ? const Color(0xFF19734A)
                                : const Color(0xFFFFE7AE),
                            foregroundColor: stop.coordinatesVerified
                                ? Colors.white
                                : const Color(0xFF5B3A00),
                            child: Text(_orderText(stop)),
                          ),
                          title: Text(
                            stop.retailerName.trim().isEmpty
                                ? 'Retailer'
                                : stop.retailerName,
                          ),
                          subtitle: Text(
                            '${_humanizeStatus(stop.status)} · '
                            '${stop.coordinatesVerified ? 'Verified' : 'Unverified'} '
                            'pin',
                          ),
                          trailing: isSelected
                              ? const Icon(Icons.check_circle_outline)
                              : null,
                          onTap: () => Navigator.of(sheetContext).pop(stop),
                        );
                      },
                    ),
                  ),
                ],
              ),
            );
          },
        );

    if (!mounted || chosenStop == null) return;
    widget.onStopSelected(chosenStop.stopId);
  }

  void _onMapReady() {
    if (!mounted) return;
    setState(() {
      _mapReady = true;
      _lastClusterZoom = _mapController.camera.zoom;
    });
  }

  void _onPositionChanged(MapCamera camera, bool _) {
    if (!_mapReady || _lastClusterZoom == camera.zoom) return;
    _lastClusterZoom = camera.zoom;
    if (mounted) setState(() {});
  }

  void _onTileError(TileImage tile, Object error, StackTrace? stackTrace) {
    if (_hasTileFailure || !mounted) return;
    setState(() => _hasTileFailure = true);
    final VoidCallback? onTileFailure = widget.onTileFailure;
    if (onTileFailure != null) {
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted) onTileFailure();
      });
    }
  }

  LatLng _initialCenter(_LocationPresentation location) {
    final String? selectedId = widget.selectedStopId;
    if (selectedId != null) {
      for (final AssignedRouteMapStop stop in widget.stops) {
        if (stop.stopId == selectedId &&
            _isValidCoordinates(stop.latitude, stop.longitude)) {
          return LatLng(stop.latitude!, stop.longitude!);
        }
      }
    }
    if (location.isAvailable) return location.point!;
    for (final AssignedRouteMapStop stop in widget.stops) {
      if (_isValidCoordinates(stop.latitude, stop.longitude)) {
        return LatLng(stop.latitude!, stop.longitude!);
      }
    }
    return const LatLng(0, 0);
  }

  void _fitMapToContent() {
    final _LocationPresentation location = _LocationPresentation.from(
      widget.ownLocation,
      DateTime.now(),
    );
    final List<LatLng> points = _uniquePoints(_mapPoints(location));
    if (points.isEmpty) return;
    if (points.length == 1) {
      _mapController.move(points.single, 14);
      return;
    }
    _mapController.fitCamera(_boundsFit(points));
  }

  List<LatLng> _uniquePoints(List<LatLng> points) {
    final Map<(double, double), LatLng> unique =
        <(double, double), LatLng>{};
    for (final LatLng point in points) {
      unique.putIfAbsent(
        (point.latitude, point.longitude),
        () => point,
      );
    }
    return unique.values.toList();
  }

  CameraFit _boundsFit(List<LatLng> points) => CameraFit.bounds(
    bounds: LatLngBounds.fromPoints(points),
    padding: const EdgeInsets.fromLTRB(44, 56, 44, 56),
    maxZoom: 15,
  );
}

class _StopCluster {
  const _StopCluster({required this.point, required this.stops});

  final LatLng point;
  final List<AssignedRouteMapStop> stops;
}

class _MutableStopCluster {
  _MutableStopCluster({
    required this.point,
    required this.projectedPoint,
    required this.stops,
  });

  final LatLng point;
  final Offset? projectedPoint;
  final List<AssignedRouteMapStop> stops;
}

enum _LocationFreshness { fresh, stale, unavailable }

class _LocationPresentation {
  const _LocationPresentation({
    required this.freshness,
    required this.statusText,
    required this.point,
    required this.accuracyMeters,
  });

  final _LocationFreshness freshness;
  final String statusText;
  final LatLng? point;
  final double? accuracyMeters;

  bool get isAvailable => freshness != _LocationFreshness.unavailable;

  Color get markerColor => switch (freshness) {
    _LocationFreshness.fresh => const Color(0xFF1769AA),
    _LocationFreshness.stale => const Color(0xFF687386),
    _LocationFreshness.unavailable => const Color(0xFF687386),
  };

  static _LocationPresentation from(
    AssignedRouteMapLocation? location,
    DateTime now,
  ) {
    if (location == null ||
        !_isValidCoordinates(location.latitude, location.longitude) ||
        location.capturedAt.isAfter(now)) {
      return const _LocationPresentation(
        freshness: _LocationFreshness.unavailable,
        statusText: 'Location not available',
        point: null,
        accuracyMeters: null,
      );
    }

    final Duration age = now.difference(location.capturedAt);
    final _LocationFreshness freshness = age <= kLocationFixMaxAge
        ? _LocationFreshness.fresh
        : _LocationFreshness.stale;
    final double? accuracy = location.accuracyMeters;
    final double? validAccuracy = accuracy != null &&
            accuracy.isFinite &&
            accuracy > 0
        ? accuracy
        : null;
    final String ageText = _formatAge(age);
    final String accuracyText = validAccuracy == null
        ? 'accuracy unavailable'
        : 'accuracy ±${validAccuracy.round()} m';
    final String statusText = freshness == _LocationFreshness.fresh
        ? 'Location fresh · updated $ageText · $accuracyText'
        : 'Location stale · last known, updated $ageText · $accuracyText';

    return _LocationPresentation(
      freshness: freshness,
      statusText: statusText,
      point: LatLng(location.latitude, location.longitude),
      accuracyMeters: validAccuracy,
    );
  }
}

bool _isValidCoordinates(double? latitude, double? longitude) =>
    latitude != null &&
    longitude != null &&
    latitude.isFinite &&
    longitude.isFinite &&
    latitude >= -_webMercatorLatitudeLimit &&
    latitude <= _webMercatorLatitudeLimit &&
    longitude >= -180 &&
    longitude <= 180;

bool _isValidRoadGeometry(List<LatLng> points) =>
    points.length >= 2 &&
    points.every(
      (LatLng point) =>
          _isValidCoordinates(point.latitude, point.longitude),
    );

String _orderText(AssignedRouteMapStop stop) =>
    stop.plannedOrder > 0 ? '${stop.plannedOrder}' : '?';

String _humanizeStatus(String status) {
  final String cleaned = status.trim().replaceAll(RegExp(r'[_-]+'), ' ');
  if (cleaned.isEmpty) return 'Status unavailable';
  return cleaned
      .split(RegExp(r'\s+'))
      .map(
        (String word) => word.isEmpty
            ? word
            : '${word[0].toUpperCase()}${word.substring(1)}',
      )
      .join(' ');
}

IconData _statusIcon(String status) => switch (status.trim().toLowerCase()) {
  'completed' => Icons.check,
  'arrived' => Icons.flag,
  'skipped' => Icons.block,
  'in_progress' => Icons.directions_walk,
  _ => Icons.schedule,
};

Color _statusColor(String status) => switch (status.trim().toLowerCase()) {
  'completed' || 'arrived' => const Color(0xFF177245),
  'skipped' => const Color(0xFF9B3D3D),
  'in_progress' => const Color(0xFF1769AA),
  _ => const Color(0xFF626D7B),
};

String _formatAge(Duration age) {
  if (age.inSeconds < 60) {
    return age.inSeconds <= 5 ? 'just now' : '${age.inSeconds} sec ago';
  }
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 24) return '${age.inHours} hr ago';
  return '${age.inDays} d ago';
}
