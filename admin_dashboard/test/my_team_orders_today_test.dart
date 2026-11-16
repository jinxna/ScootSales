import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/my_team_roster.dart';

void main() {
  test(
    'My Team does not count a rejected order today or as the last order',
    () {
      final DateTime now = DateTime.utc(2026, 11, 10, 6);
      final TeamTodayStats stats = aggregateTodayStats(
        member: const TeamMember(code: 'S001', profileFound: true),
        orders: <Map<String, dynamic>>[
          <String, dynamic>{
            'salesmanCode': 'S001',
            'status': 'approved',
            'submittedAt': DateTime.utc(2026, 11, 10, 1),
          },
          <String, dynamic>{
            'salesmanCode': 'S001',
            'status': 'rejected',
            'submittedAt': DateTime.utc(2026, 11, 10, 5),
          },
        ],
        visits: const <Map<String, dynamic>>[],
        now: now,
      );

      expect(stats.ordersToday, 1);
      expect(stats.lastOrderAt, DateTime.utc(2026, 11, 10, 1));
    },
  );
}
