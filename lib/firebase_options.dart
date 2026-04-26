import 'package:firebase_core/firebase_core.dart' show FirebaseOptions;
import 'package:flutter/foundation.dart'
    show defaultTargetPlatform, kIsWeb, TargetPlatform;

class DefaultFirebaseOptions {
  static FirebaseOptions get currentPlatform {
    if (kIsWeb) {
      return web;
    }
    switch (defaultTargetPlatform) {
      case TargetPlatform.iOS:
        return ios;
      case TargetPlatform.macOS:
        return ios;
      case TargetPlatform.windows:
      case TargetPlatform.android:
      case TargetPlatform.linux:
        return web;
      default:
        return web;
    }
  }

  static const FirebaseOptions web = FirebaseOptions(
    apiKey:            'AIzaSyDn2is2HCTMnJtd6WVEwqiwto7240tsvSY',
    authDomain:        'examiq-465c9.firebaseapp.com',
    projectId:         'examiq-465c9',
    storageBucket:     'examiq-465c9.firebasestorage.app',
    messagingSenderId: '133739514214',
    appId:             '1:133739514214:web:eb1962c9138b5a79d2e0a7',
    measurementId:     'G-EBZLE8RQW5',
  );

  static const FirebaseOptions ios = FirebaseOptions(
    apiKey:            'AIzaSyCu_Ogvk4ijhyE4b4t8IbZDNDDe6p2kHDs',
    appId:             '1:133739514214:ios:98c2981cc4c90101d2e0a7',
    messagingSenderId: '133739514214',
    projectId:         'examiq-465c9',
    storageBucket:     'examiq-465c9.firebasestorage.app',
    iosBundleId:       'com.examiq.app',
  );
}