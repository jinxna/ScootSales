String shortOrderReference(String orderId) {
  final String id = orderId.trim();
  if (id.length <= 14) return id;
  return 'ORD-${id.substring(id.length - 8).toUpperCase()}';
}

final RegExp _automaticRecordId = RegExp(r'^[A-Za-z0-9]{20}$');
final RegExp _hashedNameId = RegExp(r'^retailer_[0-9a-z]+$');

String _nameSlug(String name) {
  final String slug = name
      .trim()
      .toLowerCase()
      .replaceAll(RegExp(r'[\s/\\.]+'), '_')
      .replaceAll(RegExp(r'[^a-z0-9_-]'), '')
      .replaceAll(RegExp(r'_{2,}'), '_')
      .replaceAll(RegExp(r'^[_-]+|[_-]+$'), '');
  return slug.length > 80
      ? slug.substring(0, 80).replaceAll(RegExp(r'[_-]+$'), '')
      : slug;
}

String? retailerCodeLabel(String retailerId, {String retailerName = ''}) {
  final String id = retailerId.trim();
  if (id.isEmpty) return null;
  final bool automatic =
      _automaticRecordId.hasMatch(id) &&
      id.contains(RegExp(r'[a-z]')) &&
      id.contains(RegExp(r'[A-Z]'));
  final String slug = _nameSlug(retailerName);
  final bool hashedSlug =
      slug.isNotEmpty &&
      retailerName.contains(RegExp(r'[^\x00-\x7F]')) &&
      RegExp('^${RegExp.escape(slug)}_[0-9a-z]+\$').hasMatch(id);
  final bool fromName =
      (slug.isEmpty && _hashedNameId.hasMatch(id)) ||
      (slug.isNotEmpty && id == slug) ||
      hashedSlug;
  return automatic || fromName ? null : 'Code: $id';
}
