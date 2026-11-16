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
  _FakeCms(this.forecasts);

  final List<Map<String, dynamic>> forecasts;

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
    return collectionName == 'demand_forecasts'
        ? forecasts
        : <Map<String, dynamic>>[];
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

Map<String, dynamic> _forecast(
  String product,
  String week,
  num point,
  num reference,
) => <String, dynamic>{
  'docId': '${product}_$week',
  'productId': product,
  'productName': product,
  'periodStart': week,
  'forecastMonth': week.substring(0, 7),
  'status': 'ok',
  'point': point,
  'predictedQuantity': point,
  'referenceUnits': reference,
  'generatedAt': '${week}T00:00:00Z',
};

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  });

  test(
    'a published forecast above its reference units gives a restock item for the latest week only',
    () async {
      ActionCentreService.resetSharedDerive();

      final List<ActionCentreItem> items = await ActionCentreService(
        repository: _FakeCms(<Map<String, dynamic>>[
          _forecast('Old Week Rise', '2026-11-02', 50, 10),
          _forecast('Latest Week Rise', '2026-11-09', 30, 10),
          _forecast('Latest Week Fall', '2026-11-09', 5, 10),
        ]),
      ).loadItems(currentUser: _admin);

      expect(
        items
            .where((ActionCentreItem i) => i.category == 'Restock')
            .map((ActionCentreItem i) => i.title),
        <String>['Prepare extra stock for Latest Week Rise'],
      );
    },
  );

  test('no published forecast gives no restock item', () async {
    ActionCentreService.resetSharedDerive();

    final List<ActionCentreItem> items = await ActionCentreService(
      repository: _FakeCms(const <Map<String, dynamic>>[]),
    ).loadItems(currentUser: _admin);

    expect(
      items.where((ActionCentreItem i) => i.category == 'Restock'),
      isEmpty,
    );
  });
}
