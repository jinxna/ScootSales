import 'dart:async';

import '../utils/quantity_unit.dart';
import '../voice/core/voice_dispatcher.dart';
import '../voice/core/voice_engine.dart';
import '../voice/core/voice_types.dart';

typedef MobileVoiceNavigationCallback =
    FutureOr<void> Function(VoiceActionId action, VoiceEngineOutcome outcome);

const Set<VoiceActionId> kCopilotNavigationActions = <VoiceActionId>{
  VoiceActionId.openAssignedRoute,
  VoiceActionId.openCurrentVisit,
  VoiceActionId.openCart,
  VoiceActionId.openOrderHistory,
};

class CopilotScreenContext {
  const CopilotScreenContext({
    required this.engine,
    this.onNavigationAction,
    this.suggestions = const <String>[],
  });

  final VoiceCommandEngine engine;
  final MobileVoiceNavigationCallback? onNavigationAction;

  final List<String> suggestions;
}

enum CopilotCommandState { pending, running, done, cancelled, failed }

class CopilotPendingCommand {
  CopilotPendingCommand({
    required this.handle,
    required this.outcome,
    required this.screen,
    required this.prompt,
    required this.startedAt,
  });

  final VoiceConfirmationHandle handle;
  final VoiceEngineOutcome outcome;
  final CopilotScreenContext screen;
  final String prompt;
  final DateTime startedAt;
  CopilotCommandState state = CopilotCommandState.pending;
  String note = '';

  Timer? expiry;
}

bool isSuccessfulVoiceResult(VoiceResultCode code) =>
    code == VoiceResultCode.opened || code == VoiceResultCode.applied;

String describeVoiceCommand(VoiceInterpretation interpretation) {
  final Map<String, Object?> p = interpretation.parameters;
  switch (interpretation.action) {
    case VoiceActionId.setDraftOrderQuantity:
      final Object? quantity = p['quantity'];
      final Object? unit = p['unit'];
      final String amount = quantity is int
          ? quantityLabel(quantity, unit is String ? unit : null)
          : '$quantity';
      return 'Set ${p['productQuery']} to $amount?';
    case VoiceActionId.submitOrder:
      return 'Submit this order?';
    case VoiceActionId.completeVisit:
      return 'Complete this visit?';
    case VoiceActionId.changeRouteState:
      return 'Change the route state?';
    case VoiceActionId.recordOutcome:
      return 'Record this visit outcome?';
    default:
      return 'Run "${interpretation.normalizedTranscript}"?';
  }
}

String describeVoiceSuccess(VoiceInterpretation interpretation) {
  final Map<String, Object?> p = interpretation.parameters;
  switch (interpretation.action) {
    case VoiceActionId.openAssignedRoute:
      return 'Opened your route.';
    case VoiceActionId.openCurrentVisit:
      return 'Opened the current visit.';
    case VoiceActionId.openCart:
      return 'Opened the cart.';
    case VoiceActionId.openOrderHistory:
      return 'Opened your order history.';
    case VoiceActionId.searchProducts:
      return 'Searched for "${p['query']}".';
    case VoiceActionId.clearProductSearch:
      return 'Cleared the search.';
    case VoiceActionId.showVisitBrief:
      return 'Opened the visit brief.';
    default:
      return 'Done.';
  }
}

String voiceAbstentionMessage(VoiceAbstentionReason reason) {
  switch (reason) {
    case VoiceAbstentionReason.compoundCommand:
      return 'Say one command at a time.';
    case VoiceAbstentionReason.ambiguousNumericPhrase:
    case VoiceAbstentionReason.malformedParameters:
      return 'I couldn\'t read that amount. Try "set Milo to 5 boxes".';
    case VoiceAbstentionReason.emptyTranscript:
    case VoiceAbstentionReason.unsupportedCommand:
      return 'I couldn\'t match that to a command here.';
  }
}

String voiceResultMessage(VoiceActionResult result) {
  switch (result.code) {
    case VoiceResultCode.rejected:
      switch (result.failure) {
        case VoicePolicyFailure.riskDenied:
          return "Do that on the screen. It can't run from Scout.";
        case VoicePolicyFailure.roleNotAllowed:
          return 'Your role can\'t do that.';
        case VoicePolicyFailure.surfaceNotAllowed:
        case VoicePolicyFailure.handlerUnavailable:
          return 'That isn\'t available on this screen.';
        case VoicePolicyFailure.unauthenticated:
          return 'Sign in again to use commands.';
        case VoicePolicyFailure.featureDisabled:
          return 'Commands are turned off.';
        case VoicePolicyFailure.unavailableOffline:
          return 'That needs a connection.';
        case VoicePolicyFailure.prerequisiteMissing:
          return 'Finish the current step first.';
        default:
          return 'That command isn\'t allowed.';
      }
    case VoiceResultCode.conflict:
      return 'That was already done.';
    case VoiceResultCode.executionFailed:
      return 'That didn\'t work. Nothing changed.';
    case VoiceResultCode.invalidParameters:
      return 'Those details aren\'t valid.';
    case VoiceResultCode.cancelled:
      return 'Cancelled. Nothing changed.';
    case VoiceResultCode.expired:
      return 'That request expired. Ask again.';
    case VoiceResultCode.unavailable:
      return 'That isn\'t available on this screen.';
    case VoiceResultCode.ambiguousEntity:
      return 'More than one item matches. Name it more exactly.';
    case VoiceResultCode.persistenceFailed:
      return 'Couldn\'t save that.';
    case VoiceResultCode.needsConfirmation:
      return 'Confirm first.';
    case VoiceResultCode.opened:
    case VoiceResultCode.applied:
      return 'Done.';
  }
}

bool voiceOutcomeFallsThrough(VoiceEngineOutcome outcome) {
  final VoiceActionResult? result = outcome.actionResult;
  if (result == null) {
    final VoiceAbstentionReason? reason =
        outcome.interpretation.abstention?.reason;
    return reason == null ||
        reason == VoiceAbstentionReason.unsupportedCommand ||
        reason == VoiceAbstentionReason.emptyTranscript;
  }
  return result.code == VoiceResultCode.unavailable ||
      (result.code == VoiceResultCode.rejected &&
          (result.failure == VoicePolicyFailure.unknownAction ||
              result.failure == VoicePolicyFailure.surfaceNotAllowed ||
              result.failure == VoicePolicyFailure.handlerUnavailable));
}
