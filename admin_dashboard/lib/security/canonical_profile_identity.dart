import '../models/user_profile.dart';

class CanonicalProfileIdentity {
  const CanonicalProfileIdentity._();

  static String strictLinkedDocumentId(Map<String, dynamic> accessData) {
    final bool hasCamel = accessData.containsKey('userDocId');
    final bool hasSnake = accessData.containsKey('user_doc_id');
    if (!hasCamel && !hasSnake) return '';

    final Object? camelValue = accessData['userDocId'];
    final Object? snakeValue = accessData['user_doc_id'];
    if ((hasCamel && camelValue is! String) ||
        (hasSnake && snakeValue is! String)) {
      return '';
    }

    final String camel = (camelValue as String? ?? '').trim();
    final String snake = (snakeValue as String? ?? '').trim();
    if ((hasCamel && camel.isEmpty) || (hasSnake && snake.isEmpty)) {
      return '';
    }
    if (camel.isNotEmpty && snake.isNotEmpty && camel != snake) return '';
    return camel.isNotEmpty ? camel : snake;
  }

  static Map<String, dynamic>? strictActiveV2Identity({
    required Map<String, dynamic> accessData,
    required String authUid,
  }) {
    return strictV2Identity(accessData: accessData, authUid: authUid);
  }

  static Map<String, dynamic>? strictV2Identity({
    required Map<String, dynamic> accessData,
    required String authUid,
    bool allowSuspended = false,
  }) {
    const Set<String> roles = <String>{
      UserProfile.roleAdmin,
      UserProfile.roleDeveloper,
      UserProfile.roleBranchManager,
      UserProfile.roleSupervisor,
      UserProfile.roleSalesman,
    };
    final Object? version = accessData['accessVersion'];
    final Object? uid = accessData['uid'];
    final Object? role = accessData['role'];
    final Object? status = accessData['status'];
    final Object? branchId = accessData['branchId'];
    final Object? employeeCode = accessData['employeeCode'];
    if (version is! int ||
        version != 2 ||
        uid is! String ||
        uid != authUid ||
        role is! String ||
        !roles.contains(role) ||
        (status != UserProfile.statusActive &&
            !(allowSuspended && status == UserProfile.statusSuspended)) ||
        branchId is! String ||
        employeeCode is! String) {
      return null;
    }
    final Object? codes = accessData['assignedSalesmanCodes'];
    return <String, dynamic>{
      'uid': uid,
      'role': role,
      'status': status,
      'branchId': branchId,
      'employeeCode': employeeCode,
      'assignedSalesmanCodes': codes is List ? codes : const <dynamic>[],
    };
  }

  static bool matches({
    required Map<String, dynamic> accessData,
    required Map<String, dynamic> canonicalData,
    required String authUid,
    required String authEmail,
  }) {
    final String accessRole = _firstText(<Object?>[
      accessData['role'],
      accessData['user_group'],
    ]);
    final String canonicalRole = _firstText(<Object?>[
      canonicalData['role'],
      canonicalData['user_group'],
      canonicalData['roleLabel'],
      canonicalData['userRole'],
      canonicalData['position'],
    ]);
    if (accessRole.isEmpty || canonicalRole.isEmpty) return false;
    if (UserProfile.normalizeRole(accessRole) !=
        UserProfile.normalizeRole(canonicalRole)) {
      return false;
    }

    final String? indexedUid = _consistentAliasText(accessData, const <String>[
      'uid',
      'user_uid',
    ]);
    if (indexedUid == null ||
        (indexedUid.isNotEmpty && indexedUid != authUid)) {
      return false;
    }

    return matchesCanonicalProfile(
      canonicalData: canonicalData,
      authUid: authUid,
      authEmail: authEmail,
    );
  }

  static bool matchesCanonicalProfile({
    required Map<String, dynamic> canonicalData,
    required String authUid,
    required String authEmail,
  }) {
    final String? profileUid = _consistentAliasText(
      canonicalData,
      const <String>['uid', 'userUid', 'user_uid'],
    );
    if (profileUid == null ||
        (profileUid.isNotEmpty && profileUid != authUid)) {
      return false;
    }

    final String profileEmail = _firstText(<Object?>[
      canonicalData['email'],
    ]).toLowerCase();
    final String normalisedAuthEmail = authEmail.trim().toLowerCase();
    return profileEmail.isEmpty ||
        normalisedAuthEmail.isEmpty ||
        profileEmail == normalisedAuthEmail;
  }

  static bool isActiveAccessIndex(Map<String, dynamic> accessData) {
    return UserProfile.normalizeStatus(
          _firstText(<Object?>[
            accessData['status'],
            accessData['accountStatus'],
            accessData['account_status'],
          ]),
          isActive:
              accessData['isActive'] ??
              accessData['active'] ??
              accessData['enabled'],
        ) ==
        UserProfile.statusActive;
  }

  static bool isActiveCanonical(Map<String, dynamic> canonicalData) {
    return UserProfile.normalizeStatus(
          _firstText(<Object?>[
            canonicalData['status'],
            canonicalData['accountStatus'],
            canonicalData['account_status'],
          ]),
          isActive:
              canonicalData['isActive'] ??
              canonicalData['active'] ??
              canonicalData['enabled'],
        ) ==
        UserProfile.statusActive;
  }

  static String _firstText(Iterable<Object?> values) {
    for (final Object? value in values) {
      final String text = (value ?? '').toString().trim();
      if (text.isNotEmpty) return text;
    }
    return '';
  }

  static String? _consistentAliasText(
    Map<String, dynamic> data,
    Iterable<String> keys,
  ) {
    String? first;
    bool found = false;
    for (final String key in keys) {
      if (!data.containsKey(key)) continue;
      found = true;
      final Object? raw = data[key];
      if (raw is! String) return null;
      final String value = raw.trim();
      if (value.isEmpty) return null;
      if (first != null && first != value) return null;
      first = value;
    }
    return found ? first : '';
  }
}
