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
const String _dashboardRole = String.fromEnvironment('DASHBOARD_ROLE');

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
  final String requestedRole = _normaliseRole(_dashboardRole);
  if (requestedRole.isEmpty) return accounts;
  return accounts
      .where(
        (DevAccount account) => _normaliseRole(account.role) == requestedRole,
      )
      .toList(growable: false);
}

List<DevAccount> dashboardDevQuickAccounts([List<DevAccount>? accounts]) {
  const Map<String, String> labelsByRole = <String, String>{
    'admin': 'Admin',
    'supervisor': 'Supervisor',
    'branch_manager': 'Branch Manager',
  };
  return (accounts ?? devQuickAccounts())
      .where(
        (DevAccount account) =>
            labelsByRole.containsKey(_normaliseRole(account.role)),
      )
      .map((DevAccount account) {
        final String role = _normaliseRole(account.role);
        return DevAccount(
          label: labelsByRole[role]!,
          email: account.email,
          password: account.password,
          role: role,
        );
      })
      .toList(growable: false);
}

String _normaliseRole(String value) {
  final String normalized = value.trim().toLowerCase().replaceAll('-', '_');
  return switch (normalized) {
    'admin' || 'administrator' || 'developer' => 'admin',
    'branch manager' || 'branch_manager' || 'branchmanager' => 'branch_manager',
    'supervisor' => 'supervisor',
    _ => normalized,
  };
}
