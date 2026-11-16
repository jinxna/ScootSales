import 'dart:async';

import 'package:flutter/widgets.dart';

import '../models/company_lifecycle.dart';
import 'company_api.dart';
import 'held_work_sync.dart';

class CompanyLifecycleMonitor extends ChangeNotifier
    with WidgetsBindingObserver {
  CompanyLifecycleMonitor({
    CompanyApi? api,
    HeldWorkSync? sync,
    bool recheckOnlyWhileOpen = false,
  }) : _api = api ?? CompanyApi.instance,
       _sync = sync ?? HeldWorkSync(),
       _recheckOnlyWhileOpen = recheckOnlyWhileOpen;

  static const Duration recheckEvery = Duration(minutes: 5);

  static final CompanyLifecycleMonitor instance = CompanyLifecycleMonitor(
    recheckOnlyWhileOpen: true,
  );

  final CompanyApi _api;
  final HeldWorkSync _sync;
  final bool _recheckOnlyWhileOpen;
  bool _onScreenNow = true;
  CompanyLifecycle? _lifecycle;
  HeldWorkCounts _counts = const HeldWorkCounts();
  bool _hasWorkToUpload = false;
  int _uploadedCount = 0;
  String _uid = '';
  Timer? _timer;
  Future<void> _tail = Future<void>.value();

  CompanyLifecycle? get lifecycle => _lifecycle;
  HeldWorkCounts get counts => _counts;
  bool get hasWorkToUpload => _hasWorkToUpload;
  int get uploadedCount => _uploadedCount;
  bool get paused => _lifecycle != null && !_lifecycle!.isOpen;

  void start(String uid) {
    if (_uid == uid) return;
    _uid = uid;
    AppLifecycleState? state;
    if (_recheckOnlyWhileOpen) {
      final WidgetsBinding binding = WidgetsBinding.instance;
      binding.removeObserver(this);
      binding.addObserver(this);
      state = binding.lifecycleState;
    }
    _onScreenNow = state == null || _onScreen(state);
    _syncTimer();
    unawaited(refresh());
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (_uid.isEmpty) return;
    _onScreenNow = _onScreen(state);
    _syncTimer();
  }

  static bool _onScreen(AppLifecycleState state) =>
      state == AppLifecycleState.resumed || state == AppLifecycleState.inactive;

  void _syncTimer() {
    final bool wanted = _onScreenNow || _hasWorkToUpload;
    if (wanted == (_timer != null)) return;
    _timer?.cancel();
    _timer = wanted
        ? Timer.periodic(recheckEvery, (_) => unawaited(refresh()))
        : null;
  }

  void stop() {
    if (_recheckOnlyWhileOpen) WidgetsBinding.instance.removeObserver(this);
    _timer?.cancel();
    _timer = null;
    _uid = '';
    _lifecycle = null;
    _counts = const HeldWorkCounts();
    _hasWorkToUpload = false;
    _uploadedCount = 0;
    notifyListeners();
  }

  void dismissUploaded() {
    if (_uploadedCount == 0) return;
    _uploadedCount = 0;
    notifyListeners();
  }

  Future<CompanyLifecycle?> refresh({bool upload = true}) {
    if (!upload) return _refresh(false);
    final Future<CompanyLifecycle?> next = _tail.then((_) => _refresh(upload));
    _tail = next.then<void>((_) {}, onError: (Object _) {});
    return next;
  }

  Future<CompanyLifecycle?> _refresh(bool upload) async {
    final String uid = _uid;
    final CompanyLifecycle? fetched = await _api.readLifecycle();
    if (uid != _uid) return fetched;
    if (fetched != null) _lifecycle = fetched;
    final CompanyLifecycle? known = _lifecycle;
    int sent = 0;
    if (upload && uid.isNotEmpty && known != null) {
      try {
        if (known.cutAt == null) {
          await _sync.forgetStoredOrders(uid, known);
        } else {
          sent = await _sync.flush(uid, known);
        }
      } catch (error) {
        debugPrint('Held work upload failed: $error');
      }
    }
    if (uid.isNotEmpty && uid == _uid) {
      try {
        _counts = await _sync.counts(uid, known);
        _hasWorkToUpload = await _sync.hasWorkToUpload(
          uid,
          includeNotAccepted: false,
        );
      } catch (error) {
        debugPrint('Held work count failed: $error');
      }
    }
    if (uid == _uid && known != null && known.isOpen && sent > 0) {
      _uploadedCount += sent;
    }
    if (uid == _uid && uid.isNotEmpty) _syncTimer();
    if (uid == _uid) notifyListeners();
    return fetched;
  }
}
