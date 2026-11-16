import 'package:flutter/services.dart';
class RemarksValidator {
  RemarksValidator._();

  static const int maxLength = 200;

  static final RegExp _allowedChars = RegExp(
    r"^[a-zA-Z0-9 .,!?'\-()/:@&+%#=\[\]\n\r]*$",
  );

  static final RegExp _repeatedChar = RegExp(r'(\S)\1{4,}');

  static const List<String> _keyboardRuns = [
    'qwert', 'werty', 'ertyu', 'rtyui', 'tyuio', 'yuiop',
    'asdfg', 'sdfgh', 'dfghj', 'fghjk', 'ghjkl',
    'zxcvb', 'xcvbn', 'cvbnm',
    'qazwsx', 'wsxedc',
    'poiuyt', 'lkjhg', 'mnbvc',
    'aaaaa', 'bbbbb', 'ccccc',
  ];

  static String? validate(String text) {
    if (text.isEmpty) return null;

    if (text.length > maxLength) {
      return 'Exceeds the $maxLength-character limit.';
    }

    return validateContent(text);
  }

  static bool hasOnlyAllowedCharacters(String text) =>
      _allowedChars.hasMatch(text);

  static String? validateContent(String text) {
    if (text.isEmpty) return null;

    if (!_allowedChars.hasMatch(text)) {
      return 'Only letters, numbers, spaces, and basic punctuation are allowed.';
    }

    final specialCount = text.runes
        .where((cp) => !RegExp(r'[a-zA-Z0-9 \t\n\r]').hasMatch(
              String.fromCharCode(cp),
            ))
        .length;
    if (text.length >= 4 && specialCount / text.length > 0.40) {
      return 'Too many special characters — please use plain language.';
    }

    if (_repeatedChar.hasMatch(text)) {
      return 'Remarks must not contain the same character repeated more than 4 times in a row.';
    }

    final lower = text.toLowerCase().replaceAll(RegExp(r'[^a-z]'), '');
    for (final run in _keyboardRuns) {
      if (lower.contains(run)) {
        return 'Input looks like a keyboard run. Please enter a meaningful remark.';
      }
    }

    final alphaOnly = text.replaceAll(RegExp(r'[^a-zA-Z]'), '');
    if (alphaOnly.length >= 7) {
      final vowelCount = alphaOnly
          .toLowerCase()
          .runes
          .where((cp) => 'aeiou'.contains(String.fromCharCode(cp)))
          .length;
      final vowelRatio = vowelCount / alphaOnly.length;
      if (vowelRatio < 0.12) {
        return 'Input appears to be random characters. Please enter a meaningful remark.';
      }
    }

    return null;
  }

  static bool isValid(String text) => validate(text) == null;
}

class RemarksInputFormatter extends TextInputFormatter {
  static final RegExp _allowed = RegExp(
    r"[a-zA-Z0-9 .,!?'\-()/:@&+%#=\[\]\n\r]",
  );

  @override
  TextEditingValue formatEditUpdate(
    TextEditingValue oldValue,
    TextEditingValue newValue,
  ) {
    final filtered = newValue.text.runes
        .map((cp) => String.fromCharCode(cp))
        .where((ch) => _allowed.hasMatch(ch))
        .join();

    final clamped = filtered.length > RemarksValidator.maxLength
        ? filtered.substring(0, RemarksValidator.maxLength)
        : filtered;

    final selectionEnd =
        newValue.selection.end.clamp(0, clamped.length);
    final selectionStart =
        newValue.selection.start.clamp(0, selectionEnd);

    return newValue.copyWith(
      text: clamped,
      selection: TextSelection(
        baseOffset: selectionStart,
        extentOffset: selectionEnd,
      ),
    );
  }
}