import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/services/route_planning_service.dart';

void main() {
  test('a route returned to draft removes its approve and publish dates', () {
    final Map<String, dynamic> draft = RoutePlanningService.closedPlanFields(
      'draft',
    );
    expect(draft['status'], 'draft');
    expect(draft['approvedAt'], FieldValue.delete());
    expect(draft['publishedAt'], FieldValue.delete());

    final Map<String, dynamic> archived = RoutePlanningService.closedPlanFields(
      'archived',
      replaced: true,
    );
    expect(archived.containsKey('approvedAt'), isFalse);
    expect(archived.containsKey('publishedAt'), isFalse);
    expect(archived.containsKey('replacedAt'), isTrue);
  });
}
