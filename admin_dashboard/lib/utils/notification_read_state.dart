import 'package:cloud_firestore/cloud_firestore.dart';

class NotificationReadState {
  const NotificationReadState({this.readThroughAt});

  final DateTime? readThroughAt;

  factory NotificationReadState.fromMap(Map<String, dynamic>? data) {
    return NotificationReadState(
      readThroughAt: parseNotificationTimestamp(data?['readThroughAt']),
    );
  }

  NotificationReadState copyWith({DateTime? readThroughAt}) {
    return NotificationReadState(
      readThroughAt: readThroughAt ?? this.readThroughAt,
    );
  }

  bool isRead(
    Map<String, dynamic> notification, {
    Set<String> legacyReadKeys = const <String>{},
  }) {
    return isNotificationReadThrough(
      notification,
      readThroughAt,
      legacyReadKeys: legacyReadKeys,
    );
  }
}

int unreadNotificationCount(
  Iterable<Map<String, dynamic>> notifications,
  NotificationReadState? state,
) => notifications
    .where(
      (Map<String, dynamic> notification) =>
          !(state ?? const NotificationReadState()).isRead(notification),
    )
    .length;

DateTime? notificationEventTimestamp(Map<String, dynamic> notification) {
  for (final String field in const <String>[
    'createdAt',
    'created_at',
    'eventAt',
    'event_at',
    'occurredAt',
    'occurred_at',
    'created',
    'timestamp',
    'updatedAt',
    'updated_at',
  ]) {
    final DateTime? parsed = parseNotificationTimestamp(notification[field]);
    if (parsed != null) return parsed;
  }
  return null;
}

String notificationReadKey(Map<String, dynamic> notification) {
  final String source = _text(
    notification['sourceCollection'] ??
        notification['source_collection'] ??
        notification['collection'],
  );
  final String id = _text(
    notification['docId'] ??
        notification['notificationId'] ??
        notification['notification_id'] ??
        notification['id'],
  );
  if (id.isEmpty) return '';
  return '${source.isEmpty ? 'notification' : source}:$id';
}

bool isNotificationReadThrough(
  Map<String, dynamic> notification,
  DateTime? readThroughAt, {
  Set<String> legacyReadKeys = const <String>{},
}) {
  final DateTime? eventAt = notificationEventTimestamp(notification);
  if (eventAt != null && readThroughAt != null) {
    return !eventAt.isAfter(readThroughAt.toUtc());
  }

  final String key = notificationReadKey(notification);
  return key.isNotEmpty && legacyReadKeys.contains(key);
}

DateTime? parseNotificationTimestamp(Object? value) {
  if (value is Timestamp) return _boundedDate(value.toDate());
  if (value is DateTime) return _boundedDate(value);

  if (value is Map) {
    final Object? secondsValue = value['seconds'] ?? value['_seconds'];
    final Object? nanosValue =
        value['nanoseconds'] ?? value['_nanoseconds'] ?? value['nanos'];
    final num? seconds = _number(secondsValue);
    final num? nanos = _number(nanosValue);
    if (seconds != null) {
      final DateTime? parsed = _fromEpochMilliseconds(
        seconds * 1000 + (nanos ?? 0) / 1000000,
      );
      if (parsed != null) return parsed;
    }
  }

  if (value is num) return _fromEpochNumber(value);
  if (value is String) {
    final String text = value.trim();
    if (text.isEmpty) return null;
    final num? epoch = num.tryParse(text);
    if (epoch != null) return _fromEpochNumber(epoch);
    final DateTime? parsed = DateTime.tryParse(text);
    return parsed == null ? null : _boundedDate(parsed);
  }
  return null;
}

DateTime? _fromEpochNumber(num value) {
  final double numeric = value.toDouble();
  if (!numeric.isFinite) return null;
  final double milliseconds = numeric.abs() < 100000000000
      ? numeric * 1000
      : numeric;
  return _fromEpochMilliseconds(milliseconds);
}

DateTime? _fromEpochMilliseconds(num milliseconds) {
  if (!milliseconds.isFinite || milliseconds.abs() > 100000000000000) {
    return null;
  }
  try {
    final DateTime parsed = DateTime.fromMillisecondsSinceEpoch(
      milliseconds.round(),
      isUtc: true,
    );
    return _boundedDate(parsed);
  } on RangeError {
    return null;
  }
}

DateTime? _boundedDate(DateTime value) {
  if (value.year < 2000 || value.year > 2200) return null;
  return value.toUtc();
}

num? _number(Object? value) {
  if (value is num) return value;
  if (value is String) return num.tryParse(value.trim());
  return null;
}

String _text(Object? value) => (value ?? '').toString().trim();
