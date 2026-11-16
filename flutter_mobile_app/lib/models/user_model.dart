class UserModel {
  final String uid;
  final String staffId;
  final String employeeCode;
  final String name;
  final String displayName;
  final String initials;
  final String email;
  final String phone;
  final String territory;
  final String branchId;
  final String role;
  final String joinedDate;
  final String photoUrl;
  final bool isActive;
  final bool offlineMode;
  final bool gpsAutofill;
  final bool lastWeekTemplate;
  final bool pushNotifications;
  final String accountStatus;
  final String userDocId;

  UserModel({
    required this.uid,
    required this.staffId,
    this.employeeCode = '',
    required this.name,
    this.displayName = '',
    this.initials = '',
    required this.email,
    required this.phone,
    required this.territory,
    this.branchId = '',
    required this.role,
    required this.joinedDate,
    this.photoUrl = '',
    this.isActive = true,
    this.offlineMode = false,
    this.gpsAutofill = true,
    this.lastWeekTemplate = true,
    this.pushNotifications = true,
    this.accountStatus = 'active',
    this.userDocId = '',
  });

  String get identityCode =>
      employeeCode.trim().isNotEmpty ? employeeCode.trim() : staffId.trim();

  bool get hasActiveAccount {
    final status = accountStatus.trim().toLowerCase();
    const blocked = {
      'suspended',
      'disabled',
      'inactive',
      'removed',
      'deleted',
      'terminated',
    };
    return isActive && !blocked.contains(status);
  }

  bool get hasSalespersonRole {
    final String normalized = role.trim().toLowerCase();
    return normalized == 'salesman' ||
        normalized == 'sales representative' ||
        normalized == 'sales_representative';
  }

  String get effectiveDisplayName =>
      displayName.isNotEmpty ? displayName : name.split(' ').first;

  String get effectiveInitials {
    if (initials.isNotEmpty) return initials;
    final parts = name.trim().split(' ').where((p) => p.isNotEmpty).toList();
    if (parts.isEmpty) return '?';
    if (parts.length == 1) return parts.first.substring(0, 1).toUpperCase();
    return (parts.first.substring(0, 1) + parts.last.substring(0, 1))
        .toUpperCase();
  }

  factory UserModel.fromMap(Map<String, dynamic> map, String uid) {
    final resolvedUid = (map['uid'] ?? uid).toString();
    final resolvedStaffId =
        (map['staffId'] ??
                map['staffID'] ??
                map['employeeCode'] ??
                map['salesmanCode'] ??
                map['salesman_code'] ??
                map['userId'] ??
                uid)
            .toString();
    final resolvedName =
        (map['name'] ??
                map['displayName'] ??
                map['fullName'] ??
                map['employeeName'] ??
                map['email'] ??
                'User')
            .toString();

    return UserModel(
      uid: resolvedUid,
      staffId: resolvedStaffId,
      employeeCode: (map['employeeCode'] ?? '').toString().trim(),
      name: resolvedName,
      displayName: (map['displayName'] ?? resolvedName).toString(),
      initials: (map['initials'] ?? '').toString(),
      email: (map['email'] ?? '').toString(),
      phone: (map['phone'] ?? '').toString(),
      territory: (map['territory'] ?? map['branchName'] ?? 'Default Zone')
          .toString(),
      branchId: (map['branchId'] ?? map['branch_id'] ?? '').toString().trim(),
      role: (map['role'] ?? 'Sales Representative').toString(),
      joinedDate: (map['joinedDate'] ?? '').toString(),
      photoUrl: (map['photoUrl'] ?? '').toString(),
      isActive: _readBool(map['isActive'] ?? map['active'], fallback: true),
      offlineMode: map['offlineMode'] ?? false,
      gpsAutofill: map['gpsAutofill'] ?? true,
      lastWeekTemplate: map['lastWeekTemplate'] ?? true,
      pushNotifications: map['pushNotifications'] ?? true,
      accountStatus: (map['accountStatus'] ?? map['status'] ?? 'active')
          .toString(),
      userDocId: (map['userDocId'] ?? '').toString().trim(),
    );
  }

  Map<String, dynamic> toMap() {
    return {
      'uid': uid,
      'userId': staffId,
      'employeeCode': staffId,
      'staffId': staffId,
      'name': name,
      'displayName': displayName,
      'initials': initials,
      'email': email,
      'phone': phone,
      'territory': territory,
      if (branchId.isNotEmpty) 'branchId': branchId,
      'role': role,
      'joinedDate': joinedDate,
      'photoUrl': photoUrl,
      'isActive': isActive,
      'offlineMode': offlineMode,
      'gpsAutofill': gpsAutofill,
      'lastWeekTemplate': lastWeekTemplate,
      'pushNotifications': pushNotifications,
      'accountStatus': accountStatus,
    };
  }

  UserModel copyWith({
    String? name,
    String? displayName,
    String? initials,
    String? email,
    String? phone,
    String? territory,
    String? branchId,
    String? role,
    String? photoUrl,
    bool? offlineMode,
    bool? gpsAutofill,
    bool? lastWeekTemplate,
    bool? pushNotifications,
  }) {
    return UserModel(
      uid: uid,
      staffId: staffId,
      employeeCode: employeeCode,
      name: name ?? this.name,
      displayName: displayName ?? this.displayName,
      initials: initials ?? this.initials,
      email: email ?? this.email,
      phone: phone ?? this.phone,
      territory: territory ?? this.territory,
      branchId: branchId ?? this.branchId,
      role: role ?? this.role,
      joinedDate: joinedDate,
      photoUrl: photoUrl ?? this.photoUrl,
      isActive: isActive,
      offlineMode: offlineMode ?? this.offlineMode,
      gpsAutofill: gpsAutofill ?? this.gpsAutofill,
      lastWeekTemplate: lastWeekTemplate ?? this.lastWeekTemplate,
      pushNotifications: pushNotifications ?? this.pushNotifications,
      accountStatus: accountStatus,
      userDocId: userDocId,
    );
  }

  static bool _readBool(dynamic value, {required bool fallback}) {
    if (value is bool) return value;
    final normalized = value?.toString().trim().toLowerCase();
    if (normalized == 'true' || normalized == '1' || normalized == 'yes') {
      return true;
    }
    if (normalized == 'false' || normalized == '0' || normalized == 'no') {
      return false;
    }
    return fallback;
  }
}
