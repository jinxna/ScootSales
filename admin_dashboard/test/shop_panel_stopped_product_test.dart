import 'package:flutter/material.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/ai_insight.dart';
import 'package:flutter_web_app/models/conversation_outcome.dart';
import 'package:flutter_web_app/services/replenishment_service.dart';
import 'package:flutter_web_app/models/user_profile.dart';
import 'package:flutter_web_app/repositories/cms_repository.dart';
import 'package:flutter_web_app/services/ai_insight_service.dart';
import 'package:flutter_web_app/services/home_decisions_service.dart';
import 'package:flutter_web_app/services/outcome_review_service.dart';
import 'package:flutter_web_app/services/shop_panel_service.dart';
import 'package:flutter_web_app/widgets/shop_panel.dart';
import 'package:flutter_web_app/widgets/weekly_bar_chart.dart';
import 'package:scoot_design/scoot_design.dart';

const UserProfile _admin = UserProfile(
  docId: 'a',
  email: 'a@x.test',
  name: 'Admin',
  role: 'admin',
  employeeCode: 'A1',
  status: UserProfile.statusActive,
  uid: 'uid-a',
);

const List<String> _weekStarts = <String>[
  '2026-08-10',
  '2026-08-17',
  '2026-08-24',
  '2026-08-31',
  '2026-09-07',
  '2026-09-14',
  '2026-09-21',
  '2026-09-28',
];

AiInsight _stopped(String retailerId, String productId, String productName) =>
    AiInsight.fromMap('$retailerId-$productId', <String, dynamic>{
      'type': 'stopped_product',
      'retailerId': retailerId,
      'retailerName': 'Shop $retailerId',
      'productId': productId,
      'productName': productName,
      'latestEvidence': <String, dynamic>{
        'weekStarts': _weekStarts,
        'weeklyQuantities': <num>[6, 6, 5, 6, 6, 6, 0, 0],
      },
    });

class _Insights extends Fake implements AiInsightService {
  _Insights(this.rows);
  final List<AiInsight> rows;

  @override
  Stream<List<AiInsight>> watchInsights(
    UserProfile currentUser, {
    int limit = 200,
  }) => Stream<List<AiInsight>>.value(rows);
}

class _NoCms extends Fake implements CmsRepository {}

class _NoOutcomes extends Fake implements OutcomeReviewService {}

class _NoFollowUps extends Fake implements OutcomeReviewService {
  @override
  Future<List<ConversationOutcome>?> loadOpenDatedFollowUps(
    UserProfile currentUser, {
    int limit = 300,
  }) async => const <ConversationOutcome>[];
}

class _EmptyCms extends Fake implements CmsRepository {
  @override
  Future<List<Map<String, dynamic>>> getCollectionOnce(
    String collectionName, {
    String? orderBy,
    bool descending = false,
    int? limit,
    Duration? timeout,
    bool raw = false,
    bool coverageProbe = true,
  }) async => const <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> getRetailerDirectory({
    required int limit,
  }) async => const <Map<String, dynamic>>[];
}

class _Orders extends Fake implements ReplenishmentService {
  _Orders(this.count);
  final int count;

  @override
  Future<List<Map<String, dynamic>>> loadRetailerItemPatterns(
    UserProfile currentUser,
    String retailerId, {
    int limit = 50,
    List<String>? failedSources,
  }) async => const <Map<String, dynamic>>[];

  @override
  Future<List<Map<String, dynamic>>> loadRetailerOrders(
    UserProfile currentUser,
    String retailerId, {
    int limit = 300,
    List<String>? failedSources,
  }) async => <Map<String, dynamic>>[
    for (int i = 0; i < count; i++)
      <String, dynamic>{
        'orderId': 'o$i',
        'retailerId': 'r1',
        'createdAt': DateTime(2026, 11, 1).add(Duration(hours: i)),
        'totalAmount': 1.0,
      },
  ];
}

class _Panel extends Fake implements ShopPanelService {
  _Panel(this.data);
  final ShopPanelData data;

  @override
  Future<ShopPanelData> load(
    UserProfile user,
    String retailerId,
    String fallbackName,
  ) async => data;
}

ShopWeeklySeries _pattern(String id, String name, List<double> quantities) =>
    ShopWeeklySeries(
      productId: id,
      productName: name,
      weeks: <WeeklyQuantity>[
        for (int i = 0; i < quantities.length; i++)
          WeeklyQuantity(
            weekStart: DateTime.parse(_weekStarts[i]),
            quantity: quantities[i],
          ),
      ],
    );

Future<void> _pumpPanel(
  WidgetTester tester,
  ShopPanelData data,
  String? focus,
) async {
  await tester.binding.setSurfaceSize(const Size(600, 1400));
  addTearDown(() => tester.binding.setSurfaceSize(null));
  await tester.pumpWidget(
    MaterialApp(
      theme: ScootTheme.dashboard(),
      home: Scaffold(
        body: ShopPanel(
          currentUser: _admin,
          retailerId: 'r1',
          retailerName: 'Shop r1',
          focusProductId: focus,
          service: _Panel(data),
          onClose: () {},
        ),
      ),
    ),
  );
  await tester.pumpAndSettle();
}

ShopPanelData _data({bool tooManyOrders = false}) => ShopPanelData(
  retailerName: 'Shop r1',
  series: <ShopWeeklySeries>[
    _pattern('milk', 'Milk 16P', <double>[9, 9, 9, 9, 9, 9, 0, 0]),
    _pattern('dye', 'Food Colouring Green', <double>[1, 1, 1, 1, 1, 1, 1, 1]),
  ],
  stoppedEvidence: <String, ShopWeeklySeries?>{
    'milk': stoppedSeriesFromInsight(_stopped('r1', 'milk', 'Milk 16P')),
    'dye': stoppedSeriesFromInsight(
      _stopped('r1', 'dye', 'Food Colouring Green'),
    ),
  },
  lastVisit: null,
  lastOrderAmount: 12.5,
  lastOrderAt: DateTime(2026, 11, 16),
  followUp: null,
  salesperson: 'Jay',
  pin: null,
  failed: <String>{},
  tooManyOrders: tooManyOrders,
);

void main() {
  test(
    'the stopped phrase names the stored weeks and the date they end on',
    () {
      final ShopWeeklySeries? evidence = stoppedSeriesFromInsight(
        _stopped('r1', 'dye', 'Food Colouring Green'),
      );
      expect(stoppedWeeksPhrase(evidence), ' in the 2 weeks to 4 Oct 2026');
      expect(stoppedWeeksPhrase(null), '');
    },
  );

  test(
    'the home row names the product and weeks from the insight, and counts shops, not rows',
    () async {
      final HomeDecisionsService service = HomeDecisionsService(
        repository: _NoCms(),
        insights: _Insights(<AiInsight>[
          _stopped('r1', 'dye', 'Food Colouring Green'),
          _stopped('r2', 'a', 'A'),
          _stopped('r3', 'a', 'A'),
          _stopped('r4', 'a', 'A'),
          _stopped('r4', 'b', 'B'),
          _stopped('r5', 'a', 'A'),
        ]),
        outcomes: _NoOutcomes(),
        now: () => DateTime.utc(2026, 11, 18, 4),
      );
      final HomeDecisionResult result = await service.load(_admin);
      final List<HomeDecision> stopped = result.decisions
          .where((HomeDecision d) => d.kind == HomeDecisionKind.stoppedOrdering)
          .toList();
      expect(
        stopped.first.text,
        'Shop r1 ordered no Food Colouring Green in the 2 weeks to 4 Oct 2026.',
      );
      expect(stopped.first.productId, 'dye');
      expect(
        stopped.last.text,
        '3 more products stopped at 2 shops. Open the shop list to check them.',
      );
      expect(stopped.last.count, 3);
    },
  );

  for (final Object? evidence in <Object?>[
    null,
    <String, dynamic>{},
    <String, dynamic>{'weekStarts': 'x', 'weeklyQuantities': 3},
  ]) {
    test(
      'a stopped insight with evidence $evidence keeps the home card and says its sentence with no weeks',
      () async {
        final HomeDecisionsService service = HomeDecisionsService(
          repository: _NoCms(),
          insights: _Insights(<AiInsight>[
            AiInsight.fromMap('r9-milk', <String, dynamic>{
              'type': 'stopped_product',
              'retailerId': 'r9',
              'retailerName': 'Shop r9',
              'productId': 'milk',
              'productName': 'Milk 16P',
              if (evidence != null) 'latestEvidence': evidence,
            }),
            _stopped('r1', 'dye', 'Food Colouring Green'),
          ]),
          outcomes: _NoOutcomes(),
          now: () => DateTime.utc(2026, 11, 18, 4),
        );
        final HomeDecisionResult result = await service.load(_admin);
        expect(
          result.decisions
              .where(
                (HomeDecision d) => d.kind == HomeDecisionKind.stoppedOrdering,
              )
              .map((HomeDecision d) => d.text)
              .toList(),
          <String>[
            'Shop r9 ordered no Milk 16P.',
            'Shop r1 ordered no Food Colouring Green in the 2 weeks to 4 Oct 2026.',
          ],
        );
      },
    );
  }

  test(
    'a stopped insight with no stored weeks still loads the shop panel and keeps the order chart',
    () async {
      final ShopPanelData data = await ShopPanelService(
        repository: _EmptyCms(),
        replenishment: _Orders(1),
        insights: _Insights(<AiInsight>[
          AiInsight.fromMap('r1-milk', <String, dynamic>{
            'type': 'stopped_product',
            'retailerId': 'r1',
            'retailerName': 'Shop r1',
            'productId': 'milk',
            'productName': 'Milk 16P',
          }),
        ]),
        outcomes: _NoFollowUps(),
      ).load(_admin, 'r1', 'Shop r1');
      expect(data.failed, isEmpty);
      expect(data.stoppedEvidence, <String, ShopWeeklySeries?>{'milk': null});
      final ShopWeeklySeries pattern = _pattern('milk', 'Milk 16P', <double>[
        9,
        9,
        9,
        9,
        9,
        9,
        0,
        0,
      ]);
      expect(data.seriesToShow(pattern), same(pattern));
    },
  );

  testWidgets(
    'the panel opens on the product of the row and says the same thing',
    (WidgetTester tester) async {
      await _pumpPanel(tester, _data(), 'dye');
      expect(
        find.text(
          'No Food Colouring Green ordered in the 2 weeks to 4 Oct 2026',
        ),
        findsOneWidget,
      );
      expect(find.textContaining('Milk 16P ordered'), findsNothing);
    },
  );

  for (final (int count, bool capped) in <(int, bool)>[
    (499, false),
    (500, true),
    (501, true),
  ]) {
    test(
      '$count orders read for a shop ${capped ? 'reach' : 'stay under'} the 500-order read cap',
      () async {
        final ShopPanelData data = await ShopPanelService(
          repository: _EmptyCms(),
          replenishment: _Orders(count),
          insights: _Insights(const <AiInsight>[]),
          outcomes: _NoFollowUps(),
        ).load(_admin, 'r1', 'Shop r1');
        expect(data.tooManyOrders, capped);
        expect(data.failed, isNot(contains('orders')));
      },
    );
  }

  testWidgets(
    'a shop at the 500-order read cap shows a calm true line, not a read error',
    (WidgetTester tester) async {
      await _pumpPanel(tester, _data(tooManyOrders: true), 'dye');
      expect(
        find.text(
          'Not shown here: this shop has 500 or more orders. Only 500 are read.',
        ),
        findsOneWidget,
      );
      expect(find.text('Not available right now'), findsNothing);
      expect(find.textContaining('RM 12.50'), findsNothing);
    },
  );

  test('the chart names its real weeks and says when they end long ago', () {
    final List<WeeklyQuantity> weeks = _pattern('x', 'X', <double>[
      1,
      2,
      3,
      4,
      5,
      6,
      7,
      8,
    ]).weeks;
    expect(weeklyChartRangeLabel(weeks), 'Weeks of 10 Aug to 28 Sep 2026');
    expect(
      weeklyChartStaleNote(weeks, DateTime(2026, 11, 18)),
      'These numbers end on 4 Oct 2026. No newer weeks are stored.',
    );
    expect(weeklyChartStaleNote(weeks, DateTime(2026, 10, 18)), isNull);
    expect(weeklyChartStaleNote(weeks, DateTime(2026, 10, 19)), isNotNull);
  });
}
