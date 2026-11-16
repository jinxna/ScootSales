import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/security/canonical_profile_identity.dart';

void main() {
  const String uid = '6EWrk4GGMYbqppGdJRVf8Z57Nrs2';

  test('rejects missing, empty, and conflicting canonical link aliases', () {
    expect(
      CanonicalProfileIdentity.strictLinkedDocumentId(<String, dynamic>{}),
      isEmpty,
    );
    expect(
      CanonicalProfileIdentity.strictLinkedDocumentId(<String, dynamic>{
        'userDocId': '',
      }),
      isEmpty,
    );
    expect(
      CanonicalProfileIdentity.strictLinkedDocumentId(<String, dynamic>{
        'userDocId': 'canonical',
        'user_doc_id': 'stale',
      }),
      isEmpty,
    );
    expect(
      CanonicalProfileIdentity.strictLinkedDocumentId(<String, dynamic>{
        'user_doc_id': 'canonical',
      }),
      'canonical',
    );
  });

  test('rejects a linked profile belonging to a different Auth UID', () {
    expect(
      CanonicalProfileIdentity.matches(
        accessData: <String, dynamic>{'uid': uid, 'role': 'admin'},
        canonicalData: <String, dynamic>{
          'uid': 'different-uid',
          'email': 'admin01@scoot-ops.test',
          'role': 'admin',
        },
        authUid: uid,
        authEmail: 'admin01@scoot-ops.test',
      ),
      isFalse,
    );
  });

  test(
    'rejects an access user_uid alias belonging to a different Auth UID',
    () {
      expect(
        CanonicalProfileIdentity.matches(
          accessData: <String, dynamic>{
            'uid': uid,
            'user_uid': 'different-uid',
            'role': 'admin',
          },
          canonicalData: <String, dynamic>{
            'uid': uid,
            'email': 'admin01@scoot-ops.test',
            'role': 'admin',
          },
          authUid: uid,
          authEmail: 'admin01@scoot-ops.test',
        ),
        isFalse,
      );
    },
  );

  test('treats an inactive access index as inactive', () {
    expect(
      CanonicalProfileIdentity.isActiveAccessIndex(<String, dynamic>{
        'role': 'admin',
        'status': 'suspended',
      }),
      isFalse,
    );
  });

  test('treats a demoted canonical profile as inactive', () {
    expect(
      CanonicalProfileIdentity.isActiveCanonical(<String, dynamic>{
        'role': 'admin',
        'status': 'suspended',
      }),
      isFalse,
    );
  });
}
