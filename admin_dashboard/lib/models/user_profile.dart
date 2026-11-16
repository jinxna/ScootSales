import '../security/user_access_index.dart';

class UserProfile {
  const UserProfile({
    required this.docId,
    required this.email,
    required this.name,
    required this.role,
    required this.employeeCode,
    required this.status,
    this.uid,
    this.username = '',
    this.branchId = '',
    this.supervisorId = '',
    this.contactNumber = '',
    this.assignedSalesmanCodes = const <String>[],
  });

  final String docId;
  final String? uid;
  final String email;
  final String name;
  final String username;
  final String role;
  final String employeeCode;
  final String status;
  final String branchId;
  final String supervisorId;
  final String contactNumber;
  final List<String> assignedSalesmanCodes;

  static const String roleDeveloper = 'developer';
  static const String roleAdmin = 'admin';
  static const String roleBranchManager = 'branch_manager';
  static const String roleSupervisor = 'supervisor';
  static const String roleSalesman = 'salesman';

  static const String statusActive = 'active';
  static const String statusSuspended = 'suspended';

  bool get isActive => status.trim().toLowerCase() == statusActive;
  bool get isSalesman => role == roleSalesman;
  bool get isSupervisor => role == roleSupervisor;
  bool get isBranchManager => role == roleBranchManager;
  bool get isDeveloper => role == roleDeveloper;
  bool get isAdmin => role == roleAdmin || isDeveloper;
  bool get canUseWebDashboard => isAdmin || isSupervisor || isBranchManager;

  String get roleLabel {
    switch (role) {
      case roleDeveloper:
        return 'Developer';
      case roleAdmin:
        return 'Admin';
      case roleSupervisor:
        return 'Supervisor';
      case roleBranchManager:
        return 'Branch Manager';
      case roleSalesman:
        return 'Salesman';
      default:
        return role;
    }
  }

  static String normalizeRole(Object? raw, {Object? email}) {
    final String value = _readText(
      raw,
    ).toLowerCase().replaceAll('-', '_').replaceAll(' ', '_');
    if (value.contains('developer')) return roleDeveloper;
    if (value.contains('admin')) return roleAdmin;
    if (value.contains('branch') && value.contains('manager')) {
      return roleBranchManager;
    }
    if (value.contains('supervisor')) return roleSupervisor;
    if (value.contains('sales') ||
        value.contains('salesman') ||
        value.contains('representative')) {
      return roleSalesman;
    }
    return value.isEmpty ? roleSalesman : value;
  }

  static String normalizeStatus(Object? raw, {Object? isActive}) {
    if (isActive != null) {
      if (isActive is bool) {
        if (!isActive) return statusSuspended;
      } else if (isActive is num) {
        if (isActive == 0) return statusSuspended;
      } else {
        final String coerced = _readText(isActive).toLowerCase();
        if (coerced == 'false' ||
            coerced == '0' ||
            coerced == 'no' ||
            coerced == 'off' ||
            coerced == 'n') {
          return statusSuspended;
        }
      }
    }

    final String value = _readText(raw).toLowerCase();
    if (value == 'false' ||
        value == '0' ||
        value == 'no' ||
        value.contains('suspend') ||
        value.contains('inactive') ||
        value.contains('disable') ||
        value.contains('deactiv')) {
      return statusSuspended;
    }
    return statusActive;
  }

  factory UserProfile.fromFirestore(String docId, Map<String, dynamic> json) {
    final String email = _readText(json['email']);
    return UserProfile(
      docId: docId,
      uid: _optionalText(json['uid']),
      email: email,
      name: _firstText(<Object?>[
        json['name'],
        json['displayName'],
        json['fullName'],
      ]),
      username: _readText(json['username']),
      role: normalizeRole(
        _firstText(<Object?>[
          json['role'],
          json['user_group'],
          json['roleLabel'],
          json['userRole'],
          json['position'],
        ]),
        email: email,
      ),
      employeeCode: _firstText(<Object?>[
        json['employeeCode'],
        json['employee_code'],
        json['staffId'],
        json['staff_id'],
        json['userId'],
        json['user_id'],
      ]),
      status: normalizeStatus(
        _firstText(<Object?>[
          json['status'],
          json['accountStatus'],
          json['account_status'],
        ]),
        isActive: json['isActive'] ?? json['active'] ?? json['enabled'],
      ),
      branchId: _firstText(<Object?>[json['branchId'], json['branch_id']]),
      supervisorId: _firstText(<Object?>[
        json['supervisorId'],
        json['supervisor_id'],
      ]),
      contactNumber: _firstText(<Object?>[
        json['contactNumber'],
        json['contact_number'],
      ]),
      assignedSalesmanCodes: UserAccessIndex.parseAssignedSalesmanCodes(
        json['assignedSalesmanCodes'],
      ),
    );
  }

  static String _readText(Object? value) {
    return (value ?? '').toString().trim();
  }

  static String? _optionalText(Object? value) {
    final String text = _readText(value);
    return text.isEmpty ? null : text;
  }

  static String _firstText(Iterable<Object?> values) {
    for (final Object? value in values) {
      final String text = _readText(value);
      if (text.isNotEmpty) return text;
    }
    return '';
  }
}
