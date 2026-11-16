import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../screens/legal_document_screen.dart';

class SignInView extends StatelessWidget {
  const SignInView({
    super.key,
    required this.formKey,
    required this.emailController,
    required this.passwordController,
    required this.passwordFocus,
    required this.obscurePassword,
    required this.onToggleObscure,
    required this.loading,
    required this.onSubmit,
    required this.rememberMe,
    required this.onRememberMe,
    required this.onForgotPassword,
    this.errorText,
    this.offline = false,
    this.onInvitation,
    this.company,
    this.devQuickSignIn,
    this.productTitle,
  });

  final GlobalKey<FormState> formKey;
  final TextEditingController emailController;
  final TextEditingController passwordController;
  final FocusNode passwordFocus;
  final bool obscurePassword;
  final VoidCallback onToggleObscure;
  final bool loading;
  final VoidCallback onSubmit;
  final bool rememberMe;
  final ValueChanged<bool> onRememberMe;
  final VoidCallback onForgotPassword;
  final String? errorText;
  final bool offline;
  final VoidCallback? onInvitation;
  final Widget? company;
  final Widget? devQuickSignIn;
  final String? productTitle;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Scaffold(
      backgroundColor: c.page,
      resizeToAvoidBottomInset: true,
      body: SafeArea(
        child: SingleChildScrollView(
          keyboardDismissBehavior: ScrollViewKeyboardDismissBehavior.onDrag,
          padding: const EdgeInsets.all(ScootSpace.phoneGutter),
          child: Center(
            child: ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 440),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.stretch,
                children: <Widget>[
                  const SizedBox(height: 8),
                  _BrandRow(productTitle: productTitle),
                  const SizedBox(height: 20),
                  Container(
                    padding: const EdgeInsets.all(20),
                    decoration: BoxDecoration(
                      color: c.card,
                      border: Border.all(color: c.line),
                      borderRadius: ScootRadius.cardAll,
                    ),
                    child: _form(context, c),
                  ),
                  const SizedBox(height: 12),
                  ?company,
                  ?devQuickSignIn,
                  const LegalDocumentLinks(),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }

  Widget _form(BuildContext context, ScootColors c) {
    return AutofillGroup(
      child: Form(
        key: formKey,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                'Sign in',
                style: ScootType.h1.copyWith(color: c.ink),
              ),
            ),
            const SizedBox(height: 4),
            Text(
              'Use the work email your manager set up for you.',
              style: ScootType.body.copyWith(color: c.text2),
            ),
            if (offline) ...<Widget>[
              const SizedBox(height: 12),
              ScootNotice(
                tone: ScootTone.warning,
                icon: ScootIcons.cloudOff,
                title: 'No connection',
                message:
                    'Sign-in needs the internet. Your saved work stays on this phone.',
              ),
            ],
            const SizedBox(height: 16),
            _label('Email', c),
            TextFormField(
              controller: emailController,
              keyboardType: TextInputType.emailAddress,
              textInputAction: TextInputAction.next,
              onEditingComplete: passwordFocus.requestFocus,
              autofillHints: const <String>[AutofillHints.email],
              decoration: const InputDecoration(hintText: 'name@company.com'),
              validator: (String? value) {
                if (value == null || value.trim().isEmpty) {
                  return 'Please enter your email address';
                }
                final String t = value.trim();
                if (!t.contains('@') || !t.contains('.')) {
                  return 'Please enter a valid email address';
                }
                return null;
              },
            ),
            const SizedBox(height: 16),
            _label('Password', c),
            TextFormField(
              controller: passwordController,
              focusNode: passwordFocus,
              obscureText: obscurePassword,
              textInputAction: TextInputAction.done,
              autofillHints: const <String>[AutofillHints.password],
              onFieldSubmitted: (_) {
                if (!loading) onSubmit();
              },
              decoration: InputDecoration(
                hintText: 'Your password',
                suffixIcon: IconButton(
                  icon: Icon(
                    obscurePassword
                        ? Icons.visibility_outlined
                        : Icons.visibility_off_outlined,
                    size: 20,
                  ),
                  tooltip: obscurePassword ? 'Show password' : 'Hide password',
                  onPressed: onToggleObscure,
                ),
              ),
              validator: (String? value) {
                if (value == null || value.isEmpty) {
                  return 'Please enter your password';
                }
                return null;
              },
            ),
            if (errorText != null && errorText!.isNotEmpty) ...<Widget>[
              const SizedBox(height: 12),
              ScootNotice(
                tone: ScootTone.danger,
                icon: ScootIcons.error,
                message: errorText!,
                liveRegion: true,
              ),
            ],
            const SizedBox(height: 8),
            Wrap(
              alignment: WrapAlignment.spaceBetween,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                InkWell(
                  onTap: () => onRememberMe(!rememberMe),
                  child: ConstrainedBox(
                    constraints: const BoxConstraints(
                      minHeight: ScootSize.phoneTarget,
                    ),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Checkbox(
                          value: rememberMe,
                          onChanged: (bool? v) => onRememberMe(v ?? false),
                        ),
                        Text(
                          'Remember me',
                          style: ScootType.small.copyWith(color: c.text2),
                        ),
                        const SizedBox(width: 8),
                      ],
                    ),
                  ),
                ),
                TextButton(
                  onPressed: onForgotPassword,
                  child: const Text('Forgot password?'),
                ),
              ],
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const Key('sign-in-button'),
              onPressed: loading ? null : onSubmit,
              style: FilledButton.styleFrom(
                minimumSize: const Size.fromHeight(ScootSize.primaryButton),
              ),
              child: loading
                  ? const Row(
                      mainAxisAlignment: MainAxisAlignment.center,
                      children: <Widget>[
                        SizedBox(
                          width: 18,
                          height: 18,
                          child: CircularProgressIndicator(
                            strokeWidth: 2,
                            color: Colors.white,
                          ),
                        ),
                        SizedBox(width: 10),
                        Text('Signing in'),
                      ],
                    )
                  : const Text('Sign in'),
            ),
            if (onInvitation != null) ...<Widget>[
              const SizedBox(height: 12),
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
              const SizedBox(height: 12),
              OutlinedButton.icon(
                key: const Key('have-invitation'),
                onPressed: loading ? null : onInvitation,
                style: OutlinedButton.styleFrom(
                  minimumSize: const Size.fromHeight(ScootSize.primaryButton),
                ),
                icon: const Icon(ScootIcons.password, size: 20),
                label: const Text('I have an invitation code'),
              ),
            ],
            const SizedBox(height: 16),
            Text(
              'No account? Ask your manager to invite you.',
              textAlign: TextAlign.center,
              style: ScootType.small.copyWith(color: c.text2),
            ),
          ],
        ),
      ),
    );
  }

  Widget _label(String text, ScootColors c) => Padding(
    padding: const EdgeInsets.only(bottom: 6),
    child: Text(text, style: ScootType.smallStrong.copyWith(color: c.text2)),
  );
}

class _BrandRow extends StatelessWidget {
  const _BrandRow({this.productTitle});

  final String? productTitle;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Row(
      children: <Widget>[
        ClipRRect(
          borderRadius: BorderRadius.circular(8),
          child: SizedBox.square(
            dimension: 40,
            child: Image.asset(
              'lib/images/ScootSales-icon.png',
              fit: BoxFit.contain,
              errorBuilder: (BuildContext context, Object e, StackTrace? s) =>
                  Icon(ScootIcons.store, color: c.brandText),
            ),
          ),
        ),
        const SizedBox(width: 12),
        Expanded(
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                productTitle ?? 'Scoot Sales',
                key: productTitle == null ? null : const Key('product-title'),
                maxLines: 1,
                overflow: TextOverflow.ellipsis,
                style: ScootType.cardTitle.copyWith(color: c.ink),
              ),
              Text(
                'Faster orders, brighter business',
                style: ScootType.small.copyWith(color: c.text2),
              ),
            ],
          ),
        ),
      ],
    );
  }
}
