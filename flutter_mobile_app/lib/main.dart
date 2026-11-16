import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/foundation.dart'
    show FlutterExceptionHandler, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:firebase_app_check/firebase_app_check.dart';

import 'copilot/mobile_copilot_controller.dart';
import 'edition.dart';
import 'firebase_options.dart';
import 'models/user_model.dart';
import 'providers/auth_provider.dart';
import 'providers/connectivity_provider.dart';
import 'providers/gps_provider.dart';
import 'services/cart_draft_cache.dart';
import 'theme/app_theme.dart';
import 'services/project_local_store.dart';
import 'services/company_project.dart';
import 'services/company_runtime.dart';
import 'services/company_lifecycle_monitor.dart';
import 'screens/app_states.dart';
import 'screens/company_paused_screen.dart';
import 'screens/login_screen.dart';
import 'screens/overview_screen.dart';
import 'utils/e2e_persistence_flag.dart'
    if (dart.library.js_interop) 'utils/e2e_persistence_flag_web.dart';
import 'widgets/idle_session_lock.dart';

@visibleForTesting
bool shouldSyncGpsTracking({
  required bool isLoggedIn,
  required String currentUid,
  required String trackedUid,
}) {
  return isLoggedIn && currentUid.isNotEmpty && currentUid != trackedUid;
}

void main() {
  WidgetsFlutterBinding.ensureInitialized();
  runApp(const AppBootstrapper());
}

Future<void> _initFirebaseAndCache() async {
  final String? editionProblem = editionError;
  if (editionProblem != null) throw UnsupportedError(editionProblem);
  final ActiveCompany company = await CompanyProject.instance.active();
  if (Firebase.apps.isNotEmpty) {
    final ActiveCompany? initialized = CompanyRuntime.current;
    if (Firebase.app().options != company.options ||
        (initialized != null &&
            !CompanyRuntime.sameIdentity(initialized, company))) {
      throw const CompanyRestartRequired();
    }
  }
  await Firebase.initializeApp(options: company.options);
  FirebaseAuth.instance.tenantId = company.authTenantId;
  CompanyRuntime.bindInitialized(company);
  const bool useEmulator = bool.fromEnvironment('USE_FIREBASE_EMULATOR');
  const bool webDebugRun = kIsWeb && kDebugMode;
  if (!useEmulator && !webDebugRun) {
    await FirebaseAppCheck.instance.activate(
      androidProvider: kDebugMode
          ? AndroidProvider.debug
          : AndroidProvider.playIntegrity,
      appleProvider: kDebugMode
          ? AppleProvider.debug
          : AppleProvider.appAttestWithDeviceCheckFallback,
      webProvider: ReCaptchaEnterpriseProvider(
        '6LcYqgkuAAAAAA1q92fHY_Dp7RedJOVlkFkjGv8g',
      ),
    );
  }
  FirebaseFirestore.instance.settings = Settings(
    persistenceEnabled: !(kIsWeb && useEmulator) || e2ePersistenceRequested(),
    cacheSizeBytes: Settings.CACHE_SIZE_UNLIMITED,
  );
  await _connectLocalEmulatorsIfRequested();
  await CartDraftCache.initialise();
  CompanyProject.instance.keepRecordFresh(company, (ActiveCompany renewed) {
    final ActiveCompany? initialized = CompanyRuntime.current;
    if (initialized != null &&
        CompanyRuntime.sameIdentity(initialized, renewed)) {
      CompanyRuntime.bindInitialized(renewed);
    }
  });
}

class CompanyRestartRequired implements Exception {
  const CompanyRestartRequired();
  @override
  String toString() => 'Restart the app to use the selected company.';
}

class AppBootstrapper extends StatefulWidget {
  const AppBootstrapper({super.key});

  @override
  State<AppBootstrapper> createState() => _AppBootstrapperState();
}

class _AppBootstrapperState extends State<AppBootstrapper> {
  late Future<void> _initFuture;

  @override
  void initState() {
    super.initState();
    _initFuture = _initFirebaseAndCache();
  }

  Future<void> _refreshAndStart() async {
    await CompanyProject.instance.refreshSelected();
    await _initFirebaseAndCache();
  }

  Future<void> _chooseCompany(BuildContext pageContext) async {
    final TextEditingController code = TextEditingController();
    final String? chosen = await showDialog<String>(
      context: pageContext,
      builder: (dialog) => AlertDialog(
        title: const Text('Company code'),
        content: TextField(
          controller: code,
          autofocus: true,
          autocorrect: false,
          textCapitalization: TextCapitalization.characters,
          decoration: const InputDecoration(labelText: 'Company code'),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.pop(dialog),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(dialog, code.text),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
    code.dispose();
    if (chosen == null || !mounted) return;
    setState(() {
      _initFuture = (() async {
        await CompanyProject.instance.save(chosen);
        await _initFirebaseAndCache();
      })();
    });
  }

  @override
  Widget build(BuildContext context) {
    return FutureBuilder<void>(
      future: _initFuture,
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.done) {
          if (snapshot.hasError) {
            final Object? error = snapshot.error;
            final String message =
                firebaseTargetError ??
                editionError ??
                (error is CompanyException
                    ? error.message
                    : error is CompanyRestartRequired
                    ? error.toString()
                    : 'Could not start the app. Check your connection and company setup.');
            return MaterialApp(
              debugShowCheckedModeBanner: false,
              theme: appLightTheme,
              themeMode: ThemeMode.light,
              home: Scaffold(
                body: Center(
                  child: Padding(
                    padding: const EdgeInsets.all(24),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Text(message, textAlign: TextAlign.center),
                        const SizedBox(height: 16),
                        if (firebaseTargetError == null &&
                            editionError == null &&
                            error is! CompanyRestartRequired)
                          FilledButton(
                            onPressed: () => setState(
                              () => _initFuture = _refreshAndStart(),
                            ),
                            child: const Text('Retry'),
                          ),
                        if (CompanyProject.instance.hasDirectory)
                          Builder(
                            builder: (pageContext) => TextButton(
                              onPressed: () => _chooseCompany(pageContext),
                              child: const Text('Change company'),
                            ),
                          ),
                      ],
                    ),
                  ),
                ),
              ),
            );
          }
          return const MyApp();
        }
        return MaterialApp(
          debugShowCheckedModeBanner: false,
          theme: appLightTheme,
          themeMode: ThemeMode.light,
          home: AppSplashScreen(message: 'Loading $productTitle...'),
        );
      },
    );
  }
}

Future<void> _connectLocalEmulatorsIfRequested() async {
  const bool useEmulator = bool.fromEnvironment('USE_FIREBASE_EMULATOR');
  if (!useEmulator) return;

  const String host = String.fromEnvironment(
    'FIREBASE_EMULATOR_HOST',
    defaultValue: '127.0.0.1',
  );
  const int firestorePort = int.fromEnvironment(
    'FIRESTORE_EMULATOR_PORT',
    defaultValue: 8089,
  );
  const int authPort = int.fromEnvironment(
    'FIREBASE_AUTH_EMULATOR_PORT',
    defaultValue: 9099,
  );
  FirebaseFirestore.instance.useFirestoreEmulator(host, firestorePort);
  await FirebaseAuth.instance.useAuthEmulator(host, authPort);
  debugPrint('Local Firebase emulators enabled at $host');
  final FlutterExceptionHandler? report = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('FLUTTER_ERROR: ${details.exceptionAsString()}');
    report?.call(details);
  };
}

final GlobalKey<NavigatorState> appNavigatorKey = GlobalKey<NavigatorState>();

class MyApp extends StatelessWidget {
  const MyApp({super.key, this.cartDraftHydration});

  final Future<void>? cartDraftHydration;

  @override
  Widget build(BuildContext context) {
    return MultiProvider(
      providers: [
        ChangeNotifierProvider(create: (_) => AuthProvider()),
        ChangeNotifierProvider(create: (_) => GpsProvider()),
        ChangeNotifierProvider(create: (_) => ConnectivityProvider()),
        ChangeNotifierProxyProvider<AuthProvider, MobileCopilotController>(
          create: (_) => MobileCopilotController(),
          update: (_, auth, controller) => controller!..syncUser(auth.user),
        ),
      ],
      child: MaterialApp(
        navigatorKey: appNavigatorKey,
        title: productTitle,
        debugShowCheckedModeBanner: false,
        theme: appLightTheme,
        themeMode: ThemeMode.light,
        builder: (BuildContext context, Widget? navigator) {
          final AuthProvider auth = context.watch<AuthProvider>();
          return IdleSessionLock(
            enabled: auth.isLoggedIn && auth.user != null,
            reauthenticate: auth.reauthenticate,
            navigatorKey: appNavigatorKey,
            child: ValueListenableBuilder<String>(
              valueListenable: ProjectLocalStore.recoveryNotice,
              child: ValueListenableBuilder<bool>(
                valueListenable: CompanyProject.instance.recordExpired,
                child: Semantics(
                  container: true,
                  child: navigator ?? const SizedBox.shrink(),
                ),
                builder: (context, expired, child) {
                  if (!expired) return child!;
                  return Column(
                    children: [
                      const Material(
                        color: Color(0xFFFFF7ED),
                        child: SafeArea(
                          bottom: false,
                          child: Padding(
                            padding: EdgeInsets.all(12),
                            child: Text(
                              'Company record expired, connect to renew',
                              style: TextStyle(color: Color(0xFFB45309)),
                            ),
                          ),
                        ),
                      ),
                      Expanded(child: child!),
                    ],
                  );
                },
              ),
              builder: (context, notice, child) {
                if (notice.isEmpty) return child!;
                return Column(
                  children: [
                    Material(
                      color: const Color(0xFFFFF7ED),
                      child: SafeArea(
                        bottom: false,
                        child: Padding(
                          padding: const EdgeInsets.all(12),
                          child: Text(
                            notice,
                            style: const TextStyle(color: Color(0xFFB45309)),
                          ),
                        ),
                      ),
                    ),
                    Expanded(child: child!),
                  ],
                );
              },
            ),
          );
        },
        home: AuthWrapper(cartDraftHydration: cartDraftHydration),
      ),
    );
  }
}

class AuthWrapper extends StatefulWidget {
  const AuthWrapper({super.key, this.cartDraftHydration});

  final Future<void>? cartDraftHydration;

  @override
  State<AuthWrapper> createState() => _AuthWrapperState();
}

class _AuthWrapperState extends State<AuthWrapper> with WidgetsBindingObserver {
  String _gpsTrackingUid = '';
  bool _gpsResetScheduled = false;
  ConnectivityProvider? _connectivityProvider;
  bool _cartDraftsReady = false;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    unawaited(_restoreCartDrafts());
  }

  Future<void> _restoreCartDrafts() async {
    try {
      await (widget.cartDraftHydration ?? Future<void>.value());
    } catch (error, stackTrace) {
      debugPrint(
        'Saved-draft cache could not be restored: $error\n$stackTrace',
      );
    } finally {
      if (mounted) setState(() => _cartDraftsReady = true);
    }
  }

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    final ConnectivityProvider next = context.read<ConnectivityProvider>();
    if (identical(_connectivityProvider, next)) return;
    _connectivityProvider?.removeListener(_handleConnectivityChange);
    _connectivityProvider = next;
    next.addListener(_handleConnectivityChange);
  }

  void _handleConnectivityChange() {
    if (_connectivityProvider?.isOnline == true && mounted) {
      unawaited(context.read<AuthProvider>().revalidateOfflineProfile());
      unawaited(context.read<GpsProvider>().refreshTracking());
      unawaited(CompanyLifecycleMonitor.instance.refresh());
    }
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(context.read<AuthProvider>().revalidateOfflineProfile());
      unawaited(context.read<GpsProvider>().refreshTracking());
      unawaited(CompanyLifecycleMonitor.instance.refresh());
    }
  }

  @override
  void dispose() {
    _connectivityProvider?.removeListener(_handleConnectivityChange);
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  void _resetGpsTracking() {
    if (_gpsTrackingUid.isEmpty) return;
    final String endingUid = _gpsTrackingUid;
    _gpsTrackingUid = '';
    unawaited(context.read<GpsProvider>().endWork(uid: endingUid));
  }

  void _scheduleGpsTrackingReset() {
    final String scheduledUid = _gpsTrackingUid;
    if (scheduledUid.isEmpty || _gpsResetScheduled) return;
    _gpsResetScheduled = true;
    WidgetsBinding.instance.addPostFrameCallback((_) {
      _gpsResetScheduled = false;
      if (!mounted || _gpsTrackingUid != scheduledUid) return;
      final AuthProvider authProvider = context.read<AuthProvider>();
      final bool accessBlocked =
          !authProvider.isLoggedIn ||
          authProvider.user == null ||
          authProvider.status == AuthStatus.missingProfile ||
          authProvider.status == AuthStatus.suspended ||
          authProvider.status == AuthStatus.unavailable;
      if (accessBlocked) _resetGpsTracking();
    });
  }

  Future<void> _syncGpsTracking(UserModel user) async {
    if (_gpsTrackingUid == user.uid) return;
    final String syncingUid = user.uid;
    final GpsProvider gps = context.read<GpsProvider>();
    if (_gpsTrackingUid.isNotEmpty) {
      await gps.endWork(uid: _gpsTrackingUid);
    }
    _gpsTrackingUid = user.uid;
    if (!user.hasSalespersonRole || !user.hasActiveAccount) {
      await gps.setTrackingEnabled(false, notAllowed: true);
      return;
    }
    await gps.setTrackingEnabled(user.gpsAutofill);
    if (!_isCurrentGpsSession(syncingUid)) {
      return;
    }
    if (user.gpsAutofill) await gps.startTracking(user: user);
  }

  bool _isCurrentGpsSession(String uid) {
    if (!mounted) return false;
    final AuthProvider authProvider = context.read<AuthProvider>();
    return authProvider.isLoggedIn &&
        authProvider.user?.uid == uid &&
        _gpsTrackingUid == uid;
  }

  @override
  Widget build(BuildContext context) {
    return Consumer<AuthProvider>(
      builder: (context, authProvider, _) {
        if (authProvider.initialising) {
          return AppSplashScreen(
            message: 'Verifying account...',
            onRetry: () => context.read<AuthProvider>().retryProfile(),
          );
        }
        if (authProvider.status == AuthStatus.missingProfile ||
            authProvider.status == AuthStatus.suspended ||
            authProvider.status == AuthStatus.unavailable) {
          _scheduleGpsTrackingReset();
          return _AccountAccessScreen(
            status: authProvider.status,
            message: authProvider.errorMessage,
          );
        }

        final user = authProvider.user;
        if (authProvider.isLoggedIn && user != null) {
          if (!_cartDraftsReady) {
            return const AppSplashScreen(message: 'Restoring saved work...');
          }
          if (shouldSyncGpsTracking(
            isLoggedIn: authProvider.isLoggedIn,
            currentUid: user.uid,
            trackedUid: _gpsTrackingUid,
          )) {
            WidgetsBinding.instance.addPostFrameCallback((_) {
              if (mounted) _syncGpsTracking(user);
            });
          }
          WidgetsBinding.instance.addPostFrameCallback((_) {
            CompanyLifecycleMonitor.instance.start(user.uid);
          });
          final Widget overview = ListenableBuilder(
            listenable: CompanyLifecycleMonitor.instance,
            builder: (BuildContext context, Widget? _) {
              if (!CompanyLifecycleMonitor.instance.paused) {
                return const OverviewScreen();
              }
              WidgetsBinding.instance.addPostFrameCallback((_) {
                if (context.mounted) {
                  Navigator.of(
                    context,
                  ).popUntil((Route<dynamic> r) => r.isFirst);
                }
              });
              return CompanyPausedScreen(
                monitor: CompanyLifecycleMonitor.instance,
              );
            },
          );
          return authProvider.isOfflineVerified
              ? OfflineSessionBanner(
                  verifiedAt: authProvider.offlineVerifiedAt,
                  onRetry: () =>
                      context.read<AuthProvider>().revalidateOfflineProfile(),
                  child: overview,
                )
              : overview;
        }
        _scheduleGpsTrackingReset();
        WidgetsBinding.instance.addPostFrameCallback((_) {
          CompanyLifecycleMonitor.instance.stop();
        });
        return const LoginScreen();
      },
    );
  }
}

class _AccountAccessScreen extends StatelessWidget {
  const _AccountAccessScreen({required this.status, required this.message});

  final AuthStatus status;
  final String message;

  @override
  Widget build(BuildContext context) {
    final unavailable = status == AuthStatus.unavailable;
    final title = status == AuthStatus.missingProfile
        ? 'Profile not assigned'
        : status == AuthStatus.suspended
        ? 'Account unavailable'
        : 'Could not verify account';
    return AccountAccessScreen(
      title: title,
      message: message,
      primaryLabel: unavailable ? 'Retry verification' : null,
      primaryAction: unavailable
          ? () => context.read<AuthProvider>().retryProfile()
          : null,
      onSignOut: () => context.read<AuthProvider>().logout(),
    );
  }
}
