import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/security/canonical_profile_identity.dart';
import 'package:flutter_web_app/security/profile_gate.dart';
import 'package:flutter_web_app/security/user_management_rules.dart';

void main() {
  group('supervisor cap', () {
    test('blocks a 6th salesman with the agreed message', () {
      final String? message = UserManagementRules.supervisorCapError(
        supervisorName: 'Aina',
        currentCodes: <String>{'S1', 'S2', 'S3', 'S4', 'S5'},
        salesmanCode: 'S6',
      );
      expect(
        message,
        'Supervisor Aina already has 5 salesmen. Assign this salesman to '
        'another supervisor.',
      );
    });
  });

  group('supervisor branch', () {
    test('refuses a supervisor from another branch with the server text', () {
      expect(
        UserManagementRules.supervisorBranchError(
          supervisorBranchId: 'KCH',
          branchId: 'MIRI',
        ),
        'That supervisor is in another branch. Choose a supervisor in the '
        'same branch.',
      );
      expect(
        UserManagementRules.supervisorBranchError(
          supervisorBranchId: 'KCH',
          branchId: ' kch ',
        ),
        isNull,
      );
      expect(
        UserManagementRules.supervisorBranchError(
          supervisorBranchId: 'KCH',
          branchId: 'KCH',
        ),
        isNull,
      );
    });
  });

  group('supervisor with a team', () {
    bool mustMoveFirst({
      String oldRole = 'supervisor',
      String oldCode = 'SV1',
      String newRole = 'supervisor',
      String oldBranch = 'KCH',
      String newBranch = 'KCH',
    }) => UserManagementRules.supervisorTeamMustMoveFirst(
      oldRole: oldRole,
      oldEmployeeCode: oldCode,
      newRole: newRole,
      oldBranchId: oldBranch,
      newBranchId: newBranch,
    );

    test('the team must move first when the role or the branch changes', () {
      expect(mustMoveFirst(newBranch: 'MIRI'), isTrue);
      expect(mustMoveFirst(newRole: 'admin'), isTrue);
      expect(mustMoveFirst(), isFalse);
      expect(mustMoveFirst(newBranch: ' kch '), isFalse);
      expect(mustMoveFirst(oldCode: ' ', newBranch: 'MIRI'), isFalse);
      expect(
        mustMoveFirst(
          oldRole: 'salesman',
          newRole: 'salesman',
          newBranch: 'MIRI',
        ),
        isFalse,
      );
    });
  });

  group('profile gate', () {
    test('a suspended v2 access record resolves to an inactive profile', () {
      final Map<String, dynamic> access = <String, dynamic>{
        'accessVersion': 2,
        'uid': 'u1',
        'role': 'supervisor',
        'status': 'suspended',
        'branchId': 'KCH',
        'employeeCode': 'SV1',
      };
      expect(
        CanonicalProfileIdentity.strictActiveV2Identity(
          accessData: access,
          authUid: 'u1',
        ),
        isNull,
        reason: 'authorization callers stay fail-closed',
      );
      final Map<String, dynamic>? identity =
          CanonicalProfileIdentity.strictV2Identity(
            accessData: access,
            authUid: 'u1',
            allowSuspended: true,
          );
      expect(identity, isNotNull);
      final UserProfile profile = UserProfile.fromFirestore('SV1', identity!);
      expect(profile.isActive, isFalse);
      expect(
        decideProfileGate(
          waiting: false,
          failed: false,
          role: profile.role,
          active: profile.isActive,
        ),
        ProfileGateState.suspended,
      );
    });
  });
}
