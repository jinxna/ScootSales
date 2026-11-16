import 'dart:async';
import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../../app/workspace_runtime.dart';
import '../dashboard_voice_types.dart';

class CopilotProposal {
  const CopilotProposal({required this.name, required this.args});

  final String name;
  final Map<String, Object?> args;
}

class CopilotServerBusy implements Exception {
  const CopilotServerBusy();
}

class CopilotServerUnreachable implements Exception {
  const CopilotServerUnreachable();
}

class CopilotAssistantUnavailable implements Exception {
  const CopilotAssistantUnavailable({this.reason});

  final String? reason;
}

const Duration kCopilotHealthTimeout = Duration(seconds: 5);
const Duration kCopilotInterpretTimeout = Duration(seconds: 10);

class CopilotServerClient {
  CopilotServerClient({
    required this.baseUrl,
    required this.idToken,
    http.Client? client,
  }) : _client = client;

  final Uri baseUrl;
  final Future<String?> Function() idToken;
  final http.Client? _client;

  Future<bool> isReady() async {
    final http.Client client = _client ?? http.Client();
    try {
      final http.Response response = await client
          .get(baseUrl.resolve('/health'))
          .timeout(kCopilotHealthTimeout);
      if (response.statusCode != 200) return false;
      final Object? body = jsonDecode(response.body);
      return body is Map<String, dynamic> && body['ready'] == true;
    } catch (_) {
      return false;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<CopilotProposal?> interpret({
    required String text,
    required List<DashboardVoicePage> pages,
    required List<String> actions,
  }) async {
    final String? token = await _safeToken();
    if (token == null || token.isEmpty) return null;
    final http.Client client = _client ?? http.Client();
    try {
      final http.Response response = await client
          .post(
            baseUrl.resolve('/v1/interpret'),
            headers: <String, String>{
              'Content-Type': 'application/json',
              'Authorization': 'Bearer $token',
            },
            body: jsonEncode(<String, Object?>{
              'text': text,
              'pages': <Map<String, Object?>>[
                for (final DashboardVoicePage page in pages)
                  <String, Object?>{
                    'key': page.key,
                    'label': page.label,
                    'aliases': page.aliases.take(8).toList(),
                  },
              ],
              'actions': actions,
            }),
          )
          .timeout(kCopilotInterpretTimeout);
      if (response.statusCode == 429 || response.statusCode == 503) {
        throw const CopilotServerBusy();
      }
      if (response.statusCode >= 500) throw const CopilotServerUnreachable();
      if (response.statusCode != 200) return null;
      final Object? body = jsonDecode(response.body);
      if (body is Map<String, dynamic> && body['unavailable'] == true) {
        final Object? reason = body['unavailableReason'];
        throw CopilotAssistantUnavailable(
          reason: reason is String ? reason : null,
        );
      }
      final Object? call = body is Map<String, dynamic> ? body['call'] : null;
      if (call is! Map<String, dynamic>) return null;
      final Object? name = call['name'];
      final Object? args = call['args'];
      if (name is! String || args is! Map<String, dynamic>) return null;
      return CopilotProposal(name: name, args: Map<String, Object?>.of(args));
    } on CopilotServerBusy {
      rethrow;
    } on CopilotServerUnreachable {
      rethrow;
    } on CopilotAssistantUnavailable {
      rethrow;
    } on TimeoutException {
      throw const CopilotServerUnreachable();
    } on http.ClientException {
      throw const CopilotServerUnreachable();
    } catch (_) {
      return null;
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<String?> _safeToken() async {
    try {
      return await idToken();
    } catch (_) {
      return null;
    }
  }
}

CopilotServerClient? copilotServerFromEnvironment() {
  final String url = WorkspaceRuntime.current?.services['copilotUrl'] ?? '';
  if (url.isEmpty) return null;
  return CopilotServerClient(
    baseUrl: Uri.parse(url),
    idToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
  );
}
