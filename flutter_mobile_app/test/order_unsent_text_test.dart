import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/screens/order_signature_screen.dart';
import 'package:fmcg_sales/services/assigned_visit_order_recovery.dart';

void main() {
  test('a timeout does not tell the salesperson the phone is offline', () {
    final String text = unsentOrderMessage(
      saved: true,
      earlierSendWaiting: false,
      timedOut: true,
    );
    expect(text, isNot(contains('offline')));
    expect(text, contains('too long'));
    expect(text, contains('was not sent'));
    expect(
      unsentOrderMessage(
        saved: true,
        earlierSendWaiting: false,
        timedOut: false,
      ),
      startsWith('You are offline.'),
    );
  });

  test(
    'an unavailable recovery never blames the network unless it was offline',
    () {
      final String timeout = unavailableEarlierSubmissionMessage(
        AssignedVisitOrderRecoveryCause.timeout,
      );
      final String unknown = unavailableEarlierSubmissionMessage(
        AssignedVisitOrderRecoveryCause.unknown,
      );
      final String offline = unavailableEarlierSubmissionMessage(
        AssignedVisitOrderRecoveryCause.offline,
      );
      expect(timeout, isNot(contains('offline')));
      expect(unknown, isNot(contains('offline')));
      expect(offline, contains('offline'));
      final String unsentUnknown = unsentOrderMessage(
        saved: true,
        earlierSendWaiting: false,
        timedOut: false,
        causeUnknown: true,
      );
      expect(unsentUnknown, startsWith('The order could not be checked.'));
      expect(unsentUnknown, isNot(contains('offline')));
    },
  );

  test('only a network failure counts as offline', () {
    expect(
      isOfflineFailure(
        FirebaseException(plugin: 'cloud_firestore', code: 'unavailable'),
      ),
      isTrue,
    );
    expect(
      isOfflineFailure(
        FirebaseException(plugin: 'cloud_firestore', code: 'permission-denied'),
      ),
      isFalse,
    );
    expect(isOfflineFailure(StateError('x')), isFalse);
  });
}
