// ignore_for_file: avoid_web_libraries_in_flutter, deprecated_member_use

import 'dart:async';
import 'dart:convert';
import 'dart:typed_data';
import 'dart:ui' as ui;
import 'dart:html' as html;

import 'package:flutter/foundation.dart';

class UserAvatarStorage {
  static final ValueNotifier<int> revision = ValueNotifier<int>(0);
  static const int _maxInputBytes = 8 * 1024 * 1024;
  static const String _keyPrefix = 'dso.profile.avatar.v1.';

  static String? read(String uid) {
    if (uid.trim().isEmpty) return null;
    try {
      return html.window.localStorage[_key(uid)];
    } catch (_) {
      return null;
    }
  }

  static Future<bool> chooseAndSave(String uid) async {
    if (uid.trim().isEmpty) return false;
    final html.FileUploadInputElement input = html.FileUploadInputElement()
      ..accept = 'image/*';
    final Completer<void> pickerClosed = Completer<void>();
    final StreamSubscription<html.Event> changeSubscription = input.onChange
        .listen((_) {
          if (!pickerClosed.isCompleted) pickerClosed.complete();
        });
    final StreamSubscription<html.Event> cancelSubscription = input.on['cancel']
        .listen((_) {
          if (!pickerClosed.isCompleted) pickerClosed.complete();
        });
    input.click();
    await pickerClosed.future;
    await changeSubscription.cancel();
    await cancelSubscription.cancel();
    final List<html.File>? files = input.files;
    if (files == null || files.isEmpty) return false;
    final html.File file = files.first;
    if (file.size > _maxInputBytes) {
      throw StateError('Image is larger than the 8 MB limit.');
    }
    final html.FileReader reader = html.FileReader();
    reader.readAsArrayBuffer(file);
    await reader.onLoad.first;
    final Object? result = reader.result;
    if (result is! ByteBuffer) throw StateError('Could not read image.');
    final Uint8List inputBytes = result.asUint8List();
    final ui.Codec codec = await ui.instantiateImageCodec(
      inputBytes,
      targetWidth: 256,
      targetHeight: 256,
    );
    try {
      final ui.FrameInfo frame = await codec.getNextFrame();
      try {
        final ByteData? encoded = await frame.image.toByteData(
          format: ui.ImageByteFormat.png,
        );
        if (encoded == null) throw StateError('Could not resize image.');
        final String base64 = base64Encode(encoded.buffer.asUint8List());
        html.window.localStorage[_key(uid)] = base64;
        revision.value++;
        return true;
      } finally {
        frame.image.dispose();
      }
    } finally {
      codec.dispose();
    }
  }

  static void clear(String uid) {
    if (uid.trim().isEmpty) return;
    try {
      html.window.localStorage.remove(_key(uid));
    } catch (_) {}
    revision.value++;
  }

  static void notifyChanged() => revision.value++;

  static String _key(String uid) => '$_keyPrefix${Uri.encodeComponent(uid)}';
}
