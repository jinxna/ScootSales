const Set<String> _loopbackHosts = <String>{'localhost', '127.0.0.1', '::1'};

Uri? checkedServiceUri(String value) {
  if (value != value.trim() || value.contains('?') || value.contains('#')) {
    return null;
  }
  final Uri? uri = Uri.tryParse(value);
  if (uri == null ||
      !uri.hasAuthority ||
      uri.host.isEmpty ||
      uri.userInfo.isNotEmpty ||
      uri.hasQuery ||
      uri.hasFragment) {
    return null;
  }
  final bool loopback =
      uri.scheme == 'http' && _loopbackHosts.contains(uri.host.toLowerCase());
  if (uri.scheme != 'https' && !loopback) return null;
  if (uri.hasPort && (uri.port < 1 || uri.port > 65535)) return null;
  if (uri.path.split('/').any((String part) => part == '.' || part == '..')) {
    return null;
  }
  return uri;
}
