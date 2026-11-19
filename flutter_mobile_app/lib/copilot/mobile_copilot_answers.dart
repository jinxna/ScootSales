import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:intl/intl.dart';

import '../edition.dart';
import '../models/assigned_route_plan.dart';
import '../models/follow_up_promise.dart';
import '../models/stop_brief_view.dart' show plainStopReasonParts;
import '../models/user_model.dart';
import '../models/visit_brief.dart';
import '../screens/overview_screen.dart'
    show assignedPlanForToday, assignedStopsForToday;
import '../services/follow_up_service.dart';
import '../services/last_order_service.dart';
import '../services/route_plan_service.dart';
import '../services/sales_visit_copilot_service.dart';
import '../utils/assigned_route_lifecycle.dart' show isTerminalStopStatus;
import '../utils/order_status.dart';
import 'mobile_copilot_grammar.dart';
import 'mobile_copilot_shop_facts.dart';
import '../utils/data_number.dart';

enum CopilotDestination { route, orders, planner, profile }

class CopilotAnswer {
  const CopilotAnswer(
    this.text, {
    this.details = const <String>[],
    this.open,
    this.openLabel = '',
    this.refused = false,
    this.chips = const <String>[],
    this.remember,
  });

  final String text;
  final List<String> details;

  final CopilotDestination? open;
  final String openLabel;
  final bool refused;

  final List<String> chips;

  final ScoutMemory? remember;
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

const CopilotAnswer kCopilotWhichShop = CopilotAnswer(
  'Which shop do you mean?',
  details: <String>['Say the shop name. Example: Why am I going to <shop>?'],
  chips: kCopilotStartChips,
);

const CopilotAnswer kCopilotHelp = CopilotAnswer(
  kBasicEdition
      ? 'Ask about your own route and orders. On some screens I can '
            'also do small tasks. I ask you before I change anything.'
      : 'Ask about your own route, orders and visit briefs. On some screens I can '
            'also do small tasks. I ask you before I change anything.',
  details: <String>[
    'Route: What is my next stop? How many stops are left today? Why am I going to <shop>?',
    if (!kBasicEdition)
      'Shop: What should I say at <shop>? When does <shop> usually order? Show the visit brief for <shop>',
    'Orders: What did <shop> order last time? How much did I sell today? This week?',
    'Follow-ups: Who did I promise to visit again?',
    if (kBasicEdition)
      'After an answer you can ask: What did they order last time? And the next one?'
    else
      'After an answer you can ask: What should I say there? And the next one?',
    'Open: my route, orders, planner or profile',
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
  static const Duration _briefGlance = Duration(seconds: 2);
  static const Set<CopilotIntentKind> _briefTopics = <CopilotIntentKind>{
    CopilotIntentKind.whatToSay,
    CopilotIntentKind.visitBrief,
    CopilotIntentKind.usualOrderDay,
  };

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
          return await _route(intent.thisWeek);
        case CopilotIntentKind.nextStop:
          return await _nextStop(
            after: intent.nextOne ? intent.remembered : null,
          );
        case CopilotIntentKind.stopsLeft:
          return await _stopsLeft();
        case CopilotIntentKind.ordersThisWeek:
          return await _ordersThisWeek();
        case CopilotIntentKind.visitBrief:
        case CopilotIntentKind.lastOrder:
        case CopilotIntentKind.whyStop:
        case CopilotIntentKind.whatToSay:
        case CopilotIntentKind.usualOrderDay:
          return await _shopAnswer(intent);
        case CopilotIntentKind.followUps:
          return await _followUps();
        case CopilotIntentKind.followUp:
          return _shopMenu(intent.retailer);
        case CopilotIntentKind.whichShop:
          return kCopilotWhichShop;
        case CopilotIntentKind.sales:
          return await _sales(intent.today);
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

  static Future<List<T>> _firstNonEmpty<T>(
    Stream<List<T>> stream, [
    Duration wait = _readTimeout,
  ]) async {
    try {
      return await stream
          .firstWhere((List<T> items) => items.isNotEmpty)
          .timeout(wait, onTimeout: () => <T>[]);
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

  Future<CopilotAnswer> _nextStop({ScoutShop? after}) async {
    final List<AssignedRoutePlan> plans = await _plans();
    final AssignedRoutePlan? plan = assignedPlanForToday(plans);
    final List<AssignedRouteStop> stops = assignedStopsForToday(plans);
    if (plan == null || stops.isEmpty) {
      return const CopilotAnswer(
        'You have no assigned stops today.',
        chips: kCopilotStartChips,
      );
    }
    final List<AssignedRouteStop> ordered = <AssignedRouteStop>[...stops]
      ..sort(
        (AssignedRouteStop a, AssignedRouteStop b) =>
            a.sequence.compareTo(b.sequence),
      );
    AssignedRouteStop? next;
    if (after != null) {
      final int at = ordered.indexWhere(
        (AssignedRouteStop stop) =>
            ScoutShopBook.sameShop(after, stop.retailerId, stop.retailerName),
      );
      if (at < 0) {
        return CopilotAnswer(
          '${after.name} is not on your route today.',
          chips: kCopilotStartChips,
        );
      }
      if (at + 1 >= ordered.length) {
        return CopilotAnswer(
          '${after.name} is the last stop today.',
          chips: kCopilotStartChips,
        );
      }
      next = ordered[at + 1];
    } else {
      final RouteProgress? progress = await _progress(plan);
      for (final AssignedRouteStop stop in ordered) {
        if (isTerminalStopStatus(_status(progress, stop))) continue;
        next = stop;
        break;
      }
    }
    if (next == null) {
      return const CopilotAnswer(
        "All of today's stops are done.",
        chips: kCopilotStartChips,
      );
    }
    final ScoutShop shop = ScoutShop(
      id: next.retailerId,
      name: next.retailerName,
    );
    final VisitBrief? brief = kBasicEdition
        ? null
        : ScoutShopBook.briefFor(await _briefList(_briefGlance), shop);
    final List<String> reason = plainStopReasonParts(next.priorityReason);
    final List<VisitFocusItem> focus =
        brief?.fieldFocusItems ?? const <VisitFocusItem>[];
    return CopilotAnswer(
      after == null
          ? 'Your next stop is ${next.retailerName}.'
          : 'After ${after.name}, the next stop is ${next.retailerName}.',
      details: <String>[
        if (next.address.isNotEmpty) next.address,
        if (next.estimatedArrival.isNotEmpty)
          'Expected arrival ${next.estimatedArrival}',
        if (reason.isNotEmpty) 'Why: ${reason.join(', ')}',
        if (focus.isNotEmpty) 'Focus: ${_focusLine(focus.first)}',
      ],
      open: CopilotDestination.route,
      openLabel: 'Open route',
      chips: <String>[
        if (!kBasicEdition) 'Show the visit brief for ${next.retailerName}',
        'How many stops are left today?',
        'Open my route',
      ],
      remember: ScoutMemory(shop: shop, topic: CopilotIntentKind.nextStop),
    );
  }

  static String _focusLine(VisitFocusItem item) =>
      item.signal.isEmpty ? item.title : '${item.title}: ${item.signal}';

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

  Future<List<VisitBrief>> _briefList(Duration wait) =>
      _firstNonEmpty(_briefs.watchAssignedBriefs(user), wait);

  static String _questionFor(CopilotIntentKind kind, String shop) =>
      switch (kind) {
        CopilotIntentKind.whatToSay => 'What should I say at $shop?',
        CopilotIntentKind.visitBrief => 'Show the visit brief for $shop',
        CopilotIntentKind.lastOrder => 'What did $shop order last time?',
        CopilotIntentKind.usualOrderDay => 'When does $shop usually order?',
        _ => 'Why am I going to $shop?',
      };

  static String _notFound(
    CopilotIntentKind kind,
    String spoken,
  ) => switch (kind) {
    CopilotIntentKind.lastOrder =>
      'I could not find an order for "$spoken" in your recent orders.',
    CopilotIntentKind.visitBrief || CopilotIntentKind.whatToSay =>
      'I could not find a visit brief for "$spoken" among your assigned retailers.',
    CopilotIntentKind.whyStop => 'I could not find "$spoken" on your route.',
    _ => 'I could not find a shop called "$spoken".',
  };

  static List<String> _afterShopChips(CopilotIntentKind asked) => <String>[
    if (asked != CopilotIntentKind.whyStop) 'Why this stop?',
    if (!kBasicEdition && asked != CopilotIntentKind.whatToSay)
      'What should I say there?',
    if (asked != CopilotIntentKind.lastOrder) 'What did they order last time?',
    'And the next one?',
  ];

  CopilotAnswer _shopMenu(String spoken) => CopilotAnswer(
    'What do you want to know about "$spoken"?',
    chips: <String>[
      _questionFor(CopilotIntentKind.whyStop, spoken),
      if (!kBasicEdition) _questionFor(CopilotIntentKind.whatToSay, spoken),
      _questionFor(CopilotIntentKind.lastOrder, spoken),
    ],
  );

  Future<CopilotAnswer> _shopAnswer(CopilotIntent intent) async {
    final CopilotIntentKind kind = intent.kind;
    if (kBasicEdition && _briefTopics.contains(kind)) {
      return const CopilotAnswer(
        kNotInEditionMessage,
        chips: kCopilotStartChips,
      );
    }
    final Future<List<AssignedRoutePlan>> plansRead = _plans();
    final Future<List<VisitBrief>> briefsRead = kBasicEdition
        ? Future<List<VisitBrief>>.value(const <VisitBrief>[])
        : _briefList(_briefTopics.contains(kind) ? _readTimeout : _briefGlance);
    final Future<Map<String, LastOrder>> ordersRead = LastOrderService(
      firestore: _db,
    ).lastOrders(user.uid, online: _isOnline());
    final (
      List<AssignedRoutePlan> plans,
      List<VisitBrief> briefs,
      Map<String, LastOrder> orders,
    ) = await (
      plansRead,
      briefsRead,
      ordersRead,
    ).wait;
    final ScoutShopBook book = ScoutShopBook(
      plan: assignedPlanForToday(plans),
      today: DateTime.now(),
      briefs: briefs,
      lastOrders: orders,
    );

    ScoutShop shop;
    final ScoutShop? remembered = intent.remembered;
    if (remembered != null && intent.nextOne) {
      if (!book.isOnTodayRoute(remembered)) {
        return CopilotAnswer(
          '${remembered.name} is not on your route today.',
          chips: kCopilotStartChips,
        );
      }
      final AssignedRouteStop? next = book.stopAfter(remembered);
      if (next == null) {
        return CopilotAnswer(
          '${remembered.name} is the last stop today.',
          chips: kCopilotStartChips,
        );
      }
      shop = book.shopOf(next);
    } else if (remembered != null) {
      shop = remembered;
    } else {
      final ShopMatch match = book.find(intent.retailer);
      switch (match) {
        case ShopFound():
          shop = match.shop;
        case ShopAmbiguous():
          return CopilotAnswer(
            'Which shop do you mean?',
            details: <String>[
              for (final ScoutShop one in match.shops.take(6)) one.name,
            ],
            chips: <String>[
              for (final ScoutShop one in match.shops.take(3))
                _questionFor(kind, one.name),
            ],
          );
        case ShopMissing():
          return CopilotAnswer(
            _notFound(kind, intent.retailer),
            chips: kCopilotStartChips,
          );
      }
    }

    final ShopFacts facts = book.facts(shop);
    final ScoutMemory memory = ScoutMemory(shop: shop, topic: kind);
    switch (kind) {
      case CopilotIntentKind.whyStop:
        return _whyStop(facts, memory);
      case CopilotIntentKind.whatToSay:
        return _whatToSay(facts, memory);
      case CopilotIntentKind.visitBrief:
        return _visitBrief(facts, memory);
      case CopilotIntentKind.usualOrderDay:
        return _usualOrderDay(facts, memory);
      default:
        return _lastOrder(facts, memory);
    }
  }

  CopilotAnswer _whyStop(ShopFacts facts, ScoutMemory memory) {
    final String name = facts.shop.name;
    final AssignedRouteStop? stop = facts.stop;
    if (stop == null) {
      return CopilotAnswer(
        '$name is not on your route.',
        chips: _afterShopChips(CopilotIntentKind.whyStop),
        remember: memory,
      );
    }
    final DateTime? date = facts.stopDay?.date;
    final String day = facts.stopIsToday
        ? 'today'
        : date != null
        ? 'on ${DateFormat('EEEE d MMM').format(date)}'
        : 'this week';
    final List<String> reason = plainStopReasonParts(stop.priorityReason);
    return CopilotAnswer(
      reason.isEmpty
          ? '$name is on your route $day. No reason is saved for this stop.'
          : '$name is on your route $day for this reason.',
      details: reason,
      open: CopilotDestination.route,
      openLabel: 'Open route',
      chips: _afterShopChips(CopilotIntentKind.whyStop),
      remember: memory,
    );
  }

  CopilotAnswer _whatToSay(ShopFacts facts, ScoutMemory memory) {
    final String name = facts.shop.name;
    final VisitBrief? brief = facts.brief;
    if (brief == null) {
      return CopilotAnswer(
        _notFound(CopilotIntentKind.whatToSay, name),
        chips: _afterShopChips(CopilotIntentKind.whatToSay),
        remember: memory,
      );
    }
    final List<VisitFocusItem> focus = brief.fieldFocusItems;
    if (focus.isEmpty) {
      return CopilotAnswer(
        'There is no special point to raise at $name.',
        details: _noFocusLines(brief),
        chips: _afterShopChips(CopilotIntentKind.whatToSay),
        remember: memory,
      );
    }
    return CopilotAnswer(
      focus.length == 1
          ? 'At $name, talk about this point.'
          : 'At $name, talk about these points.',
      details: <String>[
        for (final VisitFocusItem item in focus.take(3)) ...<String>[
          _focusLine(item),
          for (final String question in item.questions) 'Ask: $question',
          if (item.action.isNotEmpty) 'Next: ${item.action}',
        ],
      ],
      chips: _afterShopChips(CopilotIntentKind.whatToSay),
      remember: memory,
    );
  }

  static List<String> _noFocusLines(VisitBrief brief) => <String>[
    if (brief.hasNoPriorityIssues) ...<String>[
      brief.noPriorityHeadline,
      brief.noPriorityBody,
    ] else
      'No focus items in this brief.',
  ];

  CopilotAnswer _visitBrief(ShopFacts facts, ScoutMemory memory) {
    final String name = facts.shop.name;
    final VisitBrief? brief = facts.brief;
    if (brief == null) {
      return CopilotAnswer(
        _notFound(CopilotIntentKind.visitBrief, name),
        chips: kCopilotStartChips,
        remember: memory,
      );
    }
    final List<VisitFocusItem> focus = brief.fieldFocusItems;
    final ({String freshness, List<String> reorders}) stored = scoutBriefFacts(
      brief,
      lastOrder: facts.lastOrder,
      now: DateTime.now(),
    );
    return CopilotAnswer(
      'Visit brief for ${brief.retailerName}',
      details: <String>[
        if (stored.freshness.isNotEmpty) stored.freshness,
        if (focus.isEmpty)
          ..._noFocusLines(brief)
        else
          for (final VisitFocusItem item in focus.take(3))
            '${item.title}: ${item.signal}${item.action.isEmpty ? '' : ' Next: ${item.action}'}',
        ...stored.reorders,
      ],
      chips: const <String>[
        'What should I say there?',
        'What did they order last time?',
        'What is my next stop?',
      ],
      remember: memory,
    );
  }

  CopilotAnswer _usualOrderDay(ShopFacts facts, ScoutMemory memory) {
    final String name = facts.shop.name;
    final VisitBrief? brief = facts.brief;
    final String? day = brief == null
        ? null
        : scoutUsualOrderDay(brief.usualOrderWeekday);
    return CopilotAnswer(
      day == null
          ? 'I do not have a usual order day for $name yet.'
          : '$name usually orders on $day.',
      chips: _afterShopChips(CopilotIntentKind.usualOrderDay),
      remember: memory,
    );
  }

  CopilotAnswer _lastOrder(ShopFacts facts, ScoutMemory memory) {
    final LastOrder? match = facts.lastOrder;
    if (match == null) {
      return CopilotAnswer(
        _notFound(CopilotIntentKind.lastOrder, facts.shop.name),
        chips: kCopilotStartChips,
        remember: memory,
      );
    }
    final String retailer = match.retailerName.isEmpty
        ? facts.shop.name
        : match.retailerName;
    final DateTime when = match.orderedAt.toLocal();
    return CopilotAnswer(
      'Last order for $retailer was on '
      '${DateFormat('d MMM y').format(when)}, '
      '${scoutDaysAgo(when, DateTime.now())}.',
      details: <String>[
        ...scoutLastOrderLines(match),
        if (match.totalRm > 0) 'Total RM ${match.totalRm.toStringAsFixed(2)}',
        if (match.status.isNotEmpty) 'Status: ${match.status}',
      ],
      open: CopilotDestination.orders,
      openLabel: 'Open orders',
      chips: <String>[
        if (!kBasicEdition) 'Show the visit brief for $retailer',
        'Open my orders',
      ],
      remember: memory,
    );
  }

  Future<CopilotAnswer> _followUps() async {
    final List<FollowUpPromise> open = await FollowUpService(
      firestore: _db,
    ).openPromises(user.uid, online: _isOnline());
    if (open.isEmpty) {
      return const CopilotAnswer(
        'You have no open follow-ups.',
        chips: kCopilotStartChips,
      );
    }
    final DateTime now = DateTime.now();
    return CopilotAnswer(
      open.length == 1
          ? 'You have 1 open follow-up.'
          : 'You have ${open.length} open follow-ups.',
      details: <String>[
        for (final FollowUpPromise one in open.take(8))
          '${scoutDayMonth(one.date, now)}: ${one.shop}'
              '${one.about.isEmpty ? '' : ', ${one.about}'}',
        if (open.length > 8) 'and ${open.length - 8} more',
      ],
      chips: const <String>['What is my next stop?', 'Open my route'],
    );
  }

  static DateTime? _when(Object? value) => scoutWhen(value);
}
