import 'dart:async';

import 'package:battery_plus/battery_plus.dart';
import 'package:flutter/foundation.dart';

class BatterySaverMonitor extends ChangeNotifier {
  BatterySaverMonitor({
    Future<bool> Function()? probe,
    Stream<Object?> Function()? changes,
  }) : _probe = probe ?? _batteryProbe,
       _changes = changes ?? _batteryChanges;

  static final BatterySaverMonitor instance = BatterySaverMonitor();

  final Future<bool> Function() _probe;
  final Stream<Object?> Function() _changes;
  StreamSubscription<Object?>? _subscription;
  bool _on = false;

  bool get isOn => _on;

  static Future<bool> _batteryProbe() => Battery().isInBatterySaveMode;

  static Stream<Object?> _batteryChanges() => Battery().onBatteryStateChanged;

  void start() {
    _subscription ??= _changes().listen(
      (_) => unawaited(refresh()),
      onError: (_) {},
    );
    unawaited(refresh());
  }

  Future<void> refresh() async {
    bool next;
    try {
      next = await _probe();
    } catch (_) {
      next = false;
    }
    if (next == _on) return;
    _on = next;
    notifyListeners();
  }

  @override
  void dispose() {
    unawaited(_subscription?.cancel());
    super.dispose();
  }
}
