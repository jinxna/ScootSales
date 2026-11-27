import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/ai_data_freshness.dart';

class RetailerSegment {
  const RetailerSegment({
    required this.retailerId,
    required this.segment,
    required this.attentionScore,
    required this.activeInsightCount,
    required this.highPriorityCount,
    required this.valueAtRiskRm,
    required this.topIssueTypes,
    this.routePriority = 'normal',
    this.considerVisitingEarlier = false,
    this.status = 'active',
    this.generatedAt,
    this.updatedAt,
    this.freshnessAt,
  });

  final String retailerId;
  final String segment;
  final int attentionScore;
  final int activeInsightCount;
  final int highPriorityCount;
  final double valueAtRiskRm;
  final List<String> topIssueTypes;
  final String routePriority;
  final bool considerVisitingEarlier;
  final String status;
  final DateTime? generatedAt;
  final DateTime? updatedAt;

  final DateTime? freshnessAt;

  factory RetailerSegment.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    return RetailerSegment.fromMap(snapshot.id, snapshot.data());
  }

  factory RetailerSegment.fromMap(String id, Map<String, dynamic> data) {
    final Object? rawTypes = data['topIssueTypes'];
    return RetailerSegment(
      retailerId: _text(data['retailerId'], fallback: id),
      segment: _text(data['segment'], fallback: 'low_signal'),
      attentionScore: _integer(data['attentionScore']).clamp(0, 100),
      activeInsightCount: _integer(data['activeInsightCount']),
      highPriorityCount: _integer(data['highPriorityCount']),
      valueAtRiskRm: _number(data['valueAtRiskRm']),
      topIssueTypes: rawTypes is List
          ? rawTypes
                .map((Object? value) => _text(value))
                .where((String value) => value.isNotEmpty)
                .take(3)
                .toList(growable: false)
          : const <String>[],
      routePriority: _routePriority(
        data['routePriority'],
        attentionScore: _integer(data['attentionScore']).clamp(0, 100),
      ),
      considerVisitingEarlier: data['considerVisitingEarlier'] == true,
      status: _text(data['status'], fallback: 'active'),
      generatedAt: _date(data['generatedAt']),
      updatedAt: _date(data['updatedAt']),
      freshnessAt: aiDataTimestamp(data),
    );
  }

  bool get isActive => status == 'active';

  bool get needsAttention =>
      isActive && (segment == 'at_risk' || attentionScore >= 55);

  String get label {
    if (routePriority == 'urgent') return 'Urgent';
    if (routePriority == 'high') return 'Priority';
    switch (segment) {
      case 'at_risk':
        return 'Attention';
      case 'growth':
        return 'Growth';
      case 'stable':
        return 'Stable';
      default:
        return 'Low signal';
    }
  }
}

String _routePriority(Object? value, {required int attentionScore}) {
  final String priority = _text(value).toLowerCase();
  if (priority == 'urgent' || priority == 'high' || priority == 'normal') {
    return priority;
  }
  if (attentionScore >= 75) return 'urgent';
  if (attentionScore >= 55) return 'high';
  return 'normal';
}

String _text(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  return text.isEmpty ? fallback : text;
}

int _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? 0;
}

double _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(_text(value)) ?? 0;
}

DateTime? _date(Object? value) {
  return aiDataTimestamp(<String, dynamic>{'generatedAt': value});
}
