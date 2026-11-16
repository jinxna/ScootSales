part of 'staff_api_client.dart';

class StaffCodeSent {
  const StaffCodeSent({
    required this.isSending,
    required this.sentTo,
    required this.expiresInSeconds,
    required this.backupCodesLeft,
  });

  factory StaffCodeSent.fromJson(Map<String, Object?> json) => StaffCodeSent(
    isSending: json['status'] == 'sending',
    sentTo: _requiredText(json, 'sentTo'),
    expiresInSeconds: json['expiresInSeconds'] is int
        ? json['expiresInSeconds'] as int
        : 600,
    backupCodesLeft: json['backupCodesLeft'] is int
        ? json['backupCodesLeft'] as int
        : 0,
  );

  final bool isSending;
  final String sentTo;
  final int expiresInSeconds, backupCodesLeft;
}

class StaffSignedIn {
  const StaffSignedIn({
    required this.sessionId,
    required this.email,
    required this.name,
    required this.role,
    required this.usedBackupCode,
    required this.backupCodesLeft,
    this.deviceToken,
    this.deviceTokenExpiresAt,
  });

  factory StaffSignedIn.fromJson(Map<String, Object?> json) => StaffSignedIn(
    sessionId: _requiredText(json, 'sessionId'),
    email: _requiredText(json, 'email'),
    name: json['name'] is String ? json['name'] as String : null,
    role: _requiredText(json, 'role'),
    usedBackupCode: json['usedBackupCode'] == true,
    backupCodesLeft: json['backupCodesLeft'] is int
        ? json['backupCodesLeft'] as int
        : 0,
    deviceToken: json['deviceToken'] is String
        ? json['deviceToken'] as String
        : null,
    deviceTokenExpiresAt: json['deviceTokenExpiresAt'] is String
        ? json['deviceTokenExpiresAt'] as String
        : null,
  );

  final String sessionId, email, role;
  final String? name;
  final bool usedBackupCode;
  final int backupCodesLeft;
  final String? deviceToken, deviceTokenExpiresAt;
}

class StaffSessionInfo {
  const StaffSessionInfo({
    required this.handle,
    required this.createdAt,
    required this.userAgent,
    required this.ip,
    required this.isCurrent,
  });

  factory StaffSessionInfo.fromJson(Map<String, Object?> json) =>
      StaffSessionInfo(
        handle: _requiredText(json, 'sessionId'),
        createdAt: _requiredText(json, 'createdAt'),
        userAgent: json['userAgent'] is String
            ? json['userAgent'] as String
            : '',
        ip: json['ip'] is String ? json['ip'] as String : '',
        isCurrent: json['current'] == true,
      );

  final String handle, createdAt, userAgent, ip;
  final bool isCurrent;
}

class StaffPerson {
  const StaffPerson({
    required this.staffId,
    required this.email,
    required this.name,
    required this.role,
    required this.status,
    required this.lastSignInAt,
    required this.inviteExpiresAt,
  });

  factory StaffPerson.fromJson(Map<String, Object?> json) => StaffPerson(
    staffId: _requiredText(json, 'staffId'),
    email: _requiredText(json, 'email'),
    name: json['name'] is String ? json['name'] as String : null,
    role: _requiredText(json, 'role'),
    status: _requiredText(json, 'status'),
    lastSignInAt: json['lastSignInAt'] is String
        ? json['lastSignInAt'] as String
        : null,
    inviteExpiresAt: json['inviteExpiresAt'] is String
        ? json['inviteExpiresAt'] as String
        : null,
  );

  final String staffId, email, role, status;
  final String? name, lastSignInAt, inviteExpiresAt;

  bool get isActive => status == 'active';
  bool get isApprover => isActive && (role == 'owner' || role == 'operator');
  bool get isInvited => status == 'invited';
}

class StaffDirectory {
  const StaffDirectory({
    required this.people,
    required this.domains,
    this.soloOwnerSetting = false,
    this.soloOwnerActive = false,
  });

  final List<StaffPerson> people;
  final List<String> domains;
  final bool soloOwnerSetting, soloOwnerActive;
}

class StaffInviteInfo {
  const StaffInviteInfo({
    required this.email,
    required this.name,
    required this.role,
  });

  factory StaffInviteInfo.fromJson(Map<String, Object?> json) =>
      StaffInviteInfo(
        email: _requiredText(json, 'email'),
        name: json['name'] is String ? json['name'] as String : null,
        role: _requiredText(json, 'role'),
      );

  final String email, role;
  final String? name;
}

extension StaffAccessApi on StaffApiClient {
  Future<StaffInviteInfo> checkInvite(String token) async =>
      StaffInviteInfo.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['invite', 'check']),
            body: <String, Object?>{'token': token},
          ),
        ),
      );

  Future<void> acceptInvite(
    String token, {
    required String password,
    String? name,
  }) async {
    await _send(
      'POST',
      _uri(<String>['invite', 'accept']),
      body: <String, Object?>{
        'token': token,
        'password': password,
        if (name != null && name.trim().isNotEmpty) 'name': name.trim(),
      },
    );
  }

  Future<void> requestPasswordReset(String email) async {
    await _send(
      'POST',
      _uri(<String>['password-reset']),
      body: <String, Object?>{'email': email},
    );
  }

  Future<StaffCodeSent> requestSignInCode() async => StaffCodeSent.fromJson(
    _objectMap(await _send('POST', _uri(<String>['session', 'code']))),
  );

  Future<StaffSignedIn> verifySignIn({
    String? code,
    String? backupCode,
    bool remember = false,
  }) async => StaffSignedIn.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['session', 'verify']),
        body: <String, Object?>{
          'code': ?code,
          'backupCode': ?backupCode,
          if (remember) 'remember': true,
        },
      ),
    ),
  );

  Future<StaffSignedIn> signInTrusted(String deviceToken) async =>
      StaffSignedIn.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['session', 'trusted']),
            body: <String, Object?>{'deviceToken': deviceToken},
          ),
        ),
      );

  Future<List<StaffSessionInfo>> staffSessions() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['sessions'])),
    )['sessions'];
    if (rows is! List) throw const FormatException('Invalid sessions.');
    return rows
        .map((Object? row) => StaffSessionInfo.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<void> endStaffSession(String handle) async {
    await _send('DELETE', _uri(<String>['sessions', handle]));
  }

  Future<void> endAllStaffSessions() async {
    await _send('POST', _uri(<String>['sessions', 'sign-out-all']));
  }

  Future<int> backupCodesLeft() async {
    final Object? left = _objectMap(
      await _send('GET', _uri(<String>['backup-codes'])),
    )['remaining'];
    if (left is! int) throw const FormatException('Invalid backup codes.');
    return left;
  }

  Future<List<String>> createBackupCodes() async {
    final Object? codes = _objectMap(
      await _send('POST', _uri(<String>['backup-codes']), endsSession: false),
    )['codes'];
    if (codes is! List) throw const FormatException('Invalid backup codes.');
    return codes.whereType<String>().toList(growable: false);
  }

  Future<StaffDirectory> staffDirectory() async {
    final Map<String, Object?> body = _objectMap(
      await _send('GET', _uri(<String>['staff'])),
    );
    final Object? rows = body['staff'];
    final Object? domains = body['domains'];
    final Object? solo = body['soloOwner'];
    if (rows is! List) throw const FormatException('Invalid staff.');
    return StaffDirectory(
      soloOwnerSetting: solo is Map && solo['enabled'] == true,
      soloOwnerActive: solo is Map && solo['active'] == true,
      people: rows
          .map((Object? row) => StaffPerson.fromJson(_objectMap(row)))
          .toList(growable: false),
      domains: domains is List
          ? domains.whereType<String>().toList(growable: false)
          : const <String>[],
    );
  }

  Future<void> inviteStaff({
    required String email,
    required String name,
    required String role,
  }) async {
    await _send(
      'POST',
      _uri(<String>['staff']),
      body: <String, Object?>{'email': email, 'name': name, 'role': role},
    );
  }

  Future<void> changeStaffRole(String staffId, String role) async {
    await _send(
      'PUT',
      _uri(<String>['staff', staffId, 'role']),
      body: <String, Object?>{'role': role},
    );
  }

  Future<void> disableStaff(String staffId) async {
    await _send('POST', _uri(<String>['staff', staffId, 'disable']));
  }

  Future<void> removeStaff(String staffId) async {
    await _send('POST', _uri(<String>['staff', staffId, 'remove']));
  }
}

class StaffSupportGrant {
  const StaffSupportGrant({
    required this.grantId,
    required this.tenantId,
    required this.companyName,
    required this.workspace,
    required this.staffEmail,
    required this.scope,
    required this.task,
    required this.expiresAt,
  });

  factory StaffSupportGrant.fromJson(Map<String, Object?> json) =>
      StaffSupportGrant(
        grantId: _requiredText(json, 'grantId'),
        tenantId: _requiredText(json, 'tenantId'),
        companyName: _nullableText(json, 'companyName'),
        workspace: _nullableText(json, 'workspace'),
        staffEmail: _requiredText(json, 'staffEmail'),
        scope: _requiredText(json, 'scope'),
        task: _nullableText(json, 'task'),
        expiresAt: _requiredTimestamp(json, 'expiresAt'),
      );

  final String grantId, tenantId, staffEmail, scope, expiresAt;
  final String? companyName, workspace, task;
  String get companyLabel => companyName ?? tenantId;
}

extension StaffSupportApi on StaffApiClient {
  Future<List<StaffSupportGrant>> supportHome() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['support', 'home'])),
    )['grants'];
    if (rows is! List) throw const FormatException('Invalid support home.');
    return rows
        .map((Object? row) => StaffSupportGrant.fromJson(_objectMap(row)))
        .toList(growable: false);
  }
}
