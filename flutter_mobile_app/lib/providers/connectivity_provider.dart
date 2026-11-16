import 'dart:async';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:flutter/material.dart';

typedef ConnectivityCheck = Future<List<ConnectivityResult>> Function();
typedef ConnectivityChanges = Stream<List<ConnectivityResult>> Function();

class ConnectivityProvider extends ChangeNotifier {
  bool _isOnline = true;
  bool get isOnline => _isOnline;
  final ConnectivityCheck _checkConnectivity;
  final ConnectivityChanges _connectivityChanges;
  StreamSubscription<List<ConnectivityResult>>? _connectivitySubscription;
  bool _disposed = false;

  ConnectivityProvider({
    ConnectivityCheck? checkConnectivity,
    ConnectivityChanges? connectivityChanges,
  }) : _checkConnectivity =
           checkConnectivity ?? Connectivity().checkConnectivity,
       _connectivityChanges =
           connectivityChanges ?? (() => Connectivity().onConnectivityChanged) {
    _init();
  }

  bool _hasConnection(List<ConnectivityResult> results) {
    return results.isNotEmpty &&
        results.any((r) => r != ConnectivityResult.none);
  }

  Future<void> _init() async {
    final results = await _checkConnectivity();
    if (_disposed) return;
    _isOnline = _hasConnection(results);
    debugPrint('Initial connectivity: $_isOnline');
    notifyListeners();

    _connectivitySubscription = _connectivityChanges().listen((results) {
      if (_disposed) return;
      final wasOnline = _isOnline;
      _isOnline = _hasConnection(results);
      debugPrint('Connectivity changed: $_isOnline');
      if (_isOnline != wasOnline) notifyListeners();
    });
  }

  @override
  void dispose() {
    _disposed = true;
    unawaited(_connectivitySubscription?.cancel());
    _connectivitySubscription = null;
    super.dispose();
  }
}
