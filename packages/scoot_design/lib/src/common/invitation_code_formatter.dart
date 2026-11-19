import 'package:flutter/services.dart';

class InvitationCodeFormatter extends TextInputFormatter {
  const InvitationCodeFormatter();

  static const int codeLength = 12;
  static const int groupLength = 4;

  static final RegExp _notCodeCharacter = RegExp(r'[^0-9A-Za-z]');

  static String format(String input) {
    final String code = input
        .replaceAll(_notCodeCharacter, '')
        .toUpperCase();
    final String capped = code.length > codeLength
        ? code.substring(0, codeLength)
        : code;
    final StringBuffer out = StringBuffer();
    for (int i = 0; i < capped.length; i++) {
      if (i > 0 && i % groupLength == 0) out.write('-');
      out.write(capped[i]);
    }
    return out.toString();
  }

  static int _offsetAfter(int codeCharacters) =>
      codeCharacters == 0
      ? 0
      : codeCharacters + (codeCharacters - 1) ~/ groupLength;

  static int _codeCharactersBefore(String text, int offset) {
    int count = 0;
    final int end = offset.clamp(0, text.length);
    for (int i = 0; i < end; i++) {
      if (!_notCodeCharacter.hasMatch(text[i])) count++;
    }
    return count;
  }

  static int _firstDifference(String a, String b) {
    final int shortest = a.length < b.length ? a.length : b.length;
    int i = 0;
    while (i < shortest && a[i] == b[i]) {
      i++;
    }
    return i;
  }

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    String text = newValue.text;
    int cursor = newValue.selection.isValid
        ? newValue.selection.extentOffset
        : text.length;

    final bool removedOneCharacter = text.length == oldValue.text.length - 1;
    if (removedOneCharacter && newValue.selection.isCollapsed) {
      final int at = _firstDifference(oldValue.text, text);
      final bool removedDash =
          at < oldValue.text.length &&
          oldValue.text[at] == '-' &&
          oldValue.text.replaceRange(at, at + 1, '') == text;
      if (removedDash && at > 0) {
        text = text.replaceRange(at - 1, at, '');
        cursor = at - 1;
      }
    }

    final String formatted = format(text);
    final int before = _codeCharactersBefore(text, cursor);
    final int offset = _offsetAfter(
      before > codeLength ? codeLength : before,
    ).clamp(0, formatted.length);
    return TextEditingValue(
      text: formatted,
      selection: TextSelection.collapsed(offset: offset),
    );
  }
}
