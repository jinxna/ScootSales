import 'dart:math';

final RegExp _legacyOrderSubmissionIdPattern = RegExp(r'^ORD-\d+$');
final RegExp _personalOrderV1IdPattern = RegExp(r'^ORD-P1-[0-9a-f]{32}$');
final RegExp _assignedVisitOrderV1IdPattern = RegExp(r'^ORD-V1-[0-9a-f]{64}$');
final RegExp _assignedVisitOrderV2IdPattern = RegExp(
  r'^ORD-V2-[A-Za-z0-9_-]{1,128}\.[A-Za-z0-9_-]{1,100}\.[A-Za-z0-9_-]{1,300}$',
);
final RegExp _assignedVisitIdentityPartPattern = RegExp(r'^[A-Za-z0-9_-]+$');

bool isOrderSubmissionId(String value) {
  final String candidate = value.trim();
  return _legacyOrderSubmissionIdPattern.hasMatch(candidate) ||
      _personalOrderV1IdPattern.hasMatch(candidate) ||
      _assignedVisitOrderV1IdPattern.hasMatch(candidate) ||
      _assignedVisitOrderV2IdPattern.hasMatch(candidate);
}

String assignedVisitOrderId({
  required String salesmanUid,
  required String routePlanId,
  required String routeStopId,
}) {
  final String uid = salesmanUid.trim();
  final String planId = routePlanId.trim();
  final String stopId = routeStopId.trim();
  final List<String> parts = <String>[uid, planId, stopId];
  if (parts.any((String value) =>
      value.isEmpty || !_assignedVisitIdentityPartPattern.hasMatch(value)) ||
      uid.length > 128 ||
      planId.length > 100 ||
      stopId.length > 300) {
    throw ArgumentError('Assigned visit order identity cannot be empty.');
  }
  return 'ORD-V2-$uid.$planId.$stopId';
}

String resolveOrderSubmissionId(String pendingOrderId, DateTime submittedAt) {
  final String existing = pendingOrderId.trim();
  if (isOrderSubmissionId(existing)) return existing;
  final Random random = Random.secure();
  final String randomHex = List<String>.generate(
    16,
    (_) => random.nextInt(256).toRadixString(16).padLeft(2, '0'),
    growable: false,
  ).join();
  return 'ORD-P1-$randomHex';
}

DateTime? legacyOrderIdTimestamp(String value) {
  final String candidate = value.trim();
  if (!_legacyOrderSubmissionIdPattern.hasMatch(candidate)) return null;
  final int? milliseconds = int.tryParse(candidate.substring(4));
  if (milliseconds == null || milliseconds <= 0) return null;
  final DateTime parsed = DateTime.fromMillisecondsSinceEpoch(milliseconds);
  if (parsed.isAfter(DateTime.utc(2100))) return null;
  return parsed;
}

bool matchesOrderSubmissionIdentity(
  Map<String, dynamic> data, {
  required String orderId,
  required String salesmanUid,
  required String retailerId,
  String? routePlanId,
  String? routeStopId,
}) {
  final bool baseMatches =
      data['orderId']?.toString().trim() == orderId.trim() &&
      data['salesmanUid']?.toString().trim() == salesmanUid.trim() &&
      data['retailerId']?.toString().trim() == retailerId.trim();
  if (!baseMatches) return false;
  if (routePlanId != null &&
      data['routePlanId']?.toString().trim() != routePlanId.trim()) {
    return false;
  }
  if (routeStopId != null &&
      data['routeStopId']?.toString().trim() != routeStopId.trim()) {
    return false;
  }
  return true;
}
