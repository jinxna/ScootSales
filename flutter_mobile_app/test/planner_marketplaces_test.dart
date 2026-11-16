import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/planner_marketplaces.dart';

void main() {
  group('retailerAssignmentQueries', () {
    test('only ever queries for this salesman\'s own identifiers', () {
      final List<RetailerAssignmentQuery> queries = retailerAssignmentQueries(
        staffId: 's0002',
        uid: 'uid-1',
      );

      expect(queries, isNotEmpty);
      expect(
        queries.map((RetailerAssignmentQuery q) => q.value).toSet().difference(
          <String>{'s0002', 'uid-1'},
        ),
        isEmpty,
        reason: 'a lookup must never widen past the signed-in salesman',
      );
    });

    test('every query is one the branch retailer rule accepts', () {
      final List<RetailerAssignmentQuery> withBranch =
          retailerAssignmentQueries(
            staffId: 's0002',
            uid: 'uid-1',
            branchId: 'B1',
          );
      for (final RetailerAssignmentQuery q in withBranch) {
        expect(
          q.field == 'assignedSalesmanId' || q.branchId == 'B1',
          isTrue,
          reason: '${q.field} must be scoped to the branch',
        );
      }
      expect(
        withBranch.where((RetailerAssignmentQuery q) => q.isList),
        isNotEmpty,
      );

      final List<RetailerAssignmentQuery> noBranch = retailerAssignmentQueries(
        staffId: 's0002',
        uid: 'uid-1',
      );
      expect(
        noBranch.map((RetailerAssignmentQuery q) => q.field).toSet(),
        <String>{'assignedSalesmanId'},
      );
    });
  });
}
