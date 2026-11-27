import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/app/build_flags.dart';
import 'package:flutter_web_app/app/role_guard.dart';
import 'package:flutter_web_app/models/user_profile.dart';

void main() {
  const UserProfile branchManager = UserProfile(
    docId: 'bm1',
    email: 'bm@example.com',
    name: 'Branch Manager',
    role: UserProfile.roleBranchManager,
    employeeCode: 'BM1',
    status: UserProfile.statusActive,
    branchId: 'BR01',
  );
  const UserProfile supervisor = UserProfile(
    docId: 'sup1',
    email: 'sup@example.com',
    name: 'Supervisor',
    role: UserProfile.roleSupervisor,
    employeeCode: 'SUP1',
    status: UserProfile.statusActive,
    branchId: 'BR01',
    assignedSalesmanCodes: <String>['S001'],
  );
  const UserProfile admin = UserProfile(
    docId: 'admin1',
    email: 'admin@example.com',
    name: 'Admin',
    role: UserProfile.roleAdmin,
    employeeCode: 'A001',
    status: UserProfile.statusActive,
  );
  const UserProfile developer = UserProfile(
    docId: 'developer1',
    email: 'developer@example.com',
    name: 'Developer',
    role: UserProfile.roleDeveloper,
    employeeCode: 'D001',
    status: UserProfile.statusActive,
  );

  test('branch manager keeps scoped route planner access', () {
    expect(RoleGuard.canAccess(branchManager, 'route_planner'), isTrue);
    expect(RoleGuard.canAccess(branchManager, 'trust_impact'), isFalse);
    expect(RoleGuard.canAccess(branchManager, 'special_requests'), isTrue);
  });

  test('supervisor opens its own console pages and no admin page', () {
    expect(RoleGuard.supervisorKeys, contains('special_requests'));
    expect(RoleGuard.canAccess(supervisor, 'special_requests'), isTrue);
    expect(RoleGuard.canAccess(supervisor, 'team_orders'), isTrue);
    expect(RoleGuard.canAccess(supervisor, 'all_orders'), isTrue);
    expect(RoleGuard.canAccess(supervisor, 'permissions'), isFalse);
    expect(RoleGuard.canAccess(supervisor, 'purchase_order'), isFalse);
  });

  test('testing visibility and URL fallback cover every role', () {
    const List<String> hiddenForTesting = <String>[
      'scenario_workbench',
      'route_scenario_planning',
      'route_scenarios',
      'system_health',
      'trust_impact',
    ];
    const List<UserProfile> roles = <UserProfile>[
      admin,
      developer,
      supervisor,
      branchManager,
    ];
    const Map<String, bool> normalAccessByAdminRole = <String, bool>{
      'system_health': false,
      'trust_impact': true,
    };

    for (final String key in hiddenForTesting) {
      for (final UserProfile user in roles) {
        if (kUserTestingMode) {
          expect(
            RoleGuard.isPageHiddenInUserTesting(key),
            isTrue,
            reason: '${user.role}: $key',
          );
          expect(
            RoleGuard.safePageKey(key),
            RoleGuard.landingKey,
            reason: '${user.role}: $key deep link fallback',
          );
          expect(
            RoleGuard.canAccess(user, key),
            isFalse,
            reason: '${user.role}: $key must be denied in testing mode',
          );
        } else {
          expect(
            RoleGuard.isPageHiddenInUserTesting(key),
            isFalse,
            reason: 'normal mode preserves $key',
          );
          expect(RoleGuard.safePageKey(key), key);
          final bool isScenarioAlias = !normalAccessByAdminRole.containsKey(
            key,
          );
          final bool expectedAccess = isScenarioAlias
              ? false
              : user.isDeveloper
              ? true
              : user.isAdmin
              ? normalAccessByAdminRole[key]!
              : false;
          expect(
            RoleGuard.canAccess(user, key),
            expectedAccess,
            reason: '${user.role}: $key normal-mode access remains unchanged',
          );
        }
      }
    }

    expect(
      RoleGuard.canAccess(developer, 'system_health'),
      equals(!kUserTestingMode),
      reason: 'System Health stays developer-only and is hidden in testing',
    );
    expect(RoleGuard.canAccess(admin, 'system_health'), isFalse);
  });

  group('one table drives navigation and access', () {
    test('a key that is not a page is never accessible', () {
      for (final UserProfile user in <UserProfile>[
        admin,
        developer,
        supervisor,
        branchManager,
      ]) {
        expect(RoleGuard.canAccess(user, 'not_a_page'), isFalse);
        expect(RoleGuard.canAccess(user, ''), isFalse);
      }
    });

    test('the supervisor reads admin page keys through its aliases', () {
      expect(RoleGuard.canonicalKey(supervisor, 'all_orders'), 'team_orders');
      expect(RoleGuard.canonicalKey(supervisor, 'visit_logs'), 'team_visits');
      expect(RoleGuard.canonicalKey(supervisor, 'reports'), 'team_reports');
      expect(RoleGuard.canonicalKey(admin, 'all_orders'), 'all_orders');
    });
  });
}
