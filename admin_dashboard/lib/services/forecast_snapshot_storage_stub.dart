abstract interface class ForecastSnapshotStorage {
  String? read(String key);

  void write(String key, String value);

  void remove(String key);

  Iterable<String> keys();
}

class _UnavailableForecastSnapshotStorage implements ForecastSnapshotStorage {
  const _UnavailableForecastSnapshotStorage();

  @override
  String? read(String key) => null;

  @override
  void remove(String key) {}

  @override
  void write(String key, String value) {}

  @override
  Iterable<String> keys() => const <String>[];
}

ForecastSnapshotStorage createForecastSnapshotStorage() =>
    const _UnavailableForecastSnapshotStorage();
