import 'dart:async';

Stream<T> streamWithFallback<T>(
  Stream<T> Function() preferred,
  Stream<T> Function() fallback,
  bool Function(Object error) shouldFallBack,
) => Stream<T>.multi((MultiStreamController<T> listener) {
  StreamSubscription<T>? current;
  void listenTo(Stream<T> stream, {required bool canFallBack}) {
    late final StreamSubscription<T> subscription;
    subscription = stream.listen(
      listener.add,
      onError: (Object error, StackTrace stackTrace) {
        if (!identical(current, subscription)) return;
        if (canFallBack && shouldFallBack(error)) {
          unawaited(subscription.cancel());
          listenTo(fallback(), canFallBack: false);
          return;
        }
        listener.addError(error, stackTrace);
      },
      onDone: () {
        if (identical(current, subscription)) listener.close();
      },
    );
    current = subscription;
  }

  listenTo(preferred(), canFallBack: true);
  listener.onCancel = () {
    final StreamSubscription<T>? active = current;
    current = null;
    return active?.cancel();
  };
});
