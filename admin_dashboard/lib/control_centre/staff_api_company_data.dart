part of 'staff_api_client.dart';

class StaffPackageFit {
  const StaffPackageFit({
    required this.planId,
    required this.name,
    required this.fits,
    required this.exceeded,
  });

  factory StaffPackageFit.fromJson(Map<String, Object?> json) =>
      StaffPackageFit(
        planId: _requiredText(json, 'planId'),
        name: _requiredText(json, 'name'),
        fits: _requiredBool(json, 'fits'),
        exceeded: _textList(json['exceeded']),
      );

  final String planId, name;
  final bool fits;
  final List<String> exceeded;
}

class StaffPrepareReport {
  const StaffPrepareReport({
    required this.counts,
    required this.accessRecords,
    required this.profiles,
    required this.prepared,
    required this.ready,
    required this.blockers,
    required this.notes,
    required this.currentPlanId,
    required this.fit,
  });

  factory StaffPrepareReport.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> counts = _objectMap(json['counts']);
    final Map<String, Object?> changes = _objectMap(json['changes']);
    final Object? fit = json['fit'];
    if (fit is! List) throw const FormatException('Invalid fit.');
    return StaffPrepareReport(
      counts: <String, int>{
        for (final MapEntry<String, Object?> entry in counts.entries)
          entry.key: entry.value is int ? entry.value! as int : 0,
      },
      accessRecords: changes['accessRecords'] is int
          ? changes['accessRecords']! as int
          : 0,
      profiles: changes['profiles'] is int ? changes['profiles']! as int : 0,
      prepared: _requiredBool(json, 'prepared'),
      ready: _requiredBool(json, 'ready'),
      blockers: _textList(json['blockers']),
      notes: _textList(json['notes']),
      currentPlanId: json['currentPlanId'] is String
          ? json['currentPlanId']! as String
          : null,
      fit: fit
          .map((Object? row) => StaffPackageFit.fromJson(_objectMap(row)))
          .toList(growable: false),
    );
  }

  final Map<String, int> counts;
  final int accessRecords, profiles;
  final bool prepared, ready;
  final List<String> blockers, notes;
  final String? currentPlanId;
  final List<StaffPackageFit> fit;
}

List<String> _textList(Object? value) {
  if (value is! List) throw const FormatException('Invalid list.');
  return value.whereType<String>().toList(growable: false);
}

const Set<String> _packageContent = <String>{
  'quotaSchemaVersion',
  'features',
  'prices',
  'tagline',
  'highlights',
  'sortOrder',
  'notes',
};

extension StaffCompanyDataApi on StaffApiClient {
  Future<StaffPrepareReport> prepareData(
    String tenantId, {
    required bool apply,
    bool resume = false,
  }) async => StaffPrepareReport.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['companies', tenantId, 'prepare-data']),
        body: <String, Object?>{if (resume) 'resume': true else 'apply': apply},
      ),
    ),
  );

  Future<StaffOperationOutcome> savePackage(
    String planId, {
    required bool isNew,
    required String name,
    required String edition,
    required Map<String, int?> limits,
    required String reason,
    required String key,
  }) async {
    final Map<String, Object?> base = isNew
        ? <String, Object?>{
            'quotaSchemaVersion': 2,
            'features': <String, Object?>{},
            'prices': <String, Object?>{
              'currency': 'MYR',
              'monthly': null,
              'yearly': null,
            },
          }
        : <String, Object?>{
            for (final MapEntry<String, Object?> entry
                in (await _currentVersion(planId)).entries)
              if (_packageContent.contains(entry.key)) entry.key: entry.value,
          };
    return StaffOperationOutcome.fromJson(
      _objectMap(
        await _send(
          'PUT',
          _uri(<String>['plans', planId]),
          body: <String, Object?>{
            ...base,
            'name': name,
            'edition': edition,
            'limits': limits,
            'reason': reason,
          },
          key: key,
        ),
      ),
    );
  }
}
