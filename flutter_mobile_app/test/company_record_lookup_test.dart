import 'dart:convert';
import 'dart:async';

import 'package:cryptography/cryptography.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/services/company_project.dart';
import 'package:fmcg_sales/services/company_runtime.dart';
import 'package:http/http.dart' as http;
import 'package:http/testing.dart';
import 'package:shared_preferences/shared_preferences.dart';

final DateTime moment = DateTime.utc(2026, 10, 29, 8);
final Ed25519 algorithm = Ed25519();
late SimpleKeyPair pair;
late String keys;
String stamp(DateTime value) =>
    value.toIso8601String().replaceFirst('.000Z', 'Z');
String b64(List<int> value) => base64Url.encode(value).replaceAll('=', '');

Future<String> record({
  int version = 5,
  Map<String, Object?> changes = const <String, Object?>{},
}) async {
  final String payload = jsonEncode(<String, Object?>{
    'kind': 'scoot.directory.record.v1',
    'version': version,
    'issuedAt': stamp(moment.subtract(const Duration(hours: 1))),
    'expiresAt': stamp(moment.add(const Duration(days: 1))),
    'tenantId': 't_acme001',
    'workspace': 'acme',
    'companyCode': 'acme',
    'legalName': 'Acme Foods',
    'status': 'active',
    'planRef': 'STARTER',
    'releaseRing': 'general',
    'rulesVersion': 'r1',
    'location': <String, Object?>{
      'projectId': 'acme-fake-1',
      'databaseId': '(default)',
      'authTenantId': null,
    },
    'clientConfig': <String, Object?>{
      'apiKey': <String, String>{'android': 'AIza${'A' * 35}'},
      'appId': <String, String>{
        'android': '1:222222222222:android:bbbbbbbbbbbbbbbb',
      },
      'messagingSenderId': '222222222222',
      'storageBucket': 'acme-fake-1.firebasestorage.app',
    },
    ...changes,
  });
  final Signature signature = await algorithm.sign(
    utf8.encode(payload),
    keyPair: pair,
  );
  return jsonEncode(<String, Object?>{
    'alg': 'Ed25519',
    'keyId': 'lookup-test',
    'payload': payload,
    'signature': b64(signature.bytes),
  });
}

CompanyProject project(http.Client client, {DateTime? now}) => CompanyProject(
  client: client,
  lookupUrl: 'https://directory.example.test/v1/companies',
  registryKeys: keys,
  platform: 'android',
  clock: () => now ?? moment,
  defaultOptions: const FirebaseOptions(
    apiKey: 'default-fake',
    appId: 'default-fake',
    messagingSenderId: '111111111111',
    projectId: 'default-fake',
  ),
);

http.Client serve(String text) =>
    MockClient((_) async => http.Response(text, 200));
final http.Client offline = MockClient(
  (_) async => throw http.ClientException('Local offline fixture'),
);
final Matcher unavailable = throwsA(
  isA<CompanyException>().having(
    (e) => e.failure,
    'failure',
    CompanyFailure.unreachable,
  ),
);

void main() {
  setUpAll(() async {
    pair = await algorithm.newKeyPair();
    keys = 'lookup-test=${b64((await pair.extractPublicKey()).bytes)}';
  });
  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('a different signed company cannot satisfy the selected code', () async {
    await expectLater(
      project(
        serve(await record(changes: <String, Object?>{'companyCode': 'other'})),
      ).resolveCompany('acme'),
      unavailable,
    );
  });

  test('an older served record cannot replace the last valid record', () async {
    await project(serve(await record())).save('acme');
    final String older = await record(
      version: 4,
      changes: <String, Object?>{'legalName': 'Old Acme'},
    );
    final ActiveCompany current = await project(
      serve(older),
    ).resolveCompany('acme');
    expect(current.name, 'Acme Foods');
  });

  test('an unknown company does not inherit another cached company', () async {
    await project(serve(await record())).save('acme');
    final CompanyProject service = project(
      MockClient((_) async => http.Response('{}', 404)),
    );
    await expectLater(
      service.resolveCompany('other'),
      throwsA(
        isA<CompanyException>().having(
          (e) => e.failure,
          'failure',
          CompanyFailure.unknownCode,
        ),
      ),
    );
    expect((await service.active()).code, 'acme');
  });

  test(
    'a late older response cannot destroy the newer offline company cache',
    () async {
      final Completer<http.Response> slow = Completer<http.Response>();
      final CompanyProject olderService = project(
        MockClient((_) => slow.future),
      );
      final Future<ActiveCompany> older = olderService.resolveCompany('acme');
      await Future<void>.delayed(const Duration(milliseconds: 10));
      final String newer = await record(
        version: 6,
        changes: <String, Object?>{'legalName': 'New Acme'},
      );
      await project(serve(newer)).save('acme');
      slow.complete(http.Response(await record(version: 5), 200));
      final ActiveCompany resolved = await older;
      expect(resolved.name, 'New Acme');
      expect((await project(offline).active()).name, 'New Acme');
    },
  );

  test('runtime identity includes workspace and Auth tenant', () {
    const FirebaseOptions options = FirebaseOptions(
      apiKey: 'same-key',
      appId: 'same-app',
      messagingSenderId: '123456789012',
      projectId: 'same-project',
    );
    const ActiveCompany initialized = ActiveCompany(
      code: 'acme',
      name: 'Acme',
      options: options,
      tenantId: 't_acme001',
      workspace: 'acme',
      authTenantId: 'auth-acme',
    );
    const ActiveCompany renamed = ActiveCompany(
      code: 'acme',
      name: 'Acme Foods Sdn Bhd',
      options: options,
      tenantId: 't_acme001',
      workspace: 'acme',
      authTenantId: 'auth-acme',
    );
    const ActiveCompany otherAuthTenant = ActiveCompany(
      code: 'bravo',
      name: 'Bravo',
      options: options,
      tenantId: 't_bravo001',
      workspace: 'bravo',
      authTenantId: 'auth-bravo',
    );

    expect(CompanyRuntime.sameIdentity(initialized, renamed), isTrue);
    expect(CompanyRuntime.sameIdentity(initialized, otherAuthTenant), isFalse);
  });
}
