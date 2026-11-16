import 'dart:async';

import 'package:flutter/services.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/voice/platform/android_on_device_speech_session.dart';
import 'package:fmcg_sales/voice/platform/ios_on_device_speech_session.dart';
import 'package:fmcg_sales/voice/ui/mobile_voice_speech_session.dart';

void main() {
  TestWidgetsFlutterBinding.ensureInitialized();

  for (final _AdapterCase adapterCase in <_AdapterCase>[
    _AdapterCase(
      'Android',
      (MethodChannel methods, EventChannel events) =>
          AndroidOnDeviceVoiceSpeechSession(methods: methods, events: events),
    ),
    _AdapterCase(
      'iOS',
      (MethodChannel methods, EventChannel events) =>
          IosOnDeviceVoiceSpeechSession(methods: methods, events: events),
    ),
  ]) {
    group('${adapterCase.name} on-device adapter', () {
      test('delivers final and stopped once and clears active state', () async {
        final _ChannelHarness harness = _ChannelHarness();
        final MobileVoiceSpeechAdapter adapter = adapterCase.create(
          harness.methods,
          harness.events,
        );
        final List<String> finals = <String>[];
        int stopped = 0;

        expect(
          await adapter.start(
            onPartial: (_) {},
            onFinal: finals.add,
            onError: (_) {},
            onStopped: () => stopped += 1,
          ),
          isTrue,
        );

        harness.emit(<String, Object>{'type': 'final', 'text': 'Open route'});
        harness.emit(<String, Object>{'type': 'stopped'});
        harness.emit(<String, Object>{'type': 'stopped'});
        await _flushEvents();

        expect(finals, <String>['Open route']);
        expect(stopped, 1);
        await adapter.stop();
        expect(harness.stopCalls, 0);
        await adapter.dispose();
      });
    });
  }
}

typedef _AdapterFactory =
    MobileVoiceSpeechAdapter Function(
      MethodChannel methods,
      EventChannel events,
    );

class _AdapterCase {
  const _AdapterCase(this.name, this.create);

  final String name;
  final _AdapterFactory create;
}

class _ChannelHarness {
  _ChannelHarness() {
    final int id = _nextId++;
    methods = MethodChannel('test/on_device/$id/methods');
    events = EventChannel('test/on_device/$id/events');
    final TestDefaultBinaryMessenger messenger =
        TestDefaultBinaryMessengerBinding.instance.defaultBinaryMessenger;
    messenger.setMockMethodCallHandler(methods, (MethodCall call) async {
      switch (call.method) {
        case 'isAvailable':
          return true;
        case 'start':
          startCalls += 1;
          return true;
        case 'stop':
          stopCalls += 1;
        case 'cancel':
          cancelCalls += 1;
        case 'dispose':
          disposeCalls += 1;
      }
      return null;
    });
    messenger.setMockStreamHandler(
      events,
      MockStreamHandler.inline(
        onListen: (_, MockStreamHandlerEventSink sink) => _eventSink = sink,
      ),
    );
  }

  static int _nextId = 0;

  final Completer<bool> _firstStartResult = Completer<bool>();
  late final MethodChannel methods;
  late final EventChannel events;
  late MockStreamHandlerEventSink _eventSink;
  int startCalls = 0;
  int stopCalls = 0;
  int cancelCalls = 0;
  int disposeCalls = 0;

  void emit(Object event) => _eventSink.success(event);

  void emitError(String code, String message) {
    _eventSink.error(code: code, message: message);
  }

  void completeFirstStart() => _firstStartResult.complete(true);

  Future<void> waitForStartCalls(int expected) async {
    for (int attempt = 0; attempt < 20 && startCalls < expected; attempt++) {
      await _flushEvents();
    }
    expect(startCalls, expected);
  }
}

Future<void> _flushEvents() async {
  await Future<void>.delayed(Duration.zero);
  await Future<void>.delayed(Duration.zero);
}
