import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/voice/core/action_registry.dart';
import 'package:fmcg_sales/voice/core/voice_binding.dart';
import 'package:fmcg_sales/voice/core/voice_dispatcher.dart';
import 'package:fmcg_sales/voice/core/voice_policy_gateway.dart';
import 'package:fmcg_sales/voice/core/voice_types.dart';
import 'package:fmcg_sales/utils/quantity_unit.dart';

VoiceScreenBinding makeBinding({
  String surfaceId = VoiceSurfaceIds.orderCart,
  String uid = 'user-1',
  String role = 'salesman',
  String? retailerId = 'retailer-1',
  String? visitId = 'visit-1',
  String? draftId = 'draft-1',
  int? draftRevision = 1,
}) {
  final VoiceScreenBinding binding = VoiceScreenBinding(surfaceId: surfaceId);
  binding.updateContext(
    uid: uid,
    role: role,
    retailerId: retailerId,
    visitId: visitId,
    draftId: draftId,
    draftRevision: draftRevision,
  );
  return binding;
}

VoiceCommandEnvelope makeEnvelope(
  VoiceScreenBinding binding,
  VoiceActionId action, {
  Map<String, Object?> parameters = const <String, Object?>{},
  int createdTick = 0,
  int expiresAtTick = 1000,
  String sessionId = 'session-1',
  String commandId = 'command-1',
}) {
  return VoiceCommandEnvelope(
    sessionId: sessionId,
    commandId: commandId,
    interpretation: VoiceInterpretation(
      action: action,
      parameters: parameters,
      normalizedTranscript: action.code,
    ),
    context: binding.snapshot(),
    createdTick: createdTick,
    expiresAtTick: expiresAtTick,
  );
}

VoiceActionDefinition yellowDefinition() {
  return VoiceActionDefinition(
    id: VoiceActionId.setDraftOrderQuantity,
    schemaVersion: 1,
    risk: VoiceRisk.yellow,
    permittedRoles: const <String>{'salesman'},
    permittedSurfaces: const <String>{VoiceSurfaceIds.orderCart},
    parameterNames: const <String>{'productQuery', 'quantity', 'unit'},
    enabled: true,
    requiresConfirmation: true,
    allowOffline: true,
    requiresAuthenticatedUser: true,
    maxQuantity: defaultMaxQtyPerLine,
  );
}

void main() {
  test('denies Red and blocked actions through registry risk', () {
    final VoiceScreenBinding binding = makeBinding(
      surfaceId: VoiceSurfaceIds.guidedVisit,
    );
    final VoicePolicyDecision decision =
        VoicePolicyGateway(
          registry: VoiceActionRegistry.defaultRegistry(maxOrderQuantity: 5),
          binding: binding,
        ).evaluate(
          envelope: makeEnvelope(binding, VoiceActionId.submitOrder),
          currentTick: 10,
          isOnline: true,
        );

    expect(decision.kind, VoiceDecisionKind.rejected);
    expect(decision.failure, VoicePolicyFailure.riskDenied);
  });

  test('cannot reclassify a protected action as Green or enable it', () {
    expect(
      () => VoiceActionRegistry(<VoiceActionDefinition>[
        VoiceActionDefinition(
          id: VoiceActionId.submitOrder,
          schemaVersion: 1,
          risk: VoiceRisk.green,
          permittedRoles: const <String>{'salesman'},
          permittedSurfaces: const <String>{VoiceSurfaceIds.orderCart},
          parameterNames: const <String>{},
          enabled: true,
          requiresConfirmation: false,
          allowOffline: true,
          requiresAuthenticatedUser: true,
        ),
      ]),
      throwsStateError,
    );

    expect(
      () => VoiceActionRegistry(<VoiceActionDefinition>[
        VoiceActionDefinition(
          id: VoiceActionId.setDraftOrderQuantity,
          schemaVersion: 1,
          risk: VoiceRisk.green,
          permittedRoles: const <String>{'salesman'},
          permittedSurfaces: const <String>{VoiceSurfaceIds.orderCart},
          parameterNames: const <String>{'productQuery', 'quantity', 'unit'},
          enabled: true,
          requiresConfirmation: false,
          allowOffline: true,
          requiresAuthenticatedUser: true,
        ),
      ]),
      throwsStateError,
    );
  });

  test('reserves a Yellow command while confirmation is pending', () async {
    final VoiceScreenBinding binding = makeBinding();
    int calls = 0;
    late VoiceCommandEnvelope executedEnvelope;
    binding.registerHandler(VoiceActionId.setDraftOrderQuantity, (
      envelope,
    ) async {
      calls += 1;
      executedEnvelope = envelope;
      return const VoiceActionResult.applied();
    });
    final VoiceActionDispatcher dispatcher = VoiceActionDispatcher(
      registry: VoiceActionRegistry(<VoiceActionDefinition>[
        yellowDefinition(),
      ]),
      binding: binding,
    );
    final VoiceCommandEnvelope envelope = makeEnvelope(
      binding,
      VoiceActionId.setDraftOrderQuantity,
      parameters: const <String, Object?>{
        'productQuery': 'milo 1kg',
        'quantity': 3,
        'unit': 'box',
      },
    );

    final VoiceActionResult first = await dispatcher.dispatch(
      envelope,
      currentTick: 10,
      isOnline: true,
    );
    final VoiceActionResult duplicate = await dispatcher.dispatch(
      envelope,
      currentTick: 10,
      isOnline: true,
    );
    final VoiceConfirmationHandle handle = dispatcher.confirmationHandleFor(
      envelope,
    )!;
    final VoiceActionResult confirmed = await dispatcher.confirm(
      handle,
      currentTick: 10,
      isOnline: true,
    );
    final VoiceActionResult replayedConfirmation = await dispatcher.confirm(
      handle,
      currentTick: 10,
      isOnline: true,
    );

    expect(first.code, VoiceResultCode.needsConfirmation);
    expect(duplicate.code, VoiceResultCode.conflict);
    expect(executedEnvelope.interpretation.parameters['quantity'], 3);
    expect(confirmed.code, VoiceResultCode.applied);
    expect(replayedConfirmation.code, VoiceResultCode.conflict);
    expect(calls, 1);
  });

  test('expired pending confirmation is pruned and cannot execute', () async {
    final VoiceScreenBinding binding = makeBinding();
    int calls = 0;
    binding.registerHandler(VoiceActionId.setDraftOrderQuantity, (_) async {
      calls += 1;
      return const VoiceActionResult.applied();
    });
    final VoiceActionDispatcher dispatcher = VoiceActionDispatcher(
      registry: VoiceActionRegistry(<VoiceActionDefinition>[
        yellowDefinition(),
      ]),
      binding: binding,
    );
    final VoiceCommandEnvelope envelope = makeEnvelope(
      binding,
      VoiceActionId.setDraftOrderQuantity,
      expiresAtTick: 10,
      parameters: const <String, Object?>{
        'productQuery': 'milo 1kg',
        'quantity': 3,
        'unit': 'box',
      },
    );
    await dispatcher.dispatch(envelope, currentTick: 0, isOnline: true);
    final VoiceConfirmationHandle handle = dispatcher.confirmationHandleFor(
      envelope,
    )!;

    final VoiceActionResult expired = await dispatcher.confirm(
      handle,
      currentTick: 10,
      isOnline: true,
    );

    expect(expired.code, VoiceResultCode.expired);
    expect(dispatcher.confirmationHandleFor(envelope), isNull);
    expect(calls, 0);
  });
}
