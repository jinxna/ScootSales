import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/voice/core/action_registry.dart';
import 'package:fmcg_sales/voice/core/voice_binding.dart';
import 'package:fmcg_sales/voice/core/voice_dispatcher.dart';
import 'package:fmcg_sales/voice/core/voice_engine.dart';
import 'package:fmcg_sales/voice/core/voice_types.dart';
import 'package:fmcg_sales/utils/quantity_unit.dart';

void main() {
  test('dispatch prevents concurrent duplicate command IDs', () async {
    final VoiceScreenBinding binding = VoiceScreenBinding(
      surfaceId: VoiceSurfaceIds.overview,
    );
    binding.updateContext(uid: 'user-1', role: 'salesman');
    int calls = 0;
    binding.registerHandler(VoiceActionId.openAssignedRoute, (_) async {
      calls += 1;
      await Future<void>.delayed(Duration.zero);
      return const VoiceActionResult.opened();
    });
    final VoiceCommandEnvelope envelope = VoiceCommandEnvelope(
      sessionId: 'session-1',
      commandId: 'command-1',
      interpretation: VoiceInterpretation(
        action: VoiceActionId.openAssignedRoute,
        parameters: <String, Object?>{},
        normalizedTranscript: 'open my assigned route',
      ),
      context: binding.snapshot(),
      createdTick: 0,
      expiresAtTick: 1000,
    );
    final VoiceActionDispatcher dispatcher = VoiceActionDispatcher(
      registry: VoiceActionRegistry.defaultRegistry(maxOrderQuantity: 5),
      binding: binding,
    );

    final List<VoiceActionResult> results =
        await Future.wait(<Future<VoiceActionResult>>[
          dispatcher.dispatch(envelope, currentTick: 1, isOnline: true),
          dispatcher.dispatch(envelope, currentTick: 1, isOnline: true),
        ]);

    expect(
      results.map((VoiceActionResult result) => result.code),
      contains(VoiceResultCode.conflict),
    );
    expect(
      results.map((VoiceActionResult result) => result.code),
      contains(VoiceResultCode.opened),
    );
    expect(calls, 1);
  });

  test('same final callback for one capture executes at most once', () async {
    final VoiceScreenBinding binding = VoiceScreenBinding(
      surfaceId: VoiceSurfaceIds.overview,
    );
    binding.updateContext(uid: 'user-1', role: 'salesman');
    int calls = 0;
    binding.registerHandler(VoiceActionId.openAssignedRoute, (_) async {
      calls += 1;
      return const VoiceActionResult.opened();
    });
    final VoiceActionDispatcher dispatcher = VoiceActionDispatcher(
      registry: VoiceActionRegistry.defaultRegistry(maxOrderQuantity: 5),
      binding: binding,
    );
    final VoiceCommandEngine engine = VoiceCommandEngine(
      sessionId: 'session-1',
      binding: binding,
      dispatcher: dispatcher,
      tickProvider: () => 0,
    );

    final VoiceEngineOutcome first = await engine.submitFinalTranscript(
      'Open my assigned route',
      captureId: 'capture-duplicate',
    );
    final VoiceEngineOutcome duplicate = await engine.submitFinalTranscript(
      'Open my assigned route',
      captureId: 'capture-duplicate',
    );

    expect(first.actionResult!.code, VoiceResultCode.opened);
    expect(duplicate.actionResult!.code, VoiceResultCode.conflict);
    expect(calls, 1);
  });

  test(
    'duplicate final does not expose the original confirmation handle',
    () async {
      final VoiceScreenBinding binding = VoiceScreenBinding(
        surfaceId: VoiceSurfaceIds.orderCart,
      );
      binding.updateContext(uid: 'user-1', role: 'salesman');
      binding.registerHandler(VoiceActionId.setDraftOrderQuantity, (_) async {
        return const VoiceActionResult.applied();
      });
      final VoiceActionRegistry registry = VoiceActionRegistry(
        <VoiceActionDefinition>[
          VoiceActionDefinition(
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
          ),
        ],
      );
      final VoiceCommandEngine engine = VoiceCommandEngine(
        sessionId: 'session-1',
        binding: binding,
        dispatcher: VoiceActionDispatcher(registry: registry, binding: binding),
        tickProvider: () => 0,
      );

      final VoiceEngineOutcome preview = await engine.submitFinalTranscript(
        'Set Milo 1kg to one box',
        captureId: 'capture-handle-duplicate',
      );
      final VoiceEngineOutcome duplicate = await engine.submitFinalTranscript(
        'Set Coke 1.5L to five boxes',
        captureId: 'capture-handle-duplicate',
      );

      expect(preview.actionResult!.code, VoiceResultCode.needsConfirmation);
      expect(preview.confirmationHandle, isNotNull);
      expect(duplicate.actionResult!.code, VoiceResultCode.conflict);
      expect(duplicate.confirmationHandle, isNull);
    },
  );

  test(
    'consumes a command ID when a handler throws after doing work',
    () async {
      final VoiceScreenBinding binding = VoiceScreenBinding(
        surfaceId: VoiceSurfaceIds.overview,
      );
      binding.updateContext(uid: 'user-1', role: 'salesman');
      int calls = 0;
      binding.registerHandler(VoiceActionId.openAssignedRoute, (_) async {
        calls += 1;
        throw StateError('effect completed before reporting failure');
      });
      final VoiceCommandEnvelope envelope = VoiceCommandEnvelope(
        sessionId: 'session-1',
        commandId: 'command-throws',
        interpretation: VoiceInterpretation(
          action: VoiceActionId.openAssignedRoute,
          parameters: <String, Object?>{},
          normalizedTranscript: 'open my assigned route',
        ),
        context: binding.snapshot(),
        createdTick: 0,
        expiresAtTick: 1000,
      );
      final VoiceActionDispatcher dispatcher = VoiceActionDispatcher(
        registry: VoiceActionRegistry.defaultRegistry(maxOrderQuantity: 5),
        binding: binding,
      );

      final VoiceActionResult first = await dispatcher.dispatch(
        envelope,
        currentTick: 1,
        isOnline: true,
      );
      final VoiceActionResult second = await dispatcher.dispatch(
        envelope,
        currentTick: 1,
        isOnline: true,
      );

      expect(first.code, VoiceResultCode.executionFailed);
      expect(second.code, VoiceResultCode.conflict);
      expect(calls, 1);
    },
  );
}
