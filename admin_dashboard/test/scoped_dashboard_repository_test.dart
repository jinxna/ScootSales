import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/repositories/scoped_dashboard_repository.dart';

void main() {
  UserProfile user(
    String role, {
    List<String> codes = const <String>[],
    String branchId = '',
  }) {
    return UserProfile(
      docId: 'profile',
      email: 'user@example.com',
      name: 'User',
      role: role,
      employeeCode: 'E1',
      status: UserProfile.statusActive,
      branchId: branchId,
      assignedSalesmanCodes: codes,
    );
  }

  group('ScopedDashboardRepository query contract', () {
    test('supervisor scopes the requested field in Firestore-sized chunks', () {
      final List<String> assignedCodes = <String>[
        ...List<String>.generate(30, (int index) => ' S$index '),
        '',
        '   ',
        ' S30 ',
      ];

      final ScopedDashboardReadPlan plan = buildScopedDashboardReadPlan(
        collection: 'orders',
        currentUser: user(UserProfile.roleSupervisor, codes: assignedCodes),
        salesmanField: 'staffId',
        orderBy: 'submittedAt',
        limit: 1000,
        deadline: const Duration(seconds: 12),
      );

      expect(plan.queries, hasLength(2));
      expect(plan.queries.first.whereInField, 'staffId');
      expect(plan.queries.first.whereInValues, hasLength(30));
      expect(plan.queries.first.whereInValues.first, 'S0');
      expect(plan.queries.last.whereInValues, <String>['S30']);
      expect(
        plan.queries.every(
          (ScopedDashboardQueryPlan query) =>
              query.orderBy == 'submittedAt' && query.descending,
        ),
        isTrue,
        reason: 'every role must use the same recency order',
      );
    });

    test('branch manager uses exact branch equality and recency ordering', () {
      final ScopedDashboardReadPlan plan = buildScopedDashboardReadPlan(
        collection: 'visit_logs',
        currentUser: user(UserProfile.roleBranchManager, branchId: ' B2 '),
        orderBy: 'arrivalTime',
        limit: 500,
        deadline: const Duration(seconds: 12),
      );

      expect(plan.queries, hasLength(1));
      expect(plan.queries.single.equalsField, 'branchId');
      expect(plan.queries.single.equalsValue, 'B2');
      expect(plan.queries.single.orderBy, 'arrivalTime');
      expect(plan.queries.single.descending, isTrue);
      expect(plan.windowStart.isBefore(plan.windowEnd), isTrue);
    });

    test('empty and unsupported scopes produce no executable queries', () {
      final List<UserProfile> denied = <UserProfile>[
        user(UserProfile.roleSupervisor),
        user(UserProfile.roleBranchManager),
        user(UserProfile.roleSalesman),
        user('auditor'),
        user(''),
      ];

      for (final UserProfile currentUser in denied) {
        final ScopedDashboardReadPlan plan = buildScopedDashboardReadPlan(
          collection: 'orders',
          currentUser: currentUser,
          limit: 1000,
          deadline: const Duration(seconds: 12),
        );
        expect(plan.queries, isEmpty, reason: currentUser.role);
      }
    });
  });
}
