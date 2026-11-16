class GuidedVisitContext {
  const GuidedVisitContext({
    required this.planId,
    required this.stopId,
    required this.branchId,
    this.retailerLatitude = 0,
    this.retailerLongitude = 0,
  });

  final String planId;
  final String stopId;
  final String branchId;
  final double retailerLatitude;
  final double retailerLongitude;

  String get sessionKey => '${_safe(planId)}_${_safe(stopId)}';
  String get routeName => 'guided_visit_$sessionKey';

  Map<String, dynamic> get orderFields => <String, dynamic>{
    'visitSource': 'assigned_route',
    'routePlanId': planId,
    'routeStopId': stopId,
    if (branchId.trim().isNotEmpty) 'branchId': branchId.trim(),
  };

  static String _safe(String value) {
    final String trimmed = value.trim();
    final StringBuffer escaped = StringBuffer();
    for (final int unit in trimmed.codeUnits) {
      final bool plain =
          (unit >= 0x30 && unit <= 0x39) ||
          (unit >= 0x41 && unit <= 0x5A) ||
          (unit >= 0x61 && unit <= 0x7A);
      if (plain) {
        escaped.writeCharCode(unit);
      } else {
        escaped.write('%${unit.toRadixString(16).padLeft(4, '0')}');
      }
    }
    return escaped.isEmpty ? '%empty' : escaped.toString();
  }
}
