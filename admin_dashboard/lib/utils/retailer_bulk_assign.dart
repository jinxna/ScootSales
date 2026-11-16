import 'package:cloud_firestore/cloud_firestore.dart';

import '../services/audit_log_service.dart';
import 'user_facing_error.dart';
import 'retailer_form_utils.dart';

const int kBulkAssignBatchSize = 450;

const List<String> kLegacyRetailerAssignmentFields = <String>[
  'assignedSalesmanUid',
  'assigned_salesman_uid',
  'assigned_salesman_id',
  'assignedSalesmanCode',
  'assigned_salesman_code',
  'assignedSalesman',
  'assigned_salesman',
  'assignedTo',
  'assignedUsers',
  'assigned_users',
  'assignedSalesmen',
  'assigned_salesmen',
  'assignedSalesmanCodes',
  'assigned_salesman_codes',
];

Map<String, dynamic> retailerAssignmentPayload(String salesmanId) =>
    <String, dynamic>{
      'assignedSalesmanId': salesmanId.trim(),
      for (final String field in kLegacyRetailerAssignmentFields)
        field: FieldValue.delete(),
    };

class BulkAssignPlan {
  const BulkAssignPlan({
    required this.ids,
    required this.skippedRetired,
    required this.unchanged,
    required this.changingOwner,
  });

  final List<String> ids;

  final List<String> skippedRetired;

  final int unchanged;

  final int changingOwner;
}

BulkAssignPlan planBulkAssignment({
  required Iterable<Map<String, dynamic>> retailers,
  required RetailerSalesmanOption? target,
  required bool Function(Map<String, dynamic>) isRetired,
}) {
  final List<String> ids = <String>[];
  final List<String> skipped = <String>[];
  int unchanged = 0;
  int changingOwner = 0;
  for (final Map<String, dynamic> retailer in retailers) {
    final String id = '${retailer['docId'] ?? retailer['retailerId'] ?? ''}'
        .trim();
    if (id.isEmpty) continue;
    final String name = '${retailer['retailerName'] ?? retailer['name'] ?? id}'
        .trim();
    if (isRetired(retailer)) {
      skipped.add(name);
      continue;
    }
    final String current = '${retailer['assignedSalesmanId'] ?? ''}'.trim();
    final bool hasLegacy = kLegacyRetailerAssignmentFields.any(
      (String field) => _hasAssignedValue(retailer[field]),
    );
    if (target == null) {
      if (current.isEmpty && !hasLegacy) {
        unchanged++;
        continue;
      }
      ids.add(id);
      changingOwner++;
      continue;
    }
    if (current.isNotEmpty && target.matches(current) && !hasLegacy) {
      unchanged++;
      continue;
    }
    ids.add(id);
    if (current.isNotEmpty || hasLegacy) changingOwner++;
  }
  return BulkAssignPlan(
    ids: ids,
    skippedRetired: skipped,
    unchanged: unchanged,
    changingOwner: changingOwner,
  );
}

bool _hasAssignedValue(Object? value) {
  if (value is List) {
    return value.any((Object? item) => '${item ?? ''}'.trim().isNotEmpty);
  }
  return '${value ?? ''}'.trim().isNotEmpty;
}

abstract class RetailerAssignmentWriter {
  Future<Map<String, Object>> setAssignment(
    List<String> ids,
    String salesmanId, {
    void Function(int done)? onProgress,
  });
}

class FirestoreRetailerAssignmentWriter implements RetailerAssignmentWriter {
  FirestoreRetailerAssignmentWriter({
    FirebaseFirestore? firestore,
    Future<void> Function(List<String> ids, String salesmanId)? commitChunk,
    Future<void> Function(String id, String salesmanId)? updateDocument,
    Future<void> Function(int succeeded, String salesmanId)? recordSuccess,
  }) : _firestore = firestore,
       _commitChunkOverride = commitChunk,
       _updateDocumentOverride = updateDocument,
       _recordSuccessOverride = recordSuccess;

  final FirebaseFirestore? _firestore;
  final Future<void> Function(List<String> ids, String salesmanId)?
  _commitChunkOverride;
  final Future<void> Function(String id, String salesmanId)?
  _updateDocumentOverride;
  final Future<void> Function(int succeeded, String salesmanId)?
  _recordSuccessOverride;

  Future<void> _commitChunk(List<String> ids, String salesmanId) async {
    final Future<void> Function(List<String>, String)? override =
        _commitChunkOverride;
    if (override != null) {
      await override(ids, salesmanId);
      return;
    }
    final FirebaseFirestore firestore =
        _firestore ?? FirebaseFirestore.instance;
    final WriteBatch batch = firestore.batch();
    for (final String id in ids) {
      batch.update(firestore.collection('retailers').doc(id), <String, dynamic>{
        ...retailerAssignmentPayload(salesmanId),
        'updatedAt': FieldValue.serverTimestamp(),
      });
    }
    await batch.commit();
  }

  Future<void> _updateDocument(String id, String salesmanId) async {
    final Future<void> Function(String, String)? override =
        _updateDocumentOverride;
    if (override != null) {
      await override(id, salesmanId);
      return;
    }
    final FirebaseFirestore firestore =
        _firestore ?? FirebaseFirestore.instance;
    await firestore.collection('retailers').doc(id).update(<String, dynamic>{
      ...retailerAssignmentPayload(salesmanId),
      'updatedAt': FieldValue.serverTimestamp(),
    });
  }

  @override
  Future<Map<String, Object>> setAssignment(
    List<String> ids,
    String salesmanId, {
    void Function(int done)? onProgress,
  }) async {
    final Map<String, Object> failed = <String, Object>{};
    int done = 0;
    for (int start = 0; start < ids.length; start += kBulkAssignBatchSize) {
      final List<String> chunk = ids.sublist(
        start,
        start + kBulkAssignBatchSize > ids.length
            ? ids.length
            : start + kBulkAssignBatchSize,
      );
      try {
        await _commitChunk(chunk, salesmanId);
      } catch (error) {
        if (!isDefiniteRetailerAssignmentFailure(error)) {
          final StateError uncertain = _uncertainResult();
          for (final String id in chunk) {
            failed[id] = uncertain;
          }
        } else {
          for (final String id in chunk) {
            try {
              await _updateDocument(id, salesmanId);
            } catch (rowError) {
              failed[id] = isDefiniteRetailerAssignmentFailure(rowError)
                  ? rowError
                  : _uncertainResult();
            }
          }
        }
      }
      done += chunk.length;
      onProgress?.call(done);
    }
    final int succeeded = ids.length - failed.length;
    if (succeeded > 0) {
      final Future<void> Function(int, String)? recordSuccess =
          _recordSuccessOverride;
      if (recordSuccess != null) {
        await recordSuccess(succeeded, salesmanId);
      } else {
        await AuditLogService.instance.record(
          action: 'updated',
          entityType: 'retailers',
          entityId: 'bulk_assignment',
          summary: salesmanId.isEmpty
              ? 'Unassigned $succeeded retailer(s)'
              : 'Assigned $succeeded retailer(s) to $salesmanId',
          metadata: <String, dynamic>{
            'assignedSalesmanId': salesmanId,
            'retailerCount': succeeded,
          },
        );
      }
    }
    return failed;
  }
}

bool isDefiniteRetailerAssignmentFailure(Object error) =>
    error is FirebaseException &&
    const <String>{
      'not-found',
      'permission-denied',
      'failed-precondition',
      'invalid-argument',
    }.contains(error.code);

StateError _uncertainResult() => StateError(
  'This batch result could not be confirmed. Refresh and retry the selected retailers.',
);

String retailerAssignmentFailureReason(String name, Object error) {
  final String retailer = name.trim().isEmpty ? 'This retailer' : name.trim();
  if (error is FirebaseException) {
    switch (error.code) {
      case 'not-found':
        return '$retailer no longer exists.';
      case 'permission-denied':
        return 'You are not allowed to change $retailer.';
      case 'failed-precondition':
        return 'The database rejected the change to $retailer. Refresh and try again.';
      case 'invalid-argument':
        return 'The change for $retailer contains invalid data. Review it and try again.';
    }
  }
  return userFacingError(error, action: 'update $retailer');
}
