import 'dart:convert';
import 'dart:typed_data';

import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:http/http.dart' as http;
import 'package:scoot_directory_client/scoot_directory_client.dart';

import '../services/forecast_snapshot_storage.dart';
import 'invite_link.dart';

class WorkspaceConfig {
  const WorkspaceConfig({
    required this.tenantId,
    required this.workspace,
    required this.legalName,
    required this.companyCode,
    required this.status,
    required this.planRef,
    required this.edition,
    required this.releaseRing,
    required this.rulesVersion,
    required this.version,
    this.authTenantId,
    this.appCheckSiteKey,
    required this.options,
    required this.services,
  });

  final String tenantId;
  final String workspace;
  final String legalName;
  final String companyCode;
  final String status;
  final String planRef;

  final String edition;
  final String releaseRing;
  final String rulesVersion;
  final int version;
  final String? authTenantId;
  final String? appCheckSiteKey;
  final FirebaseOptions options;

  final Map<String, String> services;

  bool get isBasicEdition => edition == 'basic';
}

class WorkspaceLoadException implements Exception {
  const WorkspaceLoadException(this.message);

  final String message;

  @override
  String toString() => message;
}

class _RecordUnavailable implements Exception {
  const _RecordUnavailable(this.message);

  final String message;
}

class WorkspaceRuntime {
  WorkspaceRuntime._();

  static const String recordKind = 'scoot.directory.record.v1';
  static const String _versionKeyPrefix = 'workspace_record_version_v1.';
  static const String _envelopeKeyPrefix = 'workspace_envelope_v1.';
  static const Duration _timeout = Duration(seconds: 8);
  static const int _maxBytes = 512 * 1024;
  static const Set<String> unservedRecordStatuses = <String>{
    'lead',
    'deleted',
  };
  static const Set<String> openStatuses = <String>{
    'active',
    'past_due',
  };
  static final RegExp _workspacePattern = RegExp(
    r'^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$',
  );
  static const Set<String> _serviceNames = <String>{
    'forecastingUrl',
    'copilotUrl',
  };

  static const String platformApiUrl = String.fromEnvironment(
    'PLATFORM_API_URL',
  );

  static const String publicKeysText = String.fromEnvironment(
    'PLATFORM_PUBLIC_KEYS',
  );

  static WorkspaceConfig? current;

  static String loadError = '';

  static String? workspaceFromUrl(Uri url) {
    final List<String> segments = url.pathSegments
        .where((String segment) => segment.isNotEmpty)
        .toList(growable: false);
    final int index = segments.indexOf('w');
    final String? candidate = index < 0 || index + 1 >= segments.length
        ? (segments.lastOrNull == InviteLink.pathSegment
              ? InviteLink.fromUri(url)?.workspace
              : null)
        : segments[index + 1];
    return candidate != null && _workspacePattern.hasMatch(candidate)
        ? candidate
        : null;
  }

  static Future<WorkspaceConfig> load(
    Uri url, {
    http.Client? client,
    ForecastSnapshotStorage? storage,
    String? keysText,
    String? apiUrl,
    DateTime? now,
  }) async {
    final Map<String, Uint8List> keys;
    try {
      keys = SignedEnvelope.parseKeys(keysText ?? publicKeysText);
    } on SignedEnvelopeException {
      throw const WorkspaceLoadException(
        'This dashboard build has invalid company signing keys.',
      );
    }
    if (keys.isEmpty) {
      throw const WorkspaceLoadException(
        'This dashboard build has no company signing keys.',
      );
    }
    final String? workspace = workspaceFromUrl(url);
    final ForecastSnapshotStorage store =
        storage ?? createForecastSnapshotStorage();
    final Object? remembered = workspace == null
        ? null
        : _rememberedEnvelope(store, workspace);
    final String code = workspace == null
        ? ''
        : _companyCodeOf(remembered) ?? workspace;
    final Uri source = _source(url, workspace, code, apiUrl ?? platformApiUrl);

    Object? envelope;
    bool fromStore = false;
    try {
      envelope = await _fetch(source, client);
    } on _RecordUnavailable catch (error) {
      if (remembered == null) throw WorkspaceLoadException(error.message);
      envelope = remembered;
      fromStore = true;
    }
    final Map<String, Object?> payload;
    final String tenantKey = _tenantOf(envelope);
    try {
      payload = await SignedEnvelope.verify(
        envelope,
        keys: keys,
        kind: recordKind,
        minVersion: _lastSeen(store, tenantKey),
        now: now,
      );
    } on SignedEnvelopeException {
      throw WorkspaceLoadException(
        fromStore
            ? 'The company record is unavailable. Try again shortly.'
            : 'The company record could not be verified. Do not sign in; '
                  'contact support.',
      );
    }
    final WorkspaceConfig config = _parse(payload);
    if (workspace != null && config.workspace != workspace) {
      throw const WorkspaceLoadException(
        'The company record does not match this address.',
      );
    }
    if (config.tenantId != tenantKey) {
      throw const WorkspaceLoadException(
        'The company record could not be verified.',
      );
    }
    if (unservedRecordStatuses.contains(config.status)) {
      throw WorkspaceLoadException(
        'The ${config.legalName} workspace is not active. Contact your '
        'administrator.',
      );
    }
    _remember(store, config.tenantId, config.version);
    if (workspace != null && !fromStore) {
      _rememberEnvelope(store, workspace, envelope);
    }
    current = config;
    loadError = '';
    return config;
  }

  static Uri _source(Uri url, String? workspace, String code, String apiUrl) {
    if (workspace == null) return url.resolve('/workspace.json');
    final Uri? api = checkedServiceUri(apiUrl.trim());
    if (api == null) {
      throw const WorkspaceLoadException(
        'This dashboard build has no platform address.',
      );
    }
    return api.replace(
      pathSegments: <String>[
        ...api.pathSegments.where((String part) => part.isNotEmpty),
        'v1',
        'companies',
        code,
      ],
    );
  }

  static Future<Object?> _fetch(Uri source, http.Client? client) async {
    final http.Client httpClient = client ?? http.Client();
    try {
      final http.Response response = await httpClient
          .get(source)
          .timeout(_timeout);
      if (response.statusCode == 404) {
        throw const WorkspaceLoadException('This workspace does not exist.');
      }
      if (response.statusCode != 200 || response.bodyBytes.length > _maxBytes) {
        throw const _RecordUnavailable(
          'The company record is unavailable. Try again shortly.',
        );
      }
      return jsonDecode(utf8.decode(response.bodyBytes));
    } on WorkspaceLoadException {
      rethrow;
    } on _RecordUnavailable {
      rethrow;
    } catch (_) {
      throw const _RecordUnavailable(
        'The company record is unavailable. Check the connection and reload.',
      );
    } finally {
      if (client == null) httpClient.close();
    }
  }

  static String _tenantOf(Object? envelope) {
    try {
      final Object? payload = jsonDecode(
        (envelope as Map<String, Object?>)['payload']! as String,
      );
      final Object? tenant = (payload as Map<String, Object?>)['tenantId'];
      if (tenant is String && tenant.isNotEmpty) return tenant;
    } catch (_) {}
    throw const WorkspaceLoadException(
      'The company record could not be verified.',
    );
  }

  static Object? _rememberedEnvelope(
    ForecastSnapshotStorage store,
    String workspace,
  ) {
    try {
      final String? text = store.read('$_envelopeKeyPrefix$workspace');
      return text == null ? null : jsonDecode(text);
    } catch (_) {
      return null;
    }
  }

  static void _rememberEnvelope(
    ForecastSnapshotStorage store,
    String workspace,
    Object? envelope,
  ) {
    try {
      store.write('$_envelopeKeyPrefix$workspace', jsonEncode(envelope));
    } catch (_) {
    }
  }

  static String? _companyCodeOf(Object? envelope) {
    try {
      final Object? payload = jsonDecode(
        (envelope! as Map<String, Object?>)['payload']! as String,
      );
      final Object? code = (payload! as Map<String, Object?>)['companyCode'];
      return code is String && _workspacePattern.hasMatch(code) ? code : null;
    } catch (_) {
      return null;
    }
  }

  static int _lastSeen(ForecastSnapshotStorage store, String tenantId) {
    try {
      return int.tryParse(store.read('$_versionKeyPrefix$tenantId') ?? '') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  static void _remember(
    ForecastSnapshotStorage store,
    String tenantId,
    int version,
  ) {
    try {
      if (version > _lastSeen(store, tenantId)) {
        store.write('$_versionKeyPrefix$tenantId', '$version');
      }
    } catch (_) {
    }
  }

  static WorkspaceConfig _parse(Map<String, Object?> payload) {
    String text(Object? value) {
      if (value is String && value.isNotEmpty) return value;
      throw const WorkspaceLoadException('The company record is incomplete.');
    }

    String web(Object? value) => text(value is Map ? value['web'] : value);

    final Object? location = payload['location'];
    final Object? clientConfig = payload['clientConfig'];
    if (location is! Map || clientConfig is! Map) {
      throw const WorkspaceLoadException('The company record is incomplete.');
    }
    final String projectId = text(location['projectId']);
    final Object? bucket = clientConfig['storageBucket'];
    final Object? rawServices = payload['services'];
    final Object? authTenant = location['authTenantId'];
    final Object? siteKey = clientConfig['appCheckSiteKey'];
    if (authTenant != null && (authTenant is! String ||
        !RegExp(r'^[A-Za-z0-9-]{4,63}$').hasMatch(authTenant))) {
      throw const WorkspaceLoadException('The company sign-in configuration is invalid.');
    }
    if (location['databaseId'] != '(default)') {
      throw const WorkspaceLoadException('Company setup is not supported by this app version.');
    }
    final Map<String, String> services = <String, String>{
      if (rawServices is Map)
        for (final MapEntry<Object?, Object?> entry in rawServices.entries)
          if (entry.key is String &&
              _serviceNames.contains(entry.key) &&
              entry.value is String)
            entry.key! as String: entry.value! as String,
    };
    if (rawServices is Map &&
        rawServices.keys.any(
          (Object? key) => key is! String || !_serviceNames.contains(key),
        )) {
      throw const WorkspaceLoadException(
        'The company record contains an unsupported service.',
      );
    }
    return WorkspaceConfig(
      tenantId: text(payload['tenantId']),
      workspace: text(payload['workspace']),
      legalName: text(payload['legalName']),
      companyCode: text(payload['companyCode']),
      status: text(payload['status']),
      planRef: text(payload['planRef']),
      edition: payload['edition'] == 'basic' ? 'basic' : 'advanced',
      releaseRing: text(payload['releaseRing']),
      rulesVersion: text(payload['rulesVersion']),
      version: payload['version']! as int,
      authTenantId: authTenant as String?,
      appCheckSiteKey:
          siteKey is String && RegExp(r'^[A-Za-z0-9_-]{40}$').hasMatch(siteKey)
          ? siteKey
          : null,
      services: services,
      options: FirebaseOptions(
        apiKey: web(clientConfig['apiKey']),
        appId: web(clientConfig['appId']),
        messagingSenderId: text(clientConfig['messagingSenderId']),
        projectId: projectId,
        authDomain: '$projectId.firebaseapp.com',
        storageBucket: bucket is String ? bucket : null,
      ),
    );
  }
}
