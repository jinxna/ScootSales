import 'package:cloud_firestore/cloud_firestore.dart';

enum StaleRequestAudience { admin, supervisor, branchManager }

List<Map<String, dynamic>> deriveTeamAlerts({
  required List<Map<String, dynamic>> orders,
  required List<Map<String, dynamic>> visits,
  List<Map<String, dynamic>> specialRequests = const <Map<String, dynamic>>[],
  StaleRequestAudience audience = StaleRequestAudience.admin,
  int limit = 100,
}) {
  final List<Map<String, dynamic>> alerts = <Map<String, dynamic>>[];

  for (final Map<String, dynamic> order in orders) {
    final String docId = _text(order['docId'] ?? order['orderId']);
    if (docId.isEmpty) continue;
    final String salesman = _text(
      order['salesmanName'] ?? order['salesman_name'],
      fallback: 'A salesman',
    );
    final String retailer = _text(
      order['retailerName'] ?? order['retailer_name'],
      fallback: 'a retailer',
    );
    final String status = _text(
      order['status'] ?? order['submissionStatus'] ?? order['syncStatus'],
    ).toLowerCase();
    if (status.contains('draft')) continue;

    final DateTime? submitted = _date(
      order['submittedAt'] ??
          order['submitted_at'] ??
          order['createdAt'] ??
          order['created_at'] ??
          order['orderDate'],
    );
    if (submitted != null) {
      alerts.add(
        _row(
          order,
          docId: docId,
          suffix: 'submitted',
          type: 'order_submitted',
          message: 'New order submitted by $salesman for $retailer.',
          at: submitted,
          salesman: salesman,
          retailer: retailer,
          orderDocId: docId,
        ),
      );
    }
    final bool approved = status.contains('approved');
    final bool rejected = status.contains('reject');
    if (approved || rejected) {
      final DateTime? at = _date(
        approved
            ? (order['approvedAt'] ?? order['updatedAt'])
            : (order['rejectedAt'] ?? order['updatedAt']),
      );
      if (at != null) {
        alerts.add(
          _row(
            order,
            docId: docId,
            suffix: approved ? 'approved' : 'rejected',
            type: approved ? 'order_approved' : 'order_rejected',
            message:
                "$salesman's order for $retailer was "
                '${approved ? 'approved' : 'rejected'}.',
            at: at,
            salesman: salesman,
            retailer: retailer,
            orderDocId: docId,
          ),
        );
      }
    }
  }

  for (final Map<String, dynamic> visit in visits) {
    final String docId = _text(visit['docId'] ?? visit['visitId']);
    if (docId.isEmpty) continue;
    final DateTime? at = _date(visit['arrivalTime'] ?? visit['arrival_time']);
    if (at == null) continue;
    final String salesman = _text(
      visit['salesmanName'] ?? visit['salesman_name'],
      fallback: 'A salesman',
    );
    final String retailer = _text(
      visit['retailerName'] ?? visit['retailer_name'],
      fallback: 'a retailer',
    );
    alerts.add(
      _row(
        visit,
        docId: docId,
        suffix: 'arrival',
        type: 'arrival',
        message: '$salesman arrived at $retailer.',
        at: at,
        salesman: salesman,
        retailer: retailer,
        orderDocId: '',
        sourceCollection: 'visit_logs',
      ),
    );
  }

  for (final Map<String, dynamic> request in staleSpecialRequests(
    specialRequests,
    audience: audience,
  )) {
    final String docId = _text(request['docId'] ?? request['orderId']);
    final DateTime? at = _date(request['createdAt']);
    if (docId.isEmpty || at == null) continue;
    final String retailer = _text(
      request['retailerName'] ?? request['retailer_name'],
      fallback: 'a retailer',
    );
    alerts.add(
      _row(
        request,
        docId: docId,
        suffix: 'stale',
        type: 'special_request_overdue',
        message: audience == StaleRequestAudience.branchManager
            ? 'Special request for $retailer is still waiting for a decision after more than 24 hours.'
            : 'Special request for $retailer waiting more than 24 hours.',
        at: at.add(const Duration(hours: 24)),
        salesman: _text(request['salesmanName'], fallback: 'A salesman'),
        retailer: retailer,
        orderDocId: _text(request['orderId'], fallback: docId),
        sourceCollection: 'special_requests',
      ),
    );
  }

  alerts.sort(
    (Map<String, dynamic> a, Map<String, dynamic> b) =>
        (b['createdAt'] as DateTime).compareTo(a['createdAt'] as DateTime),
  );
  return alerts.length > limit
      ? alerts.take(limit).toList(growable: false)
      : alerts;
}

List<Map<String, dynamic>> staleSpecialRequests(
  List<Map<String, dynamic>> requests, {
  DateTime? now,
  StaleRequestAudience audience = StaleRequestAudience.admin,
}) {
  final DateTime cutoff = (now ?? DateTime.now()).subtract(
    const Duration(hours: 24),
  );
  return requests
      .where((Map<String, dynamic> request) {
        final String status = _text(request['status']).toLowerCase();
        if (!status.startsWith('pending')) return false;
        if (audience == StaleRequestAudience.supervisor &&
            status != 'pending_supervisor') {
          return false;
        }
        final DateTime? created = _date(request['createdAt']);
        return created != null && created.isBefore(cutoff);
      })
      .toList(growable: false);
}

Map<String, dynamic> _row(
  Map<String, dynamic> source, {
  required String docId,
  required String suffix,
  required String type,
  required String message,
  required DateTime at,
  required String salesman,
  required String retailer,
  required String orderDocId,
  String sourceCollection = 'orders',
}) {
  return <String, dynamic>{
    'docId': 'derived_${sourceCollection}_${docId}_$suffix',
    'sourceCollection': sourceCollection,
    'derived': true,
    'notification_type': type,
    'type': type,
    'message': message,
    'salesmanCode': _text(source['salesmanCode'] ?? source['salesman_code']),
    'salesmanName': salesman,
    'retailerName': retailer,
    'branchId': _text(source['branchId'] ?? source['branch_id']),
    if (orderDocId.isNotEmpty) 'orderDocId': orderDocId,
    if (orderDocId.isNotEmpty) 'reference_id': orderDocId,
    'createdAt': at,
  };
}

String _text(Object? value, {String fallback = ''}) {
  final String text = value?.toString().trim() ?? '';
  return text.isEmpty || text.toLowerCase() == 'null' ? fallback : text;
}

DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is int) {
    return DateTime.fromMillisecondsSinceEpoch(
      value > 9999999999 ? value : value * 1000,
      isUtc: true,
    );
  }
  if (value is String) return DateTime.tryParse(value);
  return null;
}
