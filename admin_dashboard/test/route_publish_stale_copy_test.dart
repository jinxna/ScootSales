import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/route_plan.dart';
import 'package:flutter_web_app/services/route_planning_service.dart';

Map<String, dynamic> _stored({
  String status = 'approved',
  List<String> retailers = const <String>['r1', 'r2'],
}) => <String, dynamic>{
  'status': status,
  'salesmanUid': 'u1',
  'salesmanCode': 'S001',
  'weekStart': Timestamp.fromDate(DateTime(2026, 10, 5)),
  'weekEnd': Timestamp.fromDate(DateTime(2026, 10, 11)),
  'days': <Map<String, dynamic>>[
    <String, dynamic>{
      'dayId': 'd1',
      'dayLabel': 'Mon',
      'date': Timestamp.fromDate(DateTime(2026, 10, 5)),
      'stops': <Map<String, dynamic>>[
        for (int i = 0; i < retailers.length; i++)
          <String, dynamic>{
            'stopId': 's$i',
            'dayId': 'd1',
            'retailerId': retailers[i],
            'retailerName': 'Shop $i',
            'lat': 1.5 + i,
            'lng': 110.3,
            'sequence': i + 1,
          },
      ],
    },
  ],
};

void main() {
  final RoutePlan tabCopy = RoutePlan.fromMap('plan-1', _stored());

  test('newer approved contents reject the older tab copy', () {
    expect(
      RoutePlanningService.isPublishableApprovedCopy(
        tabCopy,
        _stored(retailers: const <String>['r1', 'r3']),
      ),
      isFalse,
    );
  });

  test('a plan that is no longer approved cannot be published', () {
    expect(
      RoutePlanningService.isPublishableApprovedCopy(
        tabCopy,
        _stored(status: 'draft'),
      ),
      isFalse,
    );
  });
}
