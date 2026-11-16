import 'package:cloud_firestore/cloud_firestore.dart';

class SpecialRequestType {
  const SpecialRequestType(this.code, this.label);

  final String code;
  final String label;

  static const List<SpecialRequestType> all = <SpecialRequestType>[
    SpecialRequestType('non_catalogue_item', 'Non-catalogue item'),
    SpecialRequestType('urgent_delivery', 'Urgent delivery'),
    SpecialRequestType('pricing', 'Promotional pricing'),
    SpecialRequestType('other', 'Other'),
  ];

  static SpecialRequestType? byCode(String? code) {
    for (final SpecialRequestType type in all) {
      if (type.code == code) return type;
    }
    return null;
  }
}

class SpecialRequestPayload {
  SpecialRequestPayload._();

  static const int maxDescriptionLength = 1000;

  static String docId(String orderId) => orderId;

  static Map<String, dynamic>? build({
    required String orderId,
    required String typeCode,
    required String description,
    required String retailerName,
    required String salesmanCode,
    required String branchId,
    required String salesmanUid,
    String retailerId = '',
    String selectedProductId = '',
  }) {
    final SpecialRequestType? type = SpecialRequestType.byCode(typeCode);
    final String text = description.trim();
    if (type == null ||
        text.isEmpty ||
        text.length > maxDescriptionLength ||
        orderId.isEmpty ||
        retailerName.isEmpty ||
        salesmanCode.isEmpty ||
        branchId.isEmpty ||
        salesmanUid.isEmpty) {
      return null;
    }
    if (typeCode == 'non_catalogue_item' &&
        (retailerId.isEmpty || text.length > 200)) {
      return null;
    }
    return <String, dynamic>{
      'orderId': orderId,
      'requestType': type.code,
      'retailerName': retailerName.length > 200
          ? retailerName.substring(0, 200)
          : retailerName,
      'requestedItem': typeCode == 'non_catalogue_item' ? text : type.label,
      if (typeCode == 'non_catalogue_item') 'retailerId': retailerId,
      if (typeCode == 'non_catalogue_item' && selectedProductId.isNotEmpty)
        'selectedProductId': selectedProductId,
      'reason': text,
      'salesmanCode': salesmanCode,
      'branchId': branchId,
      'createdByUid': salesmanUid,
      'createdByRole': 'salesman',
      'status': 'pending_supervisor',
      'approvalStep': 'Supervisor',
      'lastActorUid': salesmanUid,
      'lastActorRole': 'salesman',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
      'lastActionAt': FieldValue.serverTimestamp(),
    };
  }
}
