import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/visit_brief.dart';
import 'package:fmcg_sales/services/sales_visit_copilot_service.dart';
import 'package:shared_preferences/shared_preferences.dart';

import 'support/test_firebase.dart';

Map<String, dynamic> _brief({
  List<Map<String, dynamic>>? focusItems,
  bool materialised = true,
  List<Map<String, dynamic>>? topInsights,
  String status = 'active',
}) {
  return <String, dynamic>{
    'briefId': 'brief-1',
    'retailerId': 'R001',
    'retailerName': 'Retailer One',
    'salesmanUid': 'U001',
    'salesmanCode': 'S001',
    'status': status,
    'topInsights': topInsights ?? <Map<String, dynamic>>[],
    if (materialised) 'focusItems': focusItems ?? <Map<String, dynamic>>[],
    if (materialised &&
        (focusItems ?? <Map<String, dynamic>>[]).isEmpty) ...<String, dynamic>{
      'emptyStateHeadline': 'No priority issues today.',
      'emptyStateBody': 'Proceed with standard visit.',
    },
  };
}

void main() {
  setUp(() => signInTestUser('U001'));

  test('a blank user id writes and reads nothing', () async {
    SharedPreferences.setMockInitialValues(<String, Object>{});
    await SalesVisitCopilotService.saveCachedBriefs('   ', <VisitBrief>[
      VisitBrief.fromMap('brief-1', _brief()),
    ]);
    expect(await SalesVisitCopilotService.loadCachedBriefs('   '), isEmpty);
  });
}
