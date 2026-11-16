import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/dev/emulator_wiring.dart';

void main() {
  test('a plain build never wires an emulator', () {
    final EmulatorWiringDecision decision = decideEmulatorWiring(
      requested: false,
      host: '127.0.0.1',
      isWeb: true,
    );
    expect(decision.wire, isFalse);
    expect(decision.message, isEmpty);
  });
}
