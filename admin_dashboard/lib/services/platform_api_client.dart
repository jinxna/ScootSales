import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_auth/firebase_auth.dart';
import 'package:http/http.dart' as http;

import '../app/workspace_runtime.dart';

class PlatformApiException implements Exception {
  const PlatformApiException(this.message, {this.statusCode, this.code});

  final String message;
  final int? statusCode;

  final String? code;

  bool get isPlanLimit => code == 'plan_limit';

  @override
  String toString() => message;
}

class EmailCodeRequest {
  const EmailCodeRequest({
    required this.isRequired,
    required this.sentTo,
    required this.expiresInSeconds,
  });

  final bool isRequired;
  final String sentTo;
  final int expiresInSeconds;
}

class TenantExportPackage {
  const TenantExportPackage({required this.bytes, required this.filename});

  final Uint8List bytes;
  final String filename;
}

class SupportGrant {
  const SupportGrant({
    required this.grantId,
    required this.staffEmail,
    required this.scope,
    required this.status,
    required this.revision,
    required this.expiresAt,
  });

  factory SupportGrant.fromJson(Map<String, Object?> json) => SupportGrant(
    grantId: _text(json['grantId']),
    staffEmail: _text(json['staffEmail']),
    scope: _text(json['scope']),
    status: _text(json['status']),
    revision: json['revision'] is int ? json['revision']! as int : 0,
    expiresAt: DateTime.tryParse(_text(json['expiresAt'])),
  );

  final String grantId;
  final String staffEmail;
  final String scope;
  final String status;
  final int revision;
  final DateTime? expiresAt;
}

class InvitationRequest {
  const InvitationRequest({
    required this.displayName,
    required this.role,
    required this.employeeCode,
    required this.branchId,
    this.email,
    this.phone,
    this.supervisorUid,
  });

  final String displayName;
  final String role;
  final String employeeCode;
  final String branchId;
  final String? email;
  final String? phone;
  final String? supervisorUid;

  Map<String, Object?> toJson() => <String, Object?>{
    'displayName': displayName,
    'role': role,
    'employeeCode': employeeCode,
    'branchId': branchId,
    'email': email,
    'phone': phone,
    'supervisorUid': supervisorUid,
  };

  String get fingerprint => jsonEncode(toJson());
}

class CreatedInvitation {
  const CreatedInvitation({
    required this.invitationId,
    required this.uid,
    required this.signInId,
    required this.code,
    required this.qrPayload,
    required this.expiresAt,
    required this.checkKind,
  });

  factory CreatedInvitation.fromJson(Map<String, Object?> json) =>
      CreatedInvitation(
        invitationId: _text(json['invitationId']),
        uid: _text(json['uid']),
        signInId: _text(json['signInId']),
        code: _text(json['code']),
        qrPayload: _text(json['qrPayload']),
        expiresAt: DateTime.tryParse(_text(json['expiresAt'])),
        checkKind: _text(json['checkKind']),
      );

  final String invitationId;
  final String uid;
  final String signInId;

  final String code;
  final String qrPayload;
  final DateTime? expiresAt;

  final String checkKind;

  String get displayCode {
    final String plain = code.replaceAll('-', '');
    if (plain.length != 12) return code;
    return '${plain.substring(0, 4)}-${plain.substring(4, 8)}-'
        '${plain.substring(8)}';
  }

  String get checkHint => checkKind == 'phone_last4'
      ? 'The last 4 digits of the phone number'
      : 'Their email address';
}

class InvitationRecord {
  const InvitationRecord({
    required this.invitationId,
    required this.uid,
    required this.displayName,
    required this.signInId,
    required this.role,
    required this.status,
    required this.expiresAt,
    required this.createdAt,
    required this.createdBy,
    required this.redeemedAt,
    required this.redeemedDevice,
    required this.failures,
  });

  factory InvitationRecord.fromJson(Map<String, Object?> json) =>
      InvitationRecord(
        invitationId: _text(json['invitationId']),
        uid: _text(json['uid']),
        displayName: _text(json['displayName']),
        signInId: _text(json['signInId']),
        role: _text(json['role']),
        status: _text(json['status']),
        expiresAt: DateTime.tryParse(_text(json['expiresAt'])),
        createdAt: DateTime.tryParse(_text(json['createdAt'])),
        createdBy: _text(json['createdBy']),
        redeemedAt: DateTime.tryParse(_text(json['redeemedAt'])),
        redeemedDevice: _text(json['redeemedDevice']),
        failures: json['failures'] is int ? json['failures']! as int : 0,
      );

  final String invitationId;
  final String uid;
  final String displayName;
  final String signInId;
  final String role;

  final String status;
  final DateTime? expiresAt;
  final DateTime? createdAt;
  final String createdBy;
  final DateTime? redeemedAt;
  final String redeemedDevice;
  final int failures;
}

class AccountReconcileEntry {
  const AccountReconcileEntry({
    required this.uid,
    required this.email,
    required this.disabled,
    required this.createdAt,
  });

  final String uid;
  final String email;
  final bool disabled;
  final String createdAt;
}

class AccountReconcile {
  const AccountReconcile({required this.authOnly, required this.profileOnly});

  final List<AccountReconcileEntry> authOnly;

  final List<AccountReconcileEntry> profileOnly;
}

class PlanUsage {
  const PlanUsage({
    required this.limits,
    required this.usage,
    required this.planName,
    required this.edition,
    this.quotaSchemaVersion = 1,
  });

  factory PlanUsage.fromJson(Map<String, Object?> json) {
    final int schema = _quotaSchema(json['quotaSchemaVersion']);
    return PlanUsage(
      limits: _quotaCounts(json['limits'], schema, allowUnlimited: true),
      usage: _quotaCounts(json['usage'], schema, allowUnlimited: false),
      planName: _text(json['planName']),
      edition: _text(json['edition']),
      quotaSchemaVersion: schema,
    );
  }

  final Map<String, int?> limits;
  final Map<String, int?> usage;
  final String planName;
  final String edition;
  final int quotaSchemaVersion;

  int? get productRoom {
    final int? limit = limits['products'];
    if (limit == null) return null;
    return limit - (usage['products'] ?? 0);
  }
}

int _quotaSchema(Object? value) {
  if (value == null) return 1;
  if (value is int && (value == 1 || value == 2)) return value;
  throw const PlatformApiException(
    'This plan format is not supported. Refresh the dashboard.',
    code: 'unsupported_plan',
  );
}

List<String> _quotaKeys(int schema) => schema == 2
    ? <String>[
        'salesmen',
        'supervisors',
        'admins',
        'branchManagers',
        'products',
      ]
    : <String>['salesmen', 'supervisors', 'managers', 'products'];

Map<String, int?> _quotaCounts(
  Object? value,
  int schema, {
  required bool allowUnlimited,
}) {
  const PlatformApiException incomplete = PlatformApiException(
    'Plan usage is incomplete. Try again in a moment.',
    code: 'usage_missing',
  );
  final List<String> keys = _quotaKeys(schema);
  if (value is! Map || value.length != keys.length) throw incomplete;
  final Map<String, int?> result = <String, int?>{};
  for (final String key in keys) {
    if (!value.containsKey(key)) throw incomplete;
    final Object? count = value[key];
    if (count == null && allowUnlimited) {
      result[key] = null;
    } else if (count is int && count >= 0) {
      result[key] = count;
    } else {
      throw incomplete;
    }
  }
  return result;
}

Map<String, int?> _counts(Object? value) => <String, int?>{
  if (value is Map)
    for (final MapEntry<Object?, Object?> entry in value.entries)
      if (entry.key is String)
        entry.key! as String: entry.value is num
            ? (entry.value! as num).toInt()
            : null,
};

class AccountPool {
  const AccountPool({
    required this.key,
    required this.label,
    required this.used,
    required this.limit,
  });

  final String key;
  final String label;
  final int used;

  final int? limit;
}

class AccountInvoice {
  const AccountInvoice({
    required this.invoiceId,
    required this.number,
    required this.status,
    required this.packageName,
    required this.billingInterval,
    required this.periodStart,
    required this.periodEnd,
    required this.amountMinor,
    required this.currency,
    required this.issuedAt,
    required this.dueAt,
    required this.note,
    required this.paidMinor,
    required this.creditedMinor,
    required this.outstandingMinor,
  });

  factory AccountInvoice.fromJson(Map<Object?, Object?> json) {
    int minor(Object? value) => value is num ? value.round() : 0;
    return AccountInvoice(
      invoiceId: _text(json['invoiceId']),
      number: _text(json['number']),
      status: _text(json['status']),
      packageName: _text(json['packageName']),
      billingInterval: _text(json['billingInterval']),
      periodStart: DateTime.tryParse(_text(json['periodStart'])),
      periodEnd: DateTime.tryParse(_text(json['periodEnd'])),
      amountMinor: minor(json['amountMinor']),
      currency: _text(json['currency']),
      issuedAt: DateTime.tryParse(_text(json['issuedAt'])),
      dueAt: DateTime.tryParse(_text(json['dueAt'])),
      note: _text(json['note']),
      paidMinor: minor(json['paidMinor']),
      creditedMinor: minor(json['creditedMinor']),
      outstandingMinor: minor(json['outstandingMinor']),
    );
  }

  final String invoiceId;
  final String number;
  final String status;
  final String packageName;
  final String billingInterval;
  final DateTime? periodStart;
  final DateTime? periodEnd;
  final int amountMinor;
  final String currency;
  final DateTime? issuedAt;
  final DateTime? dueAt;
  final String note;
  final int paidMinor;
  final int creditedMinor;
  final int outstandingMinor;
}

class AccountSummary {
  const AccountSummary({
    required this.planName,
    required this.planId,
    required this.edition,
    required this.status,
    required this.renewsAt,
    required this.trialEndsAt,
    required this.pools,
    required this.invoices,
    required this.exportAvailable,
    this.quotaSchemaVersion = 1,
  });

  factory AccountSummary.fromJson(Map<String, Object?> json) {
    final Object? plan = json['plan'];
    final Map<Object?, Object?> planMap = plan is Map
        ? plan
        : const <Object?, Object?>{};
    final Object? usage = json['usage'];
    final Object? invoices = json['invoices'];
    final Object? export = json['export'];
    final int schema = _quotaSchema(planMap['quotaSchemaVersion']);
    final List<AccountPool> pools = <AccountPool>[
      if (usage is List)
        for (final Object? row in usage)
          if (row is Map &&
              row['key'] is String &&
              row['label'] is String &&
              row['used'] is int &&
              (row['limit'] == null || row['limit'] is int))
            AccountPool(
              key: row['key']! as String,
              label: row['label']! as String,
              used: row['used']! as int,
              limit: row['limit'] as int?,
            ),
    ];
    if (pools.isEmpty) {
      throw const PlatformApiException(
        'Plan usage is incomplete. Try again in a moment.',
        code: 'usage_missing',
      );
    }
    return AccountSummary(
      planName: _text(planMap['name']),
      planId: _text(planMap['planId']),
      edition: _text(planMap['edition']),
      status: _text(planMap['status']),
      renewsAt: DateTime.tryParse(_text(planMap['renewsAt'])),
      trialEndsAt: DateTime.tryParse(_text(planMap['trialEndsAt'])),
      pools: pools,
      invoices: <AccountInvoice>[
        if (invoices is List)
          for (final Object? row in invoices)
            if (row is Map) AccountInvoice.fromJson(row),
      ],
      exportAvailable: export is Map && export['available'] == true,
      quotaSchemaVersion: schema,
    );
  }

  final String planName;
  final String planId;
  final String edition;
  final String status;
  final DateTime? renewsAt;
  final DateTime? trialEndsAt;

  final List<AccountPool> pools;
  final List<AccountInvoice> invoices;
  final bool exportAvailable;

  int get invoiceCount => invoices.length;
  final int quotaSchemaVersion;
}

class PlanOffer {
  const PlanOffer({
    required this.planId,
    required this.name,
    required this.tagline,
    required this.edition,
    required this.limits,
    required this.currency,
    required this.monthly,
    required this.yearly,
    required this.highlights,
    required this.canRequest,
    required this.requestReason,
    this.quotaSchemaVersion = 1,
  });

  factory PlanOffer.fromJson(Map<String, Object?> json) {
    final Object? prices = json['prices'];
    final Object? highlights = json['highlights'];
    num? price(String key) {
      final Object? value = prices is Map ? prices[key] : null;
      return value is num ? value : null;
    }

    final Object? currency = prices is Map ? prices['currency'] : null;
    final int schema = _quotaSchema(json['quotaSchemaVersion']);
    return PlanOffer(
      planId: _text(json['planId']),
      name: _text(json['name']),
      tagline: _text(json['tagline']),
      edition: _text(json['edition']),
      limits: _quotaCounts(json['limits'], schema, allowUnlimited: true),
      quotaSchemaVersion: schema,
      currency: currency is String ? currency : '',
      monthly: price('monthly'),
      yearly: price('yearly'),
      canRequest: json['canRequest'] == true,
      requestReason: _text(json['requestReason']),
      highlights: <String>[
        if (highlights is List)
          for (final Object? item in highlights)
            if (item is String && item.isNotEmpty) item,
      ],
    );
  }

  final String planId;
  final String name;
  final String tagline;
  final String edition;
  final int quotaSchemaVersion;

  final Map<String, int?> limits;
  final String currency;

  final num? monthly;
  final num? yearly;
  final List<String> highlights;
  final bool canRequest;
  final String requestReason;
}

class PlanCatalogue {
  const PlanCatalogue({
    required this.currentPlanId,
    required this.currentInterval,
    required this.plans,
    this.editionFeatures = const <String, List<String>>{},
  });

  factory PlanCatalogue.fromJson(Map<String, Object?> json) {
    final Object? rows = json['plans'];
    final Object? features = json['editionFeatures'];
    final String interval = _text(json['currentInterval']);
    return PlanCatalogue(
      currentPlanId: _text(json['currentPlanId']),
      currentInterval: interval.isEmpty ? null : interval,
      plans: <PlanOffer>[
        if (rows is List)
          for (final Object? row in rows)
            if (row is Map<String, Object?>) PlanOffer.fromJson(row),
      ],
      editionFeatures: <String, List<String>>{
        if (features is Map)
          for (final MapEntry<Object?, Object?> entry in features.entries)
            if (entry.key is String && entry.value is List)
              entry.key as String: <String>[
                for (final Object? label in entry.value as List)
                  if (label is String && label.isNotEmpty) label,
              ],
      },
    );
  }

  final String currentPlanId;

  final String? currentInterval;
  final List<PlanOffer> plans;
  final Map<String, List<String>> editionFeatures;
}

class AvailabilityResult {
  const AvailabilityResult({required this.changed, required this.usage});

  final int changed;
  final Map<String, int?> usage;
}

class RedeemedInvitation {
  const RedeemedInvitation({
    required this.customToken,
    required this.workspace,
    required this.projectId,
    required this.signInId,
  });

  final String customToken;
  final String workspace;
  final String projectId;
  final String signInId;
}

String _text(Object? value) => value is String ? value : '';

class PlatformApiClient {
  PlatformApiClient({
    http.Client? client,
    Future<String> Function()? idToken,
    String? baseUrl,
    String? workspace,
  }) : _client = client,
       _idToken = idToken,
       _baseUrl = baseUrl,
       _workspace = workspace;

  static const Duration _timeout = Duration(seconds: 20);

  final http.Client? _client;
  final Future<String> Function()? _idToken;
  final String? _baseUrl;
  final String? _workspace;

  String get _api => _baseUrl ?? WorkspaceRuntime.platformApiUrl;

  String get _workspaceName {
    final String? name = _workspace ?? WorkspaceRuntime.current?.workspace;
    if (name == null || name.isEmpty) {
      throw const PlatformApiException(
        'No company is loaded, so this action is not available.',
      );
    }
    return name;
  }

  bool get isConnected {
    final Uri? api = Uri.tryParse(_api.trim());
    return api != null && api.host.isNotEmpty;
  }

  Uri _uri(List<String> tail) => _uriOn(_api, tail);

  Uri _uriOn(String base, List<String> tail) {
    final Uri? api = Uri.tryParse(base.trim());
    if (api == null || api.host.isEmpty) {
      throw const PlatformApiException(
        'This dashboard build has no platform address.',
      );
    }
    return api.replace(
      pathSegments: <String>[
        ...api.pathSegments.where((String part) => part.isNotEmpty),
        'v1',
        ...tail,
      ],
    );
  }

  Uri _adminUri(List<String> tail) =>
      _uri(<String>['w', _workspaceName, ...tail]);

  Future<String> _bearer() async {
    try {
      final Future<String> Function()? custom = _idToken;
      final String? token = custom != null
          ? await custom()
          : await FirebaseAuth.instance.currentUser?.getIdToken();
      if (token != null && token.isNotEmpty) return token;
    } catch (_) {}
    throw const PlatformApiException(
      'Your session has expired. Please sign in again.',
    );
  }

  Future<Object?> _send(
    String method,
    Uri uri, {
    bool signedIn = true,
    Map<String, Object?>? body,
    String? idempotencyKey,
  }) async {
    final Map<String, String> headers = <String, String>{
      'Accept': 'application/json',
      if (signedIn) 'Authorization': 'Bearer ${await _bearer()}',
      if (body != null) 'Content-Type': 'application/json',
      if (idempotencyKey != null) 'Idempotency-Key': idempotencyKey,
    };
    final http.Client client = _client ?? http.Client();
    try {
      final http.Request request = http.Request(method, uri)
        ..headers.addAll(headers);
      if (body != null) request.body = jsonEncode(body);
      final http.StreamedResponse streamed = await client
          .send(request)
          .timeout(_timeout);
      final http.Response response = await http.Response.fromStream(streamed);
      final Object? decoded = _decode(response);
      if (response.statusCode >= 200 && response.statusCode < 300) {
        return decoded;
      }
      throw PlatformApiException(
        _detail(decoded, response.statusCode),
        statusCode: response.statusCode,
        code: _code(decoded),
      );
    } on PlatformApiException {
      rethrow;
    } on TimeoutException {
      throw const PlatformApiException(
        'The platform service did not answer in time. Try again.',
        code: 'unreachable',
      );
    } catch (_) {
      throw const PlatformApiException(
        'Could not reach the platform service. Check the connection and try '
        'again.',
        code: 'unreachable',
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<TenantExportPackage> createTenantExport() async {
    final Uri uri = _adminUri(<String>['exports']);
    final http.Client client = _client ?? http.Client();
    try {
      final http.Response response = await client
          .post(
            uri,
            headers: <String, String>{
              'Accept': 'application/zip',
              'Authorization': 'Bearer ${await _bearer()}',
            },
          )
          .timeout(_timeout);
      if (response.statusCode < 200 || response.statusCode >= 300) {
        final Object? decoded = _decode(response);
        throw PlatformApiException(
          _detail(decoded, response.statusCode),
          statusCode: response.statusCode,
          code: _code(decoded),
        );
      }
      final String disposition = response.headers['content-disposition'] ?? '';
      final RegExpMatch? match = RegExp(
        r'filename="([A-Za-z0-9._-]+)"',
      ).firstMatch(disposition);
      return TenantExportPackage(
        bytes: response.bodyBytes,
        filename: match?.group(1) ?? 'scoot-sales-export.zip',
      );
    } on PlatformApiException {
      rethrow;
    } on TimeoutException {
      throw const PlatformApiException(
        'The export did not finish in time. Try again.',
      );
    } catch (_) {
      throw const PlatformApiException(
        'Could not create the export. Check the connection and try again.',
      );
    } finally {
      if (_client == null) client.close();
    }
  }

  Future<SupportGrant> createSupportGrant({
    required String staffEmail,
    required String reason,
    required DateTime expiresAt,
    required String idempotencyKey,
  }) async => SupportGrant.fromJson(
    _map(
      await _send(
        'POST',
        _adminUri(<String>['support-grants']),
        body: <String, Object?>{
          'staffEmail': staffEmail,
          'scope': 'diagnostics',
          'reason': reason,
          'expiresAt':
              '${expiresAt.toUtc().toIso8601String().split('.').first}Z',
        },
        idempotencyKey: idempotencyKey,
      ),
    ),
  );

  Future<SupportGrant> revokeSupportGrant(
    SupportGrant grant, {
    required String reason,
    required String idempotencyKey,
  }) async => SupportGrant.fromJson(
    _map(
      await _send(
        'POST',
        _adminUri(<String>['support-grants', grant.grantId, 'revoke']),
        body: <String, Object?>{
          'reason': reason,
          'expectedRevision': grant.revision,
        },
        idempotencyKey: idempotencyKey,
      ),
    ),
  );

  Object? _decode(http.Response response) {
    if (response.bodyBytes.isEmpty) return null;
    try {
      return jsonDecode(utf8.decode(response.bodyBytes));
    } catch (_) {
      return null;
    }
  }

  String? _code(Object? decoded) {
    if (decoded is Map) {
      final Object? code = decoded['code'];
      if (code is String && code.isNotEmpty) return code;
    }
    return null;
  }

  String _detail(Object? decoded, int status) {
    if (decoded is Map) {
      final Object? detail = decoded['detail'];
      if (detail is String && detail.trim().isNotEmpty) return detail.trim();
      if (detail is List && detail.isNotEmpty) {
        return 'Some of the details are not valid. Check them and try again.';
      }
    }
    if (status == 401) return 'Your session has expired. Please sign in again.';
    if (status == 403) return 'You do not have permission to do that.';
    return 'The platform service could not complete the request '
        '(error $status).';
  }

  Map<String, Object?> _map(Object? value) {
    if (value is Map<String, Object?>) return value;
    throw const PlatformApiException(
      'The platform service sent an answer this dashboard cannot read.',
    );
  }

  Future<CreatedInvitation> createInvitation(
    InvitationRequest request, {
    required String idempotencyKey,
  }) async {
    final Object? body = await _send(
      'POST',
      _adminUri(<String>['invitations']),
      body: request.toJson(),
      idempotencyKey: idempotencyKey,
    );
    return CreatedInvitation.fromJson(_map(body));
  }

  Future<List<InvitationRecord>> listInvitations() async {
    final Map<String, Object?> body = _map(
      await _send('GET', _adminUri(<String>['invitations'])),
    );
    final Object? rows = body['invitations'];
    if (rows is! List) return const <InvitationRecord>[];
    return <InvitationRecord>[
      for (final Object? row in rows)
        if (row is Map<String, Object?>) InvitationRecord.fromJson(row),
    ];
  }

  Future<void> revokeInvitation(String invitationId) async {
    await _send(
      'POST',
      _adminUri(<String>['invitations', invitationId, 'revoke']),
    );
  }

  Future<void> revokeAccount(String uid) async {
    await _send('POST', _adminUri(<String>['accounts', uid, 'revoke']));
  }

  Future<void> reactivateAccount(
    String uid, {
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      _adminUri(<String>['accounts', uid, 'reactivate']),
      idempotencyKey: idempotencyKey,
    );
  }

  Future<void> changeAccountRole(
    String uid, {
    required String role,
    required String branchId,
    required String? supervisorUid,
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      _adminUri(<String>['accounts', uid, 'role']),
      body: <String, Object?>{
        'role': role,
        'branchId': branchId,
        'supervisorUid': supervisorUid,
      },
      idempotencyKey: idempotencyKey,
    );
  }

  Future<void> moveSalesperson(
    String uid, {
    required String supervisorUid,
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      _adminUri(<String>['accounts', uid, 'supervisor']),
      body: <String, Object?>{'supervisorUid': supervisorUid},
      idempotencyKey: idempotencyKey,
    );
  }

  Future<String> changeEmployeeCode(
    String uid, {
    required String employeeCode,
    required String idempotencyKey,
  }) async {
    final Map<String, Object?> body = _map(
      await _send(
        'POST',
        _adminUri(<String>['accounts', uid, 'employee-code']),
        body: <String, Object?>{'employeeCode': employeeCode},
        idempotencyKey: idempotencyKey,
      ),
    );
    return _text(body['employeeCode']);
  }

  Future<void> removeAccount(
    String uid, {
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      _adminUri(<String>['accounts', uid, 'remove']),
      idempotencyKey: idempotencyKey,
    );
  }

  Future<void> removeProfile(
    String docId, {
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      _adminUri(<String>['profiles', docId, 'remove']),
      idempotencyKey: idempotencyKey,
    );
  }

  Future<PlanUsage> getUsage() async => PlanUsage.fromJson(
    _map(await _send('GET', _adminUri(<String>['usage']))),
  );

  Future<AccountSummary> getAccount() async => AccountSummary.fromJson(
    _map(await _send('GET', _adminUri(<String>['account']))),
  );

  Future<PlanCatalogue> getPlans() async => PlanCatalogue.fromJson(
    _map(await _send('GET', _adminUri(<String>['plans']))),
  );

  Future<void> requestPlan(
    String planId, {
    required String interval,
    required String idempotencyKey,
  }) async {
    await _send(
      'POST',
      _adminUri(<String>['plan-requests']),
      body: <String, Object?>{'planId': planId, 'interval': interval},
      idempotencyKey: idempotencyKey,
    );
  }

  Future<AvailabilityResult> setProductAvailability(
    Map<String, bool> changes, {
    required String idempotencyKey,
  }) async {
    final Map<String, Object?> body = _map(
      await _send(
        'POST',
        _adminUri(<String>['products', 'availability']),
        body: <String, Object?>{
          'changes': <Map<String, Object?>>[
            for (final MapEntry<String, bool> entry in changes.entries)
              <String, Object?>{'productId': entry.key, 'visible': entry.value},
          ],
        },
        idempotencyKey: idempotencyKey,
      ),
    );
    final Object? changed = body['changed'];
    return AvailabilityResult(
      changed: changed is int ? changed : 0,
      usage: _counts(body['usage']),
    );
  }

  Future<int> deleteProducts(
    List<String> productIds, {
    required String idempotencyKey,
  }) async {
    final Map<String, Object?> body = _map(
      await _send(
        'POST',
        _adminUri(<String>['products', 'delete']),
        body: <String, Object?>{'productIds': productIds},
        idempotencyKey: idempotencyKey,
      ),
    );
    final Object? deleted = body['deleted'];
    return deleted is int ? deleted : 0;
  }

  Future<AccountReconcile> reconcileAccounts() async {
    final Map<String, Object?> body = _map(
      await _send('GET', _adminUri(<String>['accounts', 'reconcile'])),
    );
    List<AccountReconcileEntry> entries(Object? rows) =>
        <AccountReconcileEntry>[
          if (rows is List)
            for (final Object? row in rows)
              if (row is Map)
                AccountReconcileEntry(
                  uid: _text(row['uid']),
                  email: _text(row['email']),
                  disabled: row['disabled'] == true,
                  createdAt: _text(row['createdAt']),
                ),
        ];
    return AccountReconcile(
      authOnly: entries(body['authOnly']),
      profileOnly: entries(body['profileOnly']),
    );
  }

  Future<void> requestPasswordReset(String email) async {
    await _send(
      'POST',
      _adminUri(<String>['auth', 'password-reset']),
      signedIn: false,
      body: <String, Object?>{'email': email, 'client': 'dashboard'},
    );
  }

  Future<void> reportSignIn(String deviceId) async {
    await _send(
      'POST',
      _adminUri(<String>['security', 'sign-in']),
      body: <String, Object?>{'device': deviceId},
    );
  }

  Future<EmailCodeRequest> requestEmailCode({
    required String code,
    required String check,
  }) async {
    final Map<String, Object?> body = _map(
      await _send(
        'POST',
        _uri(<String>['invitations', 'email-code']),
        signedIn: false,
        body: <String, Object?>{'code': code, 'check': check},
      ),
    );
    final Object? expires = body['expiresInSeconds'];
    return EmailCodeRequest(
      isRequired: body['required'] == true,
      sentTo: _text(body['sentTo']),
      expiresInSeconds: expires is int ? expires : 0,
    );
  }

  Future<RedeemedInvitation> redeem({
    required String code,
    required String check,
    required String password,
    String device = 'Web dashboard',
    String? projectId,
    String? emailCode,
  }) async {
    final Map<String, Object?> body = _map(
      await _send(
        'POST',
        _uri(<String>['invitations', 'redeem']),
        signedIn: false,
        body: <String, Object?>{
          'code': code,
          'check': check,
          'password': password,
          'device': device,
          if (projectId != null && projectId.isNotEmpty) 'projectId': projectId,
          if (emailCode != null && emailCode.isNotEmpty) 'emailCode': emailCode,
        },
      ),
    );
    final String token = _text(body['customToken']);
    if (token.isEmpty) {
      throw const PlatformApiException(
        'The platform service sent an answer this dashboard cannot read.',
      );
    }
    return RedeemedInvitation(
      customToken: token,
      workspace: _text(body['workspace']),
      projectId: _text(body['projectId']),
      signInId: _text(body['signInId']),
    );
  }
}
