import 'package:flutter/material.dart';

import '../theme/dso_theme.dart';

void showCmsToast(
  BuildContext context,
  String message, {
  bool isError = false,
}) {
  final ScaffoldMessengerState? messenger = ScaffoldMessenger.maybeOf(context);
  if (messenger == null) return;
  messenger.hideCurrentSnackBar();
  messenger.showSnackBar(
    SnackBar(
      content: Text(message, style: const TextStyle(color: Colors.white)),
      backgroundColor: isError ? DsoTokens.dangerText : const Color(0xFF12B76A),
    ),
  );
}
