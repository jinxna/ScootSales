import 'package:cloud_firestore/cloud_firestore.dart' show Timestamp;
import 'package:intl/intl.dart';

import '../models/assigned_route_plan.dart';
import '../models/stop_brief_view.dart';
import '../models/visit_brief.dart';
import '../services/last_order_service.dart';
import 'mobile_copilot_grammar.dart';

sealed class ShopMatch {
  const ShopMatch();
}

class ShopFound extends ShopMatch {
  const ShopFound(this.shop);
  final ScoutShop shop;
}

class ShopAmbiguous extends ShopMatch {
  const ShopAmbiguous(this.shops);
  final List<ScoutShop> shops;
}

class ShopMissing extends ShopMatch {
  const ShopMissing();
}

class ShopFacts {
  const ShopFacts({
    required this.shop,
    required this.stop,
    required this.stopDay,
    required this.stopIsToday,
    required this.brief,
    required this.lastOrder,
  });

  final ScoutShop shop;
  final AssignedRouteStop? stop;
  final AssignedRouteDay? stopDay;
  final bool stopIsToday;
  final VisitBrief? brief;
  final LastOrder? lastOrder;
}

DateTime? scoutWhen(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(value?.toString() ?? '');
}

String scoutReorderLine(BriefReorderView row) {
  final String product = row.productName.isEmpty
      ? ''
      : ' of ${row.productName}';
  final String suggest = 'Suggest ${row.quantity}$product.';
  return row.lastOrder.isEmpty ? suggest : '$suggest ${row.lastOrder}';
}

({String freshness, List<String> reorders}) scoutBriefFacts(
  VisitBrief brief, {
  required LastOrder? lastOrder,
  required DateTime now,
}) {
  final StopBriefView view = StopBriefView.build(
    brief: brief,
    stopReason: '',
    lastOrder: lastOrder,
    now: now,
  );
  return (
    freshness: view.freshnessLine,
    reorders: <String>[
      for (final BriefReorderView row in view.reorders.take(3))
        scoutReorderLine(row),
    ],
  );
}

List<String> scoutLastOrderLines(LastOrder order) => <String>[
  for (final LastOrderLine line in order.lines.take(5))
    '${line.name}: ${briefQuantity(line.quantity, line.uom ?? '')}',
  if (order.lines.length > 5) 'and ${order.lines.length - 5} more',
];

String scoutDayMonth(DateTime day, DateTime now) =>
    DateFormat(day.year == now.year ? 'd MMM' : 'd MMM y').format(day);

String scoutDaysAgo(DateTime when, DateTime now) {
  final int days = DateTime(
    now.year,
    now.month,
    now.day,
  ).difference(DateTime(when.year, when.month, when.day)).inDays;
  if (days <= 0) return 'today';
  return days == 1 ? '1 day ago' : '$days days ago';
}

const List<String> _weekdays = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

String? scoutUsualOrderDay(Object? weekday) {
  final int? day = weekday is num ? weekday.toInt() : null;
  if (day == null || day < 1 || day > _weekdays.length) return null;
  return _weekdays[day - 1];
}

class ScoutShopBook {
  ScoutShopBook({
    required AssignedRoutePlan? plan,
    required DateTime today,
    required List<VisitBrief> briefs,
    required Map<String, LastOrder> lastOrders,
  }) : _plan = plan,
       _today = plan?.dayFor(today),
       _briefs = briefs,
       _orders = lastOrders.values.toList() {
    _orders.sort(
      (LastOrder a, LastOrder b) => b.orderedAt.compareTo(a.orderedAt),
    );
    for (final AssignedRouteDay day
        in plan?.days ?? const <AssignedRouteDay>[]) {
      for (final AssignedRouteStop stop in day.stops) {
        _add(stop.retailerId, stop.retailerName);
      }
    }
    for (final VisitBrief brief in briefs) {
      _add(brief.retailerId, brief.retailerName);
    }
    for (final LastOrder order in _orders) {
      _add(order.retailerId, order.retailerName);
    }
  }

  final AssignedRoutePlan? _plan;
  final AssignedRouteDay? _today;
  final List<VisitBrief> _briefs;
  final List<LastOrder> _orders;
  final List<ScoutShop> _shops = <ScoutShop>[];

  static bool sameShop(ScoutShop shop, String id, String name) {
    final String otherId = id.trim();
    if (shop.id.isNotEmpty && otherId.isNotEmpty) return shop.id == otherId;
    return normaliseCopilotText(shop.name) == normaliseCopilotText(name);
  }

  static VisitBrief? briefFor(Iterable<VisitBrief> briefs, ScoutShop shop) {
    for (final VisitBrief brief in briefs) {
      if (sameShop(shop, brief.retailerId, brief.retailerName)) return brief;
    }
    return null;
  }

  void _add(String id, String name) {
    final String cleanName = name.trim();
    final String wanted = normaliseCopilotText(cleanName);
    if (wanted.isEmpty) return;
    final String cleanId = id.trim();
    for (final ScoutShop shop in _shops) {
      if (cleanId.isNotEmpty && shop.id == cleanId) return;
      if (normaliseCopilotText(shop.name) == wanted) return;
    }
    _shops.add(ScoutShop(id: cleanId, name: cleanName));
  }

  ShopMatch find(String spoken) {
    final String wanted = normaliseCopilotText(spoken);
    if (wanted.isEmpty) return const ShopMissing();
    final List<ScoutShop> partial = <ScoutShop>[];
    for (final ScoutShop shop in _shops) {
      final String name = normaliseCopilotText(shop.name);
      if (name == wanted) return ShopFound(shop);
      if (wanted.length >= 3 &&
          (name.contains(wanted) || wanted.contains(name))) {
        partial.add(shop);
      }
    }
    if (partial.isEmpty) return const ShopMissing();
    return partial.length == 1
        ? ShopFound(partial.single)
        : ShopAmbiguous(partial);
  }

  List<AssignedRouteStop> get todayStops =>
      <AssignedRouteStop>[...?_today?.stops]..sort(
        (AssignedRouteStop a, AssignedRouteStop b) =>
            a.sequence.compareTo(b.sequence),
      );

  ScoutShop shopOf(AssignedRouteStop stop) {
    for (final ScoutShop shop in _shops) {
      if (sameShop(shop, stop.retailerId, stop.retailerName)) return shop;
    }
    return ScoutShop(id: stop.retailerId, name: stop.retailerName);
  }

  bool isOnTodayRoute(ScoutShop shop) => todayStops.any(
    (AssignedRouteStop stop) =>
        sameShop(shop, stop.retailerId, stop.retailerName),
  );

  AssignedRouteStop? stopAfter(ScoutShop shop) {
    final List<AssignedRouteStop> stops = todayStops;
    final int at = stops.indexWhere(
      (AssignedRouteStop stop) =>
          sameShop(shop, stop.retailerId, stop.retailerName),
    );
    return at < 0 || at + 1 >= stops.length ? null : stops[at + 1];
  }

  ShopFacts facts(ScoutShop shop) {
    AssignedRouteStop? stop;
    AssignedRouteDay? stopDay;
    final List<AssignedRouteDay> days = <AssignedRouteDay>[
      if (_today != null) _today,
      ...?_plan?.days,
    ];
    for (final AssignedRouteDay day in days) {
      for (final AssignedRouteStop candidate in day.stops) {
        if (stop == null &&
            sameShop(shop, candidate.retailerId, candidate.retailerName)) {
          stop = candidate;
          stopDay = day;
        }
      }
    }
    LastOrder? lastOrder;
    for (final LastOrder order in _orders) {
      if (sameShop(shop, order.retailerId, order.retailerName)) {
        lastOrder = order;
        break;
      }
    }
    return ShopFacts(
      shop: shop,
      stop: stop,
      stopDay: stopDay,
      stopIsToday: stop != null && identical(stopDay, _today),
      brief: briefFor(_briefs, shop),
      lastOrder: lastOrder,
    );
  }
}
