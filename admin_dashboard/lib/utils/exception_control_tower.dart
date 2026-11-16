import '../models/action_centre_item.dart';

enum ExceptionQueueKind {
  routeWorkflow,
  priorityCoverage,
  coverageRecovery,
  commercialRisk,
  dataBlockers,
}

int exceptionTowerColumnCount(double width) {
  if (width >= 760) return 5;
  if (width >= 660) return 3;
  if (width >= 420) return 2;
  return 1;
}

class ExceptionQueue {
  const ExceptionQueue({required this.kind, required this.items});

  final ExceptionQueueKind kind;
  final List<ActionCentreItem> items;

  int get highCount => items
      .where((ActionCentreItem item) => item.priority.toLowerCase() == 'high')
      .length;
}

List<ExceptionQueue> buildExceptionQueues(List<ActionCentreItem> source) {
  final Map<ExceptionQueueKind, List<ActionCentreItem>> grouped =
      <ExceptionQueueKind, List<ActionCentreItem>>{
        for (final ExceptionQueueKind kind in ExceptionQueueKind.values)
          kind: <ActionCentreItem>[],
      };
  for (final ActionCentreItem item in source.where(
    (ActionCentreItem value) => value.isVisible,
  )) {
    grouped[_queueFor(item)]!.add(item);
  }
  for (final List<ActionCentreItem> items in grouped.values) {
    items.sort(_compare);
  }
  return <ExceptionQueue>[
    for (final ExceptionQueueKind kind in ExceptionQueueKind.values)
      ExceptionQueue(
        kind: kind,
        items: List<ActionCentreItem>.unmodifiable(grouped[kind]!),
      ),
  ];
}

ExceptionQueueKind _queueFor(ActionCentreItem item) {
  final String text = '${item.category} ${item.source} ${item.relatedPageKey}'
      .toLowerCase();
  if (text.contains('route workflow') || text.contains('route_planner')) {
    return ExceptionQueueKind.routeWorkflow;
  }
  if (text.contains('data quality') ||
      text.contains('coordinate') ||
      text.contains('identity')) {
    return ExceptionQueueKind.dataBlockers;
  }
  if (text.contains('coverage') ||
      text.contains('retailer visit') ||
      text.contains('salesman follow')) {
    return ExceptionQueueKind.coverageRecovery;
  }
  if (text.contains('priority') || text.contains('unscheduled')) {
    return ExceptionQueueKind.priorityCoverage;
  }
  return ExceptionQueueKind.commercialRisk;
}

int _compare(ActionCentreItem a, ActionCentreItem b) {
  int rank(String value) => switch (value.toLowerCase()) {
    'high' => 0,
    'medium' => 1,
    _ => 2,
  };
  final int priority = rank(a.priority).compareTo(rank(b.priority));
  if (priority != 0) return priority;
  final DateTime oldest = DateTime.fromMillisecondsSinceEpoch(0);
  final int date = (b.createdAt ?? oldest).compareTo(a.createdAt ?? oldest);
  return date != 0 ? date : a.id.compareTo(b.id);
}

String exceptionQueueTitle(ExceptionQueueKind kind) => switch (kind) {
  ExceptionQueueKind.routeWorkflow => 'Route workflow',
  ExceptionQueueKind.priorityCoverage => 'Priority coverage',
  ExceptionQueueKind.coverageRecovery => 'Coverage recovery',
  ExceptionQueueKind.commercialRisk => 'Commercial risk',
  ExceptionQueueKind.dataBlockers => 'Data blockers',
};

String exceptionQueueEmptyText(ExceptionQueueKind kind) => switch (kind) {
  ExceptionQueueKind.routeWorkflow => 'No route approval or publication waits.',
  ExceptionQueueKind.priorityCoverage =>
    'No unscheduled priority exception found.',
  ExceptionQueueKind.coverageRecovery =>
    'No current coverage recovery exception.',
  ExceptionQueueKind.commercialRisk => 'No unresolved commercial risk found.',
  ExceptionQueueKind.dataBlockers =>
    'No detected data blocker in the bounded scan.',
};
