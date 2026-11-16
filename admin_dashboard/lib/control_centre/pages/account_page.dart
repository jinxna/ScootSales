import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:scoot_legal/scoot_legal.dart';

import '../../services/csv_downloader.dart';
import '../staff_api_client.dart';
import '../staff_auth.dart';
import '../store/cc_store.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_shell.dart';
import 'legal_page.dart';

class AccountPage extends StatefulWidget {
  const AccountPage({
    super.key,
    required this.store,
    required this.auth,
    required this.onSignOut,
  });

  final CcStore store;
  final StaffAuth auth;
  final VoidCallback onSignOut;

  @override
  State<AccountPage> createState() => _AccountPageState();
}

class _AccountPageState extends State<AccountPage> {
  Loaded<List<StaffSessionInfo>>? _sessions;
  Loaded<int>? _backups;
  String? _codesError;
  bool _busy = false;
  final TextEditingController _currentPassword = TextEditingController();
  final TextEditingController _newPassword = TextEditingController();
  final TextEditingController _confirmPassword = TextEditingController();
  String? _passwordError, _passwordDone;
  bool _changingPassword = false;

  CcStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _load();
  }

  @override
  void dispose() {
    _currentPassword.dispose();
    _newPassword.dispose();
    _confirmPassword.dispose();
    super.dispose();
  }

  String? _passwordProblem() {
    final String next = _newPassword.text;
    if (_currentPassword.text.isEmpty) return 'Enter your current password.';
    if (next.length < staffPasswordMin || next.length > staffPasswordMax) {
      return 'Use a new password of $staffPasswordMin to $staffPasswordMax characters.';
    }
    if (next != _confirmPassword.text) {
      return 'The two new passwords are not the same.';
    }
    if (next == _currentPassword.text) {
      return 'The new password must be different from the current password.';
    }
    return null;
  }

  Future<void> _changePassword() async {
    if (_changingPassword) return;
    final String? problem = _passwordProblem();
    if (problem != null) {
      setState(() {
        _passwordError = problem;
        _passwordDone = null;
      });
      return;
    }
    setState(() {
      _changingPassword = true;
      _passwordError = null;
      _passwordDone = null;
    });
    final String? failure = await widget.auth.changePassword(
      _currentPassword.text,
      _newPassword.text,
    );
    if (!mounted) return;
    setState(() {
      _changingPassword = false;
      _passwordError = failure;
    });
  }

  Future<void> _sendSetPasswordLink() async {
    if (_changingPassword) return;
    setState(() {
      _changingPassword = true;
      _passwordError = null;
      _passwordDone = null;
    });
    final String message = await widget.auth.sendSetPasswordLink();
    if (!mounted) return;
    setState(() {
      _changingPassword = false;
      _passwordDone = message;
    });
  }

  Widget _passwordField(TextEditingController controller, String label) =>
      Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: TextField(
          controller: controller,
          obscureText: true,
          autofillHints: <String>[
            controller == _currentPassword
                ? AutofillHints.password
                : AutofillHints.newPassword,
          ],
          decoration: InputDecoration(labelText: label),
        ),
      );

  Widget _passwordCard() {
    final bool hasPassword = widget.auth.hasPassword;
    return CcCard(
      title: 'Change password',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          if (hasPassword) ...<Widget>[
            Text(
              'The new password must have $staffPasswordMin to $staffPasswordMax characters.',
            ),
            const SizedBox(height: 12),
            _passwordField(_currentPassword, 'Current password'),
            _passwordField(_newPassword, 'New password'),
            _passwordField(_confirmPassword, 'Confirm new password'),
            FilledButton(
              onPressed: _changingPassword ? null : _changePassword,
              child: const Text('Change password'),
            ),
          ] else ...<Widget>[
            const Text(
              'You sign in with Google. Google manages that password. To also sign in with a password, set one. We email you a link.',
            ),
            const SizedBox(height: 12),
            OutlinedButton(
              onPressed: _changingPassword ? null : _sendSetPasswordLink,
              child: const Text('Set a password'),
            ),
          ],
          if (_passwordError != null) ...<Widget>[
            const SizedBox(height: 12),
            CcBanner(text: _passwordError!, tone: Tone.danger),
          ],
          if (_passwordDone != null) ...<Widget>[
            const SizedBox(height: 12),
            CcBanner(text: _passwordDone!, tone: Tone.ok),
          ],
        ],
      ),
    );
  }

  Future<void> _load() async {
    final Loaded<List<StaffSessionInfo>> sessions = await Loaded.of(
      _store.api.staffSessions(),
    );
    final Loaded<int> backups = await Loaded.of(_store.api.backupCodesLeft());
    if (!mounted) return;
    setState(() {
      _sessions = sessions;
      _backups = backups;
    });
  }

  Future<void> _run(Future<Object?> Function() call, String done) async {
    if (_busy) return;
    setState(() => _busy = true);
    String message = done;
    try {
      await call();
    } on StaffApiException catch (error) {
      message = friendlyError(error);
    }
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, message);
    await _load();
  }

  Future<void> _signOutAll() async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Sign out of all devices?',
      message:
          'Every device, including this one, must sign in again with a new code.',
      confirmLabel: 'Sign out of all devices',
      danger: true,
    );
    if (!ok || !mounted) return;
    try {
      await _store.api.endAllStaffSessions();
      widget.auth.forgetDevice();
    } on StaffApiException catch (error) {
      if (mounted) announce(context, friendlyError(error));
    }
    if (mounted) await _load();
  }

  Future<void> _makeCodes() async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _codesError = null;
    });
    List<String>? codes;
    try {
      codes = await _store.api.createBackupCodes();
    } on StaffApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _codesError = error.statusCode == 401
            ? 'Sign in again to make new codes. Press Sign out, then sign in with your password.'
            : friendlyError(error);
      });
      return;
    }
    if (!mounted) return;
    setState(() => _busy = false);
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => _CodesDialog(codes: codes!),
    );
    await _load();
  }

  Widget _sessionsCard() {
    final Loaded<List<StaffSessionInfo>>? loaded = _sessions;
    return CcCard(
      title: 'Where you are signed in',
      trailing: OutlinedButton(
        onPressed: _busy ? null : _signOutAll,
        child: const Text('Sign out of all devices'),
      ),
      child: loaded == null
          ? const CcSkeleton(rows: 2)
          : loaded.value == null
          ? CcBanner(
              text: loaded.error!,
              tone: Tone.danger,
              action: OutlinedButton(
                onPressed: _load,
                child: const Text('Try again'),
              ),
            )
          : Column(
              children: <Widget>[
                for (final StaffSessionInfo session in <StaffSessionInfo>[
                  ...loaded.value!.where((StaffSessionInfo s) => s.isCurrent),
                  ...loaded.value!.where((StaffSessionInfo s) => !s.isCurrent),
                ])
                  Padding(
                    padding: const EdgeInsets.symmetric(vertical: 8),
                    child: Row(
                      children: <Widget>[
                        Expanded(
                          child: Column(
                            crossAxisAlignment: CrossAxisAlignment.start,
                            children: <Widget>[
                              Text(
                                session.isCurrent
                                    ? 'This device'
                                    : _device(session.userAgent),
                                style: const TextStyle(
                                  fontWeight: FontWeight.w600,
                                  color: Cc.ink,
                                ),
                              ),
                              Text(
                                'Signed in ${dateTimeText(session.createdAt)} · ${session.ip}',
                                style: Cc.small,
                              ),
                            ],
                          ),
                        ),
                        if (session.isCurrent)
                          const CcBadge('Current', tone: Tone.ok)
                        else
                          OutlinedButton(
                            onPressed: _busy
                                ? null
                                : () => _run(
                                    () => _store.api.endStaffSession(
                                      session.handle,
                                    ),
                                    'That device was signed out.',
                                  ),
                            child: const Text('Sign out'),
                          ),
                      ],
                    ),
                  ),
                if (loaded.value!.isEmpty)
                  const Text('No other sign-in is active.'),
              ],
            ),
    );
  }

  String _device(String agent) {
    final String lower = agent.toLowerCase();
    final String? system = lower.contains('windows')
        ? 'Windows'
        : lower.contains('mac')
        ? 'Mac'
        : lower.contains('android')
        ? 'Android'
        : lower.contains('iphone')
        ? 'iPhone'
        : lower.contains('linux')
        ? 'Linux'
        : null;
    final String? browser = lower.contains('edg/')
        ? 'Edge'
        : lower.contains('chrome')
        ? 'Chrome'
        : lower.contains('firefox')
        ? 'Firefox'
        : lower.contains('safari')
        ? 'Safari'
        : null;
    if (browser == null && system == null) return 'Unknown device';
    if (system == null) return browser!;
    return '${browser ?? 'Browser'} on $system';
  }

  Widget _backupCard() {
    final Loaded<int>? loaded = _backups;
    final String left = loaded?.value == null
        ? 'Could not read'
        : '${loaded!.value} left';
    return CcCard(
      title: 'Backup codes',
      trailing: OutlinedButton(
        onPressed: _busy ? null : _makeCodes,
        child: const Text('Make new codes'),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Use a backup code if the emailed code does not arrive. Each code works once.',
          ),
          const SizedBox(height: 8),
          Text(
            'Backup codes: $left',
            style: const TextStyle(fontWeight: FontWeight.w700),
          ),
          if (_codesError != null) ...<Widget>[
            const SizedBox(height: 12),
            CcBanner(
              text: _codesError!,
              tone: Tone.warn,
              action: OutlinedButton(
                onPressed: widget.onSignOut,
                child: const Text('Sign out'),
              ),
            ),
          ],
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) => CcPage(
    maxWidth: 760,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        const CcPageHeader('My account'),
        CcCard(
          child: CcKeyValue(<(String, Widget)>[
            ('Email', Text(_store.me)),
            ('Role', Text(roleLabel(_store.profile!.role))),
          ]),
        ),
        const SizedBox(height: 16),
        _sessionsCard(),
        const SizedBox(height: 16),
        _passwordCard(),
        const SizedBox(height: 16),
        _backupCard(),
        const SizedBox(height: 16),
        CcCard(
          title: 'Privacy and terms',
          child: Wrap(
            spacing: 8,
            runSpacing: 8,
            children: <Widget>[
              for (final LegalDocumentKind document in LegalDocumentKind.values)
                OutlinedButton(
                  onPressed: () => Navigator.of(context).push(
                    MaterialPageRoute<void>(
                      builder: (_) =>
                          ControlCentreLegalPage(document: document),
                    ),
                  ),
                  child: Text(legalTitle(document)),
                ),
            ],
          ),
        ),
        const SizedBox(height: 16),
        Align(
          alignment: Alignment.centerLeft,
          child: OutlinedButton.icon(
            onPressed: widget.onSignOut,
            icon: const Icon(Icons.logout, size: 18),
            label: const Text('Sign out'),
          ),
        ),
      ],
    ),
  );
}

class _CodesDialog extends StatelessWidget {
  const _CodesDialog({required this.codes});

  final List<String> codes;

  @override
  Widget build(BuildContext context) => AlertDialog(
    title: const Text('Your new backup codes'),
    content: SizedBox(
      width: 420,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Save these now. They are shown only once. Each one works once, and the old codes no longer work.',
          ),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: Cc.canvas,
              borderRadius: BorderRadius.circular(8),
              border: Border.all(color: Cc.line),
            ),
            child: SelectionArea(
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (final String code in codes)
                    Text(
                      code,
                      style: const TextStyle(
                        fontFamily: 'monospace',
                        height: 1.6,
                      ),
                    ),
                ],
              ),
            ),
          ),
        ],
      ),
    ),
    actions: <Widget>[
      TextButton(
        onPressed: () async {
          await Clipboard.setData(ClipboardData(text: codes.join('\n')));
          if (context.mounted) announce(context, 'The codes were copied.');
        },
        child: const Text('Copy codes'),
      ),
      TextButton(
        onPressed: () => downloadCsv(
          filename: 'backup-codes.csv',
          csv: <String>['Backup code', ...codes].join('\r\n'),
        ),
        child: const Text('Download codes'),
      ),
      FilledButton(
        onPressed: () => Navigator.of(context).pop(),
        child: const Text('I saved them'),
      ),
    ],
  );
}
