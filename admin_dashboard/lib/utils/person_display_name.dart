String personDisplayName(String name, String code) {
  final String trimmed = name.trim();
  if (trimmed.isNotEmpty && !trimmed.contains('@')) return trimmed;
  final String id = code.trim();
  return id.isEmpty ? 'No name set' : 'No name set ($id)';
}

String personNameForCode(
  String code,
  Iterable<Map<String, dynamic>> people, {
  List<String> codeFields = const <String>[
    'salesmanCode',
    'employeeCode',
    'staffId',
    'salesmanId',
    'userId',
    'uid',
  ],
}) {
  final String wanted = code.trim();
  if (wanted.isEmpty) return '';
  for (final Map<String, dynamic> person in people) {
    for (final String field in codeFields) {
      final Object? value = person[field];
      if (value != null && '$value'.trim().toLowerCase() == wanted.toLowerCase()) {
        return personDisplayName('${person['name'] ?? ''}', wanted);
      }
    }
  }
  return wanted;
}
