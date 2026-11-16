import 'dart:convert';

import 'package:firebase_auth/firebase_auth.dart';

import '../control_centre/staff_browser.dart';

Future<Object?> setAsideSavedSignIn({
  required String apiKey,
  required String appName,
}) => takeSavedSignIn('firebase:authUser:$apiKey:$appName');

Future<void> restoreSavedSignIn(
  FirebaseAuth auth,
  Object? saved, {
  required String apiKey,
  required String host,
  required int port,
}) async {
  if (saved is! Map) return;
  final Object? user = saved['value'];
  final Object? tokens = user is Map ? user['stsTokenManager'] : null;
  final Object? refreshToken = tokens is Map ? tokens['refreshToken'] : null;
  if (refreshToken is! String || refreshToken.isEmpty) return;
  final Uri endpoint = Uri(
    scheme: 'http',
    host: host,
    port: port,
    path: '/securetoken.googleapis.com/v1/token',
    queryParameters: <String, String>{'key': apiKey},
  );
  if (!await refreshTokenAccepted(endpoint, refreshToken)) return;
  await putSavedSignIn(saved);
  try {
    await auth
        .authStateChanges()
        .firstWhere((User? restored) => restored != null)
        .timeout(const Duration(seconds: 4));
  } catch (_) {}
}

Future<Object?> setAsideSessionSignIn({
  required String apiKey,
  required String appName,
}) async {
  final String key = 'firebase:authUser:$apiKey:$appName';
  final Object? legacy = await takeSavedSignIn(key);
  final String? raw = sessionRead(key);
  if (raw == null) return legacy;
  sessionRemove(key);
  try {
    return <String, Object?>{'fbase_key': key, 'value': jsonDecode(raw)};
  } catch (_) {
    return legacy;
  }
}
