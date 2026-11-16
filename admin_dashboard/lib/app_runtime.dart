class AppRuntime {
  static bool firebaseReady = false;

  static String emulatorHost = '';

  static String backendWarning = '';

  static bool get usesLocalEmulator => emulatorHost.isNotEmpty;
}
