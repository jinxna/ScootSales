import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/ai_data_freshness.dart';

class AiRunRecord {
  const AiRunRecord({
    required this.id,
    required this.status,
    required this.startedAt,
    required this.patternCount,
    required this.insightCount,
    required this.visitBriefCount,
    required this.retailerSegmentCount,
    this.finishedAt,
    this.generatedAt,
    this.updatedAt,
    this.freshnessAt,
  });

  final String id;
  final String status;
  final DateTime? startedAt;
  final int patternCount;
  final int insightCount;
  final int visitBriefCount;
  final int retailerSegmentCount;
  final DateTime? finishedAt;
  final DateTime? generatedAt;
  final DateTime? updatedAt;
  final DateTime? freshnessAt;

  factory AiRunRecord.fromFirestore(
    QueryDocumentSnapshot<Map<String, dynamic>> snapshot,
  ) {
    return AiRunRecord.fromMap(snapshot.id, snapshot.data());
  }

  factory AiRunRecord.fromMap(String id, Map<String, dynamic> data) {
    return AiRunRecord(
      id: id,
      status: (data['status'] ?? 'unknown').toString(),
      startedAt: data['startedAt'] is Timestamp
          ? (data['startedAt'] as Timestamp).toDate()
          : null,
      finishedAt: _date(data['finishedAt']),
      generatedAt: _date(data['generatedAt']),
      updatedAt: _date(data['updatedAt']),
      freshnessAt: aiDataTimestamp(data),
      patternCount: _integer(data['patternCount']),
      insightCount: _integer(data['insightCount']),
      visitBriefCount: _integer(data['visitBriefCount']),
      retailerSegmentCount: _integer(data['retailerSegmentCount']),
    );
  }
}

DateTime? _date(Object? value) {
  return aiDataTimestamp(<String, dynamic>{'generatedAt': value});
}

int _integer(Object? value) {
  if (value is num) return value.toInt();
  return int.tryParse((value ?? '').toString()) ?? 0;
}
