import '../models/user_profile.dart';
import 'user_access_index.dart';

class UserManagementRules {
  const UserManagementRules._();

  static const int maxSalesmenPerSupervisor = 5;

  static bool roleRequiresBranch(String role) {
    final String normalised = UserProfile.normalizeRole(role);
    return normalised != UserProfile.roleAdmin &&
        normalised != UserProfile.roleDeveloper;
  }

  static const String branchRequiredMessage =
      'Choose a branch. Supervisors, branch managers and salesmen must belong '
      'to a branch.';

  static String? branchError({required String role, required String branchId}) {
    if (roleRequiresBranch(role) && branchId.trim().isEmpty) {
      return branchRequiredMessage;
    }
    return null;
  }

  static int supervisorLoad(Iterable<Object?> sources) {
    final Set<String> codes = <String>{};
    for (final Object? source in sources) {
      codes.addAll(UserAccessIndex.parseAssignedSalesmanCodes(source));
    }
    return codes.length;
  }

  static String? supervisorCapError({
    required String supervisorName,
    required Set<String> currentCodes,
    required String salesmanCode,
    String removingCode = '',
  }) {
    final Set<String> after = <String>{...currentCodes};
    if (removingCode.isNotEmpty && removingCode != salesmanCode) {
      after.remove(removingCode);
    }
    if (after.contains(salesmanCode)) return null;
    if (after.length < maxSalesmenPerSupervisor) return null;
    final String name = supervisorName.trim().isEmpty
        ? 'This supervisor'
        : supervisorName.trim();
    return 'Supervisor $name already has $maxSalesmenPerSupervisor salesmen. '
        'Assign this salesman to another supervisor.';
  }

  static bool sameBranch(String first, String second) =>
      first.trim().toUpperCase() == second.trim().toUpperCase();

  static String? supervisorBranchError({
    required String supervisorBranchId,
    required String branchId,
  }) {
    if (sameBranch(supervisorBranchId, branchId)) return null;
    return 'That supervisor is in another branch. Choose a supervisor in the '
        'same branch.';
  }

  static bool supervisorTeamMustMoveFirst({
    required String oldRole,
    required String oldEmployeeCode,
    required String newRole,
    required String oldBranchId,
    required String newBranchId,
  }) {
    if (oldRole != UserProfile.roleSupervisor) return false;
    if (oldEmployeeCode.trim().isEmpty) return false;
    return newRole != UserProfile.roleSupervisor ||
        !sameBranch(oldBranchId, newBranchId);
  }

  static String? employeeCodeToSave({
    required String typed,
    required String storedCode,
  }) {
    final String code = typed.trim();
    if (storedCode.isNotEmpty &&
        (code.isEmpty ||
            code.toUpperCase() == storedCode.trim().toUpperCase())) {
      return storedCode;
    }
    return code.isEmpty ? null : code.toUpperCase();
  }

  static String supervisorOptionLabel(String name, int load) =>
      '$name ($load/$maxSalesmenPerSupervisor)';

  static bool supervisorOptionDisabled({
    required Set<String> codes,
    required String editingSalesmanCode,
  }) {
    if (editingSalesmanCode.isNotEmpty && codes.contains(editingSalesmanCode)) {
      return false;
    }
    return codes.length >= maxSalesmenPerSupervisor;
  }

  static Map<String, dynamic> selfEditProfilePayload({
    required String name,
    required String contactNumber,
    required String email,
    required Object updatedAt,
  }) {
    return <String, dynamic>{
      'name': name.trim(),
      'contactNumber': contactNumber.trim(),
      'contact_number': contactNumber.trim(),
      if (email.trim().isNotEmpty) 'email': email.trim(),
      'updatedAt': updatedAt,
    };
  }

  static String statusActionLabel(String normalisedStatus) =>
      normalisedStatus == UserProfile.statusActive ? 'Suspend' : 'Activate';

  static String statusConfirmTitle(String normalisedStatus, String name) =>
      normalisedStatus == UserProfile.statusActive
      ? 'Suspend $name?'
      : 'Activate $name?';

  static String statusConfirmBody(String normalisedStatus) =>
      normalisedStatus == UserProfile.statusActive
      ? 'They will be signed out and blocked until reactivated.'
      : 'They will be able to sign in again.';
}
