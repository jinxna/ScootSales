double? dataNumberOrNull(Object? value) {
  if (value == null) return null;
  if (value is num) return value.toDouble();
  return double.tryParse(
    value.toString().replaceAll('RM', '').replaceAll(',', '').trim(),
  );
}
