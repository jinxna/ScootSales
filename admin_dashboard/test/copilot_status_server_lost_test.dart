import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/voice/copilot/copilot_client.dart';
import 'package:flutter_web_app/voice/copilot/copilot_status.dart';

class _Server extends CopilotServerClient {
  _Server() : super(baseUrl: Uri.parse('http://127.0.0.1:1'), idToken: () async => 't');

  bool alive = true;

  @override
  Future<bool> isReady() async => alive;
}

void main() {
  test('Scout stops showing ready when the server stops answering', () async {
    final _Server server = _Server();
    final CopilotServerStatus status = CopilotServerStatus(server);
    await status.wake();
    expect(status.value, CopilotServerState.ready);

    server.alive = false;
    status.serverUnreachable();

    expect(status.value, isNot(CopilotServerState.ready));
    status.dispose();
  });
}
