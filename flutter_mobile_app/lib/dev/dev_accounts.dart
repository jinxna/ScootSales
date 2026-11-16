import 'package:flutter/foundation.dart';

class DevAccount {
  const DevAccount({
    required this.label,
    required this.email,
    required this.password,
    this.role = '',
  });

  final String label;
  final String email;
  final String password;
  final String role;
}

const String _rawDevAccounts = String.fromEnvironment('DEV_ACCOUNTS');

List<DevAccount> devQuickAccounts() {
  if (!kDebugMode || _rawDevAccounts.trim().isEmpty) {
    return const <DevAccount>[];
  }
  final List<DevAccount> accounts = <DevAccount>[];
  for (final String record in _rawDevAccounts.split(';;')) {
    final List<String> parts = record.split('|');
    if (parts.length < 3) continue;
    final String email = parts[1].trim();
    final String password = parts[2].trim();
    if (email.isEmpty || password.isEmpty) continue;
    accounts.add(
      DevAccount(
        label: parts[0].trim().isEmpty ? email : parts[0].trim(),
        email: email,
        password: password,
        role: parts.length > 3 ? parts[3].trim() : '',
      ),
    );
  }
  return accounts;
}

List<DevAccount> mobileSalespersonDevQuickAccounts() {
  return devQuickAccounts()
      .where((DevAccount account) => _normaliseRole(account.role) == 'salesman')
      .map(
        (DevAccount account) => DevAccount(
          label: 'Salesperson',
          email: account.email,
          password: account.password,
          role: 'salesman',
        ),
      )
      .toList(growable: false);
}

String _normaliseRole(String value) =>
    value.trim().toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
