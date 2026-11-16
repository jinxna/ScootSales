import 'dashboard_voice_types.dart';

class DashboardVoiceRankedPage {
  const DashboardVoiceRankedPage(this.pageKey, this.score, this.reach);

  final String pageKey;

  final double score;

  final double reach;
}

class DashboardVoiceRanker {
  const DashboardVoiceRanker();

  static const double autoOpenScore = 0.8;
  static const double autoOpenMargin = 0.25;

  static const double suggestReach = 0.4;
  static const int maxSuggestions = 3;

  List<DashboardVoiceRankedPage> rank(
    String normalizedQuery,
    Iterable<DashboardVoicePage> pages,
  ) {
    final List<String> query = _contentWords(normalizedQuery);
    if (query.isEmpty) return const <DashboardVoiceRankedPage>[];
    return <DashboardVoiceRankedPage>[
      for (final DashboardVoicePage page in pages) _rankPage(query, page),
    ]..sort(
      (DashboardVoiceRankedPage a, DashboardVoiceRankedPage b) =>
          b.reach.compareTo(a.reach),
    );
  }

  DashboardVoiceRankedPage? clearWinner(List<DashboardVoiceRankedPage> ranked) {
    final List<DashboardVoiceRankedPage> byScore = List.of(ranked)
      ..sort(
        (DashboardVoiceRankedPage a, DashboardVoiceRankedPage b) =>
            b.score.compareTo(a.score),
      );
    if (byScore.isEmpty || byScore.first.score < autoOpenScore) return null;
    final double second = byScore.length > 1 ? byScore[1].score : 0;
    return byScore.first.score - second >= autoOpenMargin
        ? byScore.first
        : null;
  }

  bool asksToChangeData(String normalizedQuery) => normalizedQuery
      .toLowerCase()
      .split(RegExp(r"[^a-z']+"))
      .any(_changeVerbs.contains);

  List<String> suggestions(List<DashboardVoiceRankedPage> ranked) => <String>[
    for (final DashboardVoiceRankedPage r in ranked.take(maxSuggestions))
      if (r.reach >= suggestReach) r.pageKey,
  ];

  static DashboardVoiceRankedPage _rankPage(
    List<String> query,
    DashboardVoicePage page,
  ) {
    double score = 0, reach = 0;
    void consider(String phrase, double weight) {
      final List<String> words = _contentWords(phrase);
      if (words.isEmpty) return;
      final ({double dice, double covered}) o = _overlap(query, words);
      if (o.dice * weight > score) score = o.dice * weight;
      if (o.covered * 0.7 * weight > reach) reach = o.covered * 0.7 * weight;
    }

    for (final String phrase in <String>{
      page.label,
      page.key.replaceAll('_', ' '),
      ...page.aliases,
    }) {
      consider(phrase, 1);
    }
    consider(page.description, 0.6);
    return DashboardVoiceRankedPage(
      page.key,
      score,
      reach > score ? reach : score,
    );
  }

  static ({double dice, double covered}) _overlap(
    List<String> query,
    List<String> target,
  ) {
    final List<String> remaining = List<String>.of(target);
    double matched = 0;
    for (final String word in query) {
      int hit = -1;
      double weight = 0;
      for (int i = 0; i < remaining.length; i++) {
        final double w = _wordMatch(word, remaining[i]);
        if (w > weight) {
          weight = w;
          hit = i;
        }
      }
      if (hit >= 0) {
        matched += weight;
        remaining.removeAt(hit);
      }
    }
    return (
      dice: 2 * matched / (query.length + target.length),
      covered: matched / target.length,
    );
  }

  static double _wordMatch(String a, String b) {
    if (a == b) return 1;
    if (a.length >= 4 &&
        b.length >= 4 &&
        (a.startsWith(b) || b.startsWith(a))) {
      return 0.85;
    }
    if (a.length >= 5 && b.length >= 5 && _editDistanceAtMostOne(a, b)) {
      return 0.85;
    }
    return 0;
  }

  static bool isNearFiller(String word) {
    if (word.length < 4 || _stopWords.contains(word) || _malay.containsKey(word)) {
      return false;
    }
    return _typoFillers.any(
      (String filler) => _editDistanceAtMostOne(word, filler),
    );
  }

  static const Set<String> _typoFillers = <String>{'page', 'screen', 'please'};

  static bool _editDistanceAtMostOne(String a, String b) {
    if ((a.length - b.length).abs() > 1) return false;
    if (a.length == b.length) {
      int i = 0;
      while (i < a.length && a[i] == b[i]) {
        i++;
      }
      if (i + 1 < a.length &&
          a[i] == b[i + 1] &&
          a[i + 1] == b[i] &&
          a.substring(i + 2) == b.substring(i + 2)) {
        return true;
      }
    }
    int i = 0, j = 0, edits = 0;
    while (i < a.length && j < b.length) {
      if (a[i] == b[j]) {
        i++;
        j++;
        continue;
      }
      if (++edits > 1) return false;
      if (a.length > b.length) {
        i++;
      } else if (a.length < b.length) {
        j++;
      } else {
        i++;
        j++;
      }
    }
    return edits + (a.length - i) + (b.length - j) <= 1;
  }

  static List<String> _contentWords(String text) {
    return <String>[
      for (final String raw
          in text
              .toLowerCase()
              .replaceAll(RegExp(r"[^a-z0-9' ]"), ' ')
              .split(RegExp(r'\s+')))
        if (raw.isNotEmpty && !_stopWords.contains(raw) && !isNearFiller(raw))
          _singular(_malay[raw] ?? raw),
    ].where((String w) => w.isNotEmpty && !_stopWords.contains(w)).toList();
  }

  static String _singular(String word) {
    if (word.length > 4 && word.endsWith('ies')) {
      return '${word.substring(0, word.length - 3)}y';
    }
    if (word.length > 3 && word.endsWith('s') && !word.endsWith('ss')) {
      return word.substring(0, word.length - 1);
    }
    return word;
  }

  static const Set<String> _changeVerbs = <String>{
    'delete',
    'deleted',
    'remove',
    'erase',
    'revoke',
    'cancel',
    'clear',
    'reset',
    'wipe',
    'drop',
    'approve',
    'reject',
    'decline',
    'submit',
    'confirm',
    'send',
    'create',
    'add',
    'edit',
    'update',
    'change',
    'modify',
    'rename',
    'assign',
    'publish',
    'post',
    'pay',
    'sign',
    'buang',
    'padam',
    'batal',
    'hapus',
    'lulus',
    'tolak',
    'hantar',
    'tambah',
    'ubah',
    'kemas',
  };

  static const Set<String> _stopWords = <String>{
    'the', 'a', 'an', 'my', 'our', 'me', 'i', 'we', 'you', 'it', 'its', 'to',
    'of', 'for', 'on', 'in', 'at', 'is', 'are', 'was', 'be', 'and', 'or',
    'with', 'from', 'about', 'so', 'that', 'this', 'there', 'their', 'them',
    'please', 'can', 'could', 'would', 'will', 'want', 'wanna', 'need', 'let',
    "let's", 'lets', 'like', 'help', 'hey', 'just', 'now', 'today', 'right',
    'open', 'show', 'view', 'display', 'check', 'see', 'go', 'take', 'bring',
    'pull', 'up', 'load', 'launch', 'jump', 'switch', 'navigate', 'find',
    'search', 'look', 'get', 'give', 'tell', 'know', 'do', 'does', 'doing',
    'how', 'what', "what's", 'whats', 'where', 'who', 'which', 'when', 'any',
    'all', 'page', 'screen', 'tab', 'section', 'list', 'current', 'currently',
    'buka', 'tunjuk', 'tunjukkan', 'papar', 'paparkan', 'pergi', 'ke', 'saya',
    'nak', 'mahu', 'untuk', 'dan', 'yang', 'dengan', 'sila', 'boleh', 'lihat',
    'semak', 'di', 'dalam', 'hari', 'ini',
  };

  static const Map<String, String> _malay = <String, String>{
    'pesanan': 'order',
    'tempahan': 'order',
    'laluan': 'route',
    'rancang': 'plan',
    'perancang': 'planner',
    'lawatan': 'visit',
    'laporan': 'report',
    'ramalan': 'forecast',
    'ramal': 'forecast',
    'peruncit': 'retailer',
    'kedai': 'retailer',
    'produk': 'product',
    'barang': 'product',
    'jurujual': 'salesman',
    'jualan': 'sale',
    'pasukan': 'team',
    'cawangan': 'branch',
    'pengguna': 'user',
    'kakitangan': 'staff',
    'kategori': 'category',
    'jabatan': 'department',
    'pembelian': 'purchase',
    'notifikasi': 'notification',
    'pemberitahuan': 'notification',
    'amaran': 'alert',
    'aktiviti': 'activity',
    'peta': 'map',
    'sejarah': 'history',
    'kebenaran': 'permission',
    'ringkasan': 'summary',
    'permintaan': 'request',
    'khas': 'special',
    'kelulusan': 'approval',
    'papan': 'board',
    'utama': 'main',
    'laman': 'home',
    'reps': 'salesman',
    'rep': 'salesman',
    'salesmen': 'salesman',
    'salespeople': 'salesman',
    'salesperson': 'salesman',
    'shops': 'retailer',
    'shop': 'retailer',
    'stores': 'retailer',
    'store': 'retailer',
    'outlets': 'retailer',
    'outlet': 'retailer',
    'customers': 'retailer',
    'customer': 'retailer',
    'predictions': 'forecast',
    'prediction': 'forecast',
    'forecasts': 'forecast',
    'stats': 'report',
    'statistics': 'report',
    'analytics': 'report',
    'alerts': 'notification',
    'staff': 'user',
    'people': 'user',
    'employees': 'user',
  };
}
