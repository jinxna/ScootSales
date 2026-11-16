import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart' show debugPrint;

import '../models/user_profile.dart';
import '../utils/admin_setup_checklist_state.dart';
import '../utils/catalogue_product_availability.dart';
import '../utils/order_data_utils.dart';

class AdminSetupChecklistRepository {
  AdminSetupChecklistRepository({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  static const int _fallbackLimit = 25;
  static const int _fallbackQueryLimit = _fallbackLimit + 1;
  static const int _salespersonCodeLimit = 10;

  final FirebaseFirestore _firestore;
  Future<_SalespersonProbe?>? _cachedSalespersonProbe;
  Future<_LegacyUserProbe?>? _cachedLegacyUserProbe;

  Future<AdminSetupChecklistCounts> loadCounts() async {
    _cachedSalespersonProbe = null;
    _cachedLegacyUserProbe = null;
    final List<Object?> results = await Future.wait<Object?>(<Future<Object?>>[
      _exists('branches'),
      _activeSupervisor(),
      _activeSalespeopleWithBranch(),
      _supervisorWithAssignedSalespeople(),
      _nonRetiredRetailer(),
      _retailerAssignedToValidSalesperson(),
      _visibleCategorizedProduct(),
      _exists('retailer_score_sheet_settings'),
      _exists('route_plans', field: 'status', equals: 'published'),
      _exists('ai_runs'),
    ]);

    return AdminSetupChecklistCounts(
      branches: results[0] as int?,
      activeSupervisors: results[1] as int?,
      activeSalespeopleWithBranch: results[2] as int?,
      supervisorsWithAssignedSalespeople: results[3] as int?,
      nonRetiredRetailers: results[4] as int?,
      retailersAssignedToValidSalespeople: results[5] as int?,
      visibleCategorizedProducts: results[6] as int?,
      scoreSheetSettings: results[7] as int?,
      publishedRoutes: results[8] as int?,
      aiRuns: results[9] as int?,
    );
  }

  Future<int?> _exists(
    String collection, {
    String? field,
    Object? equals,
  }) async {
    try {
      Query<Map<String, dynamic>> query = _firestore.collection(collection);
      if (field != null) query = query.where(field, isEqualTo: equals);
      final QuerySnapshot<Map<String, dynamic>> snapshot = await query
          .limit(1)
          .get();
      return snapshot.docs.isEmpty ? 0 : 1;
    } catch (_) {
      return null;
    }
  }

  Future<int?> _activeSupervisor() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('users')
          .where('role', isEqualTo: UserProfile.roleSupervisor)
          .where('status', isEqualTo: UserProfile.statusActive)
          .limit(1)
          .get();
      if (snapshot.docs.isNotEmpty) return 1;
    } on FirebaseException catch (error) {
      if (_isMissingIndex(error)) {
        _logMissingIndex('active supervisor');
        final List<_ChecklistUser>? fallback = await _roleFallback(
          UserProfile.roleSupervisor,
        );
        if (fallback == null) return null;
        if (fallback.any((_ChecklistUser user) => user.profile.isActive)) {
          return 1;
        }
        final _LegacyUserProbe? legacy = await _legacyUserProbe();
        if (legacy == null) return null;
        if (legacy.users.any(
          (_ChecklistUser user) =>
              user.profile.isSupervisor && user.profile.isActive,
        )) {
          return 1;
        }
        return fallback.length <= _fallbackLimit && legacy.exhausted ? 0 : null;
      }
    } catch (_) {
    }

    final _LegacyUserProbe? probe = await _legacyUserProbe();
    if (probe == null) return null;
    if (probe.users.any(
      (_ChecklistUser user) =>
          user.profile.isSupervisor && user.profile.isActive,
    )) {
      return 1;
    }
    return probe.exhausted ? 0 : null;
  }

  Future<_SalespersonProbe?> _salespersonProbe() =>
      _cachedSalespersonProbe ??= _loadSalespersonProbe();

  Future<_SalespersonProbe?> _loadSalespersonProbe() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('users')
          .where('role', isEqualTo: UserProfile.roleSalesman)
          .where('status', isEqualTo: UserProfile.statusActive)
          .where('branchId', isGreaterThan: '')
          .limit(_salespersonCodeLimit + 1)
          .get();
      final List<_ChecklistUser> users = snapshot.docs
          .map(
            (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                _ChecklistUser.fromDocument(doc),
          )
          .toList(growable: false);
      return _SalespersonProbe(
        users: users,
        complete: users.length <= _salespersonCodeLimit,
      );
    } on FirebaseException catch (error) {
      if (!_isMissingIndex(error)) return null;
      _logMissingIndex('active salespeople with a branch');
      final List<_ChecklistUser>? fallback = await _roleFallback(
        UserProfile.roleSalesman,
      );
      if (fallback == null) return null;
      final List<_ChecklistUser> matching = fallback
          .where(
            (_ChecklistUser user) =>
                user.profile.isActive && user.profile.branchId.isNotEmpty,
          )
          .toList(growable: false);
      return _SalespersonProbe(
        users: matching,
        complete:
            fallback.length <= _fallbackLimit &&
            matching.length <= _salespersonCodeLimit,
      );
    } catch (_) {
      return null;
    }
  }

  Future<int?> _activeSalespeopleWithBranch() async {
    final _SalespersonProbe? salespeople = await _salespersonProbe();
    if (salespeople == null) return null;
    if (salespeople.users.isNotEmpty) return 1;

    final _LegacyUserProbe? legacy = await _legacyUserProbe();
    if (legacy == null) return null;
    if (legacy.users.any(
      (_ChecklistUser user) =>
          user.profile.isSalesman &&
          user.profile.isActive &&
          user.profile.branchId.isNotEmpty,
    )) {
      return 1;
    }
    return legacy.exhausted ? 0 : null;
  }

  Future<int?> _supervisorWithAssignedSalespeople() async {
    final _SalespersonProbe? salespeople = await _salespersonProbe();
    if (salespeople == null) return null;
    final List<String> codes = salespeople.users
        .take(_salespersonCodeLimit)
        .expand((_ChecklistUser user) => user.identifiers)
        .toSet()
        .take(30)
        .toList(growable: false);

    if (codes.isNotEmpty) {
      final Set<String> validIds = salespeople.users
          .take(_salespersonCodeLimit)
          .expand((_ChecklistUser user) => user.identifiers)
          .toSet();
      try {
        final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
            .collection('users')
            .where('role', isEqualTo: UserProfile.roleSupervisor)
            .where('status', isEqualTo: UserProfile.statusActive)
            .where('assignedSalesmanCodes', arrayContainsAny: codes)
            .limit(1)
            .get();
        if (snapshot.docs.any((
          QueryDocumentSnapshot<Map<String, dynamic>> doc,
        ) {
          final UserProfile profile = UserProfile.fromFirestore(
            doc.id,
            doc.data(),
          );
          return profile.isSupervisor &&
              profile.isActive &&
              profile.assignedSalesmanCodes.any(validIds.contains);
        })) {
          return 1;
        }
      } on FirebaseException catch (error) {
        if (_isMissingIndex(error)) {
          _logMissingIndex('supervisor salesperson assignment');
          final List<_ChecklistUser>? fallback = await _roleFallback(
            UserProfile.roleSupervisor,
          );
          if (fallback == null) return null;
          if (fallback.any(
            (_ChecklistUser user) =>
                user.profile.isActive &&
                user.profile.assignedSalesmanCodes.any(validIds.contains),
          )) {
            return 1;
          }
          if (salespeople.complete && fallback.length <= _fallbackLimit) {
            return 0;
          }
          return null;
        }
      } catch (_) {
      }
    }

    final _LegacyUserProbe? legacy = await _legacyUserProbe();
    if (legacy == null) return null;
    final Set<String> validIds = salespeople.users
        .take(_salespersonCodeLimit)
        .expand((_ChecklistUser user) => user.identifiers)
        .toSet();
    final bool assigned = legacy.users.any(
      (_ChecklistUser user) =>
          user.profile.isSupervisor &&
          user.profile.isActive &&
          user.profile.assignedSalesmanCodes.any(validIds.contains),
    );
    if (assigned) return 1;
    if (!salespeople.complete || !legacy.exhausted) return null;
    return 0;
  }

  Future<_RetailerProbe?> _retailerProbe() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('retailers')
          .orderBy(FieldPath.documentId)
          .limit(_fallbackQueryLimit)
          .get();
      return _RetailerProbe(
        retailers: snapshot.docs
            .map(
              (QueryDocumentSnapshot<Map<String, dynamic>> doc) =>
                  <String, dynamic>{...doc.data(), 'docId': doc.id},
            )
            .toList(growable: false),
        exhausted: snapshot.docs.length <= _fallbackLimit,
      );
    } catch (_) {
      return null;
    }
  }

  Future<int?> _nonRetiredRetailer() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('retailers')
          .where('status', isNotEqualTo: 'retired')
          .limit(1)
          .get();
      if (snapshot.docs.any((doc) {
        final Map<String, dynamic> row = <String, dynamic>{
          ...doc.data(),
          'docId': doc.id,
        };
        return isOperationalRetailerRecord(row);
      })) {
        return 1;
      }
    } catch (_) {
    }

    final _RetailerProbe? probe = await _retailerProbe();
    if (probe == null) return null;
    if (probe.retailers.any(isOperationalRetailerRecord)) return 1;
    return probe.exhausted ? 0 : null;
  }

  Future<int?> _retailerAssignedToValidSalesperson() async {
    final _SalespersonProbe? salespeople = await _salespersonProbe();
    if (salespeople == null) return null;
    final List<String> codes = salespeople.users
        .take(_salespersonCodeLimit)
        .expand((_ChecklistUser user) => user.identifiers)
        .toSet()
        .take(30)
        .toList(growable: false);
    if (codes.isEmpty) {
      return salespeople.complete ? 0 : null;
    }

    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('retailers')
          .where('assignedSalesmanId', whereIn: codes)
          .limit(_fallbackLimit)
          .get();
      for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
          in snapshot.docs) {
        final Map<String, dynamic> row = <String, dynamic>{
          ...doc.data(),
          'docId': doc.id,
        };
        if (isOperationalRetailerRecord(row)) return 1;
      }
      if (snapshot.docs.length < _fallbackLimit && salespeople.complete) {
        return 0;
      }
    } on FirebaseException catch (error) {
      if (_isMissingIndex(error)) {
        _logMissingIndex('retailer assignment');
        final _RetailerProbe? probe = await _retailerProbe();
        if (probe == null) return null;
        final Set<String> validIds = salespeople.users
            .take(_salespersonCodeLimit)
            .expand((_ChecklistUser user) => user.identifiers)
            .toSet();
        final bool found = probe.retailers.any((Map<String, dynamic> row) {
          if (!isOperationalRetailerRecord(row)) return false;
          return validIds.contains(
            _firstText(row, const <String>[
              'assignedSalesmanId',
              'salesmanId',
              'salesman_id',
            ]),
          );
        });
        if (found) return 1;
        return probe.exhausted && salespeople.complete ? 0 : null;
      }
    } catch (_) {
    }

    final _RetailerProbe? legacy = await _retailerProbe();
    if (legacy == null) return null;
    final Set<String> validIds = salespeople.users
        .take(_salespersonCodeLimit)
        .expand((_ChecklistUser user) => user.identifiers)
        .toSet();
    final bool assigned = legacy.retailers.any((Map<String, dynamic> row) {
      if (!isOperationalRetailerRecord(row)) return false;
      return _firstText(row, const <String>[
            'assignedSalesmanId',
            'salesmanId',
            'salesman_id',
          ]).isNotEmpty &&
          validIds.contains(
            _firstText(row, const <String>[
              'assignedSalesmanId',
              'salesmanId',
              'salesman_id',
            ]),
          );
    });
    if (assigned) return 1;
    return legacy.exhausted && salespeople.complete ? 0 : null;
  }

  Future<int?> _visibleCategorizedProduct() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('products')
          .where('isVisible', isEqualTo: true)
          .where('departmentId', isGreaterThan: '')
          .where('categoryId', isGreaterThan: '')
          .limit(_fallbackLimit)
          .get();
      if (snapshot.docs.any((doc) {
        final Map<String, dynamic> row = <String, dynamic>{
          ...doc.data(),
          'docId': doc.id,
        };
        return !isDemoProductRecord(row) && isCatalogueProductVisible(row);
      })) {
        return 1;
      }
    } on FirebaseException catch (error) {
      if (_isMissingIndex(error)) {
        _logMissingIndex('visible categorized products');
        return _visibleProductFallback();
      }
      return _visibleProductFallback();
    } catch (_) {
      return _visibleProductFallback();
    }

    return _visibleProductFallback();
  }

  Future<int?> _visibleProductFallback() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('products')
          .where('isVisible', isEqualTo: true)
          .limit(_fallbackQueryLimit)
          .get();
      final bool found = snapshot.docs.any((doc) {
        final Map<String, dynamic> row = <String, dynamic>{
          ...doc.data(),
          'docId': doc.id,
        };
        if (isDemoProductRecord(row) || !isCatalogueProductVisible(row)) {
          return false;
        }
        return _firstText(row, const <String>[
              'departmentId',
              'departmentName',
              'department_id',
            ]).isNotEmpty &&
            _firstText(row, const <String>[
              'categoryId',
              'mainCategoryId',
              'mainCategoryName',
              'categoryName',
              'category_id',
            ]).isNotEmpty;
      });
      if (found) return 1;
    } catch (_) {
    }

    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('products')
          .orderBy(FieldPath.documentId)
          .limit(_fallbackQueryLimit)
          .get();
      final bool found = snapshot.docs.any((doc) {
        final Map<String, dynamic> row = <String, dynamic>{
          ...doc.data(),
          'docId': doc.id,
        };
        if (isDemoProductRecord(row) || !isCatalogueProductVisible(row)) {
          return false;
        }
        return _firstText(row, const <String>[
              'departmentId',
              'departmentName',
              'department_id',
            ]).isNotEmpty &&
            _firstText(row, const <String>[
              'categoryId',
              'mainCategoryId',
              'mainCategoryName',
              'categoryName',
              'category_id',
            ]).isNotEmpty;
      });
      if (found) return 1;
      return snapshot.docs.length <= _fallbackLimit ? 0 : null;
    } catch (_) {
      return null;
    }
  }

  Future<_LegacyUserProbe?> _legacyUserProbe() =>
      _cachedLegacyUserProbe ??= _loadLegacyUserProbe();

  Future<_LegacyUserProbe?> _loadLegacyUserProbe() async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('users')
          .orderBy(FieldPath.documentId)
          .limit(_fallbackQueryLimit)
          .get();
      return _LegacyUserProbe(
        users: snapshot.docs
            .map(_ChecklistUser.fromDocument)
            .toList(growable: false),
        exhausted: snapshot.docs.length <= _fallbackLimit,
      );
    } catch (_) {
      return null;
    }
  }

  static String _firstText(Map<String, dynamic> row, List<String> keys) {
    for (final String key in keys) {
      final String value = (row[key] ?? '').toString().trim();
      if (value.isNotEmpty) return value;
    }
    return '';
  }

  Future<List<_ChecklistUser>?> _roleFallback(String role) async {
    try {
      final QuerySnapshot<Map<String, dynamic>> snapshot = await _firestore
          .collection('users')
          .where('role', isEqualTo: role)
          .limit(_fallbackQueryLimit)
          .get();
      return snapshot.docs
          .map(_ChecklistUser.fromDocument)
          .toList(growable: false);
    } on FirebaseException catch (error) {
      if (_isMissingIndex(error)) _logMissingIndex('$role fallback');
      return null;
    } catch (_) {
      return null;
    }
  }

  static bool _isMissingIndex(FirebaseException error) =>
      error.code == 'failed-precondition';

  static void _logMissingIndex(String probe) => debugPrint(
    'Admin setup checklist: Firestore index missing for $probe; '
    'using a bounded fallback query.',
  );
}

class _ChecklistUser {
  _ChecklistUser(this.profile, this.identifiers);

  factory _ChecklistUser.fromDocument(
    QueryDocumentSnapshot<Map<String, dynamic>> doc,
  ) => _fromRow(doc.id, doc.data());

  static _ChecklistUser _fromRow(String id, Map<String, dynamic> row) {
    final UserProfile profile = UserProfile.fromFirestore(id, row);
    final Set<String> identifiers = <String>{
      id,
      if (profile.uid != null) profile.uid!,
      profile.employeeCode,
    }..removeWhere((String value) => value.trim().isEmpty);
    return _ChecklistUser(profile, identifiers);
  }

  final UserProfile profile;
  final Set<String> identifiers;
}

class _SalespersonProbe {
  const _SalespersonProbe({required this.users, required this.complete});

  final List<_ChecklistUser> users;
  final bool complete;
}

class _LegacyUserProbe {
  const _LegacyUserProbe({required this.users, required this.exhausted});

  final List<_ChecklistUser> users;
  final bool exhausted;
}

class _RetailerProbe {
  const _RetailerProbe({required this.retailers, required this.exhausted});

  final List<Map<String, dynamic>> retailers;
  final bool exhausted;
}
