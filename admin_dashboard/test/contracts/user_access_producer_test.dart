import 'dart:convert';
import 'dart:io';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/security/user_access_index.dart';

final Directory _fixtureDir = Directory('../contracts/user_access');
final bool _update = Platform.environment['UPDATE_CONTRACTS'] == '1';

const Set<String> _serverOwned = <String>{
  'role',
  'user_group',
  'status',
  'isActive',
  'seatClass',
  'employeeCode',
  'userId',
};

Map<String, dynamic> _sentinel(String name) => <String, dynamic>{
  r'$sentinel': name,
};

Object? _toFixtureValue(Object? value) {
  if (value is FieldValue) {
    if (value == FieldValue.serverTimestamp()) {
      return _sentinel('serverTimestamp');
    }
    if (value == FieldValue.delete()) return _sentinel('delete');
    throw StateError('Unmapped FieldValue in a contract payload.');
  }
  if (value is Map) {
    return <String, dynamic>{
      for (final MapEntry<dynamic, dynamic> e in value.entries)
        e.key as String: _toFixtureValue(e.value),
    };
  }
  if (value is Iterable) {
    return value.map<Object?>(_toFixtureValue).toList();
  }
  return value;
}

Map<String, dynamic> _produce(Map<String, dynamic> inputs) {
  final Object? codes = inputs['assignedSalesmanCodes'];
  return UserAccessIndex.build(
    uid: inputs['uid'] as String,
    userDocId: inputs['userDocId'] as String,
    email: inputs['email'] as String,
    roleRaw: inputs['roleRaw'] as String,
    branchId: inputs['branchId'] as String,
    supervisorId: inputs['supervisorId'] as String,
    supervisorUid: inputs['supervisorUid'] as String,
    assignedSalesmanCodes: codes == null
        ? null
        : (codes as List<dynamic>).cast<String>(),
  );
}

void main() {
  final List<File> files =
      _fixtureDir
          .listSync()
          .whereType<File>()
          .where((File f) => f.path.endsWith('.json'))
          .toList()
        ..sort((File a, File b) => a.path.compareTo(b.path));

  test('contract fixtures are present', () {
    expect(files, isNotEmpty);
  });

  for (final File file in files) {
    final Map<String, dynamic> fixture =
        jsonDecode(file.readAsStringSync()) as Map<String, dynamic>;
    final Map<String, dynamic>? producer =
        fixture['producer'] as Map<String, dynamic>?;
    if (producer == null) continue;
    final String name = file.uri.pathSegments.last;
    final Object? knownIssue = fixture['knownIssue'];

    test(
      'UserAccessIndex.build matches $name',
      () {
        final Map<String, dynamic> produced =
            _toFixtureValue(
                  _produce(producer['inputs'] as Map<String, dynamic>),
                )!
                as Map<String, dynamic>;
        if (_update) {
          fixture['access'] = <String, dynamic>{
            ...(fixture['access'] as Map<String, dynamic>),
            ...produced,
          };
          file.writeAsStringSync(
            '${const JsonEncoder.withIndent('  ').convert(fixture)}\n',
          );
          return;
        }
        expect(
          produced,
          equals(<String, dynamic>{
            for (final MapEntry<String, dynamic> entry
                in (fixture['access'] as Map<String, dynamic>).entries)
              if (!_serverOwned.contains(entry.key)) entry.key: entry.value,
          }),
          reason:
              'The dashboard write shape drifted from contracts/user_access/'
              '$name. If intentional, run UPDATE_CONTRACTS=1 and review every '
              'side that asserts the fixture.',
        );
      },
      skip: knownIssue == null ? false : '$knownIssue',
    );
  }
}
