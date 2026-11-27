import 'dart:math';

import 'package:flutter_test/flutter_test.dart';

import 'package:flutter_web_app/utils/route_stop_order.dart';

class _Problem {
  _Problem(this.stopCount, this.hasStart, Random random)
    : _matrix = <List<double>>[
        for (int from = 0; from <= stopCount; from++)
          <double>[
            for (int to = 0; to <= stopCount; to++)
              from == to ? 0 : 1 + random.nextInt(900) / 7,
          ],
      ];

  final int stopCount;
  final bool hasStart;
  final List<List<double>> _matrix;
  int startLegReads = 0;

  double cost(int from, int to) {
    if (from == kRouteStartNode || to == kRouteStartNode) startLegReads++;
    return _matrix[from + 1][to + 1];
  }

  double total(List<int> order) =>
      routeOrderCost(order, hasStart: hasStart, cost: cost);
}

double _bruteForceShortest(_Problem problem) {
  double best = double.infinity;
  void permute(List<int> head, List<int> rest) {
    if (rest.isEmpty) {
      final double total = problem.total(head);
      if (total < best) best = total;
      return;
    }
    for (final int next in rest) {
      permute(
        <int>[...head, next],
        <int>[
          for (final int other in rest)
            if (other != next) other,
        ],
      );
    }
  }

  permute(<int>[], List<int>.generate(problem.stopCount, (int i) => i));
  return best;
}

void _expectEveryStopOnce(List<int> order, int stopCount) {
  expect(order.toList()..sort(), List<int>.generate(stopCount, (int i) => i));
}

void main() {
  test('2 to 8 stops give the true shortest order, return leg included', () {
    final Random random = Random(20261118);
    for (final bool hasStart in <bool>[true, false]) {
      for (int stopCount = 2; stopCount <= 8; stopCount++) {
        final int rounds = stopCount <= 6 ? 12 : 3;
        for (int round = 0; round < rounds; round++) {
          final _Problem problem = _Problem(stopCount, hasStart, random);
          final RouteOrderResult result = bestStopOrder(
            stopCount: stopCount,
            hasStart: hasStart,
            cost: problem.cost,
          );
          _expectEveryStopOnce(result.order, stopCount);
          expect(result.method, kRouteOrderExact);
          expect(result.cost, closeTo(problem.total(result.order), 1e-6));
          expect(
            result.cost,
            closeTo(_bruteForceShortest(problem), 1e-6),
            reason: '$stopCount stops, start $hasStart, round $round',
          );
        }
      }
    }
  });

  test('more than 8 stops are never longer than the greedy order', () {
    final Random random = Random(7);
    for (final bool hasStart in <bool>[true, false]) {
      for (final int stopCount in <int>[9, 12, 20, 30]) {
        for (int round = 0; round < 5; round++) {
          final _Problem problem = _Problem(stopCount, hasStart, random);
          final RouteOrderResult result = bestStopOrder(
            stopCount: stopCount,
            hasStart: hasStart,
            cost: problem.cost,
          );
          final List<int> greedy = greedyStopOrder(
            stopCount: stopCount,
            hasStart: hasStart,
            cost: problem.cost,
          );
          _expectEveryStopOnce(result.order, stopCount);
          expect(result.method, kRouteOrderTwoOpt);
          expect(result.cost, lessThanOrEqualTo(problem.total(greedy) + 1e-6));
        }
      }
    }
  });

  test('with no start point no leg from or to a start is read', () {
    final Random random = Random(3);
    for (final int stopCount in <int>[1, 2, 5, 8, 9, 15]) {
      final _Problem problem = _Problem(stopCount, false, random);
      final RouteOrderResult result = bestStopOrder(
        stopCount: stopCount,
        hasStart: false,
        cost: problem.cost,
      );
      greedyStopOrder(
        stopCount: stopCount,
        hasStart: false,
        cost: problem.cost,
      );
      expect(problem.startLegReads, 0);
      double openPath = 0;
      for (int i = 1; i < result.order.length; i++) {
        openPath += problem.cost(result.order[i - 1], result.order[i]);
      }
      expect(result.cost, closeTo(openPath, 1e-6));
    }
  });

  test('one stop goes out and back with a start and costs nothing without', () {
    double cost(int from, int to) => from == kRouteStartNode ? 4 : 6;
    final RouteOrderResult round = bestStopOrder(
      stopCount: 1,
      hasStart: true,
      cost: cost,
    );
    expect(round.order, <int>[0]);
    expect(round.cost, 10);
    final RouteOrderResult open = bestStopOrder(
      stopCount: 1,
      hasStart: false,
      cost: cost,
    );
    expect(open.order, <int>[0]);
    expect(open.cost, 0);
  });

  test('zero stops give an empty order', () {
    for (final bool hasStart in <bool>[true, false]) {
      final RouteOrderResult result = bestStopOrder(
        stopCount: 0,
        hasStart: hasStart,
        cost: (int from, int to) => fail('no leg exists'),
      );
      expect(result.order, isEmpty);
      expect(result.cost, 0);
    }
  });

  test(
    'the return leg decides between two orders with equal outbound cost',
    () {
      double cost(int from, int to) {
        if (from == kRouteStartNode) return 1;
        if (to == kRouteStartNode) return from == 0 ? 50 : 1;
        return 1;
      }

      final RouteOrderResult result = bestStopOrder(
        stopCount: 2,
        hasStart: true,
        cost: cost,
      );
      expect(result.order, <int>[0, 1]);
      expect(result.cost, 3);
    },
  );

  test('equal costs end with a full order', () {
    final RouteOrderResult result = bestStopOrder(
      stopCount: 12,
      hasStart: true,
      cost: (int from, int to) => 5,
    );
    _expectEveryStopOnce(result.order, 12);
    expect(result.cost, 65);
  });

  test('a cost that is not a real distance is refused', () {
    for (final double bad in <double>[double.nan, double.infinity, -1]) {
      expect(
        () => bestStopOrder(
          stopCount: 3,
          hasStart: true,
          cost: (int from, int to) => bad,
        ),
        throwsArgumentError,
      );
    }
  });
}
