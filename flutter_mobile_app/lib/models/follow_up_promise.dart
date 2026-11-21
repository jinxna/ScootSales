import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;

import '../utils/retailer_memory.dart' show reasonCodeLabel;
import 'assigned_route_plan.dart';

const int followUpMaxDaysAhead = 60;

enum FollowUpStatus { open, completed, cancelled }

final RegExp _dateKey = RegExp(r'^\d{4}-\d{2}-\d{2}$');

String followUpDateKey(DateTime day) =>
    '${day.year.toString().padLeft(4, '0')}-'
    '${day.month.toString().padLeft(2, '0')}-'
    '${day.day.toString().padLeft(2, '0')}';

DateTime? followUpDateOf(String key) =>
    _dateKey.hasMatch(key) ? DateTime.tryParse(key) : null;

class FollowUpPromise {
  const FollowUpPromise({
    required this.outcomeId,
    required this.retailerId,
    required this.shop,
    required this.date,
    required this.about,
    required this.status,
    required this.recordedAt,
  });

  final String outcomeId;
  final String retailerId;
  final String shop;
  final DateTime date;
  final String about;
  final FollowUpStatus status;
  final DateTime? recordedAt;

  String get dateKey => followUpDateKey(date);

  Map<String, dynamic> toMap() => <String, dynamic>{
    'outcomeId': outcomeId,
    'retailerId': retailerId,
    'retailerName': shop,
    'followUpDate': dateKey,
    'followUpStatus': status.name,
    'note': about,
    if (recordedAt != null) 'clientCreatedAt': recordedAt!.toIso8601String(),
  };

  static FollowUpPromise? fromOutcome(Map<String, dynamic> outcome) {
    if (outcome['isDemo'] == true) return null;
    final DateTime? date = followUpDateOf(
      '${outcome['followUpDate'] ?? ''}'.trim(),
    );
    final String statusText = '${outcome['followUpStatus'] ?? ''}'
        .trim()
        .toLowerCase();
    FollowUpStatus? status;
    for (final FollowUpStatus one in FollowUpStatus.values) {
      if (one.name == statusText) status = one;
    }
    final String outcomeId = '${outcome['outcomeId'] ?? ''}'.trim();
    if (date == null || status == null) return null;
    final String note = '${outcome['note'] ?? ''}'.trim();
    final String product = '${outcome['productName'] ?? ''}'.trim();
    return FollowUpPromise(
      outcomeId: outcomeId,
      retailerId: '${outcome['retailerId'] ?? ''}'.trim(),
      shop: '${outcome['retailerName'] ?? ''}'.trim(),
      date: date,
      about: note.isNotEmpty
          ? note
          : product.isNotEmpty
          ? product
          : reasonCodeLabel('${outcome['reasonCode'] ?? ''}').toLowerCase(),
      status: status,
      recordedAt: _when(outcome['clientCreatedAt'] ?? outcome['submittedAt']),
    );
  }

  static DateTime? _when(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse('${value ?? ''}');
  }
}

List<FollowUpPromise> openFollowUpPromises(
  Iterable<Map<String, dynamic>> outcomes,
) {
  final Map<String, FollowUpPromise> byOutcome = <String, FollowUpPromise>{};
  int unnamed = 0;
  for (final Map<String, dynamic> outcome in outcomes) {
    final FollowUpPromise? promise = FollowUpPromise.fromOutcome(outcome);
    if (promise == null) continue;
    byOutcome[promise.outcomeId.isEmpty
            ? '\u0000${unnamed++}'
            : promise.outcomeId] =
        promise;
  }
  return byOutcome.values
      .where((FollowUpPromise one) => one.status == FollowUpStatus.open)
      .toList()
    ..sort((FollowUpPromise a, FollowUpPromise b) {
      final int byDate = a.date.compareTo(b.date);
      return byDate != 0 ? byDate : a.shop.compareTo(b.shop);
    });
}

DateTime? nextVisitDay(
  AssignedRoutePlan plan,
  String retailerId,
  DateTime today,
) {
  final String shop = retailerId.trim();
  if (shop.isEmpty) return null;
  final DateTime start = DateTime(today.year, today.month, today.day);
  final DateTime last = start.add(const Duration(days: followUpMaxDaysAhead));
  DateTime? next;
  for (final AssignedRouteDay day in plan.days) {
    final DateTime? date = day.date;
    if (date == null) continue;
    final DateTime onDay = DateTime(date.year, date.month, date.day);
    if (!onDay.isAfter(start) || onDay.isAfter(last)) continue;
    if (next != null && !onDay.isBefore(next)) continue;
    if (day.stops.any(
      (AssignedRouteStop stop) => stop.retailerId.trim() == shop,
    )) {
      next = onDay;
    }
  }
  return next;
}
