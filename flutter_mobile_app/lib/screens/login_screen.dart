import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:shared_preferences/shared_preferences.dart';
import '../dev/dev_accounts.dart';
import '../firebase_options.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import 'package:scoot_design/scoot_design.dart';
import '../widgets/sign_in_view.dart';
import '../services/company_api.dart';
import '../services/company_project.dart';
import '../services/company_runtime.dart';
import '../services/account_lockout_service.dart';
import '../services/invitation_service.dart';
import 'redeem_invitation_screen.dart';
import '../theme/app_theme.dart';

class LoginScreen extends StatefulWidget {
  const LoginScreen({super.key, this.company});

  final CompanyProject? company;

  @override
  State<LoginScreen> createState() => _LoginScreenState();
}

class _LoginScreenState extends State<LoginScreen> {
  final _formKey = GlobalKey<FormState>();
  final _emailController = TextEditingController();
  final _passwordController = TextEditingController();
  final _passwordFocus = FocusNode();
  bool _obscurePassword = true;
  bool _isLoading = false;
  String? _signInError;
  ActiveCompany? _company;
  String? _restartCompany;

  CompanyProject get _projects => widget.company ?? CompanyProject.instance;

  @override
  void initState() {
    super.initState();
    unawaited(_fillRememberedEmail());
    final ActiveCompany? initialized = CompanyRuntime.current;
    if (initialized != null) {
      _company = initialized;
    } else if (widget.company != null) {
      unawaited(_loadInjectedCompany(widget.company!));
    }
  }

  Future<void> _fillRememberedEmail() async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    final String? email = prefs.getString(rememberedEmailKey);
    if (!mounted || email == null || _emailController.text.isNotEmpty) return;
    if (prefs.getBool('remember_me') != true) return;
    _emailController.text = email;
  }

  Future<void> _storeRememberedEmail(String email, bool remember) async {
    final SharedPreferences prefs = await SharedPreferences.getInstance();
    if (remember) {
      await prefs.setString(rememberedEmailKey, email);
    } else {
      await prefs.remove(rememberedEmailKey);
    }
  }

  Future<void> _loadInjectedCompany(CompanyProject project) async {
    try {
      final ActiveCompany selected = await project.active();
      if (!mounted) return;
      setState(() => _company = CompanyRuntime.current ?? selected);
    } catch (_) {
      final ActiveCompany? initialized = CompanyRuntime.current;
      if (!mounted || initialized == null) return;
      setState(() => _company = initialized);
    }
  }

  Future<void> _changeCompany() async {
    final TextEditingController codeCtrl = TextEditingController();
    String? error;
    bool checking = false;
    final String? switchedTo = await showDialog<String>(
      context: context,
      builder: (BuildContext ctx) => StatefulBuilder(
        builder: (BuildContext ctx, StateSetter setDialogState) => AlertDialog(
          title: const Text('Company code'),
          content: TextField(
            controller: codeCtrl,
            autofocus: true,
            autocorrect: false,
            textCapitalization: TextCapitalization.characters,
            decoration: InputDecoration(
              hintText: 'Company code from your administrator',
              errorText: error,
              errorMaxLines: 3,
            ),
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.pop(ctx),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: checking
                  ? null
                  : () async {
                      setDialogState(() {
                        checking = true;
                        error = null;
                      });
                      try {
                        await _projects.save(codeCtrl.text);
                        final ActiveCompany next = await _projects.active();
                        if (ctx.mounted) Navigator.pop(ctx, next.name);
                      } on CompanyException catch (e) {
                        setDialogState(() {
                          checking = false;
                          error = e.message;
                        });
                      } catch (_) {
                        setDialogState(() {
                          checking = false;
                          error = const CompanyException(
                            CompanyFailure.unreachable,
                          ).message;
                        });
                      }
                    },
              child: Text(checking ? 'Checking...' : 'Continue'),
            ),
          ],
        ),
      ),
    );
    if (switchedTo != null && mounted) {
      setState(() => _restartCompany = switchedTo);
    }
  }

  Future<void> _useDefaultCompany() async {
    await _projects.forget();
    final ActiveCompany next = await _projects.active();
    if (mounted) setState(() => _restartCompany = next.name);
  }

  Widget _buildCompany() {
    final ActiveCompany? company = _company;
    if (company == null || (!_projects.hasDirectory && company.code == null)) {
      return const SizedBox.shrink();
    }
    final ScootColors c = ScootColors.of(context);
    return Container(
      margin: const EdgeInsets.only(bottom: 4),
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 4),
      decoration: BoxDecoration(
        color: c.card,
        border: Border.all(color: c.line),
        borderRadius: ScootRadius.cardAll,
      ),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          ConstrainedBox(
            constraints: const BoxConstraints(maxWidth: 240),
            child: Text(
              'Company: ${company.name}',
              key: const Key('company-name'),
              maxLines: 2,
              overflow: TextOverflow.ellipsis,
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
          ),
          TextButton(
            key: const Key('change-company'),
            onPressed: _changeCompany,
            child: const Text('Change company'),
          ),
          if (company.code != null)
            TextButton(
              key: const Key('use-default-company'),
              onPressed: _useDefaultCompany,
              child: const Text('Use default'),
            ),
        ],
      ),
    );
  }

  Widget _buildRestartNotice(String name) {
    return Scaffold(
      body: Center(
        child: Padding(
          padding: const EdgeInsets.all(32),
          child: Text(
            'Company set to $name.\n\n'
            'Close the app completely and open it '
            'again (on web, reload the page) to connect to it.',
            key: const Key('company-restart'),
            textAlign: TextAlign.center,
            style: const TextStyle(fontSize: 16, height: 1.5),
          ),
        ),
      ),
    );
  }

  @override
  void dispose() {
    _emailController.dispose();
    _passwordController.dispose();
    _passwordFocus.dispose();
    super.dispose();
  }

  Future<void> _handleSubmit() async {
    if (!_formKey.currentState!.validate()) return;

    final authProvider = context.read<AuthProvider>();
    setState(() {
      _isLoading = true;
      _signInError = null;
    });

    final String email = _emailController.text.trim();
    final success = await authProvider.login(email, _passwordController.text);
    if (success) {
      unawaited(_storeRememberedEmail(email, authProvider.rememberMe));
    }

    if (!mounted) return;
    setState(() => _isLoading = false);

    if (!success) {
      final status = authProvider.status;
      if (status == AuthStatus.locked) {
        _showLockedDialog(authProvider.errorMessage);
      } else {
        setState(() => _signInError = authProvider.errorMessage);
      }
    }
  }

  Future<void> _devLogin(DevAccount account) async {
    _emailController.text = account.email;
    _passwordController.text = account.password;

    final authProvider = context.read<AuthProvider>();

    setState(() => _isLoading = true);
    final success = await authProvider.login(account.email, account.password);
    if (!mounted) return;
    setState(() => _isLoading = false);

    if (!success) {
      final status = authProvider.status;
      if (status == AuthStatus.locked) {
        _showLockedDialog(authProvider.errorMessage);
      } else {
        setState(() => _signInError = authProvider.errorMessage);
      }
    }
  }

  Future<void> _showLockedDialog(String message) async {
    final AuthProvider authProvider = context.read<AuthProvider>();
    final String? email = authProvider.localLockEmail;
    final DateTime? until = authProvider.localLockedUntil;
    final bool localLock = email != null && until != null;
    bool notified = false;
    if (localLock) {
      try {
        notified = await AccountLockoutService.instance.isNotified(
          email: email,
          lockedUntil: until,
        );
      } catch (_) {}
    }
    if (!mounted) return;
    bool notifying = false;
    String? notificationMessage;
    showDialog(
      context: context,
      barrierDismissible: false,
      builder: (context) => StatefulBuilder(
        builder: (dialogContext, updateDialog) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          icon: const Icon(Icons.lock_outline, size: 48, color: Colors.red),
          title: Text(
            localLock ? 'Sign-in temporarily delayed' : 'Sign-in rate limited',
            style: TextStyle(
              fontWeight: FontWeight.bold,
              color: AppColors.textRed,
            ),
            textAlign: TextAlign.center,
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              Text(
                message,
                textAlign: TextAlign.center,
                style: const TextStyle(fontSize: 14, height: 1.5),
              ),
              const SizedBox(height: 12),
              Container(
                padding: const EdgeInsets.all(12),
                decoration: BoxDecoration(
                  color: Colors.orange.shade50,
                  borderRadius: BorderRadius.circular(8),
                  border: Border.all(color: Colors.orange.shade200),
                ),
                child: Row(
                  children: [
                    Icon(
                      Icons.info_outline,
                      color: Colors.orange.shade700,
                      size: 18,
                    ),
                    const SizedBox(width: 8),
                    Expanded(
                      child: Text(
                        localLock
                            ? 'After an admin releases this local delay, close this message and try signing in again.'
                            : 'Firebase is limiting sign-in attempts. Wait and try again. An admin cannot clear this limit here.',
                        style: TextStyle(
                          fontSize: 12,
                          color: AppColors.textOrange,
                        ),
                      ),
                    ),
                  ],
                ),
              ),
            ],
          ),
          actions: [
            if (localLock)
              TextButton(
                onPressed: (notifying || notified)
                    ? null
                    : () async {
                        updateDialog(() {
                          notifying = true;
                          notificationMessage = null;
                        });
                        try {
                          await authProvider.notifyAdminOfLocalLock(
                            email: email,
                            lockedUntil: until,
                          );
                          if (dialogContext.mounted) {
                            updateDialog(() => notified = true);
                          }
                        } catch (error) {
                          if (dialogContext.mounted) {
                            updateDialog(
                              () => notificationMessage =
                                  error is FirebaseException &&
                                      error.code == 'permission-denied'
                                  ? 'This sign-in problem could not be reported to your admin. The wait still ends on its own. If you still cannot sign in after it ends, contact your admin.'
                                  : 'Notification not confirmed. Reconnect and retry. The local delay will still expire.',
                            );
                          }
                        } finally {
                          if (dialogContext.mounted) {
                            updateDialog(() => notifying = false);
                          }
                        }
                      },
                child: Text(
                  notified
                      ? 'Admin notified'
                      : (notifying ? 'Sending...' : 'Notify admin'),
                ),
              ),
            if (notificationMessage != null) Text(notificationMessage!),
            SizedBox(
              width: double.infinity,
              child: ElevatedButton(
                onPressed: () => Navigator.pop(context),
                style: ElevatedButton.styleFrom(
                  backgroundColor: AppColors.textRed,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: const Text('Understood'),
              ),
            ),
          ],
        ),
      ),
    );
  }

  void _showForgotPasswordDialog() {
    final emailCtrl = TextEditingController(text: _emailController.text.trim());
    bool sending = false;
    String? emailError;

    showDialog(
      context: context,
      builder: (ctx) => StatefulBuilder(
        builder: (ctx, setDialogState) => AlertDialog(
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(16),
          ),
          icon: const Icon(
            Icons.email_outlined,
            size: 40,
            color: Color(0xFF40916C),
          ),
          title: const Text(
            'Reset Password',
            textAlign: TextAlign.center,
            style: TextStyle(fontWeight: FontWeight.bold),
          ),
          content: Column(
            mainAxisSize: MainAxisSize.min,
            children: [
              const Text(
                'Enter your email address and we will send you a link to reset your password.',
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 13,
                  color: Color(0xFF555555),
                  height: 1.5,
                ),
              ),
              const SizedBox(height: 16),
              TextField(
                controller: emailCtrl,
                keyboardType: TextInputType.emailAddress,
                onChanged: (_) {
                  if (emailError != null) {
                    setDialogState(() => emailError = null);
                  }
                },
                decoration: InputDecoration(
                  hintText: 'your@email.com',
                  errorText: emailError,
                  filled: true,
                  fillColor: Colors.grey.shade50,
                  border: OutlineInputBorder(
                    borderRadius: BorderRadius.circular(10),
                  ),
                  contentPadding: const EdgeInsets.symmetric(
                    horizontal: 14,
                    vertical: 12,
                  ),
                ),
              ),
            ],
          ),
          actions: [
            Row(
              children: [
                Expanded(
                  child: OutlinedButton(
                    onPressed: () => Navigator.pop(ctx),
                    child: const Text('Cancel'),
                  ),
                ),
                const SizedBox(width: 10),
                Expanded(
                  child: FilledButton(
                    style: FilledButton.styleFrom(
                      backgroundColor: AppColors.greenSolid,
                    ),
                    onPressed: sending
                        ? null
                        : () async {
                            final email = emailCtrl.text.trim();
                            if (email.isEmpty) {
                              setDialogState(
                                () => emailError =
                                    'Please enter your email address',
                              );
                              return;
                            }
                            if (!email.contains('@') || !email.contains('.')) {
                              setDialogState(
                                () => emailError =
                                    'Please enter a valid email address',
                              );
                              return;
                            }
                            setDialogState(() => sending = true);
                            final PasswordResetResult result = await CompanyApi
                                .instance
                                .requestPasswordReset(email);
                            if (!ctx.mounted) return;
                            if (result == PasswordResetResult.accepted) {
                              Navigator.pop(ctx);
                            } else {
                              setDialogState(() => sending = false);
                            }
                            if (!mounted) return;
                            final bool accepted =
                                result == PasswordResetResult.accepted;
                            ScaffoldMessenger.of(context).showSnackBar(
                              SnackBar(
                                content: Text(switch (result) {
                                  PasswordResetResult.accepted =>
                                    'If an account exists for $email, we sent a reset link. Check your inbox.',
                                  PasswordResetResult.tooMany =>
                                    'Too many requests. Try again later.',
                                  PasswordResetResult.failed =>
                                    'The reset email was not sent. Check the connection and try again.',
                                }),
                                backgroundColor: accepted
                                    ? Colors.green.shade700
                                    : Colors.red.shade700,
                                behavior: SnackBarBehavior.floating,
                                duration: const Duration(seconds: 5),
                              ),
                            );
                          },
                    child: sending
                        ? const SizedBox(
                            width: 18,
                            height: 18,
                            child: CircularProgressIndicator(
                              color: Colors.white,
                              strokeWidth: 2,
                            ),
                          )
                        : const Text('Send Email'),
                  ),
                ),
              ],
            ),
          ],
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String? restart = _restartCompany;
    if (restart != null) return _buildRestartNotice(restart);
    final AuthProvider auth = context.watch<AuthProvider>();
    final bool online = context.watch<ConnectivityProvider>().isOnline;
    return SignInView(
      formKey: _formKey,
      emailController: _emailController,
      passwordController: _passwordController,
      passwordFocus: _passwordFocus,
      obscurePassword: _obscurePassword,
      onToggleObscure: () =>
          setState(() => _obscurePassword = !_obscurePassword),
      loading: _isLoading,
      onSubmit: _handleSubmit,
      rememberMe: auth.rememberMe,
      onRememberMe: auth.setRememberMe,
      onForgotPassword: _showForgotPasswordDialog,
      errorText: _signInError,
      offline: !online,
      onInvitation: InvitationService().enabled
          ? () => Navigator.of(context).push(
              MaterialPageRoute<void>(
                builder: (_) => const RedeemInvitationScreen(),
              ),
            )
          : null,
      company: _buildCompany(),
      devQuickSignIn: kDebugMode ? _buildDevQuickSignIn() : null,
      productTitle: firebaseTarget == 'hardware' ? productTitle : null,
    );
  }

  Widget _buildDevQuickSignIn() {
    if (!kDebugMode) return const SizedBox.shrink();
    final List<DevAccount> accounts = mobileSalespersonDevQuickAccounts();
    return Container(
      margin: const EdgeInsets.only(top: 18),
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Colors.white.withValues(alpha: 0.7),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(
          color: const Color(0xFF40916C).withValues(alpha: 0.45),
        ),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Row(
            children: [
              Icon(Icons.bolt, size: 16, color: Color(0xFF40916C)),
              SizedBox(width: 6),
              Text(
                'Dev quick sign-in',
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1B4332),
                ),
              ),
            ],
          ),
          const SizedBox(height: 2),
          const Text(
            'Debug only · uses the normal password sign-in',
            style: TextStyle(fontSize: 11, color: AppColors.primary),
          ),
          const SizedBox(height: 10),
          if (accounts.isEmpty)
            const Text(
              'No salesperson test account is configured on this device. '
              'Add one to the local development credentials file.',
              style: TextStyle(fontSize: 11, color: AppColors.primary),
            )
          else
            Wrap(
              spacing: 8,
              runSpacing: 8,
              children: [
                for (final DevAccount account in accounts)
                  OutlinedButton(
                    onPressed: _isLoading ? null : () => _devLogin(account),
                    style: OutlinedButton.styleFrom(
                      foregroundColor: const Color(0xFF1B4332),
                      side: const BorderSide(color: Color(0xFF40916C)),
                      padding: const EdgeInsets.symmetric(
                        horizontal: 12,
                        vertical: 8,
                      ),
                      shape: RoundedRectangleBorder(
                        borderRadius: BorderRadius.circular(8),
                      ),
                    ),
                    child: Column(
                      mainAxisSize: MainAxisSize.min,
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: [
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
                            style: const TextStyle(
                              fontSize: 11,
                              color: AppColors.primary,
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            ),
        ],
      ),
    );
  }
}
