import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/copilot/mobile_copilot_shop_facts.dart';
import 'package:fmcg_sales/models/stop_brief_view.dart';
import 'package:fmcg_sales/models/visit_brief.dart';
import 'package:fmcg_sales/services/last_order_service.dart';

final DateTime _now = DateTime(2026, 11, 18, 12);

VisitBrief _brief({
  required int ageDays,
  bool withWeeks = true,
  String? unitOfMeasure,
}) => VisitBrief.fromMap('b1', <String, dynamic>{
  'retailerId': 'r1',
  'retailerName': 'Shop One',
  'updatedAt': _now.subtract(Duration(days: ageDays)),
  'focusItems': <Map<String, dynamic>>[
    <String, dynamic>{
      'issueId': 'i1',
      'type': 'declining_sales',
      'productId': 'p2',
      'productName': 'Instant Baby Oat',
      'signal': 'Orders dropped.',
      if (withWeeks) ...<String, dynamic>{
        'weeklyVersion': 'brief-weekly/1.0.0',
        'weekStarts': <String>['2026-11-02', '2026-11-09'],
        'weeklyQuantities': <int>[6, 5],
      },
    },
  ],
  'replenishment': <Map<String, dynamic>>[
    <String, dynamic>{
      'productId': 'p2',
      'productName': 'INSTANT BABY OAT (24P X 450G)',
      'suggestedQty': 6,
      'unitOfMeasure': ?unitOfMeasure,
      'inputs': <String, dynamic>{'lastOrderQty': 4, 'lastOrderDaysAgo': 10},
    },
  ],
});

StopBriefView _view(VisitBrief brief) => StopBriefView.build(
  brief: brief,
  stopReason: '',
  lastOrder: null,
  now: _now,
);

void main() {
  test('a brief 9 days old holds no weekly chart and says it is out of date', () {
    final StopBriefView view = _view(_brief(ageDays: 9));

    expect(view.focus.single.weeks, isEmpty);
    expect(
      view.freshnessLine,
      'This brief is from 9 Nov. It may be out of date.',
    );
  });

  test('a brief 8 days old keeps its two weekly bars and is not out of date', () {
    final StopBriefView view = _view(_brief(ageDays: 8));

    expect(
      view.focus.single.weeks.map((BriefWeek week) => week.quantity).toList(),
      <double>[6, 5],
    );
    expect(view.freshnessLine, 'Updated 10 Nov');
  });

  test('a fresh brief with no weekly lists has no chart and no warning', () {
    final StopBriefView view = _view(_brief(ageDays: 2, withWeeks: false));

    expect(view.focus.single.weeks, isEmpty);
    expect(view.freshnessLine, 'Updated 16 Nov');
  });

  test('the card and Scout count the last order days from today', () {
    final VisitBrief brief = _brief(ageDays: 5);

    expect(
      _view(brief).reorders.single.line,
      'Suggest 6. Last order 4, 15 days ago.',
    );
    expect(scoutBriefFacts(brief, lastOrder: null, now: _now).reorders, <String>[
      'Suggest 6 of Instant Baby Oat. Last order 4, 15 days ago.',
    ]);
  });

  test('Scout gives the out-of-date line of the card for an old brief', () {
    final VisitBrief brief = _brief(ageDays: 9);

    expect(
      scoutBriefFacts(brief, lastOrder: null, now: _now).freshness,
      'This brief is from 9 Nov. It may be out of date.',
    );
    expect(scoutBriefFacts(brief, lastOrder: null, now: _now).reorders, <String>[
      'Suggest 6 of Instant Baby Oat. Last order 4, 19 days ago.',
    ]);
  });

  test('a reorder line names a unit only when the brief stores one', () {
    expect(
      scoutBriefFacts(
        _brief(ageDays: 0, unitOfMeasure: 'pcs'),
        lastOrder: null,
        now: _now,
      ).reorders,
      <String>['Suggest 6 pcs of Instant Baby Oat. Last order 4 pcs, 10 days ago.'],
    );
    expect(
      scoutBriefFacts(_brief(ageDays: 0), lastOrder: null, now: _now).reorders,
      <String>['Suggest 6 of Instant Baby Oat. Last order 4, 10 days ago.'],
    );
  });

  test('a last order line names a unit only when the order stores one', () {
    final LastOrder order = LastOrder.fromOrder('o1', <String, dynamic>{
      'retailerId': 'r1',
      'submittedAt': _now.subtract(const Duration(days: 3)),
      'items': <Map<String, dynamic>>[
        <String, dynamic>{'name': 'Instant Baby Oat', 'qty': 6},
        <String, dynamic>{'name': 'Milk Biscuit', 'qty': 4, 'uom': 'pcs'},
        <String, dynamic>{'name': 'Rolled Oat', 'qty': 1, 'uom': 'set'},
      ],
    })!;

    expect(scoutLastOrderLines(order), <String>[
      'Instant Baby Oat: 6',
      'Milk Biscuit: 4 pcs',
      'Rolled Oat: 1 set',
    ]);
  });
}
