import 'package:flutter_test/flutter_test.dart';
import 'package:flutter_web_app/services/platform_api_client.dart';
import 'package:flutter_web_app/utils/invoice_format.dart';

void main() {
  test('account answer keeps every invoice with its amounts', () {
    final AccountSummary account = AccountSummary.fromJson(<String, Object?>{
      'plan': <String, Object?>{'name': 'Standard', 'status': 'active'},
      'usage': <Object?>[
        <String, Object?>{'key': 'users', 'label': 'Users', 'used': 1, 'limit': 5},
      ],
      'invoices': <Object?>[
        <String, Object?>{
          'invoiceId': 'i1',
          'number': 'INV-2026-0001',
          'status': 'issued',
          'packageName': 'Standard',
          'amountMinor': 123456,
          'currency': 'MYR',
          'outstandingMinor': 123456,
          'dueAt': '2026-11-20T00:00:00Z',
        },
      ],
      'export': <String, Object?>{'available': false},
    });
    expect(account.invoices.single.number, 'INV-2026-0001');
    expect(account.invoiceCount, 1);
    expect(formatMinor(account.invoices.single.amountMinor, 'MYR'), 'MYR 1,234.56');
    expect(invoiceStatusLabel('issued'), 'Unpaid');
  });
}
