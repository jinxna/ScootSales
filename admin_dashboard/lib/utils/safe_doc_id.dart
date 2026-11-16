String safeDocId(
  String name, {
  String fallbackPrefix = 'item',
  int maxLength = 80,
}) {
  final String trimmed = name.trim();
  String id = trimmed
      .toLowerCase()
      .replaceAll(RegExp(r'[\s/\\.]+'), '_')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '')
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'^[_-]+|[_-]+$'), '');
  if (id.length > maxLength) {
    id = id.substring(0, maxLength).replaceAll(RegExp(r'[_-]+$'), '');
  }
  if (id.isEmpty) {
    return '${fallbackPrefix}_${_fnv1a(trimmed).toRadixString(36)}';
  }
  if (RegExp(r'[^\x00-\x7F]').hasMatch(trimmed)) {
    return '${id}_${_fnv1a(trimmed).toRadixString(36)}';
  }
  return id;
}

int _fnv1a(String input) {
  int hash = 0x811c9dc5;
  for (final int unit in input.codeUnits) {
    hash ^= unit;
    hash = (hash * 0x01000193) & 0xFFFFFFFF;
  }
  return hash;
}
