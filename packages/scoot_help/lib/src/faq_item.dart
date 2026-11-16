enum FaqAudience {
  public,
  admin,
  supervisor,
  branchManager,
  salesperson,
  staff,
}

class FaqItem {
  const FaqItem({
    required this.id,
    required this.audiences,
    required this.topic,
    required this.question,
    required this.answer,
    required this.since,
  });

  final String id;
  final List<FaqAudience> audiences;
  final String topic;
  final String question;
  final List<String> answer;
  final String since;

  bool matches(String query) {
    final String needle = query.trim().toLowerCase();
    if (needle.isEmpty) return true;
    return question.toLowerCase().contains(needle) ||
        topic.toLowerCase().contains(needle) ||
        answer.any((String line) => line.toLowerCase().contains(needle));
  }
}
