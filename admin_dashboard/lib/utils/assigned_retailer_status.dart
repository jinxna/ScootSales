enum AssignedRetailerStatus { pending, completed, skipped, missingCoordinates }

AssignedRetailerStatus assignedRetailerStatus({
  required double lat,
  required double lng,
  required String stopStatus,
  required String retailerId,
  required Set<String> completedRetailerIds,
}) {
  final String status = stopStatus.trim().toLowerCase();
  if (status == 'skipped') return AssignedRetailerStatus.skipped;
  final String id = retailerId.trim();
  final bool served = id.isNotEmpty && completedRetailerIds.contains(id);
  if (status == 'completed' || status == 'visited' || served) {
    return AssignedRetailerStatus.completed;
  }
  if (!_usableCoordinate(lat, lng)) {
    return AssignedRetailerStatus.missingCoordinates;
  }
  return AssignedRetailerStatus.pending;
}

bool _usableCoordinate(double lat, double lng) {
  if (lat == 0 && lng == 0) return false;
  if (lat.abs() > 90 || lng.abs() > 180) return false;
  return true;
}
