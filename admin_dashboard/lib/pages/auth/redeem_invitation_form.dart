import 'package:firebase_auth/firebase_auth.dart';
import 'package:firebase_core/firebase_core.dart';
import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../app/invite_link.dart';
import '../../app/workspace_runtime.dart';
import '../../app_runtime.dart';
import '../../services/auth_service.dart';
import '../../services/platform_api_client.dart';
import 'package:scoot_design/scoot_design.dart';

String normalizeInvitationCode(String input) => input
    .toUpperCase()
    .replaceAll(RegExp(r'[\s-]'), '')
    .replaceAll('O', '0')
    .replaceAll('I', '1')
    .replaceAll('L', '1');

class RedeemInvitationForm extends StatefulWidget {
  const RedeemInvitationForm({
    super.key,
    required this.onSignedIn,
    required this.onBack,
    this.client,
    this.invite,
  });

  final VoidCallback onSignedIn;
  final VoidCallback onBack;
  final PlatformApiClient? client;
  final InviteLink? invite;

  @override
  State<RedeemInvitationForm> createState() => _RedeemInvitationFormState();
}

class _RedeemInvitationFormState extends State<RedeemInvitationForm> {
  final GlobalKey<FormState> _formKey = GlobalKey<FormState>();
  late final TextEditingController _code = TextEditingController(
    text: _formattedCode(widget.invite?.code),
  );
  final TextEditingController _check = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _confirm = TextEditingController();
  final TextEditingController _emailCode = TextEditingController();
  late final PlatformApiClient _api = widget.client ?? PlatformApiClient();
  bool _busy = false;
  String? _error;
  String? _sentTo;
  bool _emailStepDone = false;

  static String _formattedCode(String? code) => code == null
      ? ''
      : '${code.substring(0, 4)}-${code.substring(4, 8)}-${code.substring(8)}';

  @override
  void dispose() {
    _code.dispose();
    _check.dispose();
    _password.dispose();
    _confirm.dispose();
    _emailCode.dispose();
    super.dispose();
  }

  static const String _serverEmailCodeLocked =
      'Too many wrong email codes. Ask for a new one.';
  static const String emailCodeLockedMessage =
      'Too many wrong codes. Tap Resend to get a new code.';

  static String emailCodeMessage(PlatformApiException error) {
    switch (error.statusCode) {
      case 400:
        return error.message;
      case 403:
        return error.message.startsWith('The email code')
            ? error.message
            : 'The invitation code or check is not valid.';
      case 410:
        return 'This invitation or its email code has expired. Ask your '
            'administrator for a new one.';
      case 429:
        if (error.message == _serverEmailCodeLocked) {
          return emailCodeLockedMessage;
        }
        if (error.message.startsWith('Too many email codes')) {
          return error.message;
        }
        return 'Too many tries. Wait a few minutes, then try again.';
      default:
        return error.message;
    }
  }

  Future<bool> _sendEmailCode() async {
    final EmailCodeRequest request = await _api.requestEmailCode(
      code: normalizeInvitationCode(_code.text),
      check: _check.text.trim(),
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
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await _sendEmailCode();
    } on PlatformApiException catch (error) {
      if (mounted) setState(() => _error = emailCodeMessage(error));
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _redeem() async {
    if (_busy || !_formKey.currentState!.validate()) return;
    if (!AppRuntime.firebaseReady) {
      setState(
        () => _error =
            'This build is not connected to its data service yet, so signing '
            'in cannot work. Please contact your administrator.',
      );
      return;
    }
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      if (_sentTo == null && !_emailStepDone) {
        final bool skipped = await _sendEmailCode();
        if (!skipped) return;
      }
      final RedeemedInvitation redeemed = await _api.redeem(
        code: normalizeInvitationCode(_code.text),
        check: _check.text.trim(),
        password: _password.text,
        device: 'Web dashboard',
        projectId: Firebase.apps.isEmpty
            ? null
            : Firebase.app().options.projectId,
        emailCode: _sentTo == null ? null : _emailCode.text.trim(),
      );
      await FirebaseAuth.instance.signInWithCustomToken(redeemed.customToken);
      if (mounted) widget.onSignedIn();
    } on PlatformApiException catch (error) {
      if (mounted) {
        setState(
          () => _error = _sentTo == null
              ? error.message
              : emailCodeMessage(error),
        );
      }
    } catch (error) {
      if (mounted) {
        setState(
          () => _error = AuthService.instance.describeSignInError(error),
        );
      }
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  String? get _linkNotice {
    final InviteLink? invite = widget.invite;
    if (invite == null) return null;
    return invite.noticeFor(WorkspaceRuntime.current?.workspace) ??
        'Invitation link opened. Your code is filled in below.';
  }

  Widget _linkNoticeBox(String text) {
    final bool opened = text.startsWith('Invitation link opened');
    return ScootNotice(
      tone: opened ? ScootTone.success : ScootTone.warning,
      message: text,
      liveRegion: true,
    );
  }

  Widget _labelled(String label, Widget field) {
    final ScootColors c = ScootColors.of(context);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(label, style: ScootType.smallStrong.copyWith(color: c.ink)),
        const SizedBox(height: 6),
        field,
      ],
    );
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Form(
      key: _formKey,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Semantics(
            header: true,
            child: Text(
              'Redeem your invitation',
              style: ScootType.h1.copyWith(color: c.ink),
            ),
          ),
          const SizedBox(height: 6),
          Text(
            'Enter the code from your invitation. Then set your password.',
            style: ScootType.body.copyWith(color: c.muted),
          ),
          const SizedBox(height: 22),
          if (_linkNotice != null) ...<Widget>[
            _linkNoticeBox(_linkNotice!),
            const SizedBox(height: 16),
          ],
          _labelled(
            'Invitation code',
            TextFormField(
              controller: _code,
              enabled: !_busy,
              autocorrect: false,
              textCapitalization: TextCapitalization.characters,
              inputFormatters: const <TextInputFormatter>[
                InvitationCodeFormatter(),
              ],
              decoration: const InputDecoration(hintText: 'XXXX-XXXX-XXXX'),
              validator: (String? value) =>
                  normalizeInvitationCode(value ?? '').length == 12
                  ? null
                  : 'Enter the 12-character code',
            ),
          ),
          const SizedBox(height: 16),
          _labelled(
            'Second check',
            TextFormField(
              controller: _check,
              enabled: !_busy,
              autocorrect: false,
              decoration: const InputDecoration(
                hintText: 'Last 4 digits of your phone',
                helperText: 'No phone on your invitation? Enter your email.',
                helperMaxLines: 2,
              ),
              validator: (String? value) => (value ?? '').trim().isEmpty
                  ? 'Enter the second check'
                  : null,
            ),
          ),
          const SizedBox(height: 16),
          _labelled(
            'New password',
            TextFormField(
              controller: _password,
              enabled: !_busy,
              obscureText: true,
              autofillHints: const <String>[AutofillHints.newPassword],
              decoration: const InputDecoration(
                helperText: 'At least 8 characters.',
              ),
              validator: (String? value) {
                final String text = value ?? '';
                if (text.length < 8) return 'Use at least 8 characters';
                if (text.length > 128) return 'Use at most 128 characters';
                return null;
              },
            ),
          ),
          const SizedBox(height: 16),
          _labelled(
            'Confirm password',
            TextFormField(
              controller: _confirm,
              enabled: !_busy,
              obscureText: true,
              onFieldSubmitted: (_) => _redeem(),
              validator: (String? value) =>
                  value == _password.text ? null : 'The passwords do not match',
            ),
          ),
          if (_sentTo != null) ...<Widget>[
            const SizedBox(height: 16),
            Text(
              'We sent a 6-digit code to $_sentTo',
              style: ScootType.bodyStrong.copyWith(color: c.ink),
            ),
            const SizedBox(height: 8),
            _labelled(
              'Email code',
              TextFormField(
                controller: _emailCode,
                enabled: !_busy,
                autocorrect: false,
                keyboardType: TextInputType.number,
                maxLength: 6,
                validator: (String? value) =>
                    RegExp(r'^\d{6}$').hasMatch((value ?? '').trim())
                    ? null
                    : 'Enter the 6-digit code',
              ),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: TextButton(
                onPressed: _busy ? null : _resend,
                child: const Text('Resend code'),
              ),
            ),
          ],
          if (_error != null) ...<Widget>[
            const SizedBox(height: 14),
            ScootNotice(
              tone: ScootTone.danger,
              message: _error!,
              liveRegion: true,
            ),
          ],
          const SizedBox(height: 18),
          SizedBox(
            height: 48,
            child: FilledButton(
              onPressed: _busy ? null : _redeem,
              child: Text(_busy ? 'Redeeming...' : 'Set password and sign in'),
            ),
          ),
          const SizedBox(height: 8),
          TextButton(
            onPressed: _busy ? null : widget.onBack,
            child: const Text('Back to sign in'),
          ),
        ],
      ),
    );
  }
}
