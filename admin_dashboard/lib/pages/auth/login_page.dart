import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';

import '../../app/company_features.dart';
import '../../app/workspace_runtime.dart';
import '../../app_runtime.dart';
import '../../dev/dev_accounts.dart';
import '../../services/auth_service.dart';
import '../../services/account_lockout_service.dart';
import '../../services/platform_api_client.dart';
import '../../theme/dso_theme.dart';
import 'package:scoot_design/scoot_design.dart';
import '../../widgets/google_sign_in_button.dart';
import '../legal_documents_page.dart';
import '../../app/invite_link.dart';
import 'redeem_invitation_form.dart';

class LoginPage extends StatefulWidget {
  const LoginPage({super.key, required this.onSignedIn});

  final VoidCallback onSignedIn;

  @override
  State<LoginPage> createState() => _LoginPageState();
}

class _LoginPageState extends State<LoginPage> {
  final TextEditingController _emailController = TextEditingController();
  final TextEditingController _passwordController = TextEditingController();
  final FocusNode _passwordFocus = FocusNode();
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();

  bool _isLoading = false;
  bool _obscurePassword = true;
  bool _redeeming = InviteLink.pending != null;
  String? _errorMessage = AuthService.instance.takeSignInNotice();
  DateTime? _lockedUntil;
  String? _lockedEmail;
  bool _notifyingAdmin = false;
  bool _adminNotified = false;
  String? _notificationMessage;
  Timer? _lockTicker;

  @override
  void dispose() {
    _lockTicker?.cancel();
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  bool get _isLocked =>
      _lockedUntil != null && _lockedUntil!.isAfter(DateTime.now());

  void _beginLockCountdown(String email, DateTime unlockAt) {
    _lockTicker?.cancel();
    setState(() {
      _lockedUntil = unlockAt;
      _lockedEmail = email;
      _adminNotified = AccountLockoutService.instance.isNotified(
        email: email,
        lockedUntil: unlockAt,
      );
      _notificationMessage = null;
    });
    _lockTicker = Timer.periodic(const Duration(seconds: 1), (Timer timer) {
      if (!mounted) {
        timer.cancel();
        return;
      }
      if (!_isLocked) {
        timer.cancel();
        setState(() {
          _lockedUntil = null;
          _errorMessage = null;
        });
      } else {
        setState(() {});
      }
    });
  }

  String _formatRemaining(Duration d) {
    final int m = d.inMinutes;
    final int s = d.inSeconds.remainder(60);
    return '${m.toString().padLeft(2, '0')}:${s.toString().padLeft(2, '0')}';
  }

  Future<void> _showForgotPassword() async {
    final TextEditingController email = TextEditingController(
      text: _emailController.text.trim(),
    );
    String? problem;
    bool sending = false;
    bool sent = false;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => StatefulBuilder(
        builder: (BuildContext context, StateSetter setDialog) {
          Future<void> send() async {
            final String value = email.text.trim();
            if (!RegExp(r'^[^@\s]+@[^@\s]+\.[^@\s]+$').hasMatch(value)) {
              setDialog(() => problem = 'Enter a valid email');
              return;
            }
            setDialog(() {
              sending = true;
              problem = null;
            });
            try {
              await AuthService.instance.sendPasswordReset(value);
              setDialog(() => sent = true);
            } on PlatformApiException catch (error) {
              setDialog(() {
                if (error.statusCode == 429) {
                  problem = 'Too many requests. Try again later.';
                } else if (error.code == 'unreachable') {
                  problem = 'No connection. Try again.';
                } else {
                  problem = 'The reset email was not sent. Try again.';
                }
              });
            } catch (_) {
              setDialog(
                () => problem = 'The reset email was not sent. Try again.',
              );
            } finally {
              setDialog(() => sending = false);
            }
          }

          return AlertDialog(
            title: const Text('Reset password'),
            content: SizedBox(
              width: 380,
              child: sent
                  ? const Text(
                      'If an account uses this email, a reset link is on its way. Check the inbox and the spam folder.',
                    )
                  : Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        const Text(
                          'Enter your work email. We send a link to set a new password.',
                        ),
                        const SizedBox(height: 12),
                        TextField(
                          controller: email,
                          autofocus: true,
                          keyboardType: TextInputType.emailAddress,
                          textInputAction: TextInputAction.send,
                          autofillHints: const <String>[AutofillHints.email],
                          onSubmitted: (_) {
                            if (!sending) send();
                          },
                          decoration: InputDecoration(
                            labelText: 'Email',
                            errorText: problem,
                          ),
                        ),
                      ],
                    ),
            ),
            actions: sent
                ? <Widget>[
                    FilledButton(
                      onPressed: () => Navigator.pop(dialogContext),
                      child: const Text('Done'),
                    ),
                  ]
                : <Widget>[
                    TextButton(
                      onPressed: sending
                          ? null
                          : () => Navigator.pop(dialogContext),
                      child: const Text('Cancel'),
                    ),
                    FilledButton(
                      onPressed: sending ? null : send,
                      child: Text(sending ? 'Sending...' : 'Send reset link'),
                    ),
                  ],
          );
        },
      ),
    );
  }

  Future<void> _signIn() async {
    if (!_formKey.currentState!.validate()) return;
    if (!AppRuntime.firebaseReady) {
      setState(() {
        _errorMessage = _notConnected;
      });
      debugPrint(
        'Sign-in blocked: Firebase is not initialised. Check the company '
        'record the dashboard loaded.',
      );
      return;
    }

    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });

    try {
      await AuthService.instance.signIn(
        email: _emailController.text.trim(),
        password: _passwordController.text.trim(),
      );
      AuthService.instance.reportSignIn();
      if (mounted) {
        _lockTicker?.cancel();
        setState(() => _lockedUntil = null);
        widget.onSignedIn();
      }
    } on AccountLockedException catch (locked) {
      if (mounted) {
        _beginLockCountdown(locked.email, locked.unlockAt);
        setState(() {
          _isLoading = false;
          _errorMessage = null;
        });
      }
    } catch (error) {
      if (mounted) {
        _lockTicker?.cancel();
        setState(() {
          _isLoading = false;
          _lockedUntil = null;
          _lockedEmail = null;
          _adminNotified = false;
          _notificationMessage = null;
          _errorMessage = AuthService.instance.describeSignInError(error);
        });
      }
    }
  }

  Future<void> _signInWithGoogle() async {
    if (_isLoading) return;
    if (!AppRuntime.firebaseReady) {
      setState(() {
        _errorMessage = _notConnected;
      });
      return;
    }
    setState(() {
      _isLoading = true;
      _errorMessage = null;
    });
    try {
      final bool signedIn = await AuthService.instance.signInWithGoogle();
      if (signedIn) AuthService.instance.reportSignIn();
      if (!mounted) return;
      setState(() => _isLoading = false);
      if (signedIn) {
        final String? passwordNotice = AuthService.instance.takeSignInNotice();
        if (passwordNotice != null) {
          await showDialog<void>(
            context: context,
            builder: (BuildContext dialogContext) => AlertDialog(
              title: const Text('Set a new password'),
              content: Text(passwordNotice),
              actions: <Widget>[
                TextButton(
                  onPressed: () async {
                    final String? address =
                        AuthService.instance.passwordNoticeEmail;
                    if (address != null) {
                      try {
                        await AuthService.instance.sendPasswordReset(address);
                      } catch (_) {}
                    }
                    if (dialogContext.mounted) {
                      Navigator.of(dialogContext).pop();
                    }
                  },
                  child: const Text('Send reset link'),
                ),
                TextButton(
                  onPressed: () => Navigator.of(dialogContext).pop(),
                  child: const Text('Not now'),
                ),
              ],
            ),
          );
        }
        if (mounted) widget.onSignedIn();
      }
    } catch (error) {
      if (!mounted) return;
      final String message =
          AuthService.instance.takeSignInNotice() ??
          AuthService.instance.describeSignInError(error);
      setState(() {
        _isLoading = false;
        _errorMessage = message;
      });
    }
  }

  Future<void> _notifyAdmin() async {
    final String? email = _lockedEmail;
    final DateTime? until = _lockedUntil;
    if (email == null || until == null || _notifyingAdmin || _adminNotified) {
      return;
    }
    setState(() {
      _notifyingAdmin = true;
      _notificationMessage = null;
    });
    try {
      await AuthService.instance.notifyAdminOfLocalLock(
        email: email,
        lockedUntil: until,
      );
      if (mounted && _lockedEmail == email && _lockedUntil == until) {
        setState(() => _adminNotified = true);
      }
    } catch (error) {
      if (mounted && _lockedEmail == email && _lockedUntil == until) {
        setState(
          () => _notificationMessage =
              error is FirebaseException && error.code == 'permission-denied'
              ? 'This sign-in problem could not be reported to your admin. The wait still ends on its own. If you still cannot sign in after it ends, contact your admin.'
              : 'Notification not confirmed. Reconnect and retry. The local delay will still expire.',
        );
      }
    } finally {
      if (mounted) setState(() => _notifyingAdmin = false);
    }
  }

  void _devQuickSignIn(DevAccount account) {
    _emailController.text = account.email;
    _passwordController.text = account.password;
    _signIn();
  }

  Widget _buildDevQuickSignIn() {
    if (!kDebugMode) return const SizedBox.shrink();
    final List<DevAccount> accounts = dashboardDevQuickAccounts();
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: context.dso.surfaceSoft,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFF27AE60)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Row(
            children: <Widget>[
              Icon(Icons.bolt, size: 16, color: Color(0xFF2D6E5E)),
              SizedBox(width: 6),
              Text(
                'Dev quick sign-in',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1A4A3C),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          Text(
            'Debug only · OTP skipped',
            style: TextStyle(fontSize: 11, color: context.dso.muted),
          ),
          const SizedBox(height: 10),
          if (accounts.isEmpty)
            Text(
              'No approved dashboard test accounts are configured. Add the '
              'Admin, Supervisor and Branch Manager records to the local dev credentials file.',
              style: TextStyle(fontSize: 11, color: context.dso.muted),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: <Widget>[
                for (final DevAccount account in accounts)
                  OutlinedButton(
                    onPressed: _isLoading
                        ? null
                        : () => _devQuickSignIn(account),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1A4A3C),
                      side: const BorderSide(color: Color(0xFF27AE60)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          account.label,
                          style: const TextStyle(
                            fontSize: 13,
                            fontWeight: FontWeight.w700,
                          ),
                        ),
                        if (account.role.isNotEmpty)
                          Text(
                            account.role,
                            style: TextStyle(
                              fontSize: 10,
                              color: context.dso.muted,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
          if (accounts.isNotEmpty && accounts.length < 3) ...<Widget>[
            const SizedBox(height: 8),
            Text(
              'Only locally configured roles are shown. Add the missing role passwords to the ignored dev credentials file to enable their buttons.',
              style: TextStyle(fontSize: 11, color: context.dso.muted),
            ),
          ],
        ],
      ),
    );
  }

  bool get _checkingCompany =>
      WorkspaceRuntime.current == null && WorkspaceRuntime.loadError.isEmpty;

  bool get _formBusy => _isLoading || _notifyingAdmin || _checkingCompany;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      body: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          _backendStrip(),
          Expanded(
            child: LayoutBuilder(
              builder: (BuildContext context, BoxConstraints constraints) {
                final bool wide = constraints.maxWidth >= 900;
                final Widget form = Center(
                  child: SingleChildScrollView(
                    padding: const EdgeInsets.all(24),
                    child: ConstrainedBox(
                      constraints: const BoxConstraints(maxWidth: 420),
                      child: _buildCredentialsStep(),
                    ),
                  ),
                );
                if (wide) {
                  return Row(
                    children: <Widget>[
                      SizedBox(width: 380, child: _companyPanel(true)),
                      Expanded(child: form),
                    ],
                  );
                }
                return Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    _companyPanel(false),
                    Expanded(child: form),
                  ],
                );
              },
            ),
          ),
        ],
      ),
    );
  }

  Widget _companyPanel(bool tall) {
    final String? company = WorkspaceRuntime.current?.legalName;
    final bool failed = WorkspaceRuntime.loadError.isNotEmpty;
    final TextStyle linkStyle = ScootType.small.copyWith(
      color: ScootPalette.navText,
    );
    return Container(
      color: ScootPalette.navBg,
      padding: EdgeInsets.all(tall ? 32 : 20),
      child: Column(
        mainAxisSize: tall ? MainAxisSize.max : MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          _brandRow(),
          SizedBox(height: tall ? 48 : 16),
          Container(
            width: double.infinity,
            padding: const EdgeInsets.all(16),
            decoration: BoxDecoration(
              border: Border.all(color: ScootPalette.navOn),
              borderRadius: ScootRadius.cardAll,
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'COMPANY',
                  style: ScootType.caption.copyWith(
                    color: ScootPalette.navLabel,
                    letterSpacing: 0.8,
                  ),
                ),
                const SizedBox(height: 4),
                Semantics(
                  liveRegion: true,
                  child: ScootLongText(
                    failed
                        ? 'Workspace unavailable'
                        : (company ?? 'Checking company…'),
                    maxLines: 2,
                    style: ScootType.h2.copyWith(color: Colors.white),
                  ),
                ),
                if (!failed && company != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Check this name before you type your password.',
                    style: ScootType.small.copyWith(
                      color: ScootPalette.navText,
                    ),
                  ),
                ],
              ],
            ),
          ),
          if (tall) const Spacer() else const SizedBox(height: 8),
          Wrap(
            children: <Widget>[
              TextButton(
                onPressed: () =>
                    showLegalDocument(context, LegalDocumentKind.privacyPolicy),
                child: Text('Privacy policy', style: linkStyle),
              ),
              TextButton(
                onPressed: () => showLegalDocument(
                  context,
                  LegalDocumentKind.termsAndConditions,
                ),
                child: Text('Terms and conditions', style: linkStyle),
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _brandRow() {
    return Row(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: Image.asset(
            'assets/images/ScootSales-icon.png',
            width: 54,
            height: 40,
            fit: BoxFit.contain,
            errorBuilder: (_, _, _) =>
                const Icon(ScootIcons.dashboard, color: Colors.white),
          ),
        ),
        const SizedBox(width: 12),
        Text(productTitle, style: ScootType.h2.copyWith(color: Colors.white)),
      ],
    );
  }

  Widget _formHeading(String title, String subtitle) {
    final ScootColors c = ScootColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(title, style: ScootType.h1.copyWith(color: c.ink)),
        ),
        const SizedBox(height: 6),
        Text(subtitle, style: ScootType.body.copyWith(color: c.muted)),
      ],
    );
  }

  Widget _backendStrip() {
    final List<String> notices = <String>[
      if (AppRuntime.usesLocalEmulator)
        'Local emulator mode: this build reads and writes test data on '
            '${AppRuntime.emulatorHost}, not the real project.',
      if (AppRuntime.backendWarning.isNotEmpty) AppRuntime.backendWarning,
    ];
    if (notices.isEmpty) return const SizedBox.shrink();
    final ScootToneColors tone = ScootColors.of(context).warning;
    return Container(
      width: double.infinity,
      color: tone.noteBackground,
      padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
      child: Row(
        children: <Widget>[
          Icon(ScootIcons.warning, size: 18, color: tone.noteText),
          const SizedBox(width: 10),
          Expanded(
            child: Text(
              notices.join(' '),
              style: ScootType.small.copyWith(color: tone.noteText),
            ),
          ),
        ],
      ),
    );
  }

  Widget _field(String label, Widget field, {Widget? trailing}) {
    final ScootColors c = ScootColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Text(
                label,
                style: ScootType.smallStrong.copyWith(color: c.ink),
              ),
            ),
            ?trailing,
          ],
        ),
        const SizedBox(height: 6),
        field,
      ],
    );
  }

  static const String _notConnected =
      'This build is not connected to its data service yet, so signing in '
      'cannot work. Contact your administrator.';

  Widget _buildCredentialsStep() {
    if (WorkspaceRuntime.loadError.isNotEmpty) {
      final String? problem = InviteLink.pending?.problem;
      return ScootNotice(
        tone: ScootTone.danger,
        title: problem == null
            ? 'Workspace unavailable'
            : 'Invitation link not valid',
        message: problem == null
            ? '${WorkspaceRuntime.loadError} The sign-in form is hidden so nobody types a password here.'
            : '$problem Ask your administrator for a new invitation.',
        liveRegion: true,
      );
    }
    if (_redeeming && WorkspaceRuntime.current != null) {
      return RedeemInvitationForm(
        onSignedIn: widget.onSignedIn,
        onBack: () {
          InviteLink.pending = null;
          setState(() => _redeeming = false);
        },
        invite: InviteLink.pending,
      );
    }
    final ScootColors c = ScootColors.of(context);
    return FocusTraversalGroup(
      policy: OrderedTraversalPolicy(),
      child: Form(
        key: _formKey,
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            _formHeading(
              'Sign in',
              'Use the email your administrator registered.',
            ),
            const SizedBox(height: 22),
            if (!AppRuntime.firebaseReady && !_checkingCompany) ...<Widget>[
              const ScootNotice(
                tone: ScootTone.warning,
                message: _notConnected,
                liveRegion: true,
              ),
              const SizedBox(height: 16),
            ],
            _field(
              'Email',
              FocusTraversalOrder(
                order: const NumericFocusOrder(1),
                child: TextFormField(
                  controller: _emailController,
                  enabled: !_formBusy,
                  onEditingComplete: _passwordFocus.requestFocus,
                  onChanged: (_) {
                    _lockTicker?.cancel();
                    setState(() {
                      _lockedUntil = null;
                      _lockedEmail = null;
                      _adminNotified = false;
                      _notificationMessage = null;
                    });
                  },
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  autofillHints: const <String>[
                    AutofillHints.username,
                    AutofillHints.email,
                  ],
                  decoration: const InputDecoration(
                    hintText: 'name@company.com',
                  ),
                  validator: (String? value) {
                    if (value == null || value.trim().isEmpty) {
                      return 'Please enter email';
                    }
                    if (!RegExp(
                      r'^[^@\s]+@[^@\s]+\.[^@\s]+$',
                    ).hasMatch(value.trim())) {
                      return 'Enter a valid email';
                    }
                    return null;
                  },
                ),
              ),
            ),
            const SizedBox(height: 14),
            _field(
              'Password',
              trailing: TextButton(
                onPressed: _formBusy ? null : _showForgotPassword,
                child: const Text('Forgot password?'),
              ),
              FocusTraversalOrder(
                order: const NumericFocusOrder(2),
                child: TextFormField(
                  controller: _passwordController,
                  focusNode: _passwordFocus,
                  enabled: !_formBusy,
                  obscureText: _obscurePassword,
                  textInputAction: TextInputAction.done,
                  autofillHints: const <String>[AutofillHints.password],
                  onFieldSubmitted: (_) {
                    if (!_formBusy) _signIn();
                  },
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      tooltip: _obscurePassword
                          ? 'Show password'
                          : 'Hide password',
                      icon: Icon(
                        _obscurePassword
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      onPressed: () =>
                          setState(() => _obscurePassword = !_obscurePassword),
                    ),
                  ),
                  validator: (String? value) {
                    if (value == null || value.isEmpty) {
                      return 'Please enter password';
                    }
                    return null;
                  },
                ),
              ),
            ),
            if (_isLocked) ...<Widget>[
              const SizedBox(height: 14),
              _lockoutBanner(),
            ],
            if (_errorMessage != null) ...<Widget>[
              const SizedBox(height: 14),
              ScootNotice(
                tone: ScootTone.danger,
                message: _errorMessage!,
                liveRegion: true,
                onDismiss: _isLoading
                    ? null
                    : () => setState(() => _errorMessage = null),
              ),
            ],
            const SizedBox(height: 18),
            SizedBox(
              height: 48,
              child: FocusTraversalOrder(
                order: const NumericFocusOrder(3),
                child: FilledButton(
                  onPressed: _formBusy ? null : _signIn,
                  child: Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      if (_isLoading) ...<Widget>[
                        const SizedBox(
                          width: 16,
                          height: 16,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        const SizedBox(width: 10),
                      ],
                      Text(
                        _isLocked
                            ? 'Check unlock and sign in'
                            : (_isLoading ? 'Signing in...' : 'Sign In'),
                      ),
                    ],
                  ),
                ),
              ),
            ),
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                Expanded(child: Divider(color: c.line)),
                Padding(
                  padding: const EdgeInsets.symmetric(horizontal: 12),
                  child: Text(
                    'or',
                    style: ScootType.small.copyWith(color: c.muted),
                  ),
                ),
                Expanded(child: Divider(color: c.line)),
              ],
            ),
            const SizedBox(height: 14),
            GoogleSignInButton(
              onPressed: (_formBusy || !AppRuntime.firebaseReady)
                  ? null
                  : _signInWithGoogle,
            ),
            if (WorkspaceRuntime.current != null)
              Padding(
                padding: const EdgeInsets.only(top: 8),
                child: TextButton(
                  onPressed: _formBusy
                      ? null
                      : () => setState(() => _redeeming = true),
                  child: const Text('Have an invitation code?'),
                ),
              ),
            _buildDevQuickSignIn(),
          ],
        ),
      ),
    );
  }

  Widget _lockoutBanner() {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        ScootNotice(
          tone: ScootTone.warning,
          icon: ScootIcons.lock,
          title: 'Sign-in delayed',
          message:
              'Too many wrong passwords. Wait ${_formatRemaining(_lockedUntil!.difference(DateTime.now()))}, or notify an admin and try again.',
          liveRegion: true,
          actionLabel: _adminNotified
              ? 'Admin notified'
              : (_notifyingAdmin ? 'Sending...' : 'Notify admin'),
          onAction: (_notifyingAdmin || _adminNotified || _isLoading)
              ? null
              : _notifyAdmin,
          actionBelow: true,
        ),
        if (_notificationMessage != null)
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(_notificationMessage!, style: ScootType.small),
          ),
      ],
    );
  }
}
