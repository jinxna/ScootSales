import 'package:flutter/material.dart';
import 'package:flutter/scheduler.dart';

mixin PageSnackBars<T extends StatefulWidget> on State<T> {
  ScaffoldMessengerState? _pageMessenger;

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _pageMessenger = ScaffoldMessenger.maybeOf(context);
  }

  void showPageSnackBar(String message) {
    final ScaffoldMessengerState? messenger = _pageMessenger;
    if (messenger == null) return;
    messenger
      ..hideCurrentSnackBar()
      ..showSnackBar(SnackBar(content: Text(message)));
  }

  @override
  void dispose() {
    final ScaffoldMessengerState? messenger = _pageMessenger;
    if (messenger != null) {
      SchedulerBinding.instance.addPostFrameCallback(
        (_) => messenger.clearSnackBars(),
      );
    }
    super.dispose();
  }
}
