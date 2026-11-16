import 'package:flutter/foundation.dart';

class UserAvatarStorage {
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);

  static String? read(String uid) => null;

  static Future<bool> chooseAndSave(String uid) async => false;

  static void clear(String uid) {}

  static void notifyChanged() => revision.value++;
}
