import 'package:cloud_firestore/cloud_firestore.dart';

import '../models/user_profile.dart';
import 'audit_log_service.dart';

class ForecastWindowService {
  ForecastWindowService({FirebaseFirestore? firestore})
    : _firestoreOverride = firestore;

  static const int minWeeks = 4;
  static const int maxWeeks = 104;
  static const int defaultWeeks = 8;

  static const List<int> evaluatedWeeks = <int>[4, 8, 12, 26];

  final FirebaseFirestore? _firestoreOverride;

  DocumentReference<Map<String, dynamic>> get _document =>
      (_firestoreOverride ?? FirebaseFirestore.instance)
          .collection('system_settings')
          .doc('forecast_window');

  static bool isEvaluated(int weeks) => evaluatedWeeks.contains(weeks);

  static String? validate(int? weeks) {
    if (weeks == null || weeks < minWeeks || weeks > maxWeeks) {
      return 'Enter a whole number from $minWeeks to $maxWeeks weeks.';
    }
    return null;
  }

  static List<String> warnings(int weeks) => <String>[
    if (weeks < 6) 'Below 6 weeks, "stopped buying" alerts cannot fire.',
    if (weeks < 7) 'Below 7 weeks, no forecast range is shown.',
    if (weeks < 8)
      'Below 8 weeks, the forecast can change a lot from week to week.',
    if (!isEvaluated(weeks))
      'Not evaluated: accuracy was only checked for '
          '${evaluatedWeeks.join(', ')} weeks.',
  ];

  Future<int?> readLiveWeeks() async {
    final DocumentSnapshot<Map<String, dynamic>> snapshot = await _document
        .get();
    final Object? value = snapshot.data()?['historyWeeks'];
    return value is int ? value : null;
  }

  Future<void> save({required int weeks, required UserProfile actor}) async {
    if (!actor.isAdmin) {
      throw StateError('Only an administrator can change the live window.');
    }
    final String? problem = validate(weeks);
    if (problem != null) throw ArgumentError(problem);
    final int? previous = await readLiveWeeks();
    final String updatedBy = actor.uid?.trim().isNotEmpty == true
        ? actor.uid!.trim()
        : actor.docId.trim();
    await _document.set(<String, dynamic>{
      'historyWeeks': weeks,
      'updatedBy': updatedBy,
      'updatedAt': FieldValue.serverTimestamp(),
    });
    await AuditLogService.instance.record(
      action: 'updated',
      entityType: 'system_settings',
      entityId: 'forecast_window',
      summary: 'Set the live forecast window to $weeks weeks',
      actor: actor,
      metadata: <String, dynamic>{
        'historyWeeks': weeks,
        'previousHistoryWeeks': previous,
        'windowEvaluated': isEvaluated(weeks),
      },
    );
  }
}
