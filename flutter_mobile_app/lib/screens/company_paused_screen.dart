import 'package:flutter/material.dart';
import 'package:intl/intl.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';

import '../providers/auth_provider.dart';
import '../services/company_lifecycle_monitor.dart';
import '../widgets/phone_card.dart';
import '../widgets/phone_status_strip.dart';

String companyPausedHeldText(int stops, int orders, {bool otherWork = false}) {
  final int total = stops + orders;
  if (total == 0) {
    return otherWork
        ? 'Some work is held on this phone.'
        : 'No work is held on this phone.';
  }
  final List<String> parts = <String>[
    if (stops > 0) '$stops route ${stops == 1 ? 'update' : 'updates'}',
    if (orders > 0) '$orders ${orders == 1 ? 'order' : 'orders'}',
  ];
  return '$total ${total == 1 ? 'item is' : 'items are'} held on this phone: '
      '${parts.join(' and ')}.';
}

String companyPausedKeptText(String? state) => state == 'cancelled'
    ? 'Your work is kept on this phone. The company is cancelled, so it '
          'uploads only if the company is reactivated. Tell your manager.'
    : 'Your work is kept and will upload when the company is active again.';

String companyPausedRejectedText(int rejected) =>
    '$rejected ${rejected == 1 ? 'item was' : 'items were'} not accepted. '
    'Your manager can review ${rejected == 1 ? 'it' : 'them'}.';

class CompanyPausedScreen extends StatefulWidget {
  const CompanyPausedScreen({
    super.key,
    required this.monitor,
    this.onSignOut,
    this.showStatusStrip = true,
  });

  final CompanyLifecycleMonitor monitor;
  final VoidCallback? onSignOut;
  final bool showStatusStrip;

  @override
  State<CompanyPausedScreen> createState() => _CompanyPausedScreenState();
}

class _CompanyPausedScreenState extends State<CompanyPausedScreen> {
  bool _checking = false;

  Future<void> _check() async {
    setState(() => _checking = true);
    try {
      await widget.monitor.refresh();
    } finally {
      if (mounted) setState(() => _checking = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final DateTime? drainUntil = widget.monitor.lifecycle?.drainUntil
        ?.toLocal();
    final bool drainOpen =
        drainUntil != null && drainUntil.isAfter(DateTime.now());
    final int rejected = widget.monitor.counts.rejected;
    final bool hasHeldWork = widget.monitor.hasWorkToUpload;
    return ScootPhoneScaffold(
      appBar: const ScootPhoneAppBar(title: 'Company paused'),
      statusStrip: widget.showStatusStrip ? const PhoneStatusStrip() : null,
      body: ListView(
        padding: const EdgeInsets.all(ScootSpace.phoneGutter),
        children: <Widget>[
          const ScootNotice(
            tone: ScootTone.warning,
            icon: ScootIcons.paused,
            message:
                'Your company is paused by its admin or billing. '
                'You cannot start new work now.',
            liveRegion: true,
          ),
          const SizedBox(height: 12),
          PhoneCard(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  companyPausedHeldText(
                    widget.monitor.counts.stops,
                    widget.monitor.counts.orders,
                    otherWork: hasHeldWork,
                  ),
                  style: ScootType.bodyStrong.copyWith(color: c.ink),
                ),
                if (hasHeldWork || widget.monitor.counts.total > 0) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    companyPausedKeptText(widget.monitor.lifecycle?.state),
                    style: ScootType.body.copyWith(color: c.text2),
                  ),
                ],
                if (rejected > 0) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    companyPausedRejectedText(rejected),
                    style: ScootType.body.copyWith(color: c.text2),
                  ),
                ],
                if (drainOpen) ...<Widget>[
                  const SizedBox(height: 6),
                  Text(
                    'Work you did before the pause can upload until '
                    '${DateFormat('d MMM, HH:mm').format(drainUntil)}.',
                    style: ScootType.small.copyWith(color: c.muted),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
      primaryAction: ScootPrimaryActionBar(
        label: _checking ? 'Checking...' : 'Check again',
        icon: ScootIcons.refresh,
        onPressed: _checking ? null : _check,
        secondaryLabel: 'Sign out',
        onSecondary:
            widget.onSignOut ?? () => context.read<AuthProvider>().logout(),
      ),
    );
  }
}
