import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:uuid/uuid.dart';

import '../services/audit_log_service.dart';
import '../services/platform_api_client.dart';
import '../utils/catalogue_import.dart' show cleanImportId;
import '../utils/catalogue_product_availability.dart';
import '../utils/price_stamp.dart';

class SpecialRequestApproval {
  const SpecialRequestApproval({required this.productId, this.hiddenReason});

  final String productId;
  final String? hiddenReason;
}

class CatalogueProductRepository {
  CatalogueProductRepository({
    FirebaseFirestore? firestore,
    PlatformApiClient? api,
  }) : _firestore = firestore ?? FirebaseFirestore.instance,
       _api = api ?? PlatformApiClient();

  final FirebaseFirestore _firestore;
  final PlatformApiClient _api;

  static const int maxAvailabilityChanges = 400;

  Future<SpecialRequestApproval> approveSpecialRequest({
    required String requestId,
    required String actorUid,
    required String actorRole,
    String? existingProductId,
  }) async {
    if (!<String>{'admin', 'developer'}.contains(actorRole) ||
        actorUid.isEmpty) {
      throw StateError('Only an admin can add a requested catalogue item.');
    }
    final requestRef = _firestore.collection('special_requests').doc(requestId);
    final fallbackProductId = _firestore.collection('products').doc().id;
    final (String, bool)
    approved = await _firestore.runTransaction<(String, bool)>((
      transaction,
    ) async {
      final requestSnapshot = await transaction.get(requestRef);
      final request = requestSnapshot.data();
      if (request == null ||
          request['requestType'] != 'non_catalogue_item' ||
          request['status'] == 'rejected') {
        throw StateError('This request cannot be added to the catalogue.');
      }
      if (!<String>{
        'pending_supervisor',
        'pending_branch_manager',
        'pending_admin',
        'approved',
      }.contains(request['status'])) {
        throw StateError('This request is not awaiting a catalogue decision.');
      }
      final orderId = request['orderId']?.toString() ?? '';
      final retailerId = request['retailerId']?.toString() ?? '';
      if (orderId.isEmpty || retailerId.isEmpty) {
        throw StateError('This request is missing its order or retailer link.');
      }
      final order = await transaction.get(
        _firestore.collection('orders').doc(orderId),
      );
      if (order.data()?['retailerId'] != retailerId) {
        throw StateError(
          'The request retailer does not match the parent order.',
        );
      }
      final name = request['requestedItem']?.toString().trim() ?? '';
      if (name.isEmpty || name.length > 200) {
        throw StateError('The requested product name is invalid.');
      }
      final completedId = request['catalogueProductId']?.toString() ?? '';
      final selectedId = request['selectedProductId']?.toString() ?? '';
      final generatedId = cleanImportId('Special requests\u0000$name');
      var productId = completedId.isNotEmpty
          ? completedId
          : selectedId.isNotEmpty
          ? selectedId
          : existingProductId ??
                (generatedId.length <= 100 ? generatedId : fallbackProductId);
      if (productId.isEmpty ||
          productId.length > 100 ||
          productId.contains('/')) {
        throw StateError(
          'The selected product ID is invalid. Review the request again.',
        );
      }
      final explicitlySelected =
          selectedId.isNotEmpty || existingProductId != null;
      var productRef = _firestore.collection('products').doc(productId);
      var productSnapshot = await transaction.get(productRef);
      if (productSnapshot.exists &&
          completedId.isEmpty &&
          !explicitlySelected &&
          !_hasName(productSnapshot.data()!, name)) {
        productId = fallbackProductId;
        productRef = _firestore.collection('products').doc(productId);
        productSnapshot = await transaction.get(productRef);
      }
      final settingsRef = _firestore
          .collection('retailer_score_sheet_settings')
          .doc(retailerId);
      final settingsSnapshot = await transaction.get(settingsRef);
      final product = productSnapshot.data();
      if (product == null && (explicitlySelected || completedId.isNotEmpty)) {
        throw StateError(
          'The selected product no longer exists. Review the request again.',
        );
      }
      if (product != null && completedId.isEmpty && !explicitlySelected) {
        throw StateError(
          'A product with this name or ID exists. Choose it explicitly before approving.',
        );
      }
      final catalogueId = product?['productId']?.toString().trim();
      final visibleId = catalogueId == null || catalogueId.isEmpty
          ? productId
          : catalogueId;
      if (product == null) {
        transaction.set(productRef, <String, dynamic>{
          'productId': productId,
          'itemName': name,
          'productName': name,
          'departmentName': 'Other',
          'mainCategoryName': 'Special requests',
          ...cataloguePriceFields(0.0),
          'uom': 'ctn',
          'mobileDisplayMode': 'textOnly',
          'isVisible': false,
          'status': 'hidden',
          'createdAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      final settings = settingsSnapshot.data();
      if (settings != null) {
        final patch = <String, dynamic>{};
        for (final key in <String>['hiddenProductIds', 'disabledProductIds']) {
          if (settings[key] is List) {
            patch[key] = (settings[key] as List)
                .where((id) => id != visibleId && id != productId)
                .toList();
          }
        }
        final visible = settings['visibleProductIds'];
        if (visible is List && visible.isNotEmpty) {
          patch['visibleProductIds'] = {...visible, visibleId}.toList();
        }
        final overrides = Map<String, dynamic>.from(
          settings['productOverrides'] as Map? ?? {},
        );
        if (overrides[visibleId] is Map) {
          overrides[visibleId] = {
            ...Map<String, dynamic>.from(overrides[visibleId] as Map),
            'isVisible': true,
            'status': 'active',
          };
          patch['productOverrides'] = overrides;
        }
        if (patch.isNotEmpty) transaction.update(settingsRef, patch);
      }
      if (completedId.isEmpty) {
        transaction.update(requestRef, <String, dynamic>{
          'status': 'approved',
          'approvalStep': 'Approved',
          'catalogueProductId': productId,
          'lastActorUid': actorUid,
          'lastActorRole': actorRole,
          'lastActionAt': FieldValue.serverTimestamp(),
          'updatedAt': FieldValue.serverTimestamp(),
        });
      }
      return (
        productId,
        product == null || !isCatalogueProductVisible(product),
      );
    });
    final String productId = approved.$1;
    if (!approved.$2) return SpecialRequestApproval(productId: productId);
    try {
      await applyAvailability(<String, bool>{productId: true});
    } on PlatformApiException catch (error) {
      return SpecialRequestApproval(
        productId: productId,
        hiddenReason: error.message,
      );
    }
    return SpecialRequestApproval(productId: productId);
  }

  static bool _hasName(Map<String, dynamic> product, String name) {
    String normal(Object? value) => (value?.toString() ?? '')
        .trim()
        .toLowerCase()
        .replaceAll(RegExp(r'\s+'), ' ');
    return normal(product['itemName']) == normal(name) ||
        normal(product['productName']) == normal(name);
  }

  Future<void> applyAvailability(Map<String, bool> changes) async {
    if (changes.isEmpty) return;
    if (changes.keys.any((String id) => id.isEmpty || id.contains('/'))) {
      throw ArgumentError('Product visibility selection is invalid.');
    }
    if (changes.length > maxAvailabilityChanges) {
      throw ArgumentError(
        'Select at most $maxAvailabilityChanges products at a time.',
      );
    }
    await _api.setProductAvailability(
      changes,
      idempotencyKey: const Uuid().v4(),
    );
  }

  Future<void> setVisibility({
    required List<String> productIds,
    required bool visible,
  }) async {
    if (productIds.isEmpty) return;
    if (productIds.length > maxAvailabilityChanges ||
        productIds.toSet().length != productIds.length) {
      throw ArgumentError('Product visibility selection is invalid.');
    }
    await applyAvailability(<String, bool>{
      for (final String id in productIds) id: visible,
    });

    await AuditLogService.instance.record(
      action: 'updated',
      entityType: 'products',
      entityId: productIds.length == 1 ? productIds.single : 'bulk-visibility',
      summary:
          '${visible ? 'Showed' : 'Hid'} ${productIds.length} '
          '${productIds.length == 1 ? 'product' : 'products'}',
      metadata: <String, dynamic>{
        'productIds': productIds,
        'isVisible': visible,
      },
    );
  }

  Future<int> deleteProducts(List<String> productIds) =>
      _api.deleteProducts(productIds, idempotencyKey: const Uuid().v4());

  Future<void> createIfAbsent({
    required String productId,
    required Map<String, dynamic> product,
    required String departmentId,
    required Map<String, dynamic> department,
    required String categoryId,
    required Map<String, dynamic> category,
    required bool ensureDepartment,
    required bool ensureCategory,
  }) async {
    final DocumentReference<Map<String, dynamic>> productRef = _firestore
        .collection('products')
        .doc(productId);
    final DocumentReference<Map<String, dynamic>> departmentRef = _firestore
        .collection('departments')
        .doc(departmentId);
    final DocumentReference<Map<String, dynamic>> categoryRef = _firestore
        .collection('categories')
        .doc(categoryId);

    Set<String> createdParents;
    try {
      createdParents = await _createTransaction(
        productRef: productRef,
        product: product,
        departmentRef: departmentRef,
        department: department,
        ensureDepartment: ensureDepartment,
        categoryRef: categoryRef,
        category: category,
        ensureCategory: ensureCategory,
      );
    } on FirebaseException catch (error) {
      if (error.code != 'permission-denied' ||
          (!ensureDepartment && !ensureCategory)) {
        rethrow;
      }
      createdParents = await _createTransaction(
        productRef: productRef,
        product: product,
        departmentRef: departmentRef,
        department: department,
        ensureDepartment: false,
        categoryRef: categoryRef,
        category: category,
        ensureCategory: false,
      );
    }

    await AuditLogService.instance.record(
      action: 'created',
      entityType: 'products',
      entityId: productId,
      summary: 'Created products: ${product['itemName'] ?? productId}',
    );
    if (createdParents.contains('departments')) {
      await AuditLogService.instance.record(
        action: 'created',
        entityType: 'departments',
        entityId: departmentId,
        summary: 'Created departments: ${department['name'] ?? departmentId}',
      );
    }
    if (createdParents.contains('categories')) {
      await AuditLogService.instance.record(
        action: 'created',
        entityType: 'categories',
        entityId: categoryId,
        summary: 'Created categories: ${category['name'] ?? categoryId}',
      );
    }
  }

  Future<Set<String>> _createTransaction({
    required DocumentReference<Map<String, dynamic>> productRef,
    required Map<String, dynamic> product,
    required DocumentReference<Map<String, dynamic>> departmentRef,
    required Map<String, dynamic> department,
    required bool ensureDepartment,
    required DocumentReference<Map<String, dynamic>> categoryRef,
    required Map<String, dynamic> category,
    required bool ensureCategory,
  }) => _firestore.runTransaction<Set<String>>((Transaction transaction) async {
    final DocumentSnapshot<Map<String, dynamic>> productSnapshot =
        await transaction.get(productRef);
    final DocumentSnapshot<Map<String, dynamic>>? departmentSnapshot =
        ensureDepartment ? await transaction.get(departmentRef) : null;
    final DocumentSnapshot<Map<String, dynamic>>? categorySnapshot =
        ensureCategory ? await transaction.get(categoryRef) : null;

    if (productSnapshot.exists) {
      throw StateError(
        'A product with this brand and product code already exists. Open it from the catalogue to edit it.',
      );
    }

    final Set<String> createdParents = <String>{};
    if (departmentSnapshot != null && !departmentSnapshot.exists) {
      transaction.set(departmentRef, <String, dynamic>{
        ...department,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      createdParents.add('departments');
    }
    if (categorySnapshot != null && !categorySnapshot.exists) {
      transaction.set(categoryRef, <String, dynamic>{
        ...category,
        'createdAt': FieldValue.serverTimestamp(),
        'updatedAt': FieldValue.serverTimestamp(),
      });
      createdParents.add('categories');
    }
    transaction.set(productRef, <String, dynamic>{
      ...product,
      'isVisible': false,
      'status': 'hidden',
      'createdAt': FieldValue.serverTimestamp(),
      'updatedAt': FieldValue.serverTimestamp(),
    });
    return createdParents;
  });
}
