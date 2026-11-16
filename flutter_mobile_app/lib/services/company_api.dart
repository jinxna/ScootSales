import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart' show ValueNotifier;
import 'package:http/http.dart' as http;
import 'package:intl/intl.dart';

import '../models/company_lifecycle.dart';
import 'company_runtime.dart';
import 'invitation_service.dart';

class HeldWorkResult {
  const HeldWorkResult({
    required this.id,
    required this.outcome,
    this.reason,
    this.storedAs,
  });

  final String id;
  final String outcome;
  final String? reason;
  final String? storedAs;
}

class HeldWorkRefusal implements Exception {
  const HeldWorkRefusal.tooLarge()
    : tooLarge = true,
      timedOut = false,
      serverError = false,
      retryAfter = null;
  const HeldWorkRefusal.timedOut()
    : tooLarge = false,
      timedOut = true,
      serverError = false,
      retryAfter = null;
  const HeldWorkRefusal.serverError()
    : tooLarge = false,
      timedOut = false,
      serverError = true,
      retryAfter = null;
  const HeldWorkRefusal.tooMany(this.retryAfter)
    : tooLarge = false,
      timedOut = false,
      serverError = false;

  final bool tooLarge;
  final bool timedOut;
  final bool serverError;
  final Duration? retryAfter;
}

enum PasswordResetResult { accepted, tooMany, failed }

class CompanyApi {
  CompanyApi({
    http.Client? client,
    String? apiUrl,
    Future<String?> Function()? idToken,
  }) : _client = client,
       _apiUrl = apiUrl ?? _compiledApiUrl,
       _idToken = idToken ?? _firebaseIdToken;

  static const String _compiledApiUrl = String.fromEnvironment(
    'PLATFORM_API_URL',
  );
  static const Duration timeout = Duration(seconds: 15);
  static const int maxItemsPerRequest = 50;

  static final CompanyApi instance = CompanyApi();

  static final ValueNotifier<Duration?> clockOffset = ValueNotifier<Duration?>(
    null,
  );

  static final DateFormat _httpDate = DateFormat(
    "EEE, dd MMM yyyy HH:mm:ss 'GMT'",
    'en_US',
  );

  static void recordServerDate(String? header, DateTime deviceNow) {
    if (header == null) return;
    try {
      clockOffset.value = _httpDate.parseUtc(header).difference(deviceNow);
    } catch (_) {}
  }

  final http.Client? _client;
  final String _apiUrl;
  final Future<String?> Function() _idToken;
  String? _workspaceCache;

  bool get enabled => InvitationService.parseApiUrl(_apiUrl, '/') != null;

  static Future<String?> _firebaseIdToken() async =>
      FirebaseAuth.instance.currentUser?.getIdToken();

  Future<CompanyLifecycle?> readLifecycle() async {
    final Object? body = await _send('GET', (String ws) => '/v1/w/$ws/me');
    return body is Map ? CompanyLifecycle.tryParse(body['lifecycle']) : null;
  }

  Future<List<HeldWorkResult>?> submitHeldWork(
    List<Map<String, Object?>> items,
  ) async {
    if (items.isEmpty) return const <HeldWorkResult>[];
    http.Response? refused;
    bool timedOut = false;
    final Object? body = await _send(
      'POST',
      (String ws) => '/v1/w/$ws/held-work',
      payload: <String, Object?>{'items': items},
      onRefused: (http.Response response) => refused = response,
      onTimedOut: () => timedOut = true,
    );
    if (timedOut) throw const HeldWorkRefusal.timedOut();
    final http.Response? failure = refused;
    if (failure?.statusCode == 413) throw const HeldWorkRefusal.tooLarge();
    if (failure?.statusCode == 429) {
      final int? seconds = int.tryParse(failure!.headers['retry-after'] ?? '');
      throw HeldWorkRefusal.tooMany(
        Duration(seconds: (seconds ?? 300).clamp(30, 3600)),
      );
    }
    if (failure != null && failure.statusCode >= 500) {
      throw const HeldWorkRefusal.serverError();
    }
    final Object? rows = body is Map ? body['results'] : null;
    if (rows is! List) return null;
    final List<HeldWorkResult> results = <HeldWorkResult>[];
    for (final Object? row in rows) {
      if (row is! Map) continue;
      final Object? id = row['id'];
      final Object? outcome = row['outcome'];
      if (id is! String || outcome is! String) continue;
      final Object? reason = row['reason'];
      results.add(
        HeldWorkResult(
          id: id,
          outcome: outcome,
          reason: reason is String ? reason : null,
          storedAs: row['storedAs'] is String
              ? row['storedAs'] as String
              : null,
        ),
      );
    }
    return results;
  }

  Future<PasswordResetResult> requestPasswordReset(String email) async {
    final String? workspace = CompanyRuntime.current?.workspace;
    if (!enabled || workspace == null || workspace.isEmpty) {
      return PasswordResetResult.failed;
    }
    final Uri? uri = InvitationService.parseApiUrl(
      _apiUrl,
      '/v1/w/$workspace/auth/password-reset',
    );
    if (uri == null) return PasswordResetResult.failed;
    final http.Client client = _client ?? http.Client();
    try {
      final http.Response response = await client
          .post(
            uri,
            headers: const <String, String>{
              'Accept': 'application/json',
              'Content-Type': 'application/json',
            },
            body: jsonEncode(<String, Object?>{
              'email': email,
              'client': 'phone',
            }),
          )
          .timeout(timeout);
      if (response.statusCode == 202) return PasswordResetResult.accepted;
      if (response.statusCode == 429) return PasswordResetResult.tooMany;
      return PasswordResetResult.failed;
    } catch (_) {
      return PasswordResetResult.failed;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<Object?> _send(
    String method,
    String Function(String workspace) path, {
    Map<String, Object?>? payload,
    void Function(http.Response response)? onRefused,
    void Function()? onTimedOut,
  }) async {
    if (!enabled) return null;
    final http.Client client = _client ?? http.Client();
    try {
      final String? token = await _idToken();
      if (token == null || token.isEmpty) return null;
      final String? workspace = await _workspace(client, token);
      if (workspace == null) return null;
      final Uri? uri = InvitationService.parseApiUrl(_apiUrl, path(workspace));
      if (uri == null) return null;
      final Map<String, String> headers = <String, String>{
        'Authorization': 'Bearer $token',
        'Accept': 'application/json',
        if (payload != null) 'Content-Type': 'application/json',
      };
      final http.Response response;
      try {
        response = method == 'GET'
            ? await client.get(uri, headers: headers).timeout(timeout)
            : await client
                  .post(uri, headers: headers, body: jsonEncode(payload))
                  .timeout(timeout);
      } on TimeoutException {
        if (method != 'GET') onTimedOut?.call();
        rethrow;
      }
      recordServerDate(response.headers['date'], DateTime.now());
      if (response.statusCode != 200) {
        onRefused?.call(response);
        return null;
      }
      return jsonDecode(response.body);
    } catch (_) {
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<String?> _workspace(http.Client client, String token) async {
    final String? known = CompanyRuntime.current?.workspace ?? _workspaceCache;
    if (known != null && known.isNotEmpty) return known;
    final Uri? uri = InvitationService.parseApiUrl(_apiUrl, '/v1/me');
    if (uri == null) return null;
    final http.Response response = await client
        .get(
          uri,
          headers: <String, String>{
            'Authorization': 'Bearer $token',
            'Accept': 'application/json',
          },
        )
        .timeout(timeout);
    if (response.statusCode != 200) return null;
    final Object? body = jsonDecode(response.body);
    final Object? workspace = body is Map ? body['workspace'] : null;
    if (workspace is! String || workspace.isEmpty) return null;
    return _workspaceCache = workspace;
  }
}
