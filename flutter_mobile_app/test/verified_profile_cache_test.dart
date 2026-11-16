import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/models/user_model.dart';
import 'package:fmcg_sales/services/verified_profile_cache.dart';
import 'package:shared_preferences/shared_preferences.dart';

void main() {
  const String project = 'project-a';
  const String uid = 'sales-1';
  final DateTime verifiedAt = DateTime.utc(2026, 9, 6, 1);

  UserModel user({
    String userUid = uid,
    String role = 'Sales Representative',
    String status = 'active',
    bool isActive = true,
  }) => UserModel.fromMap(<String, dynamic>{
    'uid': userUid,
    'staffId': 'S001',
    'name': 'QA Salesperson',
    'email': 'qa@example.test',
    'role': role,
    'status': status,
    'isActive': isActive,
  }, userUid);

  setUp(() => SharedPreferences.setMockInitialValues(<String, Object>{}));

  test('expiry boundary and clock rollback are blocked', () async {
    final cache = VerifiedProfileCache(projectId: project);
    await cache.save(user(), now: verifiedAt);

    expect(
      await cache.load(uid, now: verifiedAt.add(const Duration(hours: 24))),
      isNotNull,
    );
    expect(
      await cache.load(
        uid,
        now: verifiedAt.add(const Duration(hours: 24, milliseconds: 1)),
      ),
      isNull,
    );
    expect(
      await cache.load(
        uid,
        now: verifiedAt.subtract(const Duration(milliseconds: 1)),
      ),
      isNull,
    );
  });

  test('project and Firebase UID changes cannot reuse a receipt', () async {
    final cache = VerifiedProfileCache(projectId: project);
    await cache.save(user(), now: verifiedAt);

    expect(
      await VerifiedProfileCache(
        projectId: 'project-b',
      ).load(uid, now: verifiedAt),
      isNull,
    );
    expect(await cache.load('sales-2', now: verifiedAt), isNull);
  });

  test('inactive and non-salesperson receipts are rejected', () {
    bool usable(UserModel candidate) =>
        VerifiedProfileReceipt(
          projectId: project,
          user: candidate,
          verifiedAt: verifiedAt,
        ).isUsableFor(
          expectedProjectId: project,
          expectedUid: candidate.uid,
          now: verifiedAt,
          maxAge: const Duration(hours: 24),
        );

    for (final status in <String>[
      'suspended',
      'disabled',
      'inactive',
      'removed',
      'deleted',
      'terminated',
    ]) {
      expect(usable(user(status: status)), isFalse, reason: status);
    }
    expect(usable(user(isActive: false)), isFalse);
    expect(usable(user(role: 'admin')), isFalse);
  });
}
