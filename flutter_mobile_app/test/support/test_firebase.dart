import 'package:firebase_core/firebase_core.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_auth_platform_interface/firebase_auth_platform_interface.dart';
// ignore: depend_on_referenced_packages
import 'package:firebase_core_platform_interface/test.dart';
import 'package:flutter_test/flutter_test.dart';

const String testProjectId = '123';

Future<void> installTestFirebase() async {
  TestWidgetsFlutterBinding.ensureInitialized();
  setupFirebaseCoreMocks();
  FirebaseAuthPlatform.instance = _TestAuthPlatform.shared;
  if (Firebase.apps.isEmpty) await Firebase.initializeApp();
}

void signInTestUser(String? uid) {
  _TestAuthPlatform.shared.signedInUid = uid;
}

class _TestAuthPlatform extends FirebaseAuthPlatform {
  _TestAuthPlatform() : super();

  static final _TestAuthPlatform shared = _TestAuthPlatform();

  String? signedInUid;

  @override
  FirebaseAuthPlatform delegateFor({required FirebaseApp app}) => this;

  @override
  FirebaseAuthPlatform setInitialValues({
    PigeonUserDetails? currentUser,
    String? languageCode,
  }) => this;

  @override
  Stream<UserPlatform?> authStateChanges() =>
      const Stream<UserPlatform?>.empty();

  @override
  UserPlatform? get currentUser {
    final String? uid = signedInUid;
    return uid == null ? null : _TestUser(this, uid);
  }
}

class _TestUser extends UserPlatform {
  _TestUser(FirebaseAuthPlatform auth, String uid)
    : super(
        auth,
        _TestMultiFactor(auth),
        PigeonUserDetails(
          userInfo: PigeonUserInfo(
            uid: uid,
            isAnonymous: false,
            isEmailVerified: false,
          ),
          providerData: <Map<Object?, Object?>>[],
        ),
      );
}

class _TestMultiFactor extends MultiFactorPlatform {
  _TestMultiFactor(super.auth);
}
