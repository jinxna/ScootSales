import 'package:flutter_test/flutter_test.dart';
import 'package:fmcg_sales/utils/canonical_profile.dart';

void main() {
  test('resolves the canonical linked profile and ignores stale UID rows', () {
    expect(
      canonicalProfileIdFromAccess(<String, dynamic>{
        'userDocId': 'canonical-profile',
      }),
      'canonical-profile',
    );
    expect(
      canonicalProfileMatchesAuth('auth-uid', <String, dynamic>{
        'uid': 'auth-uid',
        'name': 'Canonical Salesman',
      }),
      isTrue,
    );
  });

  test('fails closed for broken or conflicting access links', () {
    expect(canonicalProfileIdFromAccess(<String, dynamic>{}), isNull);
    expect(
      canonicalProfileIdFromAccess(<String, dynamic>{'userDocId': ''}),
      isNull,
    );
    expect(
      canonicalProfileIdFromAccess(<String, dynamic>{
        'userDocId': 'profile-a',
        'user_doc_id': 'profile-b',
      }),
      isNull,
    );
    expect(
      canonicalProfileMatchesAuth('auth-uid', <String, dynamic>{
        'uid': 'stale-uid',
      }),
      isFalse,
    );
    expect(
      canonicalProfileMatchesAuth('auth-uid', <String, dynamic>{
        'user_uid': 'stale-uid',
      }),
      isFalse,
    );
    expect(
      accessIdentityMatchesAuth('auth-uid', <String, dynamic>{
        'user_uid': 'stale-uid',
      }),
      isFalse,
    );
  });
}
