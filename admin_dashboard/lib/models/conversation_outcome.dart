import 'package:cloud_firestore/cloud_firestore.dart';

import 'ai_insight.dart';
import '../utils/follow_up_dates.dart';

class ConversationOutcome {
  const ConversationOutcome({
    required this.id,
    required this.issueId,
    required this.issueKey,
    required this.issueType,
    required this.retailerId,
    required this.retailerName,
    required this.productId,
    required this.productName,
    required this.reasonCode,
    required this.note,
    required this.replacementProductId,
    required this.salesmanUid,
    required this.salesmanCode,
    required this.branchId,
    required this.submittedAt,
    required this.followUpDate,
    required this.followUpTime,
    required this.followUpStatus,
    required this.isDemo,
    required this.qualityScore,
    required this.qualityFlags,
  });

  final String id;
  final String issueId;
  final String issueKey;
  final String issueType;
  final String retailerId;
  final String retailerName;
  final String productId;
  final String productName;
  final String reasonCode;
  final String note;
  final String replacementProductId;
  final String salesmanUid;
  final String salesmanCode;
  final String branchId;
  final DateTime? submittedAt;
  final String followUpDate;
  final String followUpTime;
  final String followUpStatus;
  final bool isDemo;
  final int qualityScore;
  final List<String> qualityFlags;

  factory ConversationOutcome.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    return ConversationOutcome.fromMap(snapshot.id, snapshot.data());
  }

  factory ConversationOutcome.fromMap(String id, Map<String, dynamic> data) {
    final String reasonCode = _text(data['reasonCode']).toLowerCase();
    final String note = _text(data['note']);
    final String replacementProductId = _text(data['replacementProductId']);
    final OutcomeQuality quality = scoreOutcomeQuality(
      reasonCode,
      note: note,
      replacementProductId: replacementProductId,
    );
    return ConversationOutcome(
      id: _text(data['outcomeId'], fallback: id),
      issueId: _text(data['issueId']),
      issueKey: _text(data['issueKey']),
      issueType: _text(data['issueType']),
      retailerId: _text(data['retailerId']),
      retailerName: _text(data['retailerName'], fallback: 'Retailer'),
      productId: _text(data['productId']),
      productName: _text(data['productName'], fallback: 'Product'),
      reasonCode: reasonCode,
      note: note,
      replacementProductId: replacementProductId,
      salesmanUid: _text(data['salesmanUid']),
      salesmanCode: _text(data['salesmanCode']),
      branchId: _text(data['branchId']),
      submittedAt: _date(
        data['submittedAt'] ?? data['clientCreatedAt'] ?? data['createdAt'],
      ),
      followUpDate: _text(data['followUpDate']),
      followUpTime: _text(data['followUpTime']),
      followUpStatus: _text(data['followUpStatus']).toLowerCase(),
      isDemo: data['isDemo'] == true,
      qualityScore: quality.score,
      qualityFlags: quality.flags,
    );
  }

  bool get isLowQuality => qualityScore < 60;

  bool get hasOpenDatedFollowUp =>
      followUpStatus == 'open' && isValidKualaLumpurDateKey(followUpDate);

  bool get isOverdueDatedFollowUp {
    if (!hasOpenDatedFollowUp) return false;
    return isKualaLumpurFollowUpOverdue(followUpDate);
  }

  bool get needsFollowUp => const <String>{
    'not_asked_today',
    'retailer_busy',
    'decision_maker_unavailable',
    'not_decision_maker',
  }.contains(reasonCode);

  String get reasonLabel => reasonCode
      .split('_')
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) =>
            '${part.substring(0, 1).toUpperCase()}${part.substring(1)}',
      )
      .join(' ');
}

class OutcomeQuality {
  const OutcomeQuality({required this.score, required this.flags});

  final int score;
  final List<String> flags;
}

class OutcomeOperationsSummary {
  const OutcomeOperationsSummary({
    required this.eligibleInsights,
    required this.capturedInsights,
    required this.lowQualityOutcomes,
    required this.followUpOutcomes,
    required this.averageQuality,
    required this.reasonCounts,
  });

  final int eligibleInsights;
  final int capturedInsights;
  final int lowQualityOutcomes;
  final int followUpOutcomes;
  final int averageQuality;
  final Map<String, int> reasonCounts;

  double get complianceRate =>
      eligibleInsights == 0 ? 0 : capturedInsights / eligibleInsights;

  factory OutcomeOperationsSummary.build({
    required List<AiInsight> insights,
    required List<ConversationOutcome> outcomes,
  }) {
    final List<AiInsight> eligible = insights
        .where(
          (AiInsight insight) =>
              insight.isActive &&
              insight.issueKey.isNotEmpty &&
              insight.type != 'missing_product_price',
        )
        .toList(growable: false);
    final Set<String> capturedKeys = outcomes
        .map((ConversationOutcome outcome) => outcome.issueKey)
        .where((String key) => key.isNotEmpty)
        .toSet();
    final Map<String, int> reasons = <String, int>{};
    int qualityTotal = 0;
    for (final ConversationOutcome outcome in outcomes) {
      reasons.update(
        outcome.reasonCode,
        (int count) => count + 1,
        ifAbsent: () => 1,
      );
      qualityTotal += outcome.qualityScore;
    }
    final List<MapEntry<String, int>> sortedReasons = reasons.entries.toList()
      ..sort((MapEntry<String, int> left, MapEntry<String, int> right) {
        final int count = right.value.compareTo(left.value);
        return count != 0 ? count : left.key.compareTo(right.key);
      });
    return OutcomeOperationsSummary(
      eligibleInsights: eligible.length,
      capturedInsights: eligible
          .where((AiInsight insight) => capturedKeys.contains(insight.issueKey))
          .length,
      lowQualityOutcomes: outcomes
          .where((ConversationOutcome outcome) => outcome.isLowQuality)
          .length,
      followUpOutcomes: outcomes
          .where((ConversationOutcome outcome) => outcome.needsFollowUp)
          .length,
      averageQuality: outcomes.isEmpty
          ? 0
          : (qualityTotal / outcomes.length).round(),
      reasonCounts: Map<String, int>.fromEntries(sortedReasons),
    );
  }
}

OutcomeQuality scoreOutcomeQuality(
  String reasonCode, {
  String note = '',
  String replacementProductId = '',
}) {
  const Set<String> supportedReasons = <String>{
    'low_sell_through',
    'price_too_high',
    'switched_to_alternative',
    'supplier_issue',
    'out_of_stock',
    'shelf_space_limited',
    'cash_flow_issue',
    'seasonal_change',
    'not_decision_maker',
    'not_asked_today',
    'retailer_busy',
    'decision_maker_unavailable',
    'competitor_promotion',
    'packaging_change',
    'quality_complaint',
    'other',
  };
  final String reason = reasonCode.trim().toLowerCase();
  if (!supportedReasons.contains(reason)) {
    return const OutcomeQuality(
      score: 0,
      flags: <String>['invalid_reason_code'],
    );
  }

  int score = 70;
  final List<String> flags = <String>[];
  final bool meaningfulNote = _isMeaningfulNote(note);
  if (note.trim().isNotEmpty && !meaningfulNote) {
    flags.add('junk_note');
    score -= 35;
  } else if (meaningfulNote) {
    score += 20;
  }
  if (reason == 'other' && !meaningfulNote) {
    flags.add('note_required_for_other');
    score -= 60;
  }
  if (reason == 'switched_to_alternative') {
    if (replacementProductId.trim().isEmpty) {
      flags.add('replacement_product_missing');
      score -= 20;
    } else {
      score += 10;
    }
  }
  return OutcomeQuality(
    score: score.clamp(0, 100).toInt(),
    flags: List<String>.unmodifiable(flags),
  );
}

bool _isMeaningfulNote(String value) {
  final String clean = value.trim().replaceAll(RegExp(r'\s+'), ' ');
  const Set<String> junk = <String>{
    'ok',
    'okay',
    'test',
    'testing',
    'n/a',
    'na',
    'none',
    'no',
    'yes',
    '-',
    '.',
  };
  if (clean.length < 8 || junk.contains(clean.toLowerCase())) return false;
  if (!RegExp(r'[A-Za-z]').hasMatch(clean)) return false;
  if (RegExp(r'^(.)\1{4,}$', caseSensitive: false).hasMatch(clean)) {
    return false;
  }
  final Set<String> words = RegExp(r'[A-Za-z0-9]+')
      .allMatches(clean.toLowerCase())
      .map((RegExpMatch match) => match.group(0) ?? '')
      .where((String word) => word.isNotEmpty)
      .toSet();
  return words.length >= 2;
}

String _text(Object? value, {String fallback = ''}) {
  final String text = (value ?? '').toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(_text(value));
}
