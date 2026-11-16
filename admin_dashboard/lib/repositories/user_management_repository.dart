import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../security/user_access_index.dart';
import '../security/user_management_rules.dart';
import '../utils/user_management_utils.dart';

class UserManagementFormProblem implements Exception {
  const UserManagementFormProblem(this.message);

  final String message;

  @override
  String toString() => message;
}

class UserManagementSupervisorPlan {
  const UserManagementSupervisorPlan({
    this.removeFrom,
    this.removeCode = '',
    this.addTo,
    this.addCode = '',
    this.orphans = const <QueryDocumentSnapshot<Map<String, dynamic>>>[],
  });

  final QueryDocumentSnapshot<Map<String, dynamic>>? removeFrom;
  final String removeCode;
  final QueryDocumentSnapshot<Map<String, dynamic>>? addTo;
  final String addCode;
  final List<QueryDocumentSnapshot<Map<String, dynamic>>> orphans;
}

class UserManagementRepository {
  UserManagementRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  WriteBatch createBatch() => _firestore.batch();

  Future<void> commit(WriteBatch batch) => batch.commit();

  void queueUserProfile(
    WriteBatch batch,
    String docId,
    Map<String, dynamic> payload, {
    bool merge = true,
  }) {
    batch.set(
      _firestore.collection('users').doc(docId),
      payload,
      SetOptions(merge: merge),
    );
  }

  void queueUserProfileUpdate(
    WriteBatch batch,
    String docId,
    Map<String, dynamic> payload,
  ) {
    batch.update(_firestore.collection('users').doc(docId), payload);
  }

  Future<UserManagementSupervisorPlan> planSupervisorChanges({
    required String oldRole,
    required String oldEmployeeCode,
    required String oldSupervisorId,
    required String employeeCode,
    required String newRole,
    required String newSupervisorId,
    required String newBranchId,
    required String oldBranchId,
  }) async {
    final CollectionReference<Map<String, dynamic>> users = _firestore
        .collection('users');
    final String oldCode = oldEmployeeCode.trim();
    final String oldSupervisor = oldSupervisorId.trim();

    QueryDocumentSnapshot<Map<String, dynamic>>? removeFrom;
    String removeCode = '';
    if (oldRole == UserProfile.roleSalesman &&
        oldSupervisor.isNotEmpty &&
        oldCode.isNotEmpty &&
        (oldSupervisor != newSupervisorId ||
            newRole != UserProfile.roleSalesman ||
            oldCode != employeeCode)) {
      final QuerySnapshot<Map<String, dynamic>> found = await users
          .where('employeeCode', isEqualTo: oldSupervisor)
          .limit(1)
          .get();
      if (found.docs.isNotEmpty) {
        removeFrom = found.docs.first;
        removeCode = oldCode;
      }
    }

    QueryDocumentSnapshot<Map<String, dynamic>>? addTo;
    String addCode = '';
    if (newRole == UserProfile.roleSalesman && newSupervisorId.isNotEmpty) {
      final QuerySnapshot<Map<String, dynamic>> found = await users
          .where('employeeCode', isEqualTo: newSupervisorId)
          .limit(1)
          .get();
      if (found.docs.isNotEmpty) {
        addTo = found.docs.first;
        addCode = employeeCode;
        final Map<String, dynamic> data = addTo.data();
        final String? branchError = UserManagementRules.supervisorBranchError(
          supervisorBranchId: UserManagementUtils.firstNonEmptyField(
            data,
            const <String>['branchId', 'branch_id'],
          ),
          branchId: newBranchId,
        );
        if (branchError != null) throw UserManagementFormProblem(branchError);
        final Set<String> codes = <String>{
          ...UserAccessIndex.parseAssignedSalesmanCodes(
            data['assignedSalesmanCodes'],
          ),
        };
        final String supervisorUid = ((data['uid'] ?? '') as Object)
            .toString()
            .trim();
        if (supervisorUid.isNotEmpty) {
          try {
            final DocumentSnapshot<Map<String, dynamic>> access =
                await _firestore
                    .collection('user_access')
                    .doc(supervisorUid)
                    .get();
            codes.addAll(
              UserAccessIndex.parseAssignedSalesmanCodes(
                access.data()?['assignedSalesmanCodes'],
              ),
            );
          } catch (_) {}
        }
        final bool leavingSameSupervisor =
            removeFrom != null && removeFrom.id == addTo.id;
        final String? capError = UserManagementRules.supervisorCapError(
          supervisorName: ((data['name'] ?? newSupervisorId) as Object)
              .toString(),
          currentCodes: codes,
          salesmanCode: employeeCode,
          removingCode: leavingSameSupervisor ? removeCode : '',
        );
        if (capError != null) throw UserManagementFormProblem(capError);
      }
    }

    List<QueryDocumentSnapshot<Map<String, dynamic>>> orphans =
        const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
    if (UserManagementRules.supervisorTeamMustMoveFirst(
      oldRole: oldRole,
      oldEmployeeCode: oldCode,
      newRole: newRole,
      oldBranchId: oldBranchId,
      newBranchId: newBranchId,
    )) {
      final QuerySnapshot<Map<String, dynamic>> linked = await users
          .where('supervisorId', isEqualTo: oldCode)
          .limit(50)
          .get();
      orphans = linked.docs;
    }

    return UserManagementSupervisorPlan(
      removeFrom: removeFrom,
      removeCode: removeCode,
      addTo: addTo,
      addCode: addCode,
      orphans: orphans,
    );
  }

  void queueSupervisorPlan(
    WriteBatch batch,
    UserManagementSupervisorPlan plan,
  ) {
    final QueryDocumentSnapshot<Map<String, dynamic>>? removeFrom =
        plan.removeFrom;
    if (removeFrom != null) {
      _queueSupervisorAccessAssignment(
        batch,
        removeFrom,
        salesmanCode: plan.removeCode,
        add: false,
      );
    }
    final QueryDocumentSnapshot<Map<String, dynamic>>? addTo = plan.addTo;
    if (addTo != null) {
      _queueSupervisorAccessAssignment(
        batch,
        addTo,
        salesmanCode: plan.addCode,
        add: true,
      );
    }
    for (final QueryDocumentSnapshot<Map<String, dynamic>> salesman
        in plan.orphans) {
      queueUserProfile(batch, salesman.id, <String, dynamic>{
        'supervisorId': '',
        'supervisor_id': '',
        'supervisorUid': '',
        'supervisor_uid': '',
        'updatedAt': FieldValue.serverTimestamp(),
      });
      final String salesmanUid = ((salesman.data()['uid'] ?? '') as Object)
          .toString()
          .trim();
      if (salesmanUid.isNotEmpty) {
        batch.set(
          _firestore.collection('user_access').doc(salesmanUid),
          <String, dynamic>{
            'supervisorId': '',
            'supervisor_id': '',
            'supervisorUid': '',
            'supervisor_uid': '',
            'updatedAt': FieldValue.serverTimestamp(),
          },
          SetOptions(merge: true),
        );
      }
    }
  }

  Future<void> upsertUserAccessIndex({
    required WriteBatch batch,
    required String? uid,
    required String actorUid,
    required String userDocId,
    required String email,
    required String role,
    required String branchId,
    required String supervisorId,
  }) async {
    final String safeUid = (uid ?? '').trim();
    if (safeUid.isEmpty) return;
    final DocumentSnapshot<Map<String, dynamic>> existing = await _firestore
        .collection('user_access')
        .doc(safeUid)
        .get();
    if (!existing.exists || existing.data()?['accessVersion'] != 2) return;
    if (safeUid == actorUid.trim()) {
      batch.set(
        _firestore.collection('user_access').doc(safeUid),
        <String, dynamic>{
          'email': email,
          'updatedAt': FieldValue.serverTimestamp(),
        },
        SetOptions(merge: true),
      );
      return;
    }

    final String normalizedRole = UserProfile.normalizeRole(role, email: email);
    final String supervisorUid = normalizedRole == UserProfile.roleSalesman
        ? await resolveSupervisorUid(supervisorId)
        : '';

    List<String> assignedSalesmanCodes = const <String>[];
    if (normalizedRole == UserProfile.roleSupervisor && userDocId.isNotEmpty) {
      final DocumentSnapshot<Map<String, dynamic>> profile = await _firestore
          .collection('users')
          .doc(userDocId)
          .get();
      assignedSalesmanCodes = UserAccessIndex.parseAssignedSalesmanCodes(
        profile.data()?['assignedSalesmanCodes'],
      );
    }

    final Map<String, dynamic> payload = UserAccessIndex.build(
      uid: safeUid,
      userDocId: userDocId,
      email: email,
      roleRaw: normalizedRole,
      branchId: branchId,
      supervisorId: supervisorId,
      supervisorUid: supervisorUid,
      assignedSalesmanCodes: assignedSalesmanCodes,
    );
    batch.set(
      _firestore.collection('user_access').doc(safeUid),
      payload,
      SetOptions(merge: true),
    );
  }

  Future<String> resolveSupervisorUid(String employeeCode) async {
    final String code = employeeCode.trim();
    if (code.isEmpty) return '';
    final QuerySnapshot<Map<String, dynamic>> matches = await _firestore
        .collection('users')
        .where('employeeCode', isEqualTo: code)
        .limit(2)
        .get();
    if (matches.docs.length != 1) return '';
    final Map<String, dynamic> profile = matches.docs.single.data();
    final String role = UserProfile.normalizeRole(
      profile['role'] ?? profile['user_group'],
    );
    final Object? rawUid = profile['uid'];
    if (role != UserProfile.roleSupervisor || rawUid is! String) return '';
    return rawUid.trim();
  }

  Future<int> countLinkedSalesmen(String employeeCode) async {
    final AggregateQuerySnapshot count = await _firestore
        .collection('users')
        .where('supervisorId', isEqualTo: employeeCode)
        .count()
        .get();
    return count.count ?? 0;
  }

  Stream<QuerySnapshot<Map<String, dynamic>>> watchDeletionRequests() =>
      _firestore
          .collection('privacy_deletion_requests')
          .where(
            'status',
            whereIn: <String>['submitted', 'reviewing', 'completed'],
          )
          .snapshots();

  Future<void> updateDeletionRequestStatus(String uid, String status) =>
      _firestore.collection('privacy_deletion_requests').doc(uid).update(
        <String, Object>{
          'status': status,
          'updatedAt': FieldValue.serverTimestamp(),
        },
      );

  void _queueSupervisorAccessAssignment(
    WriteBatch batch,
    QueryDocumentSnapshot<Map<String, dynamic>> supervisorDoc, {
    required String salesmanCode,
    required bool add,
  }) {
    if (salesmanCode.trim().isEmpty) return;
    batch.set(
      _firestore.collection('users').doc(supervisorDoc.id),
      <String, dynamic>{
        'assignedSalesmanCodes': add
            ? FieldValue.arrayUnion(<String>[salesmanCode])
            : FieldValue.arrayRemove(<String>[salesmanCode]),
      },
      SetOptions(merge: true),
    );
    final String uid = ((supervisorDoc.data()['uid'] ?? '') as Object)
        .toString()
        .trim();
    if (uid.isEmpty) return;
    batch.set(_firestore.collection('user_access').doc(uid), <String, dynamic>{
      'assignedSalesmanCodes': add
          ? FieldValue.arrayUnion(<String>[salesmanCode])
          : FieldValue.arrayRemove(<String>[salesmanCode]),
      'updatedAt': FieldValue.serverTimestamp(),
    }, SetOptions(merge: true));
  }
}
