import '../utils/geo_field_utils.dart';
import '../utils/order_data_utils.dart';
import '../utils/price_stamp.dart';
import '../utils/retailer_readiness.dart';
import 'user_profile.dart';

const Set<String> _dashboardRoles = <String>{
  UserProfile.roleAdmin,
  UserProfile.roleDeveloper,
  UserProfile.roleBranchManager,
  UserProfile.roleSupervisor,
};

enum HygieneSeverity { high, medium, low }

class HygieneIssue {
  const HygieneIssue({
    required this.id,
    required this.type,
    required this.title,
    required this.detail,
    required this.entityType,
    required this.entityId,
    required this.severity,
    this.fixPageKey = '',
  });

  final String id;
  final String type;
  final String title;
  final String detail;
  final String entityType;
  final String entityId;
  final HygieneSeverity severity;
  final String fixPageKey;
}

List<HygieneIssue> detectMasterDataIssues({
  required List<Map<String, dynamic>> products,
  required List<Map<String, dynamic>> retailers,
  required List<Map<String, dynamic>> users,
  required List<Map<String, dynamic>> orders,
}) {
  final List<HygieneIssue> issues = <HygieneIssue>[];
  final Map<String, Map<String, dynamic>> salesmenByCode =
      <String, Map<String, dynamic>>{};
  final Map<String, Map<String, dynamic>> salesmenByUid =
      <String, Map<String, dynamic>>{};
  for (final Map<String, dynamic> user in users) {
    final String rawRole = _text(user['role'] ?? user['user_group']);
    final String role = rawRole.isEmpty
        ? ''
        : UserProfile.normalizeRole(rawRole, email: user['email']);
    _addUnaddressableProfileIssue(issues, user, role);
    if (role != UserProfile.roleSalesman) continue;
    final String code = _first(user, const <String>[
      'employeeCode',
      'staffId',
      'salesmanCode',
    ]);
    final String uid = _first(user, const <String>['uid', 'docId']);
    if (code.isNotEmpty) salesmenByCode[code] = user;
    if (uid.isNotEmpty) salesmenByUid[uid] = user;
  }

  _addDuplicateIssues(
    issues,
    rows: products,
    entityType: 'product',
    type: 'duplicate_product',
    nameKeys: const <String>['productName', 'name', 'description'],
    codeKeys: const <String>['productId', 'itemCode', 'sku', 'barcode'],
    fixPageKey: 'product',
  );
  _addDuplicateIssues(
    issues,
    rows: retailers,
    entityType: 'retailer',
    type: 'duplicate_retailer',
    nameKeys: const <String>['retailerName', 'name', 'outletName'],
    codeKeys: const <String>['retailerId', 'customerCode', 'code'],
    fixPageKey: 'retailer',
  );

  for (final Map<String, dynamic> product in products) {
    final String id = _entityId(product, 'product');
    final double price = cataloguePriceOf(product);
    if (price <= 0) {
      issues.add(
        HygieneIssue(
          id: 'missing_product_price::$id',
          type: 'missing_product_price',
          title: 'Product has no usable price',
          detail: _label(product, 'product'),
          entityType: 'product',
          entityId: id,
          severity: HygieneSeverity.high,
          fixPageKey: 'product',
        ),
      );
    }
  }

  for (final Map<String, dynamic> retailer in retailers) {
    final String id = _entityId(retailer, 'retailer');
    if (!hasLatLng(retailer)) {
      issues.add(
        HygieneIssue(
          id: 'missing_coordinates::$id',
          type: 'missing_coordinates',
          title: 'Retailer has missing or invalid coordinates',
          detail: _label(retailer, 'retailer'),
          entityType: 'retailer',
          entityId: id,
          severity: HygieneSeverity.high,
          fixPageKey: 'retailer',
        ),
      );
    } else {
      final CoordinateStatus coordinateStatus = retailerCoordinateStatus(
        retailer,
      );
      if (!coordinateStatus.isRouteReady) {
        issues.add(
          HygieneIssue(
            id: 'unverified_coordinates::$id',
            type: 'unverified_coordinates',
            title: 'Retailer coordinates are not verified',
            detail:
                '${_label(retailer, 'retailer')} · '
                'status=${coordinateStatus.wireValue}',
            entityType: 'retailer',
            entityId: id,
            severity: HygieneSeverity.medium,
            fixPageKey: 'coordinate_review',
          ),
        );
      }
    }
    final String code = _first(retailer, const <String>[
      'assignedSalesmanId',
      'assignedSalesmanCode',
      'salesmanCode',
      'salesmanId',
    ]);
    final String uid = _first(retailer, const <String>[
      'assignedSalesmanUid',
      'salesmanUid',
    ]);
    if (code.isEmpty && uid.isEmpty) {
      issues.add(
        HygieneIssue(
          id: 'retailer_unassigned::$id',
          type: 'retailer_unassigned',
          title: 'Retailer is not assigned',
          detail: _label(retailer, 'retailer'),
          entityType: 'retailer',
          entityId: id,
          severity: HygieneSeverity.medium,
          fixPageKey: 'retailer',
        ),
      );
    } else if ((code.isNotEmpty && !salesmenByCode.containsKey(code)) ||
        (uid.isNotEmpty && !salesmenByUid.containsKey(uid))) {
      issues.add(
        HygieneIssue(
          id: 'outdated_assignment::$id',
          type: 'outdated_assignment',
          title: 'Retailer assignment does not match an active salesman',
          detail: '${_label(retailer, 'retailer')} · code=$code uid=$uid',
          entityType: 'retailer',
          entityId: id,
          severity: HygieneSeverity.high,
          fixPageKey: 'retailer',
        ),
      );
    }
  }

  for (final Map<String, dynamic> order in orders) {
    final String id = _entityId(order, 'order');
    if (_date(order['submittedAt'] ?? order['submitted_at']) == null) {
      issues.add(
        HygieneIssue(
          id: 'missing_submitted_at::$id',
          type: 'missing_submitted_at',
          title: 'Order has no parseable submittedAt',
          detail: _label(order, 'order'),
          entityType: 'order',
          entityId: id,
          severity: HygieneSeverity.high,
        ),
      );
    }
    final List<Map<String, dynamic>> rawItems = authoritativeOrderItems(order);
    if (rawItems.isEmpty) {
      issues.add(
        HygieneIssue(
          id: 'unparseable_items::$id',
          type: 'unparseable_items',
          title: 'Order items are missing or unparseable',
          detail: _label(order, 'order'),
          entityType: 'order',
          entityId: id,
          severity: HygieneSeverity.high,
        ),
      );
    } else {
      for (int index = 0; index < rawItems.length; index++) {
        final Map<String, dynamic> item = rawItems[index];
        final double quantity = _number(
          item['quantity'] ?? item['qty'] ?? item['orderQty'],
        );
        if (quantity <= 0) {
          issues.add(
            HygieneIssue(
              id: 'invalid_quantity::$id::$index',
              type: 'invalid_quantity',
              title: 'Order item quantity is missing, zero, or negative',
              detail: '${_label(order, 'order')} · item ${index + 1}',
              entityType: 'order',
              entityId: id,
              severity: HygieneSeverity.high,
            ),
          );
        }
      }
    }

    final String code = _first(order, const <String>[
      'salesmanCode',
      'salesmanId',
      'staffId',
      'employeeCode',
    ]);
    final String uid = _first(order, const <String>['salesmanUid', 'userUid']);
    final Map<String, dynamic>? byCode = salesmenByCode[code];
    final Map<String, dynamic>? byUid = salesmenByUid[uid];
    final String uidForCode = byCode == null
        ? ''
        : _first(byCode, const <String>['uid', 'docId']);
    final String codeForUid = byUid == null
        ? ''
        : _first(byUid, const <String>['employeeCode', 'staffId']);
    if ((code.isNotEmpty && byCode == null) ||
        (uid.isNotEmpty && byUid == null) ||
        (code.isNotEmpty &&
            uid.isNotEmpty &&
            ((uidForCode.isNotEmpty && uidForCode != uid) ||
                (codeForUid.isNotEmpty && codeForUid != code)))) {
      issues.add(
        HygieneIssue(
          id: 'inconsistent_salesman::$id',
          type: 'inconsistent_salesman',
          title: 'Order salesman UID/code is inconsistent',
          detail: '${_label(order, 'order')} · code=$code uid=$uid',
          entityType: 'order',
          entityId: id,
          severity: HygieneSeverity.high,
        ),
      );
    }
  }

  issues.sort((HygieneIssue left, HygieneIssue right) {
    final int severity = left.severity.index.compareTo(right.severity.index);
    return severity != 0 ? severity : left.type.compareTo(right.type);
  });
  return issues;
}

void _addUnaddressableProfileIssue(
  List<HygieneIssue> issues,
  Map<String, dynamic> user,
  String role,
) {
  if (!_dashboardRoles.contains(role)) return;
  final bool active =
      UserProfile.normalizeStatus(
        user['status'] ?? user['accountStatus'] ?? user['account_status'],
        isActive: user['isActive'] ?? user['active'] ?? user['enabled'],
      ) ==
      UserProfile.statusActive;
  if (!active) return;
  final String docId = _text(user['docId']);
  if (docId.isEmpty) return;
  final String uid = _text(user['uid'] ?? user['authUid']);
  if (uid.isNotEmpty && docId == uid) return;
  final bool confirmedMismatch = uid.isNotEmpty;
  final String label = _first(user, const <String>[
    'name',
    'displayName',
    'email',
  ]);
  issues.add(
    HygieneIssue(
      id: 'unaddressable_profile::$docId',
      type: 'unaddressable_profile',
      title: confirmedMismatch
          ? 'Dashboard profile is not addressable by Firestore rules'
          : 'Dashboard profile addressability cannot be confirmed',
      detail:
          '${label.isEmpty ? '(unnamed)' : label} '
          '· role=$role · doc=$docId '
          'uid=${confirmedMismatch ? uid : '(no uid field stored)'}',
      entityType: 'user',
      entityId: docId,
      severity: confirmedMismatch
          ? HygieneSeverity.high
          : HygieneSeverity.medium,
    ),
  );
}

void _addDuplicateIssues(
  List<HygieneIssue> issues, {
  required List<Map<String, dynamic>> rows,
  required String entityType,
  required String type,
  required List<String> nameKeys,
  required List<String> codeKeys,
  required String fixPageKey,
}) {
  final Map<String, List<Map<String, dynamic>>> groups =
      <String, List<Map<String, dynamic>>>{};
  for (final Map<String, dynamic> row in rows) {
    final String name = _normal(_first(row, nameKeys));
    final String code = _normal(_first(row, codeKeys));
    final String key = code.isNotEmpty ? 'code:$code' : 'name:$name';
    if (key.endsWith(':')) continue;
    groups.putIfAbsent(key, () => <Map<String, dynamic>>[]).add(row);
  }
  for (final List<Map<String, dynamic>> group in groups.values) {
    if (group.length < 2) continue;
    final String ids = group
        .map((Map<String, dynamic> row) => _entityId(row, entityType))
        .join(', ');
    issues.add(
      HygieneIssue(
        id: '$type::$ids',
        type: type,
        title: 'Possible duplicate ${entityType}s require review',
        detail:
            '${group.map((row) => _label(row, entityType)).join(' / ')} '
            '· documents: $ids · no automatic merge',
        entityType: entityType,
        entityId: ids,
        severity: HygieneSeverity.medium,
        fixPageKey: fixPageKey,
      ),
    );
  }
}

String _entityId(Map<String, dynamic> row, String type) => _first(row, <String>[
  'docId',
  '${type}Id',
  'id',
  'orderId',
  'productId',
  'retailerId',
]);

String _label(Map<String, dynamic> row, String type) => _first(row, <String>[
  '${type}Name',
  'name',
  'retailerName',
  'productName',
  'orderId',
  'docId',
]);

String _first(Map<String, dynamic> row, List<String> keys) {
  for (final String key in keys) {
    final String value = _text(row[key]);
    if (value.isNotEmpty) return value;
  }
  return '';
}

String _text(Object? value) {
  final String text = (value ?? '').toString().trim();
  return text.toLowerCase() == 'null' ? '' : text;
}

String _normal(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

double _number(Object? value) {
  if (value is num) return value.toDouble();
  return double.tryParse(_text(value).replaceAll(',', '')) ?? 0;
}

DateTime? _date(Object? value) {
  if (value is DateTime) return value;
  try {
    final dynamic candidate = value;
    final DateTime result = candidate.toDate() as DateTime;
    return result;
  } catch (_) {
    return DateTime.tryParse(_text(value));
  }
}
