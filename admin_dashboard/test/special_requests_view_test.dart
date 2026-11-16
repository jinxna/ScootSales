import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/pages/admin/views/special_requests_view.dart';
import 'package:scoot_design/scoot_design.dart';

Map<String, dynamic> _row(
  int n, {
  String status = 'pending_supervisor',
  String item = 'Walkthrough sample item',
  String type = 'non_catalogue_item',
  String orderId = '',
}) => <String, dynamic>{
  'docId': 'sr-$n',
  'requestedItem': item,
  'retailerName': 'Choice Supermarket Tabuan Jaya',
  'salesmanCode': 'S001',
  'salesmanName': 'E2E Salesperson',
  'reason': 'Retailer asked for a pack size we do not list',
  'status': status,
  'approvalStep': 'Supervisor',
  'requestType': type,
  'createdByRole': 'salesman',
  'createdAt': Timestamp.fromDate(DateTime.utc(2026, 11, 4, 9, 23)),
  'orderId': orderId,
};

Widget _view({
  ScootLoadPhase phase = ScootLoadPhase.ready,
  List<Map<String, dynamic>> rows = const <Map<String, dynamic>>[],
  bool isAdmin = true,
  bool isBranchManager = false,
  bool canDecide = true,
  VoidCallback? onRetry,
  ValueChanged<Map<String, dynamic>>? onApprove,
  ValueChanged<Map<String, dynamic>>? onReject,
  ValueChanged<String>? onOpenOrder,
}) {
  return MaterialApp(
    theme: ScootTheme.dashboard(),
    home: Scaffold(
      body: SpecialRequestsView(
        phase: phase,
        onRetry: onRetry ?? () {},
        rows: rows,
        isBranchManager: isBranchManager,
        isAdmin: isAdmin,
        canDecide: (_) => canDecide,
        isLegacy: (_) => false,
        busyIds: const <String>{},
        onNewRequest: () {},
        onApprove: onApprove ?? (_) {},
        onReject: onReject ?? (_) {},
        onAddToCatalogue: (_) {},
        onUpgradeLegacy: (_) {},
        onOpenOrder: onOpenOrder ?? (_) {},
      ),
    ),
  );
}

Future<void> _size(WidgetTester tester) async {
  tester.view.devicePixelRatio = 1;
  tester.view.physicalSize = const Size(1440, 900);
  addTearDown(tester.view.reset);
}

void main() {
  testWidgets('branch manager sees a view-only notice and no actions', (
    WidgetTester tester,
  ) async {
    await _size(tester);
    await tester.pumpWidget(
      _view(
        rows: <Map<String, dynamic>>[_row(1)],
        isAdmin: false,
        isBranchManager: true,
        canDecide: false,
      ),
    );
    expect(find.textContaining('View only'), findsOneWidget);
    expect(find.byKey(const ValueKey<String>('sr-new')), findsNothing);
    expect(find.byKey(const ValueKey<String>('sr-approve')), findsNothing);
    expect(find.byKey(const ValueKey<String>('sr-reject')), findsNothing);
  });
}
