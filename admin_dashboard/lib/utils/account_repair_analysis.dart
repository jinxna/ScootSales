import '../models/user_profile.dart';
import '../security/canonical_profile_identity.dart';
import '../security/user_access_index.dart';

class AccountRepairDocument {
  const AccountRepairDocument({required this.id, required this.data});

  final String id;
  final Map<String, dynamic> data;
}

enum AccountRepairFindingKind {
  missingAccess,
  orphanAccess,
  invalidSupervisorCode,
  invalidSalesmanSupervisor,
  pendingProvisioning,
}

class AccountRepairFinding {
  const AccountRepairFinding({
    required this.kind,
    required this.recordId,
    required this.title,
    required this.description,
    this.relatedId = '',
    this.canRepair = false,
  });

  final AccountRepairFindingKind kind;
  final String recordId;
  final String relatedId;
  final String title;
  final String description;
  final bool canRepair;
}

class AccountRepairReport {
  const AccountRepairReport({
    required this.findings,
    this.usersScanned = 0,
    this.accessRecordsScanned = 0,
    this.scanComplete = true,
  });

  final List<AccountRepairFinding> findings;
  final int usersScanned;
  final int accessRecordsScanned;
  final bool scanComplete;

  static const String authEnumerationNote =
      'This check cannot list Firebase Authentication logins. It may not '
      'detect a login that has no saved profile.';
}

class AccountRepairAnalysis {
  static String decodeCanonicalRole(Object? raw) {
    if (raw is! String || raw.trim().isEmpty) return '';
    final String role = raw.trim().toLowerCase().replaceAll(' ', '_');
    switch (role) {
      case 'administrator':
        return UserProfile.roleAdmin;
      case 'sales_representative':
        return UserProfile.roleSalesman;
      case UserProfile.roleAdmin:
      case UserProfile.roleDeveloper:
      case UserProfile.roleBranchManager:
      case UserProfile.roleSupervisor:
      case UserProfile.roleSalesman:
        return role;
      default:
        return '';
    }
  }

  static String decodeRulesRole(Map<String, dynamic> data) {
    final Object? raw = data.containsKey('role')
        ? data['role']
        : data['user_group'];
    if (raw is! String) return '';
    final String role = raw.toLowerCase().replaceAll(' ', '_');
    switch (role) {
      case 'administrator':
        return UserProfile.roleAdmin;
      case 'sales_representative':
        return UserProfile.roleSalesman;
      case UserProfile.roleAdmin:
      case UserProfile.roleDeveloper:
      case UserProfile.roleBranchManager:
      case UserProfile.roleSupervisor:
      case UserProfile.roleSalesman:
        return role;
      default:
        return '';
    }
  }

  const AccountRepairAnalysis._();

  static AccountRepairReport analyze({
    required List<AccountRepairDocument> users,
    required List<AccountRepairDocument> accessRecords,
    required String actorUid,
  }) {
    final List<AccountRepairFinding> findings = <AccountRepairFinding>[];
    final Map<String, List<AccountRepairDocument>> usersByUid =
        <String, List<AccountRepairDocument>>{};
    final Map<String, List<AccountRepairDocument>> accessById =
        <String, List<AccountRepairDocument>>{};
    final Map<String, List<AccountRepairDocument>> accessByUid =
        <String, List<AccountRepairDocument>>{};
    final Map<String, List<AccountRepairDocument>> usersByCode =
        <String, List<AccountRepairDocument>>{};

    for (final AccountRepairDocument profile in users) {
      final String? uid = _strictAlias(profile.data, const <String>[
        'uid',
        'userUid',
        'user_uid',
      ]);
      if (uid != null && uid.isNotEmpty) {
        usersByUid
            .putIfAbsent(uid, () => <AccountRepairDocument>[])
            .add(profile);
      }
      for (final String code in _profileCodes(profile.data)) {
        usersByCode
            .putIfAbsent(code, () => <AccountRepairDocument>[])
            .add(profile);
      }
    }
    for (final AccountRepairDocument access in accessRecords) {
      accessById[access.id] = <AccountRepairDocument>[access];
      final String? uid = _strictAlias(access.data, const <String>[
        'uid',
        'user_uid',
      ]);
      if (uid != null && uid.isNotEmpty) {
        accessByUid
            .putIfAbsent(uid, () => <AccountRepairDocument>[])
            .add(access);
      }
    }

    for (final AccountRepairDocument profile in users) {
      if (profile.data['provisioningState'] == 'pending') {
        findings.add(
          AccountRepairFinding(
            kind: AccountRepairFindingKind.pendingProvisioning,
            recordId: profile.id,
            relatedId:
                _strictAlias(profile.data, const <String>[
                  'uid',
                  'userUid',
                  'user_uid',
                ]) ??
                '',
            title: 'Provisioning needs manual follow-up',
            description:
                'This profile is still marked pending. Check the original '
                'provisioning attempt and Firebase Authentication manually.',
          ),
        );
      }

      final String? uid = _strictAlias(profile.data, const <String>[
        'uid',
        'userUid',
        'user_uid',
      ]);
      if (uid == null || uid.isEmpty || accessById.containsKey(uid)) continue;

      final AccountRepairDocument? legacyUidProfile = _firstById(users, uid);
      final bool legacyUidConflict =
          legacyUidProfile != null && legacyUidProfile.id != profile.id;

      findings.add(
        AccountRepairFinding(
          kind: AccountRepairFindingKind.missingAccess,
          recordId: profile.id,
          relatedId: uid,
          title: 'Account profile is missing an access record',
          description: legacyUidConflict
              ? 'A different profile exists at users/$uid. The identity is '
                    'ambiguous; review it manually.'
              : 'This profile has no access record, so the person cannot use '
                    'the app. Invite them again to restore access.',
        ),
      );
    }

    for (final AccountRepairDocument access in accessRecords) {
      final String linkedId = CanonicalProfileIdentity.strictLinkedDocumentId(
        access.data,
      );
      final String uid = access.id;
      final AccountRepairDocument? linked = linkedId.isNotEmpty
          ? _firstById(users, linkedId)
          : _firstById(users, uid);
      if (linked == null) {
        findings.add(
          AccountRepairFinding(
            kind: AccountRepairFindingKind.orphanAccess,
            recordId: access.id,
            relatedId: linkedId,
            title: 'Access record has no linked profile',
            description:
                'The access index points to a missing profile. Review the '
                'identity manually; this check never deletes records.',
          ),
        );
      }
    }

    for (final AccountRepairDocument supervisor in users) {
      if (_strictRole(supervisor.data) != UserProfile.roleSupervisor) continue;
      final String? supervisorUid = _strictAlias(
        supervisor.data,
        const <String>['uid', 'userUid', 'user_uid'],
      );
      if (supervisorUid == null || supervisorUid.isEmpty) continue;
      final AccountRepairDocument? supervisorAccess = _singleAccessForUid(
        supervisorUid,
        accessById,
        accessByUid,
      );
      final bool mirrored =
          supervisorAccess != null &&
          _strictRole(supervisorAccess.data) == UserProfile.roleSupervisor &&
          CanonicalProfileIdentity.strictLinkedDocumentId(
                supervisorAccess.data,
              ) ==
              supervisor.id &&
          supervisorUid != actorUid.trim();
      final Set<String> codes = <String>{
        ...UserAccessIndex.parseAssignedSalesmanCodes(
          supervisor.data['assignedSalesmanCodes'],
        ),
        if (supervisorAccess != null)
          ...UserAccessIndex.parseAssignedSalesmanCodes(
            supervisorAccess.data['assignedSalesmanCodes'],
          ),
      };
      for (final String code in codes) {
        final List<AccountRepairDocument> matches =
            usersByCode[code] ?? const [];
        if (matches.length == 1 &&
            _strictRole(matches.single.data) == UserProfile.roleSalesman) {
          continue;
        }
        findings.add(
          AccountRepairFinding(
            kind: AccountRepairFindingKind.invalidSupervisorCode,
            recordId: supervisor.id,
            relatedId: code,
            title: matches.isEmpty
                ? 'Supervisor has a missing salesman code'
                : matches.length > 1
                ? 'Supervisor code is ambiguous'
                : 'Supervisor code belongs to a non-salesman',
            description: matches.length > 1
                ? 'More than one profile matches this code. Review it manually.'
                : 'This code does not identify one salesman profile. The '
                      'repair removes it from the profile and access index.',
            canRepair:
                mirrored &&
                (matches.isEmpty ||
                    (matches.length == 1 &&
                        _isRecognisedRole(_strictRole(matches.single.data)) &&
                        _strictRole(matches.single.data) !=
                            UserProfile.roleSalesman)),
          ),
        );
      }
    }

    for (final AccountRepairDocument profile in users) {
      if (_strictRole(profile.data) != UserProfile.roleSalesman) continue;
      final String? uid = _strictAlias(profile.data, const <String>[
        'uid',
        'userUid',
        'user_uid',
      ]);
      if (uid == null || uid.isEmpty) continue;
      final AccountRepairDocument? salesmanAccess = _singleAccessForUid(
        uid,
        accessById,
        accessByUid,
      );
      final Set<String> supervisorUids = <String>{
        ..._presentAliasValues(profile.data, const <String>[
          'supervisorUid',
          'supervisor_uid',
        ]),
        if (salesmanAccess != null)
          ..._presentAliasValues(salesmanAccess.data, const <String>[
            'supervisorUid',
            'supervisor_uid',
          ]),
      };
      if (supervisorUids.isEmpty) continue;
      final String supervisorUid = supervisorUids.first;
      final bool oneUid = supervisorUids.length == 1;
      final List<AccountRepairDocument> supervisorProfiles =
          usersByUid[supervisorUid] ?? const [];
      final Set<String> supervisorCodes = <String>{
        ..._presentAliasValues(profile.data, const <String>[
          'supervisorId',
          'supervisor_id',
        ]),
        if (salesmanAccess != null)
          ..._presentAliasValues(salesmanAccess.data, const <String>[
            'supervisorId',
            'supervisor_id',
          ]),
      };
      final List<AccountRepairDocument> profilesByCode = supervisorCodes
          .expand(
            (String code) =>
                usersByCode[code] ?? const <AccountRepairDocument>[],
          )
          .toList();
      final bool supervisorCodesAgree = supervisorCodes.length <= 1;
      final AccountRepairDocument? profileByDocumentId = _firstById(
        users,
        supervisorUid,
      );
      final List<AccountRepairDocument> possibleSupervisorProfiles =
          <AccountRepairDocument>{
            ...supervisorProfiles.where(
              (AccountRepairDocument candidate) =>
                  _strictRole(candidate.data) == UserProfile.roleSupervisor,
            ),
            ...profilesByCode.where(
              (AccountRepairDocument candidate) =>
                  _strictRole(candidate.data) == UserProfile.roleSupervisor,
            ),
            if (profileByDocumentId != null &&
                _strictRole(profileByDocumentId.data) ==
                    UserProfile.roleSupervisor)
              profileByDocumentId,
          }.toList();
      final AccountRepairDocument? supervisorAccess = _singleAccessForUid(
        supervisorUid,
        accessById,
        accessByUid,
      );
      final bool validSupervisor =
          oneUid &&
          supervisorProfiles.length == 1 &&
          _strictRole(supervisorProfiles.single.data) ==
              UserProfile.roleSupervisor &&
          supervisorAccess != null &&
          _strictRole(supervisorAccess.data) == UserProfile.roleSupervisor &&
          CanonicalProfileIdentity.strictLinkedDocumentId(
                supervisorAccess.data,
              ) ==
              supervisorProfiles.single.id &&
          supervisorUids.length == 1;
      if (validSupervisor) continue;

      final bool mirrorsAgree =
          salesmanAccess != null &&
          CanonicalProfileIdentity.strictLinkedDocumentId(
                salesmanAccess.data,
              ) ==
              profile.id &&
          _strictRole(salesmanAccess.data) == UserProfile.roleSalesman &&
          uid != actorUid.trim() &&
          oneUid;
      findings.add(
        AccountRepairFinding(
          kind: AccountRepairFindingKind.invalidSalesmanSupervisor,
          recordId: profile.id,
          relatedId: supervisorUid,
          title: 'Salesman supervisor link is invalid',
          description: possibleSupervisorProfiles.isNotEmpty
              ? 'A supervisor profile exists, but its access record is '
                    'missing or legacy. Repair the supervisor\'s account first.'
              : mirrorsAgree
              ? 'The referenced UID has no matching supervisor profile and '
                    'access record. A repair clears the supervisor UID link '
                    'in both mirrors.'
              : 'The account identity or supervisor aliases conflict. Review '
                    'this link manually.',
          canRepair:
              mirrorsAgree &&
              supervisorCodesAgree &&
              possibleSupervisorProfiles.isEmpty,
        ),
      );
    }

    return AccountRepairReport(
      findings: List<AccountRepairFinding>.unmodifiable(findings),
      usersScanned: users.length,
      accessRecordsScanned: accessRecords.length,
    );
  }

  static AccountRepairDocument? _singleAccessForUid(
    String uid,
    Map<String, List<AccountRepairDocument>> accessById,
    Map<String, List<AccountRepairDocument>> accessByUid,
  ) {
    final List<AccountRepairDocument> byId = accessById[uid] ?? const [];
    final List<AccountRepairDocument> byAlias = accessByUid[uid] ?? const [];
    if (byId.length != 1 ||
        (byAlias.isNotEmpty &&
            (byAlias.length != 1 || byAlias.single.id != uid))) {
      return null;
    }
    return byId.single;
  }

  static AccountRepairDocument? _firstById(
    List<AccountRepairDocument> documents,
    String id,
  ) {
    for (final AccountRepairDocument document in documents) {
      if (document.id == id) return document;
    }
    return null;
  }

  static Set<String> _profileCodes(Map<String, dynamic> data) {
    final Set<String> values = <String>{};
    for (final String key in const <String>[
      'employeeCode',
      'employee_code',
      'staffId',
      'staff_id',
      'salesmanCode',
      'salesman_code',
      'userId',
      'user_id',
    ]) {
      final Object? value = data[key];
      if (value is String && value.trim().isNotEmpty) values.add(value.trim());
    }
    return values;
  }

  static String _strictRole(Map<String, dynamic> data) {
    final List<String> values = <String>[];
    for (final String key in const <String>[
      'role',
      'user_group',
      'roleLabel',
      'userRole',
      'position',
    ]) {
      final Object? value = data[key];
      if (value is String && value.trim().isNotEmpty) {
        values.add(decodeCanonicalRole(value));
      } else if (value != null) {
        return '';
      }
    }
    if (values.isEmpty || values.any((String value) => value != values.first)) {
      return '';
    }
    return values.first;
  }

  static bool _isRecognisedRole(String role) => const <String>{
    UserProfile.roleAdmin,
    UserProfile.roleDeveloper,
    UserProfile.roleBranchManager,
    UserProfile.roleSupervisor,
    UserProfile.roleSalesman,
  }.contains(role);

  static String? decodeRepairStatus(Map<String, dynamic> data) {
    bool? activeFlag;
    for (final String key in const <String>[
      'isActive',
      'is_active',
      'active',
      'enabled',
    ]) {
      if (!data.containsKey(key)) continue;
      final Object? value = data[key];
      final bool? parsed = _activeFlag(value);
      if (parsed == null || (activeFlag != null && activeFlag != parsed)) {
        return null;
      }
      activeFlag = parsed;
    }
    bool? statusIsActive;
    for (final String key in const <String>[
      'status',
      'accountStatus',
      'account_status',
    ]) {
      if (!data.containsKey(key)) continue;
      final bool? parsed = _activeStatus(data[key]);
      if (parsed == null ||
          (statusIsActive != null && statusIsActive != parsed)) {
        return null;
      }
      statusIsActive = parsed;
    }
    if (activeFlag != null &&
        statusIsActive != null &&
        activeFlag != statusIsActive) {
      return null;
    }
    if (activeFlag == false || statusIsActive == false) {
      return UserProfile.statusSuspended;
    }
    return UserProfile.statusActive;
  }

  static bool? _activeFlag(Object? value) {
    if (value == true || value == 1) return true;
    if (value == false || value == 0) return false;
    if (value is! String) return null;
    switch (value.toLowerCase()) {
      case 'true':
      case '1':
      case 'yes':
        return true;
      case 'false':
      case '0':
      case 'no':
      case 'off':
      case 'n':
        return false;
      default:
        return null;
    }
  }

  static bool? _activeStatus(Object? value) {
    if (value == 'active' || value == 'Active') return true;
    if (value is! String) return null;
    final String status = value.trim().toLowerCase();
    if (const <String>{'false', '0', 'no'}.contains(status) ||
        status.contains('suspend') ||
        status.contains('inactive') ||
        status.contains('disable') ||
        status.contains('deactiv')) {
      return false;
    }
    return null;
  }

  static String? _strictAlias(Map<String, dynamic> data, List<String> keys) {
    String? result;
    bool found = false;
    for (final String key in keys) {
      if (!data.containsKey(key)) continue;
      found = true;
      final Object? value = data[key];
      if (value is! String || value.trim().isEmpty) return null;
      final String text = value.trim();
      if (result != null && result != text) return null;
      result = text;
    }
    return found ? result : null;
  }

  static Set<String> _presentAliasValues(
    Map<String, dynamic> data,
    List<String> keys,
  ) {
    final Set<String> values = <String>{};
    for (final String key in keys) {
      final Object? value = data[key];
      if (value is String && value.trim().isNotEmpty) values.add(value.trim());
    }
    return values;
  }
}
