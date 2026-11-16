import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../edition.dart';
import '../models/assigned_route_plan.dart';
import '../models/user_model.dart';
import '../models/visit_brief.dart';
import '../screens/overview_screen.dart'
    show assignedPlanForToday, assignedStopsForToday;
import '../services/route_plan_service.dart';
import '../services/sales_visit_copilot_service.dart';
import '../utils/assigned_route_lifecycle.dart' show isTerminalStopStatus;
import '../utils/order_status.dart';
import 'mobile_copilot_grammar.dart';
import '../utils/data_number.dart';
import '../utils/quantity_unit.dart';

enum CopilotDestination { route, orders, planner, profile }

class CopilotAnswer {
  const CopilotAnswer(
    this.text, {
    this.details = const <String>[],
    this.open,
    this.openLabel = '',
    this.refused = false,
    this.chips = const <String>[],
  });

  final String text;
  final List<String> details;

  final CopilotDestination? open;
  final String openLabel;
  final bool refused;

  final List<String> chips;
}

const List<String> kCopilotStartChips = <String>[
  'What is my next stop?',
  'How many stops are left today?',
  'Open my orders',
  'Help',
];

const CopilotAnswer kCopilotRefusal = CopilotAnswer(
  kBasicEdition
      ? 'I can only show your own route and orders. I cannot do '
            'that from Scout. Try one of these instead.'
      : 'I can only show your own route, orders and visit briefs. I cannot do '
            'that from Scout. Try one of these instead.',
  refused: true,
  chips: kCopilotStartChips,
);

const CopilotAnswer kCopilotNotUnderstood = CopilotAnswer(
  'I did not understand that. Try one of these.',
  chips: kCopilotStartChips,
);

const CopilotAnswer kCopilotHelp = CopilotAnswer(
  kBasicEdition
      ? 'Ask about your own route and orders. On some screens I can '
            'also do small tasks. I ask you before I change anything.'
      : 'Ask about your own route, orders and visit briefs. On some screens I can '
            'also do small tasks. I ask you before I change anything.',
  details: <String>[
    'What is my next stop? How many stops are left today?',
    'How much did I sell today? This week?',
    'What did <retailer name> order last time?',
    if (!kBasicEdition) 'Show the visit brief for <retailer name>',
    'Open my route, orders, planner or profile',
    if (kBasicEdition)
      'On a screen: search products, set a quantity (you confirm)'
    else
      'On a screen: search products, open the visit brief, set a quantity (you confirm)',
    'I cannot submit orders, complete visits or record outcomes. Do those on the screen.',
  ],
  chips: kCopilotStartChips,
);

class MobileCopilotAnswers {
  MobileCopilotAnswers(
    this.user, {
    RoutePlanService? routes,
    SalesVisitCopilotService? briefs,
    FirebaseFirestore? firestore,
    bool Function()? isOnline,
  }) : _routes = routes ?? RoutePlanService(),
       _briefs = briefs ?? SalesVisitCopilotService(),
       _db = firestore ?? FirebaseFirestore.instance,
       _isOnline = isOnline ?? _assumeOnline;

  static bool _assumeOnline() => true;

  final UserModel user;
  final bool Function() _isOnline;
  final RoutePlanService _routes;
  final SalesVisitCopilotService _briefs;
  final FirebaseFirestore _db;

  static const Duration _readTimeout = Duration(seconds: 8);

  Future<String> firstBriefRetailer() async {
    if (kBasicEdition) return '';
    final List<VisitBrief> briefs = await _firstNonEmpty(
      _briefs.watchAssignedBriefs(user),
    );
    return briefs.isEmpty ? '' : briefs.first.retailerName;
  }

  Future<CopilotAnswer> answer(CopilotIntent intent) async {
    try {
      switch (intent.kind) {
        case CopilotIntentKind.refuse:
          return kCopilotRefusal;
        case CopilotIntentKind.help:
          return kCopilotHelp;
        case CopilotIntentKind.openPlanner:
          return const CopilotAnswer(
            'Opening your planner.',
            open: CopilotDestination.planner,
          );
        case CopilotIntentKind.openProfile:
          return const CopilotAnswer(
            'Opening your profile.',
            open: CopilotDestination.profile,
          );
        case CopilotIntentKind.openOrders:
          return const CopilotAnswer(
            'Opening your orders.',
            open: CopilotDestination.orders,
          );
        case CopilotIntentKind.openRoute:
          return _route(intent.thisWeek);
        case CopilotIntentKind.nextStop:
          return _nextStop();
        case CopilotIntentKind.stopsLeft:
          return _stopsLeft();
        case CopilotIntentKind.ordersThisWeek:
          return _ordersThisWeek();
        case CopilotIntentKind.visitBrief:
          return _visitBrief(intent.retailer);
        case CopilotIntentKind.lastOrder:
          return _lastOrder(intent.retailer);
        case CopilotIntentKind.sales:
          return _sales(intent.today);
        case CopilotIntentKind.unknown:
          return kCopilotNotUnderstood;
      }
    } catch (_) {
      return const CopilotAnswer(
        'I could not read your data right now. Check your connection and try again.',
        chips: kCopilotStartChips,
      );
    }
  }

  static Future<List<T>> _firstNonEmpty<T>(Stream<List<T>> stream) async {
    try {
      return await stream
          .firstWhere((List<T> items) => items.isNotEmpty)
          .timeout(_readTimeout, onTimeout: () => <T>[]);
    } catch (_) {
      return <T>[];
    }
  }

  Future<List<AssignedRoutePlan>> _plans() async {
    if (_isOnline()) {
      try {
        return await _routes
            .readAssignedPublishedRoutesFromServer(user)
            .timeout(_readTimeout);
      } catch (_) {}
    }
    return _firstNonEmpty(_routes.watchAssignedPublishedRoutes(user));
  }

  Future<RouteProgress?> _progress(AssignedRoutePlan plan) async {
    final bool online = _isOnline();
    RouteProgress? latest;
    try {
      return await _routes
          .watchProgress(planId: plan.id, salesmanUid: user.uid)
          .firstWhere((RouteProgress progress) {
            latest = progress;
            return !online || !progress.isFromCache;
          })
          .then<RouteProgress?>((RouteProgress progress) => progress)
          .timeout(_readTimeout, onTimeout: () => latest);
    } catch (_) {
      return latest;
    }
  }

  String _status(RouteProgress? progress, AssignedRouteStop stop) =>
      progress?.statusFor(stop.stopId, stop.status) ?? stop.status;

  Future<CopilotAnswer> _route(bool thisWeek) async {
    final List<AssignedRoutePlan> plans = await _plans();
    final AssignedRoutePlan? plan = assignedPlanForToday(plans);
    if (plan == null) {
      return const CopilotAnswer(
        'You have no assigned route right now.',
        open: CopilotDestination.route,
      );
    }
    final int weekStops = plan.days.fold<int>(
      0,
      (int total, AssignedRouteDay day) => total + day.stops.length,
    );
    final int todayStops = assignedStopsForToday(plans).length;
    return CopilotAnswer(
      thisWeek
          ? 'Opening your route for this week: $weekStops stops over ${plan.days.length} days.'
          : "Opening today's route: $todayStops stops.",
      open: CopilotDestination.route,
    );
  }

  Future<CopilotAnswer> _nextStop() async {
    final List<AssignedRoutePlan> plans = await _plans();
    final AssignedRoutePlan? plan = assignedPlanForToday(plans);
    final List<AssignedRouteStop> stops = assignedStopsForToday(plans);
    if (plan == null || stops.isEmpty) {
      return const CopilotAnswer(
        'You have no assigned stops today.',
        chips: kCopilotStartChips,
      );
    }
    final RouteProgress? progress = await _progress(plan);
    final List<AssignedRouteStop> ordered = <AssignedRouteStop>[...stops]
      ..sort(
        (AssignedRouteStop a, AssignedRouteStop b) =>
            a.sequence.compareTo(b.sequence),
      );
    for (final AssignedRouteStop stop in ordered) {
      if (isTerminalStopStatus(_status(progress, stop))) continue;
      return CopilotAnswer(
        'Your next stop is ${stop.retailerName}.',
        details: <String>[
          if (stop.address.isNotEmpty) stop.address,
          if (stop.estimatedArrival.isNotEmpty)
            'Expected arrival ${stop.estimatedArrival}',
          if (stop.priorityReason.isNotEmpty) stop.priorityReason,
        ],
        open: CopilotDestination.route,
        openLabel: 'Open route',
        chips: <String>[
          if (!kBasicEdition) 'Show the visit brief for ${stop.retailerName}',
          'How many stops are left today?',
          'Open my route',
        ],
      );
    }
    return const CopilotAnswer(
      "All of today's stops are done.",
      chips: kCopilotStartChips,
    );
  }

  Future<CopilotAnswer> _stopsLeft() async {
    final List<AssignedRoutePlan> plans = await _plans();
    final AssignedRoutePlan? plan = assignedPlanForToday(plans);
    final List<AssignedRouteStop> stops = assignedStopsForToday(plans);
    if (plan == null || stops.isEmpty) {
      return const CopilotAnswer(
        'You have no assigned stops today.',
        chips: kCopilotStartChips,
      );
    }
    final RouteProgress? progress = await _progress(plan);
    final int left = stops
        .where(
          (AssignedRouteStop s) => !isTerminalStopStatus(_status(progress, s)),
        )
        .length;
    return CopilotAnswer(
      '$left of ${stops.length} stops are left today.',
      chips: const <String>[
        'What is my next stop?',
        'Open my route',
        'Open my orders',
      ],
      open: CopilotDestination.route,
      openLabel: 'Open route',
    );
  }

  static DateTime _weekStart(DateTime now) => DateTime(
    now.year,
    now.month,
    now.day,
  ).subtract(Duration(days: now.weekday - 1));

  Future<List<Map<String, dynamic>>> _ordersSince(DateTime start) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _db
        .collection('orders')
        .where('salesmanUid', isEqualTo: user.uid)
        .where('submittedAt', isGreaterThanOrEqualTo: Timestamp.fromDate(start))
        .limit(300)
        .get()
        .timeout(_readTimeout);
    return <Map<String, dynamic>>[
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snapshot.docs)
        if (!(_when(
              doc.data()['submittedAt'] ?? doc.data()['createdAt'],
            )?.isBefore(start) ??
            true))
          doc.data(),
    ];
  }

  Future<CopilotAnswer> _ordersThisWeek() async {
    final Map<String, int> byStatus = <String, int>{};
    double total = 0;
    int count = 0;
    for (final Map<String, dynamic> data in await _ordersSince(
      _weekStart(DateTime.now()),
    )) {
      count += 1;
      final String status = resolveMobileOrderStatus(data);
      byStatus[status] = (byStatus[status] ?? 0) + 1;
      total += dataNumberOrNull(data['totalPrice']) ?? 0;
    }
    return CopilotAnswer(
      count == 0
          ? 'You have no orders this week.'
          : 'You have $count ${count == 1 ? 'order' : 'orders'} this week.',
      details: <String>[
        for (final MapEntry<String, int> entry in byStatus.entries)
          '${entry.key}: ${entry.value}',
        if (total > 0) 'Total RM ${total.toStringAsFixed(2)}',
      ],
      open: CopilotDestination.orders,
      openLabel: 'Open orders',
      chips: const <String>['Open my orders', 'What is my next stop?'],
    );
  }

  Future<CopilotAnswer> _sales(bool today) async {
    final DateTime now = DateTime.now();
    final DateTime start = today
        ? DateTime(now.year, now.month, now.day)
        : _weekStart(now);
    final String period = today ? 'today' : 'this week';
    final Map<String, int> byStatus = <String, int>{};
    double total = 0;
    int count = 0;
    int notCounted = 0;
    for (final Map<String, dynamic> data in await _ordersSince(start)) {
      final String status = resolveMobileOrderStatus(data);
      if (status == 'Cancelled' || status == 'Rejected') {
        notCounted += 1;
        continue;
      }
      count += 1;
      byStatus[status] = (byStatus[status] ?? 0) + 1;
      total += dataNumberOrNull(data['totalPrice']) ?? 0;
    }
    final List<String> chips = <String>[
      today ? 'How much did I sell this week?' : 'How much did I sell today?',
      'Open my orders',
    ];
    if (count == 0) {
      return CopilotAnswer('You have no orders $period.', chips: chips);
    }
    return CopilotAnswer(
      'Your orders $period total RM ${total.toStringAsFixed(2)} '
      '($count ${count == 1 ? 'order' : 'orders'}).',
      details: <String>[
        for (final MapEntry<String, int> entry in byStatus.entries)
          '${entry.key}: ${entry.value}',
        if (notCounted > 0) 'Not counted: $notCounted cancelled or rejected',
      ],
      open: CopilotDestination.orders,
      openLabel: 'Open orders',
      chips: chips,
    );
  }

  Future<CopilotAnswer> _lastOrder(String requested) async {
    final QuerySnapshot<Map<String, dynamic>> snapshot = await _db
        .collection('orders')
        .where('salesmanUid', isEqualTo: user.uid)
        .orderBy('submittedAt', descending: true)
        .limit(200)
        .get()
        .timeout(_readTimeout);
    final String wanted = normaliseCopilotText(requested);
    Map<String, dynamic>? match;
    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
        in snapshot.docs) {
      final Map<String, dynamic> data = doc.data();
      final String status = resolveMobileOrderStatus(data);
      if (status == 'Cancelled' || status == 'Rejected') continue;
      final String name = normaliseCopilotText(
        (data['retailerName'] ?? data['outlet'] ?? '').toString(),
      );
      if (name.isEmpty) continue;
      if (name == wanted ||
          (wanted.length >= 3 &&
              (name.contains(wanted) || wanted.contains(name)))) {
        match = data;
        break;
      }
    }
    if (match == null) {
      return CopilotAnswer(
        'I could not find an order for "$requested" in your recent orders.',
        chips: kCopilotStartChips,
      );
    }
    final String retailer = (match['retailerName'] ?? match['outlet'])
        .toString();
    final DateTime? when = _when(match['submittedAt'] ?? match['createdAt']);
    final List<Object?> items =
        (match['items'] as List<Object?>?) ?? const <Object?>[];
    final double total = dataNumberOrNull(match['totalPrice']) ?? 0;
    return CopilotAnswer(
      when == null
          ? 'Last order for $retailer.'
          : 'Last order for $retailer was on '
                '${DateFormat('d MMM y').format(when)}.',
      details: <String>[
        for (final Object? raw in items.take(5))
          if (raw is Map) _itemLine(raw),
        if (items.length > 5) 'and ${items.length - 5} more',
        if (total > 0) 'Total RM ${total.toStringAsFixed(2)}',
        'Status: ${resolveMobileOrderStatus(match)}',
      ],
      open: CopilotDestination.orders,
      openLabel: 'Open orders',
      chips: <String>[
        if (!kBasicEdition) 'Show the visit brief for $retailer',
        'Open my orders',
      ],
    );
  }

  static String _itemLine(Map<Object?, Object?> item) {
    final Object? name = item['name'] ?? item['productName'];
    final int qty =
        (dataNumberOrNull(
                  item['qty'] ?? item['orderQty'] ?? item['quantity'],
                ) ??
                0)
            .toInt();
    return '${name ?? 'Item'}: '
        '${quantityLabel(qty, uomOf(Map<String, dynamic>.from(item)))}';
  }

  static DateTime? _when(Object? value) {
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    return DateTime.tryParse(value?.toString() ?? '');
  }

  Future<CopilotAnswer> _visitBrief(String requested) async {
    if (kBasicEdition) {
      return const CopilotAnswer(
        kNotInEditionMessage,
        chips: kCopilotStartChips,
      );
    }
    final List<VisitBrief> briefs = await _firstNonEmpty(
      _briefs.watchAssignedBriefs(user),
    );
    final String wanted = normaliseCopilotText(requested);
    VisitBrief? match;
    for (final VisitBrief brief in briefs) {
      final String name = normaliseCopilotText(brief.retailerName);
      if (name == wanted) {
        match = brief;
        break;
      }
      if (match == null &&
          wanted.length >= 3 &&
          (name.contains(wanted) || wanted.contains(name))) {
        match = brief;
      }
    }
    if (match == null) {
      return CopilotAnswer(
        'I could not find a visit brief for "$requested" among your assigned retailers.',
        chips: kCopilotStartChips,
      );
    }
    final List<VisitFocusItem> focus = match.fieldFocusItems;
    return CopilotAnswer(
      'Visit brief for ${match.retailerName}',
      details: focus.isEmpty
          ? <String>[
              if (match.hasNoPriorityIssues) ...<String>[
                match.noPriorityHeadline,
                match.noPriorityBody,
              ] else
                'No focus items in this brief.',
            ]
          : <String>[
              for (final VisitFocusItem item in focus.take(3))
                '${item.title}: ${item.signal}${item.action.isEmpty ? '' : ' Next: ${item.action}'}',
            ],
      chips: const <String>['What is my next stop?', 'Open my route'],
    );
  }
}
