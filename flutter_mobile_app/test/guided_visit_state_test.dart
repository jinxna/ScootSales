import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/guided_visit_state.dart';

void main() {
  test('pending completion blocks repeat taps with truthful guidance', () {
    final gate = guidedVisitGate(
      stage: GuidedVisitStage.close,
      stopStatus: 'completed',
      orderSubmitted: true,
      completionPending: true,
      outcomeRecorded: false,
      hasDraft: false,
    );

    expect(gate.canAdvance, isFalse);
    expect(gate.actionLabel, 'Completion pending sync');
    expect(gate.blockedReason, contains('saved on this device'));
  });
}
