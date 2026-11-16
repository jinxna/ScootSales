import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';

import '../providers/gps_provider.dart';
import '../services/battery_saver_monitor.dart';
import '../services/company_api.dart';
import '../services/company_lifecycle_monitor.dart';
import '../services/gps_backlog.dart';
import '../services/held_work.dart';
import 'device_notice_banners.dart';
import 'location_status_banner.dart';
import 'rejected_order_banner.dart';

ScootActionBannerData? pickHomeBanner({
  ScootActionBannerData? location,
  ScootActionBannerData? rejectedOrder,
  int needsAttention = 0,
  VoidCallback? onReviewAttention,
  Duration? clockOffset,
  bool batterySaver = false,
  String gpsBacklog = '',
  int uploadedCount = 0,
  VoidCallback? onDismissUploaded,
  VoidCallback? onDismissBacklog,
}) {
  return ScootActionBanner.pick(<ScootActionBannerData>[
    ?location,
    ?rejectedOrder,
    if (needsAttention > 0)
      ScootActionBannerData(
        priority: ScootBannerPriority.workNeedsAttention,
        title: needsAttention == 1
            ? '1 item needs attention'
            : '$needsAttention items need attention',
        message:
            'Your work is kept on this phone. Send it again or remove it.',
        actionLabel: 'Review',
        onAction: onReviewAttention,
      ),
    if (uploadedCount > 0)
      ScootActionBannerData(
        priority: ScootBannerPriority.companyActiveAgain,
        title: 'The company is active again',
        message: uploadedWorkNotice(uploadedCount),
        actionLabel: 'Dismiss',
        onAction: onDismissUploaded,
      ),
    if (clockOffset != null && clockOffset.abs() >= kHeldWorkSkew)
      ScootActionBannerData(
        priority: ScootBannerPriority.clockWrong,
        title: 'Phone clock is wrong',
        message: clockOffsetNotice(clockOffset),
      ),
    if (batterySaver)
      const ScootActionBannerData(
        priority: ScootBannerPriority.batterySaver,
        title: 'Battery saver is on',
        message: batterySaverNotice,
      ),
    if (gpsBacklog.isNotEmpty)
      ScootActionBannerData(
        priority: ScootBannerPriority.gpsBacklog,
        title: 'Location points were not sent',
        message: gpsBacklog,
        actionLabel: 'Dismiss',
        onAction: onDismissBacklog,
      ),
  ]);
}

class HomeActionBanner extends StatefulWidget {
  const HomeActionBanner({
    super.key,
    this.onViewOrders,
    this.onReviewAttention,
    this.batterySaver,
  });

  final VoidCallback? onViewOrders;
  final VoidCallback? onReviewAttention;
  final BatterySaverMonitor? batterySaver;

  @override
  State<HomeActionBanner> createState() => _HomeActionBannerState();
}

class _HomeActionBannerState extends State<HomeActionBanner> {
  final LocationProbe _probe = LocationProbe();
  Stream<QuerySnapshot<Map<String, dynamic>>>? _rejected;
  DateTime? _lastSeen;

  BatterySaverMonitor get _battery =>
      widget.batterySaver ?? BatterySaverMonitor.instance;

  @override
  void initState() {
    super.initState();
    _probe.begin();
    _battery.start();
    _rejected = rejectedOrderStream();
    RejectedOrderBanner.seenRevision.addListener(_loadSeen);
    unawaited(_loadSeen());
  }

  @override
  void dispose() {
    RejectedOrderBanner.seenRevision.removeListener(_loadSeen);
    _probe.dispose();
    super.dispose();
  }

  Future<void> _loadSeen() async {
    final DateTime? seen = await rejectedOrdersLastSeen();
    if (mounted) setState(() => _lastSeen = seen);
  }

  @override
  Widget build(BuildContext context) {
    final GpsProvider gps = context.watch<GpsProvider>();
    final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor.instance;
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _rejected,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<QuerySnapshot<Map<String, dynamic>>> snapshot,
          ) {
            return ListenableBuilder(
              listenable: Listenable.merge(<Listenable>[
                _probe,
                _battery,
                CompanyApi.clockOffset,
                gpsBacklogNotice,
                monitor,
              ]),
              builder: (BuildContext context, Widget? _) {
                final ScootActionBannerData? data = pickHomeBanner(
                  location: _probe.bannerData(gps, context),
                  rejectedOrder: rejectedOrderBannerData(
                    snapshot.data?.docs ?? const [],
                    _lastSeen,
                    widget.onViewOrders,
                  ),
                  needsAttention: monitor.counts.rejected,
                  onReviewAttention: widget.onReviewAttention,
                  clockOffset: CompanyApi.clockOffset.value,
                  batterySaver: _battery.isOn,
                  gpsBacklog: gpsBacklogNotice.value,
                  uploadedCount: monitor.uploadedCount,
                  onDismissUploaded: monitor.dismissUploaded,
                  onDismissBacklog: () => gpsBacklogNotice.value = '',
                );
                if (data == null) return const SizedBox.shrink();
                return Padding(
                  padding: const EdgeInsets.fromLTRB(
                    ScootSpace.phoneGutter,
                    12,
                    ScootSpace.phoneGutter,
                    0,
                  ),
                  child: ScootActionBanner(data: data),
                );
              },
            );
          },
    );
  }
}
