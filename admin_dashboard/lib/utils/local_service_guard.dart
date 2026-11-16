bool shouldProbeLocalService(
  String baseUrl, {
  Uri? pageOrigin,
  bool explicitlyConfigured = true,
}) {
  if (!explicitlyConfigured) return false;
  final Uri? base = Uri.tryParse(baseUrl);
  if (base == null || !_isLoopbackHost(base.host)) return true;
  final Uri origin = pageOrigin ?? Uri.base;
  if (origin.scheme == 'https' && !_isLoopbackHost(origin.host)) return false;
  return true;
}

bool _isLoopbackHost(String host) {
  final String h = host.toLowerCase();
  return h == 'localhost' ||
      h == '127.0.0.1' ||
      h == '::1' ||
      h == '[::1]' ||
      h.endsWith('.localhost');
}
