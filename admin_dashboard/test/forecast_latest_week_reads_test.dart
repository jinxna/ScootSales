import 'dart:math';

import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/action_centre_item.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/overview/role_home.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/services/action_centre_service.dart';
import 'package:flutter_web_app/utils/collection_rows.dart';
import 'package:flutter_web_app/utils/order_data_utils.dart';

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

const List<String> _weeks = <String>[
  '2026-10-12',
  '2026-10-19',
  '2026-10-26',
  '2026-11-02',
  '2026-11-09',
];

class _CountingCms extends CmsRepository {
  _CountingCms(this.forecasts);

  final List<Map<String, dynamic>> forecasts;
  int documentsRead = 0;

  CollectionRows _read({
    String? orderBy,
    required bool descending,
    int? limit,
    required bool coverageProbe,
  }) {
    final List<Map<String, dynamic>> ordered = forecasts.where((
      Map<String, dynamic> row,
    ) {
      return orderBy == null || row[orderBy] != null;
    }).toList();
    if (orderBy != null) {
      ordered.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
        final int order = '${a[orderBy]}'.compareTo('${b[orderBy]}');
        return descending ? -order : order;
      });
    }
    final List<Map<String, dynamic>> window = limit == null
        ? ordered
        : ordered.take(limit).toList();
    final bool probed = coverageProbe && limit != null && orderBy != null;
    final int probeDocuments = probed ? min(forecasts.length, limit + 1) : 0;
    documentsRead += window.length + probeDocuments;
    final bool full = limit != null && window.length >= limit;
    return CollectionRows(
      window,
      isComplete: !full && (!probed || probeDocuments == window.length),
      coveredSince: orderBy == null || !descending
          ? null
          : full
          ? parseFlexibleDate(window.last[orderBy])
          : coversAllRows,
    );
  }

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
    if (collectionName != 'demand_forecasts') return <Map<String, dynamic>>[];
    return _read(
      orderBy: orderBy,
      descending: descending,
      limit: limit,
      coverageProbe: coverageProbe,
    );
  }

  @override
  Stream<List<Map<String, dynamic>>> watchCollection(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    bool coverageProbe = true,
  }) {
    return Stream<List<Map<String, dynamic>>>.value(
      _read(
        orderBy: orderBy,
        descending: descending,
        limit: limit,
        coverageProbe: coverageProbe,
      ),
    );
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

List<Map<String, dynamic>> _published({
  required int productsPerWeek,
  required int risingInLatestWeek,
}) => <Map<String, dynamic>>[
  for (final String week in _weeks)
    for (int product = 0; product < productsPerWeek; product++)
      <String, dynamic>{
        'docId': 'P${product}_$week',
        'productId': 'P$product',
        'productName': 'Product $product',
        'periodStart': week,
        'forecastMonth': week.substring(0, 7),
        'status': 'ok',
        'point': week != _weeks.last || product < risingInLatestWeek ? 30 : 5,
        'referenceUnits': 10,
      },
  for (int product = 0; product < 3; product++)
    <String, dynamic>{
      'docId': 'DEMO${product}_2026-11-16',
      'productId': 'DEMO$product',
      'productName': 'Demo $product',
      'periodStart': '2026-11-16',
      'forecastMonth': '2026-11',
      'status': 'ok',
      'point': 30,
      'referenceUnits': 10,
      'isDemo': true,
    },
];

void main() {
  setUpAll(() async {
    TestWidgetsFlutterBinding.ensureInitialized();
    setupFirebaseCoreMocks();
    if (Firebase.apps.isEmpty) await Firebase.initializeApp();
  });

  test(
    'five published weeks give a complete latest-week count without reading more documents than before',
    () async {
      final List<Map<String, dynamic>> forecasts = _published(
        productsPerWeek: 131,
        risingInLatestWeek: 7,
      );
      expect(forecasts.length, greaterThan(500));

      final _CountingCms tileRepository = _CountingCms(forecasts);
      final ({int count, bool complete}) tile = forecastAlertsTile(
        await watchForecastAlertRows(tileRepository).first,
      );
      expect(tile.count, 7);
      expect(tile.complete, isTrue);
      expect(tileRepository.documentsRead, lessThanOrEqualTo(500));

      ActionCentreService.resetSharedDerive();
      final _CountingCms actionRepository = _CountingCms(forecasts);
      final ActionCentreLoadResult result = await ActionCentreService(
        repository: actionRepository,
      ).loadAllItemsWithHealth(currentUser: _admin);
      expect(
        result.items.where((ActionCentreItem i) => i.category == 'Restock'),
        hasLength(7),
      );
      expect(result.failedSources, isNot(contains('demand_forecasts')));
      expect(
        result.items.where(
          (ActionCentreItem i) => i.id == 'forecast_restock_list_partial',
        ),
        isEmpty,
      );
      expect(actionRepository.documentsRead, lessThanOrEqualTo(200));
    },
  );

  test(
    'a latest week larger than the read is reported as partial, not as a full count',
    () async {
      final List<Map<String, dynamic>> forecasts = _published(
        productsPerWeek: 600,
        risingInLatestWeek: 600,
      );

      final _CountingCms tileRepository = _CountingCms(forecasts);
      final ({int count, bool complete}) tile = forecastAlertsTile(
        await watchForecastAlertRows(tileRepository).first,
      );
      expect(tile.complete, isFalse);
      expect(tileRepository.documentsRead, lessThanOrEqualTo(500));

      ActionCentreService.resetSharedDerive();
      final _CountingCms actionRepository = _CountingCms(forecasts);
      final ActionCentreLoadResult result = await ActionCentreService(
        repository: actionRepository,
      ).loadAllItemsWithHealth(currentUser: _admin);
      expect(
        result.cutShortSources,
        contains('demand_forecasts (only the newest 200 rows were checked)'),
      );
      expect(result.failedSources, isNot(contains('demand_forecasts')));
      expect(
        result.items
            .where(
              (ActionCentreItem i) => i.id == 'forecast_restock_list_partial',
            )
            .map((ActionCentreItem i) => i.title),
        <String>['Restock list is incomplete'],
      );
      expect(actionRepository.documentsRead, lessThanOrEqualTo(200));
    },
  );
}
