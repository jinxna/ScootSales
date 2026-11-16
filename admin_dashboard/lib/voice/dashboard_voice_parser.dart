import 'dashboard_voice_ranker.dart';
import 'dashboard_voice_types.dart';

class DashboardVoiceParser {
  const DashboardVoiceParser();

  DashboardVoiceInterpretationResult parse(
    String transcript,
    Iterable<DashboardVoicePage> pages,
  ) {
    final String normalized = normalize(transcript);
    if (normalized.isEmpty) {
      return _abstain(
        normalized,
        DashboardVoiceAbstentionReason.emptyTranscript,
      );
    }

    if (_looksLikeCompoundCommand(normalized)) {
      return _abstain(
        normalized,
        DashboardVoiceAbstentionReason.compoundCommand,
      );
    }

    final List<DashboardVoicePage> directMatches = _findCandidates(
      normalized,
      pages,
      allowFuzzy: false,
    );
    if (directMatches.length == 1) {
      return DashboardVoiceInterpretationResult.recognized(
        DashboardVoiceInterpretation(
          action: DashboardVoiceActionId.openPage,
          pageKey: directMatches.single.key,
          normalizedTranscript: normalized,
        ),
      );
    }

    final String stripped = _stripLeadIns(normalized);
    final RegExpMatch? command = _navigationVerb.firstMatch(stripped);
    final bool hasNavigationVerb = command != null;
    final String query = _cleanPageQuery(command?.group(1) ?? stripped);
    if (query.isEmpty) {
      return _byRanking(
        normalized,
        pages,
        DashboardVoiceAbstentionReason.unsupportedCommand,
      );
    }

    final List<DashboardVoicePage> candidates = _findCandidates(
      query,
      pages,
      allowFuzzy: hasNavigationVerb,
    );
    if (candidates.length != 1) {
      return _byRanking(
        normalized,
        pages,
        candidates.length > 1
            ? DashboardVoiceAbstentionReason.ambiguousPage
            : DashboardVoiceAbstentionReason.unsupportedCommand,
      );
    }

    return DashboardVoiceInterpretationResult.recognized(
      DashboardVoiceInterpretation(
        action: DashboardVoiceActionId.openPage,
        pageKey: candidates.single.key,
        normalizedTranscript: normalized,
      ),
    );
  }

  static String normalize(String transcript) {
    return transcript
        .toLowerCase()
        .replaceAll(RegExp('[’‘]'), "'")
        .replaceAll(RegExp(r'[.!?,;:]'), ' ')
        .replaceAll(RegExp(r'\s+'), ' ')
        .trim();
  }

  static List<DashboardVoicePage> _findCandidates(
    String query,
    Iterable<DashboardVoicePage> pages, {
    required bool allowFuzzy,
  }) {
    final String normalizedQuery = _singularise(query);
    final List<DashboardVoicePage> allPages = pages.toList(growable: false);

    final List<DashboardVoicePage> exact = allPages
        .where(
          (DashboardVoicePage page) =>
              page.aliases.any(
                (String alias) => _singularise(alias) == normalizedQuery,
              ) ||
              _singularise(page.label) == normalizedQuery ||
              _singularise(page.key) == normalizedQuery,
        )
        .toList(growable: false);
    if (exact.isNotEmpty) return exact;
    if (!allowFuzzy) return const <DashboardVoicePage>[];

    final List<String> terms = normalizedQuery.split(' ');
    return allPages
        .where((DashboardVoicePage page) {
          final Set<String> words = _singularise(
            page.searchText,
          ).split(' ').toSet();
          return terms.every(words.contains);
        })
        .toList(growable: false);
  }

  static final RegExp _leadIn = RegExp(
    r"^(?:can you|could you|would you|will you|please|hey|i want to|i'd like to|i would like to|let me|help me)\s+",
  );
  static final RegExp _navigationVerb = RegExp(
    r'^(?:open(?: up)?|show|view|display|check|see|pull up|load|launch|go to|jump to|switch to|navigate to|take me to|bring up|find|search for)\s+(.+)$',
  );
  static const Set<String> _leadingFillers = <String>{
    'the',
    'a',
    'my',
    'our',
    'me',
    'page',
    'screen',
    'tab',
    'section',
    'list',
  };
  static const Set<String> _trailingFillers = <String>{
    'please', 'page', 'screen', 'now', 'tab', 'list',
  };

  static String _stripLeadIns(String value) {
    String result = value;
    while (_leadIn.hasMatch(result)) {
      result = result.replaceFirst(_leadIn, '');
    }
    return result;
  }

  static String _cleanPageQuery(String value) {
    final List<String> terms = normalize(value).split(' ')
      ..removeWhere((String term) => term.isEmpty);
    while (terms.isNotEmpty &&
        (_leadingFillers.contains(terms.first) ||
            DashboardVoiceRanker.isNearFiller(terms.first))) {
      terms.removeAt(0);
    }
    while (terms.isNotEmpty) {
      if (_trailingFillers.contains(terms.last) ||
          DashboardVoiceRanker.isNearFiller(terms.last)) {
        terms.removeLast();
      } else if (terms.length >= 2 &&
          terms[terms.length - 2] == 'for' &&
          terms.last == 'me') {
        terms.length -= 2;
      } else {
        break;
      }
    }
    return terms.join(' ');
  }

  static String _singularise(String value) {
    return normalize(value.replaceAll('_', ' '))
        .split(' ')
        .map((String word) {
          if (word.length > 4 && word.endsWith('ies')) {
            return '${word.substring(0, word.length - 3)}y';
          }
          if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
            return word.substring(0, word.length - 1);
          }
          return word;
        })
        .join(' ');
  }

  static bool _looksLikeCompoundCommand(String value) {
    return RegExp(
      r'\b(?:and|then)\s+(?:open|show|view|display|check|see|pull|load|launch|go|jump|switch|navigate|take|bring|find|search)\b',
    ).hasMatch(value);
  }

  static DashboardVoiceInterpretationResult _byRanking(
    String normalized,
    Iterable<DashboardVoicePage> pages,
    DashboardVoiceAbstentionReason reason,
  ) {
    const DashboardVoiceRanker ranker = DashboardVoiceRanker();
    if (ranker.asksToChangeData(normalized)) {
      return _abstain(normalized, reason);
    }
    final List<DashboardVoiceRankedPage> ranked = ranker.rank(
      normalized,
      pages,
    );
    final DashboardVoiceRankedPage? winner = ranker.clearWinner(ranked);
    if (winner != null) {
      return DashboardVoiceInterpretationResult.recognized(
        DashboardVoiceInterpretation(
          action: DashboardVoiceActionId.openPage,
          pageKey: winner.pageKey,
          normalizedTranscript: normalized,
        ),
      );
    }
    return DashboardVoiceInterpretationResult.abstained(
      DashboardVoiceAbstention(
        reason: reason,
        normalizedTranscript: normalized,
        suggestedPageKeys: ranker.suggestions(ranked),
      ),
    );
  }

  static DashboardVoiceInterpretationResult _abstain(
    String normalized,
    DashboardVoiceAbstentionReason reason,
  ) {
    return DashboardVoiceInterpretationResult.abstained(
      DashboardVoiceAbstention(
        reason: reason,
        normalizedTranscript: normalized,
      ),
    );
  }
}
