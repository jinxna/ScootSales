import '../models/user_profile.dart';

class UserManagementUtils {
  const UserManagementUtils._();

  static String readUserName(Map<String, dynamic> user) =>
      ((user['name'] ?? user['displayName'] ?? user['fullName']) as Object? ??
              '')
          .toString()
          .trim();

  static String readUserEmail(Map<String, dynamic> user) =>
      ((user['email']) as Object? ?? '').toString().trim();

  static String readUserCode(Map<String, dynamic> user) =>
      ((user['employeeCode'] ?? user['staffId'] ?? user['userId']) as Object? ??
              '')
          .toString()
          .trim();

  static String firstNonEmptyField(
    Map<String, dynamic> values,
    Iterable<String> keys,
  ) {
    for (final String key in keys) {
      final Object? value = values[key];
      if (value == null) continue;
      final String text = value.toString().trim();
      if (text.isNotEmpty && text != 'null') return text;
    }
    return '';
  }

  static String userStatus(Map<String, dynamic> user) =>
      UserProfile.normalizeStatus(
        user['status'] ?? user['accountStatus'] ?? user['account_status'],
        isActive:
            user['isActive'] ??
            user['is_active'] ??
            user['active'] ??
            user['enabled'],
      );

  static String supervisorRoleChangeBlockedText(int count) =>
      '$count ${count == 1 ? 'salesman is' : 'salesmen are'} still assigned '
      'to this supervisor. Move them to another supervisor first, then '
      'change this role or branch. Nothing was changed.';

  static String roleLabel(String role) {
    switch (UserProfile.normalizeRole(role)) {
      case 'admin':
        return 'Admin';
      case 'supervisor':
        return 'Supervisor';
      case 'developer':
        return 'Developer';
      case 'branch_manager':
        return 'Branch Manager';
      case 'salesman':
        return 'Salesman';
      case 'active':
        return 'Active';
      case 'suspended':
        return 'Suspended';
      default:
        return role;
    }
  }

  static List<Map<String, dynamic>> supervisors(
    Iterable<Map<String, dynamic>> users,
  ) => users.where((Map<String, dynamic> user) {
    final String role = UserProfile.normalizeRole(
      ((user['role'] ?? user['user_group'] ?? user['roleLabel']) as Object? ??
              '')
          .toString(),
    );
    return role == 'supervisor';
  }).toList();

  static List<Map<String, dynamic>> filterUsers(
    Iterable<Map<String, dynamic>> users, {
    required String query,
    required bool includeDevelopers,
  }) {
    final String normalizedQuery = query.trim().toLowerCase();
    return users.where((Map<String, dynamic> user) {
      final String normalizedRole = UserProfile.normalizeRole(
        ((user['role'] ?? user['user_group'] ?? user['roleLabel']) as Object? ??
                '')
            .toString(),
        email: readUserEmail(user),
      );
      if (!includeDevelopers && normalizedRole == 'developer') return false;
      if (normalizedQuery.isEmpty) return true;
      final String text = <String>[
        readUserName(user),
        readUserEmail(user),
        readUserCode(user),
        roleLabel(normalizedRole),
      ].join(' ').toLowerCase();
      return text.contains(normalizedQuery);
    }).toList();
  }

  static Map<String, dynamic> buildProfilePayload({
    required String authUid,
    required String name,
    required String email,
    required String branchId,
    required String supervisorId,
    required String contactNumber,
    required bool isCreating,
    required String provisioningByUid,
  }) => <String, dynamic>{
    if (authUid.trim().isNotEmpty) 'uid': authUid,
    'name': name,
    'email': email,
    'username': email.split('@').first,
    'branchId': branchId,
    'branch_id': branchId,
    'supervisorId': supervisorId,
    'supervisor_id': supervisorId,
    'contactNumber': contactNumber,
    'contact_number': contactNumber,
    if (isCreating) 'provisioningState': 'pending',
    if (isCreating) 'provisioningByUid': provisioningByUid,
  };
}
