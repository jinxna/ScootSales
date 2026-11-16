import 'package:firebase_auth/firebase_auth.dart' show FirebaseAuthException;
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/providers/auth_provider.dart';
import 'package:fmcg_sales/widgets/idle_session_lock.dart';
import 'package:provider/provider.dart';
import 'package:provider/single_child_widget.dart';
import 'package:shared_preferences/shared_preferences.dart';

class _FakeAuth extends Fake implements AuthProvider {
  String _uid = 'uid-1';
  int logouts = 0;
  bool _signedIn = true;

  @override
  UserModel? get user => _signedIn
      ? UserModel(
          uid: _uid,
          staffId: 'S001',
          name: 'Sales One',
          email: 'sales1@example.test',
          phone: '',
          territory: '',
          role: 'salesman',
          joinedDate: '',
        )
      : null;

  @override
  bool get isLoggedIn => _signedIn;

  @override
  Future<void> logout() async {
    logouts += 1;
    _signedIn = false;
  }

  void switchTo(String uid) => _uid = uid;
}

Widget _lockApp({
  required _FakeAuth auth,
  required Future<String?> Function(String password) reauthenticate,
  Widget child = const Scaffold(body: Text('Route work')),
}) {
  return MultiProvider(
    providers: <SingleChildWidget>[Provider<AuthProvider>.value(value: auth)],
    child: MaterialApp(
      home: IdleSessionLock(
        enabled: true,
        timeout: const Duration(minutes: 10),
        reauthenticate: reauthenticate,
        child: child,
      ),
    ),
  );
}

void _screenLockConfirms() {
  TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger
      .setMockMethodCallHandler(
        const MethodChannel('plugins.flutter.io/local_auth'),
        (MethodCall call) async => true,
      );
}

Future<void> _goIdle(WidgetTester tester) async {
  await tester.pumpAndSettle();
  await tester.pump(const Duration(minutes: 11));
  await tester.pumpAndSettle();
}

Future<String?> _savedLockedUid() async =>
    (await SharedPreferences.getInstance()).getString(kLockedUidKey);

Future<void> _enterPassword(WidgetTester tester, String password) async {
  await tester.enterText(find.byType(TextField).last, password);
  await tester.tap(find.text('Unlock'));
  await tester.pumpAndSettle();
}

void main() {
  Provider.debugCheckInvalidValueType = null;

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  testWidgets(
    'FR-AUTH-04 (owner decision 15 Nov, keep session always): activity resets '
    'the timer, inactivity locks without signing out or discarding state, '
    'the right password unlocks',
    (WidgetTester tester) async {
      final _FakeAuth auth = _FakeAuth();
      final List<String> attempts = <String>[];

      await tester.pumpWidget(
        _lockApp(
          auth: auth,
          reauthenticate: (String p) async {
            attempts.add(p);
            return p == 'right' ? null : 'Incorrect password.';
          },
          child: const Scaffold(body: TextField(key: Key('draft'))),
        ),
      );
      await tester.enterText(
        find.byKey(const Key('draft')),
        'queued order note',
      );

      await tester.pump(const Duration(minutes: 9));
      await tester.tapAt(const Offset(5, 5));
      await tester.pump(const Duration(minutes: 9));
      expect(find.text('Session locked'), findsNothing);

      await tester.pump(const Duration(minutes: 2));
      await tester.pumpAndSettle();
      expect(find.text('Session locked'), findsOneWidget);
      expect(auth.logouts, 0);
      expect(auth.isLoggedIn, isTrue);
      expect(await _savedLockedUid(), 'uid-1');

      await _enterPassword(tester, 'wrong');
      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text('Session locked'), findsOneWidget);
      expect(auth.isLoggedIn, isTrue);

      await _enterPassword(tester, 'right');
      expect(find.text('Session locked'), findsNothing);
      expect(attempts, <String>['wrong', 'right']);
      expect(find.text('queued order note'), findsOneWidget);
      expect(auth.logouts, 0);
      expect(await _savedLockedUid(), isNull);

      await tester.pump(const Duration(minutes: 11));
      expect(find.text('Session locked'), findsOneWidget);
    },
  );

  testWidgets('FIX-108: a lock is still shown after the app restarts', (
    WidgetTester tester,
  ) async {
    SharedPreferences.setMockInitialValues(<String, Object>{
      kLockedUidKey: 'uid-1',
    });
    final _FakeAuth auth = _FakeAuth();

    await tester.pumpWidget(
      _lockApp(auth: auth, reauthenticate: (_) async => null),
    );
    await tester.pump();
    await tester.pump();

    expect(find.text('Session locked'), findsOneWidget);
    expect(find.text('Unlock with screen lock'), findsOneWidget);
    expect(auth.logouts, 0);
  });

  testWidgets(
    'FIX-327: a password that cannot be checked keeps the session and the '
    'screen lock opens the app',
    (WidgetTester tester) async {
      _screenLockConfirms();
      final _FakeAuth auth = _FakeAuth();

      await tester.pumpWidget(
        _lockApp(
          auth: auth,
          reauthenticate: (_) async =>
              'No connection. Reconnect and try again.',
        ),
      );
      await _goIdle(tester);
      expect(find.text('Session locked'), findsOneWidget);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.logouts, 0);

      await _enterPassword(tester, 'whatever');
      expect(
        find.text('No connection. Reconnect and try again.'),
        findsOneWidget,
      );
      expect(auth.isLoggedIn, isTrue);
      expect(auth.logouts, 0);

      await tester.tap(find.text('Unlock with screen lock'));
      await tester.pumpAndSettle();
      expect(find.text('Session locked'), findsNothing);
      expect(find.text('Route work'), findsOneWidget);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.logouts, 0);
    },
  );

  testWidgets('FIX-327: a different account cannot unlock the lock', (
    WidgetTester tester,
  ) async {
    _screenLockConfirms();
    final _FakeAuth auth = _FakeAuth();
    int checks = 0;

    await tester.pumpWidget(
      _lockApp(
        auth: auth,
        reauthenticate: (_) async {
          checks += 1;
          return null;
        },
      ),
    );
    await _goIdle(tester);
    auth.switchTo('uid-2');

    await _enterPassword(tester, 'right');
    expect(find.text('Session locked'), findsOneWidget);
    expect(find.text('Return to sign in to continue.'), findsOneWidget);
    expect(checks, 0);

    await tester.tap(find.text('Unlock with screen lock'));
    await tester.pumpAndSettle();
    expect(find.text('Session locked'), findsOneWidget);
  });

  testWidgets(
    'FIX-327: three wrong unlock passwords start the device sign-in delay '
    'and a fourth try is not checked',
    (WidgetTester tester) async {
      _screenLockConfirms();
      final _FakeAuth auth = _FakeAuth();
      int checks = 0;

      await tester.pumpWidget(
        _lockApp(
          auth: auth,
          reauthenticate: (String password) => checkPasswordWithDeviceThrottle(
            email: 'Sales1@example.test',
            verify: () async {
              checks += 1;
              if (password != 'right') {
                throw FirebaseAuthException(code: 'wrong-password');
              }
            },
          ),
        ),
      );
      await _goIdle(tester);

      await _enterPassword(tester, 'wrong1');
      expect(find.text('Incorrect password.'), findsOneWidget);
      await _enterPassword(tester, 'wrong2');
      await _enterPassword(tester, 'wrong3');
      expect(find.text(kPasswordCheckDelayedText), findsOneWidget);
      expect(checks, 3);

      await _enterPassword(tester, 'right');
      expect(find.text(kPasswordCheckDelayedText), findsOneWidget);
      expect(find.text('Session locked'), findsOneWidget);
      expect(checks, 3);
      expect(auth.isLoggedIn, isTrue);
      expect(auth.logouts, 0);

      await tester.tap(find.text('Unlock with screen lock'));
      await tester.pumpAndSettle();
      expect(find.text('Session locked'), findsNothing);
      expect(find.text('Route work'), findsOneWidget);
      expect(auth.logouts, 0);
    },
  );

  testWidgets(
    'FIX-327: a right password after two wrong ones clears the wrong-password '
    'count',
    (WidgetTester tester) async {
      final _FakeAuth auth = _FakeAuth();
      int checks = 0;

      await tester.pumpWidget(
        _lockApp(
          auth: auth,
          reauthenticate: (String password) => checkPasswordWithDeviceThrottle(
            email: 'sales1@example.test',
            verify: () async {
              checks += 1;
              if (password != 'right') {
                throw FirebaseAuthException(code: 'wrong-password');
              }
            },
          ),
        ),
      );
      await _goIdle(tester);

      await _enterPassword(tester, 'wrong1');
      await _enterPassword(tester, 'wrong2');
      await _enterPassword(tester, 'right');
      expect(find.text('Session locked'), findsNothing);

      await _goIdle(tester);
      await _enterPassword(tester, 'wrong3');
      expect(find.text('Incorrect password.'), findsOneWidget);
      expect(find.text(kPasswordCheckDelayedText), findsNothing);
      await _enterPassword(tester, 'right');
      expect(find.text('Session locked'), findsNothing);
      expect(checks, 5);
      expect(auth.logouts, 0);
    },
  );

  testWidgets('FIX-327: an account problem is not reported as no connection', (
    WidgetTester tester,
  ) async {
    final _FakeAuth auth = _FakeAuth();
    String code = 'user-disabled';

    await tester.pumpWidget(
      _lockApp(
        auth: auth,
        reauthenticate: (_) => checkPasswordWithDeviceThrottle(
          email: 'sales1@example.test',
          verify: () async => throw FirebaseAuthException(code: code),
        ),
      ),
    );
    await _goIdle(tester);

    await _enterPassword(tester, 'right');
    expect(
      find.text('This account is turned off. Ask your admin.'),
      findsOneWidget,
    );

    code = 'user-token-expired';
    await _enterPassword(tester, 'right');
    expect(
      find.text('Could not check your password. Try again.'),
      findsOneWidget,
    );

    code = 'network-request-failed';
    await _enterPassword(tester, 'right');
    expect(
      find.text('No connection. Reconnect and try again.'),
      findsOneWidget,
    );
    expect(auth.isLoggedIn, isTrue);
    expect(auth.logouts, 0);
  });

  testWidgets('FIX-327: the sign-out button on the lock signs out', (
    WidgetTester tester,
  ) async {
    final _FakeAuth auth = _FakeAuth();

    await tester.pumpWidget(
      _lockApp(auth: auth, reauthenticate: (_) async => null),
    );
    await _goIdle(tester);
    expect(auth.logouts, 0);

    await tester.tap(find.text('Sign in as a different user'));
    await tester.pumpAndSettle();
    expect(auth.logouts, 1);
    expect(auth.isLoggedIn, isFalse);
    expect(find.text('Session locked'), findsNothing);
    expect(await _savedLockedUid(), isNull);
  });

  testWidgets(
    'the next user never sees the previous user\'s open screen, not even while it closes',
    (WidgetTester tester) async {
      final _FakeAuth auth = _FakeAuth();
      final GlobalKey<NavigatorState> navigatorKey =
          GlobalKey<NavigatorState>();

      await tester.pumpWidget(
        MultiProvider(
          providers: <SingleChildWidget>[
            Provider<AuthProvider>.value(value: auth),
          ],
          child: MaterialApp(
            navigatorKey: navigatorKey,
            builder: (BuildContext context, Widget? navigator) =>
                IdleSessionLock(
                  enabled: true,
                  timeout: const Duration(minutes: 10),
                  reauthenticate: (_) async => null,
                  navigatorKey: navigatorKey,
                  child: navigator!,
                ),
            home: const Scaffold(body: Text('Home')),
          ),
        ),
      );
      navigatorKey.currentState!.push(
        MaterialPageRoute<void>(
          builder: (_) => const Scaffold(body: Text('Previous user order')),
        ),
      );
      await _goIdle(tester);
      expect(find.text('Session locked'), findsOneWidget);

      await tester.tap(find.text('Sign in as a different user'));
      for (int frame = 0; frame < 60; frame += 1) {
        await tester.pump(const Duration(milliseconds: 16));
        if (find.text('Session locked').evaluate().isEmpty) {
          expect(
            find.text('Previous user order'),
            findsNothing,
            reason: 'frame $frame after the lock lifted',
          );
        }
      }
      await tester.pumpAndSettle();
      expect(find.text('Session locked'), findsNothing);
      expect(find.text('Previous user order'), findsNothing);
      expect(find.text('Home'), findsOneWidget);
    },
  );
}
