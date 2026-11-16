import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/copilot/mobile_copilot_server.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

Future<CopilotServerFailure?> failureFor(int status) async {
  final MobileCopilotServer server = MobileCopilotServer(
    baseUrl: Uri.parse('http://assistant.test'),
    idToken: () async => 'token',
    client: MockClient((http.Request _) async => http.Response('', status)),
  );
  return (await server.interpret('hello there')).failure;
}

void main() {
  test('each HTTP status maps to the failure that matches its cause', () async {
    for (final int status in <int>[502, 503, 504]) {
      expect(await failureFor(status), CopilotServerFailure.waking);
    }
    expect(await failureFor(401), CopilotServerFailure.signIn);
    expect(await failureFor(403), CopilotServerFailure.noAccess);
    expect(await failureFor(408), CopilotServerFailure.assistantProblem);
    expect(await failureFor(429), CopilotServerFailure.tooMany);
    expect(await failureFor(400), CopilotServerFailure.requestRefused);
    expect(await failureFor(404), CopilotServerFailure.requestRefused);
    expect(await failureFor(500), CopilotServerFailure.assistantProblem);
    expect(await failureFor(501), CopilotServerFailure.assistantProblem);
  });
}
