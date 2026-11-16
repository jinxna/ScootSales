import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_command.dart';
import 'cc_common.dart';
import 'cc_fields.dart';

class RecordPaymentPanel extends StatefulWidget {
  const RecordPaymentPanel({
    super.key,
    required this.api,
    required this.company,
    required this.invoices,
    required this.onDone,
    required this.onCancel,
    required this.onOpenInvoices,
    this.initialInvoiceId,
  });

  final StaffApiClient api;
  final StaffCompany company;
  final List<StaffInvoice> invoices;
  final String? initialInvoiceId;
  final VoidCallback onDone, onCancel, onOpenInvoices;

  @override
  State<RecordPaymentPanel> createState() => _RecordPaymentPanelState();
}

class _RecordPaymentPanelState extends State<RecordPaymentPanel> {
  final TextEditingController _reference = TextEditingController();
  final TextEditingController _reason = TextEditingController();
  late final List<StaffInvoice> _open = widget.invoices
      .where((StaffInvoice i) => i.canTakePayment)
      .toList(growable: false);
  late String? _invoiceId =
      _open.any((StaffInvoice i) => i.invoiceId == widget.initialInvoiceId)
      ? widget.initialInvoiceId
      : _open.length == 1
      ? _open.first.invoiceId
      : null;
  late DateTime _bankDate = klToday();
  String? _key, _error, _fieldError;
  Map<String, Object?>? _body;
  bool _busy = false, _uncertain = false;

  @override
  void dispose() {
    _reference.dispose();
    _reason.dispose();
    super.dispose();
  }

  StaffInvoice? get _invoice =>
      _open.where((StaffInvoice i) => i.invoiceId == _invoiceId).firstOrNull;

  Future<void> _submit() async {
    if (_busy) return;
    final StaffInvoice? invoice = _invoice;
    if (!_uncertain) {
      if (invoice == null) {
        setState(() => _fieldError = 'Choose the invoice this payment is for.');
        return;
      }
      if (_reference.text.trim().isEmpty || _reason.text.trim().isEmpty) {
        setState(() => _fieldError = 'Enter the bank reference and a reason.');
        return;
      }
      _key = newKey();
      _body = <String, Object?>{
        'amountMinor': invoice.outstandingMinor,
        'currency': 'MYR',
        'externalReference': _reference.text.trim(),
        'invoiceId': invoice.invoiceId,
        'receivedAt': klMidnightUtc(_bankDate),
        'reason': _reason.text.trim(),
      };
    }
    setState(() {
      _busy = true;
      _error = null;
      _fieldError = null;
    });
    final CmdResult result = await CmdResult.run(
      () =>
          widget.api.recordPayment(widget.company.tenantId, _body!, key: _key!),
    );
    if (!mounted) return;
    if (result.ok) {
      announce(
        context,
        'The payment was recorded. It must be checked against the bank statement.',
      );
      widget.onDone();
      return;
    }
    setState(() {
      _busy = false;
      _uncertain = result.uncertain;
      _error = result.message;
      if (!result.uncertain) {
        _key = null;
        _body = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) {
    final StaffInvoice? invoice = _invoice;
    final DateTime today = klToday();
    final DateTime? issued = parseMoment(invoice?.issuedAt);
    final DateTime firstDay = issued == null
        ? DateTime(2020)
        : DateTime(
            issued.add(const Duration(hours: 8)).year,
            issued.add(const Duration(hours: 8)).month,
            issued.add(const Duration(hours: 8)).day,
          );
    final DateTime cover = today.add(const Duration(days: 7));
    return CcCard(
      title: 'Record payment',
      child: _open.isEmpty
          ? Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                const CcBanner(
                  bold: 'No invoice is open for payment.',
                  text:
                      'Issue an invoice first, or check that the last payment is not waiting to be checked.',
                ),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    FilledButton(
                      onPressed: widget.onOpenInvoices,
                      child: const Text('Open invoices'),
                    ),
                    TextButton(
                      onPressed: widget.onCancel,
                      child: const Text('Close'),
                    ),
                  ],
                ),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                DropdownButtonFormField<String>(
                  initialValue: _invoiceId,
                  isExpanded: true,
                  decoration: const InputDecoration(labelText: 'Invoice'),
                  items: <DropdownMenuItem<String>>[
                    for (final StaffInvoice i in _open)
                      DropdownMenuItem<String>(
                        value: i.invoiceId,
                        child: Text(
                          '${i.number} · ${money(i.outstandingMinor)} · ${periodText(i.periodStart, i.periodEnd)}',
                          overflow: TextOverflow.ellipsis,
                        ),
                      ),
                  ],
                  onChanged: _uncertain
                      ? null
                      : (String? v) => setState(() => _invoiceId = v),
                ),
                const SizedBox(height: 12),
                Wrap(
                  spacing: 16,
                  runSpacing: 12,
                  children: <Widget>[
                    SizedBox(
                      width: 220,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Amount (from the invoice)',
                        ),
                        child: Text(
                          invoice == null
                              ? '—'
                              : money(invoice.outstandingMinor),
                          style: Cc.numbers,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 300,
                      child: InputDecorator(
                        decoration: const InputDecoration(
                          labelText: 'Service period (from the invoice)',
                        ),
                        child: Text(
                          invoice == null
                              ? '—'
                              : periodText(
                                  invoice.periodStart,
                                  invoice.periodEnd,
                                ),
                          style: Cc.numbers,
                        ),
                      ),
                    ),
                    SizedBox(
                      width: 220,
                      child: CcDateField(
                        label: 'Bank date',
                        value: _bankDate,
                        first: firstDay,
                        last: today,
                        onChanged: _uncertain
                            ? null
                            : (DateTime d) => setState(() => _bankDate = d),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reference,
                  readOnly: _uncertain,
                  decoration: const InputDecoration(
                    labelText: 'Bank reference',
                    helperText:
                        'Compared without spaces, dashes or case. A voided payment reference stays blocked.',
                  ),
                ),
                const SizedBox(height: 12),
                TextField(
                  controller: _reason,
                  readOnly: _uncertain,
                  maxLength: 500,
                  decoration: const InputDecoration(
                    labelText: 'Reason',
                    helperText: 'For example: Bank statement checked.',
                  ),
                ),
                if (invoice != null)
                  CcBanner(
                    tone: Tone.info,
                    text:
                        'Until it is checked, this payment covers 7 days, to ${dayText(cover.toIso8601String())}. After the check it covers ${periodText(invoice.periodStart, invoice.periodEnd)}.',
                  ),
                if (_fieldError != null)
                  CcBanner(text: _fieldError!, tone: Tone.danger),
                if (_error != null) CcBanner(text: _error!, tone: Tone.danger),
                Wrap(
                  spacing: 8,
                  children: <Widget>[
                    FilledButton(
                      onPressed: _busy ? null : _submit,
                      child: _busy
                          ? const SizedBox(
                              width: 18,
                              height: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : Text(_uncertain ? 'Check again' : 'Record payment'),
                    ),
                    TextButton(
                      onPressed: _busy || _uncertain ? null : widget.onCancel,
                      child: const Text('Cancel'),
                    ),
                  ],
                ),
              ],
            ),
    );
  }
}
