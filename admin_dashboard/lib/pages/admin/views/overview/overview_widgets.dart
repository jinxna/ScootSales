import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import 'notification_feed_model.dart';

IconData notificationIconFor(String type) {
  final String t = type.toLowerCase();
  if (t.contains('forecast')) {
    return t.contains('fail') ? ScootIcons.error : ScootIcons.forecast;
  }
  if (t.contains('import')) {
    return t.contains('fail') ? ScootIcons.error : ScootIcons.upload;
  }
  if (t.contains('arrival')) return ScootIcons.place;
  if (t.contains('day_complete')) return ScootIcons.success;
  switch (notificationCategoryOf(type)) {
    case NotificationCategory.orders:
      return ScootIcons.orders;
    case NotificationCategory.visits:
      return ScootIcons.place;
    case NotificationCategory.retailers:
      return ScootIcons.store;
    case NotificationCategory.system:
      return ScootIcons.notifications;
  }
}
