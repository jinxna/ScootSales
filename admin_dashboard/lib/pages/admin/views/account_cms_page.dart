import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:uuid/uuid.dart';

import '../../../services/binary_downloader.dart';
import '../../../services/platform_api_client.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/invoice_format.dart';
import '../widgets/cms_panel.dart';

class AccountCmsPage extends StatefulWidget {
  const AccountCmsPage({super.key, this.client, this.onChangePlan});

  final VoidCallback? onChangePlan;

  final PlatformApiClient? client;

  @override
  State<AccountCmsPage> createState() => _AccountCmsPageState();
}

class _AccountCmsPageState extends State<AccountCmsPage> {
  late final PlatformApiClient _api = widget.client ?? PlatformApiClient();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _supportEmail = TextEditingController();
  final TextEditingController _supportReason = TextEditingController();
  AccountSummary? _account;
  String _message = '';
  bool _busy = false;
  bool _exporting = false;
  bool _supportBusy = false;
  SupportGrant? _supportGrant;
  String? _supportKey;

  @override
  void dispose() {
    _password.dispose();
    _supportEmail.dispose();
    _supportReason.dispose();
    super.dispose();
  }

  bool _hasProvider(String providerId) =>
      FirebaseAuth.instance.currentUser?.providerData.any(
        (UserInfo info) => info.providerId == providerId,
      ) ??
      false;

  Future<void> _open() async {
    final String password = _password.text;
    if (password.isEmpty) {
      setState(() => _message = 'Enter your password.');
      return;
    }
    final String email = FirebaseAuth.instance.currentUser?.email ?? '';
    await _confirm(
      (User user) => user.reauthenticateWithCredential(
        EmailAuthProvider.credential(email: email, password: password),
      ),
      requiresEmail: true,
    );
  }

  Future<void> _openWithGoogle() => _confirm(
    (User user) => user.reauthenticateWithPopup(GoogleAuthProvider()),
  );

  Future<void> _confirm(
    Future<UserCredential> Function(User user) reauthenticate, {
    bool requiresEmail = false,
  }) async {
    if (_busy) return;
    final User? user = FirebaseAuth.instance.currentUser;
    final String email = user?.email ?? '';
    if (user == null || (requiresEmail && email.isEmpty)) {
      setState(() => _message = 'Sign in again to open this page.');
      return;
    }
    setState(() {
      _busy = true;
      _message = '';
    });
    try {
      await reauthenticate(user);
      await user.getIdToken(true);
      final AccountSummary account = await _api.getAccount();
      if (!mounted) return;
      setState(() {
        _account = account;
        _password.clear();
      });
    } on FirebaseAuthException catch (error) {
      if (!mounted) return;
      setState(() {
        _message =
            error.code == 'popup-closed-by-user' ||
                error.code == 'cancelled-popup-request'
            ? 'Google sign-in was closed. Try again.'
            : error.code == 'too-many-requests' ||
                  error.code == 'network-request-failed'
            ? 'Could not check your sign-in now. Try again in a moment.'
            : requiresEmail
            ? 'That password is not right.'
            : 'Google could not confirm this account. Try again.';
      });
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _account = null;
        _message = error.code == 'reauth_required'
            ? 'Confirm your sign-in again.'
            : error.message;
      });
    } catch (_) {
      if (!mounted) return;
      setState(() => _message = 'Could not open the account page. Try again.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _lock() => setState(() {
    _account = null;
    _message = '';
  });

  Future<void> _export() async {
    if (_exporting) return;
    setState(() {
      _exporting = true;
      _message = '';
    });
    try {
      final TenantExportPackage package = await _api.createTenantExport();
      final bool started = downloadBinary(
        filename: package.filename,
        bytes: package.bytes,
        contentType: 'application/zip',
      );
      if (!mounted) return;
      setState(() {
        _message = started
            ? 'The tenant export download started.'
            : 'This device cannot download the export.';
      });
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _exporting = false);
    }
  }

  Future<void> _grantSupport() async {
    if (_supportBusy) return;
    final String email = _supportEmail.text.trim();
    final String reason = _supportReason.text.trim();
    if (email.isEmpty || reason.length < 3) {
      setState(() => _message = 'Enter the support email and a clear reason.');
      return;
    }
    final String key = _supportKey ?? const Uuid().v4();
    _supportKey = key;
    setState(() {
      _supportBusy = true;
      _message = '';
    });
    try {
      final SupportGrant grant = await _api.createSupportGrant(
        staffEmail: email,
        reason: reason,
        expiresAt: DateTime.now().toUtc().add(const Duration(minutes: 45)),
        idempotencyKey: key,
      );
      if (!mounted) return;
      setState(() {
        _supportGrant = grant;
        _supportKey = null;
        _message =
            'Diagnostics access is active for 45 minutes or until revoked.';
      });
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _supportBusy = false);
    }
  }

  Future<void> _revokeSupport() async {
    final SupportGrant? grant = _supportGrant;
    if (_supportBusy || grant == null) return;
    final String key = _supportKey ?? const Uuid().v4();
    _supportKey = key;
    setState(() => _supportBusy = true);
    try {
      final SupportGrant revoked = await _api.revokeSupportGrant(
        grant,
        reason: 'Client administrator ended diagnostics access',
        idempotencyKey: key,
      );
      if (!mounted) return;
      setState(() {
        _supportGrant = revoked;
        _supportKey = null;
        _message = 'Diagnostics access was revoked.';
      });
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() => _message = error.message);
    } finally {
      if (mounted) setState(() => _supportBusy = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final AccountSummary? account = _account;
    return SingleChildScrollView(
      child: Align(
        alignment: Alignment.topLeft,
        child: !_api.isConnected || account == null
            ? ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 720),
                child: !_api.isConnected
                    ? _notConnectedPanel()
                    : _passwordPanel(),
              )
            : _details(account),
      ),
    );
  }

  Widget _notConnectedPanel() {
    return CmsPanel(
      title: 'Account',
      expandBody: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Text(
          'Your plan, renewal date and usage come from the Scoot Sales '
          'platform service. This dashboard is not connected to it, so they '
          'cannot be shown here.',
          style: TextStyle(color: context.dso.body),
        ),
      ),
    );
  }

  Widget _passwordPanel() {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final bool google = _hasProvider('google.com');
    final bool password = _hasProvider('password') || !google;
    return CmsPanel(
      title: 'Account',
      expandBody: false,
      child: Padding(
        padding: const EdgeInsets.fromLTRB(18, 0, 18, 18),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              password
                  ? 'Enter your password to see your plan and usage.'
                  : 'Confirm with Google to see your plan and usage.',
              style: TextStyle(color: context.dso.body),
            ),
            if (password) ...<Widget>[
              const SizedBox(height: 14),
              TextField(
                controller: _password,
                obscureText: true,
                autofillHints: const <String>[AutofillHints.password],
                enabled: !_busy,
                onSubmitted: (_) => _open(),
                decoration: InputDecoration(
                  labelText: 'Password',
                  isDense: true,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(12),
                  ),
                ),
              ),
            ],
            if (_message.isNotEmpty) ...<Widget>[
              const SizedBox(height: 10),
              Semantics(
                liveRegion: true,
                child: Text(_message, style: TextStyle(color: scheme.error)),
              ),
            ],
            const SizedBox(height: 14),
            Wrap(
              spacing: 10,
              runSpacing: 10,
              children: <Widget>[
                if (password)
                  Semantics(
                    button: true,
                    label: 'Open the account page',
                    child: FilledButton(
                      onPressed: _busy ? null : _open,
                      child: _busy
                          ? const SizedBox.square(
                              dimension: 18,
                              child: CircularProgressIndicator(strokeWidth: 2),
                            )
                          : const Text('Open account'),
                    ),
                  ),
                if (google)
                  password
                      ? OutlinedButton(
                          onPressed: _busy ? null : _openWithGoogle,
                          child: const Text('Confirm with Google'),
                        )
                      : FilledButton(
                          onPressed: _busy ? null : _openWithGoogle,
                          child: const Text('Confirm with Google'),
                        ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  Widget _details(AccountSummary account) {
    final Widget plan = ScootCard(
      title: 'Plan',
      trailing: Wrap(
        spacing: 8,
        children: <Widget>[
          if (widget.onChangePlan != null)
            OutlinedButton(
              onPressed: widget.onChangePlan,
              child: const Text('Change plan'),
            ),
          OutlinedButton.icon(
            onPressed: _lock,
            icon: const Icon(ScootIcons.lock, size: 16),
            label: const Text('Lock'),
          ),
        ],
      ),
      child: _planRows(account),
    );
    final Widget usage = ScootCard(
      title: 'Usage',
      child: Wrap(
        spacing: 12,
        runSpacing: 12,
        children: <Widget>[
          for (final AccountPool pool in account.pools)
            _usageTile(pool.label, pool, account.planName),
        ],
      ),
    );
    final Widget billing = ScootCard(
      title: 'Billing and export',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            account.invoiceCount == 0
                ? 'Invoices: none yet'
                : 'Invoices: ${account.invoiceCount}',
            style: TextStyle(color: context.dso.body),
          ),
          for (final AccountInvoice invoice in account.invoices)
            _invoiceRow(invoice),
          const SizedBox(height: 6),
          Text(
            account.exportAvailable
                ? 'Export: available'
                : 'Export: not enabled for this workspace',
            style: TextStyle(color: context.dso.body),
          ),
          if (account.exportAvailable) ...<Widget>[
            const SizedBox(height: 12),
            OutlinedButton.icon(
              onPressed: _exporting ? null : _export,
              icon: _exporting
                  ? const SizedBox.square(
                      dimension: 16,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(ScootIcons.download, size: 18),
              label: const Text('Download tenant export'),
            ),
          ],
          if (_message.isNotEmpty) ...<Widget>[
            const SizedBox(height: 10),
            Text(_message, style: TextStyle(color: context.dso.body)),
          ],
        ],
      ),
    );
    final bool granted = _supportGrant?.status == 'active';
    final Widget support = ScootCard(
      title: 'Support access',
      trailing: ScootBadge(
        label: granted ? 'On' : 'Off',
        tone: granted ? ScootTone.success : ScootTone.neutral,
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Grant temporary diagnostics access. Support cannot open orders, products, or reports.',
            style: TextStyle(color: context.dso.body),
          ),
          const SizedBox(height: 12),
          if (granted) ...<Widget>[
            Text(
              '${_supportGrant!.staffEmail} · expires ${_dateTime(_supportGrant!.expiresAt)}',
            ),
            const SizedBox(height: 10),
            OutlinedButton(
              onPressed: _supportBusy ? null : _revokeSupport,
              child: const Text('Revoke support access'),
            ),
          ] else ...<Widget>[
            TextField(
              controller: _supportEmail,
              enabled: !_supportBusy,
              decoration: const InputDecoration(
                labelText: 'Support staff email',
              ),
            ),
            const SizedBox(height: 10),
            TextField(
              controller: _supportReason,
              enabled: !_supportBusy,
              maxLength: 500,
              decoration: const InputDecoration(labelText: 'Reason'),
            ),
            FilledButton(
              onPressed: _supportBusy ? null : _grantSupport,
              child: const Text('Grant 45-minute diagnostics access'),
            ),
          ],
        ],
      ),
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        const SizedBox gap = SizedBox(height: ScootSpace.blockGap);
        if (box.maxWidth < 1000) {
          return Column(
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[plan, gap, usage, gap, billing, gap, support],
          );
        }
        return Row(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Expanded(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[plan, gap, usage, gap, billing],
              ),
            ),
            const SizedBox(width: ScootSpace.blockGap),
            SizedBox(width: 400, child: support),
          ],
        );
      },
    );
  }

  Widget _planRows(AccountSummary account) {
    final DateTime? renews = account.renewsAt;
    final DateTime? trialEnds = account.trialEndsAt;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        _fact(
          'Plan',
          account.planName.isEmpty ? account.planId : account.planName,
        ),
        _fact('Status', _statusLabel(account.status)),
        if (trialEnds != null) _fact('Trial ends', _date(trialEnds)),
        if (renews != null) _fact('Renews', _date(renews)),
      ],
    );
  }

  Widget _fact(String label, String value) => Padding(
    padding: const EdgeInsets.only(bottom: 8),
    child: Semantics(
      container: true,
      label: '$label: $value',
      excludeSemantics: true,
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          SizedBox(
            width: 110,
            child: Text(label, style: TextStyle(color: context.dso.muted)),
          ),
          Expanded(
            child: Text(
              value,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
          ),
        ],
      ),
    ),
  );

  Widget _usageTile(String label, AccountPool pool, String planName) {
    final ScootColors c = ScootColors.of(context);
    final int? limit = pool.limit;
    final String amount = limit == null
        ? '${pool.used} used · No limit'
        : '${pool.used} of $limit';
    final double fraction = limit == null || limit <= 0
        ? 0
        : (pool.used / limit).clamp(0, 1).toDouble();
    final bool full = limit != null && pool.used >= limit;
    return Semantics(
      container: true,
      label: '$label: $amount',
      excludeSemantics: true,
      child: Container(
        width: 150,
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: c.card,
          border: Border.all(color: c.line),
          borderRadius: ScootRadius.noteAll,
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(label, style: ScootType.small.copyWith(color: c.muted)),
            const SizedBox(height: 6),
            Text(
              limit == null ? '${pool.used}' : '${pool.used} of $limit',
              style: ScootType.kpi.copyWith(color: c.ink),
            ),
            const SizedBox(height: 4),
            if (limit == null)
              Text(
                planName.isEmpty
                    ? 'used · No limit'
                    : 'used · No limit on $planName',
                style: ScootType.caption.copyWith(color: c.muted),
              )
            else
              ClipRRect(
                borderRadius: BorderRadius.circular(6),
                child: LinearProgressIndicator(
                  value: fraction,
                  minHeight: 8,
                  color: full ? c.tone(ScootTone.danger).foreground : c.brand,
                  backgroundColor: c.hair,
                ),
              ),
          ],
        ),
      ),
    );
  }

  Widget _invoiceRow(AccountInvoice invoice) {
    final DsoColors dso = context.dso;
    final String period =
        invoice.periodStart == null || invoice.periodEnd == null
        ? ''
        : '${_date(invoice.periodStart!)} to ${_date(invoice.periodEnd!)}';
    final String due = invoice.dueAt == null
        ? ''
        : 'Due ${_date(invoice.dueAt!)}';
    final String details = <String>[
      invoice.packageName,
      period,
      due,
    ].where((String part) => part.isNotEmpty).join(' · ');
    return Padding(
      padding: const EdgeInsets.only(top: 10),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(ScootIcons.document, size: 18, color: dso.muted),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  '${invoice.number} · ${invoiceStatusLabel(invoice.status)}',
                  style: TextStyle(
                    fontWeight: FontWeight.w700,
                    color: dso.body,
                  ),
                ),
                if (details.isNotEmpty)
                  Text(details, style: TextStyle(color: dso.muted)),
                if (invoice.note.isNotEmpty)
                  Text(invoice.note, style: TextStyle(color: dso.muted)),
              ],
            ),
          ),
          const SizedBox(width: 10),
          Column(
            crossAxisAlignment: CrossAxisAlignment.end,
            children: <Widget>[
              Text(
                formatMinor(invoice.amountMinor, invoice.currency),
                style: TextStyle(fontWeight: FontWeight.w700, color: dso.body),
              ),
              if (invoice.outstandingMinor > 0)
                Text(
                  '${formatMinor(invoice.outstandingMinor, invoice.currency)} outstanding',
                  style: TextStyle(color: dso.muted),
                ),
            ],
          ),
        ],
      ),
    );
  }

  static String _statusLabel(String status) => switch (status) {
    'active' => 'Active',
    'past_due' => 'Payment overdue',
    'suspended' => 'Suspended',
    'expired' => 'Expired',
    'cancelled' => 'Cancelled',
    '' => 'Unknown',
    _ => status,
  };

  static String _date(DateTime value) {
    const List<String> months = <String>[
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
    final DateTime local = value.toLocal();
    return '${local.day} ${months[local.month - 1]} ${local.year}';
  }

  static String _dateTime(DateTime? value) {
    if (value == null) return 'unknown time';
    final DateTime local = value.toLocal();
    return '${_date(local)} ${local.hour.toString().padLeft(2, '0')}:${local.minute.toString().padLeft(2, '0')}';
  }
}
