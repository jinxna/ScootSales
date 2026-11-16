import 'package:cloud_firestore/cloud_firestore.dart';

import '../utils/ai_data_freshness.dart';

class ActionCentreItem {
  const ActionCentreItem({
    required this.id,
    required this.title,
    required this.category,
    required this.priority,
    required this.reason,
    required this.recommendedAction,
    required this.confidence,
    required this.relatedPageKey,
    required this.relatedEntityType,
    required this.relatedEntityId,
    required this.createdAt,
    required this.source,
    required this.status,
    this.note = '',
    this.freshnessAt,
  });

  final String id;
  final String title;
  final String category;
  final String priority;
  final String reason;
  final String recommendedAction;
  final String confidence;
  final String relatedPageKey;
  final String relatedEntityType;
  final String relatedEntityId;
  final DateTime? createdAt;
  final String source;

  final String status;

  final String note;

  final DateTime? freshnessAt;

  ActionCentreItem copyWith({String? status, String? note}) {
    return ActionCentreItem(
      id: id,
      title: title,
      category: category,
      priority: priority,
      reason: reason,
      recommendedAction: recommendedAction,
      confidence: confidence,
      relatedPageKey: relatedPageKey,
      relatedEntityType: relatedEntityType,
      relatedEntityId: relatedEntityId,
      createdAt: createdAt,
      source: source,
      status: status ?? this.status,
      note: note ?? this.note,
      freshnessAt: freshnessAt,
    );
  }

  String get workflowStatus => canonicalStatus(status);

  static String canonicalStatus(String status) {
    final String normalized = status.toLowerCase().trim();
    switch (normalized) {
      case 'in_review':
      case 'in review':
      case 'reviewed':
        return 'in_review';
      case 'resolved':
      case 'done':
      case 'closed':
        return 'resolved';
      case 'ignored':
      case 'dismissed':
        return 'ignored';
      default:
        return 'new';
    }
  }

  factory ActionCentreItem.fromFirestore(Map<String, dynamic> data) {
    return ActionCentreItem(
      id: _text(data['docId'] ?? data['id']),
      title: _text(data['title']),
      category: _titleCase(_text(data['category'], fallback: 'Data Quality')),
      priority: _titleCase(_text(data['priority'], fallback: 'Medium')),
      reason: _text(data['reason']),
      recommendedAction: _text(
        data['recommendedAction'] ?? data['recommended_action'],
      ),
      confidence: _titleCase(_text(data['confidence'], fallback: 'Medium')),
      relatedPageKey: _text(data['relatedPageKey'] ?? data['related_page_key']),
      relatedEntityType: _text(
        data['relatedEntityType'] ?? data['related_entity_type'],
      ),
      relatedEntityId: _text(
        data['relatedEntityId'] ?? data['related_entity_id'],
      ),
      createdAt: _toDateTime(
        data['createdAt'] ??
            data['created_at'] ??
            data['updatedAt'] ??
            data['updated_at'],
      ),
      source: _text(data['source'], fallback: 'firestore'),
      status: _text(data['status'], fallback: 'open'),
      freshnessAt: aiDataTimestamp(<String, dynamic>{
        'generatedAt':
            data['generatedAt'] ??
            data['generated_at'] ??
            data['runCreatedAt'] ??
            data['run_created_at'] ??
            data['createdAt'] ??
            data['created_at'],
        'updatedAt': data['updatedAt'] ?? data['updated_at'],
        'weekStart': data['weekStart'] ?? data['week_start'],
      }),
    );
  }

  bool get isVisible {
    final String s = workflowStatus;
    return title.isNotEmpty && s != 'resolved' && s != 'ignored';
  }
}

String _text(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  if (text.isEmpty || text.toLowerCase() == 'null') return fallback;
  return text;
}

String _titleCase(String value) {
  final String trimmed = value.trim();
  if (trimmed.isEmpty) return trimmed;
  return trimmed
      .split(RegExp(r'[\s_-]+'))
      .where((String part) => part.isNotEmpty)
      .map(
        (String part) => part.length == 1
            ? part.toUpperCase()
            : '${part.substring(0, 1).toUpperCase()}${part.substring(1).toLowerCase()}',
      )
      .join(' ');
}

DateTime? _toDateTime(Object? value) {
  if (value == null) return null;
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  if (value is num) {
    final int n = value.toInt();
    return DateTime.fromMillisecondsSinceEpoch(
      n > 9999999999 ? n : n * 1000,
      isUtc: true,
    );
  }
  return DateTime.tryParse(value.toString().trim());
}
