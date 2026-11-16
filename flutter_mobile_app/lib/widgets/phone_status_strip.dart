import 'package:flutter/material.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';

import '../providers/connectivity_provider.dart';
import '../providers/gps_provider.dart';

class PhoneStatusStrip extends StatelessWidget {
  const PhoneStatusStrip({
    super.key,
    this.pendingCount = 0,
    this.hasPendingWrites = false,
    this.isFromCache = false,
  });

  final int pendingCount;
  final bool hasPendingWrites;
  final bool isFromCache;

  @override
  Widget build(BuildContext context) {
    final bool online = context.watch<ConnectivityProvider>().isOnline;
    final GpsProvider gps = context.watch<GpsProvider>();
    final int waiting = pendingCount < 0 ? 0 : pendingCount;
    final ScootSyncStatus sync = !online
        ? const ScootSyncStatus.offline('Updates stay on this phone')
        : waiting > 0
        ? ScootSyncStatus.sending(waiting)
        : hasPendingWrites
        ? const ScootSyncStatus.sending(1)
        : isFromCache
        ? const ScootSyncStatus.cached('this phone')
        : const ScootSyncStatus.synced('Updates are safe');
    final double? accuracy = gps.reliableCurrentPosition?.accuracy;
    final ScootGpsStatus status = gps.hasLocationProblem
        ? const ScootGpsStatus.off()
        : accuracy != null
        ? ScootGpsStatus.fix(accuracy.round())
        : gps.hasActiveWorkSession
        ? ScootGpsStatus.fix(0)
        : const ScootGpsStatus.workNotStarted();
    return MediaQuery.withClampedTextScaling(
      maxScaleFactor: 1.0,
      child: ScootStatusStrip(
        sync: sync,
        gps: status,
        onTap: () => showModalBottomSheet<void>(
          context: context,
          builder: (BuildContext sheet) => SafeArea(
            child: Padding(
              padding: const EdgeInsets.all(20),
              child: Text(gps.statusMessage),
            ),
          ),
        ),
      ),
    );
  }
}
