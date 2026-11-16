import 'dart:async';
import 'dart:convert';

import 'package:http/http.dart' as http;

part 'staff_api_approvals.dart';
part 'staff_api_access.dart';
part 'staff_api_billing.dart';
part 'staff_api_company_data.dart';
part 'staff_api_mail.dart';
part 'staff_api_onboarding.dart';

class StaffApiException implements Exception {
  const StaffApiException(this.message, {this.statusCode, this.body});

  final String message;
  final int? statusCode;
  final Map<Object?, Object?>? body;

  String? get fix => body?['fix'] is String ? body!['fix']! as String : null;

  @override
  String toString() => message;
}

class StaffProfile {
  const StaffProfile({
    required this.email,
    required this.role,
    required this.capabilities,
    required this.home,
  });

  factory StaffProfile.fromJson(Map<String, Object?> json) {
    final Object? email = json['email'];
    final Object? role = json['role'];
    final Object? capabilities = json['capabilities'];
    final Object? home = json['home'];
    if (email is! String ||
        email.trim().isEmpty ||
        role is! String ||
        role.trim().isEmpty ||
        capabilities is! List ||
        capabilities.any((Object? item) => item is! String) ||
        home is! String ||
        home.trim().isEmpty) {
      throw const FormatException('Invalid staff profile.');
    }
    return StaffProfile(
      email: email,
      role: role,
      capabilities: Set<String>.unmodifiable(capabilities.cast<String>()),
      home: home,
    );
  }

  final String email;
  final String role;
  final Set<String> capabilities;
  final String home;
  bool can(String capability) => capabilities.contains(capability);
  bool get isOwner => can('owner.tools');
  bool get canEnterSetup => can('setup.enter');
  bool get canCreateCompany => can('companies.create');
  bool get canManageAccounts => can('accounts.manage');
  bool get seesCommercialData => can('commercial.read');
}

class StaffCompany {
  const StaffCompany({
    required this.tenantId,
    required this.legalName,
    required this.workspace,
    required this.companyCode,
    required this.status,
    required this.planRef,
    this.expired = false,
    this.billingEmail,
    this.projectId,
    this.releaseRing,
    this.rulesVersion,
    this.currentRulesVersion,
    this.expiresAt,
    this.lifecycleState,
    this.record = const <String, Object?>{},
  });

  factory StaffCompany.fromJson(Map<String, Object?> json) => StaffCompany(
    record: json,
    tenantId: _requiredText(json, 'tenantId'),
    legalName: _requiredText(json, 'legalName'),
    workspace: _requiredText(json, 'workspace'),
    companyCode: _requiredText(json, 'companyCode'),
    status: _requiredText(json, 'status'),
    planRef: _requiredText(json, 'planRef'),
    expired: json['expired'] == true,
    billingEmail: json['billingEmail'] is String
        ? json['billingEmail']! as String
        : null,
    projectId: json['location'] is Map
        ? (json['location'] as Map)['projectId'] as String?
        : null,
    releaseRing: json['releaseRing'] is String
        ? json['releaseRing']! as String
        : null,
    rulesVersion: json['rulesVersion'] is String
        ? json['rulesVersion']! as String
        : null,
    currentRulesVersion: json['currentRulesVersion'] is String
        ? json['currentRulesVersion']! as String
        : null,
    expiresAt: json['expiresAt'] is String
        ? json['expiresAt']! as String
        : null,
    lifecycleState: json['lifecycleState'] is String
        ? json['lifecycleState']! as String
        : null,
  );

  StaffCompany withBillingEmail(String? value) => StaffCompany(
    tenantId: tenantId,
    legalName: legalName,
    workspace: workspace,
    companyCode: companyCode,
    status: status,
    planRef: planRef,
    expired: expired,
    billingEmail: value,
    projectId: projectId,
    releaseRing: releaseRing,
    rulesVersion: rulesVersion,
    currentRulesVersion: currentRulesVersion,
    expiresAt: expiresAt,
    lifecycleState: lifecycleState,
    record: record,
  );

  StaffCompany withLifecycleState(String? value) => StaffCompany(
    tenantId: tenantId,
    legalName: legalName,
    workspace: workspace,
    companyCode: companyCode,
    status: status,
    planRef: planRef,
    expired: expired,
    billingEmail: billingEmail,
    projectId: projectId,
    releaseRing: releaseRing,
    rulesVersion: rulesVersion,
    currentRulesVersion: currentRulesVersion,
    expiresAt: expiresAt,
    lifecycleState: value,
    record: record,
  );

  final String tenantId, legalName, workspace, companyCode, status, planRef;
  final bool expired;
  final Map<String, Object?> record;
  final String? billingEmail,
      projectId,
      releaseRing,
      rulesVersion,
      currentRulesVersion,
      expiresAt,
      lifecycleState;
}

class StaffMailJob {
  const StaffMailJob({
    required this.jobId,
    required this.kind,
    required this.recipient,
    required this.status,
    required this.attempts,
    required this.maxAttempts,
    required this.createdAt,
    required this.updatedAt,
    required this.nextAttemptAt,
    required this.lastFailure,
    required this.retriedAs,
    required this.handledAt,
    required this.handledBy,
    required this.heldReason,
    required this.deliveryStatus,
    required this.deliveryStatusAt,
    required this.attachmentName,
  });

  factory StaffMailJob.fromJson(Map<String, Object?> json) {
    final String status = _requiredText(json, 'status');
    if (!const <String>{
      'queued',
      'sending',
      'sent',
      'failed',
      'uncertain',
      'held',
    }.contains(status)) {
      throw const FormatException('Invalid mail job status.');
    }
    final String? deliveryStatus = _optionalText(json, 'deliveryStatus');
    if (deliveryStatus != null &&
        !const <String>{
          'delivered',
          'soft_bounce',
          'hard_bounce',
          'blocked',
          'spam',
          'invalid_email',
        }.contains(deliveryStatus)) {
      throw const FormatException('Invalid delivery status.');
    }
    final String? deliveryStatusAt = _optionalText(json, 'deliveryStatusAt');
    return StaffMailJob(
      jobId: _requiredText(json, 'jobId'),
      kind: _requiredText(json, 'kind'),
      recipient: _requiredText(json, 'recipient'),
      status: status,
      attempts: _requiredInt(json, 'attempts', minimum: 0),
      maxAttempts: _requiredInt(json, 'maxAttempts', minimum: 1),
      createdAt: _requiredTimestamp(json, 'createdAt'),
      updatedAt: _requiredTimestamp(json, 'updatedAt'),
      nextAttemptAt: _nullableTimestamp(json, 'nextAttemptAt'),
      lastFailure: _nullableText(json, 'lastFailure'),
      retriedAs: _nullableText(json, 'retriedAs'),
      handledAt: _nullableTimestamp(json, 'handledAt'),
      handledBy: _nullableText(json, 'handledBy'),
      heldReason: _nullableText(json, 'heldReason'),
      deliveryStatus: deliveryStatus,
      deliveryStatusAt: deliveryStatusAt == null
          ? null
          : _canonicalTimestamp(deliveryStatusAt),
      attachmentName: _optionalText(json, 'attachmentName'),
    );
  }

  final String jobId, kind, recipient, status, createdAt, updatedAt;
  final int attempts, maxAttempts;
  final String? nextAttemptAt,
      lastFailure,
      retriedAs,
      handledAt,
      handledBy,
      heldReason,
      deliveryStatus,
      deliveryStatusAt,
      attachmentName;
  bool get isHeld => status == 'held';
  bool get isOneTime => isOneTimeMailKind(kind);
  bool get needsAttention =>
      status == 'failed' || status == 'uncertain' || isHeld;
}

class StaffLifecycle {
  const StaffLifecycle({
    required this.tenantId,
    required this.state,
    required this.revision,
    required this.stateSince,
    required this.graceEndsAt,
    required this.windowEndsAt,
    required this.retentionEndsAt,
    required this.reason,
    required this.ticket,
    required this.updatedBy,
    required this.updatedAt,
    required this.lastOperationId,
    required this.activationReceiptId,
  });

  factory StaffLifecycle.fromJson(Map<String, Object?> json) {
    const Set<String> fields = <String>{
      'tenantId',
      'state',
      'revision',
      'stateSince',
      'graceEndsAt',
      'windowEndsAt',
      'retentionEndsAt',
      'reason',
      'ticket',
      'updatedBy',
      'updatedAt',
      'lastOperationId',
      'activationReceiptId',
    };
    if (json.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(json.keys.toSet()).isNotEmpty) {
      throw const FormatException('Invalid lifecycle record fields.');
    }
    final String state = _requiredText(json, 'state');
    if (!const <String>{
      'lead',
      'active',
      'past_due',
      'suspended',
      'expired',
      'cancelled',
    }.contains(state)) {
      throw const FormatException('Invalid lifecycle state.');
    }
    return StaffLifecycle(
      tenantId: _requiredText(json, 'tenantId'),
      state: state,
      revision: _requiredInt(json, 'revision', minimum: 1),
      stateSince: _requiredTimestamp(json, 'stateSince'),
      graceEndsAt: _nullableTimestamp(json, 'graceEndsAt'),
      windowEndsAt: _nullableTimestamp(json, 'windowEndsAt'),
      retentionEndsAt: _nullableTimestamp(json, 'retentionEndsAt'),
      reason: _requiredText(json, 'reason'),
      ticket: _nullableText(json, 'ticket'),
      updatedBy: _requiredText(json, 'updatedBy'),
      updatedAt: _requiredTimestamp(json, 'updatedAt'),
      lastOperationId: _requiredText(json, 'lastOperationId'),
      activationReceiptId: _nullableText(json, 'activationReceiptId'),
    );
  }

  final String tenantId, state, stateSince;
  final int revision;
  final String? graceEndsAt, windowEndsAt, retentionEndsAt;
  final String reason, updatedBy, updatedAt, lastOperationId;
  final String? ticket, activationReceiptId;
}

class StaffLifecycleProjection {
  const StaffLifecycleProjection({
    required this.tenantId,
    required this.state,
    required this.revision,
    required this.stateSince,
    required this.graceEndsAt,
    required this.windowEndsAt,
    required this.retentionEndsAt,
  });

  factory StaffLifecycleProjection.fromJson(Map<String, Object?> json) {
    const Set<String> fields = <String>{
      'tenantId',
      'state',
      'revision',
      'stateSince',
      'graceEndsAt',
      'windowEndsAt',
      'retentionEndsAt',
    };
    if (json.keys.toSet().difference(fields).isNotEmpty ||
        fields.difference(json.keys.toSet()).isNotEmpty) {
      throw const FormatException('Invalid lifecycle projection fields.');
    }
    final String state = _requiredText(json, 'state');
    if (!const <String>{
      'lead',
      'active',
      'past_due',
      'suspended',
      'expired',
      'cancelled',
    }.contains(state)) {
      throw const FormatException('Invalid lifecycle state.');
    }
    return StaffLifecycleProjection(
      tenantId: _requiredText(json, 'tenantId'),
      state: state,
      revision: _requiredInt(json, 'revision', minimum: 1),
      stateSince: _requiredTimestamp(json, 'stateSince'),
      graceEndsAt: _nullableTimestamp(json, 'graceEndsAt'),
      windowEndsAt: _nullableTimestamp(json, 'windowEndsAt'),
      retentionEndsAt: _nullableTimestamp(json, 'retentionEndsAt'),
    );
  }

  final String tenantId, state, stateSince;
  final int revision;
  final String? graceEndsAt, windowEndsAt, retentionEndsAt;
}

const Set<String> _lifecycleStates = <String>{
  'lead',
  'active',
  'past_due',
  'suspended',
  'expired',
  'cancelled',
};

List<String> _allowedNext(Map<String, Object?> json) {
  final Object? raw = json['allowedNext'];
  if (raw is! List || raw.any((Object? s) => !_lifecycleStates.contains(s))) {
    throw const FormatException('Invalid allowedNext.');
  }
  return List<String>.unmodifiable(raw.cast<String>());
}

class StaffLifecycleResponse {
  const StaffLifecycleResponse({
    required this.lifecycle,
    required this.allowedNext,
    this.projection,
  });

  factory StaffLifecycleResponse.fromJson(Map<String, Object?> json) {
    final Object? lifecycle = json['lifecycle'];
    final Object? projection = json['projection'];
    if (json.keys.toSet().difference(const <String>{
          'lifecycle',
          'projection',
          'allowedNext',
        }).isNotEmpty ||
        lifecycle is! Map ||
        !json.containsKey('projection')) {
      throw const FormatException('Invalid lifecycle response.');
    }
    final StaffLifecycle state = StaffLifecycle.fromJson(_objectMap(lifecycle));
    final StaffLifecycleProjection? projected = projection == null
        ? null
        : StaffLifecycleProjection.fromJson(_objectMap(projection));
    if (projected != null && projected.tenantId != state.tenantId) {
      throw const FormatException('Lifecycle tenant mismatch.');
    }
    return StaffLifecycleResponse(
      lifecycle: state,
      projection: projected,
      allowedNext: _allowedNext(json),
    );
  }

  final StaffLifecycle? lifecycle;
  final StaffLifecycleProjection? projection;
  final List<String> allowedNext;
}

class StaffOperationOutcome {
  const StaffOperationOutcome({
    required this.operationId,
    required this.status,
  });

  factory StaffOperationOutcome.fromJson(Map<String, Object?> json) {
    if (json.keys.toSet().difference(const <String>{
          'operationId',
          'status',
          'steps',
        }).isNotEmpty ||
        const <String>{
          'operationId',
          'status',
          'steps',
        }.difference(json.keys.toSet()).isNotEmpty) {
      throw const FormatException('Invalid operation outcome fields.');
    }
    final String status = _requiredText(json, 'status');
    if (!const <String>{'completed', 'pending', 'failed'}.contains(status)) {
      throw const FormatException('Invalid operation status.');
    }
    final Object? rawSteps = json['steps'];
    if (rawSteps is! Map || rawSteps.isEmpty) {
      throw const FormatException('Invalid operation steps.');
    }
    for (final MapEntry<Object?, Object?> step in rawSteps.entries) {
      if (step.key is! String || step.value is! Map) {
        throw const FormatException('Invalid operation step.');
      }
      final Map<String, Object?> value = _objectMap(step.value);
      if (!const <String>{
            'done',
            'pending',
            'failed',
          }.contains(value['status']) ||
          !value.containsKey('result') ||
          (value['result'] != null && value['result'] is! Map)) {
        throw const FormatException('Invalid operation step.');
      }
    }
    return StaffOperationOutcome(
      operationId: _requiredText(json, 'operationId'),
      status: status,
    );
  }

  final String operationId, status;
  bool get completed => status == 'completed';
}

const Map<String, String> staffLimitLabels = <String, String>{
  'salesmen': 'Salespeople',
  'supervisors': 'Supervisors',
  'admins': 'Admins',
  'managers': 'Managers',
  'branchManagers': 'Branch managers',
  'products': 'Products',
};

Map<String, int?> _limits(Map<String, Object?> json, String key) {
  final Object? raw = json[key];
  if (raw is! Map) throw FormatException('Invalid $key.');
  final Map<String, int?> limits = <String, int?>{};
  for (final MapEntry<Object?, Object?> entry in raw.entries) {
    final Object? value = entry.value;
    if (entry.key is! String ||
        (value != null && (value is! int || value < 0))) {
      throw FormatException('Invalid $key.');
    }
    limits[entry.key as String] = value as int?;
  }
  return limits;
}

bool _requiredBool(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! bool) throw FormatException('Invalid $key.');
  return value;
}

class StaffPackage {
  const StaffPackage({
    required this.planId,
    required this.name,
    required this.edition,
    required this.limits,
    this.monthlyPrice,
    this.yearlyPrice,
    this.tagline,
    this.canRequest,
    this.requestReason,
  });

  factory StaffPackage.fromJson(Map<String, Object?> json) => StaffPackage(
    planId: _requiredText(json, 'planId'),
    name: _requiredText(json, 'name'),
    edition: _requiredText(json, 'edition'),
    limits: _limits(json, 'limits'),
    monthlyPrice: _price(json['prices'], 'monthly'),
    yearlyPrice: _price(json['prices'], 'yearly'),
    tagline: json['tagline'] is String ? json['tagline']! as String : null,
    canRequest: json.containsKey('canRequest')
        ? _requiredBool(json, 'canRequest')
        : null,
    requestReason: json['requestReason'] is String
        ? json['requestReason'] as String
        : null,
  );

  final String planId, name, edition;
  final Map<String, int?> limits;
  final num? monthlyPrice, yearlyPrice;
  final String? tagline, requestReason;
  final bool? canRequest;
}

num? _price(Object? prices, String key) {
  if (prices is! Map) return null;
  final Object? value = prices[key];
  return value is num ? value : null;
}

class StaffCurrentPackage {
  const StaffCurrentPackage({
    required this.planId,
    required this.planVersion,
    required this.name,
    required this.edition,
    required this.billingInterval,
    required this.status,
    required this.revision,
    required this.limits,
  });

  factory StaffCurrentPackage.fromJson(Map<String, Object?> json) {
    final Object? interval = json['billingInterval'];
    if (interval != null && interval != 'monthly' && interval != 'yearly') {
      throw const FormatException('Invalid billingInterval.');
    }
    return StaffCurrentPackage(
      planId: _requiredText(json, 'planId'),
      planVersion: _requiredInt(json, 'planVersion', minimum: 1),
      name: _requiredText(json, 'name'),
      edition: _requiredText(json, 'edition'),
      billingInterval: interval as String?,
      status: json['status'] as String?,
      revision: _requiredInt(json, 'revision', minimum: 0),
      limits: _limits(json, 'limits'),
    );
  }

  final String planId, name, edition;
  final int planVersion, revision;
  final String? billingInterval, status;
  final Map<String, int?> limits;
}

class StaffCompanyPackages {
  const StaffCompanyPackages({required this.current, required this.packages});

  factory StaffCompanyPackages.fromJson(Map<String, Object?> json) {
    final Object? current = json['current'];
    final Object? rows = json['packages'];
    if (!json.containsKey('current') || rows is! List) {
      throw const FormatException('Invalid packages response.');
    }
    return StaffCompanyPackages(
      current: current == null
          ? null
          : StaffCurrentPackage.fromJson(_objectMap(current)),
      packages: rows
          .map((Object? row) => StaffPackage.fromJson(_objectMap(row)))
          .toList(growable: false),
    );
  }

  final StaffCurrentPackage? current;
  final List<StaffPackage> packages;
}

class StaffOperationSummary {
  const StaffOperationSummary({
    required this.operationId,
    required this.action,
    required this.status,
    required this.reason,
    required this.createdAt,
    required this.errorType,
    required this.errorMessage,
    required this.canRetry,
  });

  factory StaffOperationSummary.fromJson(Map<String, Object?> json) {
    final String status = _requiredText(json, 'status');
    if (status != 'pending' && status != 'failed' && status != 'completed') {
      throw const FormatException('Invalid operation status.');
    }
    return StaffOperationSummary(
      operationId: _requiredText(json, 'operationId'),
      action: _requiredText(json, 'action'),
      status: status,
      reason: _nullableText(json, 'reason'),
      createdAt: _nullableTimestamp(json, 'createdAt'),
      errorType: _nullableText(json, 'errorType'),
      errorMessage: _nullableText(json, 'errorMessage'),
      canRetry: _requiredBool(json, 'canRetry'),
    );
  }

  final String operationId, action, status;
  final String? reason, createdAt, errorType, errorMessage;
  final bool canRetry;
}

class StaffPlanRequest {
  const StaffPlanRequest({
    required this.requestId,
    required this.tenantId,
    required this.companyName,
    required this.planId,
    required this.planName,
    required this.interval,
    required this.status,
    required this.createdAt,
    required this.open,
  });

  factory StaffPlanRequest.fromJson(Map<String, Object?> json) {
    final Object? interval = json['interval'];
    if (interval != 'monthly' && interval != 'yearly') {
      throw const FormatException('Invalid interval.');
    }
    return StaffPlanRequest(
      requestId: _requiredText(json, 'requestId'),
      tenantId: _requiredText(json, 'tenantId'),
      companyName: _nullableText(json, 'companyName'),
      planId: _requiredText(json, 'planId'),
      planName: _nullableText(json, 'planName'),
      interval: interval as String,
      status: _requiredText(json, 'status'),
      createdAt: _nullableTimestamp(json, 'createdAt'),
      open: _requiredBool(json, 'open'),
    );
  }

  final String requestId, tenantId, planId, interval, status;
  final String? companyName, planName, createdAt;
  final bool open;
}

class StaffToday {
  const StaffToday({
    required this.companies,
    required this.byState,
    required this.overdue,
    required this.expiringSoon,
    required this.withinDays,
    required this.pending,
    required this.failed,
    required this.failedWithinDays,
    required this.openPlanRequests,
    this.recordsExpiringWithin14Days,
    this.recordsExpired,
    this.graceOver = const <StaffGraceOver>[],
    this.renewalBlocked = const <StaffRenewalBlocked>[],
  });

  factory StaffToday.fromJson(Map<String, Object?> json) {
    final Map<String, Object?> companies = _objectMap(json['companies']);
    final Map<String, Object?> payments = _objectMap(json['payments']);
    final Map<String, Object?> operations = _objectMap(json['operations']);
    final Map<String, Object?> requests = _objectMap(json['planRequests']);
    final Map<String, Object?> states = _objectMap(companies['byState']);
    return StaffToday(
      companies: _requiredInt(companies, 'total', minimum: 0),
      byState: <String, int>{
        for (final String state in states.keys)
          state: _requiredInt(states, state, minimum: 0),
      },
      overdue: _requiredInt(payments, 'overdue', minimum: 0),
      expiringSoon: _requiredInt(payments, 'expiringSoon', minimum: 0),
      withinDays: _requiredInt(payments, 'withinDays', minimum: 1),
      pending: _requiredInt(operations, 'pending', minimum: 0),
      failed: _requiredInt(operations, 'failed', minimum: 0),
      failedWithinDays: _requiredInt(
        operations,
        'failedWithinDays',
        minimum: 1,
      ),
      openPlanRequests: _requiredInt(requests, 'open', minimum: 0),
      recordsExpiringWithin14Days: _optionalCount(<Map<String, Object?>>[
        json,
        companies,
      ], 'recordsExpiringWithin14Days'),
      recordsExpired: _optionalCount(<Map<String, Object?>>[
        json,
        companies,
      ], 'recordsExpired'),
      graceOver: <StaffGraceOver>[
        if (companies['graceOver'] is List)
          for (final Object? row in companies['graceOver']! as List)
            if (row is Map<String, Object?>)
              StaffGraceOver(
                tenantId: _requiredText(row, 'tenantId'),
                legalName: _nullableText(row, 'legalName') ?? '',
                graceEndedAt: _requiredTimestamp(row, 'graceEndedAt'),
              ),
      ],
      renewalBlocked: <StaffRenewalBlocked>[
        if (companies['renewalBlocked'] is List)
          for (final Object? row in companies['renewalBlocked']! as List)
            if (row is Map<String, Object?>)
              StaffRenewalBlocked(
                tenantId: _requiredText(row, 'tenantId'),
                legalName: _nullableText(row, 'legalName') ?? '',
                reason: _requiredText(row, 'reason'),
                coverEndsAt: _requiredTimestamp(row, 'coverEndsAt'),
              ),
      ],
    );
  }

  final int companies, overdue, expiringSoon, withinDays;
  final int pending, failed, failedWithinDays, openPlanRequests;
  final int? recordsExpiringWithin14Days, recordsExpired;
  final Map<String, int> byState;
  final List<StaffGraceOver> graceOver;
  final List<StaffRenewalBlocked> renewalBlocked;
}

class StaffRenewalBlocked {
  const StaffRenewalBlocked({
    required this.tenantId,
    required this.legalName,
    required this.reason,
    required this.coverEndsAt,
  });

  final String tenantId, legalName, reason, coverEndsAt;
}

class StaffGraceOver {
  const StaffGraceOver({
    required this.tenantId,
    required this.legalName,
    required this.graceEndedAt,
  });

  final String tenantId, legalName, graceEndedAt;
}

class StaffApiClient {
  StaffApiClient({
    http.Client? client,
    Uri? baseUri,
    this.headers,
    this.onSessionLost,
  }) : _client = client ?? http.Client(),
       _ownsClient = client == null,
       _baseUri = _origin(baseUri ?? Uri.base);

  final Future<Map<String, String>> Function()? headers;
  final void Function()? onSessionLost;

  static const Duration _timeout = Duration(seconds: 20);
  final http.Client _client;
  final bool _ownsClient;
  final Uri _baseUri;

  static Uri _origin(Uri uri) => Uri(
    scheme: uri.scheme,
    host: uri.host,
    port: uri.hasPort ? uri.port : null,
  );

  Uri _uri(List<String> segments) => _baseUri.replace(
    pathSegments: <String>['', 'staff', 'v1', ...segments],
    query: null,
    fragment: null,
    userInfo: '',
  );

  Future<StaffProfile> profile() async => StaffProfile.fromJson(
    _objectMap(await _send('GET', _uri(<String>['me']))),
  );

  Future<List<StaffCompany>> companies() async {
    final Map<String, Object?> body = _objectMap(
      await _send('GET', _uri(<String>['companies'])),
    );
    final Object? rows = body['companies'];
    if (rows is! List) {
      throw const FormatException('Invalid companies response.');
    }
    return rows
        .map((Object? row) => StaffCompany.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffLifecycleResponse> lifecycle(String tenantId) async {
    try {
      return StaffLifecycleResponse.fromJson(
        _objectMap(
          await _send(
            'GET',
            _uri(<String>['companies', tenantId, 'lifecycle']),
          ),
        ),
      );
    } on StaffApiException catch (error) {
      final Map<Object?, Object?>? body = error.body;
      if (error.statusCode != 404 ||
          body == null ||
          !body.containsKey('allowedNext')) {
        rethrow;
      }
      try {
        return StaffLifecycleResponse(
          lifecycle: null,
          allowedNext: _allowedNext(_objectMap(body)),
        );
      } on FormatException {
        throw const StaffApiException(
          'The staff service returned an invalid response.',
        );
      }
    }
  }

  Future<StaffOperationOutcome> transitionLifecycle(
    String tenantId,
    Map<String, Object?> body, {
    required String key,
  }) async => StaffOperationOutcome.fromJson(
    _objectMap(
      await _send(
        'PUT',
        _uri(<String>['companies', tenantId, 'lifecycle']),
        body: body,
        key: key,
      ),
    ),
  );

  Future<List<String>> approvalActions() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['approval-actions'])),
    )['actions'];
    if (rows is! List || rows.any((Object? row) => row is! String)) {
      throw const FormatException('Invalid approval actions.');
    }
    return rows.cast<String>();
  }

  Future<StaffToday> today() async => StaffToday.fromJson(
    _objectMap(await _send('GET', _uri(<String>['today']))),
  );

  Future<List<StaffPackage>> packages() async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['packages'])),
    )['packages'];
    if (rows is! List) throw const FormatException('Invalid packages.');
    return rows
        .map((Object? row) => StaffPackage.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<Map<String, Object?>> _currentVersion(String planId) async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['plans'])),
    )['plans'];
    if (rows is! List) throw const FormatException('Invalid plans.');
    final Map<String, Object?> plan = rows
        .map(_objectMap)
        .firstWhere(
          (Map<String, Object?> row) => row['planId'] == planId,
          orElse: () => throw const FormatException('Unknown package.'),
        );
    return _objectMap(plan['current']);
  }

  Future<Map<String, Object?>> _versionWithPrices(
    String planId,
    num? monthly,
    num? yearly,
  ) async {
    final Map<String, Object?> current = await _currentVersion(planId);
    const List<String> kept = <String>[
      'name',
      'edition',
      'limits',
      'quotaSchemaVersion',
      'features',
      'tagline',
      'highlights',
      'sortOrder',
      'notes',
    ];
    return <String, Object?>{
      for (final String name in kept)
        if (current.containsKey(name)) name: current[name],
      'prices': <String, Object?>{
        'currency': 'MYR',
        'monthly': monthly,
        'yearly': yearly,
      },
    };
  }

  Future<StaffOperationOutcome> setFirstPrice(
    String planId, {
    required num? monthly,
    required num? yearly,
    required String reason,
    required String key,
  }) async {
    final Map<String, Object?> version = await _versionWithPrices(
      planId,
      monthly,
      yearly,
    );
    return StaffOperationOutcome.fromJson(
      _objectMap(
        await _send(
          'PUT',
          _uri(<String>['plans', planId]),
          body: <String, Object?>{...version, 'reason': reason},
          key: key,
        ),
      ),
    );
  }

  Future<StaffApproval> requestPriceChange(
    String planId, {
    required num? monthly,
    required num? yearly,
    required String reason,
    required String key,
  }) async => requestApproval(
    action: 'package.price',
    params: <String, Object?>{
      'planId': planId,
      'version': await _versionWithPrices(planId, monthly, yearly),
    },
    reason: reason,
    key: key,
  );

  Future<StaffCompanyPackages> companyPackages(String tenantId) async =>
      StaffCompanyPackages.fromJson(
        _objectMap(
          await _send('GET', _uri(<String>['companies', tenantId, 'packages'])),
        ),
      );

  Future<StaffOperationOutcome> changePackage(
    String tenantId,
    Map<String, Object?> body, {
    required String key,
  }) async => StaffOperationOutcome.fromJson(
    _objectMap(
      await _send(
        'POST',
        _uri(<String>['companies', tenantId, 'package']),
        body: body,
        key: key,
      ),
    ),
  );

  Future<StaffOperationOutcome> putCompany(
    String tenantId, {
    required Map<String, Object?> record,
    required int expectedVersion,
    required String reason,
    required String key,
  }) async => StaffOperationOutcome.fromJson(
    _objectMap(
      await _send(
        'PUT',
        _uri(<String>['companies', tenantId]),
        body: <String, Object?>{
          'record': record,
          'expectedVersion': expectedVersion,
          'reason': reason,
        },
        key: key,
      ),
    ),
  );

  Future<List<StaffOperationSummary>> companyOperations(String tenantId) async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['companies', tenantId, 'operations'])),
    )['operations'];
    if (rows is! List) throw const FormatException('Invalid operations.');
    return rows
        .map((Object? row) => StaffOperationSummary.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffOperationOutcome> retryOperation(String operationId) async =>
      StaffOperationOutcome.fromJson(
        _objectMap(
          await _send(
            'POST',
            _uri(<String>['operations', operationId, 'retry']),
          ),
        ),
      );

  Future<List<StaffMailJob>> mailJobs(String tenantId) async {
    final Object? rows = _objectMap(
      await _send('GET', _uri(<String>['companies', tenantId, 'mail-jobs'])),
    )['jobs'];
    if (rows is! List) throw const FormatException('Invalid mail jobs.');
    return rows
        .map((Object? row) => StaffMailJob.fromJson(_objectMap(row)))
        .toList(growable: false);
  }

  Future<StaffMailJob> retryMailJob(
    String tenantId,
    String jobId, {
    required bool confirmDuplicateRisk,
  }) async => _mailJob(
    await _send(
      'POST',
      _uri(<String>['companies', tenantId, 'mail-jobs', jobId, 'retry']),
      body: <String, Object?>{'confirmDuplicateRisk': confirmDuplicateRisk},
    ),
  );

  Future<StaffMailJob> markMailJobHandled(
    String tenantId,
    String jobId,
  ) async => _mailJob(
    await _send(
      'POST',
      _uri(<String>['companies', tenantId, 'mail-jobs', jobId, 'handled']),
    ),
  );

  StaffMailJob _mailJob(Object? decoded) {
    try {
      return StaffMailJob.fromJson(_objectMap(_objectMap(decoded)['job']));
    } on FormatException {
      throw const StaffApiException(
        'The staff service returned an invalid response.',
      );
    }
  }

  Future<List<StaffPlanRequest>> planRequests() async {
    final List<StaffPlanRequest> requests = <StaffPlanRequest>[];
    final Set<String> seen = <String>{};
    String? after;
    do {
      final Map<String, Object?> page = _objectMap(
        await _send(
          'GET',
          _uri(<String>['plan-requests']).replace(
            queryParameters: <String, String>{
              'limit': '200',
              if (after != null) 'after': after,
            },
          ),
        ),
      );
      final Object? rows = page['requests'];
      final Object? next = page['nextAfter'];
      if (rows is! List || (next != null && next is! String)) {
        throw const FormatException('Invalid plan requests.');
      }
      if (next is String && !seen.add(next)) {
        throw const FormatException('Invalid plan requests.');
      }
      requests.addAll(
        rows.map((Object? row) => StaffPlanRequest.fromJson(_objectMap(row))),
      );
      after = next as String?;
    } while (after != null);
    return List<StaffPlanRequest>.unmodifiable(requests);
  }

  Future<void> declinePlanRequest(String tenantId, String reason) async {
    await _send(
      'POST',
      _uri(<String>['plan-requests', tenantId, 'decline']),
      body: <String, Object?>{'reason': reason},
    );
  }

  Future<Object?> _send(
    String method,
    Uri uri, {
    Map<String, Object?>? body,
    String? key,
    bool asText = false,
    bool endsSession = true,
  }) async {
    try {
      return await (() async {
        final Map<String, String> extra =
            await headers?.call() ?? const <String, String>{};
        final http.Request request = http.Request(method, uri)
          ..headers.addAll(<String, String>{
            'Accept': 'application/json',
            if (body != null) 'Content-Type': 'application/json',
            if (key != null) 'Idempotency-Key': key,
            ...extra,
          });
        if (body != null) request.body = jsonEncode(body);
        final http.StreamedResponse streamed = await _client.send(request);
        final http.Response response = await http.Response.fromStream(streamed);
        Object? decoded;
        try {
          decoded = response.bodyBytes.isEmpty
              ? null
              : jsonDecode(utf8.decode(response.bodyBytes));
        } catch (_) {
          decoded = null;
        }
        if (response.statusCode < 200 || response.statusCode >= 300) {
          final String message = _safeDetail(decoded, response.statusCode);
          if (response.statusCode == 401 &&
              endsSession &&
              extra.containsKey('X-Staff-Session')) {
            onSessionLost?.call();
          }
          throw StaffApiException(
            message,
            statusCode: response.statusCode,
            body: decoded is Map ? decoded : null,
          );
        }
        if (asText) return utf8.decode(response.bodyBytes);
        if (decoded == null) {
          throw const FormatException('Invalid API response.');
        }
        return decoded;
      })().timeout(_timeout);
    } on StaffApiException {
      rethrow;
    } on TimeoutException {
      throw const StaffApiException(
        'The staff service did not answer in 20 seconds.',
      );
    } on FormatException {
      throw const StaffApiException(
        'The staff service returned an invalid response.',
      );
    } catch (_) {
      throw const StaffApiException(
        'Could not reach the staff service. Check the connection.',
      );
    }
  }

  static String _safeDetail(Object? decoded, int status) {
    if (decoded is Map) {
      final Object? detail = decoded['detail'];
      if (detail is String && detail.trim().isNotEmpty) {
        final Object? message = decoded['message'];
        final String text = message is String && message.trim().isNotEmpty
            ? '${detail.trim()} ${message.trim()}'
            : detail.trim();
        return text.length <= 300 ? text : '${text.substring(0, 297)}...';
      }
    }
    return 'The staff service returned an error ($status).';
  }

  void close() {
    if (_ownsClient) _client.close();
  }
}

Map<String, Object?> _objectMap(Object? value) {
  if (value is! Map) throw const FormatException('Expected an object.');
  return value.map<String, Object?>(
    (Object? key, Object? value) =>
        MapEntry<String, Object?>(key as String, value),
  );
}

String _requiredText(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value is! String || value.trim().isEmpty) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

String? _nullableText(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) throw FormatException('Missing $key.');
  final Object? value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key.');
  return value;
}

String? _optionalText(Map<String, Object?> json, String key) {
  final Object? value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key.');
  return value;
}

String? _nullableTimestamp(Map<String, Object?> json, String key) {
  if (!json.containsKey(key)) throw FormatException('Missing $key.');
  final Object? value = json[key];
  if (value == null) return null;
  if (value is! String) throw FormatException('Invalid $key.');
  return _canonicalTimestamp(value);
}

int _requiredInt(
  Map<String, Object?> json,
  String key, {
  required int minimum,
}) {
  final Object? value = json[key];
  if (value is! int || value < minimum || value > 9007199254740991) {
    throw FormatException('Invalid $key.');
  }
  return value;
}

int? _optionalCount(List<Map<String, Object?>> sources, String key) {
  for (final Map<String, Object?> source in sources) {
    if (source[key] != null) return _requiredInt(source, key, minimum: 0);
  }
  return null;
}

String _requiredTimestamp(Map<String, Object?> json, String key) =>
    _canonicalTimestamp(_requiredText(json, key));

String _canonicalTimestamp(String value) {
  if (!RegExp(r'^\d{4}-\d{2}-\d{2}T\d{2}:\d{2}:\d{2}Z$').hasMatch(value)) {
    throw const FormatException('Invalid canonical UTC timestamp.');
  }
  final DateTime? parsed = DateTime.tryParse(value);
  if (parsed == null ||
      parsed.toUtc().toIso8601String() != value.replaceFirst('Z', '.000Z')) {
    throw const FormatException('Invalid canonical UTC timestamp.');
  }
  return value;
}
