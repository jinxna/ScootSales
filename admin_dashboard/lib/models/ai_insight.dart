import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/ai_data_freshness.dart';

class AiInsight {
  const AiInsight({
    required this.id,
    required this.issueKey,
    required this.type,
    required this.priority,
    required this.confidence,
    required this.confidenceScore,
    required this.status,
    required this.autoState,
    required this.outcomeCount,
    required this.outcomeQualityScore,
    required this.retailerId,
    required this.retailerName,
    required this.productId,
    required this.productName,
    required this.salesmanUid,
    required this.salesmanCode,
    required this.branchId,
    required this.reason,
    required this.recommendation,
    required this.questions,
    required this.valueAtRiskRm,
    required this.forecastNextWeek,
    required this.anomalyScore,
    required this.ageDays,
    required this.dueDate,
    required this.fixTarget,
    required this.fixEntityId,
    required this.updatedAt,
    required this.isDemo,
    this.createdAt,
    this.generatedAt,
    this.freshnessAt,
    this.lastObservedWeekStart,
    this.autoSuppressedAt,
    this.autoSuppressionReason = '',
    this.latestEvidence = const <String, dynamic>{},
  });

  final String id;
  final String issueKey;
  final String type;
  final String priority;
  final String confidence;
  final double confidenceScore;
  final String status;
  final String autoState;
  final int outcomeCount;
  final int outcomeQualityScore;
  final String retailerId;
  final String retailerName;
  final String productId;
  final String productName;
  final String salesmanUid;
  final String salesmanCode;
  final String branchId;
  final String reason;
  final String recommendation;
  final List<String> questions;
  final double valueAtRiskRm;
  final double forecastNextWeek;
  final double anomalyScore;
  final int ageDays;
  final DateTime? dueDate;
  final String fixTarget;
  final String fixEntityId;
  final DateTime? updatedAt;
  final bool isDemo;

  final DateTime? createdAt;

  final DateTime? generatedAt;

  final DateTime? freshnessAt;

  final DateTime? lastObservedWeekStart;

  final DateTime? autoSuppressedAt;
  final String autoSuppressionReason;

  final Map<String, dynamic> latestEvidence;

  factory AiInsight.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    return AiInsight.fromMap(snapshot.id, snapshot.data());
  }

  factory AiInsight.fromMap(String id, Map<String, dynamic> data) {
    final Object? rawQuestions = data['questions'];
    return AiInsight(
      id: _text(data['issueId'], fallback: id),
      issueKey: _text(data['issueKey']),
      type: _text(data['type'], fallback: 'unknown'),
      priority: _text(data['priority'], fallback: 'medium').toLowerCase(),
      confidence: _text(data['confidence'], fallback: 'unknown').toLowerCase(),
      confidenceScore: _number(data['confidenceScore']),
      status: _text(data['status'], fallback: 'new').toLowerCase(),
      autoState: _text(data['autoState'], fallback: 'active').toLowerCase(),
      outcomeCount: _integer(data['outcomeCount']),
      outcomeQualityScore: _integer(data['outcomeQualityScore']),
      retailerId: _text(data['retailerId']),
      retailerName: _text(data['retailerName'], fallback: 'Retailer'),
      productId: _text(data['productId']),
      productName: _text(data['productName'], fallback: 'Product'),
      salesmanUid: _text(data['salesmanUid']),
      salesmanCode: _text(data['salesmanCode']),
      branchId: _text(data['branchId']),
      reason: _text(data['reason']),
      recommendation: _text(data['recommendation']),
      questions: rawQuestions is List
          ? rawQuestions
                .map((Object? value) => _text(value))
                .where((String value) => value.isNotEmpty)
                .toList(growable: false)
          : const <String>[],
      valueAtRiskRm: _number(data['valueAtRiskRm']),
      forecastNextWeek: _number(data['forecastNextWeek']),
      anomalyScore: _number(data['anomalyScore']),
      ageDays: _integer(data['ageDays']),
      dueDate: _date(data['dueDate']),
      fixTarget: _text(data['fixTarget']),
      fixEntityId: _text(data['fixEntityId']),
      updatedAt: _date(data['updatedAt']),
      isDemo: data['isDemo'] == true,
      createdAt: _date(data['createdAt']),
      generatedAt: _date(data['generatedAt']),
      freshnessAt: aiDataTimestamp(data),
      lastObservedWeekStart: _date(data['lastObservedWeekStart']),
      autoSuppressedAt: _date(data['autoSuppressedAt']),
      autoSuppressionReason: _text(data['autoSuppressionReason']),
      latestEvidence: data['latestEvidence'] is Map
          ? Map<String, dynamic>.from(data['latestEvidence'] as Map)
          : const <String, dynamic>{},
    );
  }

  bool get isActive =>
      autoState != 'suppressed' &&
      status != 'resolved' &&
      status != 'dismissed' &&
      status != 'suppressed';

  bool get needsFollowUp => isActive && autoState == 'follow_up';

  bool isOverdueAt(DateTime now) {
    if (!isActive) return false;
    final DateTime? due = dueDate;
    if (due != null) return due.isBefore(now);
    return needsFollowUp && ageDays >= 14;
  }

  bool get hasCapturedOutcome => outcomeCount > 0;

  String get typeLabel {
    switch (type) {
      case 'stopped_product':
        return 'Stopped product';
      case 'declining_sales':
        return 'Declining sales';
      case 'growth_opportunity':
        return 'Growth opportunity';
      case 'sales_anomaly':
        return 'Sales anomaly';
      case 'overdue_reorder':
        return 'Reorder overdue';
      case 'missing_product_price':
        return 'Data quality';
      default:
        return type
            .split('_')
            .where((String part) => part.isNotEmpty)
            .map(
              (String part) =>
                  '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
            )
            .join(' ');
    }
  }

  bool get isCadenceInsight =>
      type == 'overdue_reorder' &&
      latestEvidence['reorderIntervalDays'] != null &&
      latestEvidence['daysSinceLastOrder'] != null;

  double get reorderIntervalDays =>
      _number(latestEvidence['reorderIntervalDays']);
  int get daysSinceLastOrder => _integer(latestEvidence['daysSinceLastOrder']);
  double get overdueByDays => _number(latestEvidence['overdueByDays']);
  int get cadenceOrderCount => _integer(latestEvidence['orderCount']);

  String get fixPageKey {
    switch (fixTarget) {
      case 'product':
        return 'product';
      case 'coordinates':
        return 'coordinate_review';
      case 'retailer':
        return 'retailer';
      default:
        return '';
    }
  }
}

String _text(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

double _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(_text(value).replaceAll(',', '')) ?? 0;
}

int _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse(_text(value)) ?? 0;
}

DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(_text(value));
}
