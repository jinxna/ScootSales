import 'dart:convert';

import 'package:flutter_test/flutter_test.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';

import 'package:flutter_web_app/control_centre/staff_api_client.dart';
import 'package:flutter_web_app/control_centre/staff_auth.dart';
import 'package:flutter_web_app/control_centre/staff_browser.dart';

const String _key = 'staffTrustedDevice';

String _stored({
  String email = 'a@b.test',
  String token = 'tok-1',
  Duration lasts = const Duration(days: 29),
}) => jsonEncode(<String, String>{
  'email': email,
  'token': token,
  'expiresAt': DateTime.now().toUtc().add(lasts).toIso8601String(),
});

http.Response _json(int status, Map<String, Object?> body) => http.Response(
  jsonEncode(body),
  status,
  headers: <String, String>{'content-type': 'application/json'},
);

Map<String, Object?> _signedIn({Map<String, Object?> extra = const {}}) =>
    <String, Object?>{
      'sessionId': 's1',
      'email': 'a@b.test',
      'role': 'owner',
      'usedBackupCode': false,
      'backupCodesLeft': 4,
      ...extra,
    };

({StaffAuth auth, List<http.Request> sent}) _build(
  http.Response Function(http.Request request) answer,
) {
  final List<http.Request> sent = <http.Request>[];
  final StaffAuth auth = StaffAuth()
    ..email = 'A@B.test'
    ..api = StaffApiClient(
      client: MockClient((http.Request request) async {
        sent.add(request);
        return answer(request);
      }),
      baseUri: Uri.parse('http://localhost:9000'),
    );
  return (auth: auth, sent: sent);
}

http.Response _codeSent() => _json(200, <String, Object?>{
  'sentTo': 'a***@b.test',
  'sending': false,
  'backupCodesLeft': 4,
});

bool _asked(List<http.Request> sent, String tail) =>
    sent.any((http.Request r) => r.url.path.endsWith(tail));

void main() {
  setUp(() {
    localRemove(_key);
    localRemove('staffSession');
    sessionRemove('staffSession');
  });

  test('ticking the box sends remember and stores the device token', () async {
    final h = _build(
      (http.Request r) => _json(
        200,
        _signedIn(
          extra: <String, Object?>{
            'deviceToken': 'tok-9',
            'deviceTokenExpiresAt': DateTime.now()
                .toUtc()
                .add(const Duration(days: 30))
                .toIso8601String(),
          },
        ),
      ),
    );

    await h.auth.verify(code: '123456', remember: true);

    expect(jsonDecode(h.sent.single.body), containsPair('remember', true));
    expect(h.auth.step, StaffAuthStep.signedIn);
    final Map<String, Object?> record =
        jsonDecode(localRead(_key)!) as Map<String, Object?>;
    expect(record['token'], 'tok-9');
    expect(record['email'], 'a@b.test');
    expect(localRead('staffSession'), 's1');
    expect(sessionRead('staffSession'), isNull);
  });

  test('an unticked box sends no remember and keeps no token', () async {
    final h = _build((http.Request r) => _json(200, _signedIn()));

    await h.auth.verify(code: '123456');

    expect(jsonDecode(h.sent.single.body), isNot(contains('remember')));
    expect(localRead(_key), isNull);
    expect(sessionRead('staffSession'), 's1');
    expect(localRead('staffSession'), isNull);
  });

  test('a stored token signs in without asking for a code', () async {
    localWrite(_key, _stored());
    final h = _build((http.Request r) => _json(200, _signedIn()));

    await h.auth.continueSignIn();

    expect(h.auth.step, StaffAuthStep.signedIn);
    expect(h.sent.single.url.path, endsWith('/session/trusted'));
    expect(jsonDecode(h.sent.single.body), <String, Object?>{
      'deviceToken': 'tok-1',
    });
    expect(_asked(h.sent, '/session/code'), isFalse);
    expect(localRead('staffSession'), 's1');
  });

  test('a refused token is deleted and a code is requested', () async {
    localWrite(_key, _stored());
    final h = _build(
      (http.Request r) => r.url.path.endsWith('/session/trusted')
          ? _json(401, <String, Object?>{'detail': 'Enter the emailed code.'})
          : _codeSent(),
    );

    await h.auth.continueSignIn();

    expect(h.auth.step, StaffAuthStep.code);
    expect(localRead(_key), isNull);
    expect(_asked(h.sent, '/session/code'), isTrue);
  });

  test('a disabled account is sent back to sign-in', () async {
    localWrite(_key, _stored());
    final h = _build(
      (http.Request r) => _json(403, <String, Object?>{
        'detail': 'This account is turned off.',
      }),
    );

    await h.auth.continueSignIn();

    expect(h.auth.step, StaffAuthStep.signedOut);
    expect(_asked(h.sent, '/session/code'), isFalse);
  });

  test(
    'a rate limit falls back to the mailed code and keeps the token',
    () async {
      localWrite(_key, _stored());
      final h = _build(
        (http.Request r) => r.url.path.endsWith('/session/trusted')
            ? _json(429, <String, Object?>{'detail': 'Slow down.'})
            : _codeSent(),
      );

      await h.auth.continueSignIn();

      expect(h.auth.step, StaffAuthStep.code);
      expect(localRead(_key), isNotNull);
    },
  );

  test('an expired token is not sent', () async {
    localWrite(_key, _stored(lasts: const Duration(seconds: -5)));
    final h = _build((http.Request r) => _codeSent());

    await h.auth.continueSignIn();

    expect(_asked(h.sent, '/session/trusted'), isFalse);
    expect(_asked(h.sent, '/session/code'), isTrue);
  });

  test('a token stored for another email is not sent', () async {
    localWrite(_key, _stored(email: 'other@b.test'));
    final h = _build((http.Request r) => _codeSent());

    await h.auth.continueSignIn();

    expect(_asked(h.sent, '/session/trusted'), isFalse);
  });

  test('signing out and losing the session keep the token', () async {
    localWrite(_key, _stored());
    final h = _build((http.Request r) => _json(200, <String, Object?>{}));
    h.auth.step = StaffAuthStep.signedIn;

    h.auth.sessionLost();
    await Future<void>.delayed(Duration.zero);
    h.auth.step = StaffAuthStep.signedIn;
    await h.auth.signOut();

    expect(h.auth.step, StaffAuthStep.signedOut);
    expect(localRead(_key), isNotNull);
  });

  test('forgetting the device deletes the token', () async {
    localWrite(_key, _stored());
    final h = _build((http.Request r) => _codeSent());

    h.auth.forgetDevice();
    await h.auth.continueSignIn();

    expect(localRead(_key), isNull);
    expect(_asked(h.sent, '/session/trusted'), isFalse);
    expect(_asked(h.sent, '/session/code'), isTrue);
  });
}
