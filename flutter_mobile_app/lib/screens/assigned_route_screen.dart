import 'dart:async';

import 'package:flutter/material.dart';
import 'package:geolocator/geolocator.dart';
import 'package:cloud_firestore/cloud_firestore.dart'
    show FirebaseFirestore, QueryDocumentSnapshot, QuerySnapshot;
import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:intl/intl.dart';
import 'package:latlong2/latlong.dart';
import 'package:provider/provider.dart';

import '../copilot/mobile_copilot_commands.dart';
import '../copilot/mobile_copilot_page.dart';
import '../edition.dart';
import '../models/assigned_route_plan.dart';
import '../models/user_model.dart';
import '../models/visit_brief.dart';
import '../providers/auth_provider.dart';
import '../providers/connectivity_provider.dart';
import '../providers/gps_provider.dart';
import '../services/route_plan_service.dart';
import '../services/guided_visit_session_store.dart';
import '../services/sales_visit_copilot_service.dart';
import '../widgets/still_loading_indicator.dart';
import '../theme/app_theme.dart';
import '../utils/assigned_route_lifecycle.dart';
import '../utils/nearby_retailer.dart';
import '../utils/location_evidence.dart';
import '../widgets/todays_focus.dart';
import '../widgets/assigned_route_map.dart';
import '../widgets/arrival_verification_flow.dart';
import '../widgets/replenishment_suggestions.dart';
import '../widgets/retailer_memory_panel.dart';
import '../widgets/phone_status_strip.dart';
import '../models/guided_visit_context.dart';
import 'guided_visit_screen.dart';
import 'overview_screen.dart' show AppBottomNav;
import 'package:scoot_design/scoot_design.dart';
import 'order_history_screen.dart';
import '../voice/core/action_registry.dart';
import '../voice/core/voice_binding.dart';
import '../voice/core/voice_dispatcher.dart';
import '../widgets/location_status_banner.dart';
import '../voice/core/voice_engine.dart';
import '../voice/core/voice_types.dart';
import '../voice/voice_registry_factory.dart';
import '../widgets/long_name_text.dart';

bool _hasUsableStopCoordinates(AssignedRouteStop stop) =>
    stop.lat.isFinite &&
    stop.lng.isFinite &&
    stop.lat >= -90 &&
    stop.lat <= 90 &&
    stop.lng >= -180 &&
    stop.lng <= 180 &&
    !(stop.lat == 0 && stop.lng == 0);

String _routeEstimateLabel(String source) {
  final String normalized = source.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  if (normalized.isEmpty) return 'not available';
  if (normalized.contains('mixed') && normalized.contains('haversine')) {
    return 'mixed road and straight-line estimates';
  }
  if (normalized == 'geoapifyrouting' || normalized == 'geoapifyroute') {
    return 'Geoapify road distance/time estimate';
  }
  if (normalized == 'geoapifymatrix' ||
      normalized == 'geoapifymatrixroute' ||
      normalized == 'geoapifyroutematrix') {
    return 'Geoapify matrix road distance/time estimate';
  }
  if (normalized == 'osrmroute') return 'OSRM road distance/time estimate';
  if (normalized.contains('haversine') || normalized.contains('straightline')) {
    return 'straight-line distance; not a road or traffic ETA';
  }
  if (normalized == 'osrmtable') return 'OSRM road distance/time estimate';
  return source.trim();
}

String _estimateSourceForDay(AssignedRouteDay? day, String fallback) {
  if (day == null) return fallback;
  if (day.estimateSource.trim().isNotEmpty) return day.estimateSource;
  if (day.geometrySource.trim().isNotEmpty) return day.geometrySource;
  return fallback;
}

bool _hasProviderRoadGeometry(String source) {
  final String normalized = source.trim().toLowerCase().replaceAll(
    RegExp(r'[^a-z0-9]'),
    '',
  );
  return normalized == 'osrmroute' || normalized == 'geoapifyroute';
}

class AssignedRoutePreview extends StatelessWidget {
  const AssignedRoutePreview({
    super.key,
    required this.routes,
    required this.progressFor,
  });

  final Stream<List<AssignedRoutePlan>> routes;
  final Stream<RouteProgress>? Function(AssignedRoutePlan plan) progressFor;

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final user = auth.user;
    if (user == null) return const SizedBox.shrink();
    return StreamBuilder<List<AssignedRoutePlan>>(
      stream: routes,
      builder: (context, snapshot) {
        final plans = (snapshot.data ?? const <AssignedRoutePlan>[])
            .where((AssignedRoutePlan plan) => !plan.isDemo)
            .toList(growable: false);
        final AssignedRouteLoadState loadState = assignedRouteLoadState(
          isWaiting: snapshot.connectionState == ConnectionState.waiting,
          hasData: snapshot.hasData,
          hasError: snapshot.hasError,
        );
        if (loadState == AssignedRouteLoadState.loading && plans.isEmpty) {
          return const _PreviewCardSkeleton();
        }
        if (loadState == AssignedRouteLoadState.error && plans.isEmpty) {
          return _PreviewCard(
            title: 'Assigned route unavailable',
            subtitle: 'Check your connection and try again.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AssignedRouteScreen()),
            ),
          );
        }
        final candidates = activeAssignedRouteCandidates(
          plans,
          now: DateTime.now(),
        );
        if (candidates.isEmpty) {
          return _PreviewCard(
            title: 'No assigned route',
            subtitle: 'Your personal planner is still available.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AssignedRouteScreen()),
            ),
          );
        }
        return _AssignedRoutePreviewCandidate(
          candidates: candidates,
          progressFor: progressFor,
        );
      },
    );
  }
}

class _AssignedRoutePreviewCandidate extends StatelessWidget {
  const _AssignedRoutePreviewCandidate({
    required this.candidates,
    required this.progressFor,
    this.index = 0,
  });

  final List<AssignedRoutePlan> candidates;
  final Stream<RouteProgress>? Function(AssignedRoutePlan plan) progressFor;
  final int index;

  @override
  Widget build(BuildContext context) {
    if (index >= candidates.length) {
      return _PreviewCard(
        title: 'No active assigned route',
        subtitle: 'Your personal planner is still available.',
        onTap: () => Navigator.push(
          context,
          MaterialPageRoute(builder: (_) => const AssignedRouteScreen()),
        ),
      );
    }
    final plan = candidates[index];
    return StreamBuilder<RouteProgress>(
      stream: progressFor(plan),
      builder: (context, snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting &&
            !snapshot.hasData) {
          return const _PreviewCardSkeleton();
        }
        if (snapshot.hasError && !snapshot.hasData) {
          return _PreviewCard(
            title: 'Assigned route unavailable',
            subtitle: 'Check your connection and try again.',
            onTap: () => Navigator.push(
              context,
              MaterialPageRoute(builder: (_) => const AssignedRouteScreen()),
            ),
          );
        }
        final progress =
            snapshot.data ??
            RouteProgress(status: 'assigned', stopProgress: const {});
        if (progress.status.toLowerCase() == 'completed') {
          return _AssignedRoutePreviewCandidate(
            candidates: candidates,
            progressFor: progressFor,
            index: index + 1,
          );
        }
        final today = plan.dayFor(DateTime.now());
        return _PreviewCard(
          title: 'Assigned route',
          subtitle: _previewSubtitle(plan, today?.stops.length ?? 0),
          onTap: () => Navigator.push(
            context,
            MaterialPageRoute(builder: (_) => const AssignedRouteScreen()),
          ),
        );
      },
    );
  }
}

String _previewSubtitle(AssignedRoutePlan plan, int stops) {
  final DateTime? week = plan.weekStart;
  final String stopText = stops == 0
      ? 'No stops today'
      : stops == 1
      ? '1 stop today'
      : '$stops stops today';
  return <String>[
    if (week != null) 'Week of ${DateFormat('d MMM').format(week)}',
    stopText,
    plan.sourceLabel,
  ].join(' · ');
}

class AssignedRouteScreen extends StatefulWidget {
  const AssignedRouteScreen({super.key});

  @override
  State<AssignedRouteScreen> createState() => _AssignedRouteScreenState();
}

class _AssignedRouteScreenState extends State<AssignedRouteScreen>
    with WidgetsBindingObserver {
  late final RoutePlanService _routeService;
  late final SalesVisitCopilotService _copilotService;
  Stream<List<AssignedRoutePlan>>? _routeStream;
  Stream<List<VisitBrief>>? _briefStream;
  final Map<String, Stream<RouteProgress>> _progressStreams =
      <String, Stream<RouteProgress>>{};
  final RouteHeartbeatPacer _routeHeartbeat = RouteHeartbeatPacer();
  bool _routeHeartbeatAllowed = false;
  String _routeSessionAdoptKey = '';
  final Set<String> _reconciledCompletionReceipts = <String>{};
  Object? _resumeToken;
  String _resumeKey = '';
  bool? _resumeOnline;
  String _activeUid = '';
  bool _flushScheduled = false;
  late final VoiceScreenBinding _voiceBinding;
  late final VoiceCommandEngine _voiceEngine;
  AssignedRoutePlan? _voicePlan;
  RouteProgress? _voiceProgress;
  List<VisitBrief> _voiceBriefs = const <VisitBrief>[];

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addObserver(this);
    _routeService = RoutePlanService();
    _copilotService = SalesVisitCopilotService();
    _voiceBinding = VoiceScreenBinding(
      surfaceId: VoiceSurfaceIds.assignedRoute,
    );
    _voiceBinding.registerHandler(
      VoiceActionId.openAssignedRoute,
      _handleVoiceOpenAssignedRoute,
    );
    _voiceBinding.registerHandler(
      VoiceActionId.openCurrentVisit,
      _handleVoiceOpenCurrentVisit,
    );
    _voiceBinding.registerHandler(VoiceActionId.openCart, _handleVoiceOpenCart);
    _voiceBinding.registerHandler(
      VoiceActionId.openOrderHistory,
      _handleVoiceOpenOrderHistory,
    );
    _voiceBinding.registerHandler(
      VoiceActionId.showVisitBrief,
      _handleVoiceShowVisitBrief,
    );
    _voiceEngine = VoiceCommandEngine(
      sessionId: 'assigned-route-${DateTime.now().microsecondsSinceEpoch}',
      binding: _voiceBinding,
      dispatcher: VoiceActionDispatcher(
        registry: buildVoiceActionRegistry(),
        binding: _voiceBinding,
      ),
    );
  }

  void _prepareUser(UserModel user, bool isOnline) {
    if (_activeUid != user.uid) {
      _activeUid = user.uid;
      _progressStreams.clear();
      _reconciledCompletionReceipts.clear();
      _routeStream = _routeService.watchAssignedPublishedRoutes(user);
      _briefStream = _copilotService.watchAssignedBriefs(user);
      unawaited(_copilotService.initialiseForUser(user.uid));
    }
    if (isOnline && !_flushScheduled) {
      _flushScheduled = true;
      WidgetsBinding.instance.addPostFrameCallback((_) {
        _flushScheduled = false;
        unawaited(_copilotService.flushPending(isOnline: true));
      });
    }
  }

  void _reconcileCompletionReceipts({
    required AssignedRoutePlan plan,
    required RouteProgress progress,
    required String salesmanUid,
  }) {
    if (progress.hasPendingWrites || progress.isFromCache) return;
    for (final AssignedRouteDay day in plan.days) {
      for (final AssignedRouteStop stop in day.stops) {
        if (progress.statusFor(stop.stopId, stop.status) != 'completed') {
          continue;
        }
        final String receiptKey = '$salesmanUid|${plan.id}|${stop.stopId}';
        if (!_reconciledCompletionReceipts.add(receiptKey)) continue;
        WidgetsBinding.instance.addPostFrameCallback((_) {
          GuidedVisitSessionStore.clearCompletionPending(
            salesmanUid: salesmanUid,
            routePlanId: plan.id,
            routeStopId: stop.stopId,
          ).catchError((Object _) {
            _reconciledCompletionReceipts.remove(receiptKey);
          });
        });
      }
    }
  }

  @override
  void dispose() {
    WidgetsBinding.instance.removeObserver(this);
    _stopRouteHeartbeat();
    _copilotService.dispose();
    _voiceBinding.dispose();
    super.dispose();
  }

  @override
  void didChangeAppLifecycleState(AppLifecycleState state) {
    if (state == AppLifecycleState.resumed && mounted) {
      unawaited(context.read<GpsProvider>().refreshTracking());
      final AssignedRoutePlan? plan = _voicePlan;
      final RouteProgress? progress = _voiceProgress;
      final AuthProvider auth = context.read<AuthProvider>();
      final UserModel? user = auth.user;
      if (plan != null && progress != null && user != null) {
        _syncRouteHeartbeat(
          plan: plan,
          progress: progress,
          user: user,
          isOnline:
              context.read<ConnectivityProvider>().isOnline &&
              !auth.isOfflineVerified,
        );
      }
    } else if (state != AppLifecycleState.inactive) {
      _routeHeartbeat.pause();
    }
  }

  void _syncRouteHeartbeat({
    required AssignedRoutePlan plan,
    required RouteProgress progress,
    required UserModel user,
    required bool isOnline,
  }) {
    final String key = '${plan.id}_${user.uid}';
    final bool inProgress =
        isOnline &&
        progress.status.trim().toLowerCase() == 'in_progress' &&
        !progress.isFromCache;
    final String session = progress.routeSessionState.trim().toLowerCase();
    if (inProgress && session == 'untracked' && _routeSessionAdoptKey != key) {
      _routeSessionAdoptKey = key;
      unawaited(
        _routeService
            .markRouteSessionActive(plan: plan, user: user)
            .catchError((Object _) => RouteProgressWriteState.needsAttention),
      );
    }
    if (!inProgress || session != 'active' || !mounted) {
      _stopRouteHeartbeat();
      return;
    }
    _routeHeartbeatAllowed = true;
    _routeHeartbeat.start(key, _sendRouteHeartbeatNow);
  }

  bool _sendRouteHeartbeatNow() {
    final AppLifecycleState? appState = WidgetsBinding.instance.lifecycleState;
    if (!_routeHeartbeatAllowed ||
        !mounted ||
        (appState != AppLifecycleState.resumed &&
            appState != AppLifecycleState.inactive)) {
      return false;
    }
    final AssignedRoutePlan? plan = _voicePlan;
    final RouteProgress? progress = _voiceProgress;
    final UserModel? user = context.read<AuthProvider>().user;
    if (plan == null ||
        progress == null ||
        user == null ||
        progress.status.trim().toLowerCase() != 'in_progress' ||
        progress.routeSessionState.trim().toLowerCase() != 'active' ||
        '${plan.id}_${user.uid}' != _routeHeartbeat.key) {
      return false;
    }
    unawaited(
      _routeService
          .recordRouteHeartbeat(plan: plan, user: user)
          .catchError((Object _) {}),
    );
    return true;
  }

  void _stopRouteHeartbeat() {
    _routeHeartbeatAllowed = false;
    _routeHeartbeat.stop();
  }

  Future<VoiceActionResult> _handleVoiceOpenAssignedRoute(
    VoiceCommandEnvelope envelope,
  ) async => const VoiceActionResult.opened();

  Future<VoiceActionResult> _handleVoiceOpenCurrentVisit(
    VoiceCommandEnvelope envelope,
  ) async {
    return _resolveVoiceStop() == null
        ? const VoiceActionResult(code: VoiceResultCode.unavailable)
        : const VoiceActionResult.opened();
  }

  Future<VoiceActionResult> _handleVoiceOpenCart(
    VoiceCommandEnvelope envelope,
  ) async {
    return _resolveVoiceStop() == null
        ? const VoiceActionResult(code: VoiceResultCode.unavailable)
        : const VoiceActionResult.opened();
  }

  Future<VoiceActionResult> _handleVoiceOpenOrderHistory(
    VoiceCommandEnvelope envelope,
  ) async => const VoiceActionResult.opened();

  Future<VoiceActionResult> _handleVoiceShowVisitBrief(
    VoiceCommandEnvelope envelope,
  ) async {
    if (kBasicEdition) return const VoiceActionResult.handlerUnavailable();
    final AssignedRouteStop? stop = _resolveVoiceStop();
    final VisitBrief? brief = _voiceBriefFor(stop);
    if (stop == null) {
      return const VoiceActionResult(code: VoiceResultCode.unavailable);
    }
    await _showVoiceVisitBrief(stop, brief);
    return const VoiceActionResult.applied();
  }

  AssignedRouteStop? _resolveVoiceStop() {
    final AssignedRoutePlan? plan = _voicePlan;
    final RouteProgress? progress = _voiceProgress;
    if (plan == null || progress == null) return null;
    final AssignedRouteDay? today = plan.dayFor(DateTime.now());
    final List<AssignedRouteDay> days = List<AssignedRouteDay>.from(plan.days);
    if (today != null) {
      days
        ..remove(today)
        ..insert(0, today);
    }
    for (final AssignedRouteDay day in days) {
      for (final AssignedRouteStop stop in day.stops) {
        if (!isTerminalStopStatus(
          progress.statusFor(stop.stopId, stop.status),
        )) {
          return stop;
        }
      }
    }
    return null;
  }

  VisitBrief? _voiceBriefFor(AssignedRouteStop? stop) {
    if (stop == null) return null;
    for (final VisitBrief brief in _voiceBriefs) {
      if (brief.retailerId == stop.retailerId) return brief;
    }
    return null;
  }

  Future<void> _showVoiceVisitBrief(
    AssignedRouteStop stop,
    VisitBrief? brief,
  ) async {
    final List<VisitBriefInsight> insights =
        brief?.topInsights.take(5).toList(growable: false) ??
        const <VisitBriefInsight>[];
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) => AlertDialog(
        title: Text('Visit brief · ${stop.retailerName}'),
        content: SingleChildScrollView(
          child: insights.isEmpty
              ? const Text('No current visit brief insights are available.')
              : Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    for (final VisitBriefInsight insight in insights) ...[
                      Text(
                        insight.productName.isEmpty
                            ? insight.type.replaceAll('_', ' ')
                            : insight.productName,
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                      const SizedBox(height: 3),
                      Text(insight.reason),
                      const SizedBox(height: 10),
                    ],
                  ],
                ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(dialogContext).pop(),
            child: const Text('Close'),
          ),
        ],
      ),
    );
  }

  Future<void> _handleVoiceNavigation(
    VoiceActionId action,
    VoiceEngineOutcome outcome,
  ) async {
    if (!mounted || outcome.actionResult?.code != VoiceResultCode.opened) {
      return;
    }
    switch (action) {
      case VoiceActionId.openAssignedRoute:
        break;
      case VoiceActionId.openCurrentVisit:
        await _openVoiceVisit(openCart: false);
      case VoiceActionId.openCart:
        await _openVoiceVisit(openCart: true);
      case VoiceActionId.openOrderHistory:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const OrderHistoryScreen()),
        );
      default:
        break;
    }
  }

  Future<void> _openVoiceVisit({required bool openCart}) async {
    final AssignedRoutePlan? plan = _voicePlan;
    final RouteProgress? progress = _voiceProgress;
    final AssignedRouteStop? stop = _resolveVoiceStop();
    final UserModel? user = context.read<AuthProvider>().user;
    if (plan == null || progress == null || stop == null || user == null) {
      return;
    }
    final String status = progress.statusFor(stop.stopId, stop.status);
    final VisitBrief? brief = _voiceBriefFor(stop);
    final GuidedVisitContext visitContext = GuidedVisitContext(
      planId: plan.id,
      stopId: stop.stopId,
      branchId: plan.branchId,
      retailerLatitude: stop.lat,
      retailerLongitude: stop.lng,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<void>(
        settings: RouteSettings(name: visitContext.routeName),
        builder: (_) => GuidedVisitScreen(
          plan: plan,
          stop: stop,
          user: user,
          stopStatus: status,
          progress: progress,
          service: _routeService,
          copilotService: _copilotService,
          brief: brief,
          openCartInitially: openCart,
        ),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    final user = auth.user;
    if (user == null) {
      return const Scaffold(body: Center(child: Text('Sign in required.')));
    }
    final isOnline =
        context.watch<ConnectivityProvider>().isOnline &&
        !auth.isOfflineVerified;
    final GpsProvider gps = context.watch<GpsProvider>();
    final position = gps.reliableCurrentPosition;
    final DeviceLocationFix? currentFix = position == null
        ? null
        : DeviceLocationFix(
            latitude: position.latitude,
            longitude: position.longitude,
            accuracyMeters: position.accuracy,
            capturedAt: position.timestamp,
            isMocked: position.isMocked,
          );
    _prepareUser(user, isOnline);
    _voiceBinding.updateContext(uid: user.uid, role: user.role);
    return Scaffold(
      backgroundColor: ScootColors.of(context).page,
      appBar: ScootPhoneAppBar(
        title: 'Route',
        actions: <Widget>[
          CopilotEntryButton(
            screen: CopilotScreenContext(
              engine: _voiceEngine,
              onNavigationAction: _handleVoiceNavigation,
              suggestions: const <String>['Open the current visit'],
            ),
          ),
        ],
      ),
      bottomNavigationBar: const AppBottomNav(currentIndex: 1),
      body: Column(
        children: <Widget>[
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.3,
            ),
            child: SingleChildScrollView(
              child: Column(
                children: <Widget>[
                  if (gps.hasLocationProblem)
                    _LocationStatusBanner(
                      message: gps.statusMessage,
                      onRetry: gps.refreshTracking,
                      onAllow: gps.state == GpsTrackingState.permissionDenied
                          ? () => gps.startTracking(user: user, explicit: true)
                          : null,
                      onOpenSettings:
                          gps.state == GpsTrackingState.permissionDeniedForever
                          ? Geolocator.openAppSettings
                          : null,
                    ),
                  const LocationStatusBanner(),
                ],
              ),
            ),
          ),
          Expanded(
            child: AnimatedBuilder(
              animation: _copilotService,
              builder: (context, _) => StreamBuilder<List<AssignedRoutePlan>>(
                stream: _routeStream,
                builder: (context, snapshot) {
                  final plans = (snapshot.data ?? const <AssignedRoutePlan>[])
                      .where((AssignedRoutePlan plan) => !plan.isDemo)
                      .toList(growable: false);
                  if (snapshot.connectionState == ConnectionState.waiting &&
                      plans.isEmpty) {
                    return const StillLoadingIndicator();
                  }
                  if (snapshot.hasError && plans.isEmpty) {
                    return const _RouteEmptyState(
                      icon: Icons.error_outline,
                      title: 'Assigned route unavailable',
                      subtitle: 'Check your connection and try again.',
                    );
                  }
                  final candidates = activeAssignedRouteCandidates(
                    plans,
                    now: DateTime.now(),
                  );
                  if (candidates.isEmpty) {
                    _progressStreams.clear();
                    _briefStream = _copilotService.watchAssignedBriefs(user);
                    return const _RouteEmptyState(
                      icon: Icons.alt_route_outlined,
                      title: 'No assigned route',
                      subtitle:
                          'Published dashboard route plans assigned to you will appear here. Your personal planner is unchanged.',
                    );
                  }
                  return StreamBuilder<List<VisitBrief>>(
                    stream: _briefStream,
                    builder: (context, briefSnapshot) {
                      final briefs =
                          (briefSnapshot.data ?? const <VisitBrief>[])
                              .where((VisitBrief brief) => !brief.isDemo)
                              .toList(growable: false);
                      return _buildCandidate(
                        candidates: candidates,
                        index: 0,
                        briefs: briefs,
                        briefsUnavailable: briefSnapshot.hasError,
                        user: user,
                        isOnline: isOnline,
                        currentFix: currentFix,
                      );
                    },
                  );
                },
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _buildCandidate({
    required List<AssignedRoutePlan> candidates,
    required int index,
    required List<VisitBrief> briefs,
    required bool briefsUnavailable,
    required UserModel user,
    required bool isOnline,
    required DeviceLocationFix? currentFix,
  }) {
    if (index >= candidates.length) {
      return const _RouteEmptyState(
        icon: Icons.task_alt_outlined,
        title: 'No active assigned route',
        subtitle:
            'Completed and expired routes are kept in management history.',
      );
    }
    final plan = candidates[index];
    final progressKey = '${plan.id}_${user.uid}';
    return StreamBuilder<RouteProgress>(
      stream: _progressStreams.putIfAbsent(
        progressKey,
        () =>
            _routeService.watchProgress(planId: plan.id, salesmanUid: user.uid),
      ),
      builder: (context, progressSnapshot) {
        if (progressSnapshot.connectionState == ConnectionState.waiting &&
            !progressSnapshot.hasData) {
          return const StillLoadingIndicator();
        }
        if (progressSnapshot.hasError && !progressSnapshot.hasData) {
          return const _RouteEmptyState(
            icon: Icons.error_outline,
            title: 'Route progress unavailable',
            subtitle: 'Check your connection before updating this assignment.',
          );
        }
        final progress =
            progressSnapshot.data ??
            RouteProgress(status: 'assigned', stopProgress: const {});
        if (!progress.isFromCache && !progress.hasPendingWrites) {
          final Object resumeToken = progressSnapshot.data ?? progressKey;
          if (!identical(_resumeToken, resumeToken) ||
              _resumeKey != progressKey ||
              _resumeOnline != isOnline) {
            _resumeToken = resumeToken;
            _resumeKey = progressKey;
            _resumeOnline = isOnline;
            unawaited(
              _routeService.resumePendingStopEvents(
                plan: plan,
                user: user,
                progress: progress,
              ),
            );
          }
        }
        _voicePlan = plan;
        _voiceProgress = progress;
        _voiceBriefs = briefs;
        _syncRouteHeartbeat(
          plan: plan,
          progress: progress,
          user: user,
          isOnline: isOnline,
        );
        _voiceBinding.updateContext(
          uid: user.uid,
          role: user.role,
          routePlanId: plan.id,
        );
        _reconcileCompletionReceipts(
          plan: plan,
          progress: progress,
          salesmanUid: user.uid,
        );
        if (progress.status.toLowerCase() == 'completed') {
          return _buildCandidate(
            candidates: candidates,
            index: index + 1,
            briefs: briefs,
            briefsUnavailable: briefsUnavailable,
            user: user,
            isOnline: isOnline,
            currentFix: currentFix,
          );
        }
        return _AssignedRouteBody(
          plan: plan,
          progress: progress,
          briefs: briefs,
          briefsUnavailable: briefsUnavailable,
          user: user,
          service: _routeService,
          copilotService: _copilotService,
          isOnline: isOnline,
          currentFix: currentFix,
        );
      },
    );
  }
}

class _LocationStatusBanner extends StatelessWidget {
  const _LocationStatusBanner({
    required this.message,
    required this.onRetry,
    this.onAllow,
    this.onOpenSettings,
  });

  final String message;
  final Future<void> Function() onRetry;
  final Future<void> Function()? onAllow;
  final Future<bool> Function()? onOpenSettings;

  @override
  Widget build(BuildContext context) {
    const Color accent = Color(0xFFB45309);
    final String? actionLabel = onAllow != null
        ? 'Allow location'
        : onOpenSettings != null
        ? 'Open Settings'
        : null;
    return Material(
      color: const Color(0xFFFFF7ED),
      child: Padding(
        padding: const EdgeInsets.fromLTRB(16, 8, 8, 8),
        child: Row(
          children: <Widget>[
            const Icon(Icons.location_off_outlined, size: 18, color: accent),
            const SizedBox(width: 8),
            Expanded(
              child: Text(
                message,
                style: const TextStyle(
                  color: Color(0xFF92400E),
                  fontSize: 12,
                  fontWeight: FontWeight.w600,
                ),
              ),
            ),
            if (actionLabel != null)
              TextButton(
                style: TextButton.styleFrom(foregroundColor: accent),
                onPressed: () =>
                    onAllow != null ? onAllow!() : onOpenSettings!(),
                child: Text(actionLabel),
              )
            else
              IconButton(
                tooltip: 'Retry location',
                onPressed: () => onRetry(),
                icon: const Icon(Icons.refresh, size: 19),
                color: accent,
              ),
          ],
        ),
      ),
    );
  }
}

class _AssignedRouteBody extends StatelessWidget {
  const _AssignedRouteBody({
    required this.plan,
    required this.progress,
    required this.briefs,
    required this.briefsUnavailable,
    required this.user,
    required this.service,
    required this.copilotService,
    required this.isOnline,
    required this.currentFix,
  });

  final AssignedRoutePlan plan;
  final RouteProgress progress;
  final List<VisitBrief> briefs;
  final bool briefsUnavailable;
  final UserModel user;
  final RoutePlanService service;
  final SalesVisitCopilotService copilotService;
  final bool isOnline;
  final DeviceLocationFix? currentFix;

  @override
  Widget build(BuildContext context) {
    final today = plan.dayFor(DateTime.now());
    final briefsByRetailer = <String, VisitBrief>{
      for (final brief in briefs)
        if (!brief.isDemo) brief.retailerId: brief,
    };
    final AssignedRouteStop? selectedTarget = selectedPendingRouteStop(
      plan,
      progress,
    );
    final AssignedRouteStop? displayTarget =
        selectedTarget ?? firstPendingRouteStop(plan, progress);
    final remainingDays = plan.days
        .where(
          (day) => day.stops.any(
            (stop) => !isTerminalStopStatus(
              progress.statusFor(stop.stopId, stop.status),
            ),
          ),
        )
        .toList(growable: false);
    return DefaultTabController(
      length: 2,
      child: NestedScrollView(
        headerSliverBuilder: (BuildContext context, bool innerBoxIsScrolled) =>
            <Widget>[
              SliverToBoxAdapter(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: [
                    PhoneStatusStrip(
                      pendingCount: copilotService.pendingCount,
                      hasPendingWrites: progress.hasPendingWrites,
                      isFromCache: progress.isFromCache,
                    ),
                    if (briefsUnavailable)
                      const Padding(
                        padding: EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text(
                          'Visit guidance could not be loaded. The assigned route is still available, but retailer insights may be missing.',
                          style: TextStyle(
                            color: Color(0xFFB45309),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    if (copilotService.lastSyncError.isNotEmpty)
                      Padding(
                        padding: const EdgeInsets.fromLTRB(16, 8, 16, 0),
                        child: Text(
                          copilotService.lastSyncError,
                          style: const TextStyle(
                            color: Color(0xFFB45309),
                            fontSize: 12,
                          ),
                        ),
                      ),
                    _PlanHeader(
                      plan: plan,
                      progress: progress,
                      user: user,
                      service: service,
                      currentFix: currentFix,
                    ),
                  ],
                ),
              ),
              SliverOverlapAbsorber(
                handle: NestedScrollView.sliverOverlapAbsorberHandleFor(
                  context,
                ),
                sliver: const SliverPersistentHeader(
                  pinned: true,
                  delegate: _PinnedTabBarDelegate(),
                ),
              ),
            ],
        body: TabBarView(
          children: [
            _TabBarOverlapPadding(
              child: _RouteDayView(
                day: today,
                progress: progress,
                plan: plan,
                user: user,
                service: service,
                copilotService: copilotService,
                briefsByRetailer: briefsByRetailer,
                isOnline: isOnline,
                emptyTitle: 'No assigned stops today',
                displayTargetStopId: displayTarget?.stopId ?? '',
                selectedTargetStopId: selectedTarget?.stopId ?? '',
                currentFix: currentFix,
              ),
            ),
            _TabBarOverlapPadding(
              child: remainingDays.isEmpty
                  ? const _RouteEmptyState(
                      icon: Icons.task_alt_outlined,
                      title: 'All stops handled',
                      subtitle: 'Complete the route to close this assignment.',
                    )
                  : ListView.separated(
                      padding: const EdgeInsets.all(16),
                      itemCount: remainingDays.length,
                      separatorBuilder: (_, _) => const SizedBox(height: 12),
                      itemBuilder: (context, index) {
                        final day = remainingDays[index];
                        return _RouteDayView(
                          day: day,
                          progress: progress,
                          plan: plan,
                          user: user,
                          service: service,
                          copilotService: copilotService,
                          briefsByRetailer: briefsByRetailer,
                          isOnline: isOnline,
                          compactHeader: true,
                          emptyTitle: 'No remaining stops',
                          displayTargetStopId: displayTarget?.stopId ?? '',
                          selectedTargetStopId: selectedTarget?.stopId ?? '',
                        );
                      },
                    ),
            ),
          ],
        ),
      ),
    );
  }
}

class _TabBarOverlapPadding extends StatelessWidget {
  const _TabBarOverlapPadding({required this.child});

  final Widget child;

  @override
  Widget build(BuildContext context) {
    return Padding(
      padding: const EdgeInsets.only(top: _PinnedTabBarDelegate.extent),
      child: child,
    );
  }
}

class _PinnedTabBarDelegate extends SliverPersistentHeaderDelegate {
  const _PinnedTabBarDelegate();

  static const double extent = 48;

  @override
  double get minExtent => extent;
  @override
  double get maxExtent => extent;

  @override
  Widget build(
    BuildContext context,
    double shrinkOffset,
    bool overlapsContent,
  ) => Material(
    color: AppColors.bodyBg,
    child: const TabBar(
      labelColor: AppColors.primary,
      unselectedLabelColor: AppColors.textGrey,
      tabs: [
        Tab(text: 'Today'),
        Tab(text: 'Week'),
      ],
    ),
  );

  @override
  bool shouldRebuild(covariant SliverPersistentHeaderDelegate oldDelegate) =>
      false;
}

class _RouteTargetSummary extends StatelessWidget {
  const _RouteTargetSummary({required this.plan, required this.progress});

  final AssignedRoutePlan plan;
  final RouteProgress progress;

  @override
  Widget build(BuildContext context) {
    final AssignedRouteStop? selected = selectedPendingRouteStop(
      plan,
      progress,
    );
    final AssignedRouteStop? target =
        selected ?? firstPendingRouteStop(plan, progress);
    if (target == null) {
      return Container(
        width: double.infinity,
        padding: const EdgeInsets.all(12),
        decoration: BoxDecoration(
          color: const Color(0xFFF3F4F6),
          borderRadius: BorderRadius.circular(10),
        ),
        child: const Text(
          'No active destination is selected and no pending stops remain.',
          style: TextStyle(fontSize: 12, color: AppColors.textGrey),
        ),
      );
    }

    final String plannedTime = <String>[
      if (target.estimatedArrival.isNotEmpty) target.estimatedArrival,
      if (target.estimatedDeparture.isNotEmpty) target.estimatedDeparture,
    ].join(' - ');
    final AssignedRouteDay? targetDay = plan.days
        .where((AssignedRouteDay day) => day.dayId == target.dayId)
        .cast<AssignedRouteDay?>()
        .firstWhere((AssignedRouteDay? day) => day != null, orElse: () => null);
    final String estimateSource = _routeEstimateLabel(
      _estimateSourceForDay(targetDay, plan.optimisationMethod),
    );
    final String? otherDay = routeStopOtherDayLabel(plan, target);
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFEFF8F4),
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: AppColors.inputBorder),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Icon(
            Icons.near_me_outlined,
            size: 18,
            color: AppColors.primary,
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  selected == null
                      ? 'No stop selected'
                      : 'Selected destination',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
                const SizedBox(height: 3),
                LongNameText(
                  target.retailerName,
                  style: const TextStyle(
                    fontSize: 14,
                    fontWeight: FontWeight.w700,
                    color: AppColors.textPrimary,
                  ),
                ),
                if (target.address.isNotEmpty) ...[
                  const SizedBox(height: 2),
                  Text(
                    target.address,
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textGrey,
                    ),
                  ),
                ],
                if (plannedTime.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Text(
                    otherDay == null
                        ? 'Planned time: $plannedTime'
                        : 'Planned time: $otherDay, $plannedTime',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textGrey,
                    ),
                  ),
                ],
                if (target.legDistanceKm > 0 &&
                    target.travelMinutesFromPrevious > 0) ...[
                  const SizedBox(height: 2),
                  Text(
                    'Planned leg: ${target.legDistanceKm.toStringAsFixed(1)} km · '
                    'about ${target.travelMinutesFromPrevious} min',
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textGrey,
                    ),
                  ),
                ],
                const SizedBox(height: 2),
                Text(
                  target.legDistanceKm > 0 &&
                          target.travelMinutesFromPrevious > 0
                      ? 'Travel estimate: $estimateSource'
                      : 'Distance/ETA estimate unavailable · $estimateSource',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textGrey,
                  ),
                ),
                if (selected != null &&
                    !_hasUsableStopCoordinates(selected) &&
                    selected.address.trim().isNotEmpty) ...[
                  const SizedBox(height: 2),
                  const Text(
                    'No destination coordinates are available. Google Maps will search this address.',
                    style: TextStyle(fontSize: 12, color: AppColors.textGrey),
                  ),
                ],
                if (selected == null) ...[
                  const SizedBox(height: 4),
                  Text(
                    suggestedStopHint(plan, target),
                    style: const TextStyle(
                      fontSize: 12,
                      color: AppColors.textGrey,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class RouteHeaderActions extends StatelessWidget {
  const RouteHeaderActions({
    super.key,
    required this.onAccept,
    required this.onStart,
    required this.onComplete,
    required this.onOpenMaps,
    required this.onClearDestination,
  });

  final VoidCallback? onAccept;
  final VoidCallback? onStart;
  final VoidCallback? onComplete;
  final VoidCallback? onOpenMaps;
  final VoidCallback? onClearDestination;

  @override
  Widget build(BuildContext context) {
    return Wrap(
      spacing: 8,
      runSpacing: 8,
      children: [
        FilledButton(onPressed: onAccept, child: const Text('Accept route')),
        FilledButton(onPressed: onStart, child: const Text('Start route')),
        FilledButton(
          onPressed: onComplete,
          child: const Text('Complete route'),
        ),
        OutlinedButton.icon(
          onPressed: onOpenMaps,
          icon: const Icon(Icons.navigation_outlined, size: 17),
          label: const Text('Open selected stop in Google Maps'),
        ),
        if (onClearDestination != null)
          OutlinedButton.icon(
            onPressed: onClearDestination,
            icon: const Icon(Icons.close, size: 17),
            label: const Text('Clear destination'),
          ),
      ],
    );
  }
}

class _PlanHeader extends StatelessWidget {
  const _PlanHeader({
    required this.plan,
    required this.progress,
    required this.user,
    required this.service,
    required this.currentFix,
  });

  final AssignedRoutePlan plan;
  final RouteProgress progress;
  final UserModel user;
  final RoutePlanService service;
  final DeviceLocationFix? currentFix;

  @override
  Widget build(BuildContext context) {
    final allStopsHandled = allAssignedStopsHandled(plan, progress);
    final AssignedRouteStop? selectedStop = selectedPendingRouteStop(
      plan,
      progress,
    );
    final bool selectedStopCanOpen =
        selectedStop != null &&
        (_hasUsableStopCoordinates(selectedStop) ||
            selectedStop.address.trim().isNotEmpty);
    final dates = [
      if (plan.weekStart != null) DateFormat('d MMM').format(plan.weekStart!),
      if (plan.weekEnd != null) DateFormat('d MMM').format(plan.weekEnd!),
    ].join(' - ');
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.all(16),
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: AppColors.inputBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              Expanded(
                child: Text(
                  dates.isEmpty ? 'Published route' : dates,
                  style: const TextStyle(
                    fontSize: 18,
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              _Badge(plan.sourceLabel),
            ],
          ),
          const SizedBox(height: 8),
          Text(
            '${plan.days.fold<int>(0, (sum, day) => sum + day.stops.length)} stop(s) • ${_statusLabel(progress.status)}',
            style: const TextStyle(color: AppColors.textGrey),
          ),
          const SizedBox(height: 10),
          _RouteTargetSummary(plan: plan, progress: progress),
          const SizedBox(height: 12),
          RouteHeaderActions(
            onAccept: canAcceptAssignedRoute(progress.status)
                ? () => _runRouteAction(
                    context,
                    () => service.acceptRoute(plan: plan, user: user),
                  )
                : null,
            onStart:
                canStartAssignedRoute(
                  progress.status,
                  routeStart: plan.weekStart,
                )
                ? () => _runRouteAction(
                    context,
                    () => service.startRoute(plan: plan, user: user),
                  )
                : null,
            onComplete:
                canCompleteAssignedRoute(
                  progress.status,
                  allStopsHandled: allStopsHandled,
                )
                ? () => _runRouteAction(
                    context,
                    () => service.completeRoute(plan: plan, user: user),
                  )
                : null,
            onOpenMaps: selectedStopCanOpen
                ? () => service.openStopInGoogleMaps(
                    selectedStop,
                    originFix: currentFix,
                  )
                : null,
            onClearDestination: progress.selectedStopId.isNotEmpty
                ? () => _runRouteAction(
                    context,
                    () => service.clearStopSelection(
                      plan: plan,
                      user: user,
                      progress: progress,
                    ),
                  )
                : null,
          ),
          if (startRouteBlockedReason(
                progress.status,
                routeStart: plan.weekStart,
              )
              case final String reason) ...[
            const SizedBox(height: 8),
            Text(
              reason,
              style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
            ),
          ],
          if (progress.status == 'in_progress' && !allStopsHandled) ...[
            const SizedBox(height: 8),
            const Text(
              'Complete or skip every remaining stop before closing the route.',
              style: TextStyle(fontSize: 12, color: AppColors.textGrey),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _runRouteAction(
    BuildContext context,
    Future<RouteProgressWriteState> Function() action,
  ) async {
    try {
      final RouteProgressWriteState result = await action();
      if (result == RouteProgressWriteState.pending && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Route update is saved on this device and pending sync.',
            ),
          ),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Route could not be updated. Check your connection.'),
        ),
      );
    }
  }
}

class _RouteDayView extends StatefulWidget {
  const _RouteDayView({
    required this.day,
    required this.progress,
    required this.plan,
    required this.user,
    required this.service,
    required this.copilotService,
    required this.briefsByRetailer,
    required this.isOnline,
    required this.emptyTitle,
    required this.displayTargetStopId,
    required this.selectedTargetStopId,
    this.compactHeader = false,
    this.currentFix,
  });

  final AssignedRouteDay? day;
  final RouteProgress progress;
  final AssignedRoutePlan plan;
  final UserModel user;
  final RoutePlanService service;
  final SalesVisitCopilotService copilotService;
  final Map<String, VisitBrief> briefsByRetailer;
  final bool isOnline;
  final String emptyTitle;
  final String displayTargetStopId;
  final String selectedTargetStopId;
  final bool compactHeader;
  final DeviceLocationFix? currentFix;

  @override
  State<_RouteDayView> createState() => _RouteDayViewState();
}

class _RouteDayViewState extends State<_RouteDayView> {
  bool _showMap = false;
  bool _mapTilesUnavailable = false;

  @override
  Widget build(BuildContext context) {
    final AssignedRouteDay? day = widget.day;
    final RouteProgress progress = widget.progress;
    final AssignedRoutePlan plan = widget.plan;
    final UserModel user = widget.user;
    final RoutePlanService service = widget.service;
    final SalesVisitCopilotService copilotService = widget.copilotService;
    final Map<String, VisitBrief> briefsByRetailer = widget.briefsByRetailer;
    final bool isOnline = widget.isOnline;
    final String emptyTitle = widget.emptyTitle;
    final String displayTargetStopId = widget.displayTargetStopId;
    final String selectedTargetStopId = widget.selectedTargetStopId;
    final bool compactHeader = widget.compactHeader;
    final DeviceLocationFix? currentFix = widget.currentFix;
    final AssignedRouteDay? routeDay = day;
    if (routeDay == null || routeDay.stops.isEmpty) {
      return _withPersonalPlan(
        _RouteEmptyState(
          icon: Icons.event_available_outlined,
          title: emptyTitle,
          subtitle: 'Check the weekly tab or use your personal planner.',
        ),
      );
    }
    final remainingStops = routeDay.stops
        .where(
          (stop) => !isTerminalStopStatus(
            progress.statusFor(stop.stopId, stop.status),
          ),
        )
        .toList(growable: false);
    if (remainingStops.isEmpty) {
      return _withPersonalPlan(
        const _RouteEmptyState(
          icon: Icons.task_alt_outlined,
          title: 'All stops handled',
          subtitle: 'Check the weekly tab or complete the route.',
        ),
      );
    }
    final String estimateSource = _routeEstimateLabel(
      _estimateSourceForDay(routeDay, plan.optimisationMethod),
    );
    Widget buildStopTile(AssignedRouteStop stop) => _RouteStopTile(
      stop: stop,
      status: progress.statusFor(stop.stopId, stop.status),
      arrivalMode: progress.arrivalModeFor(stop.stopId),
      progress: progress,
      isSelectedDestination: selectedTargetStopId == stop.stopId,
      isSuggestedTarget:
          selectedTargetStopId.isEmpty && displayTargetStopId == stop.stopId,
      routeStatus: progress.status,
      plan: plan,
      user: user,
      service: service,
      copilotService: copilotService,
      brief: briefsByRetailer[stop.retailerId],
      isOnline: isOnline,
      currentFix: currentFix,
      estimateSourceLabel: estimateSource,
    );
    final AssignedRouteStop? selectedDayStop = routeDay.stops
        .where((AssignedRouteStop stop) => stop.stopId == selectedTargetStopId)
        .cast<AssignedRouteStop?>()
        .firstWhere(
          (AssignedRouteStop? stop) => stop != null,
          orElse: () => null,
        );
    final List<LatLng>? roadGeometry =
        _hasProviderRoadGeometry(routeDay.geometrySource) &&
            routeDay.geometry.length >= 2
        ? routeDay.geometry
              .map((List<double> point) => LatLng(point[0], point[1]))
              .toList(growable: false)
        : null;
    final content = Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: [
        Row(
          children: [
            Expanded(
              child: Text(
                '${routeDay.dayLabel}${routeDay.date == null ? '' : ' • ${DateFormat('d MMM').format(routeDay.date!)}'}',
                style: TextStyle(
                  fontSize: compactHeader ? 14 : 16,
                  fontWeight: FontWeight.bold,
                  color: AppColors.textPrimary,
                ),
              ),
            ),
            if (!compactHeader)
              SegmentedButton<bool>(
                showSelectedIcon: false,
                segments: const <ButtonSegment<bool>>[
                  ButtonSegment<bool>(
                    value: false,
                    icon: Icon(Icons.list_alt_outlined),
                    label: Text('List'),
                  ),
                  ButtonSegment<bool>(
                    value: true,
                    icon: Icon(Icons.map_outlined),
                    label: Text('Map'),
                  ),
                ],
                selected: <bool>{_showMap},
                onSelectionChanged: (Set<bool> selection) {
                  setState(() {
                    _showMap = selection.single;
                    if (_showMap) _mapTilesUnavailable = false;
                  });
                },
              ),
          ],
        ),
        _SelectedStopArrivalPrompt(
          plan: plan,
          progress: progress,
          selectedStopId: selectedTargetStopId,
          selectionRevision: progress.selectionRevision,
          user: user,
          service: service,
          isOnline: isOnline,
          currentFix: currentFix,
        ),
        const SizedBox(height: 8),
        if (_mapTilesUnavailable && !_showMap)
          Container(
            width: double.infinity,
            margin: const EdgeInsets.only(bottom: 8),
            padding: const EdgeInsets.all(10),
            decoration: BoxDecoration(
              color: const Color(0xFFFFF3E0),
              borderRadius: BorderRadius.circular(10),
            ),
            child: const Text(
              'Map tiles could not be loaded. Your route list and actions are available below.',
              style: TextStyle(fontSize: 12, color: Color(0xFF7A4B00)),
            ),
          ),
        if (_showMap) ...<Widget>[
          AssignedRouteMap(
            stops: routeDay.stops
                .map((AssignedRouteStop stop) {
                  final RetailerCoordinateSnapshot? coordinates =
                      stop.retailerCoordinateSnapshot;
                  final String plannedTime = <String>[
                    if (stop.estimatedArrival.isNotEmpty) stop.estimatedArrival,
                    if (stop.estimatedDeparture.isNotEmpty)
                      stop.estimatedDeparture,
                  ].join(' - ');
                  return AssignedRouteMapStop(
                    stopId: stop.stopId,
                    retailerName: stop.retailerName,
                    plannedOrder: stop.sequence,
                    status: progress.statusFor(stop.stopId, stop.status),
                    latitude: stop.lat,
                    longitude: stop.lng,
                    coordinatesVerified: coordinates?.isVerified ?? false,
                    coordinateRevision: coordinates?.coordinateRevision ?? '',
                    address: stop.address,
                    plannedTime: plannedTime,
                  );
                })
                .toList(growable: false),
            selectedStopId: selectedTargetStopId.isEmpty
                ? null
                : selectedTargetStopId,
            ownLocation: currentFix == null
                ? null
                : AssignedRouteMapLocation(
                    latitude: currentFix.latitude,
                    longitude: currentFix.longitude,
                    capturedAt: currentFix.capturedAt,
                    accuracyMeters: currentFix.accuracyMeters,
                  ),
            validatedRoadGeometry: roadGeometry,
            showSelectedStopSummary: false,
            onTileFailure: () {
              if (!mounted) return;
              setState(() {
                _mapTilesUnavailable = true;
                _showMap = false;
              });
            },
            onStopSelected: (String stopId) => _selectMapStop(
              context,
              routeDay: routeDay,
              plan: plan,
              user: user,
              progress: progress,
              stopId: stopId,
            ),
          ),
          if (selectedDayStop != null)
            buildStopTile(selectedDayStop)
          else
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: Text(
                selectedTargetStopId.isEmpty
                    ? 'No destination selected. Tap a pending stop marker or switch to List to choose one.'
                    : 'The selected stop is on another route day. Switch to List to view its actions.',
                style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
              ),
            ),
        ] else
          for (final stop in remainingStops) buildStopTile(stop),
      ],
    );
    if (compactHeader) {
      return Container(
        padding: const EdgeInsets.all(14),
        decoration: BoxDecoration(
          color: Colors.white,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(color: AppColors.inputBorder),
        ),
        child: content,
      );
    }
    return _withPersonalPlan(content);
  }

  Widget _withPersonalPlan(Widget primary) {
    final DateTime? date = widget.day?.date;
    return ListView(
      padding: const EdgeInsets.all(16),
      children: <Widget>[
        primary,
        if (date != null) _PersonalPlanSection(date: date),
      ],
    );
  }

  Future<void> _selectMapStop(
    BuildContext context, {
    required AssignedRouteDay routeDay,
    required AssignedRoutePlan plan,
    required UserModel user,
    required RouteProgress progress,
    required String stopId,
  }) async {
    AssignedRouteStop? stop;
    for (final AssignedRouteStop candidate in routeDay.stops) {
      if (candidate.stopId == stopId) {
        stop = candidate;
        break;
      }
    }
    if (stop == null) return;
    try {
      await widget.service.selectStop(
        plan: plan,
        stop: stop,
        user: user,
        progress: progress,
      );
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Only a pending stop on this assigned route can be selected.',
          ),
        ),
      );
    }
  }
}

class _PersonalPlanSection extends StatefulWidget {
  const _PersonalPlanSection({required this.date});

  final DateTime date;

  @override
  State<_PersonalPlanSection> createState() => _PersonalPlanSectionState();
}

class _PersonalPlanSectionState extends State<_PersonalPlanSection> {
  Stream<QuerySnapshot<Map<String, dynamic>>>? _stream;
  String _streamKey = '';

  Stream<QuerySnapshot<Map<String, dynamic>>> _visitsStream() {
    final String uid = (FirebaseAuth.instance.currentUser?.uid ?? '').trim();
    final DateTime date = widget.date;
    final String day =
        '${date.year}-${date.month.toString().padLeft(2, '0')}'
        '-${date.day.toString().padLeft(2, '0')}';
    final String key = '$uid|$day';
    if (_stream != null && _streamKey == key) return _stream!;
    _streamKey = key;
    return _stream = uid.isEmpty
        ? const Stream<QuerySnapshot<Map<String, dynamic>>>.empty()
        : FirebaseFirestore.instance
              .collection('visits')
              .where('ownerUid', isEqualTo: uid)
              .where('date', isEqualTo: day)
              .limit(200)
              .snapshots();
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<QuerySnapshot<Map<String, dynamic>>>(
      stream: _visitsStream(),
      builder: (context, snapshot) {
        final List<QueryDocumentSnapshot<Map<String, dynamic>>> visits =
            snapshot.data?.docs.toList() ??
            const <QueryDocumentSnapshot<Map<String, dynamic>>>[];
        if (visits.isEmpty) return const SizedBox.shrink();
        visits.sort(
          (a, b) => (a.data()['time'] as String? ?? '').compareTo(
            b.data()['time'] as String? ?? '',
          ),
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            const SizedBox(height: 14),
            Row(
              children: <Widget>[
                const Icon(
                  Icons.edit_calendar_outlined,
                  size: 15,
                  color: AppColors.textSecondary,
                ),
                const SizedBox(width: 6),
                Text(
                  'My plan (${visits.length})',
                  style: const TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                  ),
                ),
              ],
            ),
            const SizedBox(height: 6),
            ...visits.map((QueryDocumentSnapshot<Map<String, dynamic>> doc) {
              final Map<String, dynamic> data = doc.data();
              final String name =
                  (data['marketplace'] ?? data['retailerName'] ?? doc.id)
                      .toString();
              final String time = (data['time'] ?? '').toString();
              return Card(
                elevation: 0,
                margin: const EdgeInsets.only(bottom: 8),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(12),
                  side: BorderSide(color: Colors.grey.shade300),
                ),
                child: ListTile(
                  dense: true,
                  leading: const Icon(Icons.schedule, size: 18),
                  title: Text(
                    name,
                    style: const TextStyle(
                      fontSize: 13.5,
                      fontWeight: FontWeight.w600,
                    ),
                  ),
                  subtitle: Text(
                    time.isEmpty ? 'Personal visit' : '$time · Personal visit',
                    style: const TextStyle(fontSize: 11.5),
                  ),
                ),
              );
            }),
          ],
        );
      },
    );
  }
}

class _RouteStopTile extends StatelessWidget {
  const _RouteStopTile({
    required this.stop,
    required this.status,
    required this.arrivalMode,
    required this.progress,
    required this.isSelectedDestination,
    required this.isSuggestedTarget,
    required this.routeStatus,
    required this.plan,
    required this.user,
    required this.service,
    required this.copilotService,
    required this.brief,
    required this.isOnline,
    required this.currentFix,
    required this.estimateSourceLabel,
  });

  final AssignedRouteStop stop;
  final String status;
  final String arrivalMode;
  final RouteProgress progress;
  final bool isSelectedDestination;
  final bool isSuggestedTarget;
  final String routeStatus;
  final AssignedRoutePlan plan;
  final UserModel user;
  final RoutePlanService service;
  final SalesVisitCopilotService copilotService;
  final VisitBrief? brief;
  final bool isOnline;
  final DeviceLocationFix? currentFix;
  final String estimateSourceLabel;

  @override
  Widget build(BuildContext context) {
    final suggestion = brief?.routeIntelligence;
    final RetailerMemoryContext? embeddedMemory = brief?.retailerMemory;
    final bool hasEmbeddedMemory = hasUsableRetailerMemorySnapshot(
      embeddedMemory,
    );
    final bool isRemaining = !isTerminalStopStatus(status);
    final RetailerCoordinateSnapshot? coordinateSnapshot =
        stop.retailerCoordinateSnapshot;
    final String normalizedRouteStatus = routeStatus.trim().toLowerCase();
    final String identityCode = user.identityCode.trim();
    final bool assignedToUser =
        plan.salesmanUid.trim() == user.uid.trim() ||
        (identityCode.isNotEmpty && plan.salesmanCode.trim() == identityCode);
    final bool canSelectStop =
        isRemaining &&
        plan.status.trim().toLowerCase() == 'published' &&
        !plan.isDemo &&
        assignedToUser &&
        <String>{
          'assigned',
          'accepted',
          'in_progress',
        }.contains(normalizedRouteStatus);
    final canUpdate = canUpdateAssignedStop(
      routeStatus: routeStatus,
      stopStatus: status,
    );
    return Container(
      margin: const EdgeInsets.only(bottom: 10),
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.inputBorder),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              CircleAvatar(
                radius: 14,
                backgroundColor: AppColors.primary,
                child: Text(
                  '${stop.sequence}',
                  style: const TextStyle(
                    color: Colors.white,
                    fontWeight: FontWeight.bold,
                    fontSize: 12,
                  ),
                ),
              ),
              const SizedBox(width: 10),
              Expanded(
                child: LongNameText(
                  stop.retailerName,
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
              ),
              _Badge(_statusLabel(status)),
            ],
          ),
          if (isRemaining && (isSelectedDestination || isSuggestedTarget)) ...[
            const SizedBox(height: 8),
            Row(
              children: [
                Icon(
                  isSelectedDestination
                      ? Icons.near_me
                      : Icons.near_me_outlined,
                  size: 16,
                  color: AppColors.primary,
                ),
                const SizedBox(width: 6),
                Text(
                  isSelectedDestination
                      ? 'Selected destination'
                      : 'Suggested first pending stop · not selected',
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w700,
                    color: AppColors.primary,
                  ),
                ),
              ],
            ),
          ],
          if (isRemaining &&
              isSelectedDestination &&
              (coordinateSnapshot?.isVerified != true ||
                  (isOnline &&
                      coordinateSnapshot!.coordinateRevision
                          .trim()
                          .isEmpty))) ...[
            const SizedBox(height: 7),
            Text(
              coordinateSnapshot == null
                  ? 'No verified pin was saved with this route. GPS arrival needs an online retailer check; offline arrivals can only be recorded as unverified.'
                  : !coordinateSnapshot.isVerified
                  ? 'This retailer pin needs review. GPS arrival confirmation is disabled until an administrator refreshes the route.'
                  : 'This pin has no saved coordinate revision. Ask an administrator to refresh the route before GPS arrival confirmation.',
              style: const TextStyle(fontSize: 12, color: Color(0xFFB54708)),
            ),
          ],
          if (isRemaining && suggestion != null) ...[
            const SizedBox(height: 7),
            _RouteAttentionSuggestion(
              suggestion: suggestion,
              showEarlierHint:
                  suggestion.considerVisitingEarlier && stop.sequence > 1,
            ),
          ],
          if (stop.address.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(stop.address, style: const TextStyle(fontSize: 12)),
          ],
          const SizedBox(height: 6),
          Text(
            [
              if (stop.estimatedArrival.isNotEmpty) stop.estimatedArrival,
              if (stop.estimatedDeparture.isNotEmpty) stop.estimatedDeparture,
            ].join(' - '),
            style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
          ),
          if (stop.travelMinutesFromPrevious > 0) ...[
            const SizedBox(height: 4),
            Text(
              '~${stop.travelMinutesFromPrevious} min · $estimateSourceLabel',
              style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
            ),
          ],
          if (stop.priorityReason.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              'Reason when planned: ${stop.priorityReason}',
              style: const TextStyle(fontSize: 12, color: AppColors.textGrey),
            ),
          ],
          if (arrivalMode.isNotEmpty) ...[
            const SizedBox(height: 6),
            Text(
              arrivalMode == 'location_verified'
                  ? 'Arrival: GPS verified'
                  : 'Arrival: unverified · manager review pending',
              style: TextStyle(
                fontSize: 12,
                fontWeight: FontWeight.w600,
                color: arrivalMode == 'location_verified'
                    ? const Color(0xFF166534)
                    : const Color(0xFFB45309),
              ),
            ),
          ],
          const SizedBox(height: 10),
          Wrap(
            spacing: 8,
            runSpacing: 8,
            children: [
              if (canSelectStop)
                OutlinedButton.icon(
                  onPressed: isSelectedDestination
                      ? null
                      : () => _selectStop(context),
                  icon: Icon(
                    isSelectedDestination
                        ? Icons.check_circle_outline
                        : Icons.near_me_outlined,
                    size: 17,
                  ),
                  label: Text(
                    isSelectedDestination
                        ? 'Selected destination'
                        : 'Go to this stop',
                  ),
                ),
              OutlinedButton(
                onPressed: canUpdate && status != 'arrived'
                    ? () => _updateStop(context, 'arrived')
                    : null,
                child: const Text('Mark arrived'),
              ),
              FilledButton.icon(
                onPressed: canUpdate ? () => _openGuidedVisit(context) : null,
                icon: const Icon(Icons.storefront_outlined, size: 18),
                label: const Text('Open visit'),
              ),
              OutlinedButton(
                onPressed: canUpdate ? () => _showSkipDialog(context) : null,
                child: const Text('Skip'),
              ),
              TextButton.icon(
                onPressed: () =>
                    service.openStopInGoogleMaps(stop, originFix: currentFix),
                icon: const Icon(Icons.map_outlined, size: 17),
                label: const Text('Google Maps'),
              ),
            ],
          ),
          if (brief != null &&
              (brief!.hasFieldGuidance || hasEmbeddedMemory)) ...[
            const SizedBox(height: 12),
            _SalesVisitCopilotCard(
              brief: brief!,
              stopStatus: status,
              onRecordOutcome: (insight) =>
                  _recordOutcome(context, brief!, insight),
            ),
          ],
          if (!kBasicEdition) ...[
            const SizedBox(height: 12),
            RetailerOwnHistoryCard(
              key: ValueKey<String>(
                'retailer-history:${user.uid}:${stop.retailerId}',
              ),
              identity: '${user.uid}\u0000${stop.retailerId}',
              deferInitialLoad: hasEmbeddedMemory,
              hasEmbeddedSnapshot: hasEmbeddedMemory,
              loadMemory: ({required bool refresh}) =>
                  copilotService.loadRetailerMemory(
                    user: user,
                    retailerId: stop.retailerId,
                    forceRefresh: refresh,
                  ),
            ),
          ],
        ],
      ),
    );
  }

  Future<void> _selectStop(BuildContext context) async {
    try {
      final RouteProgressWriteState result = await service.selectStop(
        plan: plan,
        stop: stop,
        user: user,
        progress: progress,
      );
      if (result == RouteProgressWriteState.pending && context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text('Destination saved on this device and pending sync.'),
          ),
        );
      }
    } catch (_) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text(
            'Stop could not be selected. Check the route and connection.',
          ),
        ),
      );
    }
  }

  Future<void> _updateStop(BuildContext context, String nextStatus) async {
    if (nextStatus == 'arrived') {
      final GpsProvider gps = context.read<GpsProvider>();
      if (!gps.hasArrivalReadySession) {
        ScaffoldMessenger.of(context).showSnackBar(
          SnackBar(
            content: const Text('Start work first'),
            action: SnackBarAction(
              label: 'Start work',
              onPressed: () =>
                  unawaited(gps.startTracking(user: user, explicit: true)),
            ),
          ),
        );
        return;
      }
    }
    try {
      final StopArrivalEvidence? evidence = nextStatus == 'arrived'
          ? await collectSelectedStopArrivalEvidence(
              context,
              plan: plan,
              stop: stop,
              progress: progress,
              isOnline: isOnline,
            )
          : null;
      if (nextStatus == 'arrived' && evidence == null) return;
      final RouteProgressWriteState result = await service.updateStopStatus(
        plan: plan,
        stop: stop,
        user: user,
        status: nextStatus,
        arrivalEvidence: evidence,
        progress: progress,
      );
      if (!context.mounted) return;
      _showStopEventResult(
        context,
        result,
        service,
        plan,
        user,
        progress,
        stop.stopId,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            stopSaveFailureMessage(
              error,
              fallback: 'Stop could not be updated. Check your connection.',
            ),
          ),
        ),
      );
    }
  }

  Future<void> _openGuidedVisit(BuildContext context) async {
    final GuidedVisitContext visitContext = GuidedVisitContext(
      planId: plan.id,
      stopId: stop.stopId,
      branchId: plan.branchId,
      retailerLatitude: stop.lat,
      retailerLongitude: stop.lng,
    );
    await Navigator.of(context).push(
      MaterialPageRoute<bool>(
        settings: RouteSettings(name: visitContext.routeName),
        builder: (_) => GuidedVisitScreen(
          plan: plan,
          stop: stop,
          user: user,
          stopStatus: status,
          progress: progress,
          service: service,
          copilotService: copilotService,
          brief: brief,
        ),
      ),
    );
  }

  Future<void> _recordOutcome(
    BuildContext context,
    VisitBrief brief,
    VisitBriefInsight insight,
  ) async {
    final draft = await _showOutcomeDialog(context, insight);
    if (draft == null || !context.mounted) return;
    try {
      final result = await copilotService.queueOutcome(
        user: user,
        branchId: plan.branchId,
        planId: plan.id,
        stopId: stop.stopId,
        brief: brief,
        insight: insight,
        reasonCode: draft.reasonCode,
        note: draft.note,
        replacementProductId: draft.replacementProductId,
        isOnline: isOnline,
      );
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            result.synced
                ? 'Conversation outcome synced.'
                : 'Outcome saved on this device and queued for sync.',
          ),
        ),
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save this outcome. Check the fields.'),
        ),
      );
    }
  }

  Future<void> _showSkipDialog(BuildContext context) async {
    const reasons = [
      'Retailer closed',
      'Customer unavailable',
      'No order needed',
      'Wrong location',
      'Emergency / time issue',
      'Other',
    ];
    final reason = await showModalBottomSheet<String>(
      context: context,
      builder: (context) => SafeArea(
        child: ListView(
          shrinkWrap: true,
          children: [
            const Padding(
              padding: EdgeInsets.all(16),
              child: Text(
                'Skip reason',
                style: TextStyle(fontSize: 18, fontWeight: FontWeight.bold),
              ),
            ),
            for (final item in reasons)
              ListTile(
                title: Text(item),
                onTap: () => Navigator.pop(context, item),
              ),
          ],
        ),
      ),
    );
    if (reason == null) return;
    String? note;
    if (reason == 'Other') {
      if (!context.mounted) return;
      note = await _promptForNote(context);
      if (note == null || note.isEmpty) return;
    }
    try {
      final RouteProgressWriteState result = await service.updateStopStatus(
        plan: plan,
        stop: stop,
        user: user,
        status: 'skipped',
        skipReason: reason,
        notes: note,
        progress: progress,
      );
      if (!context.mounted) return;
      _showStopEventResult(
        context,
        result,
        service,
        plan,
        user,
        progress,
        stop.stopId,
      );
    } catch (error) {
      if (!context.mounted) return;
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: Text(
            stopSaveFailureMessage(
              error,
              fallback: 'Stop could not be skipped. Try again.',
            ),
          ),
        ),
      );
    }
  }

  Future<String?> _promptForNote(BuildContext context) async {
    final controller = TextEditingController();
    final note = await showDialog<String>(
      context: context,
      builder: (context) => AlertDialog(
        title: const Text('Add a note'),
        content: TextField(
          controller: controller,
          autofocus: true,
          maxLines: 3,
          textCapitalization: TextCapitalization.sentences,
          decoration: const InputDecoration(
            hintText: 'Required when the reason is "Other"',
          ),
        ),
        actions: [
          TextButton(
            onPressed: () => Navigator.pop(context),
            child: const Text('Cancel'),
          ),
          FilledButton(
            onPressed: () => Navigator.pop(context, controller.text.trim()),
            child: const Text('Save'),
          ),
        ],
      ),
    );
    controller.dispose();
    return note;
  }
}

class _SelectedStopArrivalPrompt extends StatefulWidget {
  const _SelectedStopArrivalPrompt({
    required this.plan,
    required this.progress,
    required this.selectedStopId,
    required this.selectionRevision,
    required this.user,
    required this.service,
    required this.isOnline,
    required this.currentFix,
  });

  final AssignedRoutePlan plan;
  final RouteProgress progress;
  final String selectedStopId;
  final int selectionRevision;
  final UserModel user;
  final RoutePlanService service;
  final bool isOnline;
  final DeviceLocationFix? currentFix;

  @override
  State<_SelectedStopArrivalPrompt> createState() =>
      _SelectedStopArrivalPromptState();
}

class _SelectedStopArrivalPromptState
    extends State<_SelectedStopArrivalPrompt> {
  String _dismissedStopId = '';
  bool _submitting = false;

  @override
  void didUpdateWidget(covariant _SelectedStopArrivalPrompt oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.plan.id != widget.plan.id ||
        oldWidget.selectedStopId != widget.selectedStopId ||
        oldWidget.selectionRevision != widget.selectionRevision ||
        oldWidget.isOnline != widget.isOnline) {
      _dismissedStopId = '';
      return;
    }
    final DeviceLocationFix? fix = widget.currentFix;
    final DeviceLocationFix? oldFix = oldWidget.currentFix;
    if (_dismissedStopId.isEmpty ||
        fix == null ||
        oldFix?.capturedAt == fix.capturedAt ||
        !isReliableArrivalFix(fix)) {
      return;
    }
    final AssignedRouteStop? stop = selectedPendingRouteStop(
      widget.plan,
      widget.progress,
    );
    final RetailerCoordinateSnapshot? snapshot =
        stop?.retailerCoordinateSnapshot;
    if (stop == null ||
        stop.stopId != _dismissedStopId ||
        snapshot?.isVerified != true) {
      _dismissedStopId = '';
      return;
    }
    final double? distance = distanceToStopMeters(
      currentLat: fix.latitude,
      currentLng: fix.longitude,
      stopLat: snapshot!.latitude!,
      stopLng: snapshot.longitude!,
    );
    if (distance != null && distance > kArrivalMaxDistanceMeters) {
      _dismissedStopId = '';
    }
  }

  @override
  Widget build(BuildContext context) {
    if (widget.progress.status != 'in_progress' ||
        widget.selectedStopId.isEmpty) {
      return const SizedBox.shrink();
    }
    final AssignedRouteStop? stop = selectedPendingRouteStop(
      widget.plan,
      widget.progress,
    );
    final DeviceLocationFix? fix = widget.currentFix;
    final RetailerCoordinateSnapshot? snapshot =
        stop?.retailerCoordinateSnapshot;
    if (stop == null ||
        stop.stopId != widget.selectedStopId ||
        widget.progress.statusFor(stop.stopId, stop.status).toLowerCase() ==
            'arrived' ||
        snapshot?.isVerified != true ||
        (widget.isOnline && snapshot!.coordinateRevision.trim().isEmpty) ||
        fix == null) {
      return const SizedBox.shrink();
    }
    final NearbyHint? hint = selectedStopWithinRadius(
      selectedStopId: widget.selectedStopId,
      stop: NearbyStop(
        stopId: stop.stopId,
        retailerName: stop.retailerName,
        lat: snapshot!.latitude!,
        lng: snapshot.longitude!,
        coordinatesVerified: snapshot.isVerified,
        isPending: true,
      ),
      currentLat: fix.latitude,
      currentLng: fix.longitude,
      currentFixReliable: isReliableArrivalFix(fix),
    );
    if (hint == null || _dismissedStopId == hint.stopId) {
      return const SizedBox.shrink();
    }
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: _NearbyStopBanner(
        hint: hint,
        isOnline: widget.isOnline,
        isSubmitting: _submitting,
        onDismiss: () => setState(() => _dismissedStopId = hint.stopId),
        onConfirm: () => _confirmArrival(
          context,
          stop,
          hint.stopId,
          widget.selectionRevision,
        ),
      ),
    );
  }

  Future<void> _confirmArrival(
    BuildContext context,
    AssignedRouteStop stop,
    String promptedStopId,
    int promptedSelectionRevision,
  ) async {
    if (_submitting ||
        promptedStopId != widget.selectedStopId ||
        promptedSelectionRevision != widget.selectionRevision ||
        widget.progress.statusFor(stop.stopId, stop.status).toLowerCase() ==
            'arrived') {
      return;
    }
    setState(() => _submitting = true);
    try {
      final StopArrivalEvidence? evidence = await collectStopArrivalEvidence(
        context,
        stop,
        isOnline: widget.isOnline,
        publishedSnapshotAt: widget.plan.publishedAt,
      );
      if (evidence == null || !mounted) return;
      final AssignedRouteStop? selectedNow = selectedPendingRouteStop(
        widget.plan,
        widget.progress,
      );
      if (widget.selectedStopId != promptedStopId ||
          widget.selectionRevision != promptedSelectionRevision ||
          selectedNow?.stopId != promptedStopId ||
          widget.progress.statusFor(stop.stopId, stop.status).toLowerCase() ==
              'arrived') {
        return;
      }
      final RouteProgressWriteState result = await widget.service
          .updateStopStatus(
            plan: widget.plan,
            stop: stop,
            user: widget.user,
            status: 'arrived',
            arrivalEvidence: evidence,
            progress: widget.progress,
          );
      if (!context.mounted) return;
      setState(() => _dismissedStopId = promptedStopId);
      _showStopEventResult(
        context,
        result,
        widget.service,
        widget.plan,
        widget.user,
        widget.progress,
        stop.stopId,
      );
    } catch (_) {
      if (context.mounted) {
        ScaffoldMessenger.of(context).showSnackBar(
          const SnackBar(
            content: Text(
              'Stop could not be updated. Check the route and connection.',
            ),
          ),
        );
      }
    } finally {
      if (mounted) setState(() => _submitting = false);
    }
  }
}

class _NearbyStopBanner extends StatelessWidget {
  const _NearbyStopBanner({
    required this.hint,
    required this.isOnline,
    required this.isSubmitting,
    required this.onConfirm,
    required this.onDismiss,
  });

  final NearbyHint hint;
  final bool isOnline;
  final bool isSubmitting;
  final VoidCallback onConfirm;
  final VoidCallback onDismiss;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.08),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: AppColors.primary.withValues(alpha: 0.35)),
      ),
      child: Row(
        children: [
          CircleAvatar(
            radius: 18,
            backgroundColor: AppColors.primary.withValues(alpha: 0.16),
            child: const Icon(
              Icons.my_location,
              size: 18,
              color: AppColors.primary,
            ),
          ),
          const SizedBox(width: 10),
          Expanded(
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  isOnline
                      ? 'You may have arrived at ${hint.retailerName}'
                      : 'Near the published pin for ${hint.retailerName}',
                  style: const TextStyle(
                    fontWeight: FontWeight.bold,
                    color: AppColors.textPrimary,
                  ),
                ),
                const SizedBox(height: 2),
                Text(
                  isOnline
                      ? 'GPS is within 75 m of the verified pin saved in this route. Confirmation checks the current retailer record and takes a fresh fix.'
                      : 'Within ${hint.roundedMeters} m of the route snapshot. Offline arrivals can only be recorded as unverified.',
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textGrey,
                  ),
                ),
                Wrap(
                  spacing: 6,
                  children: [
                    TextButton(
                      onPressed: isSubmitting ? null : onDismiss,
                      child: const Text('Not now'),
                    ),
                    FilledButton(
                      onPressed: isSubmitting ? null : onConfirm,
                      child: Text(
                        isSubmitting
                            ? 'Checking…'
                            : isOnline
                            ? 'Mark arrived'
                            : 'Record unverified',
                      ),
                    ),
                  ],
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _RouteAttentionSuggestion extends StatelessWidget {
  const _RouteAttentionSuggestion({
    required this.suggestion,
    required this.showEarlierHint,
  });

  final RouteIntelligenceSuggestion suggestion;
  final bool showEarlierHint;

  @override
  Widget build(BuildContext context) {
    final urgent = suggestion.priority == 'urgent';
    final high = suggestion.priority == 'high';
    final foreground = urgent
        ? const Color(0xFFB42318)
        : high
        ? const Color(0xFFB54708)
        : const Color(0xFF175CD3);
    final background = urgent
        ? const Color(0xFFFEF3F2)
        : high
        ? const Color(0xFFFFFAEB)
        : const Color(0xFFEFF8FF);
    return Wrap(
      spacing: 7,
      runSpacing: 5,
      crossAxisAlignment: WrapCrossAlignment.center,
      children: [
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
          decoration: BoxDecoration(
            color: background,
            borderRadius: BorderRadius.circular(999),
          ),
          child: Text(
            '${suggestion.priority.toUpperCase()} • ${suggestion.attentionScore}/100',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w800,
              color: foreground,
            ),
          ),
        ),
        if (showEarlierHint)
          const Text(
            'Consider visiting earlier',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w700,
              color: Color(0xFFB54708),
            ),
          ),
      ],
    );
  }
}

class _SalesVisitCopilotCard extends StatelessWidget {
  const _SalesVisitCopilotCard({
    required this.brief,
    required this.stopStatus,
    required this.onRecordOutcome,
  });

  final VisitBrief brief;
  final String stopStatus;
  final ValueChanged<VisitBriefInsight> onRecordOutcome;

  @override
  Widget build(BuildContext context) {
    final canRecord = stopStatus == 'arrived' || stopStatus == 'completed';
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(12),
      decoration: BoxDecoration(
        color: const Color(0xFFF5F3FF),
        borderRadius: BorderRadius.circular(12),
        border: Border.all(color: const Color(0xFFDDD6FE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          Row(
            children: [
              const Icon(
                Icons.psychology_alt_outlined,
                color: Color(0xFF6D28D9),
              ),
              const SizedBox(width: 8),
              const Expanded(
                child: Text(
                  'Sales Visit Scout',
                  style: TextStyle(
                    fontWeight: FontWeight.bold,
                    color: Color(0xFF4C1D95),
                  ),
                ),
              ),
              if (brief.highPriorityCount > 0)
                _Badge('${brief.highPriorityCount} high'),
            ],
          ),
          const SizedBox(height: 6),
          Text(
            'Suggested questions based on recent structured sales signals. Verify with the retailer.',
            style: TextStyle(fontSize: 12, color: Colors.deepPurple.shade700),
          ),
          const SizedBox(height: 10),
          TodaysFocusCard(brief: brief),
          const SizedBox(height: 8),
          if (brief.retailerMemory case final memory? when memory.isActive) ...[
            RetailerMemorySnapshotCard(memory: memory),
            const SizedBox(height: 8),
          ],
          if (brief.replenishment.isNotEmpty) ...[
            ReplenishmentSuggestionsCard(
              retailerId: brief.retailerId,
              suggestions: brief.replenishment,
              productNames: <String, String>{
                for (final insight in brief.topInsights)
                  if (insight.productId.isNotEmpty)
                    insight.productId: insight.productName,
              },
            ),
            const SizedBox(height: 8),
          ],
          for (final insight in brief.topInsights) ...[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(bottom: 8),
              padding: const EdgeInsets.all(10),
              decoration: BoxDecoration(
                color: Colors.white,
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    insight.productName,
                    style: const TextStyle(fontWeight: FontWeight.bold),
                  ),
                  if (insight.reason.isNotEmpty) ...[
                    const SizedBox(height: 4),
                    Text(
                      insight.reason,
                      style: const TextStyle(
                        fontSize: 12,
                        color: AppColors.textGrey,
                      ),
                    ),
                  ],
                  for (final question in insight.questions) ...[
                    const SizedBox(height: 5),
                    Text('• $question', style: const TextStyle(fontSize: 12)),
                  ],
                  const SizedBox(height: 8),
                  Align(
                    alignment: Alignment.centerRight,
                    child: TextButton.icon(
                      onPressed: canRecord
                          ? () => onRecordOutcome(insight)
                          : null,
                      icon: const Icon(Icons.fact_check_outlined, size: 17),
                      label: const Text('Record outcome'),
                    ),
                  ),
                ],
              ),
            ),
          ],
          if (!canRecord)
            const Text(
              'Mark this stop arrived before recording the conversation outcome.',
              style: TextStyle(fontSize: 11, color: AppColors.textGrey),
            ),
        ],
      ),
    );
  }
}

class _OutcomeDraft {
  const _OutcomeDraft({
    required this.reasonCode,
    required this.note,
    required this.replacementProductId,
  });

  final String reasonCode;
  final String note;
  final String replacementProductId;
}

Future<_OutcomeDraft?> _showOutcomeDialog(
  BuildContext context,
  VisitBriefInsight insight,
) async {
  final noteController = TextEditingController();
  final replacementController = TextEditingController();
  var selectedReasonCode = '';
  var showNoteField = false;
  var validationMessage = '';

  final result = await showModalBottomSheet<_OutcomeDraft>(
    context: context,
    isScrollControlled: true,
    builder: (context) => StatefulBuilder(
      builder: (context, setState) {
        return SafeArea(
          child: Padding(
            padding: EdgeInsets.only(
              bottom: MediaQuery.of(context).viewInsets.bottom,
              left: 16,
              right: 16,
              top: 16,
            ),
            child: SingleChildScrollView(
              child: Column(
                mainAxisSize: MainAxisSize.min,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: [
                  Text(
                    'Record outcome • ${insight.productName}',
                    style: const TextStyle(
                      fontWeight: FontWeight.bold,
                      fontSize: 16,
                    ),
                  ),
                  const SizedBox(height: 16),
                  if (!showNoteField &&
                      selectedReasonCode != 'other' &&
                      selectedReasonCode != 'switched_to_alternative')
                    TextButton.icon(
                      onPressed: () => setState(() => showNoteField = true),
                      icon: const Icon(Icons.note_add_outlined),
                      label: const Text('Add note (optional)'),
                    ),
                  if (showNoteField || selectedReasonCode == 'other') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: noteController,
                      maxLength: 500,
                      maxLines: 2,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: const InputDecoration(
                        labelText: 'Conversation note',
                      ),
                    ),
                  ],
                  const SizedBox(height: 16),
                  Wrap(
                    spacing: 8,
                    runSpacing: 8,
                    children: _outcomeReasonLabels.entries.map((entry) {
                      final isSelected = selectedReasonCode == entry.key;
                      return ActionChip(
                        label: Text(entry.value),
                        backgroundColor: isSelected ? AppColors.primary : null,
                        labelStyle: TextStyle(
                          color: isSelected ? Colors.white : null,
                        ),
                        onPressed: () {
                          final reasonCode = entry.key;
                          final note = noteController.text.trim();

                          if (reasonCode != 'other' &&
                              reasonCode != 'switched_to_alternative') {
                            Navigator.pop(
                              context,
                              _OutcomeDraft(
                                reasonCode: reasonCode,
                                note: note,
                                replacementProductId: '',
                              ),
                            );
                            return;
                          }

                          setState(() {
                            selectedReasonCode = reasonCode;
                            validationMessage = '';
                            if (reasonCode == 'other') {
                              showNoteField = true;
                            }
                          });
                        },
                      );
                    }).toList(),
                  ),
                  if (selectedReasonCode == 'switched_to_alternative') ...[
                    const SizedBox(height: 12),
                    TextField(
                      controller: replacementController,
                      decoration: const InputDecoration(
                        labelText: 'Replacement product ID',
                        hintText: 'Example: P004',
                      ),
                    ),
                  ],
                  if (validationMessage.isNotEmpty) ...[
                    const SizedBox(height: 8),
                    Text(
                      validationMessage,
                      style: const TextStyle(
                        color: AppColors.textRed,
                        fontSize: 12,
                      ),
                    ),
                  ],
                  if (selectedReasonCode == 'other' ||
                      selectedReasonCode == 'switched_to_alternative') ...[
                    const SizedBox(height: 12),
                    FilledButton(
                      onPressed: () {
                        final note = noteController.text.trim();
                        final replacement = replacementController.text.trim();

                        if (selectedReasonCode == 'other' && note.length < 8) {
                          setState(() {
                            validationMessage =
                                'Other requires a meaningful note.';
                          });
                          return;
                        }
                        if (selectedReasonCode == 'switched_to_alternative' &&
                            replacement.isEmpty) {
                          setState(() {
                            validationMessage =
                                'Enter the replacement product ID.';
                          });
                          return;
                        }

                        Navigator.pop(
                          context,
                          _OutcomeDraft(
                            reasonCode: selectedReasonCode,
                            note: note,
                            replacementProductId: replacement,
                          ),
                        );
                      },
                      child: const Text('Save outcome'),
                    ),
                  ],
                  const SizedBox(height: 16),
                ],
              ),
            ),
          ),
        );
      },
    ),
  );

  noteController.dispose();
  replacementController.dispose();
  return result;
}

const Map<String, String> _outcomeReasonLabels = <String, String>{
  'low_sell_through': 'Low sell-through',
  'price_too_high': 'Price too high',
  'switched_to_alternative': 'Switched to alternative',
  'supplier_issue': 'Supplier issue',
  'out_of_stock': 'Out of stock',
  'shelf_space_limited': 'Shelf space limited',
  'cash_flow_issue': 'Cash-flow issue',
  'seasonal_change': 'Seasonal change',
  'not_decision_maker': 'Not the decision maker',
  'not_asked_today': 'Not asked today',
  'retailer_busy': 'Retailer busy',
  'decision_maker_unavailable': 'Decision maker unavailable',
  'competitor_promotion': 'Competitor promotion',
  'packaging_change': 'Packaging change',
  'quality_complaint': 'Quality complaint',
  'other': 'Other',
};

class _PreviewCard extends StatelessWidget {
  const _PreviewCard({
    required this.title,
    required this.subtitle,
    required this.onTap,
  });

  final String title;
  final String subtitle;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      button: true,
      child: InkWell(
        onTap: onTap,
        borderRadius: ScootRadius.cardAll,
        child: Container(
          width: double.infinity,
          padding: const EdgeInsets.all(14),
          decoration: BoxDecoration(
            color: c.card,
            border: Border.all(color: c.line),
            borderRadius: ScootRadius.cardAll,
          ),
          child: Row(
            children: [
              Container(
                width: 40,
                height: 40,
                decoration: BoxDecoration(
                  color: c.brandTint,
                  borderRadius: ScootRadius.controlAll,
                ),
                child: Icon(ScootIcons.route, color: c.brandText, size: 20),
              ),
              const SizedBox(width: 12),
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: [
                    Text(
                      title,
                      style: ScootType.bodyStrong.copyWith(color: c.ink),
                    ),
                    Text(
                      subtitle,
                      style: ScootType.small.copyWith(color: c.text2),
                    ),
                  ],
                ),
              ),
              Icon(ScootIcons.chevronRight, color: c.text2),
            ],
          ),
        ),
      ),
    );
  }
}

class _PreviewCardSkeleton extends StatelessWidget {
  const _PreviewCardSkeleton();

  @override
  Widget build(BuildContext context) {
    return Container(
      height: 72,
      decoration: BoxDecoration(
        color: ScootColors.of(context).card,
        border: Border.all(color: ScootColors.of(context).line),
        borderRadius: ScootRadius.cardAll,
      ),
    );
  }
}

class _Badge extends StatelessWidget {
  const _Badge(this.label);

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
      decoration: BoxDecoration(
        color: AppColors.primary.withValues(alpha: 0.1),
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: const TextStyle(
          fontSize: 11,
          color: AppColors.primary,
          fontWeight: FontWeight.bold,
        ),
      ),
    );
  }
}

class _RouteEmptyState extends StatelessWidget {
  const _RouteEmptyState({
    required this.icon,
    required this.title,
    required this.subtitle,
  });

  final IconData icon;
  final String title;
  final String subtitle;

  @override
  Widget build(BuildContext context) {
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: [
            Icon(icon, size: 42, color: AppColors.textSecondary),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: const TextStyle(color: AppColors.textGrey),
            ),
          ],
        ),
      ),
    );
  }
}

String _statusLabel(String status) {
  switch (status) {
    case 'accepted':
      return 'Accepted';
    case 'in_progress':
      return 'In progress';
    case 'completed':
      return 'Completed';
    case 'arrived':
      return 'Arrived';
    case 'skipped':
      return 'Skipped';
    case 'not_started':
      return 'Not started';
    default:
      return 'Assigned';
  }
}

void _showStopEventResult(
  BuildContext context,
  RouteProgressWriteState result,
  RoutePlanService service,
  AssignedRoutePlan plan,
  UserModel user,
  RouteProgress progress,
  String stopId, {
  bool afterManualRetry = false,
}) {
  if (!context.mounted ||
      (result == RouteProgressWriteState.synced && !afterManualRetry)) {
    return;
  }
  final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
  messenger.hideCurrentSnackBar();
  switch (result) {
    case RouteProgressWriteState.synced:
      messenger.showSnackBar(
        const SnackBar(content: Text('Stop update synced.')),
      );
      break;
    case RouteProgressWriteState.pending:
      messenger.showSnackBar(
        const SnackBar(content: Text('Stop update is saved and pending sync.')),
      );
      break;
    case RouteProgressWriteState.needsAttention:
      unawaited(
        service
            .stopEventAttentionReason(plan: plan, user: user, stopId: stopId)
            .then((String? reason) {
              if (!context.mounted) return;
              messenger.showSnackBar(
                SnackBar(
                  content: Text(stopAttentionMessage(reason)),
                  action: SnackBarAction(
                    label: 'Retry',
                    onPressed: () async {
                      final RouteProgressWriteState retry = await service
                          .retryPendingStopEvents(
                            plan: plan,
                            user: user,
                            progress: progress,
                          );
                      if (context.mounted) {
                        _showStopEventResult(
                          context,
                          retry,
                          service,
                          plan,
                          user,
                          progress,
                          stopId,
                          afterManualRetry: true,
                        );
                      }
                    },
                  ),
                ),
              );
            }),
      );
      break;
  }
}
