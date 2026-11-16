import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';

const String scoreSheetTemplateKind = 'template';
const String scoreSheetAssignmentKind = 'assignment';

class ScoreSheetTemplate {
  const ScoreSheetTemplate({
    required this.docId,
    required this.templateId,
    required this.revision,
    required this.name,
    required this.productIds,
    this.sourceRetailerName = '',
    this.copiedFromName = '',
    this.copiedFromRevision,
    this.status = 'active',
  });

  factory ScoreSheetTemplate.fromDoc(String docId, Map<String, dynamic> data) {
    return ScoreSheetTemplate(
      docId: docId,
      templateId: _text(data['templateId']),
      revision: _int(data['revision']),
      name: _text(data['name']),
      productIds: _textList(data['productIds']),
      sourceRetailerName: _text(data['sourceRetailerName']),
      copiedFromName: _text(data['copiedFromName']),
      copiedFromRevision: data['copiedFromRevision'] is num
          ? (data['copiedFromRevision'] as num).toInt()
          : null,
      status: _text(data['status']).isEmpty ? 'active' : _text(data['status']),
    );
  }

  final String docId;
  final String templateId;
  final int revision;
  final String name;
  final List<String> productIds;
  final String sourceRetailerName;
  final String copiedFromName;
  final int? copiedFromRevision;
  final String status;
}

class ScoreSheetAssignmentEvent {
  const ScoreSheetAssignmentEvent({
    required this.docId,
    required this.assignmentId,
    required this.assignmentRevision,
    required this.templateId,
    required this.templateRevision,
    required this.templateName,
    required this.salesmanUid,
    required this.salesmanName,
    required this.retailerId,
    required this.retailerName,
    required this.productIds,
    this.previousSalesmanName = '',
    this.createdAt,
  });

  factory ScoreSheetAssignmentEvent.fromDoc(
    String docId,
    Map<String, dynamic> data,
  ) {
    final Object? createdAt = data['createdAt'];
    return ScoreSheetAssignmentEvent(
      docId: docId,
      assignmentId: _text(data['assignmentId']),
      assignmentRevision: _int(data['assignmentRevision']),
      templateId: _text(data['templateId']),
      templateRevision: _int(data['templateRevision']),
      templateName: _text(data['templateName']),
      salesmanUid: _text(data['salesmanUid']),
      salesmanName: _text(data['salesmanName']),
      retailerId: _text(data['retailerId']),
      retailerName: _text(data['retailerName']),
      productIds: _textList(data['productIds']),
      previousSalesmanName: _text(data['previousSalesmanName']),
      createdAt: createdAt is Timestamp ? createdAt.toDate() : null,
    );
  }

  final String docId;
  final String assignmentId;
  final int assignmentRevision;
  final String templateId;
  final int templateRevision;
  final String templateName;
  final String salesmanUid;
  final String salesmanName;
  final String retailerId;
  final String retailerName;
  final List<String> productIds;
  final String previousSalesmanName;
  final DateTime? createdAt;
}

class ScoreSheetSalesperson {
  const ScoreSheetSalesperson({
    required this.uid,
    required this.name,
    required this.code,
  });

  final String uid;
  final String name;
  final String code;
}

class ScoreSheetLibrarySnapshot {
  const ScoreSheetLibrarySnapshot({
    required this.templates,
    required this.events,
  });

  final List<ScoreSheetTemplate> templates;
  final List<ScoreSheetAssignmentEvent> events;

  List<ScoreSheetAssignmentEvent> get currentAssignments {
    final Map<String, ScoreSheetAssignmentEvent> latest =
        <String, ScoreSheetAssignmentEvent>{};
    for (final ScoreSheetAssignmentEvent event in events) {
      final ScoreSheetAssignmentEvent? known = latest[event.assignmentId];
      if (known == null ||
          event.assignmentRevision > known.assignmentRevision) {
        latest[event.assignmentId] = event;
      }
    }
    return latest.values.toList(growable: false);
  }

  List<ScoreSheetAssignmentEvent> currentAssignmentsFor(String templateId) =>
      currentAssignments
          .where((ScoreSheetAssignmentEvent e) => e.templateId == templateId)
          .toList(growable: false);
}

class ScoreSheetTemplateService {
  ScoreSheetTemplateService({FirebaseFirestore? firestore})
    : _firestore = firestore ?? FirebaseFirestore.instance;

  final FirebaseFirestore _firestore;

  CollectionReference<Map<String, dynamic>> get _sheets =>
      _firestore.collection('score_sheets');

  Stream<ScoreSheetLibrarySnapshot> watchLibrary() {
    return _sheets
        .where(
          'kind',
          whereIn: <String>[scoreSheetTemplateKind, scoreSheetAssignmentKind],
        )
        .snapshots(includeMetadataChanges: true)
        .map((QuerySnapshot<Map<String, dynamic>> snapshot) {
          final List<ScoreSheetTemplate> templates = <ScoreSheetTemplate>[];
          final List<ScoreSheetAssignmentEvent> events =
              <ScoreSheetAssignmentEvent>[];
          for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
              in snapshot.docs) {
            if (doc.metadata.hasPendingWrites) continue;
            final Map<String, dynamic> data = doc.data();
            if (data['kind'] == scoreSheetTemplateKind) {
              templates.add(ScoreSheetTemplate.fromDoc(doc.id, data));
            } else {
              events.add(ScoreSheetAssignmentEvent.fromDoc(doc.id, data));
            }
          }
          final Map<String, ScoreSheetTemplate> latest =
              <String, ScoreSheetTemplate>{};
          for (final ScoreSheetTemplate template in templates) {
            final ScoreSheetTemplate? known = latest[template.templateId];
            if (known == null || template.revision > known.revision) {
              latest[template.templateId] = template;
            }
          }
          templates
            ..clear()
            ..addAll(
              latest.values.where(
                (ScoreSheetTemplate template) => template.status != 'retired',
              ),
            );
          templates.sort(
            (ScoreSheetTemplate a, ScoreSheetTemplate b) =>
                a.name.toLowerCase().compareTo(b.name.toLowerCase()),
          );
          events.sort((
            ScoreSheetAssignmentEvent a,
            ScoreSheetAssignmentEvent b,
          ) {
            final DateTime aTime = a.createdAt ?? DateTime(9999);
            final DateTime bTime = b.createdAt ?? DateTime(9999);
            final int byTime = bTime.compareTo(aTime);
            if (byTime != 0) return byTime;
            return b.assignmentRevision.compareTo(a.assignmentRevision);
          });
          return ScoreSheetLibrarySnapshot(
            templates: templates,
            events: events,
          );
        });
  }

  Future<void> createTemplate({
    required String name,
    required List<String> productIds,
    String sourceRetailerId = '',
    String sourceRetailerName = '',
    ScoreSheetTemplate? copiedFrom,
  }) => _createRevision(
    templateId: 'tpl_${_sheets.doc().id}',
    revision: 1,
    name: name,
    productIds: productIds,
    sourceRetailerId: sourceRetailerId,
    sourceRetailerName: sourceRetailerName,
    extra: copiedFrom == null
        ? const <String, dynamic>{}
        : <String, dynamic>{
            'copiedFromTemplateId': copiedFrom.templateId,
            'copiedFromRevision': copiedFrom.revision,
            'copiedFromName': copiedFrom.name,
          },
  );

  Future<void> createNextRevision({
    required ScoreSheetTemplate template,
    required List<String> productIds,
    String sourceRetailerId = '',
    String sourceRetailerName = '',
  }) => _createRevision(
    templateId: template.templateId,
    revision: template.revision + 1,
    name: template.name,
    productIds: productIds,
    sourceRetailerId: sourceRetailerId,
    sourceRetailerName: sourceRetailerName,
    extra: <String, dynamic>{'previousRevision': template.revision},
  );

  Future<void> _createRevision({
    required String templateId,
    required int revision,
    required String name,
    required List<String> productIds,
    required String sourceRetailerId,
    required String sourceRetailerName,
    required Map<String, dynamic> extra,
  }) async {
    final List<String> sortedIds = productIds.toSet().toList()..sort();
    if (sortedIds.isEmpty) {
      throw StateError('A template needs at least one product.');
    }
    final DocumentReference<Map<String, dynamic>> ref = _sheets.doc(
      '${templateId}_r$revision',
    );
    await _firestore.runTransaction<void>((Transaction transaction) async {
      if ((await transaction.get(ref)).exists) {
        throw StateError(
          'Someone else saved this template version first. Reopen the library and try again.',
        );
      }
      transaction.set(ref, <String, dynamic>{
        'kind': scoreSheetTemplateKind,
        'templateId': templateId,
        'revision': revision,
        'name': name,
        'productIds': sortedIds,
        'productCount': sortedIds.length,
        'status': 'active',
        if (sourceRetailerId.isNotEmpty) 'sourceRetailerId': sourceRetailerId,
        if (sourceRetailerName.isNotEmpty)
          'sourceRetailerName': sourceRetailerName,
        ...extra,
        'createdByUid': _actorUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  Future<void> retireTemplate(ScoreSheetTemplate template) =>
      _sheets.doc(template.docId).update(<String, dynamic>{
        'status': 'retired',
        'retiredAt': FieldValue.serverTimestamp(),
        'retiredByUid': _actorUid,
      });

  Future<void> assign({
    required ScoreSheetTemplate template,
    required ScoreSheetSalesperson salesperson,
    required String retailerId,
    required String retailerName,
  }) async {
    final String assignmentId = 'asg_${_sheets.doc().id}';
    await _appendAssignmentEvent(<String, dynamic>{
      'assignmentId': assignmentId,
      'assignmentRevision': 1,
      'templateId': template.templateId,
      'templateRevision': template.revision,
      'templateName': template.name,
      'productIds': template.productIds,
      'retailerId': retailerId,
      'retailerName': retailerName,
      'event': 'assigned',
    }, salesperson);
  }

  Future<void> reassign({
    required ScoreSheetAssignmentEvent current,
    required ScoreSheetSalesperson salesperson,
  }) async {
    await _appendAssignmentEvent(<String, dynamic>{
      'assignmentId': current.assignmentId,
      'assignmentRevision': current.assignmentRevision + 1,
      'templateId': current.templateId,
      'templateRevision': current.templateRevision,
      'templateName': current.templateName,
      'productIds': current.productIds,
      'retailerId': current.retailerId,
      'retailerName': current.retailerName,
      'event': 'reassigned',
      'previousSalesmanUid': current.salesmanUid,
      'previousSalesmanName': current.salesmanName,
    }, salesperson);
  }

  Future<void> _appendAssignmentEvent(
    Map<String, dynamic> event,
    ScoreSheetSalesperson salesperson,
  ) async {
    final List<String> productIds =
        (event['productIds'] as List<String>).toSet().toList()..sort();
    if (productIds.isEmpty) {
      throw StateError(
        'This template has no products. An empty list would show every product on mobile.',
      );
    }
    final String assignmentId = event['assignmentId'] as String;
    final int revision = event['assignmentRevision'] as int;
    final String retailerId = event['retailerId'] as String;
    final DocumentReference<Map<String, dynamic>> eventRef = _sheets.doc(
      '${assignmentId}_r$revision',
    );
    final DocumentReference<Map<String, dynamic>> retailerSheetRef = _firestore
        .collection('retailer_score_sheet_settings')
        .doc(retailerId);
    await _firestore.runTransaction<void>((Transaction transaction) async {
      final DocumentSnapshot<Map<String, dynamic>> existing = await transaction
          .get(eventRef);
      if (existing.exists) {
        throw StateError(
          'This assignment was changed by someone else. Reopen the library and try again.',
        );
      }
      final DocumentSnapshot<Map<String, dynamic>> sheet = await transaction
          .get(retailerSheetRef);
      final Map<String, dynamic> current = sheet.data() ?? <String, dynamic>{};
      final Set<String> templateIds = productIds.toSet();
      List<String> without(Object? raw) => _textList(
        raw,
      ).where((String id) => !templateIds.contains(id)).toList(growable: false);
      final Map<String, dynamic> overrides = current['productOverrides'] is Map
          ? Map<String, dynamic>.from(current['productOverrides'] as Map)
          : <String, dynamic>{};
      for (final String id in productIds) {
        final Object? override = overrides[id];
        if (override is Map && override['isVisible'] == false) {
          overrides[id] = <String, dynamic>{
            ...Map<String, dynamic>.from(override),
            'isVisible': true,
          };
        }
      }

      transaction.set(eventRef, <String, dynamic>{
        ...event,
        'kind': scoreSheetAssignmentKind,
        'productIds': productIds,
        'productCount': productIds.length,
        'salesmanUid': salesperson.uid,
        'salesmanName': salesperson.name,
        'salesmanCode': salesperson.code,
        'createdByUid': _actorUid,
        'createdAt': FieldValue.serverTimestamp(),
      });
      transaction.set(retailerSheetRef, <String, dynamic>{
        ...current,
        'retailerId': retailerId,
        'retailerName': event['retailerName'],
        'scoreSheetId': current['scoreSheetId'] ?? 'default',
        'sheetName':
            current['sheetName'] ?? '${event['retailerName']} Score Sheet',
        'visibleProductIds': productIds,
        'hiddenProductIds': without(current['hiddenProductIds']),
        'disabledProductIds': without(current['disabledProductIds']),
        'productOverrides': overrides,
        'productCount': productIds.length,
        'visibleProductCount': productIds.length,
        'appliedTemplateId': event['templateId'],
        'appliedTemplateRevision': event['templateRevision'],
        'appliedTemplateName': event['templateName'],
        'appliedAssignmentId': assignmentId,
        'appliedAssignmentRevision': revision,
        'appliedSalesmanUid': salesperson.uid,
        'updatedAt': FieldValue.serverTimestamp(),
        if (!sheet.exists) 'createdAt': FieldValue.serverTimestamp(),
      });
    });
  }

  String get _actorUid => FirebaseAuth.instance.currentUser?.uid ?? '';
}

String _text(Object? value) {
  final String text = '${value ?? ''}'.trim();
  return text == 'null' ? '' : text;
}

int _int(Object? value) => value is num ? value.toInt() : 0;

List<String> _textList(Object? value) => value is List
    ? value
          .map(_text)
          .where((String id) => id.isNotEmpty)
          .toList(growable: false)
    : const <String>[];
