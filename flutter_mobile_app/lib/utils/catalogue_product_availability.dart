bool isCatalogueProductVisible(Map<String, dynamic> product) {
  final Object? rawVisibility = product['isVisible'] ?? product['visible'];
  if (_isExplicitlyFalse(rawVisibility)) {
    return false;
  }

  final String canonicalStatus = (product['status'] ?? '').toString().trim();
  final Object? statusSource = canonicalStatus.isNotEmpty
      ? canonicalStatus
      : product['productStatus'];
  final String status = (statusSource ?? '').toString().trim().toLowerCase();
  return !_unavailableStatuses.contains(status);
}

const Set<String> _unavailableStatuses = <String>{
  'false',
  'no',
  'n',
  '0',
  'hide',
  'hidden',
  'inactive',
  'disabled',
  'suspended',
  'retired',
  'archived',
  'discontinued',
  'deleted',
};

bool _isExplicitlyFalse(Object? raw) {
  if (raw == false) return true;
  if (raw is num && raw == 0) return true;
  return _unavailableStatuses.contains(
    (raw ?? '').toString().trim().toLowerCase(),
  );
}
