import 'dart:async';

import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/utils/ref_counted_replay_stream.dart';

void main() {
  test('reconnect waits for the previous cancellation to finish', () async {
    var listenCount = 0;
    var cancelCount = 0;
    final cancellationGate = Completer<void>();
    final source = Stream<int>.multi((controller) {
      listenCount += 1;
      controller.onCancel = () async {
        cancelCount += 1;
        await cancellationGate.future;
      };
    });
    final replay = RefCountedReplayStream<int>(() => source);

    final first = replay.stream.listen((_) {});
    await pumpEventQueue();
    expect(listenCount, 1);

    final firstCancellation = first.cancel();
    final resumed = replay.stream.listen((_) {});
    await pumpEventQueue();
    expect(cancelCount, 1);
    expect(listenCount, 1);

    cancellationGate.complete();
    await firstCancellation;
    await pumpEventQueue();
    expect(listenCount, 2);

    await resumed.cancel();
    await replay.dispose();
  });
}
