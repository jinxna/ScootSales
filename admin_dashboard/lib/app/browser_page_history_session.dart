import 'browser_page_history.dart';
import 'web_page_route.dart';

String sessionPageKey(String uid, String Function(String key) safeKey) {
  final String? owner = currentBrowserHistoryUid();
  final String key = owner != null && owner != uid
      ? safeKey('dashboard')
      : safeKey(pageKeyFromFragment(currentBrowserPageFragment()));
  if (owner != uid) {
    replaceBrowserPageFragment(fragmentForPageKey(key), uid: uid);
  }
  return key;
}
