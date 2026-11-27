import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';

import '../providers/auth_provider.dart';
import '../services/invitation_service.dart';
import 'barcode_scanner_screen.dart';

class RedeemInvitationScreen extends StatefulWidget {
  const RedeemInvitationScreen({super.key, this.service});

  final InvitationService? service;

  @override
  State<RedeemInvitationScreen> createState() => _RedeemInvitationScreenState();
}

class _RedeemInvitationScreenState extends State<RedeemInvitationScreen> {
  final _formKey = GlobalKey<FormState>();
  final _codeController = TextEditingController();
  final _checkController = TextEditingController();
  final _passwordController = TextEditingController();
  final _confirmController = TextEditingController();
  final _emailCodeController = TextEditingController();
  final _checkFocus = FocusNode();
  final _confirmFocus = FocusNode();
  late final InvitationService _service = widget.service ?? InvitationService();
  bool _obscure = true;
  bool _busy = false;
  String? _error;
  String? _sentTo;
  bool _emailStepDone = false;

  @override
  void dispose() {
    _emailCodeController.dispose();
    _codeController.dispose();
    _checkController.dispose();
    _passwordController.dispose();
    _confirmController.dispose();
    _checkFocus.dispose();
    _confirmFocus.dispose();
    super.dispose();
  }

  Future<void> _scan() async {
    final String? raw = await Navigator.of(context).push<String>(
      MaterialPageRoute<String>(builder: (_) => const BarcodeScannerScreen()),
    );
    if (raw == null || !mounted) return;
    final InvitationPayload? payload = InvitationService.parseQr(raw);
    setState(() {
      if (payload == null) {
        _error = InvitationService.notAnInvitationMessage;
      } else {
        _error = null;
        _codeController.text = InvitationService.formatCode(payload.code);
      }
    });
  }

  Future<bool> _sendEmailCode() async {
    final EmailCodeRequest request = await _service.requestEmailCode(
      code: _codeController.text,
      check: _checkController.text,
    );
    if (!request.isRequired) {
      _emailStepDone = true;
      return true;
    }
    if (mounted) {
      setState(() {
        _sentTo = request.sentTo;
        _emailStepDone = false;
      });
    }
    return false;
  }

  Future<void> _resend() async {
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _sendEmailCode();
    } on InvitationException catch (e) {
      if (mounted) setState(() => _error = e.message);
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _submit() async {
    if (!_formKey.currentState!.validate()) return;
    final AuthProvider auth = context.read<AuthProvider>();
    final NavigatorState navigator = Navigator.of(context);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    setState(() {
      _busy = true;
      _error = null;
    });

    final InvitationRedeemed redeemed;
    try {
      if (_sentTo == null && !_emailStepDone) {
        final bool skipped = await _sendEmailCode();
        if (!skipped) {
          if (mounted) setState(() => _busy = false);
          return;
        }
      }
      redeemed = await _service.redeem(
        code: _codeController.text,
        check: _checkController.text,
        password: _passwordController.text,
        projectId: Firebase.apps.isEmpty
            ? null
            : Firebase.app().options.projectId,
        emailCode: _sentTo == null ? null : _emailCodeController.text.trim(),
      );
    } on InvitationException catch (e) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = e.message;
      });
      return;
    }
    if (!mounted) return;

    if (redeemed.projectId != Firebase.app().options.projectId) {
      setState(() {
        _busy = false;
        _error = InvitationService.wrongCompanyMessage;
      });
      return;
    }

    await _showSignInId(redeemed.signInId);
    if (!mounted) return;
    final bool signedIn = await auth.loginWithCustomToken(redeemed.customToken);
    if (!signedIn) {
      if (navigator.canPop()) navigator.pop();
      messenger.showSnackBar(
        SnackBar(
          content: Text(
            '${auth.errorMessage} You can sign in with ${redeemed.signInId} '
            'and your password.',
          ),
          backgroundColor: Colors.red.shade700,
          behavior: SnackBarBehavior.floating,
          duration: const Duration(seconds: 12),
        ),
      );
      return;
    }
    if (navigator.canPop()) navigator.pop();
  }

  Future<void> _showSignInId(String signInId) {
    return showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext ctx) => AlertDialog(
        title: const Text('Invitation accepted'),
        content: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const Text('Next time sign in with'),
            const SizedBox(height: 6),
            Semantics(
              label: 'Sign-in ID $signInId',
              excludeSemantics: true,
              child: SelectableText(
                signInId,
                key: const Key('invite-sign-in-id'),
                style: const TextStyle(fontWeight: FontWeight.w700),
              ),
            ),
            const SizedBox(height: 6),
            const Text('and your password.'),
          ],
        ),
        actions: <Widget>[
          FilledButton(
            key: const Key('invite-continue'),
            onPressed: () => Navigator.of(ctx).pop(),
            child: const Text('Continue'),
          ),
        ],
      ),
    );
  }

  Widget _label(String text, {String? help}) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(text, style: ScootType.smallStrong.copyWith(color: c.text2)),
          if (help != null)
            Text(help, style: ScootType.small.copyWith(color: c.muted)),
        ],
      ),
    );
  }

  Widget _rule(bool met, String text) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: Row(
        children: <Widget>[
          Icon(
            met ? ScootIcons.check : ScootIcons.remove,
            size: 16,
            color: met ? c.success.foreground : c.muted,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: ScootType.small.copyWith(
                color: met ? c.success.noteText : c.text2,
              ),
            ),
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final String password = _passwordController.text;
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'Redeem invitation',
        onBack: () => Navigator.of(context).maybePop(),
      ),
      body: SingleChildScrollView(
        padding: const EdgeInsets.all(ScootSpace.phoneGutter),
        keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
        child: AutofillGroup(
          child: Form(
            key: _formKey,
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Text(
                  'The code comes by email. It sets your password.',
                  style: ScootType.body.copyWith(color: c.text2),
                ),
                const SizedBox(height: 16),
                _label('Invitation code'),
                TextFormField(
                  key: const Key('invite-code'),
                  controller: _codeController,
                  autocorrect: false,
                  enableSuggestions: false,
                  textCapitalization: TextCapitalization.characters,
                  inputFormatters: const <TextInputFormatter>[
                    InvitationCodeFormatter(),
                  ],
                  textInputAction: TextInputAction.next,
                  onEditingComplete: _checkFocus.requestFocus,
                  style: ScootType.mono.copyWith(
                    color: c.ink,
                    letterSpacing: 1.5,
                  ),
                  decoration: InputDecoration(
                    hintText: 'XXXX-XXXX-XXXX',
                    suffixIcon: IconButton(
                      key: const Key('invite-scan'),
                      onPressed: _busy ? null : _scan,
                      tooltip: 'Scan QR',
                      icon: const Icon(Icons.qr_code_scanner),
                    ),
                  ),
                  validator: (String? value) =>
                      InvitationService.normalizeCode(value ?? '') == null
                      ? 'Enter the 12-character invitation code'
                      : null,
                ),
                const SizedBox(height: 16),
                _label(
                  'Last 4 phone digits or email',
                  help: 'This check proves the invitation is yours.',
                ),
                TextFormField(
                  key: const Key('invite-check'),
                  controller: _checkController,
                  focusNode: _checkFocus,
                  autocorrect: false,
                  enableSuggestions: false,
                  keyboardType: TextInputType.emailAddress,
                  textInputAction: TextInputAction.next,
                  validator: (String? value) => (value ?? '').trim().isEmpty
                      ? 'Enter the last 4 phone digits or your email'
                      : null,
                ),
                const SizedBox(height: 16),
                _label('New password'),
                TextFormField(
                  key: const Key('invite-password'),
                  controller: _passwordController,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.next,
                  onEditingComplete: _confirmFocus.requestFocus,
                  onChanged: (_) => setState(() {}),
                  autofillHints: const <String>[AutofillHints.newPassword],
                  decoration: InputDecoration(
                    suffixIcon: IconButton(
                      icon: Icon(
                        _obscure
                            ? Icons.visibility_outlined
                            : Icons.visibility_off_outlined,
                      ),
                      tooltip: _obscure ? 'Show password' : 'Hide password',
                      onPressed: () => setState(() => _obscure = !_obscure),
                    ),
                  ),
                  validator: (String? value) {
                    final String v = value ?? '';
                    if (v.length < InvitationService.minPasswordLength) {
                      return 'Use at least ${InvitationService.minPasswordLength} characters';
                    }
                    if (v.length > InvitationService.maxPasswordLength) {
                      return 'Use at most ${InvitationService.maxPasswordLength} characters';
                    }
                    return null;
                  },
                ),
                const SizedBox(height: 16),
                _label('Confirm password'),
                TextFormField(
                  key: const Key('invite-confirm'),
                  controller: _confirmController,
                  focusNode: _confirmFocus,
                  obscureText: _obscure,
                  autocorrect: false,
                  enableSuggestions: false,
                  textInputAction: TextInputAction.done,
                  autofillHints: const <String>[AutofillHints.newPassword],
                  onChanged: (_) => setState(() {}),
                  onFieldSubmitted: (_) {
                    if (!_busy) _submit();
                  },
                  validator: (String? value) =>
                      value != _passwordController.text
                      ? 'The passwords do not match'
                      : null,
                ),
                _rule(
                  password.length >= InvitationService.minPasswordLength,
                  'At least ${InvitationService.minPasswordLength} characters',
                ),
                _rule(
                  password.isNotEmpty && password == _confirmController.text,
                  'Both passwords match',
                ),
                if (_sentTo != null) ...<Widget>[
                  const SizedBox(height: 16),
                  Text(
                    'We sent a 6-digit code to $_sentTo',
                    key: const Key('invite-email-sent'),
                    style: ScootType.body.copyWith(color: c.text2),
                  ),
                  const SizedBox(height: 8),
                  _label('Email code'),
                  TextFormField(
                    key: const Key('invite-email-code'),
                    controller: _emailCodeController,
                    keyboardType: TextInputType.number,
                    maxLength: 6,
                    autocorrect: false,
                    enableSuggestions: false,
                    style: ScootType.mono.copyWith(
                      color: c.ink,
                      letterSpacing: 2,
                    ),
                    validator: (String? value) =>
                        RegExp(r'^\d{6}$').hasMatch((value ?? '').trim())
                        ? null
                        : 'Enter the 6-digit code',
                  ),
                  Align(
                    alignment: Alignment.centerLeft,
                    child: TextButton(
                      key: const Key('invite-resend'),
                      onPressed: _busy ? null : _resend,
                      child: const Text('Resend code'),
                    ),
                  ),
                ],
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 16),
                  KeyedSubtree(
                    key: const Key('invite-error'),
                    child: ScootNotice(
                      tone: ScootTone.danger,
                      icon: ScootIcons.error,
                      message: _error!,
                      liveRegion: true,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
      primaryAction: Container(
        decoration: BoxDecoration(
          color: c.card,
          border: Border(top: BorderSide(color: c.line)),
        ),
        padding: const EdgeInsets.fromLTRB(16, 12, 16, 12),
        child: FilledButton(
          key: const Key('invite-submit'),
          onPressed: _busy ? null : _submit,
          style: FilledButton.styleFrom(
            minimumSize: const Size.fromHeight(ScootSize.primaryButton),
          ),
          child: _busy
              ? const SizedBox(
                  width: 22,
                  height: 22,
                  child: CircularProgressIndicator(
                    color: Colors.white,
                    strokeWidth: 2.5,
                  ),
                )
              : const Text('Redeem invitation'),
        ),
      ),
    );
  }
}
