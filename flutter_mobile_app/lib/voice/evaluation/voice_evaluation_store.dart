import 'dart:async';
import 'dart:convert';
import 'dart:math';

import 'package:shared_preferences/shared_preferences.dart';

class VoiceEvaluationEvent {
  const VoiceEvaluationEvent({
    required this.trialId,
    required this.action,
    required this.result,
    required this.durationMs,
    required this.provider,
    required this.confirmation,
    required this.occurredAt,
  });

  final String trialId;
  final String action;
  final String result;
  final int durationMs;
  final String provider;
  final bool confirmation;
  final DateTime occurredAt;

  Map<String, Object> toJson() {
    return <String, Object>{
      'trialId': trialId,
      'action': action,
      'result': result,
      'durationMs': durationMs,
      'provider': provider,
      'confirmation': confirmation,
      'occurredAt': occurredAt.toUtc().toIso8601String(),
    };
  }

  static VoiceEvaluationEvent? fromJson(Object? raw) {
    if (raw is! Map) return null;
    final String trialId = raw['trialId']?.toString().trim() ?? '';
    final String action = raw['action']?.toString().trim() ?? '';
    final String result = raw['result']?.toString().trim() ?? '';
    final String provider = raw['provider']?.toString().trim() ?? '';
    final DateTime? occurredAt = DateTime.tryParse(
      raw['occurredAt']?.toString() ?? '',
    );
    final Object? duration = raw['durationMs'];
    if (trialId.isEmpty ||
        action.isEmpty ||
        result.isEmpty ||
        provider.isEmpty ||
        occurredAt == null ||
        duration is! num) {
      return null;
    }
    return VoiceEvaluationEvent(
      trialId: trialId,
      action: action,
      result: result,
      durationMs: duration.toInt().clamp(0, 86400000),
      provider: provider,
      confirmation: raw['confirmation'] == true,
      occurredAt: occurredAt.toUtc(),
    );
  }
}

class VoiceEvaluationStore {
  VoiceEvaluationStore({
    bool enabled = true,
    Future<SharedPreferences> Function()? preferencesLoader,
    DateTime Function()? now,
    Random? random,
  }) : _enabled = enabled,
       _preferencesLoader = preferencesLoader ?? SharedPreferences.getInstance,
       _now = now ?? DateTime.now,
       _random = random ?? Random.secure();

  static const String storageKey = 'fyp_a_voice_evaluation.v1';
  static const int maxEvents = 1000;
  static const Duration retention = Duration(days: 7);

  static Future<void> _writeQueue = Future<void>.value();

  final bool _enabled;
  final Future<SharedPreferences> Function() _preferencesLoader;
  final DateTime Function() _now;
  final Random _random;

  bool get enabled => _enabled;

  Future<void> record({
    required String action,
    required String result,
    required int durationMs,
    required String provider,
    required bool confirmation,
  }) async {
    if (!_enabled) return;
    final VoiceEvaluationEvent event = VoiceEvaluationEvent(
      trialId: _newTrialId(),
      action: _safeToken(action),
      result: _safeToken(result),
      durationMs: durationMs.clamp(0, 86400000),
      provider: _safeToken(provider),
      confirmation: confirmation,
      occurredAt: _now().toUtc(),
    );
    await _enqueue<void>(() async {
      final SharedPreferences preferences = await _preferencesLoader();
      final List<VoiceEvaluationEvent> events = _read(preferences)..add(event);
      await _write(
        preferences,
        _prune(events, referenceTime: event.occurredAt),
      );
    });
  }

  Future<List<VoiceEvaluationEvent>> read() async {
    if (!_enabled) return const <VoiceEvaluationEvent>[];
    return _enqueue<List<VoiceEvaluationEvent>>(() async {
      final SharedPreferences preferences = await _preferencesLoader();
      return _prune(_read(preferences), referenceTime: _now().toUtc());
    });
  }

  Future<String> exportJson() async {
    final List<VoiceEvaluationEvent> events = await read();
    return jsonEncode(events.map((event) => event.toJson()).toList());
  }

  Future<void> clear() async {
    if (!_enabled) return;
    await _enqueue<void>(() async {
      final SharedPreferences preferences = await _preferencesLoader();
      await preferences.remove(storageKey);
    });
  }

  List<VoiceEvaluationEvent> _read(SharedPreferences preferences) {
    final String? raw = preferences.getString(storageKey);
    if (raw == null || raw.isEmpty) return <VoiceEvaluationEvent>[];
    try {
      final Object? decoded = jsonDecode(raw);
      if (decoded is! List) return <VoiceEvaluationEvent>[];
      return decoded
          .map(VoiceEvaluationEvent.fromJson)
          .whereType<VoiceEvaluationEvent>()
          .toList();
    } catch (_) {
      return <VoiceEvaluationEvent>[];
    }
  }

  Future<void> _write(
    SharedPreferences preferences,
    List<VoiceEvaluationEvent> events,
  ) async {
    await preferences.setString(
      storageKey,
      jsonEncode(events.map((event) => event.toJson()).toList()),
    );
  }

  List<VoiceEvaluationEvent> _prune(
    List<VoiceEvaluationEvent> events, {
    required DateTime referenceTime,
  }) {
    final DateTime cutoff = referenceTime.subtract(retention);
    final List<VoiceEvaluationEvent> retained = events
        .where((event) => !event.occurredAt.isBefore(cutoff))
        .toList();
    if (retained.length <= maxEvents) return retained;
    return retained.sublist(retained.length - maxEvents);
  }

  String _newTrialId() {
    final int first = _random.nextInt(1 << 32);
    final int second = _random.nextInt(1 << 32);
    return '${first.toRadixString(16).padLeft(8, '0')}-'
        '${second.toRadixString(16).padLeft(8, '0')}';
  }

  String _safeToken(String value) {
    final String token = value.trim().toLowerCase();
    if (token.isEmpty) return 'unknown';
    return token.length <= 80 ? token : token.substring(0, 80);
  }

  Future<T> _enqueue<T>(Future<T> Function() operation) {
    final Future<T> result = _writeQueue.then<T>((_) => operation());
    _writeQueue = result.then<void>((_) {}, onError: (_, _) {});
    return result;
  }
}
