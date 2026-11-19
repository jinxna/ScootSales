import 'dart:async';

import 'package:flutter/foundation.dart';

import '../../../../models/route_plan.dart';

enum RouteRoadState { settled, updating, failed }

bool routeDayHasRoadMetrics(RouteDay day) =>
    day.estimateSource == 'geoapify_routing' ||
    day.estimateSource == 'geoapify_matrix';

bool routeDayNeedsRoad(RouteDay day, {required RouteStartPoint? start}) =>
    day.stops.length + (start == null ? 0 : 1) >= 2;

class RouteRoadRefresher extends ChangeNotifier {
  RouteRoadRefresher({
    required this.fetch,
    required this.currentDay,
    required this.onRoad,
    required this.onFailure,
    this.delay = const Duration(milliseconds: 600),
  });

  final Future<RouteDay> Function(RouteDay day) fetch;
  final RouteDay? Function(String dayId) currentDay;
  final void Function(RouteDay road) onRoad;
  final void Function(String dayId, Object error, StackTrace stackTrace)
  onFailure;
  final Duration delay;

  final Map<String, Timer> _timers = <String, Timer>{};
  final Map<String, int> _tickets = <String, int>{};
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};
  final Map<String, RouteDay> _lastRoad = <String, RouteDay>{};
  final Set<String> _failed = <String>{};
  bool _disposed = false;

  RouteRoadState stateOf(String dayId) {
    if (_timers.containsKey(dayId) || _inFlight.containsKey(dayId)) {
      return RouteRoadState.updating;
    }
    return _failed.contains(dayId)
        ? RouteRoadState.failed
        : RouteRoadState.settled;
  }

  RouteDay? lastRoadDay(String dayId) =>
      stateOf(dayId) == RouteRoadState.updating ? _lastRoad[dayId] : null;

  bool get busy => _timers.isNotEmpty || _inFlight.isNotEmpty;

  void schedule(RouteDay before) {
    final String id = before.dayId;
    if (routeDayHasRoadMetrics(before)) _lastRoad.putIfAbsent(id, () => before);
    _failed.remove(id);
    _timers.remove(id)?.cancel();
    final int ticket = _nextTicket(id);
    _timers[id] = Timer(delay, () => _run(id, ticket));
    notifyListeners();
  }

  void retry(String dayId) {
    _failed.remove(dayId);
    _timers.remove(dayId)?.cancel();
    _run(dayId, _nextTicket(dayId));
    notifyListeners();
  }

  Future<void> flush() async {
    final List<String> waiting = _timers.keys.toList();
    for (final String id in waiting) {
      _timers.remove(id)!.cancel();
      _run(id, _tickets[id]!);
    }
    await Future.wait(_inFlight.values.toList());
  }

  void reset() {
    for (final Timer timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    for (final String id in _tickets.keys.toList()) {
      _nextTicket(id);
    }
    _inFlight.clear();
    _lastRoad.clear();
    _failed.clear();
    notifyListeners();
  }

  int _nextTicket(String id) => _tickets[id] = (_tickets[id] ?? 0) + 1;

  void _run(String id, int ticket) {
    _timers.remove(id);
    final RouteDay? day = currentDay(id);
    if (day == null || day.stops.isEmpty) {
      _lastRoad.remove(id);
      _inFlight.remove(id);
      _notify();
      return;
    }
    final Completer<void> done = Completer<void>();
    _inFlight[id] = done.future;
    _notify();
    fetch(day)
        .then(
          (RouteDay road) {
            if (_tickets[id] != ticket || _disposed) return;
            _lastRoad.remove(id);
            _inFlight.remove(id);
            onRoad(road);
          },
          onError: (Object error, StackTrace stackTrace) {
            if (_tickets[id] != ticket || _disposed) return;
            _lastRoad.remove(id);
            _inFlight.remove(id);
            _failed.add(id);
            onFailure(id, error, stackTrace);
          },
        )
        .whenComplete(() {
          if (_tickets[id] == ticket) _inFlight.remove(id);
          done.complete();
          _notify();
        });
  }

  void _notify() {
    if (!_disposed) notifyListeners();
  }

  @override
  void dispose() {
    _disposed = true;
    for (final Timer timer in _timers.values) {
      timer.cancel();
    }
    _timers.clear();
    super.dispose();
  }
}
