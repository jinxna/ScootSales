import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';

import '../providers/auth_provider.dart';
import '../providers/gps_provider.dart';
import '../services/held_work_sync.dart';
import '../widgets/phone_card.dart';
import 'profile_screen.dart' show confirmSignOut, uploadWaitingWork;

class DeleteAccountScreen extends StatefulWidget {
  const DeleteAccountScreen({super.key});

  @override
  State<DeleteAccountScreen> createState() => _DeleteAccountScreenState();
}

class _DeleteAccountScreenState extends State<DeleteAccountScreen> {
  final TextEditingController _password = TextEditingController();
  bool _busy = false;
  String _error = '';

  @override
  void dispose() {
    _password.dispose();
    super.dispose();
  }

  Future<void> _sendRequest(String uid) async {
    final DocumentReference<Map<String, dynamic>> reference = FirebaseFirestore
        .instance
        .collection('privacy_deletion_requests')
        .doc(uid);
    final DocumentSnapshot<Map<String, dynamic>> existing = await reference
        .get();
    if (!existing.exists) {
      await reference.set(<String, Object>{
        'requestType': 'account_deletion',
        'status': 'submitted',
        'createdAt': FieldValue.serverTimestamp(),
      });
    } else if (existing.data()?['status'] == 'rejected') {
      await reference.update(<String, Object>{
        'status': 'submitted',
        'createdAt': FieldValue.serverTimestamp(),
      });
    }
  }

  Future<void> _submit() async {
    final AuthProvider auth = context.read<AuthProvider>();
    final GpsProvider gps = context.read<GpsProvider>();
    final NavigatorState navigator = Navigator.of(context);
    final String? uid = auth.user?.uid;
    if (uid == null || uid.isEmpty) return;
    if (_password.text.isEmpty) {
      setState(() => _error = 'Enter your password.');
      return;
    }
    final HeldWorkSync sync = HeldWorkSync();
    if (await sync.hasWorkToUpload(uid)) {
      if (!mounted) return;
      final bool confirmed = await confirmSignOut(
        context,
        hasWork: () => sync.hasWorkToUpload(uid),
        upload: uploadWaitingWork,
        deletingAccount: true,
      );
      if (!confirmed || !mounted) return;
    }
    setState(() {
      _busy = true;
      _error = '';
    });
    final String? problem = await auth.reauthenticate(_password.text);
    if (problem != null) {
      if (!mounted) return;
      setState(() {
        _busy = false;
        _error = problem;
      });
      return;
    }
    try {
      await _sendRequest(uid);
    } catch (error) {
      if (!mounted) return;
      final bool refused =
          error is FirebaseException && error.code == 'permission-denied';
      setState(() {
        _busy = false;
        _error = refused
            ? (auth.user?.hasActiveAccount == false
                  ? 'Your account is suspended, so it cannot send this request. Ask your administrator to remove your profile.'
                  : 'The request was refused. Sign out, sign in again, and then request deletion. If it is refused again, contact your administrator.')
            : 'The request was not sent. Check the connection and try again.';
      });
      return;
    }
    if (!mounted) return;
    await showDialog<void>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: const Text('Request sent'),
        content: const Text(
          'Your company will turn off your sign-in and delete your account '
          'within 30 days. You are signed out now.',
        ),
        actions: <Widget>[
          FilledButton(
            onPressed: () => Navigator.pop(dialogContext),
            child: const Text('OK'),
          ),
        ],
      ),
    );
    try {
      await gps.endWork(uid: uid).timeout(const Duration(seconds: 6));
    } catch (_) {}
    await auth.logout();
    if (!navigator.mounted) return;
    navigator.popUntil((Route<dynamic> route) => route.isFirst);
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'Delete account',
        onBack: _busy ? null : () => Navigator.of(context).maybePop(),
      ),
      body: ListView(
        padding: const EdgeInsets.all(ScootSpace.phoneGutter),
        children: <Widget>[
          const ScootNotice(
            tone: ScootTone.danger,
            icon: ScootIcons.warning,
            message:
                'This starts the deletion of your account. You are signed out '
                'at once.',
          ),
          const PhoneSectionTitle('What is deleted'),
          PhoneCard(
            child: Text(
              'Your sign-in, name, email, phone number, photo and location '
              'history.',
              style: ScootType.body.copyWith(color: c.text2),
            ),
          ),
          const PhoneSectionTitle('What the company keeps'),
          PhoneCard(
            child: Text(
              'Orders, visits and signatures are company records. They stay. '
              'Your name on them becomes "Deleted user".',
              style: ScootType.body.copyWith(color: c.text2),
            ),
          ),
          const PhoneSectionTitle('When'),
          PhoneCard(
            child: Text(
              'Your data is deleted after 30 days. Your company administrator '
              'can delete it sooner or cancel the request.',
              style: ScootType.body.copyWith(color: c.text2),
            ),
          ),
          const PhoneSectionTitle('Confirm'),
          TextField(
            controller: _password,
            obscureText: true,
            enabled: !_busy,
            autofillHints: const <String>[AutofillHints.password],
            decoration: InputDecoration(
              labelText: 'Password',
              helperText: 'Enter your password to confirm.',
              errorText: _error.isEmpty ? null : _error,
            ),
            onSubmitted: (_) => _busy ? null : _submit(),
          ),
        ],
      ),
      primaryAction: ScootPrimaryActionBar(
        label: _busy ? 'Sending request...' : 'Request deletion',
        onPressed: _busy ? null : _submit,
        secondaryLabel: 'Cancel',
        onSecondary: _busy ? null : () => Navigator.of(context).maybePop(),
      ),
    );
  }
}
