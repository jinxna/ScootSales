part of 'staff_api_client.dart';

class StaffStepButton {
  const StaffStepButton({
    required this.id,
    required this.label,
    required this.roles,
  });

  factory StaffStepButton.fromJson(Map<String, Object?> json) =>
      StaffStepButton(
        id: _requiredText(json, 'id'),
        label: _requiredText(json, 'label'),
        roles: _textList(json['roles']),
      );

  final String id, label;
  final List<String> roles;
}

class StaffOnboardingStep {
  const StaffOnboardingStep({
    required this.n,
    required this.key,
    required this.label,
    required this.state,
    required this.unknown,
    required this.fact,
    required this.checkedAt,
    required this.button,
    this.operationId,
  });

  factory StaffOnboardingStep.fromJson(Map<String, Object?> json) {
    final Object? button = json['button'];
    return StaffOnboardingStep(
      n: json['n'] is int ? json['n']! as int : 0,
      key: _requiredText(json, 'key'),
      label: _requiredText(json, 'label'),
      state: _requiredText(json, 'state'),
      unknown: json['unknown'] == true,
      fact: json['fact'] is String ? json['fact']! as String : '',
      checkedAt: _optionalText(json, 'checkedAt'),
      button: button is Map
          ? StaffStepButton.fromJson(_objectMap(button))
          : null,
      operationId: _optionalText(json, 'operationId'),
    );
  }

  final int n;
  final String key, label, state, fact;
  final bool unknown;
  final String? checkedAt, operationId;
  final StaffStepButton? button;

  bool get isGreen => state == 'green';
  bool get isRed => state == 'red';
}

class StaffOnboardingDraft {
  const StaffOnboardingDraft({
    required this.draftId,
    required this.status,
    required this.phase,
    required this.legalName,
    required this.workspace,
    required this.kind,
    required this.planId,
    required this.billingInterval,
    required this.billingEmail,
    required this.adminName,
    required this.adminEmail,
    required this.adminEmployeeCode,
    required this.createdBy,
    required this.createdAt,
    required this.endsAt,
    required this.canExtend,
    required this.tenantId,
    required this.lifecycleState,
    required this.steps,
    required this.doneCount,
    required this.total,
    required this.nextStepKey,
  });

  factory StaffOnboardingDraft.fromJson(Map<String, Object?> json) {
    String? text(String key) =>
        json[key] is String ? json[key] as String : null;
    final Object? rows = json['steps'];
    if (rows is! List) throw const FormatException('Invalid steps.');
    final Object? next = json['next'];
    return StaffOnboardingDraft(
      draftId: _requiredText(json, 'draftId'),
      status: _requiredText(json, 'status'),
      phase: text('phase') ?? 'setup',
      legalName: _requiredText(json, 'legalName'),
      workspace: _requiredText(json, 'workspace'),
      kind: text('kind'),
      planId: text('planId'),
      billingInterval: text('billingInterval'),
      billingEmail: text('billingEmail'),
      adminName: text('adminName'),
      adminEmail: text('adminEmail'),
      adminEmployeeCode: text('adminEmployeeCode'),
      createdBy: _requiredText(json, 'createdBy'),
      createdAt: _requiredText(json, 'createdAt'),
      endsAt: _requiredText(json, 'endsAt'),
      canExtend: json['canExtend'] == true,
      tenantId: text('tenantId'),
      lifecycleState: text('lifecycleState'),
      steps: rows
          .map((Object? row) => StaffOnboardingStep.fromJson(_objectMap(row)))
          .toList(growable: false),
      doneCount: json['doneCount'] is int ? json['doneCount']! as int : 0,
      total: json['total'] is int ? json['total']! as int : rows.length,
      nextStepKey: next is Map && next['key'] is String
          ? next['key']! as String
          : null,
    );
  }

  final String draftId, status, phase, legalName, workspace, createdBy;
  final String createdAt, endsAt;
  final String? kind, planId, billingInterval, billingEmail;
  final String? adminName, adminEmail, adminEmployeeCode;
  final String? tenantId, lifecycleState, nextStepKey;
  final bool canExtend;
  final List<StaffOnboardingStep> steps;
  final int doneCount, total;

  bool get isOpen => status == 'open';
  bool get isSetup => phase == 'setup';
  bool get isWorking => phase == 'working';
  bool get isEnded => phase == 'ended';

  StaffOnboardingStep? step(String key) =>
      steps.where((StaffOnboardingStep s) => s.key == key).firstOrNull;

  StaffOnboardingStep? get nextStep =>
      nextStepKey == null ? null : step(nextStepKey!);
}

class StaffConnectPart {
  const StaffConnectPart({
    required this.key,
    required this.label,
    required this.state,
  });

  final String key, label, state;
}

class StaffConnectResult {
  const StaffConnectResult({
    required this.ok,
    required this.kind,
    required this.summary,
    required this.parts,
    required this.refusal,
    required this.fallback,
    required this.retryLater,
  });

  factory StaffConnectResult.fromJson(Map<String, Object?> json) {
    final Object? parts = json['parts'];
    final Object? fallback = json['fallback'];
    return StaffConnectResult(
      ok: json['ok'] == true,
      kind: json['kind'] is String ? json['kind']! as String : null,
      summary: json['summary'] is String ? json['summary']! as String : null,
      parts: parts is List
          ? parts
                .whereType<Map<Object?, Object?>>()
                .map((Map<Object?, Object?> row) {
                  final Map<String, Object?> part = _objectMap(row);
                  return StaffConnectPart(
                    key: _requiredText(part, 'key'),
                    label: _requiredText(part, 'label'),
                    state: _requiredText(part, 'state'),
                  );
                })
                .toList(growable: false)
          : const <StaffConnectPart>[],
      refusal: json['refusal'] is String ? json['refusal']! as String : null,
      fallback: fallback is String
          ? fallback
          : fallback is Map && fallback['text'] is String
          ? fallback['text']! as String
          : null,
      retryLater: json['retryLater'] == true,
    );
  }

  final bool ok, retryLater;
  final String? kind, summary, refusal, fallback;
  final List<StaffConnectPart> parts;
}

class StaffPeopleFix {
  const StaffPeopleFix({required this.id, required this.label});

  final String id, label;
}

class StaffPeopleDefect {
  const StaffPeopleDefect({
    required this.id,
    required this.employeeCode,
    required this.name,
    required this.defect,
    required this.text,
    required this.fixes,
  });

  factory StaffPeopleDefect.fromJson(Map<String, Object?> json) {
    final Object? fixes = json['fixes'];
    return StaffPeopleDefect(
      id: _requiredText(json, 'id'),
      employeeCode: _optionalText(json, 'employeeCode'),
      name: _optionalText(json, 'name'),
      defect: _requiredText(json, 'defect'),
      text: json['text'] is String ? json['text']! as String : '',
      fixes: fixes is List
          ? fixes
                .whereType<Map<Object?, Object?>>()
                .map((Map<Object?, Object?> row) {
                  final Map<String, Object?> fix = _objectMap(row);
                  return StaffPeopleFix(
                    id: _requiredText(fix, 'id'),
                    label: _requiredText(fix, 'label'),
                  );
                })
                .toList(growable: false)
          : const <StaffPeopleFix>[],
    );
  }

  final String id, defect, text;
  final String? employeeCode, name;
  final List<StaffPeopleFix> fixes;
}

class StaffArchivedRow {
  const StaffArchivedRow({
    required this.id,
    required this.employeeCode,
    required this.reason,
    required this.archivedBy,
  });

  factory StaffArchivedRow.fromJson(Map<String, Object?> json) =>
      StaffArchivedRow(
        id: _requiredText(json, 'id'),
        employeeCode: _optionalText(json, 'employeeCode'),
        reason: _optionalText(json, 'reason'),
        archivedBy: _optionalText(json, 'archivedBy'),
      );

  final String id;
  final String? employeeCode, reason, archivedBy;
}

class StaffPeopleReport {
  const StaffPeopleReport({required this.items, required this.archived});

  factory StaffPeopleReport.fromJson(Map<String, Object?> json) {
    final Object? items = json['items'];
    final Object? archived = json['archived'];
    if (items is! List) throw const FormatException('Invalid people list.');
    return StaffPeopleReport(
      items: items
          .map((Object? row) => StaffPeopleDefect.fromJson(_objectMap(row)))
          .toList(growable: false),
      archived: archived is List
          ? archived
                .map(
                  (Object? row) => StaffArchivedRow.fromJson(_objectMap(row)),
                )
                .toList(growable: false)
          : const <StaffArchivedRow>[],
    );
  }

  final List<StaffPeopleDefect> items;
  final List<StaffArchivedRow> archived;
}

extension StaffOnboardingApi on StaffApiClient {
  Future<List<StaffOnboardingDraft>> onboardingDrafts() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['onboarding-drafts'])),
    )['drafts'];
    if (rows is! List) throw const FormatException('Invalid drafts.');
    return rows
        .map((Object? row) => StaffOnboardingDraft.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffOnboardingDraft> createOnboardingDraft(
    Map<String, Object?> body, {
    required String key,
  }) async => StaffOnboardingDraft.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['onboarding-drafts']),
        body: body,
        key: key,
      ),
    ),
  );

  Future<StaffOnboardingDraft> updateOnboardingDraft(
    String draftId,
    Map<String, Object?> body,
  ) async => StaffOnboardingDraft.fromJson(
    _objectMap(
      await _send(
        'PUT',
        _uri(<String>['onboarding-drafts', draftId]),
        body: body,
      ),
    ),
  );

  Future<StaffOnboardingDraft> cancelOnboardingDraft(String draftId) async =>
      StaffOnboardingDraft.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['onboarding-drafts', draftId, 'cancel']),
          ),
        ),
      );

  Future<StaffOnboardingDraft> extendOnboardingDraft(String draftId) async =>
      StaffOnboardingDraft.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['onboarding-drafts', draftId, 'extend']),
          ),
        ),
      );

  Future<String?> projectServiceEmail() async {
    final Map<String, Object?> body = _objectMap(
      await _send('GET', _uri(<String>['project-access'])),
    );
    return _optionalText(body, 'serviceEmail');
  }

  Future<StaffConnectResult> checkProject(
    String draftId,
    String projectId,
  ) async => StaffConnectResult.fromJson(
    _objectMap(
      await _send(
        'GET',
        _uri(<String>[
          'onboarding-drafts',
          draftId,
          'connect',
        ]).replace(queryParameters: <String, String>{'projectId': projectId}),
      ),
    ),
  );

  Future<StaffConnectResult> connectProject(
    String draftId,
    String projectId,
  ) async {
    try {
      return StaffConnectResult.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['onboarding-drafts', draftId, 'connect']),
            body: <String, Object?>{'projectId': projectId},
          ),
        ),
      );
    } on StaffApiException catch (error) {
      final Map<Object?, Object?>? body = error.body;
      if (error.statusCode == 409 && body != null && body['parts'] is List) {
        return StaffConnectResult.fromJson(_objectMap(body));
      }
      rethrow;
    }
  }

  Future<StaffPeopleReport> peopleDefects(String tenantId) async =>
      StaffPeopleReport.fromJson(
        _objectMap(
          await _send(
            'GET',
            _uri(<String>['companies', tenantId, 'people-defects']),
          ),
        ),
      );

  Future<Map<String, Object?>> previewPeopleFix(
    String tenantId,
    String itemId,
    String fixId,
  ) async => _objectMap(
    await _send(
      'POST',
      _uri(<String>['companies', tenantId, 'people-fixes']),
      body: <String, Object?>{'itemId': itemId, 'fixId': fixId},
    ),
  );

  Future<void> applyPeopleFix(
    String tenantId,
    String itemId,
    String fixId,
    Map<String, Object?> preview,
  ) async {
    await _send(
      'POST',
      _uri(<String>['companies', tenantId, 'people-fixes']),
      body: <String, Object?>{
        'itemId': itemId,
        'fixId': fixId,
        'apply': true,
        'expected': preview,
      },
    );
  }

  Future<void> restorePeopleRow(String tenantId, String archiveId) async {
    await _send(
      'POST',
      _uri(<String>['companies', tenantId, 'people-restore']),
      body: <String, Object?>{'archiveId': archiveId},
    );
  }

  Future<void> giveFirstAdminAccess(String draftId) async {
    await _send(
      'POST',
      _uri(<String>['onboarding-drafts', draftId, 'first-admin']),
      body: const <String, Object?>{},
    );
  }

  Future<Map<String, Object?>> promoteFirstAdmin(
    String draftId,
    String employeeCode, {
    Map<String, Object?>? expectedRow,
  }) async => _objectMap(
    await _send(
      'POST',
      _uri(<String>['onboarding-drafts', draftId, 'first-admin', 'promote']),
      body: <String, Object?>{
        'employeeCode': employeeCode,
        'expectedRow': ?expectedRow,
      },
    ),
  );

  Future<void> resendFirstAdminInvitation(String draftId) async {
    await _send(
      'POST',
      _uri(<String>['onboarding-drafts', draftId, 'first-admin', 'resend']),
    );
  }
}
