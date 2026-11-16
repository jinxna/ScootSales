import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import 'cc_command.dart';
import 'cc_common.dart';

String _deliveryText(String status) => switch (status) {
  'delivered' => 'Delivered',
  'soft_bounce' => 'Soft bounce',
  'hard_bounce' => 'Hard bounce',
  'blocked' => 'Blocked',
  'spam' => 'Marked as spam',
  _ => 'Invalid address',
};

class CompanyMailPanel extends StatefulWidget {
  const CompanyMailPanel({
    super.key,
    required this.api,
    required this.company,
    required this.canAct,
  });

  final StaffApiClient api;
  final StaffCompany company;
  final bool canAct;

  @override
  State<CompanyMailPanel> createState() => _CompanyMailPanelState();
}

class _CompanyMailPanelState extends State<CompanyMailPanel> {
  Loaded<List<StaffMailJob>>? _jobs;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Loaded<List<StaffMailJob>> loaded = await Loaded.of(
      widget.api.mailJobs(widget.company.tenantId),
    );
    if (mounted) setState(() => _jobs = loaded);
  }

  Future<void> _retry(StaffMailJob job) async {
    final bool uncertain = job.status == 'uncertain';
    final bool ok = await showCcConfirm(
      context,
      title: uncertain ? 'Retry mail that may already be sent' : 'Retry mail',
      message: uncertain
          ? 'The mail provider did not confirm whether this message was delivered, so ${job.recipient} may already have received it. Retrying can send a duplicate.'
          : job.isHeld
          ? 'This puts the held mail to ${job.recipient} back in the queue. It is sent when the mail service accepts it.'
          : 'This creates a new mail job for ${job.recipient} from the saved message. The failed job stays in the list.',
      confirmLabel: uncertain ? 'Retry despite duplicate risk' : 'Retry mail',
      danger: uncertain,
    );
    if (!ok || !mounted) return;
    await _command(
      () => widget.api.retryMailJob(
        widget.company.tenantId,
        job.jobId,
        confirmDuplicateRisk: uncertain,
      ),
      'The mail was queued again.',
    );
  }

  Future<void> _handled(StaffMailJob job) async {
    final bool ok = await showCcConfirm(
      context,
      title: 'Mark mail as handled',
      message:
          'This records that you dealt with the mail to ${job.recipient} outside the system. It does not send the mail again.',
      confirmLabel: 'Mark handled',
    );
    if (!ok || !mounted) return;
    await _command(
      () => widget.api.markMailJobHandled(widget.company.tenantId, job.jobId),
      'The mail was marked as handled.',
    );
  }

  Future<void> _command(Future<Object?> Function() call, String done) async {
    setState(() => _busy = true);
    final CmdResult result = await CmdResult.run(call, done: done);
    if (!mounted) return;
    setState(() => _busy = false);
    announce(context, result.ok ? done : result.message!);
    await _load();
  }

  Widget _row(StaffMailJob job) {
    final bool canRetry =
        !job.isOneTime &&
        job.needsAttention &&
        (job.isHeld || job.retriedAs == null);
    final bool canHandle = job.needsAttention && job.handledAt == null;
    final bool enabled = widget.canAct && !_busy;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Wrap(
            spacing: 12,
            runSpacing: 6,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              CcBadge(
                switch (job.status) {
                  'queued' => 'Queued',
                  'sending' => 'Sending',
                  'sent' => 'Sent',
                  'failed' => 'Failed',
                  'held' => 'Held',
                  _ => 'Uncertain',
                },
                tone: job.needsAttention
                    ? Tone.danger
                    : job.status == 'sent'
                    ? Tone.ok
                    : Tone.neutral,
              ),
              Text(
                '${mailKindLabel(job.kind)} to ${job.recipient}',
                style: const TextStyle(fontWeight: FontWeight.w600),
              ),
            ],
          ),
          const SizedBox(height: 4),
          Text(
            <String>[
              'Attempts ${job.attempts} of ${job.maxAttempts}',
              'Created ${dateTimeText(job.createdAt)}',
              'Updated ${dateTimeText(job.updatedAt)}',
              if (job.status == 'queued' && job.nextAttemptAt != null)
                'Next attempt ${dateTimeText(job.nextAttemptAt)}',
            ].join(' · '),
            style: Cc.small,
          ),
          if (job.isHeld && job.heldReason != null)
            Text('Held: ${heldReasonText(job.heldReason!)}', style: Cc.small),
          if (job.deliveryStatus != null)
            Padding(
              padding: const EdgeInsets.only(top: 4),
              child: Wrap(
                spacing: 8,
                runSpacing: 4,
                crossAxisAlignment: WrapCrossAlignment.center,
                children: <Widget>[
                  CcBadge(
                    _deliveryText(job.deliveryStatus!),
                    tone: switch (job.deliveryStatus!) {
                      'delivered' => Tone.ok,
                      'soft_bounce' => Tone.warn,
                      _ => Tone.danger,
                    },
                  ),
                  if (job.deliveryStatusAt != null)
                    Text(dateTimeText(job.deliveryStatusAt), style: Cc.small),
                ],
              ),
            ),
          if (job.attachmentName != null)
            Text('Attachment: ${job.attachmentName}', style: Cc.small),
          if (job.lastFailure != null && job.status != 'sent')
            Text(
              job.lastFailure!,
              style: const TextStyle(fontSize: 13, color: Cc.dangerFg),
            ),
          if (job.retriedAs != null)
            const Text('Retried as a new mail job.', style: Cc.small),
          if (job.handledAt != null)
            Text(
              'Handled by ${job.handledBy ?? 'staff'} on ${dateTimeText(job.handledAt)}.',
              style: Cc.small,
            ),
          if (canRetry || canHandle)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Wrap(
                spacing: 8,
                runSpacing: 6,
                children: <Widget>[
                  if (canRetry)
                    Semantics(
                      button: true,
                      enabled: enabled,
                      label: 'Retry mail to ${job.recipient}',
                      onTap: enabled ? () => _retry(job) : null,
                      excludeSemantics: true,
                      child: OutlinedButton.icon(
                        onPressed: enabled ? () => _retry(job) : null,
                        icon: const Icon(Icons.refresh, size: 18),
                        label: const Text('Retry'),
                      ),
                    ),
                  if (canHandle)
                    Semantics(
                      button: true,
                      enabled: enabled,
                      label: 'Mark mail to ${job.recipient} as handled',
                      onTap: enabled ? () => _handled(job) : null,
                      excludeSemantics: true,
                      child: TextButton.icon(
                        onPressed: enabled ? () => _handled(job) : null,
                        icon: const Icon(Icons.check, size: 18),
                        label: const Text('Mark handled'),
                      ),
                    ),
                ],
              ),
            ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final Loaded<List<StaffMailJob>>? loaded = _jobs;
    if (loaded == null) return const CcSkeleton(rows: 3);
    if (loaded.value == null) {
      return CcErrorState(
        what: 'emails',
        message: loaded.error!,
        onRetry: _load,
      );
    }
    final List<StaffMailJob> jobs = loaded.value!;
    return CcCard(
      title: 'Emails',
      child: jobs.isEmpty
          ? const CcEmptyState(
              title: 'No emails yet',
              message:
                  'Invoices, receipts and reminders sent to this company appear here.',
            )
          : Column(
              children: <Widget>[
                for (int i = 0; i < jobs.length; i++) ...<Widget>[
                  if (i > 0) const Divider(height: 1, color: Cc.line),
                  _row(jobs[i]),
                ],
              ],
            ),
    );
  }
}
