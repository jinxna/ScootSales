import 'dart:convert';
import 'dart:developer' as developer;

class AppLogger {
  const AppLogger._();

  static void error(
    String event, {
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    _write(
      event,
      level: 1000,
      error: error,
      stackTrace: stackTrace,
      fields: fields,
    );
  }

  static void _write(
    String event, {
    required int level,
    Object? error,
    StackTrace? stackTrace,
    Map<String, Object?> fields = const <String, Object?>{},
  }) {
    final payload = <String, Object?>{
      'event': event,
      if (fields.isNotEmpty)
        'fields': fields.map(
          (key, value) => MapEntry<String, Object?>(key, _normalise(value)),
        ),
    };

    developer.log(
      jsonEncode(payload),
      name: 'admin_dashboard',
      level: level,
      error: error,
      stackTrace: stackTrace,
    );
  }

  static Object? _normalise(Object? value) {
    if (value == null || value is num || value is bool || value is String) {
      return value;
    }
    if (value is DateTime) {
      return value.toIso8601String();
    }
    if (value is Iterable) {
      return value.map(_normalise).toList(growable: false);
    }
    if (value is Map) {
      final result = <String, Object?>{};
      value.forEach((key, mapValue) {
        result['$key'] = _normalise(mapValue);
      });
      return result;
    }
    return value.toString();
  }
}
