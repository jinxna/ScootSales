import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../utils/app_logger.dart';

class UserAccessIndex {
  const UserAccessIndex._();

  static Map<String, dynamic> build({
    required String uid,
    required String userDocId,
    required String email,
    required String roleRaw,
    String branchId = '',
    String supervisorId = '',
    String supervisorUid = '',
    List<String>? assignedSalesmanCodes,
  }) {
    final String role = UserProfile.normalizeRole(roleRaw, email: email);
    final List<String> codes = assignedSalesmanCodes == null
        ? const <String>[]
        : List<String>.unmodifiable(assignedSalesmanCodes);

    return <String, dynamic>{
      'accessVersion': 2,
      'uid': uid,
      'userDocId': userDocId,
      'email': email,
      'branchId': branchId,
      'branch_id': branchId,
      'supervisorId': supervisorId,
      'supervisor_id': supervisorId,
      'supervisorUid': role == UserProfile.roleSalesman ? supervisorUid : '',
      'assignedSalesmanCodes': role == UserProfile.roleSupervisor
          ? codes
          : FieldValue.delete(),
      'updatedAt': FieldValue.serverTimestamp(),
    };
  }

  static List<String> parseAssignedSalesmanCodes(Object? raw) {
    if (raw == null) return const <String>[];
    if (raw is String) {
      return raw
          .split(RegExp(r'[,\s]+'))
          .map((String value) => value.trim())
          .where((String value) => value.isNotEmpty)
          .toList(growable: false);
    }
    Iterable<Object?>? entries;
    if (raw is Iterable) {
      entries = raw;
    } else if (raw is Map) {
      entries = raw.keys;
    } else {
      AppLogger.error(
        'assigned_salesman_codes_unexpected_shape',
        fields: <String, Object?>{'runtimeType': raw.runtimeType.toString()},
      );
      return const <String>[];
    }
    return entries
        .map((Object? value) => (value ?? '').toString().trim())
        .where((String value) => value.isNotEmpty)
        .toList(growable: false);
  }
}
