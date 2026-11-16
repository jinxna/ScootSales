import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/demo_data.dart';

class VisitBrief {
  const VisitBrief({
    required this.id,
    required this.retailerId,
    required this.retailerName,
    required this.salesmanUid,
    required this.salesmanCode,
    required this.branchId,
    required this.status,
    required this.insightCount,
    required this.highPriorityCount,
    required this.totalValueAtRiskRm,
    required this.topInsights,
    required this.focusItems,
    required this.focusItemsMaterialised,
    required this.emptyStateHeadline,
    required this.emptyStateBody,
    required this.retailerMemory,
    required this.routeIntelligence,
    required this.replenishment,
    required this.isDemo,
    required this.updatedAt,
  });

  final String id;
  final String retailerId;
  final String retailerName;
  final String salesmanUid;
  final String salesmanCode;
  final String branchId;
  final String status;
  final int insightCount;
  final int highPriorityCount;
  final double totalValueAtRiskRm;
  final List<VisitBriefInsight> topInsights;
  final List<VisitFocusItem> focusItems;
  final bool focusItemsMaterialised;
  final String emptyStateHeadline;
  final String emptyStateBody;
  final RetailerMemoryContext? retailerMemory;
  final RouteIntelligenceSuggestion? routeIntelligence;

  final List<ReplenishmentSuggestion> replenishment;
  final bool isDemo;
  final DateTime? updatedAt;

  factory VisitBrief.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    return VisitBrief.fromMap(snapshot.id, snapshot.data());
  }

  factory VisitBrief.fromMap(String id, Map<String, dynamic> data) {
    final Object? rawInsights = data['topInsights'];
    return VisitBrief(
      id: _text(data['briefId'], fallback: id),
      retailerId: _text(data['retailerId']),
      retailerName: _text(data['retailerName'], fallback: 'Retailer'),
      salesmanUid: _text(data['salesmanUid']),
      salesmanCode: _text(data['salesmanCode']),
      branchId: _text(data['branchId']),
      status: _text(data['status'], fallback: 'active'),
      insightCount: (data['insightCount'] as num?)?.toInt() ?? 0,
      highPriorityCount: (data['highPriorityCount'] as num?)?.toInt() ?? 0,
      totalValueAtRiskRm: (data['totalValueAtRiskRm'] as num?)?.toDouble() ?? 0,
      topInsights: rawInsights is List
          ? rawInsights
                .whereType<Map>()
                .map(
                  (Map row) =>
                      VisitBriefInsight.fromMap(Map<String, dynamic>.from(row)),
                )
                .take(3)
                .toList(growable: false)
          : const <VisitBriefInsight>[],
      focusItems: data['focusItems'] is List
          ? (data['focusItems'] as List)
                .whereType<Map>()
                .map(
                  (Map row) => VisitFocusItem.fromMap(
                    Map<String, dynamic>.from(row),
                  ),
                )
                .take(3)
                .toList(growable: false)
          : const <VisitFocusItem>[],
      focusItemsMaterialised: data.containsKey('focusItems') &&
          data['focusItems'] is List,
      emptyStateHeadline: _text(data['emptyStateHeadline']),
      emptyStateBody: _text(data['emptyStateBody']),
      retailerMemory: data['retailerMemory'] is Map
          ? RetailerMemoryContext.fromMap(
              Map<String, dynamic>.from(data['retailerMemory'] as Map),
            )
          : null,
      routeIntelligence: data['routeIntelligence'] is Map
          ? RouteIntelligenceSuggestion.fromMap(
              Map<String, dynamic>.from(data['routeIntelligence'] as Map),
            )
          : null,
      replenishment: data['replenishment'] is List
          ? (data['replenishment'] as List)
                .whereType<Map>()
                .map(
                  (Map row) => ReplenishmentSuggestion.fromMap(
                    Map<String, dynamic>.from(row),
                  ),
                )
                .where((ReplenishmentSuggestion s) => s.suggestedQty >= 1)
                .toList(growable: false)
          : const <ReplenishmentSuggestion>[],
      isDemo: isDemoRecord(<String, dynamic>{
        ...data,
        'docId': id,
      }, includeNameMarkers: false),
      updatedAt: _date(data['updatedAt']),
    );
  }

  Map<String, dynamic> toCacheMap() => <String, dynamic>{
    'briefId': id,
    'retailerId': retailerId,
    'retailerName': retailerName,
    'salesmanUid': salesmanUid,
    'salesmanCode': salesmanCode,
    'branchId': branchId,
    'status': status,
    'insightCount': insightCount,
    'highPriorityCount': highPriorityCount,
    'totalValueAtRiskRm': totalValueAtRiskRm,
    'topInsights': topInsights
        .map((VisitBriefInsight insight) => insight.toMap())
        .toList(),
    'focusItems': focusItems
        .map((VisitFocusItem item) => item.toMap())
        .toList(),
    'emptyStateHeadline': emptyStateHeadline,
    'emptyStateBody': emptyStateBody,
    if (retailerMemory != null) 'retailerMemory': retailerMemory!.toMap(),
    if (routeIntelligence != null)
      'routeIntelligence': routeIntelligence!.toMap(),
    if (replenishment.isNotEmpty)
      'replenishment': replenishment
          .map((ReplenishmentSuggestion s) => s.toMap())
          .toList(),
    'isDemo': isDemo,
    if (updatedAt != null) 'updatedAt': updatedAt!.toIso8601String(),
  };

  bool get isActive => status.toLowerCase() == 'active';

  List<VisitFocusItem> get fieldFocusItems {
    if (focusItems.isNotEmpty) return focusItems;
    if (focusItemsMaterialised) return const <VisitFocusItem>[];
    return topInsights
        .take(3)
        .map(VisitFocusItem.fromLegacyInsight)
        .toList(growable: false);
  }

  bool get hasNoPriorityIssues =>
      focusItemsMaterialised && focusItems.isEmpty;

  String get noPriorityHeadline => emptyStateHeadline.isNotEmpty
      ? emptyStateHeadline
      : 'No priority issues today.';

  String get noPriorityBody =>
      emptyStateBody.isNotEmpty ? emptyStateBody : 'Proceed with standard visit.';

  bool get hasFieldGuidance =>
      fieldFocusItems.isNotEmpty ||
      hasNoPriorityIssues ||
      replenishment.isNotEmpty;
}

class RouteIntelligenceSuggestion {
  const RouteIntelligenceSuggestion({
    required this.attentionScore,
    required this.priority,
    required this.considerVisitingEarlier,
    required this.topIssueTypes,
  });

  final int attentionScore;
  final String priority;
  final bool considerVisitingEarlier;
  final List<String> topIssueTypes;

  factory RouteIntelligenceSuggestion.fromMap(Map<String, dynamic> data) {
    return RouteIntelligenceSuggestion(
      attentionScore: ((data['attentionScore'] as num?)?.toInt() ?? 0).clamp(
        0,
        100,
      ),
      priority: _routePriority(data['priority']),
      considerVisitingEarlier: data['considerVisitingEarlier'] == true,
      topIssueTypes: _strings(data['topIssueTypes'], limit: 3),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'attentionScore': attentionScore,
    'priority': priority,
    'considerVisitingEarlier': considerVisitingEarlier,
    'topIssueTypes': topIssueTypes,
  };
}

class RetailerMemoryContext {
  const RetailerMemoryContext({
    required this.status,
    required this.confidence,
    required this.commonReasonCodes,
    required this.replacementProductIds,
    required this.priceSensitivityScore,
    required this.seasonalityScore,
  });

  final String status;
  final String confidence;
  final List<String> commonReasonCodes;
  final List<String> replacementProductIds;
  final double priceSensitivityScore;
  final double seasonalityScore;

  factory RetailerMemoryContext.fromMap(Map<String, dynamic> data) {
    return RetailerMemoryContext(
      status: _text(data['status'], fallback: 'inactive'),
      confidence: _text(data['confidence'], fallback: 'low'),
      commonReasonCodes: _strings(data['commonReasonCodes'], limit: 3),
      replacementProductIds: _strings(data['replacementProductIds'], limit: 2),
      priceSensitivityScore:
          (data['priceSensitivityScore'] as num?)?.toDouble() ?? 0,
      seasonalityScore: (data['seasonalityScore'] as num?)?.toDouble() ?? 0,
    );
  }

  bool get isActive => status.toLowerCase() == 'active';

  Map<String, dynamic> toMap() => <String, dynamic>{
    'status': status,
    'confidence': confidence,
    'commonReasonCodes': commonReasonCodes,
    'replacementProductIds': replacementProductIds,
    'priceSensitivityScore': priceSensitivityScore,
    'seasonalityScore': seasonalityScore,
  };
}

class ReplenishmentSuggestion {
  const ReplenishmentSuggestion({
    required this.retailerId,
    required this.productId,
    required this.productName,
    required this.suggestedQty,
    required this.confidence,
    required this.confidenceLabel,
    required this.rationale,
    required this.lastOrderQty,
    required this.lastOrderDaysAgo,
    required this.runRatePerDay,
    required this.patternMeanQty,
  });

  final String retailerId;
  final String productId;
  final String productName;
  final int suggestedQty;
  final double confidence;
  final String confidenceLabel;
  final String rationale;
  final int lastOrderQty;
  final int lastOrderDaysAgo;
  final double? runRatePerDay;
  final double patternMeanQty;

  factory ReplenishmentSuggestion.fromMap(Map<String, dynamic> data) {
    final Map<String, dynamic> inputs = data['inputs'] is Map
        ? Map<String, dynamic>.from(data['inputs'] as Map)
        : const <String, dynamic>{};
    return ReplenishmentSuggestion(
      retailerId: _text(data['retailerId']),
      productId: _text(data['productId']),
      productName: _text(data['productName']),
      suggestedQty: ((data['suggestedQty'] as num?)?.toInt() ?? 0).clamp(
        0,
        999999,
      ),
      confidence: ((data['confidence'] as num?)?.toDouble() ?? 0).clamp(
        0.0,
        1.0,
      ),
      confidenceLabel: _confidenceLabel(data['confidenceLabel']),
      rationale: _text(data['rationale']),
      lastOrderQty: (inputs['lastOrderQty'] as num?)?.toInt() ?? 0,
      lastOrderDaysAgo: (inputs['lastOrderDaysAgo'] as num?)?.toInt() ?? 0,
      runRatePerDay: (inputs['runRatePerDay'] as num?)?.toDouble(),
      patternMeanQty: (inputs['patternMeanQty'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'retailerId': retailerId,
    'productId': productId,
    'productName': productName,
    'suggestedQty': suggestedQty,
    'confidence': confidence,
    'confidenceLabel': confidenceLabel,
    'rationale': rationale,
    'inputs': <String, dynamic>{
      'lastOrderQty': lastOrderQty,
      'lastOrderDaysAgo': lastOrderDaysAgo,
      'runRatePerDay': runRatePerDay,
      'patternMeanQty': patternMeanQty,
    },
  };
}

String _confidenceLabel(Object? value) {
  final String label = _text(value).toLowerCase();
  return const <String>{'high', 'medium', 'low'}.contains(label)
      ? label
      : 'low';
}

class FocusPreviousOutcome {
  const FocusPreviousOutcome({
    required this.reasonCode,
    required this.note,
    required this.submittedAt,
    required this.replacementProductId,
  });

  final String reasonCode;
  final String note;
  final DateTime? submittedAt;
  final String replacementProductId;

  bool get isEmpty =>
      reasonCode.isEmpty && note.isEmpty && replacementProductId.isEmpty;

  String get label => reasonCode.isEmpty
      ? 'Recorded previously'
      : reasonCode.replaceAll('_', ' ');

  factory FocusPreviousOutcome.fromMap(Map<String, dynamic> data) {
    return FocusPreviousOutcome(
      reasonCode: _text(data['reasonCode']),
      note: _text(data['note']),
      submittedAt: _date(data['submittedAt']),
      replacementProductId: _text(data['replacementProductId']),
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'reasonCode': reasonCode,
    'note': note,
    if (submittedAt != null) 'submittedAt': submittedAt!.toIso8601String(),
    'replacementProductId': replacementProductId,
  };
}

class VisitFocusItem {
  const VisitFocusItem({
    required this.issueId,
    required this.issueKey,
    required this.type,
    required this.priority,
    required this.confidence,
    required this.productId,
    required this.productName,
    required this.signal,
    required this.action,
    required this.questions,
    required this.valueAtRiskRm,
    required this.previousOutcome,
    required this.occurrenceCount,
    required this.autoState,
  });

  final String issueId;
  final String issueKey;
  final String type;
  final String priority;
  final String confidence;
  final String productId;
  final String productName;

  final String signal;

  final String action;

  final List<String> questions;
  final double valueAtRiskRm;
  final FocusPreviousOutcome? previousOutcome;

  final int occurrenceCount;
  final String autoState;

  bool get isReturning => previousOutcome != null || occurrenceCount > 1;

  String get title => productName.isNotEmpty
      ? productName
      : type.isEmpty
      ? 'Focus item'
      : type.replaceAll('_', ' ');

  factory VisitFocusItem.fromMap(Map<String, dynamic> data) {
    final Object? rawOutcome = data['previousOutcome'];
    return VisitFocusItem(
      issueId: _text(data['issueId']),
      issueKey: _text(data['issueKey']),
      type: _text(data['type']),
      priority: _text(data['priority'], fallback: 'medium'),
      confidence: _text(data['confidence'], fallback: 'unknown'),
      productId: _text(data['productId']),
      productName: _text(data['productName']),
      signal: _text(data['signal']),
      action: _text(data['action']),
      questions: _stringList(data['questions'], limit: 3),
      valueAtRiskRm: (data['valueAtRiskRm'] as num?)?.toDouble() ?? 0,
      previousOutcome: rawOutcome is Map
          ? FocusPreviousOutcome.fromMap(
              Map<String, dynamic>.from(rawOutcome),
            )
          : null,
      occurrenceCount: (data['occurrenceCount'] as num?)?.toInt() ?? 1,
      autoState: _text(data['autoState'], fallback: 'active'),
    );
  }

  factory VisitFocusItem.fromLegacyInsight(VisitBriefInsight insight) {
    return VisitFocusItem(
      issueId: insight.issueId,
      issueKey: insight.issueKey,
      type: insight.type,
      priority: insight.priority,
      confidence: insight.confidence,
      productId: insight.productId,
      productName: insight.productName,
      signal: insight.reason,
      action: insight.recommendation,
      questions: insight.questions,
      valueAtRiskRm: insight.valueAtRiskRm,
      previousOutcome: null,
      occurrenceCount: 1,
      autoState: 'active',
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'issueId': issueId,
    'issueKey': issueKey,
    'type': type,
    'priority': priority,
    'confidence': confidence,
    'productId': productId,
    'productName': productName,
    'signal': signal,
    'action': action,
    'questions': questions,
    'valueAtRiskRm': valueAtRiskRm,
    if (previousOutcome != null) 'previousOutcome': previousOutcome!.toMap(),
    'occurrenceCount': occurrenceCount,
    'autoState': autoState,
  };
}

class VisitBriefInsight {
  const VisitBriefInsight({
    required this.issueId,
    required this.issueKey,
    required this.type,
    required this.priority,
    required this.confidence,
    required this.productId,
    required this.productName,
    required this.reason,
    required this.recommendation,
    required this.questions,
    required this.valueAtRiskRm,
  });

  final String issueId;
  final String issueKey;
  final String type;
  final String priority;
  final String confidence;
  final String productId;
  final String productName;
  final String reason;
  final String recommendation;
  final List<String> questions;
  final double valueAtRiskRm;

  factory VisitBriefInsight.fromMap(Map<String, dynamic> data) {
    final Object? rawQuestions = data['questions'];
    return VisitBriefInsight(
      issueId: _text(data['issueId']),
      issueKey: _text(data['issueKey']),
      type: _text(data['type']),
      priority: _text(data['priority'], fallback: 'medium'),
      confidence: _text(data['confidence'], fallback: 'unknown'),
      productId: _text(data['productId']),
      productName: _text(data['productName'], fallback: 'Product'),
      reason: _text(data['reason']),
      recommendation: _text(data['recommendation']),
      questions: rawQuestions is List
          ? rawQuestions
                .map((Object? value) => _text(value))
                .where((String value) => value.isNotEmpty)
                .take(3)
                .toList(growable: false)
          : const <String>[],
      valueAtRiskRm: (data['valueAtRiskRm'] as num?)?.toDouble() ?? 0,
    );
  }

  Map<String, dynamic> toMap() => <String, dynamic>{
    'issueId': issueId,
    'issueKey': issueKey,
    'type': type,
    'priority': priority,
    'confidence': confidence,
    'productId': productId,
    'productName': productName,
    'reason': reason,
    'recommendation': recommendation,
    'questions': questions,
    'valueAtRiskRm': valueAtRiskRm,
  };
}

String _text(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  return text.isEmpty ? fallback : text;
}

DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(_text(value));
}

List<String> _strings(Object? value, {required int limit}) {
  if (value is! List) return const <String>[];
  return value
      .map(_text)
      .where((String item) => item.isNotEmpty)
      .take(limit)
      .toList(growable: false);
}

List<String> _stringList(Object? value, {required int limit}) {
  if (value is! List) return const <String>[];
  return value
      .map((Object? item) => _text(item))
      .where((String item) => item.isNotEmpty)
      .take(limit)
      .toList(growable: false);
}

String _routePriority(Object? value) {
  final priority = _text(value).toLowerCase();
  return const <String>{'urgent', 'high', 'normal'}.contains(priority)
      ? priority
      : 'normal';
}
