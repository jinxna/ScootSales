import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../app/workspace_runtime.dart';
import 'forecasting_file_picker.dart';

export 'forecasting_file_picker.dart' show PickedFile;

class ForecastingApiService {
  ForecastingApiService({
    String? baseUrl,
    http.Client? client,
    Future<String?> Function()? idTokenProvider,
  }) : _client = client ?? http.Client(),
       _idTokenProvider = idTokenProvider ?? _currentFirebaseIdToken,
       _baseUrl = baseUrl;

  static const int maxUploadBytes = 10 * 1024 * 1024;
  static const int maxResponseRows = 1000;

  final String? _baseUrl;
  final http.Client _client;
  final Future<String?> Function() _idTokenProvider;

  String get base =>
      _baseUrl ?? WorkspaceRuntime.current?.services['forecastingUrl'] ?? '';

  Uri _uri(String path) {
    if (base.isEmpty) {
      throw StateError(
        'The forecasting service is not connected for this company.',
      );
    }
    return Uri.parse('$base$path');
  }

  static Future<String?> _currentFirebaseIdToken() async {
    return FirebaseAuth.instance.currentUser?.getIdToken();
  }

  Future<Map<String, String>> _authorizedHeaders() async {
    final String token = (await _idTokenProvider() ?? '').trim();
    if (token.isEmpty) {
      throw StateError(
        'Sign in as an active administrator before using forecasting data.',
      );
    }
    return <String, String>{'Authorization': 'Bearer $token'};
  }

  Future<bool> isHealthy() async {
    if (base.isEmpty) return false;
    try {
      final http.Response res = await _client
          .get(_uri('/health'))
          .timeout(const Duration(seconds: 2));
      return res.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<bool> isReady() async {
    if (!await isHealthy()) return false;
    try {
      final http.Response response = await _client
          .get(_uri('/forecast-runs'), headers: await _authorizedHeaders())
          .timeout(const Duration(seconds: 3));
      return response.statusCode == 200;
    } catch (_) {
      return false;
    }
  }

  Future<Map<String, dynamic>> health() async {
    final http.Response res = await _client
        .get(_uri('/health'))
        .timeout(const Duration(seconds: 3));
    return _asMap(res.body);
  }

  Future<Map<String, dynamic>> latestForecast() async {
    final http.Response res = await _client
        .get(_uri('/latest-forecast'), headers: await _authorizedHeaders())
        .timeout(const Duration(seconds: 30));
    final Map<String, dynamic> payload = _checkedMap(
      res.statusCode,
      res.body,
      '/latest-forecast',
    );
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final dynamic row
        in (payload['rows'] as List<dynamic>? ?? const <dynamic>[])) {
      if (row is Map) rows.add(Map<String, dynamic>.from(row));
      if (rows.length >= maxResponseRows) break;
    }
    return <String, dynamic>{...payload, 'rows': rows};
  }

  Future<List<Map<String, dynamic>>> forecastRuns() =>
      _getList('/forecast-runs');

  Future<List<Map<String, dynamic>>> importErrors() =>
      _getList('/forecast-errors');

  Future<Map<String, dynamic>> runForecast() async {
    final http.Response res = await _client
        .post(_uri('/run-forecast'), headers: await _authorizedHeaders())
        .timeout(const Duration(minutes: 12));
    return _checkedMap(res.statusCode, res.body, '/run-forecast');
  }

  Future<Map<String, dynamic>> previewForecast(int historyWeeks) async {
    final http.Response res = await _client
        .post(
          _uri('/preview-forecast'),
          headers: <String, String>{
            ...await _authorizedHeaders(),
            'Content-Type': 'application/json',
          },
          body: jsonEncode(<String, dynamic>{'historyWeeks': historyWeeks}),
        )
        .timeout(const Duration(minutes: 3));
    return _checkedMap(res.statusCode, res.body, '/preview-forecast');
  }

  Future<Map<String, dynamic>> importExcel(PickedFile file) async {
    final String extension = file.name
        .replaceAll('\\', '/')
        .split('/')
        .last
        .split('.')
        .last
        .toLowerCase();
    if (extension != 'csv' && extension != 'xlsx') {
      throw const FormatException('Choose a .csv or .xlsx forecast file.');
    }
    if (file.bytes.length > maxUploadBytes) {
      throw const FormatException('Forecast imports are limited to 10 MiB.');
    }
    final Uri uri = _uri('/import-excel');
    final http.MultipartRequest request = http.MultipartRequest('POST', uri)
      ..headers.addAll(await _authorizedHeaders())
      ..files.add(
        http.MultipartFile.fromBytes('file', file.bytes, filename: file.name),
      );
    final http.StreamedResponse streamed = await _client
        .send(request)
        .timeout(const Duration(minutes: 12));
    final String body = await streamed.stream.bytesToString();
    return _checkedMap(streamed.statusCode, body, '/import-excel');
  }

  Future<List<Map<String, dynamic>>> _getList(String path) async {
    final http.Response res = await _client
        .get(_uri(path), headers: await _authorizedHeaders())
        .timeout(const Duration(seconds: 5));
    if (res.statusCode != 200) {
      throw Exception(
        'Forecasting service returned ${res.statusCode} for $path',
      );
    }
    final dynamic decoded = jsonDecode(res.body);
    if (decoded is! List) return <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> rows = <Map<String, dynamic>>[];
    for (final dynamic value in decoded) {
      if (rows.length >= maxResponseRows) break;
      if (value is Map) rows.add(Map<String, dynamic>.from(value));
    }
    return rows;
  }

  static Map<String, dynamic> _asMap(String body) {
    try {
      final dynamic decoded = jsonDecode(body);
      return decoded is Map
          ? Map<String, dynamic>.from(decoded)
          : <String, dynamic>{};
    } catch (_) {
      return <String, dynamic>{};
    }
  }

  static Map<String, dynamic> _checkedMap(
    int statusCode,
    String body,
    String path,
  ) {
    final Map<String, dynamic> decoded = _asMap(body);
    if (statusCode < 200 || statusCode >= 300) {
      final String detail = (decoded['detail'] ?? decoded['message'] ?? '')
          .toString()
          .trim();
      throw Exception(
        detail.isEmpty
            ? 'Forecasting service returned $statusCode for $path.'
            : 'Forecasting service rejected $path: $detail',
      );
    }
    return decoded;
  }

  static Future<PickedFile?> pickSpreadsheet() => pickSpreadsheetFile();
}
