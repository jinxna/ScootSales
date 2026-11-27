import 'dart:async';
import 'dart:convert';
import 'dart:io';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:http/http.dart' as http;

import '../edition.dart';
import '../services/company_project.dart';
import '../services/company_runtime.dart';
import 'mobile_copilot_grammar.dart';

const String _buildCopilotUrl = String.fromEnvironment('COPILOT_URL');
const Duration kMobileCopilotTimeout = Duration(seconds: 25);

const List<Map<String, Object?>> _pages = <Map<String, Object?>>[
  {
    'key': 'route',
    'label': 'My Route',
    'aliases': ['assigned route', 'today route', 'laluan'],
  },
  {
    'key': 'orders',
    'label': 'My Orders',
    'aliases': ['order history', 'pesanan'],
  },
  {
    'key': 'planner',
    'label': 'Planner',
    'aliases': ['visit planner', 'perancang'],
  },
  {
    'key': 'profile',
    'label': 'Profile',
    'aliases': ['my account', 'profil'],
  },
];
const List<String> _actions = kBasicEdition
    ? <String>['search_orders']
    : <String>['search_orders', 'brief_retailer'];

enum CopilotServerFailure {
  signIn('Please sign in again.'),
  noAccess('You do not have Scout access. Ask your admin.'),
  tooMany('Too many questions. Wait a minute.'),
  personLimit(
    'You have used your share of assistant requests for today. It resets at midnight, Malaysia time.',
  ),
  companyLimit(
    'Your company has used all its assistant requests for today. They reset at midnight, Malaysia time.',
  ),
  salespeopleLimit(
    'The salespeople at your company have used their share of assistant requests for today. It resets at midnight, Malaysia time.',
  ),
  assistantUnavailable(
    'The assistant did not answer this time. Ask again, or try one of these.',
  ),
  waking('The server is waking up. Try again in a few seconds.'),
  requestRefused(
    'The assistant refused this request. Change the question and try again.',
  ),
  assistantProblem('The assistant had a problem. Try again.'),

  unreachable('The Scout server is not available right now.'),
  offline(
    kBasicEdition
        ? 'This question needs a signal. Try: next stop, last order, follow-ups.'
        : 'This question needs a signal. Try: next stop, brief, last order, follow-ups.',
  );

  const CopilotServerFailure(this.message);
  final String message;
}

class CopilotServerResult {
  const CopilotServerResult.intent(CopilotIntent this.intent) : failure = null;
  const CopilotServerResult.failure(CopilotServerFailure this.failure)
    : intent = null;

  final CopilotIntent? intent;
  final CopilotServerFailure? failure;
}

class _HttpFailure implements Exception {
  _HttpFailure(this.status);
  final int status;
}

class _SignedOut implements Exception {}

class _AssistantUnavailable implements Exception {
  _AssistantUnavailable(this.failure);
  final CopilotServerFailure failure;
}

class MobileCopilotServer {
  MobileCopilotServer({
    required this.baseUrl,
    required this.idToken,
    http.Client? client,
  }) : _client = client;

  final Uri baseUrl;
  final Future<String?> Function() idToken;
  final http.Client? _client;

  static String get _copilotUrl {
    final ActiveCompany? company = CompanyRuntime.current;
    if (company != null && company.code != null) {
      return company.copilotUrl ?? '';
    }
    return _buildCopilotUrl;
  }

  static MobileCopilotServer? fromEnvironment() {
    final String url = _copilotUrl;
    if (url.isEmpty) return null;
    return MobileCopilotServer(
      baseUrl: Uri.parse(url),
      idToken: () async => FirebaseAuth.instance.currentUser?.getIdToken(),
    );
  }

  static void warmUp() {
    final String url = _copilotUrl;
    if (url.isEmpty) return;
    unawaited(() async {
      final http.Client client = http.Client();
      try {
        await client
            .get(Uri.parse(url).resolve('/health'))
            .timeout(kMobileCopilotTimeout);
      } catch (_) {
      } finally {
        client.close();
      }
    }());
  }

  Future<CopilotServerResult> interpret(String text) async {
    final http.Client client = _client ?? http.Client();
    try {
      return CopilotServerResult.intent(
        await _interpret(client, text).timeout(kMobileCopilotTimeout),
      );
    } on _HttpFailure catch (error) {
      debugPrint('Scout server returned HTTP ${error.status}');
      return CopilotServerResult.failure(switch (error.status) {
        401 => CopilotServerFailure.signIn,
        403 => CopilotServerFailure.noAccess,
        408 => CopilotServerFailure.assistantProblem,
        429 => CopilotServerFailure.tooMany,
        502 || 503 || 504 => CopilotServerFailure.waking,
        >= 400 && < 500 => CopilotServerFailure.requestRefused,
        _ => CopilotServerFailure.assistantProblem,
      });
    } on TimeoutException {
      return const CopilotServerResult.failure(CopilotServerFailure.waking);
    } on SocketException {
      return const CopilotServerResult.failure(
        CopilotServerFailure.unreachable,
      );
    } on http.ClientException {
      return const CopilotServerResult.failure(
        CopilotServerFailure.unreachable,
      );
    } on _AssistantUnavailable catch (error) {
      return CopilotServerResult.failure(error.failure);
    } on _SignedOut {
      return const CopilotServerResult.failure(CopilotServerFailure.signIn);
    } catch (error) {
      debugPrint('Scout server call failed: $error');
      return const CopilotServerResult.failure(CopilotServerFailure.waking);
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<CopilotIntent> _interpret(http.Client client, String text) async {
    const CopilotIntent none = CopilotIntent(CopilotIntentKind.unknown);
    final String? token = await idToken();
    if (token == null || token.isEmpty) throw _SignedOut();
    final http.Response response = await client.post(
      baseUrl.resolve('/v1/interpret'),
      headers: <String, String>{
        'Content-Type': 'application/json',
        'Authorization': 'Bearer $token',
      },
      body: jsonEncode(<String, Object?>{
        'text': text,
        'pages': _pages,
        'actions': _actions,
      }),
    );
    if (response.statusCode != 200) throw _HttpFailure(response.statusCode);
    final Object? body = jsonDecode(response.body);
    if (body is Map<String, dynamic> && body['unavailable'] == true) {
      throw _AssistantUnavailable(switch (body['unavailableReason']) {
        'person_limit' => CopilotServerFailure.personLimit,
        'company_limit' => CopilotServerFailure.companyLimit,
        'salesperson_limit' => CopilotServerFailure.salespeopleLimit,
        _ => CopilotServerFailure.assistantUnavailable,
      });
    }
    final Object? call = body is Map<String, dynamic> ? body['call'] : null;
    if (call is! Map<String, dynamic>) return none;
    final Object? args = call['args'];
    final Map<String, dynamic> a = args is Map<String, dynamic>
        ? args
        : const <String, dynamic>{};
    switch (call['name']) {
      case 'navigate_to_page':
        final CopilotIntentKind? page = switch (a['page']) {
          'route' => CopilotIntentKind.openRoute,
          'orders' => CopilotIntentKind.openOrders,
          'planner' => CopilotIntentKind.openPlanner,
          'profile' => CopilotIntentKind.openProfile,
          _ => null,
        };
        if (page == null || !copilotAsksForPage(text, page)) return none;
        return CopilotIntent(page);
      case 'search_orders':
        if ('${a['salesperson'] ?? ''}'.trim().isNotEmpty) {
          return const CopilotIntent(CopilotIntentKind.refuse);
        }
        return a['period'] == 'this_week'
            ? const CopilotIntent(CopilotIntentKind.ordersThisWeek)
            : const CopilotIntent(CopilotIntentKind.openOrders);
      case 'brief_retailer':
        final String name = '${a['retailer'] ?? ''}'.trim();
        return name.isEmpty
            ? none
            : CopilotIntent(
                CopilotIntentKind.visitBrief,
                retailer: normaliseCopilotText(name),
              );
    }
    return none;
  }
}
