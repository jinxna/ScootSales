import 'dart:async';

import 'package:flutter/foundation.dart';

import 'copilot_client.dart';
import 'copilot_controller.dart';

enum CopilotServerState { off, waking, ready, offline }

const int kCopilotWakeAttempts = 25;
const Duration kCopilotWakeInterval = Duration(seconds: 3);

class CopilotServerStatus extends ValueNotifier<CopilotServerState> {
  CopilotServerStatus(this._server) : super(CopilotServerState.off);

  final CopilotServerClient? _server;

  final CopilotMemory memory = CopilotMemory();
  bool _waking = false;
  bool _disposed = false;

  Future<void> wake() async {
    final CopilotServerClient? server = _server;
    if (server == null || _waking || value == CopilotServerState.ready) return;
    _waking = true;
    _set(CopilotServerState.waking);
    try {
      for (int attempt = 0; attempt < kCopilotWakeAttempts; attempt++) {
        if (await server.isReady()) return _set(CopilotServerState.ready);
        await Future<void>.delayed(kCopilotWakeInterval);
        if (_disposed) return;
      }
      _set(CopilotServerState.offline);
    } finally {
      _waking = false;
    }
  }

  void serverUnreachable() {
    if (_disposed || value != CopilotServerState.ready) return;
    _set(CopilotServerState.offline);
    unawaited(wake());
  }

  void _set(CopilotServerState next) {
    if (!_disposed) value = next;
  }

  @override
  void dispose() {
    _disposed = true;
    super.dispose();
  }
}
