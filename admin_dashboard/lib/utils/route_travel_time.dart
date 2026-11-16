const double kRouteFallbackSpeedKmh = 28;

int estimateRouteTravelMinutes(
  double distanceKm, {
  double speedKmh = kRouteFallbackSpeedKmh,
}) {
  if (!distanceKm.isFinite || distanceKm <= 0) return 0;
  if (!speedKmh.isFinite || speedKmh <= 0) return 0;
  return (distanceKm / speedKmh * 60).round();
}
