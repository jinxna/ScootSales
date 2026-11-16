import 'package:flutter/material.dart';

import '../staff_auth.dart';
import '../widgets/cc_common.dart';
import '../../widgets/google_sign_in_button.dart';
import 'legal_page.dart';

class SignInFrame extends StatelessWidget {
  const SignInFrame({
    super.key,
    required this.title,
    required this.children,
    this.subtitle,
  });

  final String title;
  final String? subtitle;
  final List<Widget> children;

  void _openLegal(BuildContext context, LegalDocumentKind document) {
    Navigator.of(context).push(
      MaterialPageRoute<void>(
        builder: (BuildContext context) =>
            ControlCentreLegalPage(document: document),
      ),
    );
  }

  @override
  Widget build(BuildContext context) => Scaffold(
    backgroundColor: Cc.accentSoft,
    body: Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(16),
        child: ConstrainedBox(
          constraints: const BoxConstraints(maxWidth: 420),
          child: Container(
            padding: const EdgeInsets.fromLTRB(28, 28, 28, 20),
            decoration: BoxDecoration(
              color: Colors.white,
              borderRadius: BorderRadius.circular(16),
              border: Border.all(color: Cc.line),
              boxShadow: const <BoxShadow>[
                BoxShadow(
                  color: Color(0x14000000),
                  blurRadius: 32,
                  offset: Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  children: <Widget>[
                    Container(
                      width: 36,
                      height: 36,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: Cc.accent,
                        borderRadius: BorderRadius.circular(8),
                      ),
                      child: const Text(
                        'S',
                        style: TextStyle(
                          color: Colors.white,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 12),
                    const Flexible(
                      child: Text(
                        'Scoot Sales Control Centre',
                        style: TextStyle(
                          fontSize: 16,
                          fontWeight: FontWeight.w700,
                          color: Cc.ink,
                        ),
                      ),
                    ),
                  ],
                ),
                const SizedBox(height: 24),
                Semantics(
                  header: true,
                  child: Text(
                    title,
                    style: const TextStyle(
                      fontSize: 22,
                      fontWeight: FontWeight.w800,
                      color: Cc.ink,
                    ),
                  ),
                ),
                if (subtitle != null) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(subtitle!, style: Cc.small),
                ],
                const SizedBox(height: 22),
                ...children,
                const SizedBox(height: 8),
                Wrap(
                  alignment: WrapAlignment.center,
                  children: <Widget>[
                    TextButton(
                      onPressed: () =>
                          _openLegal(context, LegalDocumentKind.privacyPolicy),
                      child: const Text('Privacy Policy'),
                    ),
                    TextButton(
                      onPressed: () => _openLegal(
                        context,
                        LegalDocumentKind.termsAndConditions,
                      ),
                      child: const Text('Terms & Conditions'),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ),
      ),
    ),
  );
}

class SignInPage extends StatefulWidget {
  const SignInPage({super.key, required this.auth});

  final StaffAuth auth;

  @override
  State<SignInPage> createState() => _SignInPageState();
}

class _SignInPageState extends State<SignInPage> {
  final TextEditingController _email = TextEditingController();
  final TextEditingController _password = TextEditingController();
  final TextEditingController _code = TextEditingController();
  bool _showPassword = false, _useBackup = false, _remember = false;

  StaffAuth get _auth => widget.auth;

  @override
  void dispose() {
    _email.dispose();
    _password.dispose();
    _code.dispose();
    super.dispose();
  }

  String? _hint;

  Future<void> _submitPassword() async {
    if (_email.text.trim().isEmpty || _password.text.isEmpty) {
      setState(
        () => _hint = _email.text.trim().isEmpty
            ? 'Enter your staff email, then your password.'
            : 'Enter your password.',
      );
      return;
    }
    if (_hint != null) setState(() => _hint = null);
    await _auth.signIn(_email.text, _password.text);
    if (_auth.step != StaffAuthStep.signedOut) {
      _password.clear();
    }
  }

  void _submitCode() {
    final String value = _code.text.trim();
    if (value.isEmpty) {
      setState(
        () => _hint = _useBackup
            ? 'Enter one of your backup codes.'
            : 'Enter the 6-digit code from your email.',
      );
      return;
    }
    if (_hint != null) setState(() => _hint = null);
    if (_useBackup) {
      _auth.verify(backupCode: value, remember: _remember);
    } else {
      _auth.verify(code: value, remember: _remember);
    }
    _code.clear();
  }

  List<Widget> _feedback() => <Widget>[
    if (_hint != null) ...<Widget>[
      CcBanner(text: _hint!, tone: Tone.warn),
      const SizedBox(height: 12),
    ],
    if (_auth.error != null) ...<Widget>[
      CcBanner(text: _auth.error!, tone: Tone.danger),
      const SizedBox(height: 12),
    ],
    if (_auth.notice != null) ...<Widget>[
      CcBanner(text: _auth.notice!, tone: Tone.info),
      if (_auth.passwordNoticeEmail != null)
        TextButton(
          onPressed: _auth.busy
              ? null
              : () {
                  final String address = _auth.passwordNoticeEmail!;
                  _auth.passwordNoticeEmail = null;
                  _auth.forgotPassword(address);
                },
          child: const Text('Send reset link'),
        ),
      const SizedBox(height: 12),
    ],
  ];

  Widget _busyLabel(String text) => _auth.busy
      ? const SizedBox(
          width: 18,
          height: 18,
          child: CircularProgressIndicator(strokeWidth: 2),
        )
      : Text(text);

  Widget _passwordStep() => SignInFrame(
    title: 'Sign in',
    subtitle: 'Use your staff email.',
    children: <Widget>[
      ..._feedback(),
      TextField(
        controller: _email,
        keyboardType: TextInputType.emailAddress,
        autofillHints: const <String>[AutofillHints.username],
        decoration: const InputDecoration(labelText: 'Email'),
        textInputAction: TextInputAction.next,
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _password,
        obscureText: !_showPassword,
        autofillHints: const <String>[AutofillHints.password],
        decoration: InputDecoration(
          labelText: 'Password',
          suffixIcon: IconButton(
            tooltip: _showPassword ? 'Hide password' : 'Show password',
            onPressed: () => setState(() => _showPassword = !_showPassword),
            icon: Icon(
              _showPassword ? Icons.visibility_off : Icons.visibility,
              size: 20,
            ),
          ),
        ),
        onSubmitted: (_) => _submitPassword(),
      ),
      Align(
        alignment: Alignment.centerRight,
        child: TextButton(
          onPressed: _auth.busy
              ? null
              : () => _auth.forgotPassword(_email.text),
          child: const Text('Forgot password?'),
        ),
      ),
      const SizedBox(height: 4),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _auth.busy ? null : _submitPassword,
        child: _busyLabel('Continue'),
      ),
      const SizedBox(height: 14),
      const Row(
        children: <Widget>[
          Expanded(child: Divider()),
          Padding(
            padding: EdgeInsets.symmetric(horizontal: 12),
            child: Text('or', style: Cc.small),
          ),
          Expanded(child: Divider()),
        ],
      ),
      const SizedBox(height: 14),
      GoogleSignInButton(onPressed: _auth.busy ? null : _auth.signInWithGoogle),
    ],
  );

  Widget _codeStep() => SignInFrame(
    title: 'Check your email',
    children: <Widget>[
      ..._feedback(),
      Text(
        _useBackup
            ? 'Enter one of your backup codes. Each one works once.'
            : _auth.codeNotSent
            ? 'You can use a backup code instead.'
            : _auth.sending
            ? 'The code is on its way to ${_auth.maskedTo}.'
            : 'We sent a 6-digit code to ${_auth.maskedTo}.',
      ),
      const SizedBox(height: 14),
      TextField(
        controller: _code,
        autofocus: true,
        keyboardType: _useBackup ? TextInputType.text : TextInputType.number,
        maxLength: _useBackup ? 14 : 6,
        decoration: InputDecoration(
          labelText: _useBackup ? 'Backup code' : 'Code',
          helperText: _useBackup ? 'Looks like abcd-2345-wxyz' : null,
        ),
        onSubmitted: (_) => _submitCode(),
      ),
      CheckboxListTile(
        value: _remember,
        onChanged: _auth.busy
            ? null
            : (bool? value) => setState(() => _remember = value ?? false),
        activeColor: Cc.accent,
        contentPadding: EdgeInsets.zero,
        controlAffinity: ListTileControlAffinity.leading,
        title: const Text('Keep me signed in on this device for 30 days'),
      ),
      const SizedBox(height: 8),
      FilledButton(
        style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
        onPressed: _auth.busy ? null : _submitCode,
        child: _busyLabel('Sign in'),
      ),
      const SizedBox(height: 8),
      Wrap(
        alignment: WrapAlignment.spaceBetween,
        children: <Widget>[
          if (_useBackup || _auth.canUseBackupCode)
            TextButton(
              onPressed: _auth.busy
                  ? null
                  : () => setState(() {
                      _useBackup = !_useBackup;
                      _code.clear();
                    }),
              child: Text(
                _useBackup ? 'Use the emailed code' : 'Use a backup code',
              ),
            ),
          if (!_useBackup)
            TextButton(
              onPressed: _auth.busy ? null : _auth.requestCode,
              child: const Text('Send a new code'),
            ),
          TextButton(
            onPressed: _auth.busy ? null : _auth.cancelCode,
            child: const Text('Back'),
          ),
        ],
      ),
    ],
  );

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _auth,
    builder: (BuildContext context, Widget? _) =>
        _auth.step == StaffAuthStep.code ? _codeStep() : _passwordStep(),
  );
}
