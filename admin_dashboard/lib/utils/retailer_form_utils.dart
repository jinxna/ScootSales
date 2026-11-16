library;

class RetailerSalesmanOption {
  const RetailerSalesmanOption({
    required this.value,
    required this.storageValue,
    required this.name,
    required this.code,
    required this.aliases,
  });

  final String value;

  final String storageValue;
  final String name;
  final String code;
  final List<String> aliases;

  String get label => '$name (${code.isEmpty ? storageValue : code})';

  bool matches(String candidate) => aliases.contains(candidate.trim());
}

List<RetailerSalesmanOption> buildRetailerSalesmanOptions(
  Iterable<Map<String, dynamic>> users,
) {
  final List<RetailerSalesmanOption> options = <RetailerSalesmanOption>[];
  final Set<String> identities = <String>{};
  for (final Map<String, dynamic> user in users) {
    final String uid = _text(
      user['uid'] ?? user['userId'] ?? user['user_id'] ?? user['docId'],
    );
    final String code = _text(
      user['employeeCode'] ??
          user['employee_code'] ??
          user['staffId'] ??
          user['staff_id'] ??
          user['userId'] ??
          user['docId'] ??
          user['email'],
    );
    final String email = _text(user['email']);
    final String storageValue = code.isNotEmpty
        ? code
        : uid.isNotEmpty
        ? uid
        : email;
    if (storageValue.isEmpty) continue;

    final String identity = uid.isNotEmpty ? uid : '$storageValue::$email';
    if (!identities.add(identity)) continue;

    final String name = _text(
      user['name'] ?? user['displayName'] ?? user['fullName'] ?? user['email'],
      fallback: 'Unnamed salesman',
    );
    final List<String> aliases = <String>{
      storageValue,
      uid,
      code,
      email,
    }.where((String value) => value.trim().isNotEmpty).toList(growable: false);
    options.add(
      RetailerSalesmanOption(
        value: identity,
        storageValue: storageValue,
        name: name,
        code: code,
        aliases: aliases,
      ),
    );
  }
  return options;
}

RetailerSalesmanOption? findRetailerSalesmanOption(
  Iterable<RetailerSalesmanOption> options,
  Object? storedValue,
) {
  final String candidate = _text(storedValue);
  if (candidate.isEmpty) return null;
  for (final RetailerSalesmanOption option in options) {
    if (option.matches(candidate)) return option;
  }
  return null;
}

class RetailerSalesmanField {
  const RetailerSalesmanField({
    required this.options,
    required this.selectedValue,
    required this.unmatchedAssignment,
  });

  final List<RetailerSalesmanOption> options;

  final String selectedValue;

  final String? unmatchedAssignment;
}

RetailerSalesmanField retailerSalesmanField(
  Iterable<Map<String, dynamic>> users,
  Object? storedValue,
) {
  final List<RetailerSalesmanOption> options = <RetailerSalesmanOption>[];
  final Set<String> seenValues = <String>{};
  for (final RetailerSalesmanOption option in buildRetailerSalesmanOptions(
    users,
  )) {
    final String value = option.storageValue.trim();
    if (value.isEmpty) continue;
    if (!seenValues.add(value)) continue;
    options.add(option);
  }

  final String stored = _text(storedValue);
  final RetailerSalesmanOption? match = findRetailerSalesmanOption(
    options,
    stored,
  );
  if (match != null) {
    return RetailerSalesmanField(
      options: options,
      selectedValue: match.storageValue,
      unmatchedAssignment: null,
    );
  }
  if (stored.isEmpty) {
    return RetailerSalesmanField(
      options: options,
      selectedValue: '',
      unmatchedAssignment: null,
    );
  }
  return RetailerSalesmanField(
    options: options,
    selectedValue: stored,
    unmatchedAssignment: stored,
  );
}

String normaliseRetailerDisplayStatus(Object? rawStatus, {Object? visible}) {
  final String raw = _text(
    rawStatus,
  ).toLowerCase().replaceAll(RegExp(r'[-_\s]'), '');
  if (raw.isEmpty && visible is bool && !visible) return 'Hide';
  if (raw == 'hide' ||
      raw == 'hidden' ||
      raw == 'inactive' ||
      raw == 'disabled' ||
      raw == 'false' ||
      raw == 'archived') {
    return 'Hide';
  }
  return 'Display';
}

String _text(Object? value, {String fallback = ''}) {
  if (value == null) return fallback;
  final String text = value.toString().trim();
  return text.isEmpty || text.toLowerCase() == 'null' ? fallback : text;
}
