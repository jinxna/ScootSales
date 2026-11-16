import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';
import '../widgets/connect_project.dart';
import '../widgets/draft_fields.dart';
import '../widgets/package_change.dart';
import '../widgets/payment_actions.dart';
import '../widgets/people_fixes.dart';
import '../widgets/prepare_data.dart';
import '../widgets/record_payment_panel.dart';

class OnboardingPage extends StatefulWidget {
  const OnboardingPage({
    super.key,
    required this.store,
    required this.nav,
    this.draftId,
  });

  final CcStore store;
  final CcNav nav;
  final String? draftId;

  @override
  State<OnboardingPage> createState() => _OnboardingPageState();
}

class _OnboardingPageState extends State<OnboardingPage> {
  int _tab = 0;
  bool _busy = false;

  CcStore get _store => widget.store;
  StaffApiClient get _api => _store.api;
  StaffProfile get _me => _store.profile!;

  @override
  void initState() {
    super.initState();
    _store.refreshDrafts();
    _store.refreshCompanies(force: false);
  }

  Future<void> _reloadAll() => Future.wait<void>(<Future<void>>[
    _store.refreshDrafts(),
    _store.refreshCompanies(),
  ]);

  Future<void> _act(Future<Object?> Function() call, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    String? failure;
    try {
      await call();
    } on StaffApiException catch (error) {
      failure = friendlyError(error);
    } catch (_) {
      failure = uncertainMessage;
    }
    await _reloadAll();
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, failure ?? done);
  }

  Future<StaffCompany?> _company(StaffOnboardingDraft draft) async {
    final String? tenant = draft.tenantId;
    if (tenant == null) return null;
    StaffCompany? find() => (_store.companies?.value ?? const <StaffCompany>[])
        .where((StaffCompany c) => c.tenantId == tenant)
        .firstOrNull;
    StaffCompany? company = find();
    if (company == null) {
      await _store.refreshCompanies();
      company = find();
    }
    if (company == null && mounted) {
      announce(
        context,
        'The company record is not in the list yet. Try again.',
      );
    }
    return company;
  }

  Future<void> _edit(StaffOnboardingDraft shown) async {
    final (Loaded<List<StaffPackage>> catalogue, _) = await (
      Loaded.of(_api.packages()),
      _store.refreshDrafts(),
    ).wait;
    if (!mounted) return;
    final StaffOnboardingDraft? current =
        (_store.drafts?.value ?? const <StaffOnboardingDraft>[])
            .where((StaffOnboardingDraft d) => d.draftId == shown.draftId)
            .firstOrNull;
    if (current == null) {
      announce(context, 'That draft is not in the list. Try again.');
      return;
    }
    final StaffOnboardingDraft draft = current;
    if (catalogue.value == null) {
      announce(context, catalogue.error!);
      return;
    }
    final GlobalKey<DraftFormFieldsState> fields =
        GlobalKey<DraftFormFieldsState>();
    await showCcCommand(
      context,
      title: 'Edit details',
      confirmLabel: 'Save changes',
      reasonLabel: null,
      body: DraftFormFields(
        key: fields,
        packages: catalogue.value!,
        initial: draft,
        adminOnly: draft.tenantId != null,
      ),
      run: (String reason, String key) async {
        if (!fields.currentState!.validate()) {
          return const CmdResult.fail('Check the fields marked in red.');
        }
        return CmdResult.run(
          () => _api.updateOnboardingDraft(
            draft.draftId,
            fields.currentState!.body(),
          ),
          done: 'The details were saved.',
        );
      },
    );
    await _store.refreshDrafts();
  }

  Future<void> _connect(StaffOnboardingDraft draft) async {
    final String? known = (_store.companies?.value ?? const <StaffCompany>[])
        .where((StaffCompany c) => c.tenantId == draft.tenantId)
        .firstOrNull
        ?.projectId;
    await showConnectProject(context, _api, draft, knownProjectId: known);
    await _reloadAll();
  }

  Future<void> _people(StaffOnboardingDraft draft) async {
    await showPeopleFixes(context, _api, draft.tenantId!, draft.legalName);
    await _reloadAll();
  }

  Future<void> _prepare(StaffOnboardingDraft draft) async {
    await showPrepareData(context, _api, draft.tenantId!, draft.legalName);
    await _reloadAll();
  }

  Future<void> _resumePrepare(StaffOnboardingDraft draft) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Resume preparation',
      message:
          'Scoot finishes the preparation that stopped half way. It does not remove or add any person.',
      confirmLabel: 'Resume preparation',
    );
    if (!ok || !mounted) return;
    await _act(
      () => _api.prepareData(draft.tenantId!, apply: false, resume: true),
      'Preparation is finished.',
    );
  }

  Future<void> _package(StaffOnboardingDraft draft) async {
    final StaffCompany? company = await _company(draft);
    if (company == null || !mounted) return;
    final Loaded<StaffCompanyPackages> packages = await Loaded.of(
      _api.companyPackages(company.tenantId),
    );
    if (!mounted) return;
    if (packages.value == null) {
      announce(context, packages.error!);
      return;
    }
    await showPackageChange(
      context,
      _api,
      company,
      packages.value!,
      planId: draft.planId,
      interval: draft.billingInterval,
      onPrepare: _me.isOwner ? () => _prepare(draft) : null,
      onFinished: _reloadAll,
    );
    await _reloadAll();
  }

  Future<void> _finishPackage(StaffOnboardingDraft draft) async {
    final String? operationId = draft.nextStep?.operationId;
    if (operationId == null) return _package(draft);
    if (_busy) return;
    setState(() => _busy = true);
    final String message = await finishPackageMessage(_api, operationId);
    await _reloadAll();
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, message);
  }

  Future<void> _createInvoice(StaffOnboardingDraft draft) async {
    final String tenant = draft.tenantId!;
    await showCcCommand(
      context,
      title: 'Create first invoice',
      confirmLabel: 'Create invoice',
      reasonLabel: null,
      body: const Text(
        'Scoot makes the first invoice from the package price. A second press returns the same invoice.',
      ),
      run: (String reason, String key) => CmdResult.run(
        () => _api.createInvoiceDraft(tenant, <String, Object?>{}, key: key),
        done: 'The invoice was created.',
        fixFor: (StaffApiException error) => switch (error.fix) {
          'choose_package' => CmdFix('Choose a package', () => _package(draft)),
          'set_price' => CmdFix(
            'Open Packages to set the price',
            () => widget.nav.go(CcSection.packages),
          ),
          _ => null,
        },
      ),
    );
    _store.invalidateInvoices();
    await _reloadAll();
  }

  Future<void> _issueInvoice(StaffOnboardingDraft draft) async {
    final Loaded<List<StaffInvoice>> invoices = await Loaded.of(
      _api.invoices(tenantId: draft.tenantId),
    );
    if (!mounted) return;
    final StaffInvoice? first = invoices.value
        ?.where((StaffInvoice i) => i.status == 'draft')
        .firstOrNull;
    if (first == null) {
      announce(
        context,
        invoices.error ?? 'No draft invoice was found for this company.',
      );
      return;
    }
    final bool ok = await showCcConfirm(
      context,
      title: 'Issue invoice',
      message:
          'Scoot issues the draft invoice for ${first.packageName}. It gets a number and can no longer be edited.',
      confirmLabel: 'Issue invoice',
    );
    if (!ok || !mounted) return;
    _store.invalidateInvoices();
    await _act(
      () => _api.issueInvoice(first.invoiceId),
      'The invoice was issued.',
    );
  }

  Future<void> _recordPayment(StaffOnboardingDraft draft) async {
    final StaffCompany? company = await _company(draft);
    if (company == null || !mounted) return;
    final Loaded<List<StaffInvoice>> invoices = await Loaded.of(
      _api.invoices(tenantId: company.tenantId),
    );
    if (!mounted) return;
    if (invoices.value == null) {
      announce(context, invoices.error!);
      return;
    }
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialog) => Dialog(
        child: SizedBox(
          width: 560,
          child: SingleChildScrollView(
            child: RecordPaymentPanel(
              api: _api,
              company: company,
              invoices: invoices.value!,
              onDone: () => Navigator.of(dialog).pop(),
              onCancel: () => Navigator.of(dialog).pop(),
              onOpenInvoices: () {
                Navigator.of(dialog).pop();
                widget.nav.go(CcSection.invoices);
              },
            ),
          ),
        ),
      ),
    );
    await _store.refreshToCheck();
    await _reloadAll();
  }

  Future<void> _checkPayment(StaffOnboardingDraft draft) async {
    final Loaded<List<StaffPaymentEntry>> waiting = await Loaded.of(
      _api.paymentsToCheck(),
    );
    if (!mounted) return;
    final List<StaffPaymentEntry> ours =
        waiting.value
            ?.where((StaffPaymentEntry e) => e.tenantId == draft.tenantId)
            .toList(growable: false) ??
        const <StaffPaymentEntry>[];
    final StaffPaymentEntry? entry = ours
        .where((StaffPaymentEntry e) => e.canCheck == true)
        .firstOrNull;
    if (entry == null) {
      announce(
        context,
        waiting.error ??
            (ours.isEmpty
                ? 'No payment is waiting to be checked for this company.'
                : 'Another person must check this payment. The person who recorded it cannot.'),
      );
      return;
    }
    await confirmPaymentCheck(context, _store, entry);
    await _reloadAll();
  }

  Future<void> _giveAccess(StaffOnboardingDraft draft) async {
    await showCcCommand(
      context,
      title: 'Give access',
      confirmLabel: 'Give access',
      reasonLabel: null,
      body: Text(
        'Scoot makes ${draft.adminName ?? 'this person'} (${maskEmail(draft.adminEmail ?? '')}) the first administrator. Sign-in id and password do not change.',
      ),
      run: (String reason, String key) => CmdResult.run(
        () => _api.giveFirstAdminAccess(draft.draftId),
        done: 'Access was given.',
        fixFor: (StaffApiException error) =>
            _me.isOwner && error.fix == 'promote_first_admin'
            ? CmdFix(
                'Make this person the administrator',
                () => _promote(draft),
              )
            : null,
      ),
    );
    await _reloadAll();
  }

  Future<void> _promote(StaffOnboardingDraft draft) async {
    final String code = draft.adminEmployeeCode ?? '';
    try {
      final Map<String, Object?> preview = await _api.promoteFirstAdmin(
        draft.draftId,
        code,
      );
      if (!mounted) return;
      final Object? line = preview['line'];
      final bool ok = await showCcConfirm(
        context,
        title: 'Make this person the administrator',
        message: line is String ? line : 'This changes one access record.',
        confirmLabel: 'Make administrator',
      );
      if (!ok || !mounted) return;
      final Object? row = preview['expectedRow'];
      await _api.promoteFirstAdmin(
        draft.draftId,
        code,
        expectedRow: row is Map
            ? row.map<String, Object?>(
                (Object? k, Object? v) => MapEntry<String, Object?>('$k', v),
              )
            : <String, Object?>{},
      );
      if (mounted) announce(context, 'The person is now the administrator.');
    } on StaffApiException catch (error) {
      if (mounted) announce(context, friendlyError(error));
    }
    await _reloadAll();
  }

  Future<void> _makeActive(StaffOnboardingDraft draft) async {
    final String tenant = draft.tenantId!;
    final Loaded<StaffPayments> payments = await Loaded.of(
      _api.payments(tenant),
    );
    final Loaded<StaffLifecycleResponse> lifecycle = await Loaded.of(
      _api.lifecycle(tenant),
    );
    if (!mounted) return;
    final String? paymentId =
        payments.value?.checkedCoveringEntryIds.firstOrNull;
    if (paymentId == null || lifecycle.value == null) {
      announce(
        context,
        payments.error ??
            lifecycle.error ??
            'No checked payment covers today. Finish step 5 first.',
      );
      return;
    }
    await showCcCommand(
      context,
      title: 'Make active',
      confirmLabel: 'Make active',
      reasonHint: 'Saved in the audit log',
      body: Text('${draft.legalName} opens for its people.'),
      run: (String reason, String key) => CmdResult.run(
        () => _api.transitionLifecycle(tenant, <String, Object?>{
          'state': 'active',
          'expectedRevision': lifecycle.value!.lifecycle?.revision ?? 0,
          'paymentEntryId': paymentId,
          'reason': reason,
          'ticket': null,
        }, key: key),
        done: 'The company is active.',
      ),
    );
    await _reloadAll();
  }

  Future<void> _press(StaffOnboardingDraft draft, StaffStepButton button) {
    switch (button.id) {
      case 'edit_details':
        return _edit(draft);
      case 'connect_project':
        return _connect(draft);
      case 'check_again':
        return _reloadAll();
      case 'fix_people':
        return _people(draft);
      case 'prepare':
        return _prepare(draft);
      case 'resume_prepare':
        return _resumePrepare(draft);
      case 'apply_package':
        return _package(draft);
      case 'finish_package':
        return _finishPackage(draft);
      case 'create_invoice':
        return _createInvoice(draft);
      case 'issue_invoice':
        return _issueInvoice(draft);
      case 'record_payment':
        return _recordPayment(draft);
      case 'check_payment':
        return _checkPayment(draft);
      case 'give_access':
        return _giveAccess(draft);
      case 'resend_invitation':
        return _act(
          () => _api.resendFirstAdminInvitation(draft.draftId),
          'The invitation was sent again.',
        );
      case 'make_active':
        return _makeActive(draft);
      default:
        return Future<void>.value();
    }
  }

  Future<void> _cancel(StaffOnboardingDraft draft) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Cancel this draft?',
      message:
          'The code ${codeText(draft.workspace)} is released. Nothing else was created.',
      confirmLabel: 'Cancel draft',
      danger: true,
    );
    if (!ok || !mounted) return;
    await _act(
      () => _api.cancelOnboardingDraft(draft.draftId),
      'The draft was cancelled.',
    );
    if (mounted) widget.nav.go(CcSection.onboarding);
  }

  String _checked(String? iso) {
    final DateTime? moment = parseMoment(iso);
    if (moment == null) return '';
    final DateTime local = moment.add(const Duration(hours: 8));
    String two(int n) => n.toString().padLeft(2, '0');
    return 'checked ${two(local.hour)}:${two(local.minute)}';
  }

  String _statusLabel(StaffOnboardingDraft draft) {
    final String? state = draft.lifecycleState;
    if (state == null) {
      return switch (draft.status) {
        'cancelled' => 'Cancelled',
        'expired' => 'Expired',
        _ => 'Lead',
      };
    }
    return state == 'lead' ? 'Lead' : stateLabel(state);
  }

  Tone _statusTone(StaffOnboardingDraft draft) {
    final String? state = draft.lifecycleState;
    if (state == null) {
      return draft.isEnded ? Tone.danger : Tone.warn;
    }
    return stateTone(state);
  }

  String _kindLabel(String? kind) => switch (kind) {
    'new' => 'New',
    'existing' => 'Existing',
    _ => 'Not connected yet',
  };

  bool _canPress(StaffStepButton button) => button.roles.contains(_me.role);

  String _waitingFor(StaffStepButton button) {
    final String who = button.roles.contains('owner')
        ? 'owner'
        : button.roles.isEmpty
        ? 'owner'
        : button.roles.first;
    return 'Waiting for the $who: ${button.label}.';
  }

  Widget _primary(StaffOnboardingDraft draft) {
    final StaffOnboardingStep? next = draft.nextStep;
    if (next == null) {
      return const CcBanner(
        bold: 'All steps are green.',
        text: 'This company is working.',
        tone: Tone.ok,
      );
    }
    final StaffStepButton? button = next.button;
    final bool allowed = button != null && _canPress(button);
    final bool available = button != null && button.id != 'install_rules';
    return CcCard(
      child: Wrap(
        spacing: 16,
        runSpacing: 10,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(minWidth: 220, maxWidth: 520),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Next: step ${next.n}, ${next.label}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w700,
                    color: Cc.ink,
                  ),
                ),
                if (button != null && !allowed)
                  Text(_waitingFor(button), style: Cc.small)
                else if (button != null && !available)
                  const Text('This step is not built yet.', style: Cc.small),
              ],
            ),
          ),
          if (button != null)
            FilledButton(
              onPressed: _busy || !allowed || !available
                  ? null
                  : () => _press(draft, button),
              child: Text(button.label),
            ),
        ],
      ),
    );
  }

  Widget _stepRow(StaffOnboardingStep step) {
    final (IconData icon, Color color, String word) = switch (step.state) {
      'green' => (Icons.check_circle, Cc.accent, 'Done'),
      'red' => (Icons.error, Cc.dangerFg, 'Needs work'),
      _ => (Icons.radio_button_unchecked, Cc.muted, 'Waiting'),
    };
    final String checked = _checked(step.checkedAt);
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 12),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, color: color, semanticLabel: word),
          const SizedBox(width: 14),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${step.n}. ${step.label}',
                  style: const TextStyle(
                    fontWeight: FontWeight.w600,
                    color: Cc.ink,
                  ),
                ),
                Text(
                  step.unknown && step.fact.isEmpty
                      ? 'Could not check.'
                      : step.fact,
                  style: TextStyle(
                    fontSize: 13,
                    color: step.isRed ? Cc.dangerFg : Cc.muted,
                  ),
                ),
                if (checked.isNotEmpty) Text(checked, style: Cc.small),
              ],
            ),
          ),
        ],
      ),
    );
  }

  Widget _checklist(StaffOnboardingDraft draft) {
    final List<Widget> rows = <Widget>[];
    for (final StaffOnboardingStep step in draft.steps) {
      if (rows.isNotEmpty) rows.add(const Divider(height: 1, color: Cc.line));
      rows.add(_stepRow(step));
    }
    return CcCard(
      title: 'Checklist',
      trailing: CcBadge(_statusLabel(draft), tone: _statusTone(draft)),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: rows,
      ),
    );
  }

  Widget _detailView(StaffOnboardingDraft draft) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      CcLink(
        '← Onboarding',
        semantic: 'Back to onboarding',
        onTap: () => widget.nav.go(CcSection.onboarding),
      ),
      const SizedBox(height: 8),
      CcPageHeader(
        draft.legalName,
        actions: <Widget>[
          CcBadge(_statusLabel(draft), tone: _statusTone(draft)),
          CcBadge(
            '${draft.doneCount} of ${draft.total} steps done',
            tone: Tone.neutral,
          ),
          if (draft.tenantId != null)
            OutlinedButton(
              onPressed: () => widget.nav.openCompany(draft.tenantId!),
              child: const Text('Open company'),
            ),
          if (draft.isOpen && draft.canExtend)
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _act(
                      () => _api.extendOnboardingDraft(draft.draftId),
                      'The draft was extended by 30 days.',
                    ),
              child: const Text('Extend 30 days'),
            ),
          if (draft.isSetup && _me.canManageAccounts)
            OutlinedButton(
              onPressed: _busy ? null : () => _edit(draft),
              child: const Text('Edit details'),
            ),
          if (draft.isOpen && draft.tenantId == null && _me.canManageAccounts)
            TextButton(
              onPressed: _busy ? null : () => _cancel(draft),
              child: const Text('Cancel draft'),
            ),
        ],
      ),
      CcCard(
        child: Wrap(
          spacing: 32,
          runSpacing: 8,
          children: <Widget>[
            Text('Code ${codeText(draft.workspace)}'),
            Text('Kind: ${_kindLabel(draft.kind)}'),
            Text('Started by ${draft.createdBy}'),
            if (draft.isOpen) Text('Draft ends ${dayText(draft.endsAt)}'),
          ],
        ),
      ),
      const SizedBox(height: 16),
      _primary(draft),
      const SizedBox(height: 16),
      _checklist(draft),
    ],
  );

  List<StaffOnboardingDraft> _inTab(List<StaffOnboardingDraft> all, int tab) =>
      all
          .where(
            (StaffOnboardingDraft d) => switch (tab) {
              0 => d.isSetup,
              1 => d.isWorking,
              _ => d.isEnded,
            },
          )
          .toList(growable: false);

  Widget _list(List<StaffOnboardingDraft> all) {
    final List<StaffOnboardingDraft> rows = _inTab(all, _tab);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        CcPageHeader(
          'Onboarding',
          actions: <Widget>[
            if (_me.canCreateCompany)
              FilledButton.icon(
                onPressed: () => widget.nav.go(CcSection.newCompany),
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Add company'),
              ),
          ],
        ),
        CcTabBar(
          labels: const <String>['Setting up', 'Working', 'Ended'],
          counts: <int?>[
            _inTab(all, 0).length,
            _inTab(all, 1).length,
            _inTab(all, 2).length,
          ],
          selected: _tab,
          onSelected: (int i) => setState(() => _tab = i),
        ),
        const SizedBox(height: 12),
        CcTable(
          columns: const <CcColumn>[
            CcColumn('Company', flex: 3),
            CcColumn('Steps', width: 130, hideBelow: 700),
            CcColumn('Next', flex: 3, hideBelow: 860),
            CcColumn('Status', width: 130, hideBelow: 700),
            CcColumn('Action', width: 160, right: true),
          ],
          rows: <CcTableRow>[
            for (final StaffOnboardingDraft draft in rows)
              CcTableRow(
                semanticLabel: 'Open checklist for ${draft.legalName}',
                onTap: () => widget.nav.openOnboarding(draft.draftId),
                cells: <Widget>[
                  Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        draft.legalName,
                        overflow: TextOverflow.ellipsis,
                        style: const TextStyle(
                          fontWeight: FontWeight.w700,
                          color: Cc.ink,
                        ),
                      ),
                      Text(
                        '${codeText(draft.workspace)} · ${_kindLabel(draft.kind)}',
                        style: Cc.small,
                      ),
                    ],
                  ),
                  Text(
                    '${draft.doneCount} of ${draft.total}',
                    style: Cc.numbers,
                  ),
                  Text(
                    draft.nextStep == null
                        ? 'Nothing left'
                        : 'Step ${draft.nextStep!.n}: ${draft.nextStep!.label}',
                    overflow: TextOverflow.ellipsis,
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: CcBadge(
                      _statusLabel(draft),
                      tone: _statusTone(draft),
                    ),
                  ),
                  OutlinedButton(
                    onPressed: () => widget.nav.openOnboarding(draft.draftId),
                    child: const Text('Open checklist'),
                  ),
                ],
              ),
          ],
          empty: CcEmptyState(
            title: switch (_tab) {
              0 => 'No company is being set up',
              1 => 'No company is working yet',
              _ => 'Nothing here',
            },
            message: switch (_tab) {
              0 => 'A new company appears here until all 8 steps are green.',
              1 => 'A company moves here when all 8 steps are green.',
              _ => 'Cancelled and expired drafts appear here.',
            },
            action: _tab == 0 && _me.canCreateCompany
                ? FilledButton(
                    onPressed: () => widget.nav.go(CcSection.newCompany),
                    child: const Text('Add company'),
                  )
                : null,
          ),
        ),
      ],
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (BuildContext context, Widget? _) {
      final Loaded<List<StaffOnboardingDraft>>? loaded = _store.drafts;
      Widget body;
      if (loaded == null) {
        body = const CcSkeleton();
      } else if (loaded.value == null) {
        body = CcErrorState(
          what: 'onboarding',
          message: loaded.error!,
          onRetry: _store.refreshDrafts,
        );
      } else if (widget.draftId != null) {
        final StaffOnboardingDraft? draft = loaded.value!
            .where((StaffOnboardingDraft d) => d.draftId == widget.draftId)
            .firstOrNull;
        body = draft == null
            ? CcEmptyState(
                title: 'That draft is not in the list',
                message: 'Go back to onboarding.',
                action: FilledButton(
                  onPressed: () => widget.nav.go(CcSection.onboarding),
                  child: const Text('Back to onboarding'),
                ),
              )
            : _detailView(draft);
      } else {
        body = _list(loaded.value!);
      }
      return CcPage(child: body);
    },
  );
}
