enum FleetStatusGroup { online, lastKnown, offline }

FleetStatusGroup fleetStatusGroup(String statusKind) {
  switch (statusKind) {
    case 'active':
      return FleetStatusGroup.online;
    case 'stale':
      return FleetStatusGroup.lastKnown;
    default:
      return FleetStatusGroup.offline;
  }
}

bool fleetEntryMatches({
  required String statusKind,
  required String name,
  required String lastLocation,
  required Set<FleetStatusGroup> groups,
  required String query,
}) {
  if (groups.isNotEmpty && !groups.contains(fleetStatusGroup(statusKind))) {
    return false;
  }
  final String q = query.trim().toLowerCase();
  if (q.isEmpty) return true;
  return name.toLowerCase().contains(q) ||
      lastLocation.toLowerCase().contains(q);
}
