String resolveMobileOrderStatus(Map<String, dynamic> data) {
  final bool cancelled = _isTrue(data['isCancelled']) ||
      _isTrue(data['cancelled']) ||
      _isTrue(data['canceled']) ||
      data['cancelledAt'] != null ||
      data['canceledAt'] != null;
  if (cancelled) return 'Cancelled';

  final bool rejected = _isTrue(data['isRejected']) ||
      _isTrue(data['rejected']) ||
      data['rejectedAt'] != null;
  if (rejected) return 'Rejected';

  final String rawStatus = _firstStatus(data);
  switch (rawStatus) {
    case 'cancelled':
    case 'canceled':
    case 'void':
      return 'Cancelled';
    case 'rejected':
    case 'reject':
      return 'Rejected';
    case 'approved':
    case 'accepted':
      return 'Approved';
    case 'completed':
      return 'Completed';
    case 'submitted':
    case 'synced':
    case 'sync_success':
    case 'pending':
    case 'pending_approval':
      return 'Submitted';
    case 'held_for_review':
      return 'Held for review';
    case 'queued':
    case 'pending_sync':
    case 'offline':
      return 'Queued';
    case 'draft':
    case 'in_progress':
    case 'pending_draft':
      return 'In Progress';
  }

  if (data['approvedAt'] != null) return 'Approved';
  if (data['submittedAt'] != null || data['submittedAtServer'] != null) {
    return 'Submitted';
  }
  return 'In Progress';
}

String _firstStatus(Map<String, dynamic> data) {
  for (final String key in const <String>[
    'status',
    'syncStatus',
    'submissionStatus',
    'approvalStatus',
    'state',
  ]) {
    final String value = '${data[key] ?? ''}'.trim().toLowerCase();
    if (value.isNotEmpty && value != 'null') return value;
  }
  return '';
}

bool _isTrue(Object? value) =>
    value == true || '${value ?? ''}'.trim().toLowerCase() == 'true';
