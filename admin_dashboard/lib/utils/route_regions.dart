import 'package:latlong2/latlong.dart';

import 'geo_field_utils.dart';
import 'retailer_readiness.dart';

const String kUnzonedRegion = 'Unzoned';

const Map<String, List<String>> _regionTokens = <String, List<String>>{
  'Matang': <String>['matang', 'metrocity'],
  'Batu Kawa': <String>['batu kawa', 'batu_kawa', 'batukawa', 'kawah', 'moyan'],
  'Tabuan': <String>['tabuan', 'stutong'],
  'Kuching Central': <String>[
    'kuching central',
    'kuching_central',
    'merdeka',
    'boulevard',
    'vivacity',
    'riveredge',
    'jalan song',
    'farley',
    '3rd mile',
    '3rdmile',
    '4th mile',
    '4thmile',
  ],
};

const Map<String, LatLng> _regionCentroids = <String, LatLng>{
  'Matang': LatLng(1.5650, 110.3100),
  'Batu Kawa': LatLng(1.5200, 110.2750),
  'Tabuan': LatLng(1.5220, 110.3810),
  'Kuching Central': LatLng(1.5250, 110.3430),
};

const Distance _distance = DistanceHaversine(roundResult: false);

String resolveRetailerRegion(Map<String, dynamic> row) {
  final String explicit = retailerRegion(row);
  if (explicit.isNotEmpty) return explicit;

  final String haystack = <String>[
    _text(row['docId']),
    _text(row['retailerId'] ?? row['retailer_id'] ?? row['id']),
    _text(row['name'] ?? row['retailerName'] ?? row['retailer_name']),
    _text(row['address'] ?? row['area'] ?? row['location']),
    retailerSubRegion(row),
    retailerTerritory(row),
  ].join(' ').toLowerCase();

  for (final MapEntry<String, List<String>> entry in _regionTokens.entries) {
    for (final String token in entry.value) {
      if (haystack.contains(token)) return entry.key;
    }
  }

  final LatLng? position = readLatLng(row);
  if (position != null) {
    String? best;
    double bestKm = double.infinity;
    _regionCentroids.forEach((String region, LatLng centroid) {
      final double km = _distance.as(LengthUnit.Kilometer, position, centroid);
      if (km < bestKm) {
        bestKm = km;
        best = region;
      }
    });
    if (best != null && bestKm <= 8) return best!;
  }
  return kUnzonedRegion;
}

List<List<T>> assignRegionDays<T>(
  List<T> items, {
  required String Function(T) regionOf,
  required double Function(T) scoreOf,
  List<String> Function(T)? preferredDaysOf,
  required int maxPerDay,
  int days = 6,
}) {
  final List<List<T>> buckets = List<List<T>>.generate(
    days < 0 ? 0 : days,
    (_) => <T>[],
  );
  if (items.isEmpty || days <= 0) return buckets;

  final Map<String, List<T>> byRegion = <String, List<T>>{};
  for (final T item in items) {
    final String region = regionOf(item).trim();
    byRegion
        .putIfAbsent(region.isEmpty ? kUnzonedRegion : region, () => <T>[])
        .add(item);
  }
  double regionBest(String region) => byRegion[region]!
      .map(scoreOf)
      .fold(double.negativeInfinity, (double m, double v) => v > m ? v : m);
  final List<String> regionOrder = byRegion.keys.toList()
    ..sort((String a, String b) {
      final int byScore = regionBest(b).compareTo(regionBest(a));
      return byScore != 0 ? byScore : a.compareTo(b);
    });

  final List<T> ordered = <T>[];
  for (final String region in regionOrder) {
    final List<T> group = byRegion[region]!
      ..sort((T a, T b) => scoreOf(b).compareTo(scoreOf(a)));
    ordered.addAll(group);
  }

  final int cap = maxPerDay <= 0 ? 1 : maxPerDay;
  for (int i = 0; i < ordered.length; i++) {
    final int raw = i ~/ cap;
    buckets[raw < days ? raw : days - 1].add(ordered[i]);
  }

  if (preferredDaysOf != null) {
    for (int d = 0; d < days; d++) {
      for (final T item in List<T>.of(buckets[d])) {
        final Set<int> prefs = preferredDaysOf(item)
            .map(weekdayIndexFromName)
            .whereType<int>()
            .where((int i) => i >= 0 && i < days)
            .toSet();
        if (prefs.isEmpty || prefs.contains(d)) continue;
        for (final int pd in prefs) {
          if (buckets[pd].length < cap) {
            buckets[d].remove(item);
            buckets[pd].add(item);
            break;
          }
        }
      }
    }
  }
  return buckets;
}

int? weekdayIndexFromName(String name) {
  switch (name.trim().toLowerCase()) {
    case 'monday':
    case 'mon':
      return 0;
    case 'tuesday':
    case 'tue':
    case 'tues':
      return 1;
    case 'wednesday':
    case 'wed':
      return 2;
    case 'thursday':
    case 'thu':
    case 'thur':
    case 'thurs':
      return 3;
    case 'friday':
    case 'fri':
      return 4;
    case 'saturday':
    case 'sat':
      return 5;
    case 'sunday':
    case 'sun':
      return 6;
  }
  return null;
}

String _text(Object? value) => value?.toString().trim() ?? '';
