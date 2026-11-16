String pageKeyFromFragment(String fragment) {
  final String value = fragment.trim().replaceFirst(RegExp(r'^/?'), '');
  if (value.isEmpty) return 'dashboard';
  final String key = value.split('/').first.trim();
  return RegExp(r'^[a-z0-9_]+$').hasMatch(key) ? key : 'dashboard';
}

String fragmentForPageKey(String key) => '#/${key.trim()}';
