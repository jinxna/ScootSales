library;

const String kRouteOrderExact = 'exact-v1';
const String kRouteOrderTwoOpt = 'two-opt-v1';
const String kRouteOrderManual = 'manual';
const int kRouteExactOrderLimit = 8;
const int kRouteStartNode = -1;
const double _improvementFloor = 1e-9;

typedef RouteLegCost = double Function(int from, int to);

class RouteOrderResult {
  const RouteOrderResult({
    required this.order,
    required this.cost,
    required this.method,
  });

  final List<int> order;
  final double cost;
  final String method;
}

class RouteLegTable {
  const RouteLegTable({
    required this.hasStart,
    required this.stopIds,
    required this.seconds,
    required this.meters,
  });

  final bool hasStart;
  final List<String> stopIds;
  final List<List<double>> seconds;
  final List<List<double>> meters;

  bool covers(Iterable<String> ids, {required bool withStart}) {
    if (withStart && !hasStart) return false;
    final Set<String> known = stopIds.toSet();
    return ids.every(known.contains);
  }

  int _node(String? stopId) {
    if (stopId == null) {
      if (!hasStart) throw StateError('The leg table has no start point.');
      return 0;
    }
    final int index = stopIds.indexOf(stopId);
    if (index < 0) throw StateError('The leg table has no stop $stopId.');
    return hasStart ? index + 1 : index;
  }

  double secondsBetween(String? fromStopId, String? toStopId) =>
      seconds[_node(fromStopId)][_node(toStopId)];

  double metersBetween(String? fromStopId, String? toStopId) =>
      meters[_node(fromStopId)][_node(toStopId)];
}

double routeOrderCost(
  List<int> order, {
  required bool hasStart,
  required RouteLegCost cost,
}) {
  if (order.isEmpty) return 0;
  double total = 0;
  if (hasStart) total += cost(kRouteStartNode, order.first);
  for (int i = 1; i < order.length; i++) {
    total += cost(order[i - 1], order[i]);
  }
  if (hasStart) total += cost(order.last, kRouteStartNode);
  return total;
}

List<int> greedyStopOrder({
  required int stopCount,
  required bool hasStart,
  required RouteLegCost cost,
}) {
  final _Costs costs = _Costs.read(stopCount, hasStart, cost);
  return _greedy(costs);
}

RouteOrderResult bestStopOrder({
  required int stopCount,
  required bool hasStart,
  required RouteLegCost cost,
}) {
  final _Costs costs = _Costs.read(stopCount, hasStart, cost);
  if (stopCount <= kRouteExactOrderLimit) {
    final List<int> order = _exact(costs);
    return RouteOrderResult(
      order: order,
      cost: costs.total(order),
      method: kRouteOrderExact,
    );
  }
  final List<int> order = _improve(costs, _greedy(costs));
  return RouteOrderResult(
    order: order,
    cost: costs.total(order),
    method: kRouteOrderTwoOpt,
  );
}

class _Costs {
  _Costs._(
    this.count,
    this.hasStart,
    this._between,
    this._fromStart,
    this._toStart,
  );

  factory _Costs.read(int stopCount, bool hasStart, RouteLegCost cost) {
    if (stopCount < 0) {
      throw ArgumentError.value(stopCount, 'stopCount', 'must not be negative');
    }
    double checked(int from, int to) {
      final double value = cost(from, to);
      if (!value.isFinite || value < 0) {
        throw ArgumentError('The cost from $from to $to is $value.');
      }
      return value;
    }

    return _Costs._(
      stopCount,
      hasStart,
      <List<double>>[
        for (int from = 0; from < stopCount; from++)
          <double>[
            for (int to = 0; to < stopCount; to++)
              from == to ? 0 : checked(from, to),
          ],
      ],
      <double>[
        for (int to = 0; to < stopCount; to++)
          hasStart ? checked(kRouteStartNode, to) : 0,
      ],
      <double>[
        for (int from = 0; from < stopCount; from++)
          hasStart ? checked(from, kRouteStartNode) : 0,
      ],
    );
  }

  final int count;
  final bool hasStart;
  final List<List<double>> _between;
  final List<double> _fromStart;
  final List<double> _toStart;

  double between(int from, int to) => _between[from][to];
  double fromStart(int to) => _fromStart[to];
  double toStart(int from) => _toStart[from];

  double total(List<int> order) {
    if (order.isEmpty) return 0;
    double sum = fromStart(order.first) + toStart(order.last);
    for (int i = 1; i < order.length; i++) {
      sum += between(order[i - 1], order[i]);
    }
    return sum;
  }
}

List<int> _exact(_Costs costs) {
  final int n = costs.count;
  if (n == 0) return <int>[];
  final List<int> current = <int>[];
  final List<bool> used = List<bool>.filled(n, false);
  List<int> best = <int>[];
  double bestCost = double.infinity;

  void visit(double soFar) {
    if (current.length == n) {
      final double total = soFar + costs.toStart(current.last);
      if (total < bestCost) {
        bestCost = total;
        best = List<int>.of(current);
      }
      return;
    }
    for (int next = 0; next < n; next++) {
      if (used[next]) continue;
      final double step = current.isEmpty
          ? costs.fromStart(next)
          : costs.between(current.last, next);
      final double reached = soFar + step;
      if (reached >= bestCost) continue;
      used[next] = true;
      current.add(next);
      visit(reached);
      current.removeLast();
      used[next] = false;
    }
  }

  visit(0);
  return best;
}

List<int> _greedyFrom(_Costs costs, int first) {
  final List<int> order = <int>[first];
  final List<bool> used = List<bool>.filled(costs.count, false);
  used[first] = true;
  while (order.length < costs.count) {
    int best = -1;
    double bestCost = double.infinity;
    for (int next = 0; next < costs.count; next++) {
      if (used[next]) continue;
      final double step = costs.between(order.last, next);
      if (step < bestCost) {
        bestCost = step;
        best = next;
      }
    }
    used[best] = true;
    order.add(best);
  }
  return order;
}

List<int> _greedy(_Costs costs) {
  final int n = costs.count;
  if (n == 0) return <int>[];
  if (costs.hasStart) {
    int first = 0;
    for (int stop = 1; stop < n; stop++) {
      if (costs.fromStart(stop) < costs.fromStart(first)) first = stop;
    }
    return _greedyFrom(costs, first);
  }
  List<int> best = _greedyFrom(costs, 0);
  double bestCost = costs.total(best);
  for (int first = 1; first < n; first++) {
    final List<int> candidate = _greedyFrom(costs, first);
    final double candidateCost = costs.total(candidate);
    if (candidateCost < bestCost) {
      bestCost = candidateCost;
      best = candidate;
    }
  }
  return best;
}

List<int> _improve(_Costs costs, List<int> start) {
  List<int> order = List<int>.of(start);
  double orderCost = costs.total(order);
  bool improved = true;
  while (improved) {
    improved = false;
    for (int i = 0; i < order.length - 1; i++) {
      for (int j = i + 1; j < order.length; j++) {
        final List<int> swapped = List<int>.of(order);
        swapped[i] = order[j];
        swapped[j] = order[i];
        final List<int> reversed = <int>[
          ...order.sublist(0, i),
          ...order.sublist(i, j + 1).reversed,
          ...order.sublist(j + 1),
        ];
        for (final List<int> candidate in <List<int>>[swapped, reversed]) {
          final double candidateCost = costs.total(candidate);
          if (candidateCost < orderCost - _improvementFloor) {
            order = candidate;
            orderCost = candidateCost;
            improved = true;
          }
        }
      }
    }
  }
  return order;
}
