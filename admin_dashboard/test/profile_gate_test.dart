import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/security/profile_gate.dart';

void main() {
  test('a failed lookup is never reported as a missing profile', () {
    final ProfileGateState gate = decideProfileGate(
      waiting: false,
      failed: true,
      role: '',
      active: false,
    );
    expect(gate, ProfileGateState.lookupFailed);
    expect(gate, isNot(ProfileGateState.missingProfile));
  });

  test('a suspended profile is reported as suspended, not as a role', () {
    expect(
      decideProfileGate(
        waiting: false,
        failed: false,
        role: 'branch_manager',
        active: false,
      ),
      ProfileGateState.suspended,
    );
  });
}
