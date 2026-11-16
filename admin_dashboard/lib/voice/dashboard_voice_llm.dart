import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

import 'dashboard_voice_types.dart';

class DashboardVoiceLlmProposal {
  const DashboardVoiceLlmProposal({
    required this.pageKey,
    required this.confidence,
  });

  final String? pageKey;
  final double confidence;
}

typedef DashboardVoicePageProposer =
    Future<DashboardVoiceLlmProposal?> Function(
      String transcript,
      List<DashboardVoicePage> pages,
    );

const double kVoiceLlmMinConfidence = 0.98;

const double kVoiceLlmSuggestConfidence = 0.9;
const Duration kVoiceLlmTimeout = Duration(milliseconds: 2500);

DashboardVoicePageProposer httpDashboardVoiceProposer(
  Uri baseUrl, {
  http.Client? client,
}) {
  return (String transcript, List<DashboardVoicePage> pages) async {
    final http.Client httpClient = client ?? http.Client();
    try {
      final http.Response response = await httpClient
          .post(
            baseUrl.resolve('/propose'),
            headers: const <String, String>{'Content-Type': 'application/json'},
            body: jsonEncode(<String, Object?>{
              'text': transcript,
              'pages': <Map<String, Object?>>[
                for (final DashboardVoicePage page in pages)
                  <String, Object?>{
                    'key': page.key,
                    'label': page.label,
                    'aliases': page.aliases.take(8).toList(),
                  },
              ],
            }),
          )
          .timeout(kVoiceLlmTimeout);
      if (response.statusCode != 200) return null;
      final Object? body = jsonDecode(response.body);
      if (body is! Map<String, dynamic>) return null;
      final Object? key = body['pageKey'];
      final Object? confidence = body['confidence'];
      if (key is! String || confidence is! num) return null;
      return DashboardVoiceLlmProposal(
        pageKey: key,
        confidence: confidence.toDouble(),
      );
    } finally {
      if (client == null) httpClient.close();
    }
  };
}
