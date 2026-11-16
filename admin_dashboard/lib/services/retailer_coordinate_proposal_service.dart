import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import '../utils/firestore_query_utils.dart';
import '../utils/retailer_coordinate_edit.dart';

class RetailerCoordinateProposalService {
  RetailerCoordinateProposalService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  Stream<List<Map<String, dynamic>>> watchProposals(UserProfile user) {
    Query<Map<String, dynamic>> query = _firestore.collection(
      'retailer_coordinate_proposals',
    );
    List<Query<Map<String, dynamic>>> scoped;
    if (user.isAdmin) {
      scoped = <Query<Map<String, dynamic>>>[
        query.where('status', isEqualTo: 'pending').limit(100),
      ];
    } else if (user.isSupervisor) {
      scoped = whereInQueryChunks(
        query,
        'salesmanCode',
        user.assignedSalesmanCodes
            .map((String code) => code.trim())
            .where((String code) => code.isNotEmpty),
      ).map((Query<Map<String, dynamic>> row) => row.limit(300)).toList();
    } else if (user.isBranchManager && user.branchId.trim().isNotEmpty) {
      scoped = <Query<Map<String, dynamic>>>[
        query.where('branchId', isEqualTo: user.branchId.trim()).limit(300),
      ];
    } else if (user.isSalesman && (user.uid ?? '').trim().isNotEmpty) {
      scoped = <Query<Map<String, dynamic>>>[
        query.where('salesmanUid', isEqualTo: user.uid!.trim()).limit(100),
      ];
    } else {
      scoped = const <Query<Map<String, dynamic>>>[];
    }
    return combineFirestoreQuerySnapshots(scoped).map((
      List<QueryDocumentSnapshot<Map<String, dynamic>>> documents,
    ) {
      final List<Map<String, dynamic>> rows =
          documents
              .map(
                (QueryDocumentSnapshot<Map<String, dynamic>> document) =>
                    <String, dynamic>{'docId': document.id, ...document.data()},
              )
              .where((Map<String, dynamic> row) => row['status'] == 'pending')
              .toList(growable: false)
            ..sort((Map<String, dynamic> left, Map<String, dynamic> right) {
              final DateTime? a = _date(left['createdAt']);
              final DateTime? b = _date(right['createdAt']);
              if (a == null && b == null) return 0;
              if (a == null) return 1;
              if (b == null) return -1;
              return b.compareTo(a);
            });
      return rows;
    });
  }

  Future<void> review({
    required UserProfile reviewer,
    required String proposalId,
    required bool approve,
  }) async {
    final String uid = (reviewer.uid ?? '').trim();
    if (!reviewer.isAdmin || !reviewer.isActive || uid.isEmpty) {
      throw StateError(
        'Only an active administrator can review pin proposals.',
      );
    }
    final DocumentReference<Map<String, dynamic>> proposalRef = _firestore
        .collection('retailer_coordinate_proposals')
        .doc(proposalId.trim());
    if (proposalId.trim().isEmpty) {
      throw ArgumentError.value(proposalId, 'proposalId');
    }

    await _firestore.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> proposalSnapshot =
          await transaction.get(proposalRef);
      final Map<String, dynamic>? proposal = proposalSnapshot.data();
      if (!proposalSnapshot.exists ||
          proposal == null ||
          proposal['status'] != 'pending') {
        throw StateError('This pin proposal is no longer pending.');
      }
      final String retailerId = (proposal['retailerId'] ?? '')
          .toString()
          .trim();
      final double? latitude = (proposal['candidateLatitude'] as num?)
          ?.toDouble();
      final double? longitude = (proposal['candidateLongitude'] as num?)
          ?.toDouble();
      if (retailerId.isEmpty ||
          latitude == null ||
          longitude == null ||
          !latitude.isFinite ||
          !longitude.isFinite ||
          latitude < -90 ||
          latitude > 90 ||
          longitude < -180 ||
          longitude > 180 ||
          (latitude == 0 && longitude == 0)) {
        throw StateError('This proposal has invalid coordinate data.');
      }

      if (approve) {
        final DocumentReference<Map<String, dynamic>> retailerRef = _firestore
            .collection('retailers')
            .doc(retailerId);
        final DocumentSnapshot<Map<String, dynamic>> retailerSnapshot =
            await transaction.get(retailerRef);
        final Map<String, dynamic>? original = retailerSnapshot.data();
        if (!retailerSnapshot.exists || original == null) {
          throw StateError('The canonical retailer record is unavailable.');
        }
        transaction.set(
          retailerRef,
          verifiedCoordinatePayload(
            original: original,
            latitudeText: latitude.toString(),
            longitudeText: longitude.toString(),
            reviewerUid: uid,
            reviewedAt: FieldValue.serverTimestamp(),
          ),
          SetOptions(merge: true),
        );
      }
      transaction.update(proposalRef, <String, dynamic>{
        'status': approve ? 'approved' : 'rejected',
        'reviewedByUid': uid,
        'reviewedAt': FieldValue.serverTimestamp(),
      });
    });
  }
}

DateTime? _date(Object? value) {
  if (value is Timestamp) return value.toDate();
  if (value is DateTime) return value;
  return DateTime.tryParse(value?.toString() ?? '');
}
