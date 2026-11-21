import 'package:intl/intl.dart';

import '../services/last_order_service.dart';
import '../utils/quantity_unit.dart';
import '../utils/retailer_memory.dart' show reasonCodeLabel;
import 'follow_up_promise.dart';
import 'visit_brief.dart';

const int briefStaleAfterDays = 8;

class BriefFocusView {
  const BriefFocusView({
    required this.position,
    required this.item,
    required this.title,
    required this.previousLine,
    required this.questions,
    required this.moneyLine,
    required this.recordable,
    required this.weeks,
    required this.unit,
  });

  final int position;
  final VisitFocusItem item;
  final String title;
  final String previousLine;
  final List<String> questions;
  final String moneyLine;
  final VisitBriefInsight? recordable;
  final List<BriefWeek> weeks;
  final String unit;
}

class BriefReorderView {
  const BriefReorderView({
    required this.suggestion,
    required this.productName,
    required this.quantity,
    required this.lastOrder,
  });

  final ReplenishmentSuggestion suggestion;
  final String productName;
  final String quantity;
  final String lastOrder;

  String get name => productName.isEmpty ? 'Product with no name' : productName;

  String get line =>
      lastOrder.isEmpty ? 'Suggest $quantity.' : 'Suggest $quantity. $lastOrder';
}

class StopBriefView {
  const StopBriefView({
    required this.brief,
    required this.shopName,
    required this.freshnessLine,
    required this.isStale,
    required this.why,
    required this.focus,
    required this.noFocusHeadline,
    required this.noFocusBody,
    required this.lastOrderLine,
    required this.usualOrderDayLine,
    required this.reorders,
    required this.shopFacts,
    required this.followUp,
    required this.followUpLine,
    required this.canMarkFollowUpDone,
  });

  final VisitBrief brief;
  final String shopName;
  final String freshnessLine;
  final bool isStale;
  final String why;
  final List<BriefFocusView> focus;
  final String noFocusHeadline;
  final String noFocusBody;
  final String lastOrderLine;
  final String usualOrderDayLine;
  final List<BriefReorderView> reorders;
  final List<String> shopFacts;
  final FollowUpPromise? followUp;
  final String followUpLine;
  final bool canMarkFollowUpDone;

  static Map<String, String> productNamesOf(VisitBrief brief) =>
      <String, String>{
        for (final ReplenishmentSuggestion row in brief.replenishment)
          if (row.productId.isNotEmpty && row.productName.isNotEmpty)
            row.productId: row.productName,
        for (final VisitBriefInsight insight in brief.topInsights)
          if (insight.productId.isNotEmpty && insight.productName != 'Product')
            insight.productId: insight.productName,
        for (final VisitFocusItem item in brief.focusItems)
          if (item.productId.isNotEmpty && item.productName.isNotEmpty)
            item.productId: item.productName,
      };

  bool get hasFocusSection => focus.isNotEmpty || noFocusHeadline.isNotEmpty;

  factory StopBriefView.build({
    required VisitBrief brief,
    required String stopReason,
    required LastOrder? lastOrder,
    required DateTime now,
    FollowUpPromise? followUp,
    DateTime? laterOutcomeAt,
  }) {
    final DateTime? updatedAt = brief.updatedAt;
    final int briefAgeDays = updatedAt == null
        ? 0
        : _daysBetween(updatedAt, now);
    final bool stale = updatedAt != null && briefAgeDays > briefStaleAfterDays;
    final Map<String, String> names = productNamesOf(brief);
    final Map<String, String> units = <String, String>{
      for (final ReplenishmentSuggestion row in brief.replenishment)
        if (row.productId.isNotEmpty && row.unitOfMeasure.isNotEmpty)
          row.productId: row.unitOfMeasure,
    };

    final List<VisitBriefInsight> unmatched = brief.topInsights.toList();
    final List<VisitFocusItem> items = brief.fieldFocusItems.toList();
    final List<VisitBriefInsight?> recordables = <VisitBriefInsight?>[
      for (final VisitFocusItem item in items) _takeMatch(unmatched, item),
    ];
    for (final VisitBriefInsight insight in unmatched) {
      items.add(VisitFocusItem.fromLegacyInsight(insight));
      recordables.add(insight);
    }
    final List<BriefFocusView> focus = <BriefFocusView>[
      for (int index = 0; index < items.length; index++)
        BriefFocusView(
          position: index + 1,
          item: items[index],
          title: items[index].title,
          previousLine: _previousLine(items[index]),
          questions: items[index].questions.isNotEmpty
              ? items[index].questions
              : recordables[index]?.questions ?? const <String>[],
          moneyLine: items[index].valueAtRiskRm > 0
              ? '${_rm(items[index].valueAtRiskRm)} at risk'
              : '',
          recordable: recordables[index],
          weeks: stale ? const <BriefWeek>[] : items[index].weeks,
          unit: units[items[index].productId] ?? '',
        ),
    ];

    final List<BriefReorderView> reorders = <BriefReorderView>[
      for (final ReplenishmentSuggestion row in brief.replenishment)
        BriefReorderView(
          suggestion: row,
          productName: names[row.productId] ?? '',
          quantity: briefQuantity(row.suggestedQty, row.unitOfMeasure),
          lastOrder: _reorderLastOrder(
            row,
            briefAgeDays: briefAgeDays,
            lastOrder: lastOrder,
            now: now,
          ),
        ),
    ];

    final RetailerMemoryContext? memory = brief.retailerMemory;
    final List<String> replacementNames = <String>[
      if (memory != null && memory.isActive)
        for (final String id in memory.replacementProductIds)
          if (names[id] case final String name) name,
    ];
    final List<String> shopFacts = <String>[
      if (memory != null && memory.isActive) ...<String>[
        if (memory.commonReasonCodes.isNotEmpty)
          'Reasons given before: '
              '${memory.commonReasonCodes.take(2).map(_sentenceCase).join(', ')}.',
        if (memory.priceSensitivityScore > 0) 'Price matters to this shop.',
        if (memory.seasonalityScore > 0) 'Orders change with the season.',
        if (replacementNames.isNotEmpty)
          'Often replaced by ${replacementNames.join(', ')}.',
      ],
    ];

    final int? weekday = brief.usualOrderWeekday;
    return StopBriefView(
      brief: brief,
      shopName: brief.retailerName,
      freshnessLine: updatedAt == null
          ? ''
          : stale
          ? 'This brief is from ${_day(updatedAt)}. It may be out of date.'
          : 'Updated ${_day(updatedAt)}',
      isStale: stale,
      why: plainStopReason(stopReason),
      focus: focus,
      noFocusHeadline: focus.isEmpty && brief.hasNoPriorityIssues
          ? brief.noPriorityHeadline
          : '',
      noFocusBody: focus.isEmpty && brief.hasNoPriorityIssues
          ? brief.noPriorityBody
          : '',
      lastOrderLine: lastOrder == null ? '' : _lastOrderLine(lastOrder, now),
      usualOrderDayLine: weekday == null
          ? ''
          : 'Usually orders on ${_weekdays[weekday - 1]}.',
      reorders: reorders,
      shopFacts: shopFacts,
      followUp: followUp,
      followUpLine: followUp == null ? '' : followUpPromiseLine(followUp),
      canMarkFollowUpDone:
          followUp != null &&
          visitedAfterPromise(
            followUp,
            lastOrderAt: lastOrder?.orderedAt,
            laterOutcomeAt: laterOutcomeAt,
          ),
    );
  }
}

String followUpPromiseLine(FollowUpPromise promise) {
  final String about = promise.about.trim();
  final String head = 'You said you would come back on ${_day(promise.date)}';
  if (about.isEmpty) return '$head.';
  return RegExp(r'[.!?]$').hasMatch(about)
      ? '$head about $about'
      : '$head about $about.';
}

bool visitedAfterPromise(
  FollowUpPromise promise, {
  required DateTime? lastOrderAt,
  required DateTime? laterOutcomeAt,
}) {
  final DateTime? recordedAt = promise.recordedAt;
  if (laterOutcomeAt != null) return true;
  return recordedAt != null &&
      lastOrderAt != null &&
      lastOrderAt.isAfter(recordedAt);
}

const List<String> _weekdays = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
];

final RegExp _formulaReason = RegExp(
  r'Prioritised:\s*([^.]*)\.?',
  caseSensitive: false,
);
final RegExp _overdueToken = RegExp(r'^overdue (\d+)d$', caseSensitive: false);

List<String> plainStopReasonParts(String stored) {
  final String text = stored.trim();
  if (text.isEmpty) return const <String>[];
  final RegExpMatch? formula = _formulaReason.firstMatch(text);
  if (formula == null) return <String>[text];
  final List<String> tokens = <String>[
    for (final String token in formula.group(1)!.split(','))
      if (token.trim().isNotEmpty) _plainReasonPart(token.trim()),
  ];
  if (tokens.isEmpty) return <String>[text];
  final String before = text.substring(0, formula.start).trim();
  final String after = text.substring(formula.end).trim();
  return <String>[
    if (before.isNotEmpty) before,
    ...tokens,
    if (after.isNotEmpty) after,
  ];
}

String plainStopReason(String stored) {
  final String text = stored.trim();
  if (!_formulaReason.hasMatch(text)) return text;
  return plainStopReasonParts(text)
      .map((String part) => RegExp(r'[.!?]$').hasMatch(part) ? part : '$part.')
      .join(' ');
}

String _plainReasonPart(String part) {
  final Match? overdue = _overdueToken.firstMatch(part);
  if (overdue != null) {
    final int days = int.parse(overdue.group(1)!);
    return 'Overdue $days ${days == 1 ? 'day' : 'days'}';
  }
  switch (part.toLowerCase()) {
    case 'high forecast demand':
      return 'High demand expected';
    case 'high value':
      return 'High value shop';
    case 'balances the weekly workload':
      return 'Fits the plan for this week';
  }
  return part;
}

String briefQuantity(num quantity, String unit) {
  final String number = quantity == quantity.roundToDouble()
      ? quantity.round().toString()
      : quantity.toStringAsFixed(1);
  if (unit.trim().isEmpty) return number;
  return quantity == quantity.roundToDouble()
      ? quantityLabel(quantity.round(), unit)
      : '$number ${quantityLabel(2, unit).substring(2)}';
}

String briefUnitPlural(String unit) =>
    unit.trim().isEmpty ? '' : quantityLabel(2, unit).substring(2);

VisitBriefInsight? _takeMatch(
  List<VisitBriefInsight> insights,
  VisitFocusItem item,
) {
  final int index = insights.indexWhere(
    (VisitBriefInsight insight) => item.issueId.isNotEmpty
        ? insight.issueId == item.issueId
        : insight.issueId.isEmpty &&
              insight.issueKey == item.issueKey &&
              insight.productId == item.productId &&
              insight.type == item.type,
  );
  return index < 0 ? null : insights.removeAt(index);
}

String _previousLine(VisitFocusItem item) {
  final FocusPreviousOutcome? previous = item.previousOutcome;
  if (previous == null || previous.isEmpty) return '';
  final String answer = previous.reasonCode.isEmpty
      ? 'recorded'
      : _sentenceCase(previous.reasonCode).toLowerCase();
  if (item.occurrenceCount > 1) {
    return 'Raised ${item.occurrenceCount} times. Your last answer: $answer.';
  }
  return 'Your last answer: $answer.';
}

String _sentenceCase(String reasonCode) {
  final String label = reasonCodeLabel(reasonCode).toLowerCase();
  return label.isEmpty
      ? label
      : '${label.substring(0, 1).toUpperCase()}${label.substring(1)}';
}

String _reorderLastOrder(
  ReplenishmentSuggestion row, {
  required int briefAgeDays,
  required LastOrder? lastOrder,
  required DateTime now,
}) {
  final int storedDays = row.lastOrderDaysAgo + briefAgeDays;
  if (lastOrder != null) {
    final int ownDays = _daysBetween(lastOrder.orderedAt, now);
    for (final LastOrderLine line in lastOrder.lines) {
      if (line.productId.isNotEmpty &&
          line.productId == row.productId &&
          (row.lastOrderQty < 1 || ownDays <= storedDays)) {
        return 'Last order '
            '${briefQuantity(line.quantity, row.unitOfMeasure)}, '
            '${_ago(ownDays)}.';
      }
    }
  }
  if (row.lastOrderQty < 1) return '';
  return 'Last order '
      '${briefQuantity(row.lastOrderQty, row.unitOfMeasure)}, '
      '${_ago(storedDays)}.';
}

String _lastOrderLine(LastOrder order, DateTime now) {
  const int shownLines = 4;
  final List<String> lines = <String>[
    for (final LastOrderLine line in order.lines.take(shownLines))
      '${line.name} ${briefQuantity(line.quantity, line.uom ?? '')}',
    if (order.lines.length > shownLines)
      'and ${order.lines.length - shownLines} more',
  ];
  final String head =
      'Last order ${_day(order.orderedAt)}, '
      '${_ago(_daysBetween(order.orderedAt, now))}';
  return <String>[
    lines.isEmpty ? '$head.' : '$head: ${lines.join(', ')}.',
    if (order.totalRm > 0) 'RM ${order.totalRm.toStringAsFixed(2)}.',
  ].join(' ');
}

String _ago(int days) {
  if (days <= 0) return 'today';
  return days == 1 ? '1 day ago' : '$days days ago';
}

int _daysBetween(DateTime earlier, DateTime later) {
  final DateTime from = earlier.toLocal();
  final DateTime to = later.toLocal();
  final int days = DateTime.utc(
    to.year,
    to.month,
    to.day,
  ).difference(DateTime.utc(from.year, from.month, from.day)).inDays;
  return days < 0 ? 0 : days;
}

String _day(DateTime date) => DateFormat('d MMM').format(date.toLocal());

String _rm(double amount) => amount == amount.roundToDouble()
    ? 'RM ${amount.toStringAsFixed(0)}'
    : 'RM ${amount.toStringAsFixed(2)}';
