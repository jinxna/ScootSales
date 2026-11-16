import 'dart:convert';
import 'dart:io';
import 'dart:typed_data';

import 'package:cryptography/cryptography.dart';
import 'package:scoot_directory_client/scoot_directory_client.dart';
import 'package:test/test.dart';

const String _kind = 'scoot.directory.record.v1';
const String _pythonKeyId = 'test-1';

late Map<String, Uint8List> _keys;
late String _pythonKeyText;
late String _v5;
late SimpleKeyPair _dartPair;
final Ed25519 _ed25519 = Ed25519();

String _b64(List<int> bytes) => base64Url.encode(bytes).replaceAll('=', '');

String _timestamp(DateTime moment) =>
    moment.toUtc().toIso8601String().replaceFirst(RegExp(r'\.\d+Z$'), 'Z');

Future<Map<String, Object?>> _dartEnvelope({
  String kind = _kind,
  Object version = 1,
  String? issuedAt,
  String? expiresAt,
  String keyId = 'dart-1',
  String alg = 'Ed25519',
}) async {
  final DateTime now = DateTime.now();
  final String payload = jsonEncode(<String, Object?>{
    'kind': kind,
    'version': version,
    'issuedAt': issuedAt ?? _timestamp(now.subtract(const Duration(hours: 1))),
    'expiresAt': expiresAt ?? _timestamp(now.add(const Duration(days: 30))),
    'tenantId': 't_acmefoods',
  });
  final Signature signature = await _ed25519.sign(
    utf8.encode(payload),
    keyPair: _dartPair,
  );
  return <String, Object?>{
    'alg': alg,
    'keyId': keyId,
    'payload': payload,
    'signature': _b64(signature.bytes),
  };
}

Map<String, Object?> _bend(
  Map<String, Object?> envelope,
  void Function(Map<String, Object?>) change,
) {
  final Map<String, Object?> copy = Map<String, Object?>.from(envelope);
  change(copy);
  return copy;
}

Map<String, Object?> _python() => (jsonDecode(_v5) as Map).cast<String, Object?>();

Future<void> _expectRejected(
  Object? envelope, {
  Map<String, Uint8List>? keys,
  int minVersion = 0,
  DateTime? now,
}) async {
  await expectLater(
    SignedEnvelope.verify(
      envelope,
      keys: keys ?? _keys,
      kind: _kind,
      minVersion: minVersion,
      now: now,
    ),
    throwsA(isA<SignedEnvelopeException>()),
  );
}

Future<String> _pythonTool(List<String> args) async {
  final ProcessResult result = await Process.run('python', <String>[
    '-m',
    'platform_service.devtool',
    ...args,
  ], workingDirectory: Directory.current.parent.parent.path);
  if (result.exitCode != 0) {
    fail('platform_service.devtool ${args.first} failed: ${result.stderr}');
  }
  return (result.stdout as String).trim();
}

const Map<String, Object?> _record = <String, Object?>{
  'tenantId': 't_acmefoods',
  'workspace': 'acme',
  'legalName': 'Acme Foods Sdn Bhd',
  'companyCode': 'acme',
  'location': <String, Object?>{
    'projectId': 'acme-fake-1',
    'databaseId': '(default)',
    'authTenantId': null,
  },
  'locationKind': 'byo',
  'clientConfig': <String, Object?>{
    'apiKey': <String, Object?>{
      'web': 'AIzaAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAAA',
    },
    'appId': <String, Object?>{'web': '1:222222222222:web:bbbbbbbbbbbbbbbb'},
    'messagingSenderId': '222222222222',
  },
  'status': 'live',
  'planRef': 'standard',
  'releaseRing': 'general',
  'rulesVersion': 'r1',
};

void main() {
  late Directory temp;

  setUpAll(() async {
    temp = Directory.systemTemp.createTempSync('directory_client_test');
    final String keyFile = '${temp.path}/k.json';
    final String recordFile = '${temp.path}/r.json';
    File(recordFile).writeAsStringSync(jsonEncode(_record));
    _pythonKeyText = await _pythonTool(<String>[
      'keygen',
      '--key-id',
      _pythonKeyId,
      '--out',
      keyFile,
    ]);
    _v5 = await _pythonTool(<String>[
      'sign-record',
      '--key-file',
      keyFile,
      '--version',
      '5',
      '--record-json',
      recordFile,
    ]);
    _dartPair = await _ed25519.newKeyPair();
    final SimplePublicKey dartPublic = await _dartPair.extractPublicKey();
    _keys = SignedEnvelope.parseKeys(
      '$_pythonKeyText,dart-1=${_b64(dartPublic.bytes)}',
    );
  });

  tearDownAll(() => temp.deleteSync(recursive: true));

  group('signed envelope', () {
    test('accepts an envelope made by the Python signer', () async {
      final Map<String, Object?> payload = await SignedEnvelope.verify(
        _python(),
        keys: _keys,
        kind: _kind,
      );
      expect(payload['tenantId'], 't_acmefoods');
      expect(payload['version'], 5);
    });

    test('rejects a tampered payload', () async {
      await _expectRejected(
        _bend(_python(), (Map<String, Object?> m) {
          m['payload'] = (m['payload']! as String).replaceFirst(
            'acme-fake-1',
            'evil-fake-1',
          );
        }),
      );
    });

    test('rejects a signature from a key it does not hold', () async {
      await _expectRejected(await _dartEnvelope(keyId: _pythonKeyId));
      await _expectRejected(
        _python(),
        keys: SignedEnvelope.parseKeys(
          'other-1=${_pythonKeyText.split('=')[1]}',
        ),
      );
    });

    test('rejects an unknown keyId, wrong alg and a bad envelope shape', () async {
      final List<void Function(Map<String, Object?>)> bends =
          <void Function(Map<String, Object?>)>[
            (Map<String, Object?> m) => m['keyId'] = 'nobody-1',
            (Map<String, Object?> m) => m['alg'] = 'ed25519',
            (Map<String, Object?> m) => m['note'] = 'x',
            (Map<String, Object?> m) => m.remove('alg'),
            (Map<String, Object?> m) => m['payload'] = <String, Object?>{},
          ];
      for (final void Function(Map<String, Object?>) bend in bends) {
        await _expectRejected(_bend(_python(), bend));
      }
      await _expectRejected(<Object?>[_python()]);
      await _expectRejected(null);
      await _expectRejected(await _dartEnvelope(alg: 'RS256'));
    });

    test('rejects a signature with bad length, padding or characters', () async {
      final String signature = _python()['signature']! as String;
      final List<String> bad = <String>[
        signature.substring(0, signature.length - 4),
        '${signature}AAAA',
        signature.substring(0, signature.length - 1),
        '$signature==',
        signature.replaceFirst(RegExp(r'[A-Za-z0-9]'), '+'),
        '$signature\n',
        '',
      ];
      for (final String value in bad) {
        await _expectRejected(
          _bend(_python(), (Map<String, Object?> m) => m['signature'] = value),
        );
      }
    });

    test('rejects a signed payload of the wrong kind, version or times', () async {
      final DateTime now = DateTime.now();
      final List<Map<String, Object?>> served = <Map<String, Object?>>[
        await _dartEnvelope(kind: 'scoot.registry.v1'),
        await _dartEnvelope(version: 0),
        await _dartEnvelope(version: '1'),
        await _dartEnvelope(version: true),
        await _dartEnvelope(issuedAt: '2026-02-30T00:00:00Z'),
        await _dartEnvelope(issuedAt: '2026-01-01T00:00:00.000Z'),
        await _dartEnvelope(expiresAt: '2099-01-01'),
        await _dartEnvelope(
          issuedAt: _timestamp(now),
          expiresAt: _timestamp(now),
        ),
        await _dartEnvelope(
          issuedAt: _timestamp(now.add(const Duration(hours: 1))),
        ),
      ];
      for (final Map<String, Object?> envelope in served) {
        await _expectRejected(envelope);
      }
    });

    test('rejects an expired payload unless expiry is allowed', () async {
      final DateTime later = DateTime.now().add(const Duration(days: 60));
      await _expectRejected(_python(), now: later);
      final Map<String, Object?> payload = await SignedEnvelope.verify(
        _python(),
        keys: _keys,
        kind: _kind,
        now: later,
        allowExpired: true,
      );
      expect(payload['version'], 5);
    });

    test('tolerates a small clock skew only', () async {
      final Map<String, Object?> skewed = await _dartEnvelope(
        issuedAt: _timestamp(DateTime.now().add(const Duration(minutes: 3))),
      );
      expect(
        (await SignedEnvelope.verify(skewed, keys: _keys, kind: _kind))['kind'],
        _kind,
      );
    });

    test('never accepts a version below the last one seen', () async {
      await _expectRejected(_python(), minVersion: 6);
      final Map<String, Object?> payload = await SignedEnvelope.verify(
        _python(),
        keys: _keys,
        kind: _kind,
        minVersion: 5,
      );
      expect(payload['version'], 5);
    });

    test('rejects an unsigned record', () async {
      await _expectRejected(<String, Object?>{
        'tenantId': 't_acmefoods',
        'kind': _kind,
        'version': 1,
      });
    });

    test('invalid key lists are refused', () {
      for (final String keys in <String>[
        'test-1',
        'test-1=not*base64',
        'test-1=AAAA',
        '$_pythonKeyText,$_pythonKeyText',
      ]) {
        expect(
          () => SignedEnvelope.parseKeys(keys),
          throwsA(isA<SignedEnvelopeException>()),
          reason: 'keys: "$keys"',
        );
      }
      expect(SignedEnvelope.parseKeys('  '), isEmpty);
    });
  });

  group('checked service address', () {
    test('accepts https and loopback http only', () {
      expect(checkedServiceUri('https://api.example.test/base'), isNotNull);
      expect(checkedServiceUri('http://127.0.0.1:8100'), isNotNull);
      for (final String value in <String>[
        'http://api.example.test',
        'https://user:pw@api.example.test',
        'https://api.example.test?x=1',
        'https://api.example.test/#frag',
        ' https://api.example.test',
        'ftp://api.example.test',
        'https://api.example.test:99999',
      ]) {
        expect(checkedServiceUri(value), isNull, reason: value);
      }
    });
  });
}
