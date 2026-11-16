import 'package:firebase_app_check/firebase_app_check.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart'
    show FlutterExceptionHandler, kDebugMode, kIsWeb;
import 'package:flutter/material.dart';
import 'package:flutter/semantics.dart';

import 'app.dart';
import 'app/browser_page_history.dart';
import 'app/invite_link.dart';
import 'app/workspace_runtime.dart';
import 'app_runtime.dart';
import 'dev/emulator_saved_sign_in.dart';
import 'dev/emulator_wiring.dart';

Future<void> main() async {
  WidgetsFlutterBinding.ensureInitialized();
  if (emulatorRequested()) SemanticsBinding.instance.ensureSemantics();
  disableEngineBrowserHistory();

  final Uri address = Uri.base;
  InviteLink.pending = InviteLink.fromUri(address);
  if (InviteLink.pending != null) replaceBrowserPageFragment('');

  try {
    final WorkspaceConfig workspace = await WorkspaceRuntime.load(address);
    final EmulatorWiringDecision decision = decideEmulatorWiring(
      requested: emulatorRequested(),
      host: configuredEmulatorHost(),
      isWeb: kIsWeb,
    );
    final Object? saved = decision.wire
        ? await setAsideSavedSignIn(
            apiKey: workspace.options.apiKey,
            appName: defaultFirebaseAppName,
          )
        : null;
    await Firebase.initializeApp(options: workspace.options);
    FirebaseAuth.instance.tenantId = workspace.authTenantId;
    await _connectLocalEmulatorsIfRequested(decision);
    final String? appCheckSiteKey = workspace.appCheckSiteKey;
    if (appCheckSiteKey != null && !decision.wire && !kDebugMode) {
      await _activateAppCheck(appCheckSiteKey);
    }
    if (decision.wire) {
      await restoreSavedSignIn(
        FirebaseAuth.instance,
        saved,
        apiKey: workspace.options.apiKey,
        host: configuredEmulatorHost(),
        port: _authEmulatorPort,
      );
    }
    AppRuntime.firebaseReady = true;
  } on WorkspaceLoadException catch (error) {
    debugPrint('Workspace load failed: $error');
    AppRuntime.firebaseReady = false;
    WorkspaceRuntime.loadError = error.message;
    AppRuntime.backendWarning = error.message;
  } catch (error) {
    debugPrint('Firebase init failed: $error');
    AppRuntime.firebaseReady = false;
  }

  runApp(const DigitalSalesOrderAdminWebApp());
}

Future<void> _activateAppCheck(String siteKey) async {
  try {
    await FirebaseAppCheck.instance.activate(
      providerWeb: ReCaptchaEnterpriseProvider(siteKey),
    );
  } catch (error) {
    debugPrint('App Check could not start: $error');
  }
}

const int _authEmulatorPort = int.fromEnvironment(
  'FIREBASE_AUTH_EMULATOR_PORT',
  defaultValue: 9099,
);

Future<void> _connectLocalEmulatorsIfRequested(
  EmulatorWiringDecision decision,
) async {
  AppRuntime.emulatorHost = decision.wire ? configuredEmulatorHost() : '';
  AppRuntime.backendWarning = decision.message;
  if (!decision.wire) {
    if (decision.message.isNotEmpty) debugPrint(decision.message);
    return;
  }
  if (decision.message.isNotEmpty) debugPrint(decision.message);
  final String host = configuredEmulatorHost();
  FirebaseFirestore.instance.useFirestoreEmulator(
    host,
    const int.fromEnvironment('FIRESTORE_EMULATOR_PORT', defaultValue: 8089),
  );
  await FirebaseAuth.instance.useAuthEmulator(host, _authEmulatorPort);
  debugPrint('Local Firebase emulators enabled at $host');
  final FlutterExceptionHandler? report = FlutterError.onError;
  FlutterError.onError = (FlutterErrorDetails details) {
    debugPrint('FLUTTER_ERROR: ${details.exceptionAsString()}');
    report?.call(details);
  };
}
