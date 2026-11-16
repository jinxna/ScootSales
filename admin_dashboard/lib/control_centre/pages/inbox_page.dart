import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';
import '../widgets/package_change.dart';
import '../widgets/payment_actions.dart';

class InboxPage extends StatefulWidget {
  const InboxPage({super.key, required this.store, required this.nav});

  final CcStore store;
  final CcNav nav;

  @override
  State<InboxPage> createState() => _InboxPageState();
}

class _InboxPageState extends State<InboxPage> {
  InboxKind? _filter;
  bool _busy = false;

  CcStore get _store => widget.store;
  StaffProfile get _me => _store.profile!;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  Future<void> _reload({bool force = false}) async {
    await Future.wait<void>(<Future<void>>[
      _store.loadAll(force: force),
      _store.loadFailedMail(force: force),
      _store.loadHeldMail(force: force),
      _store.loadSuppressions(force: force),
    ]);
  }

  Future<void> _retryHeld(StaffHeldMail held) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Retry held mail',
      message:
          'This puts the held mail to ${held.recipient} back in the queue. It is sent when the mail service accepts it.',
      confirmLabel: 'Retry mail',
    );
    if (!ok || !mounted) return;
    await _heldCommand(
      () => _store.api.retryHeldMail(held.jobId),
      'The mail was queued again.',
    );
  }

  Future<void> _handleHeld(StaffHeldMail held) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Mark mail as handled',
      message:
          'This records that you dealt with the mail to ${held.recipient} outside the system. It does not send the mail.',
      confirmLabel: 'Mark handled',
    );
    if (!ok || !mounted) return;
    await _heldCommand(
      () => _store.api.markHeldMailHandled(held.jobId),
      'The mail was marked as handled.',
    );
  }

  Future<void> _heldCommand(
    Future<Object?> Function() call,
    String done,
  ) async {
    setState(() => _busy = true);
    final CmdResult result = await CmdResult.run(call, done: done);
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, result.ok ? done : result.message!);
    await _store.loadHeldMail();
  }

  Future<void> _liftBlock(StaffMailSuppression bounced) async {
    final bool done = await showCcCommand(
      context,
      title: 'Lift the block on this address',
      confirmLabel: 'Lift block',
      reasonLabel: 'Reason',
      reasonHint: 'Say why the address is safe to use. Saved in the audit log.',
      body: Text(
        '${bounced.recipient} was blocked after a ${bounced.reasonText.toLowerCase()}. Mail to it is held until you lift the block.',
      ),
      run: (String reason, String key) => CmdResult.run(
        () => _store.api.liftMailSuppression(bounced.suppressionId, reason),
        done: 'The block was lifted.',
      ),
    );
    if (done) {
      await Future.wait<void>(<Future<void>>[
        _store.loadSuppressions(),
        _store.loadHeldMail(),
      ]);
    }
  }

  Future<void> _changePackage(InboxItem item) async {
    final StaffCompany? company = _store.company(item.tenantId);
    final StaffPlanRequest? request = item.request;
    if (company == null || request == null || _busy) return;
    setState(() => _busy = true);
    final Loaded<StaffCompanyPackages> packages = await Loaded.of(
      _store.api.companyPackages(company.tenantId),
    );
    if (!mounted) return;
    setState(() => _busy = false);
    if (packages.value == null) {
      announce(context, packages.error!);
      return;
    }
    final bool done = await showPackageChange(
      context,
      _store.api,
      company,
      packages.value!,
      planId: request.planId,
      interval: request.interval,
    );
    if (done) {
      await Future.wait<void>(<Future<void>>[
        _store.refreshRequests(),
        _refreshApprovals(),
      ]);
    }
  }

  Future<void> _declineRequest(InboxItem item) async {
    final StaffPlanRequest? request = item.request;
    if (request == null) return;
    final bool done = await showCcCommand(
      context,
      title: 'Decline this package request',
      confirmLabel: 'Decline request',
      danger: true,
      reasonLabel: 'Reason',
      reasonHint: 'The company administrator is told this reason by email.',
      body: Text(
        '${item.companyName} asked for ${request.planName ?? request.planId}.',
      ),
      run: (String reason, String key) => CmdResult.run(
        () => _store.api.declinePlanRequest(item.tenantId, reason),
        done: 'The request was declined.',
      ),
    );
    if (done) await _store.refreshRequests();
  }

  Future<void> _decide(InboxItem item, {required bool approve}) async {
    final StaffApproval? approval = item.approval;
    if (approval == null) return;
    await showCcCommand(
      context,
      title: approve ? 'Approve this change' : 'Reject this change',
      confirmLabel: approve ? 'Approve' : 'Reject',
      danger: !approve,
      reasonLabel: approve ? null : 'Reason',
      reasonHint: 'Say why you reject it. Saved in the audit log.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            approvalTitle(approval),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text('${item.companyName} · asked by ${approval.requestedBy}'),
          const SizedBox(height: 4),
          Text('Their reason: ${approval.reason}', style: Cc.small),
        ],
      ),
      run: (String reason, String key) async {
        StaffOperationOutcome? outcome;
        final CmdResult result = await CmdResult.run(() async {
          if (approve) {
            outcome = await _store.api.approve(approval.approvalId);
          } else {
            await _store.api.reject(approval.approvalId, reason);
          }
          return null;
        }, done: approve ? 'Approved.' : 'Rejected.');
        if (result.ok && outcome != null && !outcome!.completed) {
          return const CmdResult.ok('Approved. Finishing in the background.');
        }
        return result;
      },
    );
    await Future.wait<void>(<Future<void>>[
      _store.refreshApprovals(),
      _store.refreshCompanies(),
      _store.refreshMoney(),
    ]);
  }

  Future<void> _refreshApprovals() => Future.wait<void>(<Future<void>>[
    _store.refreshApprovals(),
    _store.refreshCompanies(),
    _store.refreshMoney(),
  ]);

  Future<void> _retryApproval(InboxItem item) async {
    final StaffApproval? approval = item.approval;
    if (approval == null) return;
    final bool ok = await showCcConfirm(
      context,
      title: 'Try this change again',
      message:
          'This runs the approved change again. Steps that already finished are not repeated.',
      confirmLabel: 'Try again',
    );
    if (!ok || !mounted) return;
    setState(() => _busy = true);
    StaffOperationOutcome? outcome;
    final CmdResult result = await CmdResult.run(() async {
      outcome = await _store.api.retryApproval(approval.approvalId);
      return null;
    });
    if (!mounted) return;
    setState(() => _busy = false);
    final bool finishing = result.ok && outcome != null && !outcome!.completed;
    announce(
      context,
      !result.ok
          ? result.message!
          : finishing
          ? 'Trying again. Finishing in the background.'
          : 'The change was finished.',
    );
    await _refreshApprovals();
  }

  Future<void> _closeApproval(InboxItem item) async {
    final StaffApproval? approval = item.approval;
    if (approval == null) return;
    await showCcCommand(
      context,
      title: 'Close this change',
      confirmLabel: 'Close change',
      danger: true,
      reasonLabel: 'Reason',
      reasonHint:
          'Say why it is closed. The reason is saved in the audit log. None of this change was applied, and nothing more will be done.',
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            approvalTitle(approval),
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          const SizedBox(height: 4),
          Text(item.companyName),
        ],
      ),
      run: (String reason, String key) => CmdResult.run(
        () => _store.api.closeApproval(approval.approvalId, reason),
        done: 'The change was closed.',
      ),
    );
    await _refreshApprovals();
  }

  Widget _actions(InboxItem item) {
    final bool manage = _me.canManageAccounts;
    switch (item.kind) {
      case InboxKind.graceOver:
      case InboxKind.renewalBlocked:
        return OutlinedButton(
          onPressed: () => widget.nav.openCompany(item.tenantId),
          child: const Text('Open company'),
        );
      case InboxKind.planRequest:
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: <Widget>[
            if (manage)
              FilledButton(
                onPressed: _busy ? null : () => _changePackage(item),
                child: const Text('Change package'),
              ),
            if (manage)
              OutlinedButton(
                onPressed: _busy ? null : () => _declineRequest(item),
                child: const Text('Decline…'),
              ),
            OutlinedButton(
              onPressed: () => widget.nav.openCompany(
                item.tenantId,
                tab: CompanyTab.requests,
              ),
              child: const Text('Open company'),
            ),
          ],
        );
      case InboxKind.payment:
        return manage && item.payment != null
            ? PaymentActionButtons(
                store: _store,
                entry: item.payment!,
                onDone: _store.refreshMoney,
                showVoid: false,
              )
            : const SizedBox.shrink();
      case InboxKind.invoice:
      case InboxKind.renewal:
        return OutlinedButton(
          onPressed: () => widget.nav.openInvoice(item.invoice!.invoiceId),
          child: const Text('Open invoice'),
        );
      case InboxKind.mail:
        return OutlinedButton(
          onPressed: () =>
              widget.nav.openCompany(item.tenantId, tab: CompanyTab.emails),
          child: const Text('Open emails'),
        );
      case InboxKind.heldMail:
        final StaffHeldMail held = item.held!;
        return manage
            ? Wrap(
                spacing: 8,
                runSpacing: 8,
                alignment: WrapAlignment.end,
                children: <Widget>[
                  if (!held.isOneTime &&
                      (held.kind != 'staff_invite' || _me.isOwner))
                    FilledButton(
                      onPressed: _busy ? null : () => _retryHeld(held),
                      child: const Text('Retry'),
                    ),
                  OutlinedButton(
                    onPressed: _busy ? null : () => _handleHeld(held),
                    child: const Text('Mark handled'),
                  ),
                ],
              )
            : const SizedBox.shrink();
      case InboxKind.bounce:
        return manage
            ? OutlinedButton(
                onPressed: _busy ? null : () => _liftBlock(item.suppression!),
                child: const Text('Lift block…'),
              )
            : const SizedBox.shrink();
      case InboxKind.onboarding:
        return OutlinedButton(
          onPressed: () => widget.nav.openOnboarding(item.draft!.draftId),
          child: const Text('Open checklist'),
        );
      case InboxKind.approvalFailed:
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: <Widget>[
            FilledButton(
              onPressed: _busy ? null : () => _retryApproval(item),
              child: const Text('Try again'),
            ),
            if (item.approval?.canClose ?? false)
              OutlinedButton(
                onPressed: _busy ? null : () => _closeApproval(item),
                child: const Text('Close…'),
              ),
            if (item.tenantId.isNotEmpty)
              OutlinedButton(
                onPressed: () => widget.nav.openCompany(
                  item.tenantId,
                  tab: CompanyTab.activity,
                ),
                child: const Text('Open activity'),
              ),
          ],
        );
      case InboxKind.approval:
        return Wrap(
          spacing: 8,
          runSpacing: 8,
          alignment: WrapAlignment.end,
          children: <Widget>[
            FilledButton(
              onPressed: () => _decide(item, approve: true),
              child: const Text('Approve'),
            ),
            if (item.approval?.canReject ?? false)
              OutlinedButton(
                onPressed: () => _decide(item, approve: false),
                child: const Text('Reject…'),
              ),
          ],
        );
    }
  }

  Tone _tone(InboxItem item) =>
      item.invoice?.isNotDelivered == true && item.kind == InboxKind.invoice
      ? Tone.danger
      : switch (item.kind) {
          InboxKind.graceOver ||
          InboxKind.renewalBlocked ||
          InboxKind.renewal ||
          InboxKind.mail ||
          InboxKind.approvalFailed => Tone.danger,
          InboxKind.heldMail || InboxKind.bounce => Tone.warn,
          InboxKind.payment => item.overdue ? Tone.danger : Tone.warn,
          InboxKind.approval || InboxKind.planRequest => Tone.info,
          _ => Tone.neutral,
        };

  Widget _loadErrors() {
    final List<(String, String)> failed = <(String, String)>[
      ('companies', _store.companies?.error ?? ''),
      ('invoices', _store.invoices?.error ?? ''),
      ('payments', _store.toCheck?.error ?? ''),
      ('plan requests', _store.requests?.error ?? ''),
    ].where(((String, String) e) => e.$2.isNotEmpty).toList(growable: false);
    if (failed.isEmpty) return const SizedBox.shrink();
    return CcBanner(
      tone: Tone.danger,
      bold:
          'Some items did not load: ${failed.map(((String, String) e) => e.$1).join(', ')}.',
      text: failed.first.$2,
      action: OutlinedButton(
        onPressed: () => _reload(force: true),
        child: const Text('Try again'),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (BuildContext context, Widget? _) {
      final List<InboxItem> all = _store.inboxItems();
      final bool loading =
          _store.companies == null ||
          _store.invoices == null ||
          _store.toCheck == null ||
          _store.requests == null;
      final List<InboxItem> shown =
          all
              .where((InboxItem i) => _filter == null || i.kind == _filter)
              .toList(growable: false)
            ..sort((InboxItem a, InboxItem b) {
              final bool aGrace = a.kind == InboxKind.graceOver;
              if (aGrace != (b.kind == InboxKind.graceOver)) {
                return aGrace ? -1 : 1;
              }
              if (a.overdue != b.overdue) return a.overdue ? -1 : 1;
              return (a.at ?? '').compareTo(b.at ?? '');
            });
      final Map<InboxKind, int> counts = <InboxKind, int>{
        for (final InboxKind kind in InboxKind.values)
          kind: all.where((InboxItem i) => i.kind == kind).length,
      };
      return CcPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CcPageHeader(
              'Inbox',
              actions: <Widget>[
                OutlinedButton.icon(
                  onPressed: () => _reload(force: true),
                  icon: const Icon(Icons.refresh, size: 18),
                  label: const Text('Refresh'),
                ),
              ],
            ),
            _loadErrors(),
            if (!_store.approvalsAvailable && _me.isOwner)
              const CcBanner(
                tone: Tone.info,
                text:
                    'Approvals are not switched on yet. Risky changes cannot be sent until they are.',
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Wrap(
                spacing: 8,
                runSpacing: 8,
                children: <Widget>[
                  CcFilterChip(
                    label: 'All',
                    count: all.length,
                    selected: _filter == null,
                    onTap: () => setState(() => _filter = null),
                  ),
                  for (final InboxKind kind in InboxKind.values)
                    if (counts[kind]! > 0 || _filter == kind)
                      CcFilterChip(
                        label: inboxKindLabel(kind),
                        count: counts[kind],
                        selected: _filter == kind,
                        onTap: () => setState(() => _filter = kind),
                      ),
                ],
              ),
            ),
            if (loading)
              const CcSkeleton(rows: 6)
            else
              CcTable(
                columns: const <CcColumn>[
                  CcColumn('Item', flex: 5),
                  CcColumn('Type', width: 150, hideBelow: 820),
                  CcColumn('Waiting', width: 100, hideBelow: 700),
                  CcColumn('Action', width: 320, right: true),
                ],
                rows: <CcTableRow>[
                  for (final InboxItem item in shown)
                    CcTableRow(
                      cells: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            CcLink(
                              item.companyName,
                              semantic: 'Open company ${item.companyName}',
                              onTap: () => item.tenantId.isEmpty
                                  ? widget.nav.go(CcSection.companies)
                                  : widget.nav.openCompany(item.tenantId),
                            ),
                            Text(
                              item.title,
                              style: const TextStyle(color: Cc.ink),
                            ),
                            Text(item.detail, style: Cc.small),
                          ],
                        ),
                        CcBadge(item.label, tone: _tone(item)),
                        Text(
                          item.at == null ? '' : ageText(item.at),
                          style: TextStyle(
                            fontFeatures: Cc.figures,
                            color: item.overdue ? Cc.dangerFg : Cc.body,
                          ),
                        ),
                        _actions(item),
                      ],
                    ),
                ],
                empty: const CcEmptyState(
                  title: 'Nothing is waiting',
                  message:
                      'New plan requests, payments to check, failed emails, held emails and bounced addresses appear here.',
                ),
              ),
          ],
        ),
      );
    },
  );
}
