import 'dart:async';
import 'dart:convert';

import 'package:flutter/foundation.dart'
    show TargetPlatform, defaultTargetPlatform, kIsWeb;
import 'package:http/http.dart' as http;

class InvitationRedeemed {
  const InvitationRedeemed({
    required this.customToken,
    required this.workspace,
    required this.projectId,
    required this.signInId,
  });

  final String customToken;
  final String workspace;
  final String projectId;
  final String signInId;
}

class EmailCodeRequest {
  const EmailCodeRequest({
    required this.isRequired,
    required this.sentTo,
    required this.expiresInSeconds,
  });

  final bool isRequired;
  final String sentTo;
  final int expiresInSeconds;
}

class InvitationPayload {
  const InvitationPayload({required this.workspace, required this.code});

  final String workspace;

  final String code;
}

class InvitationException implements Exception {
  const InvitationException(this.message, {this.status});

  final String message;

  final int? status;

  @override
  String toString() => 'InvitationException($status, $message)';
}

class InvitationService {
  InvitationService({http.Client? client, String? apiUrl, String? device})
    : _client = client,
      _apiUrl = apiUrl ?? _compiledApiUrl,
      _device = device ?? deviceLabel();

  static const String _compiledApiUrl = String.fromEnvironment(
    'PLATFORM_API_URL',
  );

  static const Duration timeout = Duration(seconds: 15);
  static const int minPasswordLength = 8;
  static const int maxPasswordLength = 128;

  static const String _alphabet = '0123456789ABCDEFGHJKMNPQRSTVWXYZ';
  static const int _codeLength = 12;

  static const String invalidCodeMessage =
      'The invitation code or check is not valid.';
  static const String expiredMessage =
      'This invitation has expired. Ask your administrator for a new one.';
  static const String wrongCompanyMessage =
      'This invitation is for another company. Change company first.';
  static const String lockedMessage =
      'This invitation is locked after too many tries. Ask your administrator for a new one.';
  static const String emailCodeLockedMessage =
      'Too many wrong codes. Tap Resend to get a new code.';
  static const String _serverEmailCodeLocked =
      'Too many wrong email codes. Ask for a new one.';
  static const String rateLimitedMessage =
      'Too many attempts from this network. Try again later.';
  static const String badInputMessage =
      'Check the invitation details and try again.';
  static const String offlineMessage =
      'No connection. Reconnect and try again.';
  static const String unavailableMessage =
      'The invitation service is not available. Try again later.';
  static const String notAnInvitationMessage =
      'That QR code is not a Scoot invitation.';

  final http.Client? _client;
  final String _apiUrl;
  final String _device;

  Uri? _endpoint() => parseApiUrl(_apiUrl, '/v1/invitations/redeem');

  bool get enabled => _endpoint() != null;

  static String deviceLabel() {
    if (kIsWeb) return 'Web';
    return switch (defaultTargetPlatform) {
      TargetPlatform.android => 'Android phone',
      TargetPlatform.iOS => 'iPhone',
      _ => 'Phone',
    };
  }

  static Uri? parseApiUrl(String base, String path) {
    final Uri? uri = Uri.tryParse(base.trim());
    if (uri == null || uri.host.isEmpty) return null;
    final bool loopback = uri.host == '127.0.0.1' || uri.host == 'localhost';
    final bool allowed =
        uri.scheme == 'https' || (uri.scheme == 'http' && loopback);
    if (!allowed) return null;
    final String root = uri.path.endsWith('/')
        ? uri.path.substring(0, uri.path.length - 1)
        : uri.path;
    return Uri(
      scheme: uri.scheme,
      host: uri.host,
      port: uri.hasPort ? uri.port : null,
      path: '$root$path',
    );
  }

  static String? normalizeCode(String input) {
    final StringBuffer out = StringBuffer();
    for (final int unit in input.toUpperCase().runes) {
      final String ch = String.fromCharCode(unit);
      if (ch == ' ' || ch == '-') continue;
      out.write(switch (ch) {
        'O' => '0',
        'I' || 'L' => '1',
        _ => ch,
      });
    }
    final String code = out.toString();
    if (code.length != _codeLength) return null;
    for (final int unit in code.codeUnits) {
      if (!_alphabet.contains(String.fromCharCode(unit))) return null;
    }
    return code;
  }

  static String formatCode(String code) =>
      '${code.substring(0, 4)}-${code.substring(4, 8)}-${code.substring(8)}';

  static InvitationPayload? parseQr(String raw) {
    final List<String> parts = raw.trim().split(':');
    if (parts.length != 4) return null;
    if (parts[0] != 'scoot-invite' || parts[1] != '1') return null;
    final String workspace = parts[2].trim();
    if (workspace.isEmpty) return null;
    final String? code = normalizeCode(parts[3]);
    if (code == null) return null;
    return InvitationPayload(workspace: workspace, code: code);
  }

  Future<EmailCodeRequest> requestEmailCode({
    required String code,
    required String check,
  }) async {
    final Uri? uri = parseApiUrl(_apiUrl, '/v1/invitations/email-code');
    if (uri == null) throw const InvitationException(unavailableMessage);
    final String? normalised = normalizeCode(code);
    if (normalised == null) {
      throw const InvitationException(invalidCodeMessage, status: 403);
    }
    if (check.trim().isEmpty) {
      throw const InvitationException(badInputMessage, status: 400);
    }
    final http.Client client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await client
          .post(
            uri,
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, Object?>{
              'code': normalised,
              'check': check.trim(),
            }),
          )
          .timeout(timeout);
    } catch (_) {
      throw const InvitationException(offlineMessage);
    } finally {
      if (_client == null) client.close();
    }
    if (response.statusCode != 200) {
      throw InvitationException(
        _messageFor(response.statusCode, response.body),
        status: response.statusCode,
      );
    }
    try {
      final Object? json = jsonDecode(response.body);
      if (json is Map<String, Object?>) {
        final Object? expires = json['expiresInSeconds'];
        final Object? sentTo = json['sentTo'];
        return EmailCodeRequest(
          isRequired: json['required'] == true,
          sentTo: sentTo is String ? sentTo : '',
          expiresInSeconds: expires is int ? expires : 0,
        );
      }
    } catch (_) {}
    throw const InvitationException(unavailableMessage);
  }

  Future<InvitationRedeemed> redeem({
    required String code,
    required String check,
    required String password,
    String? projectId,
    String? emailCode,
  }) async {
    final Uri? uri = _endpoint();
    if (uri == null) throw const InvitationException(unavailableMessage);
    final String? normalised = normalizeCode(code);
    if (normalised == null) {
      throw const InvitationException(invalidCodeMessage, status: 403);
    }
    if (check.trim().isEmpty ||
        password.length < minPasswordLength ||
        password.length > maxPasswordLength) {
      throw const InvitationException(badInputMessage, status: 400);
    }

    final http.Client client = _client ?? http.Client();
    final http.Response response;
    try {
      response = await client
          .post(
            uri,
            headers: const <String, String>{
              'Content-Type': 'application/json',
              'Accept': 'application/json',
            },
            body: jsonEncode(<String, Object?>{
              'code': normalised,
              'check': check.trim(),
              'password': password,
              'device': _device,
              'projectId': ?projectId,
              'emailCode': ?emailCode,
            }),
          )
          .timeout(timeout);
    } on TimeoutException {
      throw const InvitationException(offlineMessage);
    } catch (_) {
      throw const InvitationException(offlineMessage);
    } finally {
      if (_client == null) client.close();
    }

    if (response.statusCode == 200) return _parseSuccess(response.body);
    throw InvitationException(
      _messageFor(response.statusCode, response.body),
      status: response.statusCode,
    );
  }

  static InvitationRedeemed _parseSuccess(String body) {
    try {
      final Object? json = jsonDecode(body);
      if (json is Map<String, Object?>) {
        String? text(String key) {
          final Object? value = json[key];
          return value is String && value.isNotEmpty ? value : null;
        }

        final String? token = text('customToken');
        final String? workspace = text('workspace');
        final String? projectId = text('projectId');
        final String? signInId = text('signInId');
        if (token != null &&
            workspace != null &&
            projectId != null &&
            signInId != null) {
          return InvitationRedeemed(
            customToken: token,
            workspace: workspace,
            projectId: projectId,
            signInId: signInId,
          );
        }
      }
    } catch (_) {}
    throw const InvitationException(unavailableMessage);
  }

  static String _messageFor(int status, String body) {
    switch (status) {
      case 403:
        final String? reason = _detail(body);
        return reason != null && reason.startsWith('The email code')
            ? reason
            : invalidCodeMessage;
      case 410:
        return _detail(body) ?? expiredMessage;
      case 409:
        return _detail(body) ?? wrongCompanyMessage;
      case 423:
        return lockedMessage;
      case 429:
        final String? limit = _detail(body);
        if (limit == _serverEmailCodeLocked) return emailCodeLockedMessage;
        if (limit != null && limit.startsWith('Too many email codes')) {
          return limit;
        }
        return rateLimitedMessage;
      case 400:
      case 422:
        return _detail(body) ?? badInputMessage;
      default:
        return unavailableMessage;
    }
  }

  static String? _detail(String body) {
    try {
      final Object? json = jsonDecode(body);
      if (json is Map<String, Object?>) {
        final Object? detail = json['detail'];
        if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      }
    } catch (_) {}
    return null;
  }
}
