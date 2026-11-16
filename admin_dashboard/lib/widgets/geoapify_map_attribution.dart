import 'dart:async';

import 'package:flutter/material.dart';
import 'package:flutter_map/flutter_map.dart';
import 'package:url_launcher/url_launcher.dart';

import '../services/geoapify_config.dart';

class GeoapifyMapAttribution extends StatelessWidget {
  const GeoapifyMapAttribution({super.key, this.includeOpenMapTiles = true});

  final bool includeOpenMapTiles;

  @override
  Widget build(BuildContext context) {
    if (!GeoapifyConfig.isConfigured) {
      return const RichAttributionWidget(
        attributions: <SourceAttribution>[
          TextSourceAttribution(
            'OpenStreetMap contributors',
            onTap: _openOpenStreetMapCopyright,
          ),
        ],
      );
    }
    return RichAttributionWidget(
      attributions: <SourceAttribution>[
        const TextSourceAttribution(
          'Powered by Geoapify',
          prependCopyright: false,
          onTap: _openGeoapify,
        ),
        if (includeOpenMapTiles)
          const TextSourceAttribution('OpenMapTiles', onTap: _openOpenMapTiles),
        const TextSourceAttribution(
          'OpenStreetMap contributors',
          onTap: _openOpenStreetMapCopyright,
        ),
      ],
    );
  }
}

void _openGeoapify() => unawaited(
  launchUrl(
    Uri.https('www.geoapify.com'),
    mode: LaunchMode.externalApplication,
  ),
);

void _openOpenMapTiles() => unawaited(
  launchUrl(
    Uri.https('openmaptiles.org'),
    mode: LaunchMode.externalApplication,
  ),
);

void _openOpenStreetMapCopyright() => unawaited(
  launchUrl(
    Uri.https('www.openstreetmap.org', '/copyright'),
    mode: LaunchMode.externalApplication,
  ),
);
