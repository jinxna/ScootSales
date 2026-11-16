import 'dart:async';

import 'package:flutter/foundation.dart' show kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:local_auth/local_auth.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../providers/auth_provider.dart';

const String kLockedUidKey = 'idle_session_locked_uid';
const String kLastActiveKey = 'idle_session_last_active';

const String kNoScreenLockText =
    'This phone has no screen lock. Set a PIN, pattern or fingerprint in the '
    'phone settings, or connect to the internet and enter your password.';

const String _returnToSignIn = 'Return to sign in to continue.';

const int _configuredIdleMinutes = int.fromEnvironment(
  'MOBILE_IDLE_TIMEOUT_MINUTES',
  defaultValue: 120,
);
const Duration kSessionIdleTimeout = Duration(
  minutes: _configuredIdleMinutes > 0 ? _configuredIdleMinutes : 120,
);

class IdleSessionLock extends StatefulWidget {
  const IdleSessionLock({
    super.key,
    required this.enabled,
    required this.child,
    required this.reauthenticate,
    this.timeout = kSessionIdleTimeout,
    this.navigatorKey,
  });

  final bool enabled;
  final Widget child;

  final Future<String?> Function(String password) reauthenticate;
  final Duration timeout;

  final GlobalKey<NavigatorState>? navigatorKey;

  @override
  State<IdleSessionLock> createState() => _IdleSessionLockState();
}

class _IdleSessionLockState extends State<IdleSessionLock>
    with WidgetsBindingObserver {
  final TextEditingController _password = TextEditingController();
  Timer? _timer;
  DateTime _lastActivity = DateTime.now();
  bool _locked = false;
  bool _busy = false;
  bool _signingOut = false;
  bool _releasing = false;
  String? _lockedUid;
  String? _error;
  bool _savedLoaded = false;
  String? _savedLockedUid;
  String? _savedLastActive;

  Duration get _timeout =>
      widget.timeout > Duration.zero ? widget.timeout : kSessionIdleTimeout;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    HardwareKeyboard.instance.addHandler(_onKey);
    _restart();
    _loadSaved();
  }

  Future<void> _loadSaved() async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      _savedLockedUid = prefs.getString(kLockedUidKey);
      _savedLastActive = prefs.getString(kLastActiveKey);
    } catch (_) {}
    _savedLoaded = true;
    _applySaved();
  }

  void _applySaved() {
    if (!_savedLoaded || !mounted || !widget.enabled || _locked) return;
    final String? uid = context.read<AuthProvider>().user?.uid;
    if (uid == null || uid.isEmpty) return;
    final bool lockedBefore = _savedLockedUid == uid;
    final String prefix = '$uid|';
    final int? lastActiveMs =
        _savedLastActive != null && _savedLastActive!.startsWith(prefix)
        ? int.tryParse(_savedLastActive!.substring(prefix.length))
        : null;
    _savedLockedUid = null;
    _savedLastActive = null;
    final bool idleTooLong =
        lastActiveMs != null &&
        DateTime.now().difference(
              DateTime.fromMillisecondsSinceEpoch(lastActiveMs),
            ) >=
            _timeout;
    if (lockedBefore || idleTooLong) _lock();
  }

  Future<void> _writeSaved({String? lockedUid, String? lastActive}) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (lockedUid == null) {
        await prefs.remove(kLockedUidKey);
      } else {
        await prefs.setString(kLockedUidKey, lockedUid);
      }
      if (lastActive == null) {
        await prefs.remove(kLastActiveKey);
      } else {
        await prefs.setString(kLastActiveKey, lastActive);
      }
    } catch (_) {}
  }

  @override
  void didUpdateWidget(IdleSessionLock old) {
    super.didUpdateWidget(old);
    if (old.enabled != widget.enabled && !_locked) {
      _password.clear();
      _error = null;
      _restart();
      if (widget.enabled) {
        _applySaved();
      } else {
        _savedLockedUid = null;
        _savedLastActive = null;
        _writeSaved();
      }
    } else if (old.timeout != widget.timeout && widget.enabled && !_locked) {
      if (DateTime.now().difference(_lastActivity) >= _timeout) {
        _lock();
      } else {
        _timer?.cancel();
        _timer = Timer(
          _timeout - DateTime.now().difference(_lastActivity),
          _lock,
        );
      }
    }
  }

  bool _onKey(KeyEvent _) {
    _activity();
    return false;
  }

  void _activity() {
    if (!widget.enabled || _locked) return;
    if (DateTime.now().difference(_lastActivity) >= _timeout) {
      _lock();
    } else {
      _restart();
    }
  }

  void _restart() {
    _timer?.cancel();
    _timer = null;
    if (!widget.enabled || _locked) return;
    _lastActivity = DateTime.now();
    _timer = Timer(_timeout, _lock);
  }

  void _lock() {
    _timer?.cancel();
    if (!mounted || !widget.enabled || _locked) return;
    final String? uid = context.read<AuthProvider>().user?.uid;
    _writeSaved(lockedUid: uid);
    setState(() {
      _locked = true;
      _lockedUid = uid;
      _password.clear();
      _error = null;
    });
  }

  bool _sameAccount() {
    final AuthProvider auth = context.read<AuthProvider>();
    return _lockedUid != null &&
        _lockedUid!.isNotEmpty &&
        auth.isLoggedIn &&
        auth.user?.uid == _lockedUid;
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.paused && widget.enabled && !_locked) {
      final String? uid = context.read<AuthProvider>().user?.uid;
      if (uid != null && uid.isNotEmpty) {
        _writeSaved(lastActive: '$uid|${_lastActivity.millisecondsSinceEpoch}');
      }
    }
    if (state == AppLifecycleState.resumed &&
        widget.enabled &&
        !_locked &&
        DateTime.now().difference(_lastActivity) >= _timeout) {
      _lock();
    }
  }

  Future<void> _unlock() async {
    if (_busy || _signingOut || _releasing || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      if (!_sameAccount()) {
        error = _returnToSignIn;
      } else {
        error = await widget.reauthenticate(_password.text);
        if (error == null && mounted && !_sameAccount()) {
          error = _returnToSignIn;
        }
      }
    } catch (_) {
      error = 'Could not check your password. Try again.';
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) _release();
  }

  Future<void> _unlockWithScreenLock() async {
    if (kIsWeb || _busy || _signingOut || _releasing) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? error;
    try {
      final LocalAuthentication localAuth = LocalAuthentication();
      if (!await localAuth.isDeviceSupported()) {
        error = kNoScreenLockText;
      } else if (!await localAuth.authenticate(
        localizedReason: 'Unlock Scoot Sales',
        persistAcrossBackgrounding: true,
      )) {
        error = 'The screen lock was not confirmed. Try again.';
      }
    } on LocalAuthException catch (e) {
      error = e.code == LocalAuthExceptionCode.noCredentialsSet
          ? kNoScreenLockText
          : 'The screen lock was not confirmed. Try again.';
    } catch (_) {
      error = 'Could not use the screen lock. Try again.';
    }
    if (!mounted) return;
    if (error == null && !_sameAccount()) error = _returnToSignIn;
    setState(() {
      _busy = false;
      _error = error;
    });
    if (error == null) _release();
  }

  Future<void> _useDifferentAccount() async {
    final AuthProvider auth = context.read<AuthProvider>();
    if (auth.isLoggedIn) {
      setState(() => _signingOut = true);
      try {
        await auth.logout();
      } catch (_) {
        if (mounted) {
          setState(() {
            _signingOut = false;
            _error = 'Could not sign out. Try again.';
          });
        }
        return;
      }
      if (!mounted) return;
      setState(() => _signingOut = false);
    }
    widget.navigatorKey?.currentState?.popUntil(
      (Route<dynamic> route) => route.isFirst,
    );
    _release();
  }

  void _release() {
    if (_releasing) return;
    _writeSaved();
    setState(() => _releasing = true);
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (!mounted) return;
      setState(() {
        _releasing = false;
        _locked = false;
        _lockedUid = null;
        _error = null;
        _password.clear();
      });
      _restart();
    });
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    HardwareKeyboard.instance.removeHandler(_onKey);
    _timer?.cancel();
    _password.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      behavior: HitTestBehavior.translucent,
      onPointerDown: (_) => _activity(),
      onPointerMove: (_) => _activity(),
      onPointerSignal: (_) => _activity(),
      child: Stack(
        children: <Widget>[
          ExcludeSemantics(
            excluding: _locked,
            child: ExcludeFocus(excluding: _locked, child: widget.child),
          ),
          if (_locked)
            Positioned.fill(
              child: Overlay.wrap(
                child: ExcludeSemantics(
                  excluding: _releasing,
                  child: ExcludeFocus(
                    excluding: _releasing,
                    child: Material(
                      color: Theme.of(context).colorScheme.surface,
                      child: SafeArea(
                        child: Center(
                          child: ConstrainedBox(
                            constraints: const BoxConstraints(maxWidth: 360),
                            child: Padding(
                              padding: const EdgeInsets.all(24),
                              child: Column(
                                mainAxisSize: MainAxisSize.min,
                                children: <Widget>[
                                  const Icon(Icons.lock_outline, size: 40),
                                  const SizedBox(height: 12),
                                  const Text(
                                    'Session locked',
                                    style: TextStyle(
                                      fontSize: 20,
                                      fontWeight: FontWeight.w700,
                                    ),
                                  ),
                                  const SizedBox(height: 8),
                                  const Text(
                                    kIsWeb
                                        ? 'Enter your password to unlock.'
                                        : 'Unlock with your phone screen lock, '
                                              'or enter your password when you have internet.',
                                    textAlign: TextAlign.center,
                                  ),
                                  const SizedBox(height: 16),
                                  if (!kIsWeb) ...<Widget>[
                                    SizedBox(
                                      width: double.infinity,
                                      child: FilledButton.icon(
                                        onPressed: _busy
                                            ? null
                                            : _unlockWithScreenLock,
                                        icon: const Icon(Icons.fingerprint),
                                        label: const Text(
                                          'Unlock with screen lock',
                                        ),
                                      ),
                                    ),
                                    const SizedBox(height: 16),
                                  ],
                                  AutofillGroup(
                                    child: TextField(
                                      controller: _password,
                                      obscureText: true,
                                      autofocus: kIsWeb,
                                      autofillHints: const <String>[
                                        AutofillHints.password,
                                      ],
                                      textInputAction: TextInputAction.done,
                                      onSubmitted: (_) => _unlock(),
                                      decoration: InputDecoration(
                                        labelText: 'Password',
                                        errorText: _error,
                                        border: const OutlineInputBorder(),
                                      ),
                                    ),
                                  ),
                                  const SizedBox(height: 12),
                                  SizedBox(
                                    width: double.infinity,
                                    child: FilledButton(
                                      onPressed: _busy || _signingOut
                                          ? null
                                          : _unlock,
                                      child: Text(
                                        _signingOut
                                            ? 'Signing out...'
                                            : _busy
                                            ? 'Checking...'
                                            : 'Unlock',
                                      ),
                                    ),
                                  ),
                                  TextButton(
                                    onPressed: _busy || _signingOut
                                        ? null
                                        : _useDifferentAccount,
                                    child: const Text(
                                      'Sign in as a different user',
                                    ),
                                  ),
                                ],
                              ),
                            ),
                          ),
                        ),
                      ),
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}
