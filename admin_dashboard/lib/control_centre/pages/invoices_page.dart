import 'package:flutter/material.dart';

import '../../services/csv_downloader.dart';
import '../../utils/csv_export.dart';
import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_fields.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';
import '../widgets/invoice_preview.dart';

class InvoicesPage extends StatefulWidget {
  const InvoicesPage({
    super.key,
    required this.store,
    required this.nav,
    this.initialInvoiceId,
    this.initialQuery = '',
  });

  final CcStore store;
  final CcNav nav;
  final String? initialInvoiceId;
  final String initialQuery;

  @override
  State<InvoicesPage> createState() => _InvoicesPageState();
}

class _InvoicesPageState extends State<InvoicesPage> {
  static const List<String> _tabs = <String>[
    'Drafts',
    'Sent',
    'Overdue',
    'Paid',
    'Void',
    'Credit notes',
  ];

  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  int _tab = 0;
  String? _selectedId, _error;
  StaffInvoice? _detail;
  bool _busy = false;
  bool _pickedInitial = false;

  CcStore get _store => widget.store;
  StaffProfile get _me => _store.profile!;

  @override
  void initState() {
    super.initState();
    _store.refreshInvoices(force: true);
    if (_store.companies == null) _store.refreshCompanies();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  List<StaffInvoice> _forTab(int tab, List<StaffInvoice> all) {
    final DateTime now = DateTime.now().toUtc();
    final String query = _query.text.trim().toLowerCase();
    return all
        .where((StaffInvoice i) {
          final bool inTab = switch (tab) {
            0 => i.isDraft,
            1 => i.isOpen && !i.isOverdue(now),
            2 => i.isOverdue(now),
            3 => i.isPaid,
            4 => i.isVoid,
            _ => !i.isVoid && i.creditedMinor > 0,
          };
          if (!inTab) return false;
          if (query.isEmpty) return true;
          return (i.number ?? '').toLowerCase().contains(query) ||
              _store.companyName(i.tenantId).toLowerCase().contains(query);
        })
        .toList(growable: false);
  }

  int _tabOf(StaffInvoice invoice) {
    final DateTime now = DateTime.now().toUtc();
    if (invoice.isDraft) return 0;
    if (invoice.isVoid) return 4;
    if (invoice.isOverdue(now)) return 2;
    if (invoice.isPaid) return 3;
    return 1;
  }

  Future<void> _select(String? id) async {
    setState(() {
      _selectedId = id;
      _detail = null;
      _error = null;
    });
    if (id == null) return;
    try {
      final StaffInvoice detail = await _store.api.invoice(id);
      if (mounted && _selectedId == id) setState(() => _detail = detail);
    } on StaffApiException catch (error) {
      if (mounted && _selectedId == id) setState(() => _error = error.message);
    }
  }

  Future<void> _refreshAfter(String id) async {
    await _store.refreshInvoices();
    await _select(id);
  }

  Future<void> _act(
    StaffInvoice invoice,
    Future<Object?> Function() call,
    String done,
  ) async {
    setState(() {
      _busy = true;
      _error = null;
    });
    final CmdResult result = await CmdResult.run(call, done: done);
    if (!mounted) return;
    setState(() {
      _busy = false;
      if (!result.ok) _error = result.message;
    });
    if (result.ok) announce(context, done);
    await _refreshAfter(invoice.invoiceId);
  }

  Future<void> _issue(StaffInvoice invoice) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Issue this invoice?',
      message:
          'It gets its number and is locked. To fix it later, issue a credit note and a new invoice.',
      confirmLabel: 'Issue invoice',
    );
    if (!ok || !mounted) return;
    await _act(
      invoice,
      () => _store.api.issueInvoice(invoice.invoiceId),
      'The invoice was issued.',
    );
  }

  Future<void> _send(StaffInvoice invoice) async {
    await _store.refreshCompanies();
    if (!mounted) return;
    final String email =
        _store.company(invoice.tenantId)?.billingEmail ?? 'the billing email';
    final bool again = invoice.isNotDelivered;
    final bool ok = await showCcConfirm(
      context,
      title: again ? 'Send this invoice again?' : 'Send this invoice?',
      message: invoice.deliveryNeedsConfirm
          ? 'The mail provider may already have sent this email to $email. If you send again, the company may get it twice. The 14-day due date starts when the email is delivered.'
          : 'This emails the invoice to $email. The 14-day due date starts when the email is delivered.',
      confirmLabel: again ? 'Send again' : 'Send invoice',
    );
    if (!ok || !mounted) return;
    await _act(
      invoice,
      () => _store.api.sendInvoice(
        invoice.invoiceId,
        confirmDuplicateRisk: invoice.deliveryNeedsConfirm,
      ),
      'The invoice email is queued. It shows as sent when it is delivered.',
    );
  }

  Future<void> _deleteDraft(StaffInvoice invoice) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Delete this draft?',
      message: 'A deleted draft uses no invoice number.',
      confirmLabel: 'Delete draft',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _act(
      invoice,
      () => _store.api.deleteInvoiceDraft(invoice.invoiceId),
      'The draft was deleted.',
    );
    if (mounted) setState(() => _selectedId = null);
  }

  Future<void> _edit(StaffInvoice invoice) async {
    final TextEditingController note = TextEditingController(
      text: invoice.note,
    );
    DateTime? start;
    final bool saved = await showCcCommand(
      context,
      title: 'Edit note and dates',
      confirmLabel: 'Save changes',
      reasonLabel: null,
      body: StatefulBuilder(
        builder: (BuildContext context, StateSetter setInner) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text(
              'Only a draft can change. The end date follows the billing period.',
              style: Cc.small,
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 3,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Note'),
            ),
            CcDateField(
              label: 'Service starts',
              helper: 'Now: ${dayText(invoice.periodStart)}',
              value: start,
              onChanged: (DateTime day) => setInner(() => start = day),
            ),
          ],
        ),
      ),
      run: (String reason, String key) => CmdResult.run(
        () => _store.api.editInvoiceDraft(invoice.invoiceId, <String, Object?>{
          'note': note.text.trim(),
          if (start != null) 'periodStart': klMidnightUtc(start!),
        }),
        done: 'The draft was saved.',
      ),
    );
    note.dispose();
    if (saved && mounted) await _refreshAfter(invoice.invoiceId);
  }

  Future<void> _creditNote(StaffInvoice invoice) async {
    final TextEditingController amount = TextEditingController(
      text: (invoice.outstandingMinor / 100).toStringAsFixed(2),
    );
    final bool sent = await showCcCommand(
      context,
      title: 'Issue credit note',
      confirmLabel: 'Send for approval',
      reasonHint: 'Why the credit is needed. Saved in the audit log.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            '${invoice.number} has ${money(invoice.outstandingMinor)} left. A credit note cannot be more than that. For money back, record a refund to the account that paid.',
            style: Cc.small,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: amount,
            keyboardType: const TextInputType.numberWithOptions(decimal: true),
            decoration: const InputDecoration(labelText: 'Credit amount (RM)'),
          ),
        ],
      ),
      run: (String reason, String key) async {
        final int? minor = parseRmToMinor(amount.text);
        if (minor == null || minor > invoice.outstandingMinor) {
          return CmdResult.fail(
            'Enter an amount of at most ${money(invoice.outstandingMinor)}.',
          );
        }
        return sendForApproval(
          _store.api,
          action: 'invoice.credit_note',
          params: <String, Object?>{
            'invoiceId': invoice.invoiceId,
            'amountMinor': minor,
          },
          reason: reason,
          key: key,
          tenantId: invoice.tenantId,
        );
      },
    );
    amount.dispose();
    if (sent && mounted) await _store.refreshApprovals();
  }

  Future<void> _newInvoice() async {
    await _store.refreshCompanies();
    if (!mounted) return;
    final List<StaffCompany> companies =
        _store.companies?.value ?? const <StaffCompany>[];
    String? tenantId;
    DateTime? start;
    final TextEditingController note = TextEditingController();
    StaffInvoice? created;
    await showCcCommand(
      context,
      title: 'New invoice',
      confirmLabel: 'Create draft',
      reasonLabel: null,
      body: StatefulBuilder(
        builder: (BuildContext context, StateSetter setInner) => Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            DropdownButtonFormField<String>(
              initialValue: tenantId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Company'),
              items: <DropdownMenuItem<String>>[
                for (final StaffCompany company in companies)
                  DropdownMenuItem<String>(
                    value: company.tenantId,
                    child: Text(
                      company.legalName,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
              ],
              onChanged: (String? value) => setInner(() => tenantId = value),
            ),
            const SizedBox(height: 12),
            CcDateField(
              label: 'Service starts',
              helper: 'Leave empty to start today.',
              value: start,
              onChanged: (DateTime day) => setInner(() => start = day),
            ),
            const SizedBox(height: 12),
            TextField(
              controller: note,
              maxLines: 2,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Note (optional)'),
            ),
          ],
        ),
      ),
      run: (String reason, String key) async {
        if (tenantId == null) {
          return const CmdResult.fail('Choose a company.');
        }
        return CmdResult.run(
          () async {
            created = await _store.api
                .createInvoiceDraft(tenantId!, <String, Object?>{
                  if (start != null) 'periodStart': klMidnightUtc(start!),
                  if (note.text.trim().isNotEmpty) 'note': note.text.trim(),
                }, key: key);
            return created;
          },
          done: 'The draft was created.',
          fixFor: (StaffApiException error) {
            final String company = tenantId!;
            return switch (error.fix) {
              'choose_package' => CmdFix(
                'Choose a package for this company',
                () => widget.nav.openCompany(company),
              ),
              'set_price' => CmdFix(
                'Open Packages to set the price',
                () => widget.nav.go(CcSection.packages),
              ),
              _ => null,
            };
          },
        );
      },
    );
    note.dispose();
    if (created != null && mounted) {
      await _store.refreshInvoices();
      setState(() => _tab = 0);
      await _select(created!.invoiceId);
    }
  }

  void _export(List<StaffInvoice> rows) {
    downloadCsv(
      filename: 'invoices.csv',
      csv: buildCsv(
        <String>[
          'Number',
          'Company',
          'Status',
          'Period start',
          'Period end',
          'Amount (RM)',
          'Paid (RM)',
          'Credited (RM)',
          'Due',
        ],
        <List<Object?>>[
          for (final StaffInvoice i in rows)
            <Object?>[
              i.number ?? 'Draft',
              _store.companyName(i.tenantId),
              i.status,
              dayText(i.periodStart),
              lastDayText(i.periodEnd),
              (i.amountMinor / 100).toStringAsFixed(2),
              (i.paidMinor / 100).toStringAsFixed(2),
              (i.creditedMinor / 100).toStringAsFixed(2),
              dayText(i.dueAt),
            ],
        ],
      ),
    );
  }

  Widget _row(StaffInvoice invoice) {
    final bool selected = invoice.invoiceId == _selectedId;
    final DateTime now = DateTime.now().toUtc();
    final (String label, Tone tone) badge = invoice.isVoid
        ? ('Void', Tone.neutral)
        : invoice.isDraft
        ? ('Draft', Tone.neutral)
        : invoice.isPaid
        ? ('Paid', Tone.ok)
        : invoice.isOverdue(now)
        ? ('Overdue', Tone.danger)
        : invoice.status == 'sent'
        ? ('Sent', Tone.info)
        : invoice.isNotDelivered
        ? ('Not delivered', Tone.danger)
        : invoice.isSending
        ? ('Sending', Tone.info)
        : ('Issued', Tone.warn);
    final String company = _store.companyName(invoice.tenantId);
    return Semantics(
      button: true,
      selected: selected,
      label: '$company ${invoice.number ?? 'draft'} ${badge.$1}',
      excludeSemantics: true,
      onTap: () => _select(invoice.invoiceId),
      child: Material(
        color: selected ? Cc.accentSoft : Colors.white,
        child: InkWell(
          onTap: () => _select(invoice.invoiceId),
          child: Container(
            constraints: const BoxConstraints(minHeight: 64),
            padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 10),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        company,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Cc.ink,
                        ),
                      ),
                      Text(
                        invoice.number == null
                            ? periodText(invoice.periodStart, invoice.periodEnd)
                            : '${invoice.number} · ${periodText(invoice.periodStart, invoice.periodEnd)}',
                        overflow: TextOverflow.ellipsis,
                        style: Cc.small,
                      ),
                    ],
                  ),
                ),
                const SizedBox(width: 12),
                Column(
                  crossAxisAlignment: CrossAxisAlignment.end,
                  children: <Widget>[
                    Text(
                      money(invoice.amountMinor),
                      style: const TextStyle(
                        fontWeight: FontWeight.w700,
                        color: Cc.ink,
                        fontFeatures: Cc.figures,
                      ),
                    ),
                    const SizedBox(height: 4),
                    CcBadge(badge.$1, tone: badge.$2),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }

  Widget _detailPane(StaffInvoice listed) {
    final StaffInvoice invoice = _detail?.invoiceId == listed.invoiceId
        ? _detail!
        : listed;
    final StaffCompany? company = _store.company(invoice.tenantId);
    final bool hasEmail = company?.billingEmail != null;
    final bool canSend = invoice.status == 'issued' && !invoice.isSending;
    final bool canCredit =
        _me.canManageAccounts &&
        !invoice.isDraft &&
        !invoice.isVoid &&
        invoice.outstandingMinor > 0;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Wrap(
          spacing: 8,
          runSpacing: 8,
          crossAxisAlignment: WrapCrossAlignment.center,
          children: <Widget>[
            CcBadge(
              invoice.isDraft
                  ? 'Draft'
                  : invoice.isPaid
                  ? 'Paid'
                  : invoice.status == 'sent'
                  ? 'Sent'
                  : invoice.isNotDelivered
                  ? 'Not delivered'
                  : invoice.isSending
                  ? 'Sending'
                  : 'Issued',
              tone: invoice.isPaid
                  ? Tone.ok
                  : invoice.isNotDelivered
                  ? Tone.danger
                  : Tone.neutral,
            ),
            Text(
              invoice.isDraft
                  ? invoice.source == 'scheduler'
                        ? 'Drafted automatically 14 days before the paid-to date.'
                        : 'Drafted by ${invoice.createdBy}.'
                  : 'Issued ${dayText(invoice.issuedAt)}${invoice.issuedBy == null ? '' : ' by ${invoice.issuedBy}'}.',
              style: Cc.small,
            ),
            CcLink(
              company?.legalName ?? invoice.tenantId,
              semantic: 'Open company ${company?.legalName ?? ''}',
              onTap: () => widget.nav.openCompany(invoice.tenantId),
            ),
          ],
        ),
        const SizedBox(height: 10),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (invoice.isDraft) ...<Widget>[
              OutlinedButton(
                onPressed: _busy ? null : () => _edit(invoice),
                child: const Text('Edit note and dates'),
              ),
              FilledButton(
                onPressed: _busy ? null : () => _issue(invoice),
                child: const Text('Issue invoice'),
              ),
              if (_me.isOwner)
                TextButton(
                  onPressed: _busy ? null : () => _deleteDraft(invoice),
                  child: const Text('Delete draft'),
                ),
            ],
            if (canSend)
              FilledButton(
                onPressed: _busy || !hasEmail ? null : () => _send(invoice),
                child: Text(
                  invoice.isNotDelivered ? 'Send again' : 'Send invoice',
                ),
              ),
            if (invoice.canTakePayment)
              OutlinedButton(
                onPressed: () => widget.nav.openCompany(
                  invoice.tenantId,
                  tab: CompanyTab.payments,
                ),
                child: const Text('Record payment'),
              ),
            if (canCredit)
              OutlinedButton(
                onPressed: _busy ? null : () => _creditNote(invoice),
                child: const Text('Issue credit note…'),
              ),
          ],
        ),
        const SizedBox(height: 12),
        if (_error != null) CcBanner(text: _error!, tone: Tone.danger),
        if (invoice.isNotDelivered)
          CcBanner(
            bold: 'Not delivered:',
            text:
                '${invoice.deliveryReason ?? 'The email did not reach the company.'} The due date has not started.',
            tone: Tone.danger,
          ),
        if (invoice.isSending)
          const CcBanner(
            tone: Tone.info,
            text:
                'The invoice email is waiting to be sent. The 14-day due date starts when it is delivered.',
          ),
        if ((invoice.isDraft || canSend) && !hasEmail)
          CcBanner(
            bold: 'Cannot send:',
            text:
                'this company has no billing email. Add one, then send the invoice.',
            action: OutlinedButton(
              onPressed: () => widget.nav.openCompany(invoice.tenantId),
              child: const Text('Add billing email'),
            ),
          ),
        if (!invoice.isDraft && !invoice.isVoid)
          CcBanner(
            tone: Tone.info,
            text:
                '${invoice.number} was issued on ${dayText(invoice.issuedAt)}. It cannot be edited. To fix it, issue a credit note and a new invoice.',
          ),
        if (invoice.pendingEntryId != null)
          const CcBanner(
            tone: Tone.info,
            text:
                'A payment for this invoice is waiting to be checked against the bank statement.',
          ),
        InvoicePreview(invoice: invoice, company: company),
        if (invoice.creditNotes.isNotEmpty) ...<Widget>[
          const SizedBox(height: 16),
          CcCard(
            title: 'Credit notes',
            child: CcKeyValue(<(String, Widget)>[
              for (final StaffCreditNote note in invoice.creditNotes)
                (
                  note.number,
                  Text(
                    '${money(note.amountMinor)} · ${dayText(note.issuedAt)} · ${note.reason}',
                  ),
                ),
            ]),
          ),
        ],
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (BuildContext context, Widget? _) {
      final Loaded<List<StaffInvoice>>? loaded = _store.invoices;
      final List<StaffInvoice> all = loaded?.value ?? const <StaffInvoice>[];
      if (!_pickedInitial && loaded?.value != null) {
        _pickedInitial = true;
        final StaffInvoice? first = widget.initialInvoiceId == null
            ? null
            : all
                  .where(
                    (StaffInvoice i) => i.invoiceId == widget.initialInvoiceId,
                  )
                  .firstOrNull;
        if (first != null) {
          _tab = _tabOf(first);
          WidgetsBinding.instance.addPostFrameCallback(
            (_) => _select(first.invoiceId),
          );
        } else if (widget.initialQuery.isNotEmpty) {
          for (int tab = 0; tab < _tabs.length; tab++) {
            if (_forTab(tab, all).isNotEmpty) {
              _tab = tab;
              break;
            }
          }
        }
      }
      final List<StaffInvoice> rows = _forTab(_tab, all);
      final StaffInvoice? selected = rows
          .where((StaffInvoice i) => i.invoiceId == _selectedId)
          .firstOrNull;
      final bool wide = MediaQuery.sizeOf(context).width >= 1100;
      final Widget list = loaded == null
          ? const CcSkeleton()
          : loaded.value == null
          ? CcErrorState(
              what: 'invoices',
              message: loaded.error!,
              onRetry: _store.refreshInvoices,
            )
          : rows.isEmpty
          ? CcCard(
              child: CcEmptyState(
                title: _query.text.trim().isEmpty
                    ? _tab == 4
                          ? 'No voided invoices.'
                          : 'No ${_tabs[_tab].toLowerCase()} yet'
                    : 'No invoices match "${_query.text.trim()}"',
                message: _tab == 0
                    ? 'Drafts appear 14 days before a paid-to date, or when you press New invoice.'
                    : _query.text.trim().isEmpty
                    ? ''
                    : 'Check the spelling, or search by company name or invoice number.',
              ),
            )
          : Container(
              decoration: BoxDecoration(
                color: Colors.white,
                border: Border.all(color: Cc.line),
                borderRadius: BorderRadius.circular(12),
              ),
              clipBehavior: Clip.antiAlias,
              child: Column(
                children: <Widget>[
                  for (int i = 0; i < rows.length; i++) ...<Widget>[
                    if (i > 0) const Divider(height: 1, color: Cc.line),
                    _row(rows[i]),
                  ],
                ],
              ),
            );
      final Widget detail = selected == null
          ? CcCard(
              child: CcEmptyState(
                title: 'Choose an invoice',
                message: 'Its full preview and actions show here.',
              ),
            )
          : _detailPane(selected);
      return CcPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CcPageHeader(
              'Invoices',
              actions: <Widget>[
                OutlinedButton(
                  onPressed: all.isEmpty ? null : () => _export(all),
                  child: const Text('Export for accountant'),
                ),
                if (_me.canManageAccounts)
                  FilledButton(
                    onPressed: _newInvoice,
                    child: const Text('New invoice'),
                  ),
              ],
            ),
            CcTabBar(
              labels: _tabs,
              counts: <int?>[
                for (int i = 0; i < _tabs.length; i++)
                  loaded?.value == null ? null : _forTab(i, all).length,
              ],
              selected: _tab,
              onSelected: (int tab) => setState(() {
                _tab = tab;
                _selectedId = null;
                _detail = null;
              }),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 420),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      labelText: 'Search this list',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) => setState(() {}),
                  ),
                ),
              ),
            ),
            if (wide)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(width: 380, child: list),
                  const SizedBox(width: 20),
                  Expanded(child: detail),
                ],
              )
            else ...<Widget>[list, const SizedBox(height: 20), detail],
          ],
        ),
      );
    },
  );
}
