import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../services/battery_saver_monitor.dart';
import '../services/company_api.dart';
import '../services/company_lifecycle_monitor.dart';
import '../services/gps_backlog.dart';
import '../services/held_work.dart';
import 'location_status_banner.dart';

String clockOffsetNotice(Duration offset) {
  final int minutes = offset.inMinutes.abs();
  final String direction = offset.isNegative ? 'ahead of' : 'behind';
  return 'This phone clock is about $minutes minutes $direction the server. '
      'Set date and time to automatic so your work is recorded correctly.';
}

String uploadedWorkNotice(int count) =>
    '$count saved ${count == 1 ? 'item was' : 'items were'} sent now that the '
    'company is active again.';

const String batterySaverNotice =
    'Battery saver is on. It may stop location tracking when the app is in '
    'the background. Turn it off while you work.';

class DeviceNoticeBanners extends StatefulWidget {
  const DeviceNoticeBanners({super.key, this.batterySaver});

  final BatterySaverMonitor? batterySaver;

  @override
  State<DeviceNoticeBanners> createState() => _DeviceNoticeBannersState();
}

class _DeviceNoticeBannersState extends State<DeviceNoticeBanners>
    with WidgetsBindingObserver {
  BatterySaverMonitor get _battery =>
      widget.batterySaver ?? BatterySaverMonitor.instance;

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _battery.start();
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(_battery.refresh());
  }

  int _shown = 0;

  @override
  Widget build(BuildContext context) {
    final CompanyLifecycleMonitor monitor = CompanyLifecycleMonitor.instance;
    return ListenableBuilder(
      listenable: Listenable.merge(<Listenable>[
        _battery,
        CompanyApi.clockOffset,
        gpsBacklogNotice,
        monitor,
      ]),
      builder: (BuildContext context, Widget? _) {
        final Duration? offset = CompanyApi.clockOffset.value;
        final List<BannerCard> notices = <BannerCard>[
          if (offset != null && offset.abs() >= kHeldWorkSkew)
            BannerCard(
              icon: ScootIcons.clock,
              title: 'Phone clock is wrong',
              text: clockOffsetNotice(offset),
            ),
          if (_battery.isOn)
            const BannerCard(
              icon: Icons.battery_alert,
              text: batterySaverNotice,
            ),
          if (gpsBacklogNotice.value.isNotEmpty)
            BannerCard(
              icon: Icons.location_off_outlined,
              text: gpsBacklogNotice.value,
              action: 'Dismiss',
              onPressed: () async => gpsBacklogNotice.value = '',
            ),
          if (monitor.uploadedCount > 0)
            BannerCard(
              icon: ScootIcons.success,
              tone: ScootTone.success,
              text: uploadedWorkNotice(monitor.uploadedCount),
              action: 'Dismiss',
              onPressed: () async => monitor.dismissUploaded(),
            ),
        ];
        if (notices.isEmpty) return const SizedBox.shrink();
        final int others = notices.length - 1;
        return Column(
          children: <Widget>[
            notices[_shown % notices.length],
            if (others > 0)
              Align(
                alignment: Alignment.centerRight,
                child: Padding(
                  padding: const EdgeInsets.only(right: 16),
                  child: TextButton(
                    style: TextButton.styleFrom(
                      minimumSize: const Size(0, 32),
                      padding: const EdgeInsets.symmetric(horizontal: 8),
                      tapTargetSize: MaterialTapTargetSize.shrinkWrap,
                    ),
                    onPressed: () => setState(() => _shown++),
                    child: Text('+$others more'),
                  ),
                ),
              ),
          ],
        );
      },
    );
  }
}
