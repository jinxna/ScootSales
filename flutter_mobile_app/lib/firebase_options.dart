import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

const String firebaseTarget = String.fromEnvironment(
  'FIREBASE_TARGET',
  defaultValue: 'supermarket',
);

const Set<String> _knownTargets = <String>{'supermarket', 'hardware'};

String? get firebaseTargetError => _knownTargets.contains(firebaseTarget)
    ? null
    : 'This build has an unknown FIREBASE_TARGET "$firebaseTarget". '
          'Rebuild it with FIREBASE_TARGET=supermarket or '
          'FIREBASE_TARGET=hardware.';

String get productTitle =>
    firebaseTarget == 'hardware' ? 'Scoot Sales · Hardware' : 'Scoot Sales';

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    final String? error = firebaseTargetError;
    if (error != null) throw UnsupportedError(error);
    final bool hardware = firebaseTarget == 'hardware';
    if (kIsWeb) {
      return hardware ? hardwareWeb : web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.android:
        return hardware ? hardwareAndroid : android;
      case TargetPlatform.iOS:
        return hardware ? hardwareIos : ios;
      default:
        throw UnsupportedError(
          'DefaultFirebaseOptions are not supported for this platform.',
        );
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey: 'AIzaSyDeytVHO_y42bfNY9iGQZ6hqM0Ah7H6iuE',
    appId: '1:789087499876:web:38bf7ca370bb5f5f1ed171',
    messagingSenderId: '789087499876',
    projectId: 'cos40005',
    authDomain: 'cos40005.firebaseapp.com',
    storageBucket: 'cos40005.firebasestorage.app',
  );

  static const FirebaseOptions android = FirebaseOptions(
    apiKey: 'AIzaSyBTvOSDWpkpNpgJf4uVpb74qBjHcN1g47A',
    appId: '1:789087499876:android:db3a58e525133a581ed171',
    messagingSenderId: '789087499876',
    projectId: 'cos40005',
    storageBucket: 'cos40005.firebasestorage.app',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey: 'AIzaSyBnguMqcvB88jsI9Srri6hixw1wMUXWBZs',
    appId: '1:789087499876:ios:5ae33707db1392811ed171',
    messagingSenderId: '789087499876',
    projectId: 'cos40005',
    storageBucket: 'cos40005.firebasestorage.app',
    iosBundleId: 'my.scootsales.app',
  );

  static const FirebaseOptions hardwareWeb = FirebaseOptions(
    apiKey: 'AIzaSyBAM4TKSDX7qXT8q9zXoM6_9KftPVYfTx8',
    appId: '1:573265614719:web:2ec72d3946f0f46b86ac4a',
    messagingSenderId: '573265614719',
    projectId: 'hardware-client-sales',
    authDomain: 'hardware-client-sales.firebaseapp.com',
    storageBucket: 'hardware-client-sales.firebasestorage.app',
    measurementId: 'G-78CPMQ6RKS',
  );

  static const FirebaseOptions hardwareAndroid = FirebaseOptions(
    apiKey: 'AIzaSyDBdvAAr2pMDiYN5K2oIKaWdjl7Wn6BKj8',
    appId: '1:573265614719:android:9849e6f7653a4f4386ac4a',
    messagingSenderId: '573265614719',
    projectId: 'hardware-client-sales',
    storageBucket: 'hardware-client-sales.firebasestorage.app',
  );

  static const FirebaseOptions hardwareIos = FirebaseOptions(
    apiKey: 'AIzaSyC4EUO9nP_vilTHA_NlpDofTxoU3hmfrm4',
    appId: '1:573265614719:ios:4064c74c54a56e7b86ac4a',
    messagingSenderId: '573265614719',
    projectId: 'hardware-client-sales',
    storageBucket: 'hardware-client-sales.firebasestorage.app',
    iosBundleId: 'my.scootsales.app',
  );
}
