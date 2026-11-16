import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/app/permission_policy.dart';

void main() {
  test('mirror carries view tokens and the client reads view from it', () {
    final PermissionPolicy matrix = PermissionPolicy.fromDocument(
      <String, dynamic>{
        'roles': <String, dynamic>{
          'supervisor': <String>[
            'retailer_scoresheets:edit',
            'retailer_scoresheets:view',
          ],
        },
        'revision': 3,
      },
    );
    final List<String> grants = matrix.delegatedGrantsFor('supervisor');
    expect(grants, <String>[
      'retailer_scoresheets:edit',
      'retailer_scoresheets:view',
    ]);
    final PermissionPolicy withView = PermissionPolicy.forActorRole(
      'supervisor',
      <String, dynamic>{
        'grants': <String>['retailer_scoresheets:view'],
        'revision': 4,
        'shape': 2,
      },
    );
    expect(
      withView.allows(
        'supervisor',
        'retailer_scoresheets',
        PermissionAction.view,
      ),
      isTrue,
    );
    expect(
      withView.allows('supervisor', 'department_pic', PermissionAction.view),
      isFalse,
    );
    expect(
      withView.allows('supervisor', 'products', PermissionAction.view),
      isTrue,
    );
    expect(
      PermissionPolicy.forActorRole(
        'supervisor',
        null,
      ).allows('supervisor', 'department_pic', PermissionAction.view),
      isTrue,
    );
  });

  test('a mirror without view tokens keeps baseline view', () {
    final PermissionPolicy legacy = PermissionPolicy.forActorRole(
      'supervisor',
      <String, dynamic>{
        'grants': <String>['retailer_scoresheets:edit'],
        'revision': 3,
      },
    );
    expect(
      legacy.allows('supervisor', 'department_pic', PermissionAction.view),
      isTrue,
    );
  });

  test('a matrix row with a write and no view drops the write', () {
    final PermissionPolicy loaded = PermissionPolicy.fromDocument(
      <String, dynamic>{
        'roles': <String, dynamic>{
          'supervisor': <String>['retailer_scoresheets:create'],
        },
        'revision': 1,
      },
    );
    expect(
      loaded.allows(
        'supervisor',
        'retailer_scoresheets',
        PermissionAction.create,
      ),
      isFalse,
    );
    expect(loaded.delegatedGrantsFor('supervisor'), isEmpty);
  });
}
