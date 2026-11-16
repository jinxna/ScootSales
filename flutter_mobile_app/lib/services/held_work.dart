import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/company_lifecycle.dart';

const Duration kHeldWorkSkew = Duration(minutes: 5);

enum WriteFailure { held, other }

enum HeldRoute { direct, endpoint, wait }

class HeldWorkPolicy {
  const HeldWorkPolicy._();

  static WriteFailure classify(Object error, String? access) =>
      error is FirebaseException &&
          error.code == 'permission-denied' &&
          access != null &&
          access != 'open'
      ? WriteFailure.held
      : WriteFailure.other;

  static HeldRoute routeForStopEvent(
    CompanyLifecycle lifecycle, {
    required DateTime sessionStartedAt,
    required DateTime now,
  }) {
    if (!lifecycle.isOpen) return _drainRoute(lifecycle, now);
    return _reactivatedRoute(lifecycle, sessionStartedAt);
  }

  static HeldRoute routeForOrder(
    CompanyLifecycle lifecycle, {
    required DateTime sessionStartedAt,
    required DateTime deviceAt,
    required DateTime now,
  }) {
    final DateTime? cutAt = lifecycle.cutAt;
    final bool madeBeforeCut =
        cutAt != null && !deviceAt.isAfter(cutAt.add(kHeldWorkSkew));
    if (!lifecycle.isOpen) {
      return madeBeforeCut ? _drainRoute(lifecycle, now) : HeldRoute.wait;
    }
    return madeBeforeCut
        ? _reactivatedRoute(lifecycle, sessionStartedAt)
        : HeldRoute.direct;
  }

  static HeldRoute _drainRoute(CompanyLifecycle lifecycle, DateTime now) {
    final DateTime? drainUntil = lifecycle.drainUntil;
    return drainUntil != null && now.isBefore(drainUntil)
        ? HeldRoute.endpoint
        : HeldRoute.wait;
  }

  static HeldRoute _reactivatedRoute(
    CompanyLifecycle lifecycle,
    DateTime sessionStartedAt,
  ) {
    final DateTime? reactivatedAt = lifecycle.reactivatedAt;
    return lifecycle.cutAt != null &&
            reactivatedAt != null &&
            sessionStartedAt.isBefore(reactivatedAt)
        ? HeldRoute.endpoint
        : HeldRoute.direct;
  }

  static const String _keepWhilePaused =
      'Keep this item and show it to your manager. Work recorded while the company is paused is not accepted, so do not record it again now.';

  static String rejectionText(String? reason, {required bool companyOpen}) =>
      switch (reason) {
        'after_cut' =>
          'This was recorded after the company was paused, so it was not accepted.',
        'session_after_cut' =>
          'Your work session started after the company was paused, so this was not accepted.',
        'before_session' when !companyOpen =>
          'The date and time on this phone were more than a day earlier than the start of your work session, so this was not accepted. Set the phone clock to automatic time. $_keepWhilePaused',
        'before_session' =>
          'The date and time on this phone were more than a day earlier than the start of your work session, so this was not accepted. Set the phone clock to automatic time, record this item again, then remove this one.',
        'too_large' when !companyOpen =>
          'This item is too large for the server to accept. Sending it again will not help. $_keepWhilePaused',
        'too_large' =>
          'This item is too large for the server to accept. Sending it again will not help. Record it again with fewer details, then remove this one.',
        'drain_closed' =>
          'The time allowed to upload held work had ended before this reached the server.',
        'not_on_plan' =>
          'This stop is not on a route assigned to you now. The route may have been replaced or removed, so this could not be recorded. Ask your manager which route to follow.',
        'save_failed' when !companyOpen =>
          'The company could not save this item, and sending it again will not change that. $_keepWhilePaused',
        'save_failed' =>
          'The company could not save this item, and sending it again will not change that. Record it again, then remove this one.',
        _ when !companyOpen =>
          'The server could not accept this item. $_keepWhilePaused',
        _ =>
          'The server could not accept this item. Send it again. If it is refused again, record it again, then remove this one.',
      };
}
