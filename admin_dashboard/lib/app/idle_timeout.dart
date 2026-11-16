import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../services/auth_service.dart';
import '../services/forecast_snapshot_cache.dart';
import '../services/forecast_snapshot_storage.dart';
import 'workspace_runtime.dart';

const int _configuredIdleMinutes = int.fromEnvironment(
  'ADMIN_IDLE_TIMEOUT_MINUTES',
  defaultValue: 30,
);
const Duration kSessionIdleTimeout = Duration(
  minutes: _configuredIdleMinutes > 0 ? _configuredIdleMinutes : 30,
);
const String kAdminLastActivityStorageKey = 'scoot.admin.lastActivityMs';
const String kAdminSessionUidStorageKey = 'scoot.admin.sessionUid';

String adminIdleStorageKey(String base, String? workspace) =>
    workspace == null ? base : '$base.$workspace';

class IdleTimeout extends StatefulWidget {
  const IdleTimeout({
    super.key,
    required this.child,
    required this.onTimeout,
    this.timeout = kSessionIdleTimeout,
    this.authStateChanges,
    this.storage,
  });

  final Widget child;
  final VoidCallback onTimeout;
  final Duration timeout;

  final Stream<User?>? authStateChanges;
  final ForecastSnapshotStorage? storage;

  @override
  State<IdleTimeout> createState() => _IdleTimeoutState();
}

class _IdleTimeoutState extends State<IdleTimeout> with WidgetsBindingObserver {
  static final Set<String?> _expiredScopes = <String?>{};

  late final ForecastSnapshotStorage _storage =
      widget.storage ?? createForecastSnapshotStorage();
  final String? _scope = WorkspaceRuntime.current?.workspace;
  late final String _activityKey = adminIdleStorageKey(
    kAdminLastActivityStorageKey,
    _scope,
  );
  late final String _uidKey = adminIdleStorageKey(
    kAdminSessionUidStorageKey,
    _scope,
  );
  StreamSubscription<User?>? _authSubscription;
  Timer? _timer;
  DateTime _lastActivity = DateTime.now();
  String? _storedUid;
  String? _uid;
  bool _restoring = true;
  late bool _expired = _expiredScopes.contains(_scope);

  Duration get _timeout =>
      widget.timeout > Duration.zero ? widget.timeout : kSessionIdleTimeout;

  @override
  void initState() {
    super.initState();
    try {
      _storedUid = _storage.read(_uidKey);
      final raw = _storage.read(_activityKey);
      if (raw != null) {
        final milliseconds = int.tryParse(raw);
        _lastActivity = milliseconds == null
            ? DateTime.fromMillisecondsSinceEpoch(0)
            : DateTime.fromMillisecondsSinceEpoch(milliseconds);
        if (_lastActivity.isAfter(DateTime.now())) {
          _lastActivity = DateTime.fromMillisecondsSinceEpoch(0);
        }
      }
    } catch (_) {
    }
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _authSubscription =
        (widget.authStateChanges ?? AuthService.instance.authStateChanges())
            .listen(_onAuth);
  }

  void _onAuth(User? user) {
    if (!mounted) return;
    final uid = user?.uid;
    if (!_restoring && uid == _uid) return;
    _timer?.cancel();
    final restored =
        _restoring && uid != null && (_storedUid == null || _storedUid == uid);
    _restoring = false;
    if (uid != null) _expiredScopes.remove(_scope);
    setState(() {
      _uid = uid;
      if (uid != null) _expired = false;
    });
    if (uid == null) {
      _clearStorage();
      return;
    }
    if (restored && _deadlinePassed) {
      _expire();
      return;
    }
    if (!restored) _lastActivity = DateTime.now();
    _persist();
    _schedule();
  }

  bool get _deadlinePassed {
    _adoptActivityFromOtherTabs();
    return DateTime.now().difference(_lastActivity) >= _timeout;
  }

  void _adoptActivityFromOtherTabs() {
    if (_uid == null) return;
    try {
      if (_storage.read(_uidKey) != _uid) return;
      final int? milliseconds = int.tryParse(
        _storage.read(_activityKey) ?? '',
      );
      if (milliseconds == null) return;
      final DateTime shared = DateTime.fromMillisecondsSinceEpoch(
        milliseconds,
      );
      if (shared.isAfter(_lastActivity) && !shared.isAfter(DateTime.now())) {
        _lastActivity = shared;
      }
    } catch (_) {}
  }

  void _persist() {
    try {
      _storage.write(_uidKey, _uid!);
      _storage.write(
        _activityKey,
        _lastActivity.millisecondsSinceEpoch.toString(),
      );
    } catch (_) {
    }
  }

  void _clearStorage() {
    try {
      _storage.remove(_activityKey);
      _storage.remove(_uidKey);
    } catch (_) {
    }
    ForecastSnapshotCache.clearAll(_storage);
  }

  bool _onKey(KeyEvent _) {
    _activity();
    return false;
  }

  void _activity() {
    if (_restoring || _uid == null || _expired) return;
    if (_deadlinePassed) {
      _expire();
      return;
    }
    _lastActivity = DateTime.now();
    _persist();
    _schedule();
  }

  void _schedule() {
    _timer?.cancel();
    _timer = Timer(
      _timeout - DateTime.now().difference(_lastActivity),
      _expire,
    );
  }

  void _expire() {
    if (!mounted || _uid == null || _expired) return;
    _timer?.cancel();
    if (!_deadlinePassed) {
      _schedule();
      return;
    }
    _expiredScopes.add(_scope);
    setState(() => _expired = true);
    widget.onTimeout();
  }

  @override
  void didUpdateWidget(IdleTimeout oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.timeout != widget.timeout &&
        !_restoring &&
        _uid != null &&
        !_expired) {
      if (_deadlinePassed) {
        _expire();
      } else {
        _schedule();
      }
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed &&
        !_restoring &&
        _uid != null &&
        !_expired &&
        _deadlinePassed) {
      _expire();
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    unawaited(_authSubscription?.cancel());
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _activity(),
      onPointerMove: (_) => _activity(),
      onPointerSignal: (_) => _activity(),
      child: Column(
        children: [
          if (_expired)
            Material(
              color: Theme.of(context).colorScheme.errorContainer,
              child: const SafeArea(
                bottom: false,
                child: Padding(
                  padding: EdgeInsets.all(12),
                  child: Text('Session expired. Sign in again.'),
                ),
              ),
            ),
          Expanded(
            child: AbsorbPointer(
              absorbing: _expired && _uid != null,
              child: ExcludeFocus(
                excluding: _expired && _uid != null,
                child: widget.child,
              ),
            ),
          ),
        ],
      ),
    );
  }
}
