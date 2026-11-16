import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';

import 'package:connectivity_plus/connectivity_plus.dart';
import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show
        TargetPlatform,
        ValueNotifier,
        debugPrint,
        defaultTargetPlatform,
        kIsWeb;
import 'package:http/http.dart' as http;
import 'package:scoot_directory_client/scoot_directory_client.dart';
import 'package:shared_preferences/shared_preferences.dart';

import '../firebase_options.dart';

enum CompanyFailure {
  invalidCode,
  unknownCode,
  unreachable,
  tooManyTries,
  selectionRequired,
}

enum _RecordCommit { stored, stale, failed }

class CompanyException implements Exception {
  const CompanyException(this.failure);

  final CompanyFailure failure;

  String get message => switch (failure) {
    CompanyFailure.invalidCode =>
      'Company codes use 2-32 letters, numbers or hyphens.',
    CompanyFailure.unknownCode =>
      'We could not find that company code. Check it with your manager.',
    CompanyFailure.unreachable =>
      'Could not reach the company directory. Connect to the internet and try again.',
    CompanyFailure.tooManyTries =>
      'Too many tries from this network. Wait a few minutes and try again.',
    CompanyFailure.selectionRequired => 'Enter your company code to start.',
  };

  @override
  String toString() => 'CompanyException(${failure.name})';
}

class ActiveCompany {
  const ActiveCompany({
    required this.code,
    required this.name,
    required this.options,
    this.tenantId,
    this.workspace,
    this.expiresAt,
    this.authTenantId,
    this.copilotUrl,
  }) : _recordVersion = 0;

  const ActiveCompany._record({
    required this.code,
    required this.name,
    required this.options,
    required this.tenantId,
    required this.workspace,
    required this.expiresAt,
    required this.authTenantId,
    required this.copilotUrl,
    required int recordVersion,
  }) : _recordVersion = recordVersion;

  final String? code;
  final String name;
  final FirebaseOptions options;
  final String? tenantId;
  final String? workspace;
  final DateTime? expiresAt;
  final String? authTenantId;
  final String? copilotUrl;
  final int _recordVersion;
}

class CompanyProject {
  CompanyProject({
    http.Client? client,
    String? registryKeys,
    String? lookupUrl,
    String? platform,
    FirebaseOptions? defaultOptions,
    DateTime Function()? clock,
  }) : _client = client,
       _lookupUrl = lookupUrl ?? _compiledLookupUrl,
       _keys = _parseKeys(registryKeys ?? _compiledRegistryKeys),
       _platform = platform ?? _currentPlatform(),
       _clock = clock ?? DateTime.now,
       _default = defaultOptions;

  static const String _compiledRegistryKeys = String.fromEnvironment(
    'COMPANY_REGISTRY_KEYS',
  );
  static const String _compiledLookupUrl = String.fromEnvironment(
    'COMPANY_LOOKUP_URL',
  );
  static const String recordKind = 'scoot.directory.record.v1';
  static const String defaultName = 'Internal';
  static const String recordCachePrefix = 'company_record_v2:';
  static const String recordVersionPrefix = 'company_record_version_v2:';
  static const String activeRecordKey = 'company_active_v2';
  static const Duration timeout = Duration(seconds: 5);
  static const Duration renewWithin = Duration(days: 7);
  static const Duration renewRetry = Duration(seconds: 30);
  static const int _maxBytes = 512 * 1024;
  static final RegExp _codePattern = RegExp(r'^[a-z0-9-]{2,32}$');
  static Future<void> _recordCommitTail = Future<void>.value();

  static final CompanyProject instance = CompanyProject();

  final http.Client? _client;
  final String _lookupUrl;
  final Map<String, Uint8List> _keys;
  final String _platform;
  final DateTime Function() _clock;
  final FirebaseOptions? _default;
  final ValueNotifier<bool> recordExpired = ValueNotifier<bool>(false);
  Timer? _renewTimer;
  StreamSubscription<List<ConnectivityResult>>? _renewOnline;
  int _renewRun = 0;

  bool get hasDirectory =>
      _lookupConfigured && _lookupUri() != null && _keys.isNotEmpty;

  bool get _lookupConfigured => _lookupUrl.trim().isNotEmpty;

  FirebaseOptions get _defaultOptions =>
      _default ?? DefaultFirebaseOptions.currentPlatform;

  Future<ActiveCompany> active() async {
    final String? targetError = firebaseTargetError;
    if (targetError != null) throw UnsupportedError(targetError);
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (_lookupConfigured && !prefs.containsKey(activeRecordKey)) {
        throw const CompanyException(CompanyFailure.selectionRequired);
      }
      if (prefs.containsKey(activeRecordKey)) {
        try {
          final String? code = prefs.getString(activeRecordKey);
          if (code == null || !_codePattern.hasMatch(code)) {
            throw const CompanyException(CompanyFailure.unreachable);
          }
          final ActiveCompany? selected = await _cachedCompany(
            code,
            allowExpired: true,
          );
          if (selected == null) {
            throw const CompanyException(CompanyFailure.unreachable);
          }
          return selected;
        } on CompanyException {
          rethrow;
        } catch (_) {
          throw const CompanyException(CompanyFailure.unreachable);
        }
      }
    } on CompanyException {
      rethrow;
    } catch (error) {
      if (_lookupConfigured) {
        throw const CompanyException(CompanyFailure.unreachable);
      }
      debugPrint('Saved company unreadable, using the default company: $error');
    }
    return ActiveCompany(
      code: null,
      name: defaultName,
      options: _defaultOptions,
    );
  }

  Future<String?> savedCode() async => (await active()).code;

  Future<FirebaseOptions> resolve(String code) async =>
      (await resolveCompany(code)).options;

  Future<ActiveCompany> resolveCompany(String code) async {
    final String normalised = _normalise(code);
    if (!_lookupConfigured) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    return _resolveRecord(normalised);
  }

  Future<void> save(String code) async {
    final String normalised = _normalise(code);
    if (!_lookupConfigured) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    await _resolveRecord(normalised);
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (!await prefs.setString(activeRecordKey, normalised)) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
  }

  Future<void> forget() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    await prefs.remove(activeRecordKey);
  }

  Future<ActiveCompany?> refreshSelected() async {
    if (!_lookupConfigured) return null;
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      if (!prefs.containsKey(activeRecordKey)) return null;
      final String? code = prefs.getString(activeRecordKey);
      if (code == null || !_codePattern.hasMatch(code)) {
        throw const CompanyException(CompanyFailure.unreachable);
      }
      return _resolveRecord(code, allowCacheOnFailure: false);
    } on CompanyException {
      rethrow;
    } catch (_) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
  }

  bool isExpired(ActiveCompany company) {
    final DateTime? expiresAt = company.expiresAt;
    return expiresAt != null && !expiresAt.isAfter(_clock().toUtc());
  }

  void keepRecordFresh(
    ActiveCompany company,
    void Function(ActiveCompany renewed) onRenewed,
  ) {
    final int run = ++_renewRun;
    _stopRenewal();
    recordExpired.value = isExpired(company);
    final String? code = company.code;
    final DateTime? expiresAt = company.expiresAt;
    if (!_lookupConfigured ||
        code == null ||
        company._recordVersion < 1 ||
        expiresAt == null ||
        expiresAt.difference(_clock().toUtc()) > renewWithin) {
      return;
    }
    bool attempting = false;
    Future<void> attempt() async {
      if (attempting || run != _renewRun) return;
      attempting = true;
      try {
        final ActiveCompany renewed = await _resolveRecord(
          code,
          allowCacheOnFailure: false,
          sameLocationAs: company,
        );
        if (run != _renewRun) return;
        _stopRenewal();
        recordExpired.value = isExpired(renewed);
        onRenewed(renewed);
      } catch (_) {
      } finally {
        attempting = false;
      }
    }

    _renewTimer = Timer.periodic(renewRetry, (_) => unawaited(attempt()));
    try {
      _renewOnline = Connectivity().onConnectivityChanged.listen((
        List<ConnectivityResult> results,
      ) {
        if (results.any(
          (ConnectivityResult result) => result != ConnectivityResult.none,
        )) {
          unawaited(attempt());
        }
      }, onError: (Object _) {});
    } catch (_) {}
    unawaited(attempt());
  }

  void _stopRenewal() {
    _renewTimer?.cancel();
    _renewTimer = null;
    unawaited(_renewOnline?.cancel());
    _renewOnline = null;
  }

  static bool _sameLocation(ActiveCompany expected, ActiveCompany next) =>
      next.tenantId == expected.tenantId &&
      next.options.projectId == expected.options.projectId &&
      next.authTenantId == expected.authTenantId &&
      next._recordVersion >= expected._recordVersion;

  String _normalise(String code) {
    final String lower = code.trim().toLowerCase();
    if (!_codePattern.hasMatch(lower)) {
      throw const CompanyException(CompanyFailure.invalidCode);
    }
    return lower;
  }

  Future<ActiveCompany> _resolveRecord(
    String code, {
    bool allowCacheOnFailure = true,
    ActiveCompany? sameLocationAs,
  }) async {
    final Uri? base = _lookupUri();
    if (base == null || _keys.isEmpty) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    final ActiveCompany? cached = await _cachedCompany(code);
    bool cacheWriteFailed = false;
    try {
      final Uri uri = base.replace(
        pathSegments: <String>[
          ...base.pathSegments.where((String part) => part.isNotEmpty),
          code,
        ],
      );
      final http.Client client = _client ?? http.Client();
      try {
        final http.Response response = await client.get(uri).timeout(timeout);
        if (response.statusCode == 404) {
          if (allowCacheOnFailure && cached != null) return cached;
          throw const CompanyException(CompanyFailure.unknownCode);
        }
        if (response.statusCode == 429) {
          throw const CompanyException(CompanyFailure.tooManyTries);
        }
        if (response.statusCode != 200 ||
            response.bodyBytes.length > _maxBytes) {
          throw const CompanyException(CompanyFailure.unreachable);
        }
        final String envelopeText = utf8.decode(response.bodyBytes);
        final int floor = await _recordFloor(code);
        final int minimum = cached == null
            ? floor
            : (cached._recordVersion > floor ? cached._recordVersion : floor);
        final Map<String, Object?> payload = await SignedEnvelope.verify(
          jsonDecode(envelopeText),
          keys: _keys,
          kind: recordKind,
          minVersion: minimum,
          now: _clock(),
        );
        final ActiveCompany company = _parseRecord(code, payload);
        if (sameLocationAs != null && !_sameLocation(sameLocationAs, company)) {
          throw const CompanyException(CompanyFailure.unreachable);
        }
        final _RecordCommit committed = await _storeRecord(
          code,
          envelopeText,
          company._recordVersion,
        );
        if (committed == _RecordCommit.stale) {
          final ActiveCompany? latest = await _cachedCompany(code);
          if (allowCacheOnFailure &&
              latest != null &&
              latest._recordVersion > company._recordVersion) {
            return latest;
          }
          throw const CompanyException(CompanyFailure.unreachable);
        }
        if (committed == _RecordCommit.failed) {
          cacheWriteFailed = true;
          throw const CompanyException(CompanyFailure.unreachable);
        }
        return company;
      } finally {
        if (_client == null) client.close();
      }
    } on CompanyException catch (error) {
      if (cacheWriteFailed) rethrow;
      if (allowCacheOnFailure) {
        final ActiveCompany? latest = await _cachedCompany(code);
        if (latest != null) return latest;
      }
      if (error.failure == CompanyFailure.unknownCode) rethrow;
      rethrow;
    } catch (_) {
      if (allowCacheOnFailure) {
        final ActiveCompany? latest = await _cachedCompany(code);
        if (latest != null) return latest;
      }
      throw const CompanyException(CompanyFailure.unreachable);
    }
  }

  Future<int> _recordFloor(String code) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      return prefs.getInt('$recordVersionPrefix$code') ?? 0;
    } catch (_) {
      return 0;
    }
  }

  Future<ActiveCompany?> _cachedCompany(
    String code, {
    bool allowExpired = false,
  }) async {
    try {
      final SharedPreferences prefs = await SharedPreferences.getInstance();
      final String? envelope = prefs.getString('$recordCachePrefix$code');
      if (envelope == null) return null;
      final Map<String, Object?> payload = await SignedEnvelope.verify(
        jsonDecode(envelope),
        keys: _keys,
        kind: recordKind,
        minVersion: await _recordFloor(code),
        now: _clock(),
        allowExpired: allowExpired,
      );
      return _parseRecord(code, payload, allowExpired: allowExpired);
    } catch (_) {
      return null;
    }
  }

  Future<_RecordCommit> _storeRecord(
    String code,
    String envelope,
    int version,
  ) {
    final Completer<_RecordCommit> result = Completer<_RecordCommit>();
    _recordCommitTail = _recordCommitTail.then((_) async {
      try {
        result.complete(await _storeRecordLocked(code, envelope, version));
      } catch (_) {
        result.complete(_RecordCommit.failed);
      }
    });
    return result.future;
  }

  Future<_RecordCommit> _storeRecordLocked(
    String code,
    String envelope,
    int version,
  ) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String floorKey = '$recordVersionPrefix$code';
    final int floor = prefs.getInt(floorKey) ?? 0;
    final ActiveCompany? cached = await _cachedCompany(code);
    final int cachedVersion = cached?._recordVersion ?? 0;
    final int currentVersion = floor > cachedVersion ? floor : cachedVersion;
    if (version < currentVersion) return _RecordCommit.stale;
    final String cacheKey = '$recordCachePrefix$code';
    if (!await prefs.setString(cacheKey, envelope)) {
      return _RecordCommit.failed;
    }
    if (version > floor && !await prefs.setInt(floorKey, version)) {
      return _RecordCommit.failed;
    }
    return _RecordCommit.stored;
  }

  ActiveCompany _parseRecord(
    String requestedCode,
    Map<String, Object?> data, {
    bool allowExpired = false,
  }) {
    if (data['companyCode'] != requestedCode) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    final String? tenantId = _validText(
      data['tenantId'],
      RegExp(r'^t_[a-z0-9]{6,32}$'),
    );
    final String? workspace = _validText(
      data['workspace'],
      RegExp(r'^[a-z0-9](?:[a-z0-9-]{1,30}[a-z0-9])$'),
    );
    final String? legalName = _validText(
      data['legalName'],
      RegExp(r'^[^\x00-\x1f\x7f]{1,120}$'),
    );
    final Object? rawLocation = data['location'];
    final Object? rawConfig = data['clientConfig'];
    if (tenantId == null ||
        workspace == null ||
        legalName == null ||
        rawLocation is! Map ||
        rawConfig is! Map ||
        !rawLocation.containsKey('databaseId') ||
        !rawLocation.containsKey('authTenantId') ||
        rawLocation.keys.toSet().difference(const <String>{
          'projectId',
          'databaseId',
          'authTenantId',
        }).isNotEmpty ||
        rawLocation['databaseId'] != '(default)') {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    final String? projectId = _validText(
      rawLocation['projectId'],
      RegExp(r'^[a-z][a-z0-9-]{4,29}$'),
    );
    final Object? rawAuthTenant = rawLocation['authTenantId'];
    final String? authTenantId = rawAuthTenant == null
        ? null
        : _validText(rawAuthTenant, RegExp(r'^[A-Za-z0-9-]{4,63}$'));
    if (projectId == null || (rawAuthTenant != null && authTenantId == null)) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    final Object? rawExpiry = data['expiresAt'];
    final DateTime? expiresAt = rawExpiry is String
        ? DateTime.tryParse(rawExpiry)
        : null;
    if (expiresAt == null ||
        (!allowExpired && !expiresAt.toUtc().isAfter(_clock().toUtc()))) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    final Map<String, Object?> entry = <String, Object?>{
      'projectId': projectId,
      'apiKey': rawConfig['apiKey'],
      'appId': rawConfig['appId'],
      'messagingSenderId': rawConfig['messagingSenderId'],
      'storageBucket': rawConfig['storageBucket'],
      'iosBundleId': rawConfig['iosBundleId'],

      'name': 'Verified company',
    };
    final ActiveCompany? parsed = _parseEntry(requestedCode, entry, _platform);
    if (parsed == null) {
      throw const CompanyException(CompanyFailure.unreachable);
    }
    final Object? rawServices = data['services'];
    final Object? rawCopilotUrl = rawServices is Map
        ? rawServices['copilotUrl']
        : null;
    final String? copilotUrl =
        rawCopilotUrl is String && checkedServiceUri(rawCopilotUrl) != null
        ? rawCopilotUrl
        : null;
    return ActiveCompany._record(
      code: requestedCode,
      name: legalName,
      options: parsed.options,
      tenantId: tenantId,
      workspace: workspace,
      expiresAt: expiresAt.toUtc(),
      authTenantId: authTenantId,
      copilotUrl: copilotUrl,
      recordVersion: data['version'] as int,
    );
  }

  static String? _validText(Object? value, RegExp pattern) =>
      value is String && pattern.hasMatch(value) ? value : null;

  Uri? _lookupUri() => checkedServiceUri(_lookupUrl);

  static Map<String, Uint8List> _parseKeys(String text) {
    try {
      return SignedEnvelope.parseKeys(text);
    } on SignedEnvelopeException {
      return const <String, Uint8List>{};
    }
  }

  static ActiveCompany? _parseEntry(
    String code,
    Object? entry,
    String platform,
  ) {
    if (entry is! Map) return null;
    String? text(Object? value, RegExp pattern) {
      final Object? picked = value is Map ? value[platform] : value;
      return picked is String && pattern.hasMatch(picked) ? picked : null;
    }

    final String? projectId = text(
      entry['projectId'],
      RegExp(r'^[a-z][a-z0-9-]{4,29}$'),
    );
    final String? apiKey = text(
      entry['apiKey'],
      RegExp(r'^AIza[0-9A-Za-z_-]{35}$'),
    );
    final String? sender = text(
      entry['messagingSenderId'],
      RegExp(r'^\d{6,20}$'),
    );
    final String? appId = text(
      entry['appId'],
      RegExp(r'^\d+:\d+:(android|ios|web):[0-9a-f]+$'),
    );
    final String? name = text(entry['name'], RegExp(r'^[^\r\n]{1,60}$'));
    final Object? bucketRaw = entry['storageBucket'];
    final String? bucket = bucketRaw == null
        ? null
        : text(bucketRaw, RegExp(r'^[a-z0-9][a-z0-9.-]{2,}$'));
    if (projectId == null ||
        apiKey == null ||
        sender == null ||
        appId == null ||
        name == null) {
      return null;
    }
    if (bucketRaw != null && bucket == null) return null;
    final List<String> parts = appId.split(':');
    if (parts[1] != sender || parts[2] != platform) return null;
    return ActiveCompany(
      code: code,
      name: name,
      options: FirebaseOptions(
        apiKey: apiKey,
        appId: appId,
        messagingSenderId: sender,
        projectId: projectId,
        storageBucket: bucket,
        authDomain: platform == 'web' ? '$projectId.firebaseapp.com' : null,
        iosBundleId: platform == 'ios'
            ? text(entry['iosBundleId'], RegExp(r'^[A-Za-z0-9.-]{3,155}$'))
            : null,
      ),
    );
  }

  static String _currentPlatform() {
    if (kIsWeb) return 'web';
    return defaultTargetPlatform == TargetPlatform.iOS ? 'ios' : 'android';
  }
}
