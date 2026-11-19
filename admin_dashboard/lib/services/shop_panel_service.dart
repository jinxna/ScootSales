import '../models/ai_insight.dart';
import '../models/conversation_outcome.dart';
import '../models/user_profile.dart';
import '../repositories/cms_repository.dart';
import '../utils/count_label.dart';
import '../utils/order_data_utils.dart';
import '../utils/retailer_readiness.dart';
import '../widgets/weekly_bar_chart.dart';
import 'ai_insight_service.dart';
import 'outcome_review_service.dart';
import 'replenishment_service.dart';

class ShopWeeklySeries {
  const ShopWeeklySeries({
    required this.productId,
    required this.productName,
    required this.weeks,
  });

  final String productId;
  final String productName;
  final List<WeeklyQuantity> weeks;

  double get total =>
      weeks.fold<double>(0, (double a, WeeklyQuantity w) => a + w.quantity);

  int get stoppedWeeks => trailingEmptyWeeks(
    weeks.map((WeeklyQuantity w) => w.quantity).toList(growable: false),
  );
}

int trailingEmptyWeeks(List<double> quantities) {
  int count = 0;
  for (int i = quantities.length - 1; i >= 0 && quantities[i] <= 0; i--) {
    count++;
  }
  return count;
}

List<WeeklyQuantity> weeklyQuantitiesFromStored(
  Object? weekStarts,
  Object? quantities,
) {
  if (weekStarts is! List || quantities is! List) {
    return <WeeklyQuantity>[];
  }
  final int length = weekStarts.length < quantities.length
      ? weekStarts.length
      : quantities.length;
  final List<WeeklyQuantity> weeks = <WeeklyQuantity>[];
  for (int i = 0; i < length; i++) {
    final DateTime? start = parseFlexibleDate(weekStarts[i]);
    final Object? raw = quantities[i];
    if (start == null || raw is! num) continue;
    weeks.add(
      WeeklyQuantity(
        weekStart: DateTime(start.year, start.month, start.day),
        quantity: raw.toDouble(),
      ),
    );
  }
  return weeks;
}

List<ShopWeeklySeries> shopSeriesFromPatterns(
  List<Map<String, dynamic>> patterns,
) {
  final List<ShopWeeklySeries> series = <ShopWeeklySeries>[];
  for (final Map<String, dynamic> row in patterns) {
    final List<WeeklyQuantity> weeks = weeklyQuantitiesFromStored(
      row['weekStarts'],
      row['weeklyQuantities'],
    );
    if (weeks.isEmpty) continue;
    final String productId = dataText(row['productId']);
    series.add(
      ShopWeeklySeries(
        productId: productId,
        productName: dataText(row['productName'], fallback: productId),
        weeks: weeks,
      ),
    );
  }
  series.sort(
    (ShopWeeklySeries a, ShopWeeklySeries b) => b.total.compareTo(a.total),
  );
  return series;
}

String shopPanelDateLabel(DateTime day) =>
    '${weeklyChartDayLabel(day)} ${day.year}';

ShopWeeklySeries? stoppedSeriesFromInsight(AiInsight insight) {
  final List<WeeklyQuantity> weeks = weeklyQuantitiesFromStored(
    insight.latestEvidence['weekStarts'],
    insight.latestEvidence['weeklyQuantities'],
  )..sort((WeeklyQuantity a, WeeklyQuantity b) => a.weekStart.compareTo(b.weekStart));
  if (weeks.isEmpty) return null;
  return ShopWeeklySeries(
    productId: insight.productId,
    productName: insight.productName,
    weeks: weeks,
  );
}

String stoppedWeeksPhrase(ShopWeeklySeries? evidence) {
  if (evidence == null || evidence.stoppedWeeks == 0) return '';
  final DateTime lastDay = evidence.weeks.last.weekStart.add(
    const Duration(days: 6),
  );
  return ' in the ${countLabel(evidence.stoppedWeeks, 'week')} to '
      '${shopPanelDateLabel(lastDay)}';
}

String shopPanelDateKeyLabel(String key) {
  final DateTime? parsed = DateTime.tryParse(key);
  return parsed == null ? key : shopPanelDateLabel(parsed);
}

String retailerRowId(Map<String, dynamic> row) =>
    dataText(row['retailerId'] ?? row['docId'] ?? row['id']);

class ShopPanelData {
  const ShopPanelData({
    required this.retailerName,
    required this.series,
    required this.stoppedEvidence,
    required this.lastVisit,
    required this.lastOrderAmount,
    required this.lastOrderAt,
    required this.followUp,
    required this.salesperson,
    required this.pin,
    required this.failed,
    this.tooManyOrders = false,
  });

  final String retailerName;
  final List<ShopWeeklySeries> series;
  final Map<String, ShopWeeklySeries?> stoppedEvidence;
  final bool tooManyOrders;

  ShopWeeklySeries seriesToShow(ShopWeeklySeries series) =>
      stoppedEvidence[series.productId] ?? series;
  final DateTime? lastVisit;
  final double? lastOrderAmount;
  final DateTime? lastOrderAt;
  final ConversationOutcome? followUp;
  final String salesperson;
  final CoordinateStatus? pin;
  final Set<String> failed;
}

const int _orderLimit = 500;
const int _visitLimit = 500;

class ShopPanelService {
  ShopPanelService({
    CmsRepository? repository,
    ReplenishmentService? replenishment,
    AiInsightService? insights,
    OutcomeReviewService? outcomes,
  }) : _repository = repository ?? CmsRepository(),
       _replenishment = replenishment ?? ReplenishmentService(),
       _insights = insights ?? AiInsightService(),
       _outcomes = outcomes ?? OutcomeReviewService();

  final CmsRepository _repository;
  final ReplenishmentService _replenishment;
  final AiInsightService _insights;
  final OutcomeReviewService _outcomes;

  Future<ShopPanelData> load(
    UserProfile user,
    String retailerId,
    String fallbackName,
  ) async {
    final Set<String> failed = <String>{};
    final List<String> patternFailures = <String>[];
    final List<String> orderFailures = <String>[];

    Future<T?> guarded<T>(String source, Future<T> Function() read) async {
      try {
        return await read();
      } catch (_) {
        failed.add(source);
        return null;
      }
    }

    final List<Object?> results = await Future.wait(<Future<Object?>>[
      _replenishment.loadRetailerItemPatterns(
        user,
        retailerId,
        failedSources: patternFailures,
      ),
      _replenishment.loadRetailerOrders(
        user,
        retailerId,
        limit: _orderLimit,
        failedSources: orderFailures,
      ),
      guarded<List<AiInsight>>(
        'insights',
        () => _insights.watchInsights(user).first,
      ),
      guarded<List<ConversationOutcome>?>(
        'follow-ups',
        () => _outcomes.loadOpenDatedFollowUps(user),
      ),
      guarded<List<Map<String, dynamic>>>(
        'visits',
        () => _repository.getCollectionOnce(
          'visit_logs',
          orderBy: 'arrivalTime',
          descending: true,
          limit: _visitLimit,
        ),
      ),
      guarded<List<Map<String, dynamic>>>(
        'shops',
        () => _repository.getRetailerDirectory(limit: 2000),
      ),
      guarded<List<Map<String, dynamic>>>(
        'people',
        () => _repository.getCollectionOnce('users', limit: 1000),
      ),
    ]);
    if (patternFailures.isNotEmpty) failed.add('weekly orders');
    if (orderFailures.isNotEmpty) failed.add('orders');

    final List<Map<String, dynamic>> patterns =
        results[0] as List<Map<String, dynamic>>;
    final List<Map<String, dynamic>> orders =
        results[1] as List<Map<String, dynamic>>;
    final List<AiInsight> insights =
        (results[2] as List<AiInsight>?) ?? const <AiInsight>[];
    final List<ConversationOutcome>? followUps =
        results[3] as List<ConversationOutcome>?;
    if (results[3] == null && !failed.contains('follow-ups')) {
      failed.add('follow-ups');
    }
    final List<Map<String, dynamic>> visits =
        (results[4] as List<Map<String, dynamic>>?) ??
        const <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> shops =
        (results[5] as List<Map<String, dynamic>>?) ??
        const <Map<String, dynamic>>[];
    final List<Map<String, dynamic>> people =
        (results[6] as List<Map<String, dynamic>>?) ??
        const <Map<String, dynamic>>[];

    Map<String, dynamic>? shop;
    for (final Map<String, dynamic> row in shops) {
      if (retailerRowId(row) == retailerId) {
        shop = row;
        break;
      }
    }

    DateTime? lastVisit;
    for (final Map<String, dynamic> row in visits) {
      if (dataText(row['retailerId']) != retailerId) continue;
      final DateTime? at = visitDateFromRow(row);
      if (at != null && (lastVisit == null || at.isAfter(lastVisit))) {
        lastVisit = at;
      }
    }

    double? lastOrderAmount;
    DateTime? lastOrderAt;
    Map<String, dynamic>? newestOrder;
    int datedOrders = 0;
    for (final Map<String, dynamic> order in orders) {
      final DateTime? at = orderDateFromRow(order);
      if (at == null) continue;
      datedOrders++;
      if (lastOrderAt == null || at.isAfter(lastOrderAt)) {
        lastOrderAt = at;
        newestOrder = order;
      }
    }
    if (newestOrder != null) lastOrderAmount = orderRevenue(newestOrder);
    final bool tooManyOrders =
        !failed.contains('orders') && orders.length >= _orderLimit;
    if (!failed.contains('orders') &&
        !tooManyOrders &&
        orders.isNotEmpty &&
        datedOrders == 0) {
      failed.add('orders');
    }

    if (lastVisit == null && visits.length >= _visitLimit) {
      failed.add('visits');
    }

    ConversationOutcome? followUp;
    for (final ConversationOutcome outcome
        in followUps ?? const <ConversationOutcome>[]) {
      if (outcome.retailerId == retailerId) {
        followUp = outcome;
        break;
      }
    }

    final Map<String, ShopWeeklySeries?> stopped = <String, ShopWeeklySeries?>{
      for (final AiInsight insight in insights)
        if (insight.retailerId == retailerId &&
            insight.type == 'stopped_product' &&
            insight.isActive)
          insight.productId: stoppedSeriesFromInsight(insight),
    };

    final String code = dataText(
      shop == null
          ? null
          : pickFirst(shop, const <String>[
              'assignedSalesmanCode',
              'assignedSalesmanId',
              'salesmanCode',
            ]),
    );
    String salesperson = code;
    for (final Map<String, dynamic> person in people) {
      final String personCode = dataText(
        pickFirst(person, const <String>[
          'salesmanCode',
          'employeeCode',
          'userId',
        ]),
      );
      if (code.isNotEmpty && personCode == code) {
        salesperson = dataText(person['name'], fallback: code);
        break;
      }
    }

    return ShopPanelData(
      retailerName: shop == null
          ? fallbackName
          : dataText(
              pickFirst(shop, const <String>['retailerName', 'name']),
              fallback: fallbackName,
            ),
      series: shopSeriesFromPatterns(patterns),
      stoppedEvidence: stopped,
      tooManyOrders: tooManyOrders,
      lastVisit: lastVisit,
      lastOrderAmount: lastOrderAmount,
      lastOrderAt: lastOrderAt,
      followUp: followUp,
      salesperson: salesperson,
      pin: shop == null ? null : retailerCoordinateStatus(shop),
      failed: failed,
    );
  }
}
