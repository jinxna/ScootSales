String formatMinor(int minor, String currency) {
  final int whole = minor.abs() ~/ 100;
  final String cents = (minor.abs() % 100).toString().padLeft(2, '0');
  final String digits = whole.toString();
  final StringBuffer grouped = StringBuffer();
  for (int i = 0; i < digits.length; i++) {
    if (i > 0 && (digits.length - i) % 3 == 0) grouped.write(',');
    grouped.write(digits[i]);
  }
  final String code = currency.isEmpty ? 'RM' : currency.toUpperCase();
  return '${minor < 0 ? '-' : ''}$code $grouped.$cents';
}

String invoiceStatusLabel(String status) => switch (status) {
  'paid' => 'Paid',
  'issued' || 'open' || 'unpaid' => 'Unpaid',
  'partially_paid' => 'Part paid',
  'overdue' => 'Overdue',
  'void' || 'voided' => 'Void',
  'credited' => 'Credited',
  '' => 'Unknown',
  _ => status,
};
