import 'voice_types.dart';

class DeterministicCommandParser {
  const DeterministicCommandParser();

  VoiceInterpretationResult parse(String transcript) {
    final String normalized = normalize(transcript);
    if (normalized.isEmpty) {
      return _abstain(normalized, VoiceAbstentionReason.emptyTranscript);
    }

    if (_looksLikeCompoundCommand(normalized)) {
      return _abstain(normalized, VoiceAbstentionReason.compoundCommand);
    }

    if (_matches(
      normalized,
      r'^(?:please\s+)?(?:clear(?:\s+the)?(?:\s+(?:product|item))?\s+search|remove(?:\s+the)?(?:\s+(?:product|item))?\s+filter|reset(?:\s+the)?(?:\s+(?:product|item))?\s+search(?:\s+box)?|show\s+all\s+products)$',
    )) {
      return _recognized(
        normalized,
        VoiceActionId.clearProductSearch,
        const <String, Object?>{},
      );
    }

    final RegExpMatch? quantity = RegExp(
      r'^(?:please\s+)?(?:set|change|update)\s+(.+?)\s+to\s+([a-z0-9]+)\s+(box(?:es)?|sets?|pcs?|pieces?|units?)$',
    ).firstMatch(normalized);
    if (quantity != null) {
      final int? parsedQuantity = _parseQuantity(quantity.group(2)!);
      if (parsedQuantity == null) {
        return _abstain(
          normalized,
          VoiceAbstentionReason.ambiguousNumericPhrase,
        );
      }
      return _recognized(
        normalized,
        VoiceActionId.setDraftOrderQuantity,
        <String, Object?>{
          'productQuery': quantity.group(1)!,
          'quantity': parsedQuantity,
          'unit': _singularUnit(quantity.group(3)!),
        },
      );
    }

    if (_looksLikeQuantityCommand(normalized)) {
      return _abstain(normalized, VoiceAbstentionReason.malformedParameters);
    }

    if (_matches(
      normalized,
      r"^(?:please\s+)?(?:(?:open|show|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:assigned\s+)?(?:route|visits?)(?:\s+for\s+today)?)|take me to (?:today's\s+route|(?:the\s+)?(?:assigned\s+)?(?:route|visits?)))$",
    )) {
      return _recognized(
        normalized,
        VoiceActionId.openAssignedRoute,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r"^(?:please\s+)?(?:(?:open|show|view|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:order history|previous orders|past orders|orders))|take me to (?:the\s+)?(?:order history|previous orders|past orders))$",
    )) {
      return _recognized(
        normalized,
        VoiceActionId.openOrderHistory,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r"^(?:please\s+)?(?:(?:open|show|view|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:current visit|active retailer visit))|take me to (?:the\s+)?(?:current visit|visit i am working on))$",
    )) {
      return _recognized(
        normalized,
        VoiceActionId.openCurrentVisit,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r"^(?:please\s+)?(?:(?:open|show|bring up)(?:\s+(?:the\s+)?(?:my\s+)?(?:cart|order cart|current cart|current order workspace))|take me to (?:the\s+)?(?:cart|order cart|current cart))$",
    )) {
      return _recognized(
        normalized,
        VoiceActionId.openCart,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r"^(?:please\s+)?(?:(?:show|open|read)(?:\s+(?:the\s+)?(?:visit\s+)?brief)|(?:show|open|read)(?:\s+(?:the\s+)?(?:active\s+)?retailer\s+brief)|give\s+me\s+(?:the\s+)?(?:today's\s+)?(?:visit\s+)?brief|tell\s+me\s+about\s+this\s+visit|show(?:\s+today's)?\s+visit\s+insights|what\s+are\s+my\s+visit\s+insights|what\s+should\s+i\s+know\s+about\s+this\s+visit)$",
    )) {
      return _recognized(
        normalized,
        VoiceActionId.showVisitBrief,
        const <String, Object?>{},
      );
    }

    final RegExpMatch? search = RegExp(
      r'^(?:please\s+)?(?:find|search(?:\s+for)?|look for)\s+(.+)$',
    ).firstMatch(normalized);
    if (search != null && search.group(1)!.trim().isNotEmpty) {
      return _recognized(
        normalized,
        VoiceActionId.searchProducts,
        <String, Object?>{'query': search.group(1)!.trim()},
      );
    }

    if (_matches(
      normalized,
      r'^(?:please\s+)?(?:submit|place)\s+(?:this\s+)?order$',
    )) {
      return _recognized(
        normalized,
        VoiceActionId.submitOrder,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r'^(?:please\s+)?(?:complete|finish|close)\s+(?:this\s+)?visit$',
    )) {
      return _recognized(
        normalized,
        VoiceActionId.completeVisit,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r'^(?:please\s+)?(?:change|update)\s+(?:the\s+)?route\s+(?:status|state)$',
    )) {
      return _recognized(
        normalized,
        VoiceActionId.changeRouteState,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r'^(?:please\s+)?(?:record|add)\s+(?:a\s+)?(?:visit\s+)?outcome$',
    )) {
      return _recognized(
        normalized,
        VoiceActionId.recordOutcome,
        const <String, Object?>{},
      );
    }

    if (_matches(
      normalized,
      r'^(?:please\s+)?(?:change|turn on|turn off)\s+(?:my\s+)?(?:location|permissions?)$',
    )) {
      return _recognized(
        normalized,
        normalized.contains('permission')
            ? VoiceActionId.changePermissions
            : VoiceActionId.changeLocationState,
        const <String, Object?>{},
      );
    }

    return _abstain(normalized, VoiceAbstentionReason.unsupportedCommand);
  }

  static String normalize(String transcript) {
    return transcript
        .toLowerCase()
        .replaceAll(RegExp('[’‘]'), "'")
        .replaceAll(RegExp(r'(?<!\d)\.(?!\d)'), ' ')
        .replaceAll(RegExp(r'[!?,;:]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static VoiceInterpretationResult _recognized(
    String normalized,
    VoiceActionId action,
    Map<String, Object?> parameters,
  ) {
    return VoiceInterpretationResult.recognized(
      VoiceInterpretation(
        action: action,
        parameters: parameters,
        normalizedTranscript: normalized,
      ),
    );
  }

  static VoiceInterpretationResult _abstain(
    String normalized,
    VoiceAbstentionReason reason,
  ) {
    return VoiceInterpretationResult.abstained(
      VoiceAbstention(reason: reason, normalizedTranscript: normalized),
    );
  }

  static bool _matches(String value, String pattern) {
    return RegExp(pattern).hasMatch(value);
  }

  static bool _looksLikeQuantityCommand(String value) {
    return RegExp(r'^(?:please\s+)?(?:set|change|update)\b').hasMatch(value);
  }

  static bool _looksLikeCompoundCommand(String value) {
    return RegExp(
      r'\b(?:and|then)\s+(?:open|show|bring up|find|search|clear|remove|reset|submit|place|complete|finish|record|change|update)\b',
    ).hasMatch(value);
  }

  static String _singularUnit(String token) {
    if (token == 'boxes') return 'box';
    return token.endsWith('s') ? token.substring(0, token.length - 1) : token;
  }

  static int? _parseQuantity(String token) {
    final int? numeric = int.tryParse(token);
    if (numeric != null) return numeric;

    const Map<String, int> numberWords = <String, int>{
      'one': 1,
      'two': 2,
      'three': 3,
      'four': 4,
      'five': 5,
      'six': 6,
      'seven': 7,
      'eight': 8,
      'nine': 9,
      'ten': 10,
    };
    return numberWords[token];
  }
}
