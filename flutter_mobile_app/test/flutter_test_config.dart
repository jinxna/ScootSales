import 'dart:async';

import 'support/test_firebase.dart';

Future<void> testExecutable(FutureOr<void> Function() testMain) async {
  await installTestFirebase();
  await testMain();
}
