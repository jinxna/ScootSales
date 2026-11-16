import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:provider/provider.dart';
import 'package:scoot_design/scoot_design.dart';

import '../providers/auth_provider.dart';
import '../providers/gps_provider.dart';
import 'device_notice_banners.dart';

class LocationProbe extends ChangeNotifier with WidgetsBindingObserver {
  StreamSubscription<ServiceStatus>? _serviceSub;
  bool serviceOn = true;
  bool approximate = false;
  bool starting = false;
  bool _disposed = false;

  void begin() {
    WidgetsBinding.instance.addObserver(this);
    unawaited(refresh());
    try {
      _serviceSub = Geolocator.getServiceStatusStream().listen(
        (_) => unawaited(refresh()),
        onError: (_) {},
      );
    } catch (_) {}
  }

  @override
  void dispose() {
    _disposed = true;
    WidgetsBinding.instance.removeObserver(this);
    unawaited(_serviceSub?.cancel());
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed) unawaited(refresh());
  }

  Future<void> refresh() async {
    try {
      final bool on = await Geolocator.isLocationServiceEnabled();
      final LocationAccuracyStatus accuracy =
          await Geolocator.getLocationAccuracy();
      if (_disposed) return;
      serviceOn = on;
      approximate = accuracy == LocationAccuracyStatus.reduced;
      notifyListeners();
    } catch (_) {}
  }

  Future<void> startWork(BuildContext context) async {
    starting = true;
    notifyListeners();
    try {
      await context.read<GpsProvider>().startTracking(
        user: context.read<AuthProvider>().user,
        explicit: true,
      );
    } finally {
      if (!_disposed) {
        starting = false;
        notifyListeners();
      }
    }
  }

  ScootActionBannerData? bannerData(GpsProvider gps, BuildContext context) {
    if (!serviceOn) {
      final bool iosSettings =
          !kIsWeb && defaultTargetPlatform == TargetPlatform.iOS;
      return ScootActionBannerData(
        priority: ScootBannerPriority.locationOff,
        title: 'Location is off',
        message: iosSettings
            ? 'Location Services are off. Open Settings > Privacy & Security > Location Services and turn them on.'
            : 'Turn on location to check in at a stop.',
        actionLabel: iosSettings ? null : 'Turn on',
        onAction: iosSettings ? null : Geolocator.openLocationSettings,
      );
    }
    if (approximate) {
      return const ScootActionBannerData(
        priority: ScootBannerPriority.preciseLocationOff,
        title: 'Precise location is off',
        message: 'Check-ins need precise location.',
        actionLabel: 'Settings',
        onAction: Geolocator.openAppSettings,
      );
    }
    if (gps.trackingEnabled && !gps.hasArrivalReadySession) {
      return ScootActionBannerData(
        priority: ScootBannerPriority.workNotStarted,
        title: 'Work not started',
        message: 'Start work to share your location with your team.',
        actionLabel: starting ? 'Starting...' : 'Start',
        onAction: starting ? null : () => unawaited(startWork(context)),
      );
    }
    return null;
  }
}

class LocationStatusBanner extends StatefulWidget {
  const LocationStatusBanner({super.key});

  @override
  State<LocationStatusBanner> createState() => _LocationStatusBannerState();
}

class _LocationStatusBannerState extends State<LocationStatusBanner> {
  final LocationProbe _probe = LocationProbe();

  @override
  void initState() {
    super.initState();
    _probe.begin();
  }

  @override
  void dispose() {
    _probe.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      children: <Widget>[
        const DeviceNoticeBanners(),
        ListenableBuilder(
          listenable: _probe,
          builder: (BuildContext context, Widget? _) => _locationCard(context),
        ),
      ],
    );
  }

  Widget _locationCard(BuildContext context) {
    final GpsProvider gps = context.watch<GpsProvider>();
    final ScootActionBannerData? data = _probe.bannerData(gps, context);
    if (data == null) return const SizedBox.shrink();
    return BannerCard(
      icon: data.icon,
      tone: data.tone,
      title: data.title,
      text: data.message ?? '',
      action: data.actionLabel,
      onPressed: data.onAction == null ? null : () async => data.onAction!(),
    );
  }
}

class BannerCard extends StatelessWidget {
  const BannerCard({
    super.key,
    required this.icon,
    required this.text,
    this.title,
    this.tone = ScootTone.warning,
    this.action,
    this.onPressed,
  });

  final IconData icon;
  final String text;
  final String? title;
  final ScootTone tone;
  final String? action;
  final Future<dynamic> Function()? onPressed;

  @override
  Widget build(BuildContext context) {
    final ScootToneColors t = ScootColors.of(context).tone(tone);
    return Container(
      margin: const EdgeInsets.fromLTRB(16, 8, 16, 4),
      padding: const EdgeInsets.fromLTRB(14, 12, 12, 12),
      decoration: BoxDecoration(
        color: t.background,
        border: Border.all(color: t.border),
        borderRadius: ScootRadius.cardAll,
      ),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 18, color: t.foreground),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (title != null)
                  Text(
                    title!,
                    style: ScootType.bodyStrong.copyWith(color: t.foreground),
                  ),
                Text(
                  text,
                  style: title == null
                      ? ScootType.body.copyWith(color: t.foreground)
                      : ScootType.body.copyWith(color: t.noteText),
                ),
              ],
            ),
          ),
          if (action != null) ...<Widget>[
            const SizedBox(width: 10),
            OutlinedButton(
              style: OutlinedButton.styleFrom(
                foregroundColor: t.foreground,
                side: BorderSide(color: t.foreground),
              ),
              onPressed: onPressed == null ? null : () => onPressed!(),
              child: Text(action!),
            ),
          ],
        ],
      ),
    );
  }
}

const List<String> finishedStopMessages = <String>[
  'terminal stop',
  'already has a terminal state',
  'no longer pending',
  'cannot move to skipped',
  'already finished',
];

const List<String> arrivalNeededMessages = <String>[
  'prior accepted arrival',
  'accepted arrival evidence',
];

String stopSaveFailureMessage(Object error, {required String fallback}) {
  if (error is StateError &&
      error.message.contains('work session is required')) {
    return 'Work is not started. Tap Start work, then try again.';
  }
  if (error is FirebaseException) {
    if (error.code == 'permission-denied') {
      return 'The server did not allow this. Ask your manager to check your account.';
    }
    if (error.code == 'unavailable' || error.code == 'deadline-exceeded') {
      return 'You are offline. Try again when you have a signal.';
    }
  }
  if (error is PermissionDeniedException) {
    return 'Location permission is off. Allow location for this app.';
  }
  if (error is LocationServiceDisabledException) {
    return 'Location is off. Turn it on and try again.';
  }
  if (error is TimeoutException) return 'Saving took too long. Try again.';
  if (error is StateError) {
    final String message = error.message;
    if (finishedStopMessages.any(message.contains)) {
      return 'This stop is already finished.';
    }
    if (arrivalNeededMessages.any(message.contains)) {
      return 'Mark arrival at this stop first.';
    }
    return message;
  }
  return fallback;
}
