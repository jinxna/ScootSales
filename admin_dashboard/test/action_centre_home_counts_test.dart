import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/action_centre_item.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/services/action_centre_service.dart';

const UserProfile _admin = UserProfile(
  docId: 'a',
  email: 'a@x.test',
  name: 'Admin',
  role: 'admin',
  employeeCode: 'A1',
  status: UserProfile.statusActive,
  uid: 'uid-a',
  branchId: '',
  assignedSalesmanCodes: <String>[],
);

class _FakeCms extends CmsRepository {
  _FakeCms(
    this.orders, {
    this.visits = const <Map<String, dynamic>>[],
    this.retailers = const <Map<String, dynamic>>[],
  });

  final List<Map<String, dynamic>> orders;
  final List<Map<String, dynamic>> visits;
  final List<Map<String, dynamic>> retailers;

  @override
  Future<List<Map<String, dynamic>>> getCollectionOnce(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    Duration? timeout,
    bool raw = false,
    bool coverageProbe = true,
  }) async {
    return switch (collectionName) {
      'orders' => orders,
      'visit_logs' => visits,
      'retailers' => retailers,
      _ => <Map<String, dynamic>>[],
    };
  }

  @override
  Future<Map<String, Map<String, dynamic>>> getActionCentreUserStatuses(
    String uid, {
    bool throwOnError = false,
  }) async {
    return <String, Map<String, dynamic>>{};
  }

  @override
  Stream<List<Map<String, dynamic>>> watchSpecialRequests({
    required UserProfile currentUser,
    int limit = 200,
  }) {
    return Stream<List<Map<String, dynamic>>>.value(<Map<String, dynamic>>[]);
  }
}

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  });

  test(
    'the Home list holds every open item when more than five retailers are overdue',
    () async {
      ActionCentreService.resetSharedDerive();
      final DateTime lastOrder = DateTime.now().subtract(
        const Duration(days: 20),
      );
      final List<Map<String, dynamic>> orders = <Map<String, dynamic>>[
        for (int i = 1; i <= 7; i++)
          <String, dynamic>{
            'docId': 'O$i',
            'retailerId': 'R$i',
            'retailerName': 'Shop $i',
            'status': 'approved',
            'totalPrice': 10,
            'submittedAt': lastOrder,
          },
      ];

      final List<ActionCentreItem> items = await ActionCentreService(
        repository: _FakeCms(orders),
      ).loadItems(currentUser: _admin);

      expect(
        items.where((ActionCentreItem i) => i.category == 'Retailer Visit'),
        hasLength(7),
      );
    },
  );

  test(
    'an old last-seen row does not make a cut visit list count as a full week',
    () async {
      ActionCentreService.resetSharedDerive();
      final DateTime now = DateTime.now();
      final List<Map<String, dynamic>> visits = <Map<String, dynamic>>[
        for (int i = 0; i < 500; i++)
          <String, dynamic>{
            'docId': 'route_stop_progress_S$i',
            'sourceCollection': 'route_stop_progress',
            'retailerId': 'R-SEEN',
            'retailerName': 'Seen shop',
            'arrivalTime': now.subtract(Duration(minutes: 5 * i)),
            'status': 'completed',
          },
        <String, dynamic>{
          'docId': 'user_location_sales-1',
          'sourceCollection': 'users',
          'retailerId': 'live',
          'retailerName': 'Live location',
          'arrivalTime': now.subtract(const Duration(days: 60)),
        },
      ];

      final List<ActionCentreItem> items = await ActionCentreService(
        repository: _FakeCms(
          const <Map<String, dynamic>>[],
          visits: visits,
          retailers: <Map<String, dynamic>>[
            <String, dynamic>{
              'docId': 'R-QUIET',
              'retailerId': 'R-QUIET',
              'name': 'Quiet shop',
            },
          ],
        ),
      ).loadItems(currentUser: _admin);

      expect(
        items.where((ActionCentreItem i) => i.relatedEntityId == 'R-QUIET'),
        isEmpty,
      );
    },
  );
}
