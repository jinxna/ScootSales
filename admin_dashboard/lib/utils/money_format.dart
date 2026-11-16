String formatRm(double value) {
  final String fixed = value.abs().toStringAsFixed(2);
  final int dot = fixed.indexOf('.');
  final String whole = fixed
      .substring(0, dot)
      .replaceAllMapped(RegExp(r'\B(?=(\d{3})+(?!\d))'), (_) => ',');
  final bool negative = value < 0 && fixed != '0.00';
  return '${negative ? '-' : ''}RM $whole${fixed.substring(dot)}';
}
