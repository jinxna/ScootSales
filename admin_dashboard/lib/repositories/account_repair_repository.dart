import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../security/canonical_profile_identity.dart';
import '../security/user_access_index.dart';
import '../utils/account_repair_analysis.dart';

abstract interface class AccountRepairRepository {
  Future<AccountRepairReport> scan({required UserProfile actor});

  Future<void> repair(
    AccountRepairFinding finding, {
    required UserProfile actor,
  });
}

class FirestoreAccountRepairRepository implements AccountRepairRepository {
  FirestoreAccountRepairRepository({
    FirebaseFirestore? firestore,
    this.pageSize = 200,
  }) : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;
  final int pageSize;

  static const List<String> _uidFields = <String>['uid', 'userUid', 'user_uid'];
  static const List<String> _accessUidFields = <String>['uid', 'user_uid'];
  static const List<String> _codeFields = <String>[
    'employeeCode',
    'employee_code',
    'staffId',
    'staff_id',
    'salesmanCode',
    'salesman_code',
    'userId',
    'user_id',
  ];

  @override
  Future<AccountRepairReport> scan({required UserProfile actor}) async {
    _requireAdmin(actor);
    if (pageSize < 1 || pageSize > 500) {
      throw StateError('Account scan page size is invalid.');
    }
    final List<AccountRepairDocument> users = await _readAll('users');
    final List<AccountRepairDocument> access = await _readAll('user_access');
    return AccountRepairAnalysis.analyze(
      users: users,
      accessRecords: access,
      actorUid: actor.uid ?? '',
    );
  }

  Future<List<AccountRepairDocument>> _readAll(String collection) async {
    final List<AccountRepairDocument> documents = <AccountRepairDocument>[];
    QueryDocumentSnapshot<Map<String, dynamic>>? cursor;
    while (true) {
      Query<Map<String, dynamic>> query = _firestore
          .collection(collection)
          .orderBy(FieldPath.documentId)
          .limit(pageSize);
      if (cursor != null) query = query.startAfterDocument(cursor);
      final QuerySnapshot<Map<String, dynamic>> page = await query.get();
      documents.addAll(
        page.docs.map(
          (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
              AccountRepairDocument(id: doc.id, data: doc.data()),
        ),
      );
      if (page.docs.length < pageSize) return documents;
      cursor = page.docs.last;
    }
  }

  @override
  Future<void> repair(
    AccountRepairFinding finding, {
    required UserProfile actor,
  }) async {
    _requireAdmin(actor);
    if (!finding.canRepair) {
      throw StateError('This finding needs manual review.');
    }
    switch (finding.kind) {
      case AccountRepairFindingKind.invalidSupervisorCode:
        await _repairSupervisorCode(finding, actor);
        return;
      case AccountRepairFindingKind.invalidSalesmanSupervisor:
        await _repairSalesmanSupervisor(finding, actor);
        return;
      case AccountRepairFindingKind.missingAccess:
      case AccountRepairFindingKind.orphanAccess:
      case AccountRepairFindingKind.pendingProvisioning:
        throw StateError('This finding needs manual review.');
    }
  }

  Future<void> _repairSupervisorCode(
    AccountRepairFinding finding,
    UserProfile actor,
  ) async {
    _requireSafeDocumentId(finding.recordId);
    _requireSafeDocumentId(finding.relatedId);
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> codeCandidates =
        await _queryCandidates('users', _codeFields, finding.relatedId);
    if (codeCandidates.length > 1) {
      throw StateError('The code is ambiguous. Review it manually.');
    }
    final DocumentReference<Map<String, dynamic>> supervisorRef = _firestore
        .collection('users')
        .doc(finding.recordId);
    await _firestore.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> supervisorSnapshot =
          await transaction.get(supervisorRef);
      if (!supervisorSnapshot.exists) {
        throw StateError('The supervisor changed after the scan.');
      }
      final Map<String, dynamic> supervisor = supervisorSnapshot.data()!;
      final String uid = _textAlias(supervisor, _uidFields) ?? '';
      _requireSafeDocumentId(uid);
      final DocumentReference<Map<String, dynamic>> accessRef = _firestore
          .collection('user_access')
          .doc(uid);
      final DocumentSnapshot<Map<String, dynamic>> accessSnapshot =
          await transaction.get(accessRef);
      final List<DocumentSnapshot<Map<String, dynamic>>> candidateSnapshots =
          await _readCandidateRefs(transaction, 'users', codeCandidates);
      final DocumentSnapshot<Map<String, dynamic>> codeIdSnapshot =
          await transaction.get(
            _firestore.collection('users').doc(finding.relatedId),
          );

      final bool candidateStillInvalid = candidateSnapshots.isEmpty
          ? !codeIdSnapshot.exists
          : candidateSnapshots.length == 1 &&
                candidateSnapshots.single.exists &&
                _sameData(
                  candidateSnapshots.single.data()!,
                  codeCandidates.single.data(),
                ) &&
                _hasCode(
                  candidateSnapshots.single.data()!,
                  finding.relatedId,
                ) &&
                _role(candidateSnapshots.single.data()!) !=
                    UserProfile.roleSalesman &&
                (!codeIdSnapshot.exists ||
                    codeIdSnapshot.id == candidateSnapshots.single.id);
      if (uid.isEmpty ||
          uid == (actor.uid ?? '').trim() ||
          !accessSnapshot.exists ||
          _role(supervisor) != UserProfile.roleSupervisor ||
          _role(accessSnapshot.data()!) != UserProfile.roleSupervisor ||
          CanonicalProfileIdentity.strictLinkedDocumentId(
                accessSnapshot.data()!,
              ) !=
              finding.recordId ||
          !(UserAccessIndex.parseAssignedSalesmanCodes(
                supervisor['assignedSalesmanCodes'],
              ).contains(finding.relatedId) ||
              UserAccessIndex.parseAssignedSalesmanCodes(
                accessSnapshot.data()?['assignedSalesmanCodes'],
              ).contains(finding.relatedId)) ||
          !candidateStillInvalid) {
        throw StateError('The assignment changed or is ambiguous. Scan again.');
      }

      final List<String> profileCodes =
          UserAccessIndex.parseAssignedSalesmanCodes(
            supervisor['assignedSalesmanCodes'],
          ).where((String code) => code != finding.relatedId).toList();
      final List<String> accessCodes =
          UserAccessIndex.parseAssignedSalesmanCodes(
            accessSnapshot.data()?['assignedSalesmanCodes'],
          ).where((String code) => code != finding.relatedId).toList();
      transaction.update(supervisorRef, <String, dynamic>{
        'assignedSalesmanCodes': profileCodes,
      });
      transaction.update(accessRef, <String, dynamic>{
        'assignedSalesmanCodes': accessCodes,
        'updatedAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> _repairSalesmanSupervisor(
    AccountRepairFinding finding,
    UserProfile actor,
  ) async {
    _requireSafeDocumentId(finding.recordId);
    _requireSafeDocumentId(finding.relatedId);
    final DocumentReference<Map<String, dynamic>> salesmanRef = _firestore
        .collection('users')
        .doc(finding.recordId);
    final DocumentSnapshot<Map<String, dynamic>> salesmanAtQuery =
        await salesmanRef.get();
    if (!salesmanAtQuery.exists) {
      throw StateError('The salesman changed after the scan.');
    }
    final Map<String, dynamic> salesmanDataAtQuery = salesmanAtQuery.data()!;
    final String salesmanUidAtQuery =
        _textAlias(salesmanDataAtQuery, _uidFields) ?? '';
    _requireSafeDocumentId(salesmanUidAtQuery);
    final DocumentReference<Map<String, dynamic>> accessRef = _firestore
        .collection('user_access')
        .doc(salesmanUidAtQuery);
    final DocumentSnapshot<Map<String, dynamic>> accessAtQuery = await accessRef
        .get();
    final Map<String, dynamic>? accessDataAtQuery = accessAtQuery.data();
    const List<String> supervisorCodeFields = <String>[
      'supervisorId',
      'supervisor_id',
    ];
    final String? supervisorCodeAtQuery = _validatedSupervisorCode(
      salesmanDataAtQuery,
      supervisorCodeFields,
    );
    final String? accessSupervisorCodeAtQuery = accessDataAtQuery == null
        ? null
        : _validatedSupervisorCode(accessDataAtQuery, supervisorCodeFields);
    if ((_hasAnySupervisorCode(salesmanDataAtQuery) &&
            supervisorCodeAtQuery == null) ||
        (supervisorCodeAtQuery != null &&
            supervisorCodeAtQuery.isNotEmpty &&
            accessSupervisorCodeAtQuery != null &&
            accessSupervisorCodeAtQuery.isNotEmpty &&
            supervisorCodeAtQuery != accessSupervisorCodeAtQuery) ||
        (accessDataAtQuery != null &&
            _hasAnySupervisorCode(accessDataAtQuery) &&
            accessSupervisorCodeAtQuery == null)) {
      throw StateError('The supervisor code aliases conflict. Scan again.');
    }
    final String? codeToResolve =
        supervisorCodeAtQuery == null || supervisorCodeAtQuery.isEmpty
        ? accessSupervisorCodeAtQuery
        : supervisorCodeAtQuery;
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> uidCandidates =
        await _queryCandidates('users', _uidFields, finding.relatedId);
    final List<QueryDocumentSnapshot<Map<String, dynamic>>> codeCandidates =
        codeToResolve == null || codeToResolve.isEmpty
        ? <QueryDocumentSnapshot<Map<String, dynamic>>>[]
        : await _queryCandidates('users', _codeFields, codeToResolve);
    if (uidCandidates.length > 1 || codeCandidates.length > 1) {
      throw StateError('Repair the supervisor\'s account first.');
    }
    await _firestore.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> profileSnapshot =
          await transaction.get(salesmanRef);
      if (!profileSnapshot.exists) {
        throw StateError('The salesman changed after the scan.');
      }
      final Map<String, dynamic> profile = profileSnapshot.data()!;
      final String uid = _textAlias(profile, _uidFields) ?? '';
      _requireSafeDocumentId(uid);
      final DocumentSnapshot<Map<String, dynamic>> accessSnapshot =
          await transaction.get(accessRef);
      final DocumentSnapshot<Map<String, dynamic>> targetAccessSnapshot =
          await transaction.get(
            _firestore.collection('user_access').doc(finding.relatedId),
          );
      final List<DocumentSnapshot<Map<String, dynamic>>> uidCandidateSnapshots =
          await _readCandidateRefs(transaction, 'users', uidCandidates);
      final List<DocumentSnapshot<Map<String, dynamic>>>
      codeCandidateSnapshots = await _readCandidateRefs(
        transaction,
        'users',
        codeCandidates,
      );
      final DocumentSnapshot<Map<String, dynamic>> uidDocumentSnapshot =
          await transaction.get(
            _firestore.collection('users').doc(finding.relatedId),
          );
      final DocumentSnapshot<Map<String, dynamic>>? codeDocumentSnapshot =
          codeToResolve == null || codeToResolve.isEmpty
          ? null
          : await transaction.get(
              _firestore.collection('users').doc(codeToResolve),
            );
      final String targetProfileId = targetAccessSnapshot.exists
          ? CanonicalProfileIdentity.strictLinkedDocumentId(
              targetAccessSnapshot.data()!,
            )
          : '';
      if (targetProfileId.isNotEmpty) {
        _requireSafeDocumentId(targetProfileId);
      }
      final DocumentSnapshot<Map<String, dynamic>>? targetProfileSnapshot =
          targetProfileId.isEmpty
          ? null
          : await transaction.get(
              _firestore.collection('users').doc(targetProfileId),
            );

      final Map<String, dynamic>? access = accessSnapshot.data();
      final Set<String> profileLinks = _aliasValues(profile, const <String>[
        'supervisorUid',
        'supervisor_uid',
      ]);
      final Set<String> accessLinks = access == null
          ? <String>{}
          : _aliasValues(access, const <String>[
              'supervisorUid',
              'supervisor_uid',
            ]);
      final bool linkStillPresent = <String>{
        ...profileLinks,
        ...accessLinks,
      }.contains(finding.relatedId);
      final bool targetIsValid =
          targetProfileSnapshot != null &&
          targetProfileSnapshot.exists &&
          _role(targetProfileSnapshot.data()!) == UserProfile.roleSupervisor &&
          _role(targetAccessSnapshot.data()!) == UserProfile.roleSupervisor &&
          _textAlias(targetAccessSnapshot.data()!, _accessUidFields) ==
              finding.relatedId;
      final bool uidCandidatesUnchanged = _candidatesUnchanged(
        uidCandidates,
        uidCandidateSnapshots,
      );
      final bool codeCandidatesUnchanged = _candidatesUnchanged(
        codeCandidates,
        codeCandidateSnapshots,
      );
      final bool targetSupervisorProfileExists =
          <DocumentSnapshot<Map<String, dynamic>>?>[
            ...uidCandidateSnapshots,
            ...codeCandidateSnapshots,
            uidDocumentSnapshot,
            codeDocumentSnapshot,
          ].any(
            (DocumentSnapshot<Map<String, dynamic>>? snapshot) =>
                snapshot != null &&
                snapshot.exists &&
                _role(snapshot.data()!) == UserProfile.roleSupervisor,
          );
      if (uid.isEmpty ||
          uid != salesmanUidAtQuery ||
          uid == (actor.uid ?? '').trim() ||
          profile['provisioningState'] == 'pending' ||
          access == null ||
          _role(profile) != UserProfile.roleSalesman ||
          _role(access) != UserProfile.roleSalesman ||
          CanonicalProfileIdentity.strictLinkedDocumentId(access) !=
              finding.recordId ||
          <String>{...profileLinks, ...accessLinks}.length != 1 ||
          !linkStillPresent ||
          targetIsValid ||
          !uidCandidatesUnchanged ||
          !codeCandidatesUnchanged ||
          _validatedSupervisorCode(profile, supervisorCodeFields) !=
              supervisorCodeAtQuery ||
          _validatedSupervisorCode(access, supervisorCodeFields) !=
              accessSupervisorCodeAtQuery ||
          targetSupervisorProfileExists) {
        if (targetSupervisorProfileExists) {
          throw StateError('Repair the supervisor\'s account first.');
        }
        throw StateError(
          'The supervisor link changed or is ambiguous. Scan again.',
        );
      }

      final Map<String, dynamic> clearLink = <String, dynamic>{
        'supervisorUid': '',
        'supervisor_uid': '',
        'updatedAt': FieldValue.serverTimestamp(),
      };
      transaction.update(salesmanRef, clearLink);
      transaction.update(accessRef, clearLink);
    });
  }

  Future<List<QueryDocumentSnapshot<Map<String, dynamic>>>> _queryCandidates(
    String collection,
    List<String> fields,
    String value,
  ) async {
    if (value.isEmpty) return <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> byId =
        <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
    for (final String field in fields) {
      final QuerySnapshot<Map<String, dynamic>> result = await _firestore
          .collection(collection)
          .where(field, isEqualTo: value)
          .limit(2)
          .get();
      for (final QueryDocumentSnapshot<Map<String, dynamic>> document
          in result.docs) {
        byId[document.id] = document;
      }
    }
    return byId.values.toList(growable: false);
  }

  static void _requireSafeDocumentId(String id) {
    if (id.isEmpty ||
        id.trim().isEmpty ||
        id != id.trim() ||
        id.contains('/')) {
      throw StateError(
        'The account data is stale or invalid. Scan accounts again.',
      );
    }
  }

  Future<List<DocumentSnapshot<Map<String, dynamic>>>> _readCandidateRefs(
    Transaction transaction,
    String collection,
    List<QueryDocumentSnapshot<Map<String, dynamic>>> candidates,
  ) async {
    final List<DocumentSnapshot<Map<String, dynamic>>> result =
        <DocumentSnapshot<Map<String, dynamic>>>[];
    for (final QueryDocumentSnapshot<Map<String, dynamic>> candidate
        in candidates) {
      result.add(
        await transaction.get(
          _firestore.collection(collection).doc(candidate.id),
        ),
      );
    }
    return result;
  }

  static bool _sameData(Object? left, Object? right) {
    if (identical(left, right)) return true;
    if (left is Map && right is Map) {
      if (left.length != right.length) return false;
      for (final Object? key in left.keys) {
        if (!right.containsKey(key) || !_sameData(left[key], right[key])) {
          return false;
        }
      }
      return true;
    }
    if (left is List && right is List) {
      if (left.length != right.length) return false;
      for (int i = 0; i < left.length; i++) {
        if (!_sameData(left[i], right[i])) return false;
      }
      return true;
    }
    return left == right;
  }

  static bool _candidatesUnchanged(
    List<QueryDocumentSnapshot<Map<String, dynamic>>> candidates,
    List<DocumentSnapshot<Map<String, dynamic>>> snapshots,
  ) {
    if (candidates.length != snapshots.length) return false;
    for (int index = 0; index < candidates.length; index++) {
      final DocumentSnapshot<Map<String, dynamic>> snapshot = snapshots[index];
      if (!snapshot.exists ||
          !_sameData(snapshot.data(), candidates[index].data())) {
        return false;
      }
    }
    return true;
  }

  static bool _hasCode(Map<String, dynamic> data, String code) =>
      _codeFields.any((String field) => data[field] == code);

  static Set<String> _aliasValues(
    Map<String, dynamic> data,
    List<String> fields,
  ) => <String>{
    for (final String field in fields)
      if (data[field] is String && (data[field] as String).trim().isNotEmpty)
        (data[field] as String).trim(),
  };

  static bool _hasAnySupervisorCode(Map<String, dynamic> data) =>
      data.containsKey('supervisorId') || data.containsKey('supervisor_id');

  static String? _validatedSupervisorCode(
    Map<String, dynamic> data,
    List<String> fields,
  ) {
    String? resolved;
    for (final String field in fields) {
      if (!data.containsKey(field)) continue;
      final Object? raw = data[field];
      if (raw is! String) return null;
      final String code = raw.trim();
      if (code.isEmpty) continue;
      if (resolved != null && resolved != code) return null;
      resolved = code;
    }
    return resolved ?? '';
  }

  static String? _textAlias(Map<String, dynamic> data, List<String> fields) {
    String? value;
    for (final String field in fields) {
      if (!data.containsKey(field)) continue;
      final Object? raw = data[field];
      if (raw is! String || raw.trim().isEmpty) return null;
      final String candidate = raw.trim();
      if (value != null && value != candidate) return null;
      value = candidate;
    }
    return value;
  }

  static String _role(Map<String, dynamic> data) {
    String? role;
    for (final String field in const <String>[
      'role',
      'user_group',
      'roleLabel',
      'userRole',
      'position',
    ]) {
      if (!data.containsKey(field) || data[field] == null) continue;
      final Object? raw = data[field];
      if (raw is! String || raw.trim().isEmpty) return '';
      final String normalised = AccountRepairAnalysis.decodeCanonicalRole(raw);
      if (role != null && role != normalised) return '';
      role = normalised;
    }
    return role ?? '';
  }

  static void _requireAdmin(UserProfile actor) {
    if (!actor.isActive || !actor.isAdmin) {
      throw StateError('This check is available to active admins only.');
    }
  }
}
