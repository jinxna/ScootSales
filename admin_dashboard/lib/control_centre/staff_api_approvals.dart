part of 'staff_api_client.dart';

class StaffApproval {
  const StaffApproval({
    required this.approvalId,
    required this.action,
    required this.status,
    required this.requestedBy,
    required this.reason,
    required this.summary,
    required this.createdAt,
    required this.params,
    required this.canDecide,
    required this.canReject,
    this.canClose = false,
    this.appliedSteps = const <String>[],
    this.tenantId,
    this.companyName,
    this.expiresAt,
    this.decidedBy,
    this.decidedAt,
    this.rejectionReason,
    this.executionError,
  });

  factory StaffApproval.fromJson(Map<String, Object?> json) {
    final Object? params = json['params'];
    return StaffApproval(
      approvalId: _requiredText(json, 'approvalId'),
      action: _requiredText(json, 'action'),
      status: _requiredText(json, 'status'),
      requestedBy: _looseText(json, 'requestedBy') ?? '',
      reason: _looseText(json, 'reason') ?? '',
      summary: _looseText(json, 'summary') ?? '',
      createdAt: _looseText(json, 'createdAt') ?? '',
      params: params is Map ? _objectMap(params) : const <String, Object?>{},
      canDecide: json['canDecide'] == true,
      canReject: json['canReject'] == true,
      canClose: json['canClose'] == true,
      appliedSteps: json['appliedSteps'] is List
          ? (json['appliedSteps'] as List<Object?>)
                .map((Object? step) => '$step')
                .toList(growable: false)
          : const <String>[],
      tenantId: _looseText(json, 'tenantId'),
      companyName: _looseText(json, 'companyName'),
      expiresAt: _looseText(json, 'expiresAt'),
      decidedBy: _looseText(json, 'decidedBy'),
      decidedAt: _looseText(json, 'decidedAt'),
      rejectionReason: _looseText(json, 'rejectionReason'),
      executionError: _looseText(json, 'executionError'),
    );
  }

  final String approvalId, action, status, requestedBy, reason, summary;
  final String createdAt;
  final Map<String, Object?> params;
  final bool canDecide, canReject, canClose;
  final List<String> appliedSteps;
  final String? tenantId, companyName, expiresAt, decidedBy, decidedAt;
  final String? rejectionReason, executionError;
  bool get isPending => status == 'requested';
}

class StaffAuditEvent {
  const StaffAuditEvent({
    required this.eventId,
    required this.at,
    required this.actor,
    required this.action,
    required this.summary,
    this.tenantId,
  });

  factory StaffAuditEvent.fromJson(Map<String, Object?> json) =>
      StaffAuditEvent(
        eventId: _requiredText(json, 'eventId'),
        at: _requiredText(json, 'at'),
        actor: _looseText(json, 'actor') ?? 'System',
        action: _looseText(json, 'action') ?? '',
        summary: _looseText(json, 'summary') ?? '',
        tenantId: _looseText(json, 'tenantId'),
      );

  final String eventId, at, actor, action, summary;
  final String? tenantId;
}

class StaffAuditPage {
  const StaffAuditPage({
    required this.events,
    required this.from,
    required this.to,
    this.nextAfter,
  });

  final List<StaffAuditEvent> events;
  final String from, to;
  final String? nextAfter;
}

class StaffAuditCheck {
  const StaffAuditCheck({
    required this.day,
    required this.ok,
    required this.events,
    this.brokenReason,
  });

  final String day;
  final bool ok;
  final int events;
  final String? brokenReason;
}

extension StaffApprovalsApi on StaffApiClient {
  Future<List<StaffApproval>> approvals({String? status}) async {
    final Uri base = _uri(<String>['approvals']);
    final Object? rows = _objectMap(
      await _send(
        'GET',
        base.replace(
          queryParameters: <String, String>{
            if (status != null) 'status': status,
            'limit': '200',
          },
        ),
      ),
    )['approvals'];
    if (rows is! List) throw const FormatException('Invalid approvals.');
    return rows
        .map((Object? row) => StaffApproval.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffApproval> requestApproval({
    required String action,
    required Map<String, Object?> params,
    required String reason,
    required String key,
    String? tenantId,
  }) async => StaffApproval.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['approvals']),
        body: <String, Object?>{
          'action': action,
          'params': params,
          if (tenantId != null) 'tenantId': tenantId,
          'reason': reason,
        },
        key: key,
      ),
    ),
  );

  Future<StaffOperationOutcome?> approve(String approvalId) async {
    final Map<String, Object?> body = _objectMap(
      await _send('POST', _uri(<String>['approvals', approvalId, 'approve'])),
    );
    final Object? operation = body['operation'];
    return operation is Map
        ? StaffOperationOutcome.fromJson(_objectMap(operation))
        : null;
  }

  Future<StaffOperationOutcome?> retryApproval(String approvalId) async {
    final Map<String, Object?> body = _objectMap(
      await _send('POST', _uri(<String>['approvals', approvalId, 'retry'])),
    );
    final Object? operation = body['operation'];
    return operation is Map
        ? StaffOperationOutcome.fromJson(_objectMap(operation))
        : null;
  }

  Future<StaffApproval> closeApproval(String approvalId, String reason) async =>
      StaffApproval.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['approvals', approvalId, 'close']),
            body: <String, Object?>{'reason': reason},
          ),
        ),
      );

  Future<StaffApproval> reject(String approvalId, String reason) async =>
      StaffApproval.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['approvals', approvalId, 'reject']),
            body: <String, Object?>{'reason': reason},
          ),
        ),
      );

  Future<StaffAuditPage> auditEvents({
    String? actor,
    String? group,
    String? tenantId,
    String? from,
    String? to,
    String? after,
    int limit = 25,
  }) async {
    final Uri base = _uri(<String>['audit-events']);
    final Map<String, Object?> body = _objectMap(
      await _send(
        'GET',
        base.replace(
          queryParameters: <String, String>{
            if (actor != null) 'actor': actor,
            if (group != null) 'group': group,
            if (tenantId != null) 'tenantId': tenantId,
            if (from != null) 'from': from,
            if (to != null) 'to': to,
            if (after != null) 'after': after,
            'limit': '$limit',
          },
        ),
      ),
    );
    final Object? rows = body['events'];
    if (rows is! List) throw const FormatException('Invalid audit events.');
    return StaffAuditPage(
      events: rows
          .map((Object? row) => StaffAuditEvent.fromJson(_objectMap(row)))
          .toList(growable: false),
      from: _looseText(body, 'from') ?? '',
      to: _looseText(body, 'to') ?? '',
      nextAfter: _looseText(body, 'nextAfter'),
    );
  }

  Future<String> exportAudit({
    required String format,
    String? actor,
    String? group,
    String? tenantId,
    String? from,
    String? to,
  }) async =>
      await _send(
            'POST',
            _uri(<String>['audit-events', 'export']),
            body: <String, Object?>{
              'format': format,
              'actor': ?actor,
              'group': ?group,
              'tenantId': ?tenantId,
              'from': ?from,
              'to': ?to,
            },
            asText: true,
          )
          as String;

  Future<StaffAuditCheck> verifyAuditDay(String day) async {
    final Map<String, Object?> body = _objectMap(
      await _send(
        'GET',
        _uri(<String>[
          'audit-events',
          'verify',
        ]).replace(queryParameters: <String, String>{'day': day}),
      ),
    );
    final Object? broken = body['firstBroken'];
    return StaffAuditCheck(
      day: _looseText(body, 'day') ?? day,
      ok: body['ok'] == true,
      events: body['events'] is int ? body['events']! as int : 0,
      brokenReason: broken is Map
          ? _looseText(_objectMap(broken), 'reason')
          : null,
    );
  }
}
