import 'dart:async';

import 'package:geolocator/geolocator.dart';

Future<Position?> acquireLocationFix({
  required bool Function(Position position) isUsable,
  Duration preciseWait = const Duration(seconds: 15),
  Duration coarseWait = const Duration(seconds: 10),
}) async {
  final List<Position> candidates = <Position>[];

  Future<Position?> request(LocationAccuracy accuracy, Duration wait) async {
    try {
      return await Geolocator.getCurrentPosition(
        locationSettings: LocationSettings(accuracy: accuracy, timeLimit: wait),
      ).timeout(wait + const Duration(seconds: 1));
    } catch (_) {
      return null;
    }
  }

  final Position? precise = await request(LocationAccuracy.high, preciseWait);
  if (precise != null) {
    if (isUsable(precise)) return precise;
    candidates.add(precise);
  }

  try {
    final Position? last = await Geolocator.getLastKnownPosition();
    if (last != null) {
      if (isUsable(last)) return last;
      candidates.add(last);
    }
  } catch (_) {
  }

  final Position? coarse = coarseWait > Duration.zero
      ? await request(LocationAccuracy.medium, coarseWait)
      : null;
  if (coarse != null) {
    if (isUsable(coarse)) return coarse;
    candidates.add(coarse);
  }

  if (candidates.isEmpty) return null;
  candidates.sort(
    (Position a, Position b) => b.timestamp.compareTo(a.timestamp),
  );
  return candidates.first;
}
