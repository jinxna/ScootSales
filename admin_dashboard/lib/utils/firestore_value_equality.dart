bool sameFirestoreValue(Object? left, Object? right) {
  if (left is Map && right is Map) {
    if (left.length != right.length) return false;
    for (final Object? key in left.keys) {
      if (!right.containsKey(key) ||
          !sameFirestoreValue(left[key], right[key])) {
        return false;
      }
    }
    return true;
  }
  if (left is List && right is List) {
    if (left.length != right.length) return false;
    for (int i = 0; i < left.length; i++) {
      if (!sameFirestoreValue(left[i], right[i])) return false;
    }
    return true;
  }
  return left == right;
}
