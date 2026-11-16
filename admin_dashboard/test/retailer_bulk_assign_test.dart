import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_web_app/theme/dso_theme.dart';
import 'package:flutter_web_app/utils/retailer_bulk_assign.dart';
import 'package:flutter_web_app/utils/retailer_form_utils.dart';
import 'package:flutter_web_app/widgets/retailer_bulk_assign_list.dart';

class _FakeWriter implements RetailerAssignmentWriter {
  _FakeWriter();

  final List<(List<String>, String)> calls = <(List<String>, String)>[];

  @override
  Future<Map<String, Object>> setAssignment(
    List<String> ids,
    String salesmanId, {
    void Function(int done)? onProgress,
  }) async {
    calls.add((ids, salesmanId));
    onProgress?.call(ids.length);
    return <String, Object>{};
  }
}

bool _retired(Map<String, dynamic> r) => r['status'] == 'retired';

Map<String, dynamic> _retailer(
  String id, {
  String assigned = '',
  String status = 'active',
}) => <String, dynamic>{
  'docId': id,
  'retailerName': 'Retailer $id',
  'assignedSalesmanId': assigned,
  'status': status,
};

final List<RetailerSalesmanOption> _options = buildRetailerSalesmanOptions(
  <Map<String, dynamic>>[
    <String, dynamic>{'uid': 'u1', 'name': 'Aina', 'employeeCode': 'S001'},
    <String, dynamic>{'uid': 'u2', 'name': 'Ben', 'employeeCode': 'S002'},
  ],
);

void main() {
  test('uncertain chunk rejection does not retry rows', () async {
    int rowCalls = 0;
    final FirestoreRetailerAssignmentWriter writer =
        FirestoreRetailerAssignmentWriter(
          commitChunk: (List<String> ids, String salesmanId) async {
            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'unavailable',
            );
          },
          updateDocument: (String id, String salesmanId) async => rowCalls++,
        );

    final Map<String, Object> failed = await writer.setAssignment(<String>[
      'a',
      'b',
    ], 'S001');

    expect(rowCalls, 0);
    expect(failed.keys, <String>['a', 'b']);
    expect(failed.values, everyElement(isA<StateError>()));
    expect(
      (failed.values.first as StateError).message,
      contains('could not be confirmed. Refresh and retry'),
    );
  });

  test('uncertain per-document outcomes remain unconfirmed', () async {
    final FirestoreRetailerAssignmentWriter writer =
        FirestoreRetailerAssignmentWriter(
          commitChunk: (List<String> ids, String salesmanId) async {
            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'permission-denied',
            );
          },
          updateDocument: (String id, String salesmanId) async {
            throw FirebaseException(
              plugin: 'cloud_firestore',
              code: 'deadline-exceeded',
            );
          },
        );

    final Map<String, Object> failed = await writer.setAssignment(<String>[
      'a',
    ], 'S001');

    expect(failed.keys, <String>['a']);
    expect(
      (failed.values.single as StateError).message,
      contains('could not be confirmed. Refresh and retry'),
    );
  });

  group('RetailerBulkAssignList', () {
    Future<void> pump(
      WidgetTester tester,
      _FakeWriter writer, {
      bool canEdit = true,
    }) async {
      await tester.pumpWidget(
        MaterialApp(
          theme: DsoTheme.light,
          home: Scaffold(
            body: RetailerBulkAssignList(
              retailers: <Map<String, dynamic>>[
                _retailer('a'),
                _retailer('b', assigned: 'S002'),
                _retailer('c'),
              ],
              options: _options,
              writer: writer,
              canEdit: canEdit,
              isRetired: _retired,
              cardBuilder: (BuildContext c, Map<String, dynamic> r) =>
                  Text('${r['retailerName']}'),
            ),
          ),
        ),
      );
    }

    testWidgets('read-only roles see no checkboxes', (
      WidgetTester tester,
    ) async {
      await pump(tester, _FakeWriter(), canEdit: false);
      expect(find.byType(Checkbox), findsNothing);
      expect(find.text('Retailer a'), findsOneWidget);
    });
  });
}
