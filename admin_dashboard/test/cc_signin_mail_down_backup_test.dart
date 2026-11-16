import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/staff_auth.dart';

void main() {
  test('a staff member whose code cannot be mailed can use a backup code', () async {
    final List<http.Request> sent = <http.Request>[];
    final MockClient client = MockClient((http.Request request) async {
      sent.add(request);
      if (request.url.path.endsWith('/session/code')) {
        return http.Response(
          jsonEncode(<String, Object?>{
            'detail':
                'Sign-in codes cannot be sent today because the daily mail limit is reached. Use a backup code, or ask an owner to help.',
          }),
          503,
          headers: <String, String>{'content-type': 'application/json'},
        );
      }
      return http.Response(
        jsonEncode(<String, Object?>{
          'sessionId': 's1',
          'email': 'a@b.test',
          'role': 'owner',
          'usedBackupCode': true,
          'backupCodesLeft': 4,
        }),
        200,
        headers: <String, String>{'content-type': 'application/json'},
      );
    });
    final StaffAuth auth = StaffAuth()
      ..api = StaffApiClient(
        client: client,
        baseUri: Uri.parse('http://localhost:9000'),
      );

    await auth.requestCode();

    expect(auth.step, StaffAuthStep.code);
    expect(auth.canUseBackupCode, isTrue);

    await auth.verify(backupCode: 'abcd-2345-wxyz');

    expect(auth.step, StaffAuthStep.signedIn);
    final http.Request verify = sent.last;
    expect(verify.url.path, endsWith('/session/verify'));
    expect(jsonDecode(verify.body), <String, Object?>{
      'backupCode': 'abcd-2345-wxyz',
    });
  });
}
