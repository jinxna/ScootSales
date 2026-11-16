import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';

void main() {
  group('buildUserIndex collision handling', () {
    test('a code shared by two users resolves to neither (raw code shown)', () {
      final Map<String, Map<String, dynamic>> users = buildUserIndex(
        <Map<String, dynamic>>[
          <String, dynamic>{'uid': 'u1', 'staffId': 'S100', 'name': 'Alice'},
          <String, dynamic>{'uid': 'u2', 'employeeCode': 'S100', 'name': 'Bob'},
        ],
      );
      expect(
        resolveSalesmanName(<String, dynamic>{
          'staffId': 'S100',
        }, usersByKey: users),
        'S100',
      );
      expect(
        resolveSalesmanName(<String, dynamic>{
          'salesmanUid': 'u1',
        }, usersByKey: users),
        'Alice',
      );
    });
  });
}
