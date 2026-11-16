import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';

import '../../../models/user_profile.dart';
import '../../../services/account_lockout_service.dart';
import '../widgets/cms_panel.dart';
import '../../../widgets/slow_loading.dart';

class AccountLockoutsPage extends StatefulWidget {
  const AccountLockoutsPage({super.key, required this.currentUser});

  final UserProfile currentUser;

  @override
  State<AccountLockoutsPage> createState() => _AccountLockoutsPageState();
}

class _AccountLockoutsPageState extends State<AccountLockoutsPage> {
  final Set<String> _unlocking = <String>{};
  late final Stream<QuerySnapshot<Map<String, dynamic>>> _requests =
      FirebaseFirestore.instance
          .collection(AccountLockoutService.requestsCollection)
          .orderBy('createdAt', descending: true)
          .limit(200)
          .snapshots();

  Future<void> _unlock(String requestId) async {
    if (!_unlocking.add(requestId)) return;
    setState(() {});
    try {
      await AccountLockoutService.instance.unlockRequest(
        requestId: requestId,
        actor: widget.currentUser,
      );
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Unlocked. This device can try signing in again.'),
        ),
      );
    } catch (_) {
      if (!mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Could not unlock. Check your connection and try again.',
          ),
        ),
      );
    } finally {
      _unlocking.remove(requestId);
      if (mounted) setState(() {});
    }
  }

  String _when(Object? value) {
    if (value is! Timestamp) return 'Time unavailable';
    final DateTime time = value.toDate().toLocal();
    String two(int number) => number.toString().padLeft(2, '0');
    return '${time.year}-${two(time.month)}-${two(time.day)} '
        '${two(time.hour)}:${two(time.minute)}';
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.currentUser.isAdmin || !widget.currentUser.isActive) {
      return const Center(child: Text('An active admin account is required.'));
    }
    return CmsPanel(
      title: 'Account Lockouts',
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          const Padding(
            padding: EdgeInsets.all(16),
            child: Text(
              'These are unverified reports of local login delays. '
              'The reported email does not prove account ownership. '
              'Unlock allows that reporting device to retry; credentials are still required.',
            ),
          ),
          const Divider(height: 1),
          Expanded(
            child: StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
              stream: _requests,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
                  ) {
                    if (snapshot.hasError) {
                      return const Center(
                        child: Text(
                          'Lock reports could not be loaded. Check your connection and access.',
                        ),
                      );
                    }
                    if (!snapshot.hasData) {
                      return const SlowLoading();
                    }
                    final List<QueryDocumentSnapshot<Map<String, dynamic>>>
                    rows = snapshot.data!.docs;
                    if (rows.isEmpty) {
                      return const Center(
                        child: Text('No reported login locks.'),
                      );
                    }
                    return ListView.separated(
                      itemCount: rows.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final QueryDocumentSnapshot<Map<String, dynamic>> row =
                            rows[index];
                        final Map<String, dynamic> data = row.data();
                        final bool unlocked = data['status'] == 'unlocked';
                        final bool pending = data['status'] == 'pending';
                        final bool busy = _unlocking.contains(row.id);
                        return ListTile(
                          leading: Icon(
                            unlocked ? Icons.lock_open : Icons.lock_outline,
                          ),
                          title: Text(
                            '${data['claimedEmail'] ?? 'Unknown reported email'}',
                          ),
                          subtitle: Text(
                            'Reported ${_when(data['createdAt'])} · ${data['client']}\n'
                            '${unlocked ? 'Unlocked ${_when(data['reviewedAt'])}' : 'Local delay until ${_when(data['localLockedUntil'])}'}',
                          ),
                          isThreeLine: true,
                          trailing: unlocked
                              ? const Text('Unlocked')
                              : FilledButton(
                                  onPressed: pending && !busy
                                      ? () => _unlock(row.id)
                                      : null,
                                  child: Text(busy ? 'Unlocking…' : 'Unlock'),
                                ),
                        );
                      },
                    );
                  },
            ),
          ),
        ],
      ),
    );
  }
}
