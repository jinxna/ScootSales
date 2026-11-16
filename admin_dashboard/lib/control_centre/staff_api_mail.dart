part of 'staff_api_client.dart';

bool isOneTimeMailKind(String kind) =>
    kind == 'staff_signin_code' ||
    kind == 'invitation_email_code' ||
    kind == 'password_reset' ||
    kind == 'email_verification';

String heldReasonText(String reason) => switch (reason) {
  'daily_cap' => 'The daily mail limit was reached.',
  'template_missing' => 'The mail template is not set up.',
  'provider_unavailable' => 'The mail provider refused the request.',
  'recipient_suppressed' =>
    'The address bounced or was blocked. Lift the block first.',
  _ => reason.replaceAll('_', ' '),
};

String suppressionReasonText(String reason) => switch (reason) {
  'hard_bounce' => 'Hard bounce',
  'blocked' => 'Blocked',
  'spam' => 'Marked as spam',
  'invalid_email' => 'Invalid address',
  _ => reason,
};

class StaffMailSuppression {
  const StaffMailSuppression({
    required this.suppressionId,
    required this.recipient,
    required this.reason,
    required this.since,
    required this.lastEventAt,
    required this.tenantId,
    required this.companyName,
    required this.kind,
  });

  factory StaffMailSuppression.fromJson(Map<String, Object?> json) {
    final String reason = _requiredText(json, 'reason');
    if (!const <String>{
      'hard_bounce',
      'blocked',
      'spam',
      'invalid_email',
    }.contains(reason)) {
      throw const FormatException('Invalid suppression reason.');
    }
    return StaffMailSuppression(
      suppressionId: _requiredText(json, 'suppressionId'),
      recipient: _requiredText(json, 'recipient'),
      reason: reason,
      since: _requiredTimestamp(json, 'since'),
      lastEventAt: _requiredTimestamp(json, 'lastEventAt'),
      tenantId: _requiredText(json, 'tenantId'),
      companyName: _requiredText(json, 'companyName'),
      kind: _requiredText(json, 'kind'),
    );
  }

  final String suppressionId,
      recipient,
      reason,
      since,
      lastEventAt,
      tenantId,
      companyName,
      kind;

  String get reasonText => suppressionReasonText(reason);
}

class StaffHeldMail {
  const StaffHeldMail({
    required this.jobId,
    required this.tenantId,
    required this.companyName,
    required this.kind,
    required this.recipient,
    required this.reason,
    required this.heldAt,
    required this.attempts,
    required this.maxAttempts,
    required this.lastFailure,
  });

  factory StaffHeldMail.fromJson(Map<String, Object?> json) => StaffHeldMail(
    jobId: _requiredText(json, 'jobId'),
    tenantId: _requiredText(json, 'tenantId'),
    companyName: _requiredText(json, 'companyName'),
    kind: _requiredText(json, 'kind'),
    recipient: _requiredText(json, 'recipient'),
    reason: _requiredText(json, 'reason'),
    heldAt: _requiredTimestamp(json, 'heldAt'),
    attempts: _requiredInt(json, 'attempts', minimum: 0),
    maxAttempts: _requiredInt(json, 'maxAttempts', minimum: 1),
    lastFailure: _nullableText(json, 'lastFailure'),
  );

  final String jobId, tenantId, companyName, kind, recipient, reason, heldAt;
  final int attempts, maxAttempts;
  final String? lastFailure;

  bool get isOneTime => isOneTimeMailKind(kind);

  String get reasonText => heldReasonText(reason);
}

class StaffAttentionMail {
  const StaffAttentionMail({
    required this.tenantId,
    required this.companyName,
    required this.job,
  });

  factory StaffAttentionMail.fromJson(Map<String, Object?> json) =>
      StaffAttentionMail(
        tenantId: _requiredText(json, 'tenantId'),
        companyName: _requiredText(json, 'companyName'),
        job: StaffMailJob.fromJson(json),
      );

  final String tenantId, companyName;
  final StaffMailJob job;
}

extension StaffApiMail on StaffApiClient {
  Future<List<StaffAttentionMail>> mailAttention() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['mail', 'attention'])),
    )['jobs'];
    if (rows is! List) throw const FormatException('Invalid attention mail.');
    return rows
        .map((Object? row) => StaffAttentionMail.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<List<StaffHeldMail>> heldMail() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['mail', 'held'])),
    )['jobs'];
    if (rows is! List) throw const FormatException('Invalid held mail.');
    return rows
        .map((Object? row) => StaffHeldMail.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffMailJob> retryHeldMail(String jobId) async => _mailJob(
    await _send('POST', _uri(<String>['mail', 'held', jobId, 'retry'])),
  );

  Future<StaffMailJob> markHeldMailHandled(String jobId) async => _mailJob(
    await _send('POST', _uri(<String>['mail', 'held', jobId, 'handled'])),
  );

  Future<List<StaffMailSuppression>> mailSuppressions() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['mail', 'suppressions'])),
    )['suppressions'];
    if (rows is! List) throw const FormatException('Invalid suppressions.');
    return rows
        .map((Object? row) => StaffMailSuppression.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<void> liftMailSuppression(String suppressionId, String reason) async {
    await _send(
      'POST',
      _uri(<String>['mail', 'suppressions', suppressionId, 'lift']),
      body: <String, Object?>{'reason': reason},
    );
  }
}
