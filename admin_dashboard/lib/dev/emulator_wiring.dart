import 'package:flutter/foundation.dart' show kIsWeb;

const String androidEmulatorHostAlias = '10.0.2.2';

class EmulatorWiringDecision {
  const EmulatorWiringDecision({required this.wire, this.message = ''});

  final bool wire;

  final String message;
}

EmulatorWiringDecision decideEmulatorWiring({
  required bool requested,
  required String host,
  required bool isWeb,
}) {
  if (!requested) {
    return const EmulatorWiringDecision(wire: false);
  }
  if (host == androidEmulatorHostAlias) {
    return isWeb
        ? const EmulatorWiringDecision(
            wire: false,
            message:
                'Ignoring USE_FIREBASE_EMULATOR: FIREBASE_EMULATOR_HOST=10.0.2.2 '
                'is the Android emulator alias and cannot work in a browser. The '
                'app is using the real project; pass 127.0.0.1 to drive the local '
                'emulators.',
          )
        : const EmulatorWiringDecision(wire: true);
  }
  final bool loopback =
      host == '127.0.0.1' || host == 'localhost' || host == '::1';
  return EmulatorWiringDecision(
    wire: true,
    message: loopback
        ? ''
        : 'USE_FIREBASE_EMULATOR with a non-loopback host ($host). If the app '
              'cannot reach it, accounts will resolve to no profile.',
  );
}

String configuredEmulatorHost() => const String.fromEnvironment(
  'FIREBASE_EMULATOR_HOST',
  defaultValue: '127.0.0.1',
);

bool emulatorRequested() => const bool.fromEnvironment('USE_FIREBASE_EMULATOR');

bool get runningOnWeb => kIsWeb;
