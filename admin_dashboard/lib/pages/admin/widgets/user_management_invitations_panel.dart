import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:flutter/services.dart';
import 'package:qr_flutter/qr_flutter.dart';

import '../../../app/workspace_runtime.dart';
import '../../../services/platform_api_client.dart';
import '../../../utils/user_management_utils.dart';
import '../../../widgets/confirm_destructive_dialog.dart';

String formatLocalTime(DateTime? time) {
  if (time == null) return '-';
  final DateTime local = time.toLocal();
  String two(int value) => value.toString().padLeft(2, '0');
  return '${local.year}-${two(local.month)}-${two(local.day)} '
      '${two(local.hour)}:${two(local.minute)}';
}

class InvitationCreatedDialog extends StatelessWidget {
  const InvitationCreatedDialog({
    super.key,
    required this.invitation,
    required this.personName,
  });

  final CreatedInvitation invitation;
  final String personName;

  @override
  Widget build(BuildContext context) {
    final ThemeData theme = Theme.of(context);
    final TextStyle? caption = theme.textTheme.bodySmall?.copyWith(
      color: theme.colorScheme.onSurfaceVariant,
    );
    return AlertDialog(
      title: const Text('Invitation created'),
      content: SizedBox(
        width: 420,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                'Give this code to $personName. It works once. It is shown '
                'only now, so copy it before you close this window.',
              ),
              const SizedBox(height: 16),
              Text('Invitation code', style: caption),
              Row(
                children: <Widget>[
                  Expanded(
                    child: Semantics(
                      label: 'Invitation code ${invitation.displayCode}',
                      excludeSemantics: true,
                      child: SelectableText(
                        invitation.displayCode,
                        style: theme.textTheme.headlineSmall?.copyWith(
                          fontFamily: 'monospace',
                          fontWeight: FontWeight.w700,
                          letterSpacing: 1.5,
                        ),
                      ),
                    ),
                  ),
                  IconButton(
                    tooltip: 'Copy code',
                    icon: const Icon(ScootIcons.document),
                    onPressed: () async {
                      await Clipboard.setData(
                        ClipboardData(text: invitation.displayCode),
                      );
                      if (!context.mounted) return;
                      ScaffoldMessenger.of(context).showSnackBar(
                        const SnackBar(content: Text('Code copied.')),
                      );
                    },
                  ),
                ],
              ),
              const SizedBox(height: 12),
              Text('Sign-in ID', style: caption),
              Semantics(
                label: 'Sign-in ID ${invitation.signInId}',
                excludeSemantics: true,
                child: SelectableText(invitation.signInId),
              ),
              const SizedBox(height: 12),
              Text('Expires', style: caption),
              Text(formatLocalTime(invitation.expiresAt)),
              const SizedBox(height: 12),
              Text('Second check', style: caption),
              Text(
                '${invitation.checkHint}. ${personName.isEmpty ? 'The person' : personName} '
                'enters it with the code.',
              ),
              const SizedBox(height: 16),
              Center(
                child: Semantics(
                  label: 'Invitation QR code',
                  image: true,
                  child: Container(
                    color: Colors.white,
                    padding: const EdgeInsets.all(8),
                    child: QrImageView(
                      data: invitation.qrPayload,
                      size: 180,
                      backgroundColor: Colors.white,
                    ),
                  ),
                ),
              ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        FilledButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Done'),
        ),
      ],
    );
  }
}

class UserManagementInvitationsPanel extends StatefulWidget {
  const UserManagementInvitationsPanel({
    super.key,
    this.client,
    this.onInviteAgain,
  });

  final PlatformApiClient? client;
  final void Function(InvitationRecord row)? onInviteAgain;

  @override
  State<UserManagementInvitationsPanel> createState() =>
      UserManagementInvitationsPanelState();
}

class UserManagementInvitationsPanelState
    extends State<UserManagementInvitationsPanel> {
  late final PlatformApiClient _api = widget.client ?? PlatformApiClient();
  final ExpansibleController _controller = ExpansibleController();
  List<InvitationRecord>? _rows;
  String? _error;
  bool _loading = false;
  final Set<String> _busy = <String>{};

  Future<void> refresh({bool expand = false}) async {
    if (expand && !_controller.isExpanded) _controller.expand();
    if (_loading) return;
    setState(() {
      _loading = true;
      _error = null;
    });
    try {
      final List<InvitationRecord> rows = await _api.listInvitations();
      if (!mounted) return;
      setState(() => _rows = rows);
    } on PlatformApiException catch (error) {
      if (!mounted) return;
      setState(() => _error = error.message);
    } finally {
      if (mounted) setState(() => _loading = false);
    }
  }

  void _toast(String message, {bool isError = false}) {
    if (!mounted) return;
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    messenger.hideCurrentSnackBar();
    messenger.showSnackBar(
      SnackBar(
        content: Text(message),
        backgroundColor: isError
            ? Theme.of(context).colorScheme.errorContainer
            : null,
      ),
    );
  }

  Future<void> _run(
    InvitationRecord row,
    Future<void> Function() action,
    String done,
  ) async {
    setState(() => _busy.add(row.invitationId));
    try {
      await action();
      _toast(done);
    } on PlatformApiException catch (error) {
      _toast(error.message, isError: true);
    } finally {
      if (mounted) setState(() => _busy.remove(row.invitationId));
    }
    await refresh();
  }

  Future<void> _revokeCode(InvitationRecord row) => _run(
    row,
    () => _api.revokeInvitation(row.invitationId),
    'The code for ${row.displayName} was revoked.',
  );

  void _inviteAgain(InvitationRecord row) => widget.onInviteAgain?.call(row);

  Future<void> _revokeAccount(InvitationRecord row) async {
    final bool confirmed = await confirmDestructive(
      context,
      title: 'Revoke this account?',
      message:
          '${row.displayName} (${row.signInId}) will be signed out and '
          'blocked from signing in again. Their records are kept.',
      confirmLabel: 'Revoke account',
    );
    if (!confirmed || !mounted) return;
    await _run(
      row,
      () => _api.revokeAccount(row.uid),
      'The account of ${row.displayName} was revoked.',
    );
  }

  @override
  Widget build(BuildContext context) {
    if (WorkspaceRuntime.current == null) return const SizedBox.shrink();
    final List<InvitationRecord>? rows = _rows;
    return Card(
      margin: EdgeInsets.zero,
      clipBehavior: Clip.antiAlias,
      child: ExpansionTile(
        controller: _controller,
        shape: const Border(),
        collapsedShape: const Border(),
        leading: const Icon(ScootIcons.inbox),
        title: const Text('Invitations'),
        subtitle: Text(
          rows == null
              ? 'Open this list to see who has used their code.'
              : '${rows.length} invitation${rows.length == 1 ? '' : 's'}',
        ),
        onExpansionChanged: (bool open) {
          if (open && _rows == null && !_loading) refresh();
        },
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.symmetric(horizontal: 16),
            child: Align(
              alignment: Alignment.centerRight,
              child: OutlinedButton.icon(
                onPressed: _loading ? null : refresh,
                icon: _loading
                    ? const SizedBox.square(
                        dimension: 16,
                        child: CircularProgressIndicator(strokeWidth: 2),
                      )
                    : const Icon(ScootIcons.refresh, size: 18),
                label: Text(_loading ? 'Loading...' : 'Refresh'),
              ),
            ),
          ),
          if (_error != null)
            Padding(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 16),
              child: Semantics(
                liveRegion: true,
                child: Text(
                  _error!,
                  style: TextStyle(color: Theme.of(context).colorScheme.error),
                ),
              ),
            ),
          if (rows != null && rows.isEmpty)
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text('No invitations yet.'),
            ),
          if (rows != null && rows.isNotEmpty)
            ConstrainedBox(
              constraints: const BoxConstraints(maxHeight: 320),
              child: ListView.separated(
                shrinkWrap: true,
                padding: const EdgeInsets.all(16),
                itemCount: rows.length,
                separatorBuilder: (_, _) => const SizedBox(height: 8),
                itemBuilder: (BuildContext context, int index) =>
                    _row(context, rows[index]),
              ),
            ),
        ],
      ),
    );
  }

  Widget _row(BuildContext context, InvitationRecord row) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    final TextStyle? small = Theme.of(
      context,
    ).textTheme.bodySmall?.copyWith(color: scheme.onSurfaceVariant);
    final bool busy = _busy.contains(row.invitationId);
    final bool codeRevocable = row.status == 'open' || row.status == 'locked';
    final bool accountRevocable = row.status == 'redeemed';
    final bool canInviteAgain =
        row.status == 'expired' && widget.onInviteAgain != null;
    final String roleLabel = UserManagementUtils.roleLabel(row.role);
    return Semantics(
      container: true,
      identifier: 'invitation-${row.invitationId}',
      child: Container(
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          border: Border.all(color: scheme.outlineVariant),
          borderRadius: BorderRadius.circular(12),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Row(
              children: <Widget>[
                Expanded(
                  child: Text(
                    '${row.displayName} · $roleLabel',
                    style: const TextStyle(fontWeight: FontWeight.w700),
                  ),
                ),
                Chip(
                  label: Text(_statusLabel(row.status)),
                  visualDensity: VisualDensity.compact,
                ),
              ],
            ),
            Text(row.signInId, style: small),
            Text('Created ${formatLocalTime(row.createdAt)}', style: small),
            if (row.status == 'open')
              Text('Expires ${formatLocalTime(row.expiresAt)}', style: small),
            if (row.status == 'redeemed')
              Text(
                'Redeemed at ${formatLocalTime(row.redeemedAt)} on '
                '${row.redeemedDevice.isEmpty ? 'an unknown device' : row.redeemedDevice}',
                style: small,
              ),
            if (row.failures > 0)
              Text(
                '${row.failures} wrong second check${row.failures == 1 ? '' : 's'}',
                style: small?.copyWith(color: scheme.error),
              ),
            if (codeRevocable || accountRevocable || canInviteAgain) ...<Widget>[
              const SizedBox(height: 8),
              Wrap(
                spacing: 8,
                children: <Widget>[
                  if (codeRevocable)
                    OutlinedButton(
                      onPressed: busy ? null : () => _revokeCode(row),
                      child: const Text('Revoke code'),
                    ),
                  if (canInviteAgain)
                    FilledButton.tonal(
                      onPressed: busy ? null : () => _inviteAgain(row),
                      child: const Text('Invite again'),
                    ),
                  if (accountRevocable)
                    OutlinedButton(
                      onPressed: busy ? null : () => _revokeAccount(row),
                      child: const Text('Revoke account'),
                    ),
                ],
              ),
            ],
          ],
        ),
      ),
    );
  }

  String _statusLabel(String status) => switch (status) {
    'open' => 'Open',
    'redeemed' => 'Redeemed',
    'locked' => 'Locked',
    'expired' => 'Expired',
    'revoked' => 'Revoked',
    _ => status,
  };
}
