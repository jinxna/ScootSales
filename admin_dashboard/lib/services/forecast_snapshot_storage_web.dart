// ignore: deprecated_member_use, avoid_web_libraries_in_flutter
import 'dart:html' as html;

abstract interface class ForecastSnapshotStorage {
  String? read(String key);

  void write(String key, String value);

  void remove(String key);

  Iterable<String> keys();
}

class _BrowserForecastSnapshotStorage implements ForecastSnapshotStorage {
  const _BrowserForecastSnapshotStorage();

  @override
  String? read(String key) => html.window.localStorage[key];

  @override
  void write(String key, String value) {
    html.window.localStorage[key] = value;
  }

  @override
  void remove(String key) {
    html.window.localStorage.remove(key);
  }

  @override
  Iterable<String> keys() => html.window.localStorage.keys.toList();
}

ForecastSnapshotStorage createForecastSnapshotStorage() =>
    const _BrowserForecastSnapshotStorage();
