import 'dart:async';
import 'dart:convert';

import 'package:shared_preferences/shared_preferences.dart';
import '../utils/quantity_unit.dart';
import 'project_local_store.dart';

class CartDraftSnapshot {
  CartDraftSnapshot({
    required this.salesmanUid,
    required this.retailerId,
    this.visitId,
    this.progress,
    this.pendingOrderId = '',
    this.revision = 0,
    List<Map<String, dynamic>>? items,
    Map<String, Map<String, dynamic>>? signatures,
    this.specialRequest,
  }) : items = items ?? <Map<String, dynamic>>[],
       signatures = signatures ?? <String, Map<String, dynamic>>{};

  final String salesmanUid;
  final String retailerId;
  final String? visitId;
  final int? progress;
  final String pendingOrderId;
  final int revision;
  final List<Map<String, dynamic>> items;
  final Map<String, Map<String, dynamic>> signatures;

  final Map<String, dynamic>? specialRequest;

  CartDraftSnapshot copyWith({
    int? progress,
    String? pendingOrderId,
    int? revision,
    List<Map<String, dynamic>>? items,
    Map<String, Map<String, dynamic>>? signatures,
  }) {
    return CartDraftSnapshot(
      salesmanUid: salesmanUid,
      retailerId: retailerId,
      visitId: visitId,
      progress: progress ?? this.progress,
      pendingOrderId: pendingOrderId ?? this.pendingOrderId,
      revision: revision ?? this.revision,
      items: items ?? this.items,
      signatures: signatures ?? this.signatures,
      specialRequest: specialRequest,
    );
  }
}

enum CartDraftPersistenceStatus { saved, failed }

class CartDraftPersistenceResult {
  const CartDraftPersistenceResult._(this.status, this.error);

  const CartDraftPersistenceResult.saved()
    : this._(CartDraftPersistenceStatus.saved, null);

  const CartDraftPersistenceResult.failed(Object error)
    : this._(CartDraftPersistenceStatus.failed, error);

  final CartDraftPersistenceStatus status;
  final Object? error;

  bool get isSaved => status == CartDraftPersistenceStatus.saved;
}

class _OpenDraftWrite {
  _OpenDraftWrite(this.draft);

  CartDraftSnapshot? draft;
}

class CartDraftCache {
  CartDraftCache._();

  static const String _storageKey = 'cart_draft_cache.v1';

  static final Map<String, CartDraftSnapshot> _drafts =
      <String, CartDraftSnapshot>{};
  static Future<void> _persistQueue = Future<void>.value();
  static final Set<String> _deletedKeys = {};
  static int _runtimeGeneration = 0;

  static bool _hydratedAll = false;
  static final Set<String> _hydratedOwnerPrefixes = <String>{};

  static void resetRuntime({String? keepOwnerUid}) {
    _runtimeGeneration++;
    _deletedKeys.clear();
    String? ownerPrefix;
    try {
      if (keepOwnerUid != null) {
        ownerPrefix = ProjectLocalStore().prefix(keepOwnerUid);
      }
    } catch (_) {
      ownerPrefix = null;
    }
    final String? keptPrefix = ownerPrefix;
    final bool keepHydrated =
        keptPrefix != null &&
        (_hydratedAll || _hydratedOwnerPrefixes.contains(keptPrefix));
    if (!keepHydrated) {
      _drafts.clear();
      _hydratedAll = false;
      _hydratedOwnerPrefixes.clear();
      return;
    }
    _drafts.removeWhere((String key, _) => !key.startsWith(keptPrefix));
    _hydratedAll = false;
    _hydratedOwnerPrefixes
      ..clear()
      ..add(keptPrefix);
  }

  static List<Map<String, dynamic>> removeEmptyShelfBatches(
    List<Map<String, dynamic>> items,
  ) {
    return items
        .map((Map<String, dynamic> item) {
          final Object? rawBatches = item['shelfBatches'];
          if (rawBatches is! List) return item;
          return <String, dynamic>{
            ...item,
            'shelfBatches': rawBatches
                .whereType<Map>()
                .map((Map batch) => Map<String, dynamic>.from(batch))
                .where((Map<String, dynamic> batch) {
                  final Object? quantity = batch['qty'];
                  return quantity is int && quantity > 0;
                })
                .toList(growable: false),
          };
        })
        .toList(growable: false);
  }

  static Future<void> initialise({String? uid}) async {
    final store = ProjectLocalStore();
    final generation = _runtimeGeneration;
    final projectPrefix =
        'project_storage_v1.${ProjectLocalStore.encode(store.projectId)}.';
    final String? ownerPrefix = uid == null ? null : store.prefix(uid);
    await _persistQueue;
    if (ownerPrefix != null &&
        (_hydratedAll || _hydratedOwnerPrefixes.contains(ownerPrefix))) {
      await ProjectLocalStore.refreshRecoveryNotice();
      return;
    }
    await _migrateLegacy(store);
    await ProjectLocalStore.refreshRecoveryNotice();
    final prefs = await SharedPreferences.getInstance();
    final keys = prefs
        .getKeys()
        .where(
          (key) =>
              key.startsWith(projectPrefix) &&
              key.split('.').length == 5 &&
              key.split('.')[3] == 'cart_draft' &&
              (uid == null || key.startsWith(store.prefix(uid))),
        )
        .toList();
    final List<(String?, String?, Object?)> reads = await Future.wait(
      keys.map((String key) async {
        try {
          final owner = utf8.decode(
            base64Url.decode(base64Url.normalize(key.split('.')[2])),
          );
          final raw = await store.read(
            owner,
            key.substring(store.prefix(owner).length),
          );
          return (owner, raw, null);
        } catch (error) {
          return (null, null, error);
        }
      }),
    );
    for (int index = 0; index < keys.length; index++) {
      final key = keys[index];
      try {
        final String? owner = reads[index].$1;
        final String? raw = reads[index].$2;
        if (reads[index].$3 != null || owner == null) {
          throw StateError('Draft could not be read');
        }
        if (generation != _runtimeGeneration ||
            ProjectLocalStore().projectId != store.projectId) {
          return;
        }
        if (raw == null ||
            _drafts.containsKey(key) ||
            _deletedKeys.contains(key)) {
          continue;
        }
        final decoded = jsonDecode(raw);
        if (decoded is! Map) throw const FormatException('Invalid draft');
        final row = Map<String, dynamic>.from(decoded);
        if (row['salesmanUid'] != owner) {
          throw const FormatException('Invalid draft owner');
        }
        _drafts[key] = CartDraftSnapshot(
          salesmanUid: owner,
          retailerId: row['retailerId']?.toString() ?? '',
          visitId: row['visitId']?.toString(),
          progress: (row['progress'] as num?)?.toInt(),
          pendingOrderId: row['pendingOrderId']?.toString() ?? '',
          revision: (row['revision'] as num?)?.toInt() ?? 0,
          items: (row['items'] as List? ?? const [])
              .whereType<Map>()
              .map((item) => Map<String, dynamic>.from(item))
              .toList(growable: false),
          signatures: _decodeSignatures(row['signatures']),
          specialRequest: row['specialRequest'] is Map
              ? Map<String, dynamic>.from(row['specialRequest'] as Map)
              : null,
        );
      } catch (_) {
        await ProjectLocalStore.recoverLegacyKey(key);
      }
    }
    if (generation != _runtimeGeneration) return;
    if (ownerPrefix == null) {
      _hydratedAll = true;
    } else {
      _hydratedOwnerPrefixes.add(ownerPrefix);
    }
  }

  static String keyFor({
    required String salesmanUid,
    required String retailerId,
    String? visitId,
    String? routePlanId,
    String? routeStopId,
  }) {
    final store = ProjectLocalStore();
    final uid = _safePart(salesmanUid);
    String scoped(String identity) => store.key(
      salesmanUid,
      'cart_draft.${ProjectLocalStore.encode(identity)}',
    );
    final visit = (visitId ?? '').trim();
    if (visit.isNotEmpty) return scoped('$uid|visit:${_safePart(visit)}');
    final String plan = (routePlanId ?? '').trim();
    final String stop = (routeStopId ?? '').trim();
    if (plan.isNotEmpty != stop.isNotEmpty) {
      throw ArgumentError(
        'Assigned visit draft identity requires both route plan and stop.',
      );
    }
    if (plan.isNotEmpty) {
      return scoped('$uid|route:${_safePart(plan)}|stop:${_safePart(stop)}');
    }
    return scoped('$uid|retailer:${_safePart(retailerId)}');
  }

  static CartDraftSnapshot? read(String key) {
    final scope = _scope(key);
    return scope.$1.isActive(scope.$2) ? _drafts[key] : null;
  }

  static CartDraftSnapshot? readForRetailer({
    required String salesmanUid,
    required String retailerId,
  }) {
    if (!ProjectLocalStore().isActive(salesmanUid)) return null;
    final scopedRetailerKey = keyFor(
      salesmanUid: salesmanUid,
      retailerId: retailerId,
    );
    final direct = read(scopedRetailerKey);
    if (direct != null) return direct;

    final safeUid = _safePart(salesmanUid);
    final prefix = ProjectLocalStore().prefix(salesmanUid);
    for (final entry in _drafts.entries) {
      if (!entry.key.startsWith(prefix)) continue;
      final draft = entry.value;
      if (_safePart(draft.salesmanUid) == safeUid &&
          draft.retailerId == retailerId) {
        return draft;
      }
    }
    return null;
  }

  static int? setSuggestedQty({
    required String salesmanUid,
    required String retailerId,
    required String productId,
    required int suggestedQty,
  }) {
    if (!ProjectLocalStore().isActive(salesmanUid)) return null;
    final String prefix = ProjectLocalStore().prefix(salesmanUid);
    int? applied;
    for (final MapEntry<String, CartDraftSnapshot> entry
        in _drafts.entries.toList(growable: false)) {
      final CartDraftSnapshot draft = entry.value;
      if (!entry.key.startsWith(prefix) ||
          draft.retailerId != retailerId ||
          draft.pendingOrderId.trim().isNotEmpty ||
          !draft.items.any(
            (Map<String, dynamic> item) => item['productId'] == productId,
          )) {
        continue;
      }
      save(
        entry.key,
        draft.copyWith(
          items: draft.items
              .map((Map<String, dynamic> item) {
                if (item['productId'] != productId) return item;
                final int limit = maxQtyFor(item);
                final int quantity = suggestedQty > limit
                    ? limit
                    : suggestedQty;
                applied = quantity;
                return <String, dynamic>{
                  ...item,
                  'qty': quantity,
                  'suggestedReorderQty': suggestedQty,
                };
              })
              .toList(growable: false),
        ),
      );
    }
    return applied;
  }

  static void save(String key, CartDraftSnapshot draft) {
    _validateKey(key, draft);
    _deletedKeys.remove(key);
    _drafts[key] = draft;
    _schedulePersist(key, draft);
  }

  static Future<CartDraftPersistenceResult> saveAndWait(
    String key,
    CartDraftSnapshot draft,
  ) async {
    _validateKey(key, draft);
    _deletedKeys.remove(key);
    _drafts[key] = draft;
    try {
      await _enqueuePersist(key, draft);
      return const CartDraftPersistenceResult.saved();
    } catch (error) {
      return CartDraftPersistenceResult.failed(error);
    }
  }

  static void clear(String key) {
    _drafts.remove(key);
    _deletedKeys.add(key);
    _schedulePersist(key, null);
  }

  static void clearSalesman(String salesmanUid) {
    final prefix = ProjectLocalStore().prefix(salesmanUid);
    for (final key
        in _drafts.keys.where((key) => key.startsWith(prefix)).toList()) {
      clear(key);
    }
  }

  static (ProjectLocalStore, String, String) _scope(String key) {
    final parts = key.split('.');
    if (parts.length != 5 ||
        parts[0] != 'project_storage_v1' ||
        parts[3] != 'cart_draft') {
      throw ArgumentError('Invalid scoped draft key.');
    }
    String decode(String text) =>
        utf8.decode(base64Url.decode(base64Url.normalize(text)));
    final store = ProjectLocalStore(projectId: decode(parts[1]));
    final uid = decode(parts[2]);
    return (store, uid, key.substring(store.prefix(uid).length));
  }

  static void _validateKey(String key, CartDraftSnapshot draft) {
    if (_scope(key).$2 != draft.salesmanUid.trim()) {
      throw ArgumentError('Draft owner does not match its key.');
    }
  }

  static final Map<String, _OpenDraftWrite> _openWrites =
      <String, _OpenDraftWrite>{};

  static void _schedulePersist(String key, CartDraftSnapshot? draft) {
    final _OpenDraftWrite? open = _openWrites[key];
    if (open != null) {
      open.draft = draft;
      return;
    }
    final scope = _scope(key);
    final _OpenDraftWrite write = _OpenDraftWrite(draft);
    _openWrites[key] = write;
    final operation = _persistQueue.then((_) {
      if (identical(_openWrites[key], write)) _openWrites.remove(key);
      final CartDraftSnapshot? latest = write.draft;
      return latest == null
          ? scope.$1.remove(scope.$2, scope.$3)
          : scope.$1.write(scope.$2, scope.$3, _encodeDraft(latest));
    });
    _persistQueue = operation.catchError((Object _, StackTrace _) {});
  }

  static Future<void> _enqueuePersist(String key, CartDraftSnapshot? draft) {
    _openWrites.remove(key);
    final scope = _scope(key);
    final encoded = draft == null ? null : _encodeDraft(draft);
    final operation = _persistQueue.then(
      (_) => encoded == null
          ? scope.$1.remove(scope.$2, scope.$3)
          : scope.$1.write(scope.$2, scope.$3, encoded),
    );
    _persistQueue = operation.catchError((Object _, StackTrace _) {});
    return operation;
  }

  static Map<String, Map<String, dynamic>> _decodeSignatures(Object? raw) {
    if (raw is! Map) return <String, Map<String, dynamic>>{};
    return <String, Map<String, dynamic>>{
      for (final MapEntry<Object?, Object?> entry in raw.entries)
        if (entry.key is String && entry.value is Map)
          entry.key as String: Map<String, dynamic>.from(entry.value as Map),
    };
  }

  static String _encodeDraft(CartDraftSnapshot draft) => jsonEncode({
    'salesmanUid': draft.salesmanUid,
    'retailerId': draft.retailerId,
    if ((draft.visitId ?? '').isNotEmpty) 'visitId': draft.visitId,
    if (draft.progress != null) 'progress': draft.progress,
    if (draft.pendingOrderId.isNotEmpty) 'pendingOrderId': draft.pendingOrderId,
    'revision': draft.revision,
    'items': _jsonSafe(removeEmptyShelfBatches(draft.items)),
    'signatures': _jsonSafe(draft.signatures),
    if (draft.specialRequest != null)
      'specialRequest': _jsonSafe(draft.specialRequest),
  });

  static Object? _jsonSafe(Object? value) {
    if (value == null || value is String || value is num || value is bool) {
      return value;
    }
    if (value is DateTime) return value.toIso8601String();
    if (value is List) {
      return value
          .map(_jsonSafe)
          .where((Object? item) => item != null)
          .toList();
    }
    if (value is Map) {
      return <String, dynamic>{
        for (final MapEntry<Object?, Object?> entry in value.entries)
          if (entry.key is String && _jsonSafe(entry.value) != null)
            entry.key as String: _jsonSafe(entry.value),
      };
    }
    return null;
  }

  static Future<void> _migrateLegacy(ProjectLocalStore store) async {
    var complete = true;
    await ProjectLocalStore.locked('migration:$_storageKey', () async {
      final prefs = await SharedPreferences.getInstance();
      final raw = prefs.get(_storageKey);
      if (raw == null) return;
      final remaining = <String, Object?>{};
      try {
        final decoded = raw is String ? jsonDecode(raw) : null;
        if (decoded is! Map) throw const FormatException('Invalid cart cache');
        for (final entry in decoded.entries) {
          final value = entry.value;
          final owner = value is Map ? '${value['salesmanUid'] ?? ''}' : '';
          final identity = entry.key;
          if (owner.trim().isEmpty ||
              owner != owner.trim() ||
              identity is! String ||
              !identity.startsWith('${_safePart(owner)}|')) {
            complete = false;
            continue;
          }
          if (!store.isActive(owner)) {
            remaining[identity] = value;
            continue;
          }
          final name = 'cart_draft.${ProjectLocalStore.encode(identity)}';
          final encoded = jsonEncode(value);
          final existing = await store.read(owner, name);
          if (existing == null) {
            await store.write(owner, name, encoded);
          } else if (existing != encoded) {
            complete = false;
          }
        }
      } catch (_) {
        complete = false;
      }
      if (!complete) return;
      await prefs.reload();
      if (prefs.get(_storageKey) != raw) return;
      if (remaining.isEmpty) {
        await prefs.remove(_storageKey);
      } else if (remaining.length < (jsonDecode(raw as String) as Map).length) {
        await prefs.setString(_storageKey, jsonEncode(remaining));
      }
    });
    if (!complete) await ProjectLocalStore.recoverLegacyKey(_storageKey);
  }

  static String _safePart(String value) {
    final text = value.trim();
    if (text.isEmpty) return 'unknown';
    return text.replaceAll('|', '_');
  }
}
