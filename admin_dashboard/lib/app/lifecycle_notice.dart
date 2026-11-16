const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

String noticeDate(DateTime value) {
  final DateTime local = value.toLocal();
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

String? pastDueNotice(
  String? state,
  DateTime? graceEndsAt, {
  bool isAdmin = false,
}) {
  if (state != 'past_due') return null;
  final String deadline = graceEndsAt == null
      ? ''
      : ' Pay by ${noticeDate(graceEndsAt)} to keep the workspace open.';
  final String action = isAdmin
      ? 'Open Account to see the invoice.'
      : 'Ask your administrator to open Account to see the invoice.';
  return 'Payment is overdue.$deadline $action';
}

String restrictedNotice(
  String company,
  String? state,
  DateTime? retentionEndsAt,
) {
  final String retention = retentionEndsAt == null
      ? ''
      : ' Company data is kept until ${noticeDate(retentionEndsAt)} and is '
            'deleted after that date unless the company is reactivated.';
  return '$company is ${state ?? 'not active'}. The workspace is read-only: '
      'you can download a data export and grant support access while the '
      'company data is retained.$retention Other pages are closed until the '
      'company is reactivated.';
}

String roleChangeNotice(String fromLabel, String toLabel) =>
    'Your role changed from $fromLabel to $toLabel. The console reloaded '
    'with the pages that role can open.';
