import 'package:intl/intl.dart';
import '../models/assigned_route_plan.dart';

enum AssignedRouteLoadState { loading, error, ready }

AssignedRouteLoadState assignedRouteLoadState({
  required bool isWaiting,
  required bool hasData,
  required bool hasError,
}) {
  if (hasError) return AssignedRouteLoadState.error;
  if (isWaiting && !hasData) return AssignedRouteLoadState.loading;
  return AssignedRouteLoadState.ready;
}

List<AssignedRoutePlan> activeAssignedRouteCandidates(
  List<AssignedRoutePlan> plans, {
  required DateTime now,
}) {
  final today = DateTime(now.year, now.month, now.day);
  final current = <AssignedRoutePlan>[];
  final upcoming = <AssignedRoutePlan>[];

  for (final plan in plans) {
    if (plan.isDemo) continue;
    final start = plan.weekStart;
    final end = plan.weekEnd;
    if (start == null || end == null) continue;
    final startDate = DateTime(start.year, start.month, start.day);
    final endDate = DateTime(end.year, end.month, end.day);
    if (!today.isBefore(startDate) && !today.isAfter(endDate)) {
      current.add(plan);
    } else if (startDate.isAfter(today)) {
      upcoming.add(plan);
    }
  }

  current.sort((a, b) => _start(b).compareTo(_start(a)));
  upcoming.sort((a, b) => _start(a).compareTo(_start(b)));
  return <AssignedRoutePlan>[...current, ...upcoming];
}

bool isTerminalStopStatus(String status) {
  final normalized = status.trim().toLowerCase();
  return normalized == 'completed' || normalized == 'skipped';
}

AssignedRouteStop? selectedPendingRouteStop(
  AssignedRoutePlan plan,
  RouteProgress progress,
) {
  final String selectedStopId = progress.selectedStopId;
  if (selectedStopId.isEmpty) return null;
  for (final AssignedRouteDay day in plan.days) {
    for (final AssignedRouteStop stop in day.stops) {
      if (stop.stopId == selectedStopId &&
          !isTerminalStopStatus(progress.statusFor(stop.stopId, stop.status))) {
        return stop;
      }
    }
  }
  return null;
}

AssignedRouteStop? firstPendingRouteStop(
  AssignedRoutePlan plan,
  RouteProgress progress,
) {
  for (final AssignedRouteDay day in plan.days) {
    for (final AssignedRouteStop stop in day.stops) {
      if (!isTerminalStopStatus(progress.statusFor(stop.stopId, stop.status))) {
        return stop;
      }
    }
  }
  return null;
}

String? routeStopOtherDayLabel(
  AssignedRoutePlan plan,
  AssignedRouteStop stop, {
  DateTime? now,
}) {
  final AssignedRouteDay? today = plan.dayFor(now ?? DateTime.now());
  if (today != null && today.dayId == stop.dayId) return null;
  for (final AssignedRouteDay day in plan.days) {
    if (day.dayId != stop.dayId) continue;
    final DateTime? date = day.date;
    return date == null
        ? (day.dayLabel == 'Day' ? 'another day' : day.dayLabel)
        : '${day.dayLabel} • ${DateFormat('d MMM').format(date)}';
  }
  return null;
}

String suggestedStopHint(
  AssignedRoutePlan plan,
  AssignedRouteStop stop, {
  DateTime? now,
}) {
  final String? otherDay = routeStopOtherDayLabel(plan, stop, now: now);
  if (otherDay == null) {
    return 'Suggested first pending stop. Tap “Go to this stop” to save it as the destination.';
  }
  return 'Suggested first pending stop. It is planned for $otherDay, not today. '
      'To save it as the destination, open the Week tab and tap “Go to this stop”.';
}

bool canAcceptAssignedRoute(String routeStatus) =>
    routeStatus.trim().toLowerCase() == 'assigned';

bool canStartAssignedRoute(
  String routeStatus, {
  DateTime? routeStart,
  DateTime? now,
}) {
  if (routeStatus.trim().toLowerCase() != 'accepted') return false;
  if (routeStart == null) return true;
  final DateTime businessNow = _malaysiaDate(now ?? DateTime.now());
  final DateTime startDate = _malaysiaDate(routeStart);
  return !businessNow.isBefore(startDate);
}

String? startRouteBlockedReason(
  String routeStatus, {
  DateTime? routeStart,
  DateTime? now,
}) {
  if (routeStart == null ||
      routeStatus.trim().toLowerCase() != 'accepted' ||
      canStartAssignedRoute(routeStatus, routeStart: routeStart, now: now)) {
    return null;
  }
  final DateTime startDate = _malaysiaDate(routeStart);
  return 'You can start this route on ${DateFormat('d MMM yyyy').format(startDate)}.';
}

String stopAttentionMessage(String? reason) {
  final String detail = (reason ?? '').trim();
  if (detail == 'The published route assignment changed.') {
    return 'Stop update is saved on this phone. Your manager published this route again, so it cannot be recorded on the new version. Ask your manager.';
  }
  if (detail == 'The stop already has a terminal state.' ||
      detail == 'The stop is no longer pending.') {
    return 'Stop update is saved on this phone. This stop was already closed from another place, so it was not recorded again.';
  }
  return 'Stop update is saved. Sync needs attention before it is recorded.';
}

bool canCompleteAssignedRoute(
  String routeStatus, {
  required bool allStopsHandled,
}) => routeStatus.trim().toLowerCase() == 'in_progress' && allStopsHandled;

bool canUpdateAssignedStop({
  required String routeStatus,
  required String stopStatus,
}) =>
    routeStatus.trim().toLowerCase() == 'in_progress' &&
    !isTerminalStopStatus(stopStatus);

bool allAssignedStopsHandled(AssignedRoutePlan plan, RouteProgress progress) {
  final stops = plan.days.expand((day) => day.stops);
  if (stops.isEmpty) return false;
  return stops.every(
    (stop) =>
        isTerminalStopStatus(progress.statusFor(stop.stopId, stop.status)),
  );
}

DateTime _start(AssignedRoutePlan plan) =>
    plan.weekStart ?? DateTime.fromMillisecondsSinceEpoch(0);

DateTime _malaysiaDate(DateTime value) {
  final DateTime malaysia = value.isUtc
      ? value.toUtc().add(const Duration(hours: 8))
      : value;
  return DateTime(malaysia.year, malaysia.month, malaysia.day);
}
