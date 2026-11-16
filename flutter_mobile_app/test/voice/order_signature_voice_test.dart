import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/voice/core/action_registry.dart';
import 'package:fmcg_sales/voice/core/voice_binding.dart';
import 'package:fmcg_sales/voice/core/voice_dispatcher.dart';
import 'package:fmcg_sales/voice/core/voice_types.dart';
import 'package:fmcg_sales/voice/voice_registry_factory.dart';

VoiceScreenBinding _signatureBinding({
  String surfaceId = VoiceSurfaceIds.orderSignature,
}) {
  final VoiceScreenBinding binding = VoiceScreenBinding(surfaceId: surfaceId);
  binding.updateContext(
    uid: 'salesman-1',
    role: 'salesman',
    retailerId: 'retailer-1',
    visitId: 'visit-1',
    draftId: 'draft-1',
  );
  return binding;
}

VoiceCommandEnvelope _quantityEnvelope(
  VoiceScreenBinding binding, {
  int quantity = 3,
  String commandId = 'command-1',
}) {
  return VoiceCommandEnvelope(
    sessionId: 'session-1',
    commandId: commandId,
    interpretation: VoiceInterpretation(
      action: VoiceActionId.setDraftOrderQuantity,
      parameters: <String, Object?>{
        'productQuery': 'Milo 1kg',
        'quantity': quantity,
        'unit': 'box',
      },
      normalizedTranscript: 'set milo 1kg to $quantity boxes',
    ),
    context: binding.snapshot(),
    createdTick: 0,
    expiresAtTick: 1000,
  );
}

void main() {
  test('the handler runs only after the confirmation is confirmed', () async {
    final VoiceScreenBinding binding = _signatureBinding();
    int handlerCalls = 0;
    binding.registerHandler(VoiceActionId.setDraftOrderQuantity, (_) async {
      handlerCalls += 1;
      return const VoiceActionResult.applied();
    });
    final VoiceActionDispatcher dispatcher = VoiceActionDispatcher(
      registry: buildVoiceActionRegistry(),
      binding: binding,
    );
    final VoiceCommandEnvelope envelope = _quantityEnvelope(binding);

    final VoiceActionResult first = await dispatcher.dispatch(
      envelope,
      currentTick: 1,
      isOnline: true,
    );
    expect(first.code, VoiceResultCode.needsConfirmation);
    expect(handlerCalls, 0);

    final VoiceConfirmationHandle handle = dispatcher.confirmationHandleFor(
      envelope,
    )!;
    final VoiceActionResult confirmed = await dispatcher.confirm(
      handle,
      currentTick: 2,
      isOnline: true,
    );
    expect(confirmed.code, VoiceResultCode.applied);
    expect(handlerCalls, 1);

    final VoiceActionResult replayed = await dispatcher.confirm(
      handle,
      currentTick: 3,
      isOnline: true,
    );
    expect(replayed.code, VoiceResultCode.conflict);
    expect(handlerCalls, 1);
  });

  test(
    'an order-submitting voice command stays blocked on this surface',
    () async {
      final VoiceScreenBinding binding = _signatureBinding();
      binding.registerHandler(
        VoiceActionId.submitOrder,
        (_) async => const VoiceActionResult.applied(),
      );
      final VoiceCommandEnvelope envelope = VoiceCommandEnvelope(
        sessionId: 'session-1',
        commandId: 'submit-1',
        interpretation: VoiceInterpretation(
          action: VoiceActionId.submitOrder,
          parameters: const <String, Object?>{},
          normalizedTranscript: 'submit order',
        ),
        context: binding.snapshot(),
        createdTick: 0,
        expiresAtTick: 1000,
      );

      final VoiceActionResult result = await VoiceActionDispatcher(
        registry: buildVoiceActionRegistry(),
        binding: binding,
      ).dispatch(envelope, currentTick: 1, isOnline: true);

      expect(result.code, VoiceResultCode.rejected);
      expect(result.failure, VoicePolicyFailure.riskDenied);
    },
  );
}
