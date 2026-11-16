// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

void armBrowserNotificationPermission() {
  if (!html.Notification.supported ||
      html.Notification.permission != 'default') {
    return;
  }
  html.document.onClick.first.then((_) {
    html.Notification.requestPermission();
  });
}

void showBrowserNotification(String title, String body) {
  try {
    if (html.Notification.supported &&
        html.Notification.permission == 'granted') {
      html.Notification(title, body: body);
    }
  } catch (_) {
  }
}
