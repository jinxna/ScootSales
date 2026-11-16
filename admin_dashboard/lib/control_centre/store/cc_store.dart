import 'dart:async';

import 'package:flutter/foundation.dart';

import '../staff_api_client.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';

enum InboxKind {
  graceOver,
  renewalBlocked,
  planRequest,
  payment,
  invoice,
  renewal,
  mail,
  heldMail,
  bounce,
  onboarding,
  approval,
  approvalFailed,
}

String inboxKindLabel(InboxKind kind) => switch (kind) {
  InboxKind.graceOver => 'Grace over, still unpaid',
  InboxKind.renewalBlocked => 'Renewal not drafted',
  InboxKind.planRequest => 'Plan request',
  InboxKind.payment => 'Payment to check',
  InboxKind.invoice => 'Invoice to send',
  InboxKind.renewal => 'Renewal problem',
  InboxKind.mail => 'Failed email',
  InboxKind.heldMail => 'Held email',
  InboxKind.bounce => 'Bounced address',
  InboxKind.onboarding => 'Onboarding',
  InboxKind.approval => 'Approval',
  InboxKind.approvalFailed => 'Approval failed',
};

typedef FailedMail = StaffAttentionMail;

class InboxItem {
  const InboxItem({
    required this.id,
    required this.kind,
    required this.tenantId,
    required this.companyName,
    required this.title,
    required this.detail,
    required this.at,
    this.overdue = false,
    this.request,
    this.payment,
    this.invoice,
    this.mail,
    this.held,
    this.suppression,
    this.approval,
    this.draft,
  });

  final String id, tenantId, companyName, title, detail;
  final InboxKind kind;

  String get label {
    final StaffInvoice? row = invoice;
    if (kind == InboxKind.invoice && row != null) {
      if (row.isSending) return 'Sending';
      if (row.isNotDelivered) return 'Not delivered';
    }
    return inboxKindLabel(kind);
  }

  final String? at;
  final bool overdue;
  final StaffPlanRequest? request;
  final StaffPaymentEntry? payment;
  final StaffInvoice? invoice;
  final FailedMail? mail;
  final StaffHeldMail? held;
  final StaffMailSuppression? suppression;
  final StaffApproval? approval;
  final StaffOnboardingDraft? draft;
}

class CcStore extends ChangeNotifier {
  CcStore(this.api);

  static const Duration staleAfter = Duration(seconds: 30);

  final StaffApiClient api;
  StaffProfile? profile;
  Loaded<List<StaffCompany>>? companies;
  Loaded<List<StaffInvoice>>? invoices;
  Loaded<List<StaffPaymentEntry>>? toCheck;
  Loaded<List<StaffPlanRequest>>? requests;
  Loaded<List<StaffApproval>>? approvals;
  Loaded<List<StaffOnboardingDraft>>? drafts;
  Loaded<StaffToday>? today;
  Loaded<List<StaffSupportGrant>>? supportGrants;
  Loaded<List<FailedMail>>? failedMail;
  Loaded<List<StaffHeldMail>>? heldMail;
  Loaded<List<StaffMailSuppression>>? suppressions;
  bool approvalsAvailable = true;
  final Map<String, StaffLifecycleResponse?> lifecycles =
      <String, StaffLifecycleResponse?>{};
  final Map<String, DateTime> _loadedAt = <String, DateTime>{};
  final Map<String, int> _generation = <String, int>{};
  final Map<String, Future<void>> _inFlight = <String, Future<void>>{};
  Future<void>? _loadAllRun;
  bool _loadAllForced = false;

  String get me => profile?.email ?? '';

  Future<void> _cached<T>(
    String key,
    bool force,
    Future<Loaded<T>> Function() read,
    void Function(Loaded<T> loaded) apply,
  ) {
    if (!force) {
      final Future<void>? running = _inFlight[key];
      if (running != null) return running;
      final DateTime? at = _loadedAt[key];
      if (at != null && DateTime.now().difference(at) < staleAfter) {
        return Future<void>.value();
      }
    }
    final int generation = (_generation[key] ?? 0) + 1;
    _generation[key] = generation;
    late final Future<void> run;
    run =
        () async {
          final Loaded<T> loaded = await read();
          if (_generation[key] != generation) return;
          apply(loaded);
          if (loaded.value != null) {
            _loadedAt[key] = DateTime.now();
          } else {
            _loadedAt.remove(key);
          }
          notifyListeners();
        }().whenComplete(() {
          if (identical(_inFlight[key], run)) _inFlight.remove(key);
        });
    _inFlight[key] = run;
    return run;
  }

  void invalidateInvoices() => _loadedAt.remove('invoices');

  Future<void> loadProfile() async {
    profile = await api.profile();
    notifyListeners();
  }

  Future<void> loadAll({bool force = false}) {
    final Future<void>? running = _loadAllRun;
    if (running != null && (_loadAllForced || !force)) return running;
    late final Future<void> run;
    run = _runLoadAll(force).whenComplete(() {
      if (identical(_loadAllRun, run)) _loadAllRun = null;
    });
    _loadAllRun = run;
    _loadAllForced = force;
    return run;
  }

  Future<void> _runLoadAll(bool force) async {
    await Future.wait<void>(<Future<void>>[
      refreshCompanies(force: force),
      refreshInvoices(force: force),
      refreshToCheck(force: force),
      refreshRequests(force: force),
      refreshApprovals(force: force),
      refreshDrafts(force: force),
      refreshToday(force: force),
    ]);
  }

  Future<void> refreshCompanies({bool force = true}) =>
      _cached<List<StaffCompany>>(
        'companies',
        force,
        () => Loaded.of(api.companies()),
        (Loaded<List<StaffCompany>> loaded) => companies = loaded,
      );

  Future<void> refreshInvoices({bool force = true}) =>
      _cached<List<StaffInvoice>>(
        'invoices',
        force,
        () => Loaded.of(api.invoices()),
        (Loaded<List<StaffInvoice>> loaded) {
          invoices = loaded;
          _syncInvoicePoll();
        },
      );

  Timer? _invoicePoll;

  void _syncInvoicePoll() {
    final bool sending = (invoices?.value ?? const <StaffInvoice>[]).any(
      (StaffInvoice invoice) => invoice.isSending,
    );
    if (!sending) {
      _invoicePoll?.cancel();
      _invoicePoll = null;
    } else {
      _invoicePoll ??= Timer.periodic(
        const Duration(seconds: 15),
        (_) => refreshInvoices(),
      );
    }
  }

  @override
  void dispose() {
    _invoicePoll?.cancel();
    super.dispose();
  }

  Future<void> refreshToCheck({bool force = true}) =>
      _cached<List<StaffPaymentEntry>>(
        'toCheck',
        force,
        () => Loaded.of(api.paymentsToCheck()),
        (Loaded<List<StaffPaymentEntry>> loaded) => toCheck = loaded,
      );

  Future<void> refreshRequests({bool force = true}) =>
      _cached<List<StaffPlanRequest>>(
        'requests',
        force,
        () => Loaded.of(api.planRequests()),
        (Loaded<List<StaffPlanRequest>> loaded) => requests = loaded,
      );

  Future<void> refreshDrafts({bool force = true}) =>
      _cached<List<StaffOnboardingDraft>>(
        'drafts',
        force,
        () => Loaded.of(api.onboardingDrafts()),
        (Loaded<List<StaffOnboardingDraft>> loaded) => drafts = loaded,
      );

  Future<void> refreshApprovals({bool force = true}) =>
      _cached<List<StaffApproval>>('approvals', force, () async {
        try {
          final List<StaffApproval> rows = await api.approvals();
          approvalsAvailable = true;
          return Loaded<List<StaffApproval>>.ok(rows);
        } on StaffApiException catch (error) {
          approvalsAvailable = !isMissingRoute(error);
          return Loaded<List<StaffApproval>>.failed(error.message);
        } catch (_) {
          return const Loaded<List<StaffApproval>>.failed(
            'The staff service returned an invalid response.',
          );
        }
      }, (Loaded<List<StaffApproval>> loaded) => approvals = loaded);

  Future<void> refreshSupportGrants({bool force = true}) =>
      _cached<List<StaffSupportGrant>>(
        'supportGrants',
        force,
        () => Loaded.of(api.supportHome()),
        (Loaded<List<StaffSupportGrant>> loaded) => supportGrants = loaded,
      );

  Future<void> refreshToday({bool force = true}) => _cached<StaffToday>(
    'today',
    force,
    () => Loaded.of(api.today()),
    (Loaded<StaffToday> loaded) => today = loaded,
  );

  Future<void> refreshMoney({bool force = true}) async {
    await Future.wait<void>(<Future<void>>[
      refreshInvoices(force: force),
      refreshToCheck(force: force),
    ]);
  }

  Future<void> _loadLifecycle(String tenantId) async {
    try {
      lifecycles[tenantId] = await api.lifecycle(tenantId);
    } on StaffApiException {
      lifecycles[tenantId] = null;
    } catch (_) {
      lifecycles[tenantId] = null;
    }
  }

  Future<void> refreshLifecycle(String tenantId) async {
    await _loadLifecycle(tenantId);
    final String? state = lifecycles[tenantId]?.lifecycle?.state;
    final List<StaffCompany>? rows = companies?.value;
    if (state != null && rows != null) {
      companies = Loaded<List<StaffCompany>>.ok(<StaffCompany>[
        for (final StaffCompany row in rows)
          row.tenantId == tenantId ? row.withLifecycleState(state) : row,
      ]);
    }
    notifyListeners();
  }

  String? lifecycleState(String tenantId) =>
      company(tenantId)?.lifecycleState ??
      lifecycles[tenantId]?.lifecycle?.state;

  Future<void> loadFailedMail({bool force = true}) => _cached<List<FailedMail>>(
    'failedMail',
    force,
    () => Loaded.of(
      api.mailAttention().then(
        (List<StaffAttentionMail> rows) => <StaffAttentionMail>[
          for (final StaffAttentionMail row in rows)
            if (row.job.needsAttention &&
                !row.job.isHeld &&
                row.job.retriedAs == null &&
                row.job.handledAt == null)
              row,
        ],
      ),
    ),
    (Loaded<List<FailedMail>> loaded) => failedMail = loaded,
  );

  Future<void> loadHeldMail({bool force = true}) =>
      _cached<List<StaffHeldMail>>(
        'heldMail',
        force,
        () => Loaded.of(api.heldMail()),
        (Loaded<List<StaffHeldMail>> loaded) => heldMail = loaded,
      );

  Future<void> loadSuppressions({bool force = true}) =>
      _cached<List<StaffMailSuppression>>(
        'suppressions',
        force,
        () => Loaded.of(api.mailSuppressions()),
        (Loaded<List<StaffMailSuppression>> loaded) => suppressions = loaded,
      );

  StaffCompany? company(String tenantId) =>
      (companies?.value ?? const <StaffCompany>[])
          .where((StaffCompany c) => c.tenantId == tenantId)
          .firstOrNull;

  String companyName(String tenantId) =>
      company(tenantId)?.legalName ?? tenantId;

  List<StaffInvoice> invoicesFor(String tenantId) =>
      (invoices?.value ?? const <StaffInvoice>[])
          .where((StaffInvoice i) => i.tenantId == tenantId)
          .toList(growable: false);

  String? paidToPeriodEnd(String tenantId) =>
      paidToPeriodEndIn(invoicesFor(tenantId));

  String? paidToPeriodEndIn(Iterable<StaffInvoice> invoices) {
    DateTime? best;
    String? text;
    for (final StaffInvoice invoice in invoices) {
      if (invoice.paidMinor <= 0 || invoice.isVoid) continue;
      final DateTime? end = parseMoment(invoice.periodEnd);
      if (end != null && (best == null || end.isAfter(best))) {
        best = end;
        text = invoice.periodEnd;
      }
    }
    return text;
  }

  List<StaffOnboardingDraft> get openDrafts =>
      (drafts?.value ?? const <StaffOnboardingDraft>[])
          .where((StaffOnboardingDraft d) => d.isSetup)
          .toList(growable: false);

  List<StaffApproval> get approvalsForMe =>
      (approvals?.value ?? const <StaffApproval>[])
          .where((StaffApproval a) => a.isPending && a.canDecide)
          .toList(growable: false);

  List<StaffApproval> get failedApprovals =>
      (approvals?.value ?? const <StaffApproval>[])
          .where(
            (StaffApproval a) =>
                a.status == 'approved' && a.executionError != null,
          )
          .toList(growable: false);

  List<InboxItem> inboxItems() {
    final DateTime now = DateTime.now().toUtc();
    final List<InboxItem> items = <InboxItem>[];
    for (final StaffGraceOver over
        in today?.value?.graceOver ?? const <StaffGraceOver>[]) {
      items.add(
        InboxItem(
          id: 'grace:${over.tenantId}',
          kind: InboxKind.graceOver,
          tenantId: over.tenantId,
          companyName: over.legalName.isEmpty
              ? companyName(over.tenantId)
              : over.legalName,
          title: 'Grace over, still unpaid',
          detail: 'The grace period ended on ${dayText(over.graceEndedAt)}',
          at: over.graceEndedAt,
          overdue: true,
        ),
      );
    }
    for (final StaffRenewalBlocked blocked
        in today?.value?.renewalBlocked ?? const <StaffRenewalBlocked>[]) {
      items.add(
        InboxItem(
          id: 'renewal:${blocked.tenantId}',
          kind: InboxKind.renewalBlocked,
          tenantId: blocked.tenantId,
          companyName: blocked.legalName.isEmpty
              ? companyName(blocked.tenantId)
              : blocked.legalName,
          title: 'The renewal invoice could not be drafted',
          detail:
              '${blocked.reason} Cover ends ${dayText(blocked.coverEndsAt)}.',
          at: blocked.coverEndsAt,
          overdue: true,
        ),
      );
    }
    for (final StaffPlanRequest request
        in requests?.value ?? const <StaffPlanRequest>[]) {
      if (!request.open) continue;
      items.add(
        InboxItem(
          id: 'req:${request.requestId}',
          kind: InboxKind.planRequest,
          tenantId: request.tenantId,
          companyName: request.companyName ?? companyName(request.tenantId),
          title: 'Change package to ${request.planName ?? request.planId}',
          detail:
              '${intervalLabel(request.interval)[0].toUpperCase()}${intervalLabel(request.interval).substring(1)} · sent by the company administrator',
          at: request.createdAt,
          request: request,
        ),
      );
    }
    for (final StaffPaymentEntry entry
        in toCheck?.value ?? const <StaffPaymentEntry>[]) {
      final DateTime? created = parseMoment(entry.createdAt);
      items.add(
        InboxItem(
          id: 'pay:${entry.entryId}',
          kind: InboxKind.payment,
          tenantId: entry.tenantId,
          companyName: entry.companyName ?? companyName(entry.tenantId),
          title:
              '${money(entry.amountMinor ?? 0)} · invoice ${entry.invoiceReference ?? ''}',
          detail: entry.createdBy == me
              ? 'Recorded by you'
              : 'Recorded by ${entry.createdBy}',
          at: entry.createdAt,
          overdue: created != null && now.difference(created).inHours >= 72,
          payment: entry,
        ),
      );
    }
    for (final StaffInvoice invoice
        in invoices?.value ?? const <StaffInvoice>[]) {
      final StaffCompany? owner = company(invoice.tenantId);
      if (invoice.isDraft || invoice.status == 'issued') {
        items.add(
          InboxItem(
            id: 'inv:${invoice.invoiceId}',
            kind: InboxKind.invoice,
            tenantId: invoice.tenantId,
            companyName: owner?.legalName ?? invoice.tenantId,
            title:
                '${invoice.number ?? 'Draft'} · ${money(invoice.amountMinor)} · ${periodText(invoice.periodStart, invoice.periodEnd)}',
            detail: invoice.isSending
                ? 'Sending: the email is waiting to go out'
                : owner?.billingEmail == null
                ? 'Cannot send: no billing email'
                : invoice.isNotDelivered
                ? 'Not delivered: ${invoice.deliveryReason ?? 'the email did not reach the company'} Send it again.'
                : invoice.isDraft
                ? 'Draft, ready to issue and send'
                : 'Issued, ready to send',
            at: invoice.createdAt,
            invoice: invoice,
          ),
        );
      } else if (invoice.isOverdue(now)) {
        items.add(
          InboxItem(
            id: 'due:${invoice.invoiceId}',
            kind: InboxKind.renewal,
            tenantId: invoice.tenantId,
            companyName: owner?.legalName ?? invoice.tenantId,
            title:
                '${invoice.number ?? 'Invoice'} is unpaid · ${money(invoice.outstandingMinor)}',
            detail: 'Due ${dayText(invoice.dueAt)}',
            at: invoice.dueAt,
            overdue: true,
            invoice: invoice,
          ),
        );
      }
    }
    for (final FailedMail failed in failedMail?.value ?? const <FailedMail>[]) {
      items.add(
        InboxItem(
          id: 'mail:${failed.job.jobId}',
          kind: InboxKind.mail,
          tenantId: failed.tenantId,
          companyName: failed.companyName,
          title: '${mailKindLabel(failed.job.kind)} not delivered',
          detail:
              '${maskEmail(failed.job.recipient)} · ${failed.job.attempts} of ${failed.job.maxAttempts} attempts',
          at: failed.job.updatedAt,
          mail: failed,
        ),
      );
    }
    for (final StaffHeldMail held
        in heldMail?.value ?? const <StaffHeldMail>[]) {
      items.add(
        InboxItem(
          id: 'held:${held.jobId}',
          kind: InboxKind.heldMail,
          tenantId: held.tenantId == staffMailTenant ? '' : held.tenantId,
          companyName: held.companyName,
          title: '${mailKindLabel(held.kind)} is held',
          detail:
              '${held.recipient} · ${held.reasonText} · ${held.attempts} of ${held.maxAttempts} attempts',
          at: held.heldAt,
          overdue: true,
          held: held,
        ),
      );
    }
    for (final StaffMailSuppression bounced
        in suppressions?.value ?? const <StaffMailSuppression>[]) {
      items.add(
        InboxItem(
          id: 'bounce:${bounced.suppressionId}',
          kind: InboxKind.bounce,
          tenantId: bounced.tenantId == staffMailTenant ? '' : bounced.tenantId,
          companyName: bounced.companyName,
          title: '${mailKindLabel(bounced.kind)} bounced',
          detail: '${bounced.recipient} · ${bounced.reasonText}',
          at: bounced.lastEventAt,
          suppression: bounced,
        ),
      );
    }
    for (final StaffOnboardingDraft draft in openDrafts) {
      final StaffOnboardingStep? next = draft.nextStep;
      items.add(
        InboxItem(
          id: 'onb:${draft.draftId}',
          kind: InboxKind.onboarding,
          tenantId: draft.tenantId ?? '',
          companyName: draft.legalName,
          title: next == null
              ? 'Ready to open'
              : 'Step ${next.n}: ${next.label}',
          detail: '${draft.doneCount} of ${draft.total} steps done',
          at: draft.createdAt,
          draft: draft,
        ),
      );
    }
    for (final StaffApproval approval in failedApprovals) {
      items.add(
        InboxItem(
          id: 'aprf:${approval.approvalId}',
          kind: InboxKind.approvalFailed,
          tenantId: approval.tenantId ?? '',
          companyName:
              approval.companyName ??
              (approval.tenantId == null
                  ? 'All companies'
                  : companyName(approval.tenantId!)),
          title:
              '${approvalTitle(approval).replaceFirst(RegExp(r'\.+$'), '')} did not finish',
          detail: approval.appliedSteps.isEmpty
              ? approval.executionError!
              : '${approval.executionError!} Already done: ${approval.appliedSteps.join('; ')}. Try again to finish the rest.',
          at: approval.decidedAt ?? approval.createdAt,
          overdue: true,
          approval: approval,
        ),
      );
    }
    for (final StaffApproval approval in approvalsForMe) {
      items.add(
        InboxItem(
          id: 'apr:${approval.approvalId}',
          kind: InboxKind.approval,
          tenantId: approval.tenantId ?? '',
          companyName:
              approval.companyName ??
              (approval.tenantId == null
                  ? 'All companies'
                  : companyName(approval.tenantId!)),
          title: approvalTitle(approval),
          detail: 'Asked by ${approval.requestedBy}',
          at: approval.createdAt,
          approval: approval,
        ),
      );
    }
    return items;
  }
}

const String staffMailTenant = 't_platform';

String mailKindLabel(String kind) => switch (kind) {
  'invitation' => 'Invitation',
  'receipt' => 'Receipt',
  'invoice' => 'Invoice',
  'plan_request_received' => 'Plan request received',
  'plan_request_notice' => 'New plan request',
  'renewal_reminder' => 'Renewal reminder',
  'status_changed' => 'Account status change',
  'past_due' => 'Past due notice',
  'billing_email_changed' => 'Billing email change',
  'plan_request_declined' => 'Plan request declined',
  'account_deletion_notice' => 'Account deletion notice',
  'staff_digest' => 'Daily digest',
  'audit_anchor' => 'Audit anchor',
  'staff_signin_code' => 'Sign-in code',
  'staff_notice' => 'Security notice',
  'staff_invite' => 'Staff invitation',
  'password_reset' => 'Password reset',
  'email_verification' => 'Email verification',
  'signin_alert' => 'Sign-in alert',
  'password_changed' => 'Password changed',
  _ => kind,
};

String approvalActionLabel(String action) => switch (action) {
  'lifecycle.suspend' => 'Suspend company',
  'lifecycle.cancel' => 'Cancel company',
  'lifecycle.reactivate' => 'Reactivate company',
  'billing_email.change' => 'Change billing email',
  'invoice.extension' => 'Extend an invoice',
  'invoice.credit_note' => 'Issue a credit note',
  'payment.void' => 'Void a payment',
  'package.price' => 'Change a package price',
  'plan.override' => 'Add a package override',
  'quote.price' => 'Set a quoted price',
  _ => action,
};

const Map<String, String> _operationWords = <String, String>{
  'subscription.change': 'package change',
  'subscription.refresh': 'package refresh',
  'lifecycle.transition': 'status change',
  'directory.put': 'company record',
  'lifecycle.suspend': 'company suspension',
  'lifecycle.cancel': 'company cancellation',
  'lifecycle.reactivate': 'company reactivation',
  'lifecycle.expire': 'company expiry',
  'billing_email.change': 'billing email change',
  'invoice.extension': 'invoice extension',
  'invoice.credit_note': 'credit note',
  'payment.void': 'payment void',
  'package.price': 'package price change',
  'plan.override': 'package override',
  'quote.price': 'quoted price',
  'plan.put': 'package save',
  'plan.retire': 'package retirement',
  'invitation.create': 'user invitation',
  'account.revoke': 'user access removal',
  'account.reactivate': 'user reactivation',
  'account.role': 'user role change',
  'account.remove': 'user removal',
  'account.move': 'salesperson move',
  'account.code': 'employee code change',
  'account.deletion_accept': 'account deletion acceptance',
  'account.deletion_cancel': 'account deletion cancellation',
  'account.deletion_shorten': 'account deletion shortening',
  'account.deletion_purge': 'final account deletion',
  'products.availability': 'product availability change',
  'products.delete': 'product deletion',
};

String _capitalised(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

String operationLabel(String key) =>
    _capitalised(_operationWords[key] ?? key.replaceAll(RegExp(r'[._]'), ' '));

final RegExp _operationKeys = RegExp(
  r'(?<![\w@.-])(' +
      _operationWords.keys.map(RegExp.escape).join('|') +
      r')(?![\w@-]|\.\w)',
);
final RegExp _stateMove = RegExp(r'moved from ([a-z_]+) to ([a-z_]+)');

String auditSummaryText(String summary) => summary
    .replaceAllMapped(
      _stateMove,
      (Match m) => 'moved from ${stateLabel(m[1])} to ${stateLabel(m[2])}',
    )
    .replaceAllMapped(_operationKeys, (Match m) {
      final String words = _operationWords[m[1]]!;
      return m.start == 0 ? _capitalised(words) : words;
    });

String approvalTitle(StaffApproval approval) {
  final Object? amount = approval.params['amountMinor'];
  return approval.summary.isNotEmpty
      ? '${approval.summary}${amount is int ? ' ${money(amount)}' : ''}'
      : approvalActionLabel(approval.action);
}
