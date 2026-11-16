class CatalogueCache<T extends Object> {
  CatalogueCache({required this.ttl, DateTime Function()? clock})
    : _clock = clock ?? DateTime.now;

  final Duration ttl;
  final DateTime Function() _clock;

  T? _value;
  DateTime? _storedAt;
  int _loads = 0;

  int get loads => _loads;

  bool get hasFreshValue => _value != null && !_isExpired;

  Future<T> get(Future<T> Function() loader) async {
    final T? stored = _value;
    if (stored != null && !_isExpired) return stored;

    final T loaded = await loader();
    _value = loaded;
    _storedAt = _clock();
    _loads += 1;
    return loaded;
  }

  bool get _isExpired {
    final DateTime? storedAt = _storedAt;
    if (storedAt == null) return true;
    return _clock().difference(storedAt) >= ttl;
  }
}
