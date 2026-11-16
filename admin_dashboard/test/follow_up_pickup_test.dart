import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/models/conversation_outcome.dart';
import 'package:flutter_web_app/services/outcome_review_service.dart';

ConversationOutcome _outcome({
  required String retailerId,
  required String reason,
  required DateTime at,
  String uid = 'u1',
  String code = 's1',
}) {
  return ConversationOutcome.fromMap(
    'id_${retailerId}_${at.millisecondsSinceEpoch}',
    <String, dynamic>{
      'retailerId': retailerId,
      'reasonCode': reason,
      'salesmanUid': uid,
      'salesmanCode': code,
      'submittedAt': at,
    },
  );
}

void main() {
  final DateTime now = DateTime(2026, 6, 26);
  final DateTime cutoff = now.subtract(const Duration(days: 45));

  group('deriveDueFollowUpRetailerIds', () {
    test('matches by salesman code and ignores other salesmen', () {
      final Set<String> ids = OutcomeReviewService.deriveDueFollowUpRetailerIds(
        <ConversationOutcome>[
          _outcome(
            retailerId: 'r1',
            reason: 'decision_maker_unavailable',
            at: now.subtract(const Duration(days: 3)),
            uid: 'other',
            code: 's1',
          ),
          _outcome(
            retailerId: 'r2',
            reason: 'retailer_busy',
            at: now.subtract(const Duration(days: 3)),
            uid: 'other',
            code: 'other',
          ),
        ],
        salesmanUid: '',
        salesmanCode: 's1',
        cutoff: cutoff,
      );
      expect(ids, <String>{'r1'});
    });
  });
}
