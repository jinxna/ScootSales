import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../widgets/cc_command.dart';
import '../widgets/cc_common.dart';
import 'signin_page.dart';

class InvitePage extends StatefulWidget {
  const InvitePage({
    super.key,
    required this.api,
    required this.token,
    required this.onDone,
  });

  final StaffApiClient api;
  final String token;
  final VoidCallback onDone;

  @override
  State<InvitePage> createState() => _InvitePageState();
}

class _InvitePageState extends State<InvitePage> {
  final TextEditingController _name = TextEditingController();
  final TextEditingController _password = TextEditingController();
  Loaded<StaffInviteInfo>? _invite;
  String? _error;
  bool _busy = false, _show = false;

  @override
  void initState() {
    super.initState();
    _check();
  }

  @override
  void dispose() {
    _name.dispose();
    _password.dispose();
    super.dispose();
  }

  Future<void> _check() async {
    final Loaded<StaffInviteInfo> loaded = await Loaded.of(
      widget.api.checkInvite(widget.token),
    );
    if (!mounted) return;
    setState(() {
      _invite = loaded;
      _name.text = loaded.value?.name ?? '';
    });
  }

  Future<void> _accept() async {
    if (_busy || _password.text.isEmpty) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    try {
      await widget.api.acceptInvite(
        widget.token,
        password: _password.text,
        name: _name.text,
      );
      if (!mounted) return;
      widget.onDone();
    } on StaffApiException catch (error) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = friendlyError(error);
      });
    }
  }

  @override
  Widget build(BuildContext context) {
    final Loaded<StaffInviteInfo>? invite = _invite;
    if (invite == null) {
      return const SignInFrame(
        title: 'Staff invitation',
        children: <Widget>[Center(child: CircularProgressIndicator())],
      );
    }
    if (invite.value == null) {
      return SignInFrame(
        title: 'Staff invitation',
        children: <Widget>[
          CcBanner(text: invite.error!, tone: Tone.danger),
          const SizedBox(height: 12),
          OutlinedButton(
            onPressed: widget.onDone,
            child: const Text('Go to sign in'),
          ),
        ],
      );
    }
    final StaffInviteInfo info = invite.value!;
    return SignInFrame(
      title: 'Accept your invitation',
      children: <Widget>[
        Text(
          'You are invited to the Control Centre as ${roleLabel(info.role)}.',
        ),
        const SizedBox(height: 4),
        Text(info.email, style: const TextStyle(fontWeight: FontWeight.w700)),
        const SizedBox(height: 16),
        if (_error != null) ...<Widget>[
          CcBanner(text: _error!, tone: Tone.danger),
          const SizedBox(height: 12),
        ],
        TextField(
          controller: _name,
          decoration: const InputDecoration(labelText: 'Your name'),
        ),
        const SizedBox(height: 14),
        TextField(
          controller: _password,
          obscureText: !_show,
          decoration: InputDecoration(
            labelText: 'Choose a password',
            suffixIcon: IconButton(
              tooltip: _show ? 'Hide password' : 'Show password',
              onPressed: () => setState(() => _show = !_show),
              icon: Icon(
                _show ? Icons.visibility_off : Icons.visibility,
                size: 20,
              ),
            ),
          ),
          onSubmitted: (_) => _accept(),
        ),
        const SizedBox(height: 16),
        FilledButton(
          style: FilledButton.styleFrom(minimumSize: const Size.fromHeight(48)),
          onPressed: _busy ? null : _accept,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : const Text('Create my account'),
        ),
      ],
    );
  }
}
