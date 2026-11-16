import '../models/user_profile.dart';

enum UserDirectoryState { loading, error, ready }

class UserDirectoryView {
  const UserDirectoryView({
    required this.state,
    this.rows = const <Map<String, dynamic>>[],
    this.ownAccountRow,
    this.scopedRowCount = 0,
  });

  static const UserDirectoryView loading = UserDirectoryView(
    state: UserDirectoryState.loading,
  );

  static const UserDirectoryView error = UserDirectoryView(
    state: UserDirectoryState.error,
  );

  final UserDirectoryState state;

  final List<Map<String, dynamic>> rows;

  final Map<String, dynamic>? ownAccountRow;

  final int scopedRowCount;

  bool get showsOwnAccountOnly =>
      state == UserDirectoryState.ready &&
      scopedRowCount == 0 &&
      ownAccountRow != null;

  static const String developerAccountEmail = String.fromEnvironment(
    'HIDDEN_DEVELOPER_EMAIL',
  );

  factory UserDirectoryView.from({
    required UserProfile currentUser,
    required bool hasData,
    required bool hasError,
    required List<Map<String, dynamic>> rawRows,
  }) {
    if (hasError) return error;
    if (!hasData) return loading;
    final List<Map<String, dynamic>> scoped = scopeForActor(
      rawRows,
      currentUser,
    );
    if (scoped.isEmpty) {
      return UserDirectoryView(
        state: UserDirectoryState.ready,
        rows: const <Map<String, dynamic>>[],
        ownAccountRow: ownAccountRowFor(currentUser),
        scopedRowCount: 0,
      );
    }
    return UserDirectoryView(
      state: UserDirectoryState.ready,
      rows: sortRows(scoped),
      scopedRowCount: scoped.length,
    );
  }

  static List<Map<String, dynamic>> scopeForActor(
    List<Map<String, dynamic>> rows,
    UserProfile currentUser, {
    String hiddenEmail = developerAccountEmail,
  }) {
    final List<Map<String, dynamic>> visible = currentUser.isDeveloper
        ? List<Map<String, dynamic>>.from(rows)
        : rows.where((Map<String, dynamic> row) {
            final String role = readText(
              row['role'] ?? row['user_group'],
            ).toLowerCase();
            final String email = readText(row['email']).toLowerCase();
            return role != UserProfile.roleDeveloper &&
                (hiddenEmail.isEmpty ||
                    email != hiddenEmail.trim().toLowerCase());
          }).toList();

    if (currentUser.isAdmin) {
      return visible;
    }
    if (currentUser.isBranchManager && currentUser.branchId.isNotEmpty) {
      return visible.where((Map<String, dynamic> row) {
        final String branch = readText(row['branchId'] ?? row['branch_id']);
        final String code = readText(row['employeeCode'] ?? row['userId']);
        final String docId = readText(row['docId']);
        final String uid = readText(row['uid']);
        final String email = readText(row['email']).toLowerCase();
        final bool isOwnRow =
            (code.isNotEmpty && code == currentUser.employeeCode) ||
            (docId.isNotEmpty && docId == currentUser.docId) ||
            (uid.isNotEmpty && uid == currentUser.uid) ||
            (email.isNotEmpty && email == currentUser.email.toLowerCase());
        if (isOwnRow) return true;
        final String rawRole = readText(
          readText(row['role']).isNotEmpty ? row['role'] : row['user_group'],
        );
        if (rawRole.isEmpty) return false;
        final String role = UserProfile.normalizeRole(rawRole);
        return branch == currentUser.branchId &&
            (role == UserProfile.roleSalesman ||
                role == UserProfile.roleSupervisor);
      }).toList();
    }
    if (currentUser.isSupervisor) {
      return visible.where((Map<String, dynamic> row) {
        final String rawRole = readText(row['role'] ?? row['user_group']);
        if (rawRole.isEmpty) return false;
        final String role = UserProfile.normalizeRole(rawRole);
        final String code = readText(row['employeeCode'] ?? row['userId']);
        final String supervisorId = readText(
          row['supervisorId'] ?? row['supervisor_id'],
        );
        return role == UserProfile.roleSalesman &&
            (currentUser.assignedSalesmanCodes.contains(code) ||
                supervisorId == currentUser.employeeCode);
      }).toList();
    }
    return visible.where((Map<String, dynamic> row) {
      final String code = readText(row['employeeCode'] ?? row['userId']);
      return code == currentUser.employeeCode;
    }).toList();
  }

  static List<Map<String, dynamic>> sortRows(List<Map<String, dynamic>> rows) {
    final List<Map<String, dynamic>> sorted = List<Map<String, dynamic>>.from(
      rows,
    );
    sorted.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final String left = displaySortKey(a);
      final String right = displaySortKey(b);
      return left.compareTo(right);
    });
    return sorted;
  }

  static String displaySortKey(Map<String, dynamic> row) {
    final List<String> candidates = <String>[
      readText(row['name']),
      readText(row['email']),
      readText(row['employeeCode'] ?? row['userId']),
      readText(row['docId']),
    ];
    for (final String value in candidates) {
      if (value.isNotEmpty) return value.toLowerCase();
    }
    return '';
  }

  static Map<String, dynamic> ownAccountRowFor(UserProfile currentUser) {
    return <String, dynamic>{
      'docId': currentUser.docId.isNotEmpty
          ? currentUser.docId
          : 'current_session_user',
      'uid': currentUser.uid,
      'name': currentUser.name.isNotEmpty
          ? currentUser.name
          : 'Current logged-in user',
      'email': currentUser.email,
      'role': currentUser.role,
      'employeeCode': currentUser.employeeCode,
      'branchId': currentUser.branchId,
      'supervisorId': currentUser.supervisorId,
      'contactNumber': currentUser.contactNumber,
      'status': currentUser.status.isNotEmpty
          ? currentUser.status
          : UserProfile.statusActive,
    };
  }

  static String readText(Object? value, {String fallback = ''}) {
    final String text = '$value'.trim();
    if (text.isEmpty || text == 'null') return fallback;
    return text;
  }
}
