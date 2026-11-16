import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';

import '../services/platform_api_client.dart';

String userFacingError(Object error, {required String action}) {
  debugPrint('Could not $action: $error');
  if (error is PlatformApiException) return error.message;
  if (error is FirebaseException) {
    switch (error.code) {
      case 'permission-denied':
        return 'Could not $action: your account is not allowed to make this '
            'change. Ask an administrator if you need access.';
      case 'unavailable':
      case 'deadline-exceeded':
        return 'Could not $action: the database could not be reached. Check '
            'your connection and try again.';
      case 'unauthenticated':
        return 'Could not $action: your session has expired. Sign in again.';
      case 'not-found':
        return 'Could not $action: this record no longer exists. Refresh the '
            'page.';
      case 'already-exists':
        return 'Could not $action: a record with the same name already '
            'exists.';
      case 'failed-precondition':
        return 'Could not $action: the database is not ready for this request '
            'yet. Try again in a few minutes.';
    }
  }
  if (error is StateError) return 'Could not $action: ${error.message}';
  if (error is ArgumentError && error.message is String) {
    return 'Could not $action: ${error.message}';
  }
  return 'Could not $action. Please try again.';
}
