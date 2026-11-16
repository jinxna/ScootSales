import 'dart:async';

import 'dashboard_voice_llm.dart';
import 'dashboard_voice_parser.dart';
import 'dashboard_voice_policy.dart';
import 'dashboard_voice_types.dart';

typedef DashboardVoicePageHandler = FutureOr<void> Function(String pageKey);

class DashboardVoiceEngine {
  DashboardVoiceEngine({
    this.parser = const DashboardVoiceParser(),
    this.policy = const DashboardVoicePolicyGateway(),
    this.proposer,
  });

  final DashboardVoiceParser parser;
  final DashboardVoicePolicyGateway policy;

  final DashboardVoicePageProposer? proposer;
  final Set<String> _seenCaptureIds = <String>{};

  Future<DashboardVoiceEngineOutcome> submitFinalTranscript({
    required String transcript,
    required String captureId,
    required Iterable<DashboardVoicePage> pages,
    required String role,
    required bool isAuthenticated,
    required bool isActive,
    required DashboardVoicePageHandler onPageRequested,
    bool featureEnabled = true,
  }) async {
    final String normalizedCaptureId = captureId.trim();
    if (normalizedCaptureId.isEmpty) {
      throw ArgumentError.value(captureId, 'captureId', 'must not be empty');
    }
    if (!_seenCaptureIds.add(normalizedCaptureId)) {
      return const DashboardVoiceEngineOutcome.duplicate();
    }

    final DashboardVoiceInterpretationResult interpretation = parser.parse(
      transcript,
      pages,
    );
    DashboardVoiceInterpretation? recognized = interpretation.interpretation;
    bool viaLocalModel = false;
    DashboardVoiceAbstention? unresolved = interpretation.abstention;
    if (recognized == null) {
      final _ModelAnswer answer = await _askLocalModel(
        unresolved!,
        transcript,
        pages,
      );
      recognized = answer.interpretation;
      if (recognized == null) {
        final String? tip = answer.suggestedPageKey;
        if (tip != null && !unresolved.suggestedPageKeys.contains(tip)) {
          unresolved = DashboardVoiceAbstention(
            reason: unresolved.reason,
            normalizedTranscript: unresolved.normalizedTranscript,
            suggestedPageKeys: <String>[tip, ...unresolved.suggestedPageKeys],
          );
        }
        return DashboardVoiceEngineOutcome.abstained(
          DashboardVoiceInterpretationResult.abstained(unresolved),
        );
      }
      viaLocalModel = true;
    }

    final DashboardVoicePolicyDecision decision = policy.evaluate(
      interpretation: recognized,
      pages: pages,
      role: role,
      isAuthenticated: isAuthenticated,
      isActive: isActive,
      featureEnabled: featureEnabled,
    );
    if (!decision.isAllowed) {
      return DashboardVoiceEngineOutcome.rejected(
        recognized,
        decision.failure ?? DashboardVoicePolicyFailure.pageNotAllowed,
      ).withLocalModel(viaLocalModel);
    }

    final DashboardVoicePage page = decision.page!;
    try {
      await onPageRequested(page.key);
      return DashboardVoiceEngineOutcome.opened(
        recognized,
        page,
      ).withLocalModel(viaLocalModel);
    } catch (_) {
      return DashboardVoiceEngineOutcome.executionFailed(
        recognized,
        page,
      ).withLocalModel(viaLocalModel);
    }
  }

  Future<_ModelAnswer> _askLocalModel(
    DashboardVoiceAbstention abstention,
    String transcript,
    Iterable<DashboardVoicePage> pages,
  ) async {
    final DashboardVoicePageProposer? proposer = this.proposer;
    if (proposer == null ||
        (abstention.reason !=
                DashboardVoiceAbstentionReason.unsupportedCommand &&
            abstention.reason !=
                DashboardVoiceAbstentionReason.ambiguousPage)) {
      return const _ModelAnswer();
    }
    final List<DashboardVoicePage> catalogue = pages.toList(growable: false);
    try {
      final DashboardVoiceLlmProposal? proposal = await proposer(
        abstention.normalizedTranscript,
        catalogue,
      ).timeout(kVoiceLlmTimeout);
      final String? key = proposal?.pageKey;
      if (proposal == null ||
          key == null ||
          !catalogue.any((DashboardVoicePage page) => page.key == key)) {
        return const _ModelAnswer();
      }
      if (proposal.confidence >= kVoiceLlmMinConfidence) {
        return _ModelAnswer(
          interpretation: DashboardVoiceInterpretation(
            action: DashboardVoiceActionId.openPage,
            pageKey: key,
            normalizedTranscript: abstention.normalizedTranscript,
          ),
        );
      }
      return proposal.confidence >= kVoiceLlmSuggestConfidence
          ? _ModelAnswer(suggestedPageKey: key)
          : const _ModelAnswer();
    } catch (_) {
      return const _ModelAnswer();
    }
  }
}

class _ModelAnswer {
  const _ModelAnswer({this.interpretation, this.suggestedPageKey});

  final DashboardVoiceInterpretation? interpretation;
  final String? suggestedPageKey;
}
