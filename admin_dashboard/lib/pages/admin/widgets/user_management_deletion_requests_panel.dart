import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../repositories/user_management_repository.dart';
import '../../../widgets/slow_loading.dart';

class _UiBadge extends StatelessWidget {
  const _UiBadge({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
      decoration: BoxDecoration(
        color: Theme.of(context).colorScheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          color: Theme.of(context).colorScheme.onSurfaceVariant,
          fontWeight: FontWeight.w700,
          fontSize: 12,
        ),
      ),
    );
  }
}

class UserManagementDeletionRequestsPanel extends StatelessWidget {
  const UserManagementDeletionRequestsPanel({
    super.key,
    required this.listHeight,
    required this.repository,
  });

  final double listHeight;
  final UserManagementRepository repository;

  static String _requestedLabel(Map<String, dynamic> data) {
    final Object? requestedAt = data['createdAt'];
    final Object? purgeAfter = data['purgeAfter'];
    final String requested = requestedAt is Timestamp
        ? 'Deletion requested ${_date(requestedAt)}'
        : 'Deletion requested';
    return purgeAfter is Timestamp
        ? '$requested. Can be restored until ${_date(purgeAfter)}, then deleted for good.'
        : requested;
  }

  static String _statusLabel(String status) {
    switch (status) {
      case 'submitted':
        return 'Requested';
      case 'reviewing':
        return 'Sign-in off, restorable';
      case 'completed':
        return 'Delete now sent';
      default:
        return status;
    }
  }

  static String _date(Timestamp value) {
    final DateTime date = value.toDate();
    final String month = date.month.toString().padLeft(2, '0');
    final String day = date.day.toString().padLeft(2, '0');
    return '${date.year}-$month-$day';
  }

  Future<void> _setStatus(
    BuildContext context,
    String uid,
    String status,
  ) async {
    if (status == 'completed') {
      final bool? confirmed = await showDialog<bool>(
        context: context,
        builder: (BuildContext dialogContext) => AlertDialog(
          title: const Text('Delete this account now?'),
          content: const Text(
            'Sign-in stops within the hour. The account stays in the user '
            'list marked "Deletion requested". You can restore it for 7 days '
            'with "Restore account". After 7 days the sign-in, name, email, '
            'phone, photo and location history are removed for good. Orders '
            'and visits stay with the name "Deleted user".',
          ),
          actions: <Widget>[
            TextButton(
              onPressed: () => Navigator.of(dialogContext).pop(false),
              child: const Text('Cancel'),
            ),
            FilledButton(
              onPressed: () => Navigator.of(dialogContext).pop(true),
              child: const Text('Delete now'),
            ),
          ],
        ),
      );
      if (confirmed != true) return;
    }

    try {
      await repository.updateDeletionRequestStatus(uid, status);
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Could not update this request.')),
      );
    }
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: repository.watchDeletionRequests(),
      builder:
          (
            BuildContext context,
            AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
          ) {
            final List<QueryDocumentSnapshot<Map<String, dynamic>>> requests =
                snapshot.data?.docs
                    .where(
                      (QueryDocumentSnapshot<Map<String, dynamic>> request) =>
                          request.data()['purgedAt'] == null,
                    )
                    .toList() ??
                <QueryDocumentSnapshot<Map<String, dynamic>>>[];
            requests.sort((
              QueryDocumentSnapshot<Map<String, dynamic>> left,
              QueryDocumentSnapshot<Map<String, dynamic>> right,
            ) {
              final Object? leftValue = left.data()['createdAt'];
              final Object? rightValue = right.data()['createdAt'];
              if (leftValue is Timestamp && rightValue is Timestamp) {
                return rightValue.compareTo(leftValue);
              }
              return left.id.compareTo(right.id);
            });
            final int pendingCount = requests.length;
            return ExpansionTile(
              tilePadding: const EdgeInsets.symmetric(horizontal: 12),
              childrenPadding: const EdgeInsets.only(bottom: 8),
              title: const Text('Account deletion requests'),
              subtitle: Text(
                snapshot.hasError
                    ? 'Could not load requests.'
                    : '$pendingCount open',
              ),
              children: <Widget>[
                SizedBox(
                  height: listHeight,
                  child: snapshot.hasError
                      ? const Center(child: Text('Request list unavailable.'))
                      : !snapshot.hasData
                      ? const SlowLoading()
                      : requests.isEmpty
                      ? const Center(child: Text('No requests.'))
                      : ListView.separated(
                          padding: const EdgeInsets.symmetric(horizontal: 8),
                          itemCount: requests.length,
                          separatorBuilder: (_, _) => const SizedBox(height: 8),
                          itemBuilder: (BuildContext context, int index) {
                            final QueryDocumentSnapshot<Map<String, dynamic>>
                            request = requests[index];
                            final Object? statusValue = request
                                .data()['status'];
                            final String status = statusValue is String
                                ? statusValue
                                : 'unknown';
                            return Container(
                              padding: const EdgeInsets.all(12),
                              decoration: BoxDecoration(
                                color: Theme.of(context).colorScheme.surface,
                                borderRadius: BorderRadius.circular(12),
                                border: Border.all(
                                  color: Theme.of(
                                    context,
                                  ).colorScheme.outlineVariant,
                                ),
                              ),
                              child: Column(
                                crossAxisAlignment: CrossAxisAlignment.start,
                                children: <Widget>[
                                  Row(
                                    children: <Widget>[
                                      Expanded(
                                        child: Text(
                                          'Account ID: ${request.id}',
                                          maxLines: 1,
                                          overflow: TextOverflow.ellipsis,
                                        ),
                                      ),
                                      const SizedBox(width: 8),
                                      _UiBadge(label: _statusLabel(status)),
                                    ],
                                  ),
                                  const SizedBox(height: 4),
                                  Text(_requestedLabel(request.data())),
                                  const SizedBox(height: 8),
                                  Wrap(
                                    spacing: 8,
                                    runSpacing: 4,
                                    children: <Widget>[
                                      if (status != 'completed')
                                        TextButton.icon(
                                          onPressed: () => _setStatus(
                                            context,
                                            request.id,
                                            'completed',
                                          ),
                                          icon: const Icon(ScootIcons.remove),
                                          label: const Text('Delete now'),
                                        ),
                                      TextButton.icon(
                                        onPressed: () => _setStatus(
                                          context,
                                          request.id,
                                          'rejected',
                                        ),
                                        icon: const Icon(ScootIcons.close),
                                        label: Text(
                                          status == 'submitted'
                                              ? 'Cancel request'
                                              : 'Restore account',
                                        ),
                                      ),
                                    ],
                                  ),
                                ],
                              ),
                            );
                          },
                        ),
                ),
              ],
            );
          },
    );
  }
}
