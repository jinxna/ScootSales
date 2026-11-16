import 'dart:async';

import 'package:flutter/foundation.dart';
import 'package:flutter/services.dart' show PlatformException;

import '../edition.dart';
import '../models/user_model.dart';
import '../voice/core/voice_engine.dart';
import '../voice/core/voice_types.dart';
import '../voice/evaluation/voice_evaluation_store.dart';
import '../voice/mobile_voice_feature_config.dart';
import '../voice/platform/android_on_device_speech_session.dart';
import '../voice/platform/ios_on_device_speech_session.dart';
import '../voice/ui/mobile_voice_speech_session.dart';
import 'mobile_copilot_answers.dart';
import 'mobile_copilot_commands.dart';
import 'mobile_copilot_grammar.dart';
import 'mobile_copilot_server.dart';

enum CopilotMessageKind { user, answer, error, confirm }

class CopilotMessage {
  const CopilotMessage.user(this.text)
    : kind = CopilotMessageKind.user,
      notice = '',
      answer = null,
      command = null;
  const CopilotMessage.answer(CopilotAnswer this.answer)
    : kind = CopilotMessageKind.answer,
      notice = '',
      text = '',
      command = null;

  const CopilotMessage.error(this.text, {this.notice = ''})
    : kind = CopilotMessageKind.error,
      answer = null,
      command = null;

  const CopilotMessage.confirm(CopilotPendingCommand this.command)
    : kind = CopilotMessageKind.confirm,
      notice = '',
      text = '',
      answer = null;

  final CopilotMessageKind kind;
  final String text;

  final String notice;
  final CopilotAnswer? answer;
  final CopilotPendingCommand? command;
}

const List<String> kCopilotBasicFollowUps = <String>[
  'What is my next stop?',
  'Stops left today',
  'Show my orders this week',
];

const String kCopilotSpeechUnavailable =
    'Speech is not available. Type your question instead.';

MobileVoiceSpeechAdapter _defaultSpeechAdapter() {
  if (defaultTargetPlatform == TargetPlatform.android) {
    return AndroidOnDeviceVoiceSpeechSession();
  }
  if (defaultTargetPlatform == TargetPlatform.iOS) {
    return IosOnDeviceVoiceSpeechSession();
  }
  return const UnavailableMobileVoiceSpeechAdapter();
}

class MobileCopilotController extends ChangeNotifier {
  MobileCopilotController({MobileVoiceSpeechAdapterFactory? speechFactory})
    : _speechFactory = speechFactory ?? _defaultSpeechAdapter;

  final MobileVoiceSpeechAdapterFactory _speechFactory;

  UserModel? _user;
  MobileCopilotAnswers? _answers;
  MobileCopilotServer? _server;
  MobileVoiceSpeechAdapter? _speech;

  final List<CopilotMessage> _messages = <CopilotMessage>[];
  List<String> _followUps = const <String>[];
  String _firstRetailer = '';
  bool _retailerLoaded = false;
  bool _busy = false;
  bool _listening = false;
  bool _preparing = false;
  bool _micIntroSeen = false;
  int _captureNumber = 0;
  CopilotScreenContext? _screen;
  VoiceEvaluationStore? _evaluation;
  String _partial = '';
  int _generation = 0;

  void Function(CopilotDestination destination)? openHandler;

  VoidCallback? closeHandler;

  bool online = false;

  List<CopilotMessage> get messages =>
      List<CopilotMessage>.unmodifiable(_messages);
  bool get isEmpty => _messages.isEmpty;
  bool get busy => _busy;
  bool get listening => _listening;

  bool get preparing => _preparing;
  CopilotScreenContext? get screen => _screen;
  VoiceEvaluationStore? get evaluation => _evaluation;
  bool get micIntroSeen => _micIntroSeen;
  String get partial => _partial;

  List<String> get suggestions {
    if (_busy) return const <String>[];
    if (_messages.any(
      (CopilotMessage m) => m.command?.state == CopilotCommandState.pending,
    )) {
      return const <String>[];
    }
    if (_messages.isEmpty) {
      return <String>[
        ...?_screen?.suggestions,
        'What is my next stop?',
        'Stops left today',
        'Show my orders this week',
        if (!kBasicEdition && _firstRetailer.isNotEmpty)
          'Show the visit brief for $_firstRetailer',
        'How much did I sell this week?',
        if (_firstRetailer.isNotEmpty)
          'What did $_firstRetailer order last time?',
        'Open my route',
        "Show this week's route",
      ];
    }
    return _followUps.isEmpty
        ? (_screen?.suggestions ?? const <String>[])
        : _followUps;
  }

  void syncUser(UserModel? user) {
    if (user?.uid == _user?.uid) return;
    _clear();
    _user = user;
    _answers = null;
    _server = null;
    _firstRetailer = '';
    _retailerLoaded = false;
    notifyListeners();
  }

  Future<void> loadFirstRetailer() async {
    final UserModel? user = _user;
    if (user == null || _retailerLoaded) return;
    _retailerLoaded = true;
    try {
      _answers ??= MobileCopilotAnswers(user, isOnline: () => online);
      final String name = await _answers!.firstBriefRetailer();
      if (_user?.uid != user.uid) return;
      _firstRetailer = name;
      notifyListeners();
    } catch (_) {
    }
  }

  void attachScreen(CopilotScreenContext? screen) {
    if (identical(screen, _screen)) return;
    _cancelPendingCommands();
    _screen = screen;
    if (kMobileVoiceEvaluationEnabled) _evaluation ??= VoiceEvaluationStore();
    notifyListeners();
  }

  void detachScreen() {
    _cancelPendingCommands();
    _screen = null;
    notifyListeners();
  }

  void _cancelPendingCommands() {
    for (final CopilotMessage message in _messages) {
      final CopilotPendingCommand? command = message.command;
      if (command == null || command.state != CopilotCommandState.pending) {
        continue;
      }
      command.expiry?.cancel();
      command.screen.engine.cancel(command.handle);
      command.state = CopilotCommandState.cancelled;
      command.note = 'Cancelled. Nothing changed.';
    }
  }

  void newChat() {
    _clear();
    notifyListeners();
  }

  void _clear() {
    _generation++;
    _cancelPendingCommands();
    _speech?.cancel();
    _messages.clear();
    _followUps = const <String>[];
    _busy = false;
    _endListening();
  }

  Future<void> retry(int errorIndex) {
    if (_busy || errorIndex < 0 || errorIndex >= _messages.length) {
      return Future<void>.value();
    }
    final String text = _messages[errorIndex].text;
    _messages.removeRange(
      errorIndex > 0 ? errorIndex - 1 : errorIndex,
      errorIndex + 1,
    );
    notifyListeners();
    return ask(text);
  }

  Future<void> ask(String raw) async {
    final String text = raw.trim();
    final UserModel? user = _user;
    if (text.isEmpty || _busy || user == null) return;
    final int generation = _generation;
    _messages.add(CopilotMessage.user(text));
    _busy = true;
    notifyListeners();

    final CopilotScreenContext? screen = _screen;
    if (screen != null && kMobileVoiceCommandsEnabled) {
      final bool handled = await _runCommand(text, screen, generation);
      if (generation != _generation) return;
      if (handled) {
        _followUps = const <String>[];
        _busy = false;
        notifyListeners();
        return;
      }
    }

    _answers ??= MobileCopilotAnswers(user, isOnline: () => online);
    _server ??= MobileCopilotServer.fromEnvironment();
    CopilotIntent? intent = interpretCopilotText(text);
    CopilotServerFailure? failure;
    if (intent.kind == CopilotIntentKind.unknown && _server != null) {
      final CopilotServerResult result = await _server!.interpret(text);
      intent = result.intent;
      failure = result.failure == CopilotServerFailure.unreachable && !online
          ? CopilotServerFailure.offline
          : result.failure;
    }
    if (generation != _generation) return;
    if (intent == null) {
      _messages.add(CopilotMessage.error(text, notice: failure?.message ?? ''));
      _followUps = kCopilotBasicFollowUps;
      _busy = false;
      notifyListeners();
      return;
    }
    final CopilotAnswer answer = await _answers!.answer(intent);
    if (generation != _generation) return;
    _messages.add(CopilotMessage.answer(answer));
    _followUps = _followUpsFor(intent, answer);
    _busy = false;
    notifyListeners();
    final CopilotDestination? destination = answer.open;
    if (destination != null && answer.openLabel.isEmpty) {
      openHandler?.call(destination);
    }
  }

  void _say(String text) =>
      _messages.add(CopilotMessage.answer(CopilotAnswer(text)));

  Future<bool> _runCommand(
    String text,
    CopilotScreenContext screen,
    int generation,
  ) async {
    final DateTime startedAt = DateTime.now();
    final VoiceEngineOutcome outcome;
    try {
      outcome = await screen.engine.submitFinalTranscript(
        text,
        captureId:
            'copilot-${startedAt.microsecondsSinceEpoch}-${++_captureNumber}',
        isOnline: online,
        featureEnabled: kMobileVoiceCommandsEnabled,
      );
    } catch (_) {
      _say("That didn't work. Nothing changed.");
      return true;
    }
    if (generation != _generation) return true;
    if (voiceOutcomeFallsThrough(outcome)) return false;
    _record(outcome, startedAt, confirmation: false);

    final VoiceActionResult? result = outcome.actionResult;
    final VoiceInterpretation? interpretation =
        outcome.interpretation.interpretation;
    if (result == null) {
      _say(voiceAbstentionMessage(outcome.interpretation.abstention!.reason));
      return true;
    }
    if (result.code == VoiceResultCode.needsConfirmation &&
        outcome.confirmationHandle != null &&
        interpretation != null) {
      final CopilotPendingCommand command = CopilotPendingCommand(
        handle: outcome.confirmationHandle!,
        outcome: outcome,
        screen: screen,
        prompt: describeVoiceCommand(interpretation),
        startedAt: startedAt,
      );
      command.expiry = Timer(
        Duration(milliseconds: screen.engine.expiryTicks),
        () {
          if (command.state != CopilotCommandState.pending) return;
          command.state = CopilotCommandState.failed;
          command.note = 'That request expired. Ask again.';
          notifyListeners();
        },
      );
      _messages.add(CopilotMessage.confirm(command));
      return true;
    }
    if (isSuccessfulVoiceResult(result.code) && interpretation != null) {
      _say(describeVoiceSuccess(interpretation));
      unawaited(_afterSuccess(interpretation.action, outcome, screen));
      return true;
    }
    _say(voiceResultMessage(result));
    return true;
  }

  Future<void> _afterSuccess(
    VoiceActionId action,
    VoiceEngineOutcome outcome,
    CopilotScreenContext screen,
  ) async {
    closeHandler?.call();
    final MobileVoiceNavigationCallback? navigate =
        kCopilotNavigationActions.contains(action)
        ? screen.onNavigationAction
        : null;
    if (navigate == null) return;
    try {
      await Future<void>.delayed(Duration.zero);
      await navigate(action, outcome);
    } catch (_) {
    }
  }

  Future<void> confirmCommand(CopilotPendingCommand command) async {
    if (command.state != CopilotCommandState.pending || _busy) return;
    command.expiry?.cancel();
    command.state = CopilotCommandState.running;
    notifyListeners();
    final VoiceActionResult result;
    try {
      result = await command.screen.engine.confirm(
        command.handle,
        isOnline: online,
        featureEnabled: kMobileVoiceCommandsEnabled,
      );
    } catch (_) {
      command.state = CopilotCommandState.failed;
      command.note = "That didn't work. Nothing changed.";
      notifyListeners();
      return;
    }
    final VoiceEngineOutcome confirmed = VoiceEngineOutcome(
      interpretation: command.outcome.interpretation,
      actionResult: result,
    );
    _record(confirmed, command.startedAt, confirmation: true);
    if (isSuccessfulVoiceResult(result.code)) {
      command.state = CopilotCommandState.done;
      command.note = command.prompt.replaceFirst(RegExp(r'\?$'), '.');
      notifyListeners();
      final VoiceInterpretation? interpretation =
          command.outcome.interpretation.interpretation;
      if (interpretation != null) {
        await _afterSuccess(interpretation.action, confirmed, command.screen);
      }
      return;
    }
    command.state = CopilotCommandState.failed;
    command.note = voiceResultMessage(result);
    notifyListeners();
  }

  void cancelCommand(CopilotPendingCommand command) {
    if (command.state != CopilotCommandState.pending) return;
    command.expiry?.cancel();
    command.screen.engine.cancel(command.handle);
    command.state = CopilotCommandState.cancelled;
    command.note = 'Cancelled. Nothing changed.';
    notifyListeners();
  }

  void _record(
    VoiceEngineOutcome outcome,
    DateTime startedAt, {
    required bool confirmation,
  }) {
    final VoiceEvaluationStore? store = _evaluation;
    if (store == null) return;
    unawaited(
      store.record(
        action:
            outcome.interpretation.interpretation?.action.code ?? 'abstained',
        result:
            outcome.actionResult?.code.name ??
            outcome.interpretation.abstention?.reason.name ??
            'unknown',
        durationMs: DateTime.now().difference(startedAt).inMilliseconds,
        provider: 'copilot',
        confirmation: confirmation,
      ),
    );
  }

  List<String> _followUpsFor(CopilotIntent intent, CopilotAnswer answer) {
    switch (intent.kind) {
      case CopilotIntentKind.nextStop:
        final bool hasBrief = answer.chips.any(
          (String c) => c.startsWith('Show the visit brief'),
        );
        return hasBrief
            ? <String>[
                answer.chips.firstWhere(
                  (String c) => c.startsWith('Show the visit brief'),
                ),
                'Stops left today',
                'Open my route',
              ]
            : const <String>[
                'Stops left today',
                'Open my route',
                "Show this week's route",
              ];
      case CopilotIntentKind.stopsLeft:
        return const <String>[
          'What is my next stop?',
          "Show this week's route",
          'Show my orders today',
        ];
      case CopilotIntentKind.ordersThisWeek:
        return const <String>[
          'Show my orders today',
          'What is my next stop?',
          'Open my planner',
        ];
      case CopilotIntentKind.lastOrder:
      case CopilotIntentKind.sales:
        return const <String>[
          'What is my next stop?',
          'Show my orders this week',
          'Stops left today',
        ];
      case CopilotIntentKind.visitBrief:
        return const <String>[
          'What is my next stop?',
          'Show my orders this week',
          'Stops left today',
        ];
      case CopilotIntentKind.openRoute:
        return const <String>[
          'What is my next stop?',
          'Stops left today',
          "Show this week's route",
        ];
      case CopilotIntentKind.openOrders:
        return const <String>[
          'Show my orders this week',
          'What is my next stop?',
          'Open my route',
        ];
      case CopilotIntentKind.openPlanner:
      case CopilotIntentKind.openProfile:
      case CopilotIntentKind.help:
      case CopilotIntentKind.refuse:
      case CopilotIntentKind.unknown:
        return kCopilotBasicFollowUps;
    }
  }

  void markMicIntroSeen() => _micIntroSeen = true;

  void speechUnavailable([String message = '']) {
    _messages.add(
      CopilotMessage.answer(
        CopilotAnswer(message.isEmpty ? kCopilotSpeechUnavailable : message),
      ),
    );
    _followUps = kCopilotBasicFollowUps;
    notifyListeners();
  }

  Future<void> startListening() async {
    if (_listening || _busy) return;
    final int generation = ++_generation;
    _listening = true;
    _preparing = true;
    _partial = '';
    notifyListeners();
    bool started = false;
    bool speechErrorShown = false;
    try {
      _speech ??= _speechFactory();
      started = await _speech!.start(
        onReady: () {
          if (generation != _generation || !_listening) return;
          _preparing = false;
          notifyListeners();
        },
        onPartial: (String text) {
          if (generation != _generation || !_listening) return;
          _preparing = false;
          _partial = text;
          notifyListeners();
        },
        onFinal: (String text) {
          if (generation != _generation || !_listening) return;
          _endListening();
          notifyListeners();
          ask(text);
        },
        onError: (String message) {
          if (generation != _generation || !_listening) return;
          _endListening();
          speechErrorShown = true;
          speechUnavailable(message.trim());
        },
        onStopped: () {
          if (generation != _generation || !_listening) return;
          _endListening();
          notifyListeners();
        },
      );
    } catch (error) {
      started = false;
      if (generation == _generation && _listening) {
        _endListening();
        speechErrorShown = true;
        speechUnavailable(
          error is PlatformException ? (error.message ?? '') : '',
        );
      }
    }
    if (!started &&
        !speechErrorShown &&
        generation == _generation &&
        _listening) {
      _endListening();
      speechUnavailable();
    }
  }

  void _endListening() {
    _listening = false;
    _preparing = false;
    _partial = '';
  }

  Future<void> cancelListening() async {
    if (!_listening) return;
    _generation++;
    _endListening();
    notifyListeners();
    await _speech?.cancel();
  }

  @override
  void dispose() {
    _cancelPendingCommands();
    _speech?.dispose();
    super.dispose();
  }
}
