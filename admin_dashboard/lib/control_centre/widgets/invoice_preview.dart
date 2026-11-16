import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_common.dart';

class InvoicePreview extends StatelessWidget {
  const InvoicePreview({
    super.key,
    required this.invoice,
    required this.company,
  });

  final StaffInvoice invoice;
  final StaffCompany? company;

  static const TextStyle _strong = TextStyle(
    fontWeight: FontWeight.w700,
    color: Cc.ink,
  );
  static const TextStyle _plain = TextStyle(color: Cc.body, fontSize: 14);

  Widget _amountRow(String label, String value, {bool bold = false}) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 4),
    child: Row(
      children: <Widget>[
        Expanded(child: Text(label, style: bold ? _strong : _plain)),
        Text(
          value,
          style: TextStyle(
            color: Cc.ink,
            fontWeight: bold ? FontWeight.w700 : FontWeight.w400,
            fontFeatures: Cc.figures,
          ),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final String number = invoice.number ?? 'Draft';
    final String amount = money(invoice.amountMinor);
    final String unit = money(invoice.amountMinor).substring(3);
    return Semantics(
      container: true,
      label: 'Invoice preview $number',
      child: Container(
        padding: const EdgeInsets.all(24),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Cc.line),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              spacing: 24,
              runSpacing: 16,
              children: <Widget>[
                const Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Text(
                      'Scoot Sales [Sdn Bhd]',
                      style: TextStyle(
                        fontSize: 17,
                        fontWeight: FontWeight.w700,
                        color: Cc.ink,
                      ),
                    ),
                    SizedBox(height: 4),
                    Text(
                      'SSM [registration no.] · TIN [tax no.]',
                      style: _plain,
                    ),
                    Text('[address], Kuching, Sarawak', style: _plain),
                    Text('billing@scootsales.app · [phone]', style: _plain),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    const Text(
                      'INVOICE',
                      style: TextStyle(
                        fontSize: 24,
                        fontWeight: FontWeight.w800,
                        color: Cc.ink,
                        letterSpacing: 1,
                      ),
                    ),
                    Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          const TextSpan(text: 'No. '),
                          TextSpan(text: number, style: _strong),
                        ],
                      ),
                      style: _plain,
                    ),
                    Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          const TextSpan(text: 'Issue date: '),
                          TextSpan(
                            text: invoice.issuedAt == null
                                ? 'When issued'
                                : dayText(invoice.issuedAt),
                            style: _strong,
                          ),
                        ],
                      ),
                      style: _plain,
                    ),
                    Text.rich(
                      TextSpan(
                        children: <InlineSpan>[
                          const TextSpan(text: 'Due date: '),
                          TextSpan(
                            text: invoice.dueAt == null
                                ? '14 days after sending'
                                : dayText(invoice.dueAt),
                            style: _strong,
                          ),
                        ],
                      ),
                      style: _plain,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            Wrap(
              spacing: 48,
              runSpacing: 16,
              children: <Widget>[
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('BILL TO', style: Cc.label),
                    const SizedBox(height: 4),
                    Text(
                      company?.legalName ?? invoice.tenantId,
                      style: _strong,
                    ),
                    const Text('SSM [buyer SSM no.]', style: _plain),
                    const Text('[buyer address], Kuching', style: _plain),
                    Text(
                      company?.billingEmail ?? 'Billing email not set',
                      style: _plain,
                    ),
                  ],
                ),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text('SERVICE PERIOD', style: Cc.label),
                    const SizedBox(height: 4),
                    Text(
                      periodText(invoice.periodStart, invoice.periodEnd),
                      style: _strong,
                    ),
                    Text(
                      'Workspace ${codeText(company?.workspace ?? '')}',
                      style: _plain,
                    ),
                  ],
                ),
              ],
            ),
            const SizedBox(height: 24),
            const Divider(height: 1, color: Cc.ink),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Row(
                children: const <Widget>[
                  Expanded(child: Text('DESCRIPTION', style: Cc.label)),
                  SizedBox(
                    width: 40,
                    child: Text(
                      'QTY',
                      style: Cc.label,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Text(
                      'UNIT PRICE (RM)',
                      style: Cc.label,
                      textAlign: TextAlign.right,
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Text(
                      'AMOUNT (RM)',
                      style: Cc.label,
                      textAlign: TextAlign.right,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Cc.line),
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 12),
              child: Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          'Scoot Sales ${invoice.packageName} · ${intervalLabel(invoice.billingInterval)} subscription',
                          style: _plain,
                        ),
                        Text(
                          periodText(invoice.periodStart, invoice.periodEnd),
                          style: Cc.small,
                        ),
                      ],
                    ),
                  ),
                  const SizedBox(
                    width: 40,
                    child: Text(
                      '1',
                      textAlign: TextAlign.right,
                      style: TextStyle(fontFeatures: Cc.figures),
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Text(
                      unit,
                      textAlign: TextAlign.right,
                      style: Cc.numbers,
                    ),
                  ),
                  SizedBox(
                    width: 110,
                    child: Text(
                      unit,
                      textAlign: TextAlign.right,
                      style: Cc.numbers,
                    ),
                  ),
                ],
              ),
            ),
            const Divider(height: 1, color: Cc.line),
            const SizedBox(height: 8),
            Align(
              alignment: Alignment.centerRight,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 320),
                child: Column(
                  children: <Widget>[
                    _amountRow('Subtotal', amount),
                    _amountRow('SST', 'Not registered'),
                    if (invoice.creditedMinor > 0)
                      _amountRow(
                        'Credit notes',
                        '- ${money(invoice.creditedMinor)}',
                      ),
                    if (invoice.paidMinor > 0)
                      _amountRow('Paid', '- ${money(invoice.paidMinor)}'),
                    const Divider(height: 12, color: Cc.ink),
                    _amountRow(
                      invoice.paidMinor > 0 || invoice.creditedMinor > 0
                          ? 'Balance (RM)'
                          : 'Total payable (RM)',
                      invoice.paidMinor > 0 || invoice.creditedMinor > 0
                          ? money(invoice.outstandingMinor).substring(3)
                          : unit,
                      bold: true,
                    ),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 20),
            const Divider(height: 1, color: Cc.line),
            const SizedBox(height: 16),
            const Text('How to pay', style: _strong),
            const SizedBox(height: 4),
            const Text(
              'Bank transfer to [bank name], account [account no.], [account name].',
              style: _plain,
            ),
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  const TextSpan(text: 'Use '),
                  TextSpan(text: number, style: _strong),
                  const TextSpan(text: ' as the payment reference.'),
                ],
              ),
              style: _plain,
            ),
            const Text(
              'Payment terms: 14 days. Questions: billing@scootsales.app',
              style: Cc.small,
            ),
            const SizedBox(height: 16),
            const Center(
              child: Text(
                'This invoice is computer-generated. Kept for 7 years.',
                style: Cc.small,
              ),
            ),
          ],
        ),
      ),
    );
  }
}
