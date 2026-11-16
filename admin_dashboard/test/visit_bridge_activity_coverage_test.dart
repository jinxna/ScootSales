import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/pages/admin/views/salesman_activity_page.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/utils/collection_rows.dart';

final DateTime _now = DateTime.utc(2026, 11, 12, 4);
final DateTime _performanceStart = _now.subtract(salesmanPerformanceWindow);
final DateTime _todayStart = DateTime.utc(2026, 11, 11, 16);

Map<String, dynamic> _visit(int i, DateTime at) => <String, dynamic>{
  'docId': 'route_stop_progress_S$i',
  'bridgeKey': 'route_stop_progress:S$i',
  'sourceCollection': 'route_stop_progress',
  'salesmanUid': 'sales-1',
  'retailerId': 'R$i',
  'retailerName': 'Shop $i',
  'arrivalTime': at,
  'departureTime': at,
  'updatedAt': at,
  'status': 'completed',
};

Map<String, dynamic> _point(int i, DateTime at) => <String, dynamic>{
  'docId': 'gps_tracking_G$i',
  'bridgeKey': 'gps_tracking:G$i',
  'sourceCollection': 'gps_tracking',
  'salesmanUid': 'sales-1',
  'arrivalTime': at,
  'timestamp': at,
  'updatedAt': at,
  'status': 'tracking',
};

List<Map<String, dynamic>> _visits(int count, Duration step) =>
    <Map<String, dynamic>>[
      for (int i = 0; i < count; i++) _visit(i, _now.subtract(step * i)),
    ];

List<Map<String, dynamic>> _points(int count) => <Map<String, dynamic>>[
  for (int i = 0; i < count; i++)
    _point(i, _now.subtract(Duration(minutes: i))),
];

CollectionRows _sourceRead(
  List<Map<String, dynamic>> stored, {
  String field = 'updatedAt',
}) {
  const int limit = 500;
  final List<Map<String, dynamic>> newest = stored.take(limit).toList();
  final bool full = newest.length >= limit;
  return CollectionRows(
    newest,
    isComplete: !full,
    coveredSince: full ? newest.last[field] as DateTime : coversAllRows,
  );
}

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

const SalesmanActivityPage _page = SalesmanActivityPage(currentUser: _admin);

Map<String, dynamic> _order(
  String id,
  DateTime at, {
  String status = 'submitted',
}) => <String, dynamic>{
  'docId': id,
  'orderId': id,
  'salesmanUid': 'sales-1',
  'status': status,
  'submittedAt': at,
};

List<Map<String, dynamic>> _orders(int count, Duration step) =>
    <Map<String, dynamic>>[
      for (int i = 0; i < count; i++) _order('O$i', _now.subtract(step * i)),
    ];

CollectionRows _orderPanelInput(List<Map<String, dynamic>> stored) {
  final CollectionRows read = _sourceRead(stored, field: 'submittedAt');
  final CollectionRows none = CollectionRows(
    const <Map<String, dynamic>>[],
    isComplete: true,
  );
  return CmsRepository.combinedSourceRows(
    CollectionRows(read, isComplete: true),
    <String, List<Map<String, dynamic>>>{
      'orders': read,
      'users': none,
      'retailers': none,
    },
    const <String>['orders', 'users', 'retailers'],
  );
}

Map<String, String> _figures(SalesmanPerformance person) => <String, String>{
  for (final (String label, String value) in person.figures) label: value,
};

const String _locationHeldBack =
    'GPS sync, last GPS sync, active days, trend and score are unavailable.';

CollectionRows _panelInput({
  required List<Map<String, dynamic>> visits,
  required List<Map<String, dynamic>> points,
  List<Map<String, dynamic>> orders = const <Map<String, dynamic>>[],
  List<Map<String, dynamic>> orderVisits = const <Map<String, dynamic>>[],
  int limit = 500,
}) {
  final CollectionRows stops = _sourceRead(visits);
  final CollectionRows gps = _sourceRead(points);
  final CollectionRows orderRead = _sourceRead(orders, field: 'submittedAt');
  final CollectionRows none = CollectionRows(
    const <Map<String, dynamic>>[],
    isComplete: true,
  );
  final Map<String, List<Map<String, dynamic>>> sources =
      <String, List<Map<String, dynamic>>>{
        'visit_logs': none,
        'route_stop_progress': stops,
        'orders': orderRead,
        'gps_tracking': gps,
        'users': none,
        'retailers': none,
      };
  return CmsRepository.combinedSourceRows(
    CmsRepository.visitBridgeRows(
      CmsRepository.withoutNonCountingOrderReferences(<Map<String, dynamic>>[
        ...stops,
        ...orderVisits,
        ...gps,
      ], orderRead),
      locationSource: gps,
      orderSource: orderRead,
      limit: limit,
    ),
    sources,
    CmsRepository.visitBridgeSources,
    coverageSources: CmsRepository.visitCoverageSources,
  );
}

int _count(CollectionRows rows, String source) => rows
    .where((Map<String, dynamic> row) => row['sourceCollection'] == source)
    .length;

void main() {
  test(
    'a day of location points does not push older visits out or hide the visit counts',
    () {
      final CollectionRows rows = _panelInput(
        visits: _visits(40, const Duration(hours: 16)),
        points: _points(600),
      );

      expect(_count(rows, 'route_stop_progress'), 40);
      expect(_count(rows, 'gps_tracking'), 500);
      expect(rows.length, lessThanOrEqualTo(1000));
      for (int i = 1; i < rows.length; i++) {
        expect(
          (rows[i]['updatedAt'] as DateTime).isAfter(
            rows[i - 1]['updatedAt'] as DateTime,
          ),
          isFalse,
        );
      }
      expect(activityCoverage(rows, _performanceStart).visits, isTrue);
      expect(collectionRowsCover(rows, _todayStart), isTrue);
    },
  );

  test('visits cut inside the window keep the incomplete notice', () {
    final CollectionRows cutBySource = _panelInput(
      visits: _visits(501, const Duration(minutes: 1)),
      points: _points(20),
    );
    expect(activityCoverage(cutBySource, _performanceStart).visits, isFalse);
    expect(activityCoverage(cutBySource, _performanceStart).location, isFalse);
    expect(collectionRowsCover(cutBySource, _todayStart), isFalse);

    final CollectionRows cutByPanel = _panelInput(
      visits: _visits(201, const Duration(minutes: 1)),
      points: _points(20),
      limit: 200,
    );
    expect(activityCoverage(cutByPanel, _performanceStart).visits, isFalse);
    expect(collectionRowsCover(cutByPanel, _todayStart), isFalse);

    final CollectionRows readOnce = CmsRepository.visitBridgeRows(
      CollectionRows(_visits(40, const Duration(hours: 16)), isComplete: false),
      locationSource: _sourceRead(_points(20)),
      limit: 500,
    );
    expect(collectionRowsCover(readOnce, _performanceStart), isFalse);
  });

  test(
    'location points cut inside the window hold back only the location figures',
    () {
      final CollectionRows cut = _panelInput(
        visits: _visits(40, const Duration(hours: 16)),
        points: _points(600),
      );
      expect(activityCoverage(cut, _performanceStart).visits, isTrue);
      expect(activityCoverage(cut, _performanceStart).location, isFalse);
      expect(locationRowsCover(cut, _todayStart), isFalse);
      expect(
        activityCoverage(cut, _now.subtract(const Duration(hours: 1))).location,
        isTrue,
      );

      final CollectionRows whole = _panelInput(
        visits: _visits(40, const Duration(hours: 16)),
        points: _points(20),
      );
      expect(activityCoverage(whole, _performanceStart).visits, isTrue);
      expect(activityCoverage(whole, _performanceStart).location, isTrue);
      expect(locationRowsCover(whole, _todayStart), isTrue);
    },
  );

  test('each kind of row is cut to the panel limit on its own', () {
    final CollectionRows rows = _panelInput(
      visits: _visits(150, const Duration(hours: 1)),
      points: _points(300),
      limit: 200,
    );

    expect(_count(rows, 'route_stop_progress'), 150);
    expect(_count(rows, 'gps_tracking'), 200);
    expect(collectionRowsComplete(rows), isTrue);
    expect(activityCoverage(rows, _performanceStart).visits, isTrue);
    expect(activityCoverage(rows, _performanceStart).location, isFalse);
    expect(
      activityCoverage(
        rows,
        _now.subtract(const Duration(minutes: 199)),
      ).location,
      isTrue,
    );
  });

  test(
    'many stops a day: the panel counts the days that are loaded and names the first one',
    () {
      final List<Map<String, dynamic>> stored = _visits(
        700,
        const Duration(minutes: 58),
      );
      final ({String label, List<SalesmanPerformance>? people}) panel = _page
          .performancePanel(
            _panelInput(visits: stored, points: _points(20)),
            _orderPanelInput(const <Map<String, dynamic>>[]),
            const <Map<String, dynamic>>[],
            _now,
          );

      final DateTime firstCountedDay = DateTime.utc(2026, 10, 23, 16);
      expect(panel.label, 'Supportive view · since 24 Oct 2026');
      expect(panel.people, hasLength(1));
      final SalesmanPerformance person = panel.people!.single;
      expect(person.visitsCompleted, 485);
      expect(
        stored
            .where(
              (Map<String, dynamic> row) =>
                  !(row['updatedAt'] as DateTime).isBefore(firstCountedDay),
            )
            .length,
        485,
      );
      expect(_figures(person).keys, <String>[
        'Visits completed',
        'Orders submitted',
        'Conversion',
        'Retailer coverage',
        'GPS sync',
        'Last GPS sync',
        'Active days',
      ]);
      expect(person.label, 'Shorter period');
      expect(
        person.recommendedFollowUp,
        'Trend and score need the full 28 days and are unavailable.',
      );
    },
  );

  test(
    'more orders than the page reads do not hide the visits, and orders count from the day they are loaded',
    () {
      final List<Map<String, dynamic>> orders = _orders(
        1120,
        const Duration(minutes: 36),
      );
      final CollectionRows visitRows = _panelInput(
        visits: _visits(40, const Duration(hours: 16)),
        points: _points(20),
        orders: orders,
      );
      expect(activityCoverage(visitRows, _performanceStart).visits, isTrue);
      expect(collectionRowsCover(visitRows, _todayStart), isTrue);

      final ({String label, List<SalesmanPerformance>? people}) panel = _page
          .performancePanel(
            visitRows,
            _orderPanelInput(orders),
            const <Map<String, dynamic>>[],
            _now,
          );
      expect(panel.label, 'Supportive view · since 1 Nov 2026');
      final SalesmanPerformance person = panel.people!.single;
      expect(person.visitsCompleted, 18);
      expect(person.ordersSubmitted, 461);
      expect(_figures(person)['Conversion'], '2561%');
    },
  );

  test(
    'orders come from the order list, whatever the location points say or cover',
    () {
      final List<Map<String, dynamic>> orders = <Map<String, dynamic>>[
        _order('A', _now.subtract(const Duration(hours: 1))),
        _order(
          'B',
          _now.subtract(const Duration(hours: 2)),
          status: 'held_for_review',
        ),
        _order(
          'C',
          _now.subtract(const Duration(hours: 3)),
          status: 'rejected',
        ),
        _order(
          'D',
          _now.subtract(const Duration(hours: 4)),
          status: 'cancelled',
        ),
      ];
      final List<Map<String, dynamic>> orderPoints = <Map<String, dynamic>>[
        for (final Map<String, dynamic> order in orders)
          <String, dynamic>{
            ..._point(
              1000 + orders.indexOf(order),
              order['submittedAt'] as DateTime,
            ),
            'lastOrderId': order['orderId'],
          },
      ];
      final List<Map<String, dynamic>> manyPoints =
          <Map<String, dynamic>>[..._points(600), ...orderPoints]..sort(
            (Map<String, dynamic> a, Map<String, dynamic> b) =>
                (b['updatedAt'] as DateTime).compareTo(
                  a['updatedAt'] as DateTime,
                ),
          );

      for (final List<Map<String, dynamic>> points
          in <List<Map<String, dynamic>>>[orderPoints, manyPoints]) {
        final SalesmanPerformance person = _page
            .performancePanel(
              _panelInput(
                visits: _visits(4, const Duration(hours: 1)),
                points: points,
                orders: orders,
              ),
              _orderPanelInput(orders),
              const <Map<String, dynamic>>[],
              _now,
            )
            .people!
            .single;
        expect(person.ordersSubmitted, 2);
        expect(_figures(person)['Orders submitted'], '2');
        expect(_figures(person)['Conversion'], '50%');
      }
    },
  );

  test(
    'location points cut: visits, orders and conversion show and the location figures are held back',
    () {
      final ({String label, List<SalesmanPerformance>? people}) panel = _page
          .performancePanel(
            _panelInput(
              visits: _visits(40, const Duration(hours: 16)),
              points: _points(600),
            ),
            _orderPanelInput(_orders(3, const Duration(days: 2))),
            const <Map<String, dynamic>>[],
            _now,
          );

      expect(panel.label, 'Supportive view · last 28 days');
      final SalesmanPerformance person = panel.people!.single;
      expect(_figures(person), <String, String>{
        'Visits completed': '40',
        'Orders submitted': '3',
        'Conversion': '8%',
        'Retailer coverage': '40',
      });
      expect(person.label, 'Incomplete location coverage');
      expect(person.recommendedFollowUp, _locationHeldBack);
    },
  );

  test(
    'no usable period keeps the whole-panel notice, and one full day is enough',
    () {
      final CollectionRows noOrders = _orderPanelInput(
        const <Map<String, dynamic>>[],
      );
      List<SalesmanPerformance>? people(
        List<Map<String, dynamic>>? visitRows,
        List<Map<String, dynamic>>? orderRows,
      ) => _page
          .performancePanel(
            visitRows,
            orderRows,
            const <Map<String, dynamic>>[],
            _now,
          )
          .people;

      expect(
        people(
          CollectionRows(
            _visits(40, const Duration(hours: 16)),
            isComplete: false,
          ),
          noOrders,
        ),
        isNull,
      );
      expect(
        people(
          _panelInput(
            visits: _visits(40, const Duration(hours: 16)),
            points: _points(20),
          ),
          const <Map<String, dynamic>>[],
        ),
        isNull,
      );
      expect(
        people(
          _panelInput(
            visits: _visits(501, const Duration(minutes: 4)),
            points: _points(20),
          ),
          noOrders,
        ),
        isNull,
      );

      final ({String label, List<SalesmanPerformance>? people}) oneFullDay =
          _page.performancePanel(
            _panelInput(
              visits: _visits(600, const Duration(minutes: 5)),
              points: _points(20),
            ),
            noOrders,
            const <Map<String, dynamic>>[],
            _now,
          );
      expect(oneFullDay.label, 'Supportive view · since 11 Nov 2026');
      expect(oneFullDay.people!.single.visitsCompleted, 433);
    },
  );

  test(
    'the location coverage is still known after the page cache replays the rows',
    () {
      final List<Map<String, dynamic>> replayed = CmsRepository.replayedRows(
        _panelInput(
          visits: _visits(40, const Duration(hours: 16)),
          points: _points(20),
        ),
      );
      expect(collectionRowsCover(replayed, _performanceStart), isTrue);
      expect(locationRowsCover(replayed, _performanceStart), isTrue);
    },
  );

  test('orders that are visits keep their cut in the visit coverage', () {
    final CollectionRows rows = _panelInput(
      visits: _visits(40, const Duration(hours: 16)),
      points: _points(20),
      orders: _orders(600, const Duration(hours: 1)),
      orderVisits: <Map<String, dynamic>>[
        <String, dynamic>{
          ..._visit(9000, _now),
          'bridgeKey': 'orders:O0',
          'sourceCollection': 'orders',
        },
      ],
    );
    expect(activityCoverage(rows, _performanceStart).visits, isFalse);
    expect(collectionRowsCover(rows, _todayStart), isTrue);
  });
}
