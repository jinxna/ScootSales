import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/utils/my_team_roster.dart';
import 'package:flutter_web_app/widgets/team_hierarchy_tree.dart';

void main() {
  testWidgets(
    'a code with no profile offers Remove from team for its supervisor',
    (WidgetTester tester) async {
      final TeamHierarchy hierarchy = buildTeamHierarchy(
        branchId: 'BR1',
        userRows: <Map<String, dynamic>>[
          <String, dynamic>{
            'docId': 'SUP1',
            'uid': 'sup-uid',
            'name': 'Siti',
            'role': 'supervisor',
            'branchId': 'BR1',
            'employeeCode': 'SUP1',
            'assignedSalesmanCodes': <String>['S001', 'SYN001'],
          },
          <String, dynamic>{
            'docId': 'S001',
            'uid': 's001-uid',
            'name': 'Ali',
            'role': 'salesman',
            'branchId': 'BR1',
            'employeeCode': 'S001',
          },
        ],
      );
      final List<String> removed = <String>[];
      await tester.pumpWidget(
        MaterialApp(
          theme: DsoTheme.light,
          home: Scaffold(
            body: TeamHierarchyTree(
              managerName: '',
              title: 'Branch BR1',
              hierarchy: hierarchy,
              onMove: (_, _, _) {},
              onRemoveOrphan:
                  (
                    TeamTreeSalesman orphan,
                    TeamTreeSupervisor supervisor,
                  ) => removed.add(
                    '${orphan.code} from ${supervisor.docId} ${supervisor.uid}',
                  ),
            ),
          ),
        ),
      );

      expect(find.text('SYN001 (no visible profile)'), findsOneWidget);
      expect(find.text('Remove from team'), findsOneWidget);
      await tester.tap(find.text('Remove from team'));
      await tester.pump();

      expect(removed, <String>['SYN001 from SUP1 sup-uid']);
    },
  );
}
