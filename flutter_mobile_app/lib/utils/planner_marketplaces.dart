library;

import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../models/assigned_route_plan.dart';
import 'demo_data.dart';

List<String> salesmanAssignmentIdentities({
  required String staffId,
  required String uid,
}) {
  return <String>{
    staffId.trim(),
    uid.trim(),
  }.where((String value) => value.isNotEmpty).toList(growable: false);
}

const List<String> kRetailerAssignmentSingleFields = <String>[
  'assignedSalesmanId',
  'assignedSalesmanCode',
  'assignedSalesmanUid',
  'salesmanId',
  'salesmanCode',
];

const List<String> kRetailerAssignmentListFields = <String>[
  'assignedSalesmanCodes',
  'assignedUsers',
  'assignedSalesmen',
];

const String kRetailerReadRefusedMessage =
    'Your account cannot read these retailers. Ask your admin to set your '
    'branch or assign the retailers to you.';

class RetailerAssignmentQuery {
  const RetailerAssignmentQuery({
    required this.field,
    required this.value,
    required this.isList,
    this.branchId = '',
  });

  final String field;

  final String value;

  final bool isList;

  final String branchId;

  Query<Map<String, dynamic>> apply(Query<Map<String, dynamic>> retailers) {
    final Query<Map<String, dynamic>> scoped = branchId.isEmpty
        ? retailers
        : retailers.where('branchId', isEqualTo: branchId);
    return isList
        ? scoped.where(field, arrayContains: value)
        : scoped.where(field, isEqualTo: value);
  }
}

List<RetailerAssignmentQuery> retailerAssignmentQueries({
  required String staffId,
  required String uid,
  String branchId = '',
}) {
  final String branch = branchId.trim();
  final List<RetailerAssignmentQuery> queries = <RetailerAssignmentQuery>[];
  for (final String identity in salesmanAssignmentIdentities(
    staffId: staffId,
    uid: uid,
  )) {
    for (final String field in kRetailerAssignmentSingleFields) {
      if (field == 'assignedSalesmanId') {
        queries.add(
          RetailerAssignmentQuery(field: field, value: identity, isList: false),
        );
      } else if (branch.isNotEmpty) {
        queries.add(
          RetailerAssignmentQuery(
            field: field,
            value: identity,
            isList: false,
            branchId: branch,
          ),
        );
      }
    }
    if (branch.isEmpty) continue;
    for (final String field in kRetailerAssignmentListFields) {
      queries.add(
        RetailerAssignmentQuery(
          field: field,
          value: identity,
          isList: true,
          branchId: branch,
        ),
      );
    }
  }
  return queries;
}

bool isRetailerReadRefused(Object error) =>
    error is FirebaseException && error.code == 'permission-denied';

String? assignedMarketplaceName(Map<String, dynamic> data, String docId) {
  if (!isOperationalRetailerRecord(<String, dynamic>{
    ...data,
    'docId': docId,
  })) {
    return null;
  }
  return _usableMarketplaceName(data['retailerName'] ?? data['name'] ?? docId);
}

Set<String> plannerMarketplaces({
  Iterable<Map<String, dynamic>> assignedRetailerRows =
      const <Map<String, dynamic>>[],
  Iterable<AssignedRoutePlan> assignedPlans = const <AssignedRoutePlan>[],
}) {
  final Set<String> names = <String>{};
  for (final Map<String, dynamic> row in assignedRetailerRows) {
    final String docId =
        '${row['docId'] ?? row['retailerId'] ?? row['id'] ?? ''}'.trim();
    final String? name = assignedMarketplaceName(row, docId);
    if (name != null) names.add(name);
  }
  for (final AssignedRoutePlan plan in assignedPlans) {
    for (final AssignedRouteDay day in plan.days) {
      for (final AssignedRouteStop stop in day.stops) {
        final String? name = _usableMarketplaceName(stop.retailerName);
        if (name != null) names.add(name);
      }
    }
  }
  return names;
}

Stream<List<Map<String, dynamic>>> watchAssignedRetailers({
  required FirebaseFirestore firestore,
  required String staffId,
  required String uid,
  String branchId = '',
  ValueNotifier<bool>? partlyRefused,
}) {
  final List<RetailerAssignmentQuery> queries = retailerAssignmentQueries(
    staffId: staffId,
    uid: uid,
    branchId: branchId,
  );
  if (queries.isEmpty) {
    return Stream<List<Map<String, dynamic>>>.value(
      const <Map<String, dynamic>>[],
    );
  }

  final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
  subscriptions = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];
  final Map<String, Map<String, Map<String, dynamic>>> rowsByQuery =
      <String, Map<String, Map<String, dynamic>>>{};
  final Set<String> refusedQueries = <String>{};
  String keyFor(RetailerAssignmentQuery query) =>
      '${query.field}|${query.value}|${query.isList}|${query.branchId}';
  final int queryCount = queries.map(keyFor).toSet().length;
  late final StreamController<List<Map<String, dynamic>>> controller;

  void emit() {
    final Map<String, Map<String, dynamic>> merged =
        <String, Map<String, dynamic>>{};
    for (final Map<String, Map<String, dynamic>> rows in rowsByQuery.values) {
      merged.addAll(rows);
    }
    if (merged.isEmpty && refusedQueries.isNotEmpty) {
      if (rowsByQuery.length == queryCount && !controller.isClosed) {
        controller.addError(kRetailerReadRefusedMessage);
      }
      return;
    }
    partlyRefused?.value = refusedQueries.isNotEmpty;
    final List<Map<String, dynamic>> result = merged.values.toList()
      ..sort(
        (Map<String, dynamic> a, Map<String, dynamic> b) =>
            '${a['retailerName'] ?? a['docId']}'.compareTo(
              '${b['retailerName'] ?? b['docId']}',
            ),
      );
    if (!controller.isClosed) controller.add(result);
  }

  controller = StreamController<List<Map<String, dynamic>>>(
    onListen: () {
      for (final RetailerAssignmentQuery query in queries) {
        final String cacheKey = keyFor(query);
        final Query<Map<String, dynamic>> filtered = query.apply(
          firestore.collection('retailers'),
        );
        subscriptions.add(
          filtered
              .limit(1000)
              .snapshots()
              .listen(
                (QuerySnapshot<Map<String, dynamic>> snapshot) {
                  rowsByQuery[cacheKey] = <String, Map<String, dynamic>>{
                    for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
                        in snapshot.docs)
                      doc.id: <String, dynamic>{...doc.data(), 'docId': doc.id},
                  };
                  emit();
                },
                onError: (Object error) {
                  if (!isRetailerReadRefused(error)) return;
                  refusedQueries.add(cacheKey);
                  rowsByQuery[cacheKey] = <String, Map<String, dynamic>>{};
                  emit();
                },
              ),
        );
      }
    },
    onCancel: () async {
      for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>>
          subscription
          in subscriptions) {
        await subscription.cancel();
      }
      subscriptions.clear();
    },
  );
  return controller.stream;
}

String? _usableMarketplaceName(Object? raw) {
  final String name = (raw ?? '').toString().trim();
  if (name.isEmpty) return null;
  final String lower = name.toLowerCase();
  if (lower == 'null' || lower == 'retailer' || lower == 'unknown') return null;
  return name;
}
