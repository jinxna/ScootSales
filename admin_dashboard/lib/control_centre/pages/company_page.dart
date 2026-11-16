import 'dart:async';

import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';
import '../widgets/company_mail_panel.dart';
import '../widgets/company_requests.dart';
import '../widgets/package_change.dart';
import '../widgets/payment_actions.dart';
import '../widgets/prepare_data.dart';
import '../widgets/record_payment_panel.dart';

class CompanyPage extends StatefulWidget {
  const CompanyPage({
    super.key,
    required this.store,
    required this.nav,
    required this.tenantId,
    this.initialTab = CompanyTab.overview,
  });

  final CcStore store;
  final CcNav nav;
  final String tenantId;
  final int initialTab;

  @override
  State<CompanyPage> createState() => _CompanyPageState();
}

class _CompanyPageState extends State<CompanyPage> {
  late int _tab = widget.initialTab;
  bool _showRecord = false;
  Loaded<StaffPayments>? _payments;
  Loaded<StaffCompanyPackages>? _packages;
  Loaded<List<StaffInvoice>>? _invoices;
  Loaded<List<StaffOperationSummary>>? _operations;
  Loaded<StaffAuditPage>? _audit;
  bool _busy = false;
  Timer? _invoicePoll;

  CcStore get _store => widget.store;
  StaffProfile get _me => _store.profile!;
  StaffApiClient get _api => _store.api;
  String get _tenant => widget.tenantId;
  List<StaffInvoice> get _invoiceRows =>
      _invoices?.value ?? const <StaffInvoice>[];

  @override
  void initState() {
    super.initState();
    _showRecord = widget.initialTab == CompanyTab.payments;
    _loadAll();
  }

  @override
  void dispose() {
    _invoicePoll?.cancel();
    super.dispose();
  }

  bool _refreshing = false;

  Future<void> _refreshNow() async {
    if (_refreshing) return;
    setState(() => _refreshing = true);
    try {
      await _loadAll(force: true);
    } finally {
      if (mounted) setState(() => _refreshing = false);
    }
  }

  Future<void> _loadAll({bool force = false}) async {
    final Future<void> companies = _store.refreshCompanies(force: force);
    if (!_me.canManageAccounts) {
      await companies;
      return;
    }
    await Future.wait<void>(<Future<void>>[
      companies,
      _loadPayments(),
      _loadPackages(),
      _loadOperations(),
      _loadInvoices(),
      _store.refreshLifecycle(_tenant),
      _store.refreshRequests(force: force),
      _store.refreshToCheck(force: force),
    ]);
  }

  Future<void> _loadInvoices() async {
    final Loaded<List<StaffInvoice>> loaded = await Loaded.of(
      _api.invoices(tenantId: _tenant),
    );
    if (!mounted) return;
    setState(() => _invoices = loaded);
    final bool sending = _invoiceRows.any((StaffInvoice i) => i.isSending);
    if (!sending) {
      _invoicePoll?.cancel();
      _invoicePoll = null;
    } else {
      _invoicePoll ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => _loadInvoices(),
      );
    }
  }

  Future<void> _loadPayments() async {
    final Loaded<StaffPayments> loaded = await Loaded.of(
      _api.payments(_tenant),
    );
    if (mounted) setState(() => _payments = loaded);
  }

  Future<void> _loadPackages() async {
    final Loaded<StaffCompanyPackages> loaded = await Loaded.of(
      _api.companyPackages(_tenant),
    );
    if (mounted) setState(() => _packages = loaded);
  }

  Future<void> _loadOperations() async {
    final Loaded<List<StaffOperationSummary>> loaded = await Loaded.of(
      _api.companyOperations(_tenant),
    );
    if (mounted) setState(() => _operations = loaded);
  }

  Future<void> _loadAudit() async {
    final Loaded<StaffAuditPage> loaded = await Loaded.of(
      _api.auditEvents(tenantId: _tenant, limit: 10),
    );
    if (mounted) setState(() => _audit = loaded);
  }

  Future<void> _reloadMoney() async {
    await Future.wait<void>(<Future<void>>[
      _loadPayments(),
      _loadInvoices(),
      _store.refreshToCheck(),
      _store.refreshLifecycle(_tenant),
    ]);
    _store.invalidateInvoices();
  }

  String _periodDays(DateTime end) {
    final int days = end.difference(DateTime.now().toUtc()).inDays;
    return days >= 0 ? '$days days left' : '${-days} days ago';
  }

  Future<void> _changePackage(
    StaffCompany company, {
    StaffPlanRequest? request,
  }) async {
    final StaffCompanyPackages? packages = _packages?.value;
    if (packages == null) return;
    final bool done = await showPackageChange(
      context,
      _api,
      company,
      packages,
      planId: request?.planId,
      interval: request?.interval,
      onPrepare: _me.isOwner ? () => _prepareData(company) : null,
    );
    if (done && mounted) {
      await Future.wait<void>(<Future<void>>[
        _loadPackages(),
        _store.refreshRequests(),
        _loadOperations(),
        _store.refreshCompanies(),
      ]);
    }
  }

  Future<void> _requestAndRefresh(Future<bool> request) async {
    await request;
    await _store.refreshApprovals();
  }

  Future<void> _editCompany(StaffCompany company) async {
    final bool saved = await showCompanyEdit(
      context,
      _api,
      company,
      canRename: _me.isOwner,
    );
    if (saved && mounted) await _store.refreshCompanies();
  }

  Future<void> _prepareData(StaffCompany company) async {
    final bool done = await showPrepareData(
      context,
      _api,
      company.tenantId,
      company.legalName,
    );
    if (done && mounted) await _loadPackages();
  }

  Future<void> _changeBillingEmail(StaffCompany company) async {
    final TextEditingController email = TextEditingController(
      text: company.billingEmail ?? '',
    );
    await showCcCommand(
      context,
      title: company.billingEmail == null
          ? 'Add billing email'
          : 'Change billing email',
      confirmLabel: 'Send for approval',
      reasonHint: 'Why the address changes. Saved in the audit log.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Invoices, receipts and renewal reminders go to this address. The change waits for approval in the Inbox.',
            style: Cc.small,
          ),
          const SizedBox(height: 12),
          TextField(
            controller: email,
            keyboardType: TextInputType.emailAddress,
            decoration: const InputDecoration(labelText: 'Billing email'),
          ),
        ],
      ),
      run: (String reason, String key) {
        final String value = email.text.trim();
        if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
          return Future<CmdResult>.value(
            const CmdResult.fail('Enter a valid email address.'),
          );
        }
        return sendForApproval(
          _api,
          action: 'billing_email.change',
          params: <String, Object?>{'billingEmail': value},
          reason: reason,
          key: key,
          tenantId: company.tenantId,
        );
      },
    );
    email.dispose();
    await _store.refreshApprovals();
  }

  List<StaffPaymentEntry> _coveringPayments(StaffPayments payments) {
    return payments.entries
        .where(
          (StaffPaymentEntry e) =>
              payments.coveringEntryIds.contains(e.entryId),
        )
        .toList(growable: false);
  }

  static bool _needsApproval(String? target, String? from) =>
      target == 'suspended' ||
      target == 'cancelled' ||
      target == 'expired' ||
      (target == 'active' &&
          (from == 'suspended' || from == 'cancelled' || from == 'expired'));

  Future<void> _changeStatus(StaffCompany company, {String? preselect}) async {
    final StaffLifecycleResponse? response = _store.lifecycles[_tenant];
    final StaffLifecycle? current = response?.lifecycle;
    final List<String> next = response?.allowedNext ?? const <String>[];
    final List<StaffPaymentEntry> covering = _payments?.value == null
        ? const <StaffPaymentEntry>[]
        : _coveringPayments(_payments!.value!);
    String? state = next.contains(preselect) ? preselect : null;
    String? paymentId;
    await showCcCommand(
      context,
      title: 'Change status',
      confirmLabel: 'Apply change',
      body: StatefulBuilder(
        builder: (BuildContext context, StateSetter setInner) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Text(
              '${company.legalName} is ${stateLabel(current?.state).toLowerCase()}.',
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: state,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'New status'),
              items: <DropdownMenuItem<String>>[
                for (final String option in next)
                  DropdownMenuItem<String>(
                    value: option,
                    child: Text(stateLabel(option)),
                  ),
              ],
              onChanged: (String? value) => setInner(() {
                state = value;
                paymentId = null;
              }),
            ),
            if (state == 'active') ...<Widget>[
              const SizedBox(height: 12),
              DropdownButtonFormField<String>(
                initialValue: paymentId,
                isExpanded: true,
                decoration: const InputDecoration(
                  labelText: 'Payment that covers today',
                ),
                items: <DropdownMenuItem<String>>[
                  for (final StaffPaymentEntry e in covering)
                    DropdownMenuItem<String>(
                      value: e.entryId,
                      child: Text(
                        '${e.invoiceReference} · ${money(e.amountMinor ?? 0)}',
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                ],
                onChanged: (String? value) => setInner(() => paymentId = value),
              ),
              if (covering.isEmpty)
                const Padding(
                  padding: EdgeInsets.only(top: 8),
                  child: Text(
                    'Record a payment that covers today first. Without one, Apply change shows an error.',
                    style: TextStyle(color: Cc.warnFg),
                  ),
                ),
            ],
            if (_needsApproval(state, current?.state))
              const Padding(
                padding: EdgeInsets.only(top: 8),
                child: Text(
                  'This change waits for approval in the Inbox.',
                  style: Cc.small,
                ),
              ),
          ],
        ),
      ),
      run: (String reason, String key) async {
        if (state == null) return const CmdResult.fail('Choose a new status.');
        if (state == 'active' && paymentId == null) {
          return const CmdResult.fail('Choose a payment that covers today.');
        }
        final DateTime? retentionEnd = parseMoment(current?.retentionEndsAt);
        if (state == 'active' &&
            retentionEnd != null &&
            retentionEnd.isBefore(DateTime.now().toUtc())) {
          if (!mounted) return const CmdResult.fail('Nothing was sent.');
          final bool proceed = await showCcConfirm(
            context,
            title: 'Reactivate this company?',
            message:
                'The data window ended on ${dayText(current!.retentionEndsAt)}. Data may be deleted. Reactivate anyway?',
            confirmLabel: 'Reactivate anyway',
            danger: true,
          );
          if (!proceed) {
            return const CmdResult.fail('The reactivation was not sent.');
          }
        }
        final Map<String, Object?> params = <String, Object?>{
          'state': state,
          'expectedRevision': current?.revision ?? 0,
          'paymentEntryId': state == 'active' ? paymentId : null,
        };
        if (_needsApproval(state, current?.state)) {
          return sendForApproval(
            _api,
            action: switch (state) {
              'suspended' => 'lifecycle.suspend',
              'cancelled' => 'lifecycle.cancel',
              'expired' => 'lifecycle.expire',
              _ => 'lifecycle.reactivate',
            },
            params: <String, Object?>{
              'expectedRevision': params['expectedRevision'],
              if (state == 'active') 'paymentEntryId': paymentId,
            },
            reason: reason,
            key: key,
            tenantId: company.tenantId,
          );
        }
        try {
          final StaffOperationOutcome outcome = await _api.transitionLifecycle(
            company.tenantId,
            <String, Object?>{...params, 'reason': reason, 'ticket': null},
            key: key,
          );
          if (outcome.completed) {
            return const CmdResult.ok('The status changed.');
          }
          return const CmdResult.fail(
            'The change did not finish. Open Activity and press Retry.',
          );
        } on StaffApiException catch (error) {
          return CmdResult.fail(
            isUncertain(error) ? uncertainMessage : friendlyError(error),
            uncertain: isUncertain(error),
          );
        }
      },
    );
    await Future.wait<void>(<Future<void>>[
      _store.refreshLifecycle(_tenant),
      _store.refreshApprovals(),
      _loadOperations(),
      _store.refreshCompanies(),
    ]);
  }

  Future<void> _extend(StaffCompany company) async {
    final List<StaffInvoice> open = _invoiceRows
        .where((StaffInvoice i) => i.canExtend)
        .toList(growable: false);
    String? invoiceId;
    await showCcCommand(
      context,
      title: 'Extend an invoice',
      confirmLabel: 'Send for approval',
      reasonHint: 'Why more time is fair. Saved in the audit log.',
      body: StatefulBuilder(
        builder: (BuildContext context, StateSetter setInner) => Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            const Text(
              'An invoice can be extended once, by up to 14 days. It waits for approval in the Inbox.',
              style: Cc.small,
            ),
            const SizedBox(height: 12),
            DropdownButtonFormField<String>(
              initialValue: invoiceId,
              isExpanded: true,
              decoration: const InputDecoration(labelText: 'Invoice'),
              items: <DropdownMenuItem<String>>[
                for (final StaffInvoice i in open)
                  DropdownMenuItem<String>(
                    value: i.invoiceId,
                    child: Text('${i.number} · ${money(i.outstandingMinor)}'),
                  ),
              ],
              onChanged: (String? value) => setInner(() => invoiceId = value),
            ),
          ],
        ),
      ),
      run: (String reason, String key) {
        if (invoiceId == null) {
          return Future<CmdResult>.value(
            const CmdResult.fail('Choose an invoice.'),
          );
        }
        return sendForApproval(
          _api,
          action: 'invoice.extension',
          params: <String, Object?>{'invoiceId': invoiceId, 'days': 14},
          reason: reason,
          key: key,
          tenantId: company.tenantId,
        );
      },
    );
    await _store.refreshApprovals();
  }

  Widget _moreMenu(StaffCompany company) => PopupMenuButton<String>(
    tooltip: '',
    offset: const Offset(0, 48),
    onSelected: (String value) {
      switch (value) {
        case 'package':
          _changePackage(company);
        case 'prepare':
          _prepareData(company);
        case 'status':
          _changeStatus(company);
        case 'email':
          _changeBillingEmail(company);
        case 'extend':
          _extend(company);
        case 'quote':
          _requestAndRefresh(showQuoteRequest(context, _api, company));
        case 'override':
          _requestAndRefresh(showOverrideRequest(context, _api, company));
        case 'edit':
          _editCompany(company);
      }
    },
    itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
      if (_me.canManageAccounts)
        const PopupMenuItem<String>(
          value: 'package',
          height: 44,
          child: Text('Change package…'),
        ),
      if (_me.isOwner)
        const PopupMenuItem<String>(
          value: 'prepare',
          height: 44,
          child: Text('Prepare company data…'),
        ),
      if (_me.canManageAccounts)
        const PopupMenuItem<String>(
          value: 'status',
          height: 44,
          child: Text('Change status…'),
        ),
      if (_me.canManageAccounts)
        PopupMenuItem<String>(
          value: 'email',
          height: 44,
          child: Text(
            company.billingEmail == null
                ? 'Add billing email…'
                : 'Change billing email…',
          ),
        ),
      if (_invoiceRows.any((StaffInvoice i) => i.canExtend))
        const PopupMenuItem<String>(
          value: 'extend',
          height: 44,
          child: Text('Extend an invoice…'),
        ),
      if (_me.canManageAccounts)
        const PopupMenuItem<String>(
          value: 'quote',
          height: 44,
          child: Text('Request a quoted price…'),
        ),
      if (_me.canManageAccounts)
        const PopupMenuItem<String>(
          value: 'override',
          height: 44,
          child: Text('Request a package override…'),
        ),
      if (_me.isOwner || _me.canEnterSetup)
        const PopupMenuItem<String>(
          value: 'edit',
          height: 44,
          child: Text('Edit company record…'),
        ),
    ],
    child: Semantics(
      button: true,
      label: 'More actions',
      excludeSemantics: true,
      child: Container(
        constraints: const BoxConstraints(minHeight: 44),
        padding: const EdgeInsets.symmetric(horizontal: 16),
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Cc.line),
          borderRadius: BorderRadius.circular(8),
        ),
        child: const Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text('More', style: TextStyle(fontWeight: FontWeight.w600)),
            Icon(Icons.expand_more, size: 18),
          ],
        ),
      ),
    ),
  );

  Widget _header(StaffCompany company) {
    final String? state = _store.lifecycleState(_tenant);
    final String? paidEnd = _store.paidToPeriodEndIn(_invoiceRows);
    final DateTime? end = parseMoment(paidEnd);
    final StaffCurrentPackage? current = _packages?.value?.current;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.only(bottom: 4),
          child: Row(
            children: <Widget>[
              CcLink(
                'Companies',
                semantic: 'Back to companies',
                onTap: () => widget.nav.go(CcSection.companies),
              ),
              const Text('  /  ', style: Cc.small),
              Flexible(
                child: Text(
                  company.legalName,
                  overflow: TextOverflow.ellipsis,
                  style: Cc.small,
                ),
              ),
            ],
          ),
        ),
        CcPageHeader(
          company.legalName,
          actions: <Widget>[
            CcBadge(stateLabel(state), tone: stateTone(state)),
            if (current != null)
              CcBadge(
                '${current.name} · ${intervalLabel(current.billingInterval)}',
              ),
            if (end != null)
              CcBadge(
                'Paid to ${lastDayText(paidEnd!)} · ${_periodDays(end)}',
                tone: end.isBefore(DateTime.now().toUtc())
                    ? Tone.danger
                    : end.difference(DateTime.now().toUtc()).inDays <= 14
                    ? Tone.warn
                    : Tone.ok,
              ),
            if (company.expired)
              const CcBadge('Expired record', tone: Tone.danger),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _refreshing ? null : _refreshNow,
              icon: const Icon(Icons.refresh),
            ),
            if (_me.canManageAccounts || _me.canEnterSetup) _moreMenu(company),
            if (_me.canManageAccounts)
              FilledButton.icon(
                onPressed: () => setState(() {
                  _tab = CompanyTab.payments;
                  _showRecord = true;
                }),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Record payment'),
              ),
          ],
        ),
        if (_me.canManageAccounts &&
            (state == null || state == 'lead') &&
            end != null)
          CcBanner(
            bold: 'Ready to go live.',
            text:
                'A payment covers this company. Make it active to open its dashboard.',
            action: FilledButton(
              onPressed: () => _changeStatus(company, preselect: 'active'),
              child: const Text('Make active'),
            ),
          ),
        if (company.billingEmail == null)
          CcBanner(
            bold: 'No billing email.',
            text:
                'Receipts and renewal reminders cannot be sent to this company.',
            action: _me.canManageAccounts
                ? OutlinedButton(
                    onPressed: () => _changeBillingEmail(company),
                    child: const Text('Add billing email'),
                  )
                : null,
          ),
      ],
    );
  }

  Widget _openItem(String label, Tone tone, String text, String age, int tab) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 10),
        child: Semantics(
          button: true,
          label: '$label: $text',
          excludeSemantics: true,
          onTap: () => setState(() => _tab = tab),
          child: InkWell(
            borderRadius: BorderRadius.circular(10),
            onTap: () => setState(() => _tab = tab),
            child: Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.all(12),
              decoration: BoxDecoration(
                border: Border.all(color: Cc.line),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        CcBadge(label, tone: tone),
                        const SizedBox(height: 6),
                        Text(text),
                      ],
                    ),
                  ),
                  if (age.isNotEmpty) Text(age, style: Cc.small),
                ],
              ),
            ),
          ),
        ),
      );

  Widget _overview(StaffCompany company) {
    final StaffLifecycleResponse? response = _store.lifecycles[_tenant];
    final StaffLifecycle? lifecycle = response?.lifecycle;
    final String? paidEnd = _store.paidToPeriodEndIn(_invoiceRows);
    final StaffCurrentPackage? current = _packages?.value?.current;
    final List<StaffInvoice> invoices = _invoiceRows;
    final DateTime now = DateTime.now().toUtc();
    final List<StaffPlanRequest> requests =
        (_store.requests?.value ?? const <StaffPlanRequest>[])
            .where((StaffPlanRequest r) => r.tenantId == _tenant && r.open)
            .toList(growable: false);
    final List<StaffPaymentEntry> waiting =
        (_store.toCheck?.value ?? const <StaffPaymentEntry>[])
            .where((StaffPaymentEntry e) => e.tenantId == _tenant)
            .toList(growable: false);
    final List<StaffInvoice> overdue = invoices
        .where((StaffInvoice i) => i.isOverdue(now))
        .toList(growable: false);
    final List<StaffInvoice> drafts = invoices
        .where((StaffInvoice i) => i.isDraft)
        .toList(growable: false);
    final Widget subscription = CcCard(
      title: 'Subscription',
      child: CcKeyValue(<(String, Widget)>[
        (
          'Package',
          Text(
            current == null
                ? 'No package yet'
                : '${current.name} · ${intervalLabel(current.billingInterval)}',
          ),
        ),
        (
          'Paid to',
          Text(
            paidEnd == null
                ? 'Not paid yet'
                : dayText(
                    parseMoment(
                      paidEnd,
                    )!.subtract(const Duration(days: 1)).toIso8601String(),
                  ),
          ),
        ),
        (
          'Status',
          Text(
            lifecycle == null
                ? 'No status yet. ${stateLabel(null)}.'
                : '${stateLabel(lifecycle.state)} since ${dayText(lifecycle.stateSince)}${lifecycle.state == 'past_due' ? '. Reason: ${lifecycle.reason}' : ''}',
          ),
        ),
        (
          'Renewal reminders',
          Text(
            company.billingEmail == null
                ? 'Sent automatically 14 and 3 days before the paid-to date. Skipped: no billing email.'
                : 'Sent automatically 14 and 3 days before the paid-to date.',
          ),
        ),
        (
          'If it is not paid',
          const Text(
            'It becomes Past due automatically 14 days after the invoice is delivered. Suspending is always a person\'s decision.',
          ),
        ),
        (
          'Payments checked',
          Text(
            waiting.isEmpty
                ? (_payments?.value?.entries.any(
                            (StaffPaymentEntry e) => e.isPayment,
                          ) ==
                          false
                      ? 'No payments'
                      : 'All payments checked')
                : '${waiting.length} waiting to be checked',
          ),
        ),
      ]),
    );
    final Widget limits = current == null
        ? const SizedBox.shrink()
        : Padding(
            padding: const EdgeInsets.only(top: 16),
            child: CcCard(
              title: 'Limits in ${current.name}',
              child: Wrap(
                spacing: 32,
                runSpacing: 12,
                children: <Widget>[
                  for (final MapEntry<String, int?> limit
                      in current.limits.entries)
                    SizedBox(
                      width: 190,
                      child: Row(
                        mainAxisAlignment: MainAxisAlignment.spaceBetween,
                        children: <Widget>[
                          Text(
                            staffLimitLabels[limit.key] ?? limit.key,
                            style: Cc.small,
                          ),
                          Text(
                            limit.value == null
                                ? 'Unlimited'
                                : '${limit.value}',
                            style: Cc.numbers,
                          ),
                        ],
                      ),
                    ),
                ],
              ),
            ),
          );
    final Widget side = Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CcCard(
          title: 'Open items',
          child:
              requests.isEmpty &&
                  waiting.isEmpty &&
                  overdue.isEmpty &&
                  drafts.isEmpty
              ? const Text(
                  'Nothing is waiting for this company.',
                  style: Cc.small,
                )
              : Column(
                  children: <Widget>[
                    for (final StaffPlanRequest r in requests)
                      _openItem(
                        'Plan request',
                        Tone.info,
                        '${r.planName ?? r.planId}, ${intervalLabel(r.interval)}',
                        ageText(r.createdAt),
                        CompanyTab.requests,
                      ),
                    for (final StaffPaymentEntry e in waiting)
                      _openItem(
                        'Payment to check',
                        Tone.warn,
                        '${money(e.amountMinor ?? 0)} · ${e.invoiceReference ?? ''}',
                        ageText(e.createdAt),
                        CompanyTab.payments,
                      ),
                    for (final StaffInvoice i in overdue)
                      _openItem(
                        'Invoice overdue',
                        Tone.danger,
                        '${i.number} · ${money(i.outstandingMinor)}',
                        'due ${dayText(i.dueAt)}',
                        CompanyTab.invoices,
                      ),
                    for (final StaffInvoice i in drafts)
                      _openItem(
                        'Draft invoice',
                        Tone.neutral,
                        periodText(i.periodStart, i.periodEnd),
                        ageText(i.createdAt),
                        CompanyTab.invoices,
                      ),
                  ],
                ),
        ),
        const SizedBox(height: 16),
        CcCard(
          title: 'Contacts',
          child: CcKeyValue(<(String, Widget)>[
            (
              'Billing email',
              Text(
                company.billingEmail == null
                    ? 'Not set'
                    : maskEmail(company.billingEmail!),
              ),
            ),
            ('Workspace', Text(codeText(company.workspace))),
          ], labelWidth: 120),
        ),
      ],
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => box.maxWidth >= 980
          ? Row(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Expanded(
                  flex: 3,
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.stretch,
                    children: <Widget>[subscription, limits],
                  ),
                ),
                const SizedBox(width: 20),
                Expanded(flex: 2, child: side),
              ],
            )
          : Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                subscription,
                limits,
                const SizedBox(height: 16),
                side,
              ],
            ),
    );
  }

  Widget _invoicesTab() {
    final List<StaffInvoice> rows = _invoiceRows
        .where((StaffInvoice i) => !i.isVoid)
        .toList(growable: false);
    return CcTable(
      columns: const <CcColumn>[
        CcColumn('Invoice', width: 170),
        CcColumn('Period', flex: 3, hideBelow: 760),
        CcColumn('Amount', width: 130, right: true),
        CcColumn('Status', width: 130),
      ],
      rows: <CcTableRow>[
        for (final StaffInvoice i in rows)
          CcTableRow(
            semanticLabel: 'Open invoice ${i.number ?? 'draft'}',
            onTap: () => widget.nav.openInvoice(i.invoiceId),
            cells: <Widget>[
              Text(
                i.number ?? 'Draft',
                style: const TextStyle(
                  fontWeight: FontWeight.w700,
                  color: Cc.ink,
                ),
              ),
              Text(periodText(i.periodStart, i.periodEnd)),
              Text(money(i.amountMinor), style: Cc.numbers),
              CcBadge(
                i.isDraft
                    ? 'Draft'
                    : i.isPaid
                    ? 'Paid'
                    : i.isOverdue(DateTime.now().toUtc())
                    ? 'Overdue'
                    : i.isNotDelivered
                    ? 'Not delivered'
                    : i.isSending
                    ? 'Sending'
                    : i.status == 'sent'
                    ? 'Sent'
                    : 'Issued',
                tone: i.isPaid
                    ? Tone.ok
                    : i.isOverdue(DateTime.now().toUtc()) || i.isNotDelivered
                    ? Tone.danger
                    : i.isSending
                    ? Tone.info
                    : Tone.neutral,
              ),
            ],
          ),
      ],
      empty: const CcEmptyState(
        title: 'No invoices yet',
        message:
            'Drafts appear 14 days before a paid-to date. Create one in Invoices.',
      ),
    );
  }

  Widget _paymentsTab(StaffCompany company) {
    final Loaded<StaffPayments>? loaded = _payments;
    final List<Widget> children = <Widget>[];
    if (_showRecord && _me.canManageAccounts) {
      children.add(
        RecordPaymentPanel(
          key: ValueKey<bool>(_invoices?.value != null),
          api: _api,
          company: company,
          invoices: _invoiceRows,
          onDone: () async {
            setState(() => _showRecord = false);
            await _reloadMoney();
          },
          onCancel: () => setState(() => _showRecord = false),
          onOpenInvoices: () => widget.nav.go(CcSection.invoices),
        ),
      );
      children.add(const SizedBox(height: 16));
    }
    if (loaded == null) {
      children.add(const CcSkeleton());
    } else if (loaded.value == null) {
      children.add(
        CcErrorState(
          what: 'payments',
          message: loaded.error!,
          onRetry: _loadPayments,
        ),
      );
    } else {
      final Set<String> voided = loaded.value!.voidedIds;
      final Map<String, StaffPaymentEntry> voids = <String, StaffPaymentEntry>{
        for (final StaffPaymentEntry e in loaded.value!.entries)
          if (e.type == 'void' && e.receiptId != null) e.receiptId!: e,
      };
      final List<StaffPaymentEntry> rows = loaded.value!.entries
          .where((StaffPaymentEntry e) => e.isPayment)
          .toList(growable: false)
          .reversed
          .toList(growable: false);
      if (loaded.value!.checkBy != null) {
        children.add(
          CcBanner(
            bold: 'A payment is waiting to be checked.',
            text:
                parseMoment(
                      loaded.value!.checkBy,
                    )?.isAfter(DateTime.now().toUtc()) ??
                    true
                ? 'Check it against the bank statement by ${dayText(loaded.value!.checkBy)}. An unchecked payment gives at most 7 days of cover.'
                : 'The 7 days of cover from an unchecked payment ended on ${dayText(loaded.value!.checkBy)}. Check the payment against the bank statement to cover the company again.',
          ),
        );
        children.add(const SizedBox(height: 12));
      }
      children.add(
        CcTable(
          columns: const <CcColumn>[
            CcColumn('Invoice and bank reference', flex: 3),
            CcColumn('Amount', width: 130, right: true),
            CcColumn('Recorded', flex: 3, hideBelow: 900),
            CcColumn('Actions', width: 250, right: true),
          ],
          rows: <CcTableRow>[
            for (final StaffPaymentEntry e in rows)
              CcTableRow(
                cells: <Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        e.invoiceReference ?? 'Payment',
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Cc.ink,
                        ),
                      ),
                      Text(
                        'Bank ref ${e.externalReference ?? ''}',
                        style: Cc.small,
                      ),
                      if (e.periodStart != null && e.periodEnd != null)
                        Text(
                          periodText(e.periodStart!, e.periodEnd!),
                          style: Cc.small,
                        ),
                    ],
                  ),
                  Text(money(e.amountMinor ?? 0), style: Cc.numbers),
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        'Bank date ${shortDayText(e.receivedAt)} · by ${e.createdBy}',
                        style: const TextStyle(fontSize: 13),
                      ),
                      if (voided.contains(e.entryId))
                        CcBadge(
                          'Voided: ${voids[e.entryId]?.reason ?? ''}',
                          tone: Tone.danger,
                        )
                      else if (e.check != null)
                        CcBadge(
                          'Checked by ${e.check!.checkedBy} · ${e.check!.receiptNumber}',
                          tone: Tone.ok,
                        )
                      else
                        const CcBadge('Waiting to be checked', tone: Tone.warn),
                    ],
                  ),
                  voided.contains(e.entryId) || !_me.canManageAccounts
                      ? const SizedBox.shrink()
                      : PaymentActionButtons(
                          store: _store,
                          entry: e,
                          onDone: _reloadMoney,
                        ),
                ],
              ),
          ],
          empty: const CcEmptyState(
            title: 'No payments yet',
            message:
                'Press Record payment when the bank statement shows money for an invoice.',
          ),
        ),
      );
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: children,
    );
  }

  Widget _requestsTab(StaffCompany company) {
    final List<StaffPlanRequest> rows =
        (_store.requests?.value ?? const <StaffPlanRequest>[])
            .where((StaffPlanRequest r) => r.tenantId == _tenant)
            .toList(growable: false);
    return CcTable(
      columns: const <CcColumn>[
        CcColumn('Request', flex: 3),
        CcColumn('Sent', width: 140, hideBelow: 700),
        CcColumn('Status', width: 100),
        CcColumn('Actions', width: 190, right: true),
      ],
      rows: <CcTableRow>[
        for (final StaffPlanRequest r in rows)
          CcTableRow(
            cells: <Widget>[
              Text(
                '${r.planName ?? r.planId}, ${intervalLabel(r.interval)}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
              Text(dayText(r.createdAt)),
              CcBadge(
                r.open ? 'Open' : 'Done',
                tone: r.open ? Tone.warn : Tone.ok,
              ),
              r.open && _me.canManageAccounts
                  ? OutlinedButton(
                      onPressed: () => _changePackage(company, request: r),
                      child: const Text('Change package'),
                    )
                  : const SizedBox.shrink(),
            ],
          ),
      ],
      empty: const CcEmptyState(
        title: 'No plan requests',
        message: 'When the company asks for another package it appears here.',
      ),
    );
  }

  Future<void> _retry(StaffOperationSummary operation) async {
    setState(() => _busy = true);
    final CmdResult result = await savedOrWaiting(
      () => _api.retryOperation(operation.operationId),
      saved: 'The operation completed.',
    );
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, result.message!);
    await Future.wait<void>(<Future<void>>[
      _loadOperations(),
      _loadPackages(),
      _store.refreshLifecycle(_tenant),
    ]);
  }

  Widget _activityTab() {
    final Loaded<List<StaffOperationSummary>>? ops = _operations;
    if (_audit == null) _loadAudit();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (ops != null && ops.value != null && ops.value!.isNotEmpty)
          CcCard(
            title: 'Operations needing attention',
            child: Column(
              children: <Widget>[
                for (final StaffOperationSummary o in ops.value!)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      children: <Widget>[
                        CcBadge(
                          o.status == 'pending' ? 'Pending' : 'Failed',
                          tone: Tone.danger,
                        ),
                        const SizedBox(width: 12),
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                operationLabel(o.action),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                ),
                              ),
                              Text(
                                <String>[
                                  ?o.reason,
                                  if (o.createdAt != null)
                                    dateTimeText(o.createdAt),
                                  o.errorMessage ??
                                      (o.errorType == null
                                          ? ''
                                          : 'Error: ${o.errorType}'),
                                ].where((String s) => s.isNotEmpty).join(' · '),
                                style: Cc.small,
                              ),
                            ],
                          ),
                        ),
                        if (o.canRetry)
                          TextButton(
                            onPressed: _busy ? null : () => _retry(o),
                            child: const Text('Retry'),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          )
        else if (ops?.error != null)
          CcBanner(text: ops!.error!, tone: Tone.danger),
        const SizedBox(height: 16),
        _auditCard(),
      ],
    );
  }

  Widget _auditCard() {
    final Loaded<StaffAuditPage>? audit = _audit;
    return CcCard(
      title: 'Recent activity',
      child: audit == null
          ? const Text('Loading…', style: Cc.small)
          : audit.value == null
          ? Text(
              audit.error!.contains('(404)')
                  ? 'The audit log is not switched on yet.'
                  : audit.error!,
              style: Cc.small,
            )
          : audit.value!.events.isEmpty
          ? const Text(
              'Nothing has been recorded for this company yet.',
              style: Cc.small,
            )
          : Column(
              children: <Widget>[
                for (final StaffAuditEvent e in audit.value!.events)
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 6),
                    child: Row(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        SizedBox(
                          width: 150,
                          child: Text(dateTimeText(e.at), style: Cc.small),
                        ),
                        Expanded(
                          child: Text(
                            '${e.actor}: ${e.summary.isEmpty ? e.action : e.summary}',
                          ),
                        ),
                      ],
                    ),
                  ),
              ],
            ),
    );
  }

  String _rulesText(StaffCompany company) {
    final String recorded = company.rulesVersion ?? 'Not set';
    final String? current = company.currentRulesVersion;
    if (current == null) return recorded;
    return '$recorded (${company.rulesVersion == current ? 'matches' : 'differs from'} the current build)';
  }

  Widget _technicalTab(StaffCompany company) => CcCard(
    title: 'Technical details',
    child: CcKeyValue(<(String, Widget)>[
      ('Company ID', SelectableText(company.tenantId)),
      ('Workspace code', SelectableText(codeText(company.workspace))),
      ('Company code', SelectableText(codeText(company.companyCode))),
      ('Company record', Text(company.status)),
      ('Package reference', Text(company.planRef)),
      ('Firebase project', Text(company.projectId ?? 'Not set')),
      ('Release ring', Text(company.releaseRing ?? 'Not set')),
      ('Rules version', Text(_rulesText(company))),
      (
        'Record expires',
        Text(
          company.expiresAt == null
              ? 'Not set'
              : dateTimeText(company.expiresAt),
        ),
      ),
    ]),
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (BuildContext context, Widget? _) {
      final Loaded<List<StaffCompany>>? loaded = _store.companies;
      if (loaded == null) return const CcPage(child: CcSkeleton());
      final StaffCompany? company = _store.company(_tenant);
      if (company == null) {
        return CcPage(
          child: loaded.value == null
              ? CcErrorState(
                  what: 'this company',
                  message: loaded.error!,
                  onRetry: _store.refreshCompanies,
                )
              : CcCard(
                  child: CcEmptyState(
                    title: 'That company is not in the list',
                    message: 'It may have been removed. Go back to the list.',
                    action: FilledButton(
                      onPressed: () => widget.nav.go(CcSection.companies),
                      child: const Text('Back to companies'),
                    ),
                  ),
                ),
        );
      }
      final int requestCount =
          (_store.requests?.value ?? const <StaffPlanRequest>[])
              .where((StaffPlanRequest r) => r.tenantId == _tenant && r.open)
              .length;
      final List<int> visibleTabs = _me.canManageAccounts
          ? const <int>[
              CompanyTab.overview,
              CompanyTab.invoices,
              CompanyTab.payments,
              CompanyTab.requests,
              CompanyTab.emails,
              CompanyTab.activity,
              CompanyTab.technical,
            ]
          : const <int>[CompanyTab.overview, CompanyTab.technical];
      return CcPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _header(company),
            CcTabBar(
              labels: <String>[
                for (final int tab in visibleTabs)
                  switch (tab) {
                    CompanyTab.overview => 'Overview',
                    CompanyTab.invoices => 'Invoices',
                    CompanyTab.payments => 'Payments',
                    CompanyTab.requests =>
                      requestCount > 0
                          ? 'Requests ($requestCount)'
                          : 'Requests',
                    CompanyTab.emails => 'Emails',
                    CompanyTab.activity => 'Activity',
                    _ => 'Technical',
                  },
              ],
              selected: visibleTabs.contains(_tab)
                  ? visibleTabs.indexOf(_tab)
                  : 0,
              onSelected: (int index) =>
                  setState(() => _tab = visibleTabs[index]),
            ),
            switch (visibleTabs.contains(_tab) ? _tab : CompanyTab.overview) {
              CompanyTab.overview => _overview(company),
              CompanyTab.invoices => _invoicesTab(),
              CompanyTab.payments => _paymentsTab(company),
              CompanyTab.requests => _requestsTab(company),
              CompanyTab.emails => CompanyMailPanel(
                api: _api,
                company: company,
                canAct: _me.canManageAccounts,
              ),
              CompanyTab.activity => _activityTab(),
              _ => _technicalTab(company),
            },
          ],
        ),
      );
    },
  );
}
