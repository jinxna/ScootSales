import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;

Future<void> markVisitSubmitted(
  FirebaseFirestore firestore, {
  required String visitId,
  required String orderId,
}) => firestore.collection('visits').doc(visitId).update({
  'progress': 3,
  'status': 'submitted',
  'step3At': FieldValue.serverTimestamp(),
  'submittedOrderId': orderId,
  'draftStage': FieldValue.delete(),
  'cartDraftItems': FieldValue.delete(),
  'signatureDraft': FieldValue.delete(),
  'pendingSignatures': FieldValue.delete(),
  'updatedAt': FieldValue.serverTimestamp(),
});

Future<int> repairSubmittedVisits(
  FirebaseFirestore firestore, {
  required String uid,
  required Iterable<QueryDocumentSnapshot<Map<String, dynamic>>> visits,
}) async {
  final Map<String, Object?> linkedOrderByVisit = <String, Object?>{};
  for (final QueryDocumentSnapshot<Map<String, dynamic>> doc in visits) {
    final Map<String, dynamic> data = doc.data();
    if (data['status'] != 'submitted' &&
        (data['status'] == 'counting' ||
            data['status'] == 'pending_signature' ||
            data['draftStage'] != null)) {
      linkedOrderByVisit[doc.id] = data['submittedOrderId'];
    }
  }
  final List<String> unfinished = linkedOrderByVisit.keys.toList(
    growable: false,
  );
  int repaired = 0;
  for (int start = 0; start < unfinished.length; start += 30) {
    final List<String> ids = unfinished.sublist(
      start,
      start + 30 > unfinished.length ? unfinished.length : start + 30,
    );
    try {
      final QuerySnapshot<Map<String, dynamic>> orders = await firestore
          .collection('orders')
          .where('salesmanUid', isEqualTo: uid)
          .where('visitId', whereIn: ids)
          .get(const GetOptions(source: Source.server))
          .timeout(const Duration(seconds: 8));
      final Map<String, QueryDocumentSnapshot<Map<String, dynamic>>> newest =
          <String, QueryDocumentSnapshot<Map<String, dynamic>>>{};
      for (final QueryDocumentSnapshot<Map<String, dynamic>> order
          in orders.docs) {
        final Object? visitId = order.data()['visitId'];
        if (visitId is! String || !ids.contains(visitId)) continue;
        final QueryDocumentSnapshot<Map<String, dynamic>>? known =
            newest[visitId];
        if (known == null ||
            _createdAt(order) > _createdAt(known) ||
            (_createdAt(order) == _createdAt(known) &&
                linkedOrderByVisit[visitId] == order.id)) {
          newest[visitId] = order;
        }
      }
      for (final MapEntry<String, QueryDocumentSnapshot<Map<String, dynamic>>>
          entry
          in newest.entries) {
        if (linkedOrderByVisit[entry.key] == entry.value.id) continue;
        await markVisitSubmitted(
          firestore,
          visitId: entry.key,
          orderId: entry.value.id,
        ).timeout(const Duration(seconds: 8));
        repaired++;
      }
    } catch (error) {
      debugPrint('Visits with a sent order could not be repaired: $error');
      return repaired;
    }
  }
  return repaired;
}

int _createdAt(QueryDocumentSnapshot<Map<String, dynamic>> order) {
  final Object? at = order.data()['createdAt'];
  return at is Timestamp ? at.millisecondsSinceEpoch : 0;
}
