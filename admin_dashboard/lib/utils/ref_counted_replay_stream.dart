import 'dart:async';

class RefCountedReplayStream<T> {
  RefCountedReplayStream(
    this._createSource, {
    T Function(T value)? snapshot,
    Duration keepAlive = Duration.zero,
  }) : _snapshot = snapshot ?? _identity,
       _keepAlive = keepAlive {
    _controller = StreamController<T>.broadcast(
      onListen: _handleListen,
      onCancel: _handleCancel,
    );
    _stream = Stream<T>.multi((listener) {
      final int replayRevision = _revision;
      final bool hasLatest = _hasLatest;
      final T? latest = _latest;
      final subscription = _controller.stream.listen(
        listener.add,
        onError: listener.addError,
        onDone: listener.close,
      );
      if (!_disposed && hasLatest && replayRevision == _revision) {
        listener.add(_snapshot(latest as T));
      }
      listener.onCancel = subscription.cancel;
    }, isBroadcast: true);
  }

  final Stream<T> Function() _createSource;
  final T Function(T value) _snapshot;
  final Duration _keepAlive;
  late final StreamController<T> _controller;
  late final Stream<T> _stream;

  StreamSubscription<T>? _subscription;
  Timer? _idleTimer;
  Future<void>? _pendingCancellation;
  T? _latest;
  bool _hasLatest = false;
  bool _disposed = false;
  int _revision = 0;

  Stream<T> get stream => _stream;

  T? get liveLatest {
    if (_disposed || !_hasLatest || _subscription == null) return null;
    return _snapshot(_latest as T);
  }

  void seed(T value) {
    if (_disposed) return;
    _latest = _snapshot(value);
    _hasLatest = true;
    _revision += 1;
    if (_controller.hasListener) {
      _controller.add(_latest as T);
    }
  }

  void _handleListen() {
    if (_disposed) return;

    _idleTimer?.cancel();
    _idleTimer = null;
    _connectSource();
  }

  void _connectSource() {
    if (_disposed ||
        !_controller.hasListener ||
        _subscription != null ||
        _pendingCancellation != null) {
      return;
    }

    _subscription = _createSource().listen(
      seed,
      onError: (Object error, StackTrace stackTrace) {
        _latest = null;
        _hasLatest = false;
        _revision += 1;
        _idleTimer?.cancel();
        _idleTimer = null;
        final StreamSubscription<T>? failedSource = _subscription;
        _subscription = null;
        if (failedSource != null) unawaited(failedSource.cancel());
        if (!_disposed && _controller.hasListener) {
          _controller.addError(error, stackTrace);
        }
      },
      onDone: () => _subscription = null,
    );
  }

  void _handleCancel() {
    if (_keepAlive > Duration.zero && _subscription != null && !_disposed) {
      _idleTimer?.cancel();
      _idleTimer = Timer(_keepAlive, () {
        _idleTimer = null;
        if (!_controller.hasListener) _releaseSource();
      });
      return;
    }
    _releaseSource();
  }

  void _releaseSource() {
    final StreamSubscription<T>? subscription = _subscription;
    _subscription = null;
    if (subscription != null) {
      final Future<void> cancellation = subscription.cancel();
      _pendingCancellation = cancellation;

      void finishCancellation() {
        if (!identical(_pendingCancellation, cancellation)) return;
        _pendingCancellation = null;
        _connectSource();
      }

      unawaited(
        cancellation.then<void>(
          (_) => finishCancellation(),
          onError: (Object _, StackTrace _) => finishCancellation(),
        ),
      );
    }
  }

  Future<void> dispose() async {
    if (_disposed) return;
    _disposed = true;
    _revision += 1;
    _idleTimer?.cancel();
    _idleTimer = null;
    final StreamSubscription<T>? subscription = _subscription;
    _subscription = null;
    await subscription?.cancel();
    final Future<void>? pendingCancellation = _pendingCancellation;
    _pendingCancellation = null;
    if (pendingCancellation != null) {
      try {
        await pendingCancellation;
      } catch (_) {}
    }
    await _controller.close();
  }

  static T _identity<T>(T value) => value;
}
