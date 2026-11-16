library;

int editDistance(String a, String b) {
  if (a == b) return 0;
  if (a.isEmpty) return b.length;
  if (b.isEmpty) return a.length;
  List<int> before = List<int>.filled(b.length + 1, 0);
  List<int> prev = List<int>.generate(b.length + 1, (int i) => i);
  for (int i = 1; i <= a.length; i++) {
    final List<int> cur = List<int>.filled(b.length + 1, 0)..[0] = i;
    for (int j = 1; j <= b.length; j++) {
      final int cost = a.codeUnitAt(i - 1) == b.codeUnitAt(j - 1) ? 0 : 1;
      int best = prev[j - 1] + cost;
      if (prev[j] + 1 < best) best = prev[j] + 1;
      if (cur[j - 1] + 1 < best) best = cur[j - 1] + 1;
      if (i > 1 &&
          j > 1 &&
          a.codeUnitAt(i - 1) == b.codeUnitAt(j - 2) &&
          a.codeUnitAt(i - 2) == b.codeUnitAt(j - 1) &&
          before[j - 2] + 1 < best) {
        best = before[j - 2] + 1;
      }
      cur[j] = best;
    }
    before = prev;
    prev = cur;
  }
  return prev[b.length];
}

bool isNearWord(String typed, String word) {
  if (typed == word) return true;
  if (typed.length < 4 || word.length < 4) return false;
  final int allowed = typed.length >= 8 ? 2 : 1;
  if ((typed.length - word.length).abs() > allowed) return false;
  return editDistance(typed, word) <= allowed;
}

final RegExp _wordBreak = RegExp(r'[^a-z0-9]+');

bool fuzzyTextMatches(String text, String query) {
  final List<String> typed = query
      .toLowerCase()
      .split(_wordBreak)
      .where((String w) => w.isNotEmpty)
      .toList(growable: false);
  if (typed.isEmpty) return false;
  final List<String> words = text
      .toLowerCase()
      .split(_wordBreak)
      .where((String w) => w.isNotEmpty)
      .toList(growable: false);
  return typed.every(
    (String t) => words.any((String w) => w.contains(t) || isNearWord(t, w)),
  );
}
