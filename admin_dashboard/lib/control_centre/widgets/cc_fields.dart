import 'package:flutter/material.dart';

import 'cc_common.dart';

class CcDateField extends StatelessWidget {
  const CcDateField({
    super.key,
    required this.label,
    required this.value,
    required this.onChanged,
    this.helper,
    this.first,
    this.last,
  });

  final String label;
  final DateTime? value;
  final ValueChanged<DateTime>? onChanged;
  final String? helper;
  final DateTime? first, last;

  String _text(DateTime day) =>
      '${day.day} ${<String>['Jan', 'Feb', 'Mar', 'Apr', 'May', 'Jun', 'Jul', 'Aug', 'Sep', 'Oct', 'Nov', 'Dec'][day.month - 1]} ${day.year}';

  Future<void> _pick(BuildContext context) async {
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: value ?? klToday(),
      firstDate: first ?? DateTime(2020),
      lastDate: last ?? DateTime(2100),
      helpText: label,
    );
    if (picked != null) {
      onChanged!(DateTime(picked.year, picked.month, picked.day));
    }
  }

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: label,
    value: value == null ? 'Not set' : _text(value!),
    excludeSemantics: true,
    onTap: onChanged == null ? null : () => _pick(context),
    child: InkWell(
      onTap: onChanged == null ? null : () => _pick(context),
      child: InputDecorator(
        decoration: InputDecoration(
          labelText: label,
          helperText: helper,
          suffixIcon: const Icon(Icons.calendar_today_outlined, size: 18),
          enabled: onChanged != null,
        ),
        child: Text(value == null ? 'Choose a date' : _text(value!)),
      ),
    ),
  );
}

int? parseRmToMinor(String text) {
  final String cleaned = text.replaceAll(',', '').trim();
  final RegExpMatch? match = RegExp(
    r'^(\d+)(?:\.(\d{1,2}))?$',
  ).firstMatch(cleaned);
  if (match == null) return null;
  final int major = int.parse(match.group(1)!);
  final int minor = int.parse((match.group(2) ?? '').padRight(2, '0'));
  final int total = major * 100 + minor;
  return total > 0 ? total : null;
}
