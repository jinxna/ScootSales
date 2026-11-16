String? canonicalProfileIdFromAccess(Map<String, dynamic> accessData) {
  final bool hasCamel = accessData.containsKey('userDocId');
  final bool hasSnake = accessData.containsKey('user_doc_id');
  if (!hasCamel && !hasSnake) return null;

  final Object? camelValue = accessData['userDocId'];
  final Object? snakeValue = accessData['user_doc_id'];
  if ((hasCamel && camelValue is! String) ||
      (hasSnake && snakeValue is! String)) {
    return null;
  }

  final String camel = (camelValue as String? ?? '').trim();
  final String snake = (snakeValue as String? ?? '').trim();
  if ((hasCamel && camel.isEmpty) || (hasSnake && snake.isEmpty)) {
    return null;
  }
  if (camel.isNotEmpty && snake.isNotEmpty && camel != snake) return null;
  final String resolved = camel.isNotEmpty ? camel : snake;
  return resolved.isEmpty ? null : resolved;
}

bool accessIdentityMatchesAuth(
  String authUid,
  Map<String, dynamic> accessData,
) {
  for (final String key in const <String>['uid', 'user_uid']) {
    if (!accessData.containsKey(key)) continue;
    final Object? value = accessData[key];
    if (value is! String || value != authUid) return false;
  }
  return true;
}

Map<String, dynamic>? strictActiveV2Identity(
  String authUid,
  Map<String, dynamic> accessData,
) {
  const Set<String> roles = <String>{
    'admin',
    'developer',
    'branch_manager',
    'supervisor',
    'salesman',
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
      status != 'active' ||
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

bool canonicalProfileMatchesAuth(
  String authUid,
  Map<String, dynamic> profileData,
) {
  for (final String key in const <String>['uid', 'userUid', 'user_uid']) {
    if (!profileData.containsKey(key)) continue;
    final Object? value = profileData[key];
    if (value is! String || value != authUid) return false;
  }
  return true;
}
