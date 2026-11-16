import 'package:flutter/painting.dart' show ColorFilter;
import 'package:flutter/widgets.dart' show BuildContext, ColorFiltered, Widget;
import 'package:flutter_map/flutter_map.dart';

abstract final class GeoapifyConfig {
  static const String apiKey = String.fromEnvironment(
    'GEOAPIFY_API_KEY',
    defaultValue: '',
  );

  static const String routePreviewStyle = 'osm-carto';
  static const String lightStyle = 'positron';

  static bool get isConfigured => apiKey.trim().isNotEmpty;

  static String tileUrl(String style) =>
      'https://maps.geoapify.com/v1/tile/$style/{z}/{x}/{y}.png'
      '?apiKey=${Uri.encodeQueryComponent(apiKey.trim())}';

  static TileLayer lightTileLayer() {
    final MapTiles tiles = MapTiles.light();
    return TileLayer(
      urlTemplate: tiles.urlTemplate,
      subdomains: tiles.subdomains,
      userAgentPackageName: 'com.norman.digitalsalesorder.admin',
      maxZoom: tiles.isGeoapify ? 20 : 19,
      tileBuilder: tiles.isGeoapify
          ? null
          : (BuildContext context, Widget tile, TileImage image) =>
                ColorFiltered(colorFilter: _positronSoftening, child: tile),
    );
  }

  static const ColorFilter _positronSoftening = ColorFilter.matrix(<double>[
    0.62,
    0.38,
    0.06,
    0,
    30,
    0.20,
    0.80,
    0.06,
    0,
    30,
    0.20,
    0.38,
    0.48,
    0,
    30,
    0,
    0,
    0,
    1,
    0,
  ]);
}

class MapTiles {
  const MapTiles({
    required this.urlTemplate,
    required this.subdomains,
    required this.attribution,
    required this.isGeoapify,
  });

  final String urlTemplate;
  final List<String> subdomains;
  final String attribution;
  final bool isGeoapify;

  static const String osmAttribution = '© OpenStreetMap contributors';

  static MapTiles light() => GeoapifyConfig.isConfigured
      ? MapTiles(
          urlTemplate: GeoapifyConfig.tileUrl(GeoapifyConfig.lightStyle),
          subdomains: const <String>[],
          attribution:
              'Powered by Geoapify · OpenMapTiles · '
              'OpenStreetMap contributors',
          isGeoapify: true,
        )
      : const MapTiles(
          urlTemplate: 'https://tile.openstreetmap.org/{z}/{x}/{y}.png',
          subdomains: <String>[],
          attribution: osmAttribution,
          isGeoapify: false,
        );
}
