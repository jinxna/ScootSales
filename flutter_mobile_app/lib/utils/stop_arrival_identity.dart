class StopArrivalIdentity {
  const StopArrivalIdentity._();

  static String documentId({
    required String planId,
    required String salesmanUid,
    required String stopId,
  }) {
    return '${_clean(planId)}_${_clean(salesmanUid)}_${_clean(stopId)}';
  }

  static String eventId({
    required String planId,
    required String stopId,
  }) {
    return '${_clean(planId)}_${_clean(stopId)}_arrival';
  }

  static bool isAcceptableEventId(String value) {
    final String trimmed = value.trim();
    return trimmed.isNotEmpty && trimmed.length <= 100;
  }

  static String _clean(String value) {
    return value.trim().replaceAll('%', '%25').replaceAll('/', '%2F');
  }
}
