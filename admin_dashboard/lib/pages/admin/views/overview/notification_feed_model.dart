library;

enum NotificationCategory { orders, visits, retailers, system }

extension NotificationCategoryLabel on NotificationCategory {
  String get label {
    switch (this) {
      case NotificationCategory.orders:
        return 'Orders';
      case NotificationCategory.visits:
        return 'Visits';
      case NotificationCategory.retailers:
        return 'Retailers';
      case NotificationCategory.system:
        return 'System';
    }
  }
}

NotificationCategory notificationCategoryOf(String type) {
  final String t = type.toLowerCase();
  if (t.contains('order')) return NotificationCategory.orders;
  if (t.contains('arrival') ||
      t.contains('visit') ||
      t.contains('day_complete')) {
    return NotificationCategory.visits;
  }
  if (t.contains('retailer')) return NotificationCategory.retailers;
  return NotificationCategory.system;
}

class NotificationEntry {
  const NotificationEntry({
    required this.id,
    required this.type,
    required this.title,
    required this.detail,
    required this.time,
    required this.unread,
    required this.source,
    this.count = 1,
    this.orderDocumentId = '',
  });

  final String id;
  final String type;
  final String title;
  final String detail;
  final DateTime? time;
  final bool unread;
  final int count;
  final String orderDocumentId;

  final Map<String, dynamic> source;

  NotificationCategory get category => notificationCategoryOf(type);
}

class NotificationDayGroup {
  const NotificationDayGroup({required this.label, required this.entries});
  final String label;
  final List<NotificationEntry> entries;
}

const Duration _kualaLumpurOffset = Duration(hours: 8);

DateTime _kl(DateTime value) => value.toUtc().add(_kualaLumpurOffset);

DateTime _klDay(DateTime value) {
  final DateTime kl = _kl(value);
  return DateTime.utc(kl.year, kl.month, kl.day);
}

String tidyNotificationTitle(String message, {String referenceId = ''}) {
  final RegExpMatch? match = RegExp(
    r'^(\w[\w ]*?) (\w+): (.+)$',
  ).firstMatch(message.trim());
  if (match == null) return message.trim();
  final String label = referenceId.isNotEmpty && match.group(3) == referenceId
      ? match.group(1)!
      : match.group(3)!;
  return '$label ${match.group(2)}';
}

List<NotificationEntry> collapseRepeatedNotifications(
  List<NotificationEntry> entries,
) {
  final Map<String, int> indexByKey = <String, int>{};
  final List<NotificationEntry> out = <NotificationEntry>[];
  for (final NotificationEntry entry in entries) {
    final DateTime? time = entry.time;
    final String day = time == null ? 'none' : _klDay(time).toIso8601String();
    final String key =
        '$day|${entry.type}|${entry.title}|${entry.orderDocumentId}';
    final int? existing = indexByKey[key];
    if (existing == null) {
      indexByKey[key] = out.length;
      out.add(entry);
      continue;
    }
    final NotificationEntry first = out[existing];
    out[existing] = NotificationEntry(
      id: first.id,
      type: first.type,
      title: first.title,
      detail: first.detail,
      time: first.time,
      unread: first.unread || entry.unread,
      source: first.source,
      count: first.count + entry.count,
      orderDocumentId: first.orderDocumentId,
    );
  }
  return out;
}

String notificationDayLabel(DateTime? time, {DateTime? now}) {
  if (time == null) return 'Undated';
  final DateTime today = _klDay(now ?? DateTime.now());
  final DateTime day = _klDay(time);
  final int diff = today.difference(day).inDays;
  if (diff == 0) return 'Today';
  if (diff == 1) return 'Yesterday';
  const List<String> weekdays = <String>[
    'Mon',
    'Tue',
    'Wed',
    'Thu',
    'Fri',
    'Sat',
    'Sun',
  ];
  const List<String> months = <String>[
    'Jan',
    'Feb',
    'Mar',
    'Apr',
    'May',
    'Jun',
    'Jul',
    'Aug',
    'Sep',
    'Oct',
    'Nov',
    'Dec',
  ];
  return '${weekdays[day.weekday - 1]} ${day.day} ${months[day.month - 1]}';
}

List<NotificationDayGroup> groupNotificationsByDay(
  List<NotificationEntry> entries, {
  DateTime? now,
}) {
  final List<NotificationDayGroup> groups = <NotificationDayGroup>[];
  String? currentLabel;
  List<NotificationEntry> bucket = <NotificationEntry>[];
  for (final NotificationEntry entry in entries) {
    final String label = notificationDayLabel(entry.time, now: now);
    if (label != currentLabel) {
      if (currentLabel != null) {
        groups.add(NotificationDayGroup(label: currentLabel, entries: bucket));
      }
      currentLabel = label;
      bucket = <NotificationEntry>[];
    }
    bucket.add(entry);
  }
  if (currentLabel != null) {
    groups.add(NotificationDayGroup(label: currentLabel, entries: bucket));
  }
  return groups;
}

String relativeTimeLabel(DateTime? time, {DateTime? now}) {
  if (time == null) return '';
  final Duration age = (now ?? DateTime.now()).difference(time);
  if (age.inSeconds < 60) return 'just now';
  if (age.inMinutes < 60) return '${age.inMinutes} min ago';
  if (age.inHours < 24) return '${age.inHours} h ago';
  if (age.inDays < 7) return '${age.inDays} d ago';
  final DateTime kl = _kl(time);
  return '${kl.day.toString().padLeft(2, '0')}/${kl.month.toString().padLeft(2, '0')}/${kl.year}';
}
