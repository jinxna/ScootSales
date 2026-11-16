import 'dart:async';

import 'package:firebase_auth/firebase_auth.dart' hide AuthProvider;
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import 'package:provider/provider.dart';

import '../copilot/mobile_copilot_commands.dart';
import '../copilot/mobile_copilot_page.dart';
import '../edition.dart';
import '../models/assigned_route_plan.dart';
import '../models/guided_visit_context.dart';
import '../models/user_model.dart';
import '../models/visit_brief.dart';
import '../providers/connectivity_provider.dart';
import '../providers/auth_provider.dart';
import '../providers/gps_provider.dart';
import '../services/cart_draft_cache.dart';
import '../services/assigned_visit_order_recovery.dart';
import '../services/guided_visit_session_store.dart';
import '../services/route_plan_service.dart';
import '../services/sales_visit_copilot_service.dart';
import '../theme/app_theme.dart';
import '../utils/guided_visit_state.dart';
import '../utils/retailer_memory.dart';
import '../widgets/replenishment_suggestions.dart';
import '../widgets/arrival_verification_flow.dart';
import '../widgets/location_status_banner.dart';
import '../widgets/no_order_reason_sheet.dart';
import '../widgets/phone_status_strip.dart';
import 'add_to_cart.dart';
import 'order_cart_screen.dart';
import 'order_signature_screen.dart';
import 'order_history_screen.dart';
import '../voice/core/action_registry.dart';
import '../voice/core/voice_binding.dart';
import '../voice/core/voice_dispatcher.dart';
import '../voice/core/voice_engine.dart';
import '../voice/core/voice_types.dart';
import '../voice/voice_registry_factory.dart';
import '../widgets/long_name_text.dart';

class GuidedVisitScreen extends StatefulWidget {
  const GuidedVisitScreen({
    super.key,
    required this.plan,
    required this.stop,
    required this.user,
    required this.stopStatus,
    required this.progress,
    required this.service,
    required this.copilotService,
    required this.brief,
    this.openCartInitially = false,
  });

  final AssignedRoutePlan plan;
  final AssignedRouteStop stop;
  final UserModel user;
  final String stopStatus;
  final RouteProgress progress;
  final RoutePlanService service;
  final SalesVisitCopilotService copilotService;
  final VisitBrief? brief;
  final bool openCartInitially;

  @override
  State<GuidedVisitScreen> createState() => _GuidedVisitScreenState();
}

class _GuidedVisitScreenState extends State<GuidedVisitScreen> {
  GuidedVisitStage _stage = GuidedVisitStage.prepare;
  GuidedVisitSessionState _session = const GuidedVisitSessionState();
  late String _stopStatus;
  late RouteProgress _progress;
  bool _busy = false;
  StreamSubscription<RouteProgress>? _completionSubscription;
  late final VoiceScreenBinding _voiceBinding;
  late final VoiceCommandEngine _voiceEngine;

  GuidedVisitContext get _context => GuidedVisitContext(
    planId: widget.plan.id,
    stopId: widget.stop.stopId,
    branchId: widget.plan.branchId,
    retailerLatitude: widget.stop.lat,
    retailerLongitude: widget.stop.lng,
  );

  String get _draftKey => CartDraftCache.keyFor(
    salesmanUid: FirebaseAuth.instance.currentUser?.uid.trim() ?? '',
    retailerId: widget.stop.retailerId,
    routePlanId: widget.plan.id,
    routeStopId: widget.stop.stopId,
  );

  CartDraftSnapshot? get _draft => CartDraftCache.read(_draftKey);

  @override
  void initState() {
    super.initState();
    _stopStatus = widget.stopStatus;
    _progress = widget.progress;
    _voiceBinding = VoiceScreenBinding(surfaceId: VoiceSurfaceIds.guidedVisit);
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
      sessionId: 'guided-visit-${DateTime.now().microsecondsSinceEpoch}',
      binding: _voiceBinding,
      dispatcher: VoiceActionDispatcher(
        registry: buildVoiceActionRegistry(),
        binding: _voiceBinding,
      ),
    );
    unawaited(_initialise());
  }

  Future<void> _initialise() async {
    await _reloadSession();
    if (widget.openCartInitially && mounted) await _openOrderFlow();
  }

  Future<void> _reloadSession() async {
    final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (uid.isEmpty || uid != widget.user.uid.trim()) {
      if (mounted) {
        setState(
          () => _session = const GuidedVisitSessionState(
            orderRecoveryBlocked: true,
          ),
        );
      }
      return;
    }
    GuidedVisitSessionState session = await GuidedVisitSessionStore.read(
      salesmanUid: uid,
      routePlanId: widget.plan.id,
      routeStopId: widget.stop.stopId,
    );
    if (!session.outcomeRecorded) {
      final AssignedVisitOrderRecoveryResult recovery =
          await AssignedVisitOrderRecovery().resolve(
            salesmanUid: uid,
            retailerId: widget.stop.retailerId,
            routePlanId: widget.plan.id,
            routeStopId: widget.stop.stopId,
          );
      switch (recovery.status) {
        case AssignedVisitOrderRecoveryStatus.submitted:
          if (!session.orderSubmitted) {
            await GuidedVisitSessionStore.markOrderSubmitted(
              salesmanUid: uid,
              routePlanId: widget.plan.id,
              routeStopId: widget.stop.stopId,
            );
          }
          session = session.copyWith(
            orderSubmitted: true,
            orderPending: false,
            orderRecoveryBlocked: false,
            duplicateOrderCount: recovery.duplicateCount,
            orderAbsenceVerified: false,
          );
        case AssignedVisitOrderRecoveryStatus.pending:
          session = session.copyWith(
            orderPending: true,
            orderRecoveryBlocked: false,
            duplicateOrderCount: recovery.duplicateCount,
            orderAbsenceVerified: false,
          );
        case AssignedVisitOrderRecoveryStatus.conflict:
          session = session.copyWith(
            orderPending: false,
            orderRecoveryBlocked: true,
            duplicateOrderCount: recovery.duplicateCount,
            orderAbsenceVerified: false,
          );
        case AssignedVisitOrderRecoveryStatus.absent:
          if (!session.orderAbsenceVerified) {
            await GuidedVisitSessionStore.markOrderAbsenceVerified(
              salesmanUid: uid,
              routePlanId: widget.plan.id,
              routeStopId: widget.stop.stopId,
            );
          }
          session = session.copyWith(
            orderPending: false,
            orderRecoveryBlocked: false,
            orderAbsenceVerified: true,
          );
        case AssignedVisitOrderRecoveryStatus.unavailable:
          break;
      }
    }
    if (mounted) {
      setState(() => _session = session);
      if (session.completionPending) _watchCompletionAcknowledgement();
    }
  }

  @override
  void dispose() {
    unawaited(_completionSubscription?.cancel());
    _voiceBinding.dispose();
    super.dispose();
  }

  Future<VoiceActionResult> _handleVoiceOpenAssignedRoute(
    VoiceCommandEnvelope envelope,
  ) async => const VoiceActionResult.opened();

  Future<VoiceActionResult> _handleVoiceOpenCurrentVisit(
    VoiceCommandEnvelope envelope,
  ) async => const VoiceActionResult.opened();

  Future<VoiceActionResult> _handleVoiceOpenCart(
    VoiceCommandEnvelope envelope,
  ) async {
    if (_session.orderRecoveryBlocked) {
      return const VoiceActionResult(code: VoiceResultCode.unavailable);
    }
    return const VoiceActionResult.opened();
  }

  Future<VoiceActionResult> _handleVoiceOpenOrderHistory(
    VoiceCommandEnvelope envelope,
  ) async => const VoiceActionResult.opened();

  Future<VoiceActionResult> _handleVoiceShowVisitBrief(
    VoiceCommandEnvelope envelope,
  ) async {
    if (kBasicEdition) return const VoiceActionResult.handlerUnavailable();
    await _showVoiceVisitBrief();
    return const VoiceActionResult.applied();
  }

  Future<void> _showVoiceVisitBrief() async {
    final VisitBrief? brief = widget.brief;
    await showDialog<void>(
      context: context,
      builder: (BuildContext dialogContext) {
        final List<VisitBriefInsight> insights =
            brief?.topInsights.take(5).toList(growable: false) ??
            const <VisitBriefInsight>[];
        return AlertDialog(
          title: Text('Visit brief · ${widget.stop.retailerName}'),
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
        );
      },
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
        Navigator.of(context).pop();
      case VoiceActionId.openCurrentVisit:
        break;
      case VoiceActionId.openCart:
        await _openOrderFlow();
      case VoiceActionId.openOrderHistory:
        await Navigator.of(context).push(
          MaterialPageRoute<void>(builder: (_) => const OrderHistoryScreen()),
        );
      default:
        break;
    }
  }

  @override
  Widget build(BuildContext context) {
    final AuthProvider auth = context.watch<AuthProvider>();
    _voiceBinding.updateContext(
      uid: auth.user?.uid ?? '',
      role: auth.user?.role ?? '',
      retailerId: widget.stop.retailerId,
      routePlanId: widget.plan.id,
      routeStopId: widget.stop.stopId,
      draftId: _draftKey,
    );
    final GuidedVisitGate gate = guidedVisitGate(
      stage: _stage,
      stopStatus: _stopStatus,
      orderSubmitted: _session.orderSubmitted,
      orderPending: _session.orderPending,
      orderRecoveryBlocked: _session.orderRecoveryBlocked,
      completionPending: _session.completionPending,
      outcomeRecorded: _session.outcomeRecorded,
      hasDraft: _draft != null,
    );
    return Scaffold(
      backgroundColor: ScootColors.of(context).page,
      appBar: ScootPhoneAppBar(
        title: widget.stop.retailerName,
        subtitle: widget.stop.address.isEmpty ? null : widget.stop.address,
        onBack: () => Navigator.of(context).maybePop(),
        actions: <Widget>[
          CopilotEntryButton(
            screen: CopilotScreenContext(
              engine: _voiceEngine,
              onNavigationAction: _handleVoiceNavigation,
              suggestions: kBasicEdition
                  ? const <String>[]
                  : const <String>['Show the visit brief'],
            ),
          ),
          _StatusPill(label: _stopStatus),
        ],
      ),
      body: Column(
        children: <Widget>[
          _StageHeader(stage: _stage, onSelected: _selectStage),
          PhoneStatusStrip(
            pendingCount: widget.copilotService.pendingCount,
            hasPendingWrites: _session.completionPending,
          ),
          ConstrainedBox(
            constraints: BoxConstraints(
              maxHeight: MediaQuery.sizeOf(context).height * 0.3,
            ),
            child: const SingleChildScrollView(child: LocationStatusBanner()),
          ),
          Expanded(
            child: SingleChildScrollView(
              padding: const EdgeInsets.fromLTRB(16, 12, 16, 24),
              child: AnimatedSwitcher(
                duration: const Duration(milliseconds: 180),
                child: switch (_stage) {
                  GuidedVisitStage.prepare => _prepare(),
                  GuidedVisitStage.sell => _sell(),
                  GuidedVisitStage.close => _close(),
                },
              ),
            ),
          ),
        ],
      ),
      bottomNavigationBar: ScootPrimaryActionBar(
        label: gate.actionLabel,
        icon: _primaryIcon,
        aboveHomeIndicator: true,
        note: gate.blockedReason.isEmpty ? null : gate.blockedReason,
        disabledReason: gate.blockedReason.isEmpty ? null : gate.blockedReason,
        onPressed: _busy || _session.completionPending ? null : _primaryAction,
      ),
    );
  }

  IconData get _primaryIcon => switch (_stage) {
    GuidedVisitStage.prepare => ScootIcons.chevronRight,
    GuidedVisitStage.sell => ScootIcons.orders,
    GuidedVisitStage.close => ScootIcons.success,
  };

  void _selectStage(GuidedVisitStage next) {
    if (next.index <= _stage.index) setState(() => _stage = next);
  }

  Future<void> _primaryAction() async {
    final String currentUid =
        FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (currentUid.isEmpty || currentUid != widget.user.uid.trim()) {
      _message('This visit belongs to another sign-in. Return and reopen it.');
      return;
    }
    switch (_stage) {
      case GuidedVisitStage.prepare:
        if (_stopStatus != 'arrived') {
          await _markArrived();
        }
        if (mounted && _stopStatus == 'arrived') {
          setState(() => _stage = GuidedVisitStage.sell);
        }
        return;
      case GuidedVisitStage.sell:
        if (_session.closeReady) {
          setState(() => _stage = GuidedVisitStage.close);
        } else {
          await _openOrderFlow();
        }
        return;
      case GuidedVisitStage.close:
        final GuidedVisitGate gate = guidedVisitGate(
          stage: _stage,
          stopStatus: _stopStatus,
          orderSubmitted: _session.orderSubmitted,
          orderPending: _session.orderPending,
          orderRecoveryBlocked: _session.orderRecoveryBlocked,
          completionPending: _session.completionPending,
          outcomeRecorded: _session.outcomeRecorded,
          hasDraft: _draft != null,
        );
        if (!gate.canAdvance) return;
        await _completeStop();
        return;
    }
  }

  Future<void> _markArrived() async {
    final GpsProvider gps = context.read<GpsProvider>();
    if (!gps.hasArrivalReadySession) {
      ScaffoldMessenger.of(context).showSnackBar(
        SnackBar(
          content: const Text('Start work first'),
          action: SnackBarAction(
            label: 'Start work',
            onPressed: () =>
                unawaited(gps.startTracking(user: widget.user, explicit: true)),
          ),
        ),
      );
      return;
    }
    setState(() => _busy = true);
    try {
      final evidence = await collectSelectedStopArrivalEvidence(
        context,
        plan: widget.plan,
        stop: widget.stop,
        progress: _progress,
        isOnline:
            context.read<ConnectivityProvider>().isOnline &&
            !context.read<AuthProvider>().isOfflineVerified,
      );
      if (evidence == null) return;
      final RouteProgressWriteState result = await widget.service
          .updateStopStatus(
            plan: widget.plan,
            stop: widget.stop,
            user: widget.user,
            status: 'arrived',
            arrivalEvidence: evidence,
            progress: _progress,
          );
      if (result == RouteProgressWriteState.needsAttention) {
        _message('Arrival needs attention before this visit can continue.');
        return;
      }
      if (mounted) {
        setState(() {
          _stopStatus = 'arrived';
          _progress = _progressAfterStopUpdate(
            'arrived',
            arrivalMode: evidence.mode,
          );
        });
      }
      if (result == RouteProgressWriteState.pending) {
        _message('Arrival is saved on this device and pending sync.');
      }
    } catch (error) {
      _message(
        stopSaveFailureMessage(
          error,
          fallback: 'Arrival could not be saved. Try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _completeStop() async {
    setState(() => _busy = true);
    try {
      final String uid = FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
      if (uid.isEmpty || uid != widget.user.uid.trim()) {
        throw StateError('The signed-in salesperson changed during the visit.');
      }
      final RouteProgressWriteState result = await widget.service
          .updateStopStatus(
            plan: widget.plan,
            stop: widget.stop,
            user: widget.user,
            status: 'completed',
            progress: _progress,
          );
      if (result == RouteProgressWriteState.needsAttention) {
        _message('Completion needs attention before this visit can close.');
        return;
      }
      if (result == RouteProgressWriteState.pending) {
        await GuidedVisitSessionStore.markCompletionPending(
          salesmanUid: uid,
          routePlanId: widget.plan.id,
          routeStopId: widget.stop.stopId,
        );
        if (!mounted) return;
        setState(() {
          _stopStatus = 'completed';
          _progress = _progressAfterStopUpdate('completed');
          _session = _session.copyWith(completionPending: true);
        });
        _message(
          'Completion is saved on this device and pending sync. You can safely leave this screen.',
        );
        _watchCompletionAcknowledgement();
      } else {
        await GuidedVisitSessionStore.clear(
          salesmanUid: uid,
          routePlanId: widget.plan.id,
          routeStopId: widget.stop.stopId,
        );
        if (!mounted) return;
        Navigator.of(context).pop(true);
      }
    } catch (error) {
      _message(
        stopSaveFailureMessage(
          error,
          fallback: 'Visit could not be completed. Try again.',
        ),
      );
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _watchCompletionAcknowledgement() {
    unawaited(_completionSubscription?.cancel());
    _completionSubscription = widget.service
        .watchProgress(planId: widget.plan.id, salesmanUid: widget.user.uid)
        .listen((RouteProgress progress) async {
          if (!mounted) return;
          setState(() => _progress = progress);
          if (!_session.completionPending) return;
          final String status = progress.statusFor(
            widget.stop.stopId,
            widget.stop.status,
          );
          if (progress.hasPendingWrites || progress.isFromCache) return;
          final String uid =
              FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
          if (uid.isEmpty || uid != widget.user.uid.trim()) return;
          await GuidedVisitSessionStore.clearCompletionPending(
            salesmanUid: uid,
            routePlanId: widget.plan.id,
            routeStopId: widget.stop.stopId,
          );
          if (!mounted) return;
          if (status == 'completed') {
            await GuidedVisitSessionStore.clear(
              salesmanUid: uid,
              routePlanId: widget.plan.id,
              routeStopId: widget.stop.stopId,
            );
            if (mounted) Navigator.of(context).pop(true);
            return;
          }
          setState(() {
            _stopStatus = status;
            _session = _session.copyWith(completionPending: false);
          });
          _message('Completion was not accepted. Review the visit and retry.');
        }, onError: (_) {});
  }

  RouteProgress _progressAfterStopUpdate(String status, {String? arrivalMode}) {
    final String stopId = widget.stop.stopId;
    final Map<String, dynamic> rawData =
        Map<String, dynamic>.from(_progress.rawData)
          ..['lastStopId'] = stopId
          ..['lastStopStatus'] = status;
    if (status == 'completed' || status == 'skipped') {
      final Object? currentHandled = rawData['handledStopIds'];
      final List<dynamic> handled = currentHandled is List
          ? List<dynamic>.from(currentHandled)
          : <dynamic>[];
      if (!handled.contains(stopId)) handled.add(stopId);
      rawData['handledStopIds'] = handled;
    }
    final Map<String, Map<String, dynamic>> canonical =
        Map<String, Map<String, dynamic>>.from(
          _progress.canonicalStopDocuments,
        );
    canonical[stopId] = <String, dynamic>{
      ...?_progress.canonicalStopFor(stopId),
      'lifecycleSchemaVersion': 2,
      'status': status,
      ...?(arrivalMode == null
          ? null
          : <String, dynamic>{'arrivalMode': arrivalMode}),
    };
    return RouteProgress.fromMap(
      rawData,
      hasPendingWrites: true,
      isFromCache: _progress.isFromCache,
      hasDocument: _progress.hasDocument,
      canonicalStopDocuments: canonical,
    );
  }

  Future<bool> _openOrderFlow() async {
    if (_session.orderRecoveryBlocked) {
      _message(
        'This stop already has conflicting order data. Ask a manager to review it.',
      );
      return false;
    }
    final CartDraftSnapshot? draft = _draft;
    final List<Map<String, dynamic>> items = draft?.items ?? const [];
    final int stage = draft?.progress ?? 0;
    Widget page;
    if ((stage == 3 || stage == 4) &&
        items.isNotEmpty &&
        items.every(
          (item) => (item['productId'] ?? '').toString().isNotEmpty,
        )) {
      page = OrderSignatureScreen(
        cartItems: items,
        guidedVisitContext: _context,
      );
    } else if (stage >= 2 && items.isNotEmpty) {
      page = OrderCartScreen(
        selectedItems: items,
        retailerId: widget.stop.retailerId,
        retailerName: widget.stop.retailerName,
        guidedVisitContext: _context,
      );
    } else {
      page = AddToCartPage(
        retailerId: widget.stop.retailerId,
        retailerName: widget.stop.retailerName,
        initialSelectedItems: items,
        guidedVisitContext: _context,
      );
    }
    await Navigator.of(
      context,
    ).push(MaterialPageRoute<void>(builder: (_) => page));
    await _reloadSession();
    if (mounted && _session.orderSubmitted) {
      setState(() => _stage = GuidedVisitStage.close);
    }
    return true;
  }

  Widget _prepare() {
    final VisitBrief? brief = widget.brief;
    return Column(
      key: const ValueKey<String>('prepare'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _VisitHero(stop: widget.stop),
        if (!kBasicEdition) ...<Widget>[
          const SizedBox(height: 12),
          _SectionCard(
            title: 'Retailer memory',
            child: FutureBuilder<RetailerMemory?>(
              future: widget.copilotService.loadRetailerMemory(
                user: widget.user,
                retailerId: widget.stop.retailerId,
              ),
              builder: (BuildContext context, AsyncSnapshot<RetailerMemory?> snap) {
                if (snap.connectionState == ConnectionState.waiting) {
                  return const LinearProgressIndicator(minHeight: 2);
                }
                final RetailerMemory? memory = snap.data;
                if (memory == null || memory.isEmpty) {
                  return const Text('No confirmed retailer outcomes yet.');
                }
                return Text(
                  '${memory.outcomeCount} outcome(s) · '
                  '${(memory.confidence * 100).round()}% confidence · '
                  '${memory.topReasons.take(3).map((ReasonStat r) => r.reasonCode.replaceAll('_', ' ')).join(', ')}',
                );
              },
            ),
          ),
          const SizedBox(height: 12),
          _SectionCard(title: "Today's focus", child: _focusBody(brief)),
        ],
        if (brief != null && brief.replenishment.isNotEmpty) ...<Widget>[
          const SizedBox(height: 12),
          ReplenishmentSuggestionsCard(
            retailerId: widget.stop.retailerId,
            suggestions: brief.replenishment.take(3).toList(growable: false),
            productNames: <String, String>{
              for (final VisitBriefInsight insight in brief.topInsights)
                if (insight.productId.isNotEmpty)
                  insight.productId: insight.productName,
            },
          ),
        ],
      ],
    );
  }

  Widget _sell() {
    final CartDraftSnapshot? draft = _draft;
    return Column(
      key: const ValueKey<String>('sell'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionCard(
          title: 'Order workspace',
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Text(
                _session.orderSubmitted
                    ? 'Order submitted.'
                    : _session.orderPending
                    ? 'Order saved on this phone. It is sent when you are online, and it is not sent twice.'
                    : _session.orderRecoveryBlocked
                    ? 'Existing order data for this stop needs manager review. A second order is blocked.'
                    : draft == null
                    ? 'No order draft yet.'
                    : '${draft.items.length} product line(s) saved.',
              ),
              const SizedBox(height: 10),
              const Text(
                'Scan or search products, count shelf stock, review quantities, and collect signatures. Your progress is saved if you leave.',
                style: TextStyle(color: AppColors.textGrey, height: 1.4),
              ),
            ],
          ),
        ),
        if (!_session.orderSubmitted &&
            !_session.orderPending &&
            !_session.orderRecoveryBlocked &&
            !_session.outcomeRecorded) ...<Widget>[
          const SizedBox(height: 12),
          if (widget.brief?.topInsights.isNotEmpty == true)
            OutlinedButton.icon(
              onPressed: _recordNoOrderOutcome,
              icon: const Icon(Icons.chat_outlined),
              label: const Text('Record no-order outcome'),
            )
          else
            OutlinedButton.icon(
              key: const ValueKey<String>('no-order-today'),
              onPressed: _busy ? null : _recordNoOrderToday,
              icon: const Icon(Icons.do_not_disturb_on_outlined),
              label: const Text('No order today'),
            ),
        ],
      ],
    );
  }

  Widget _close() {
    return Column(
      key: const ValueKey<String>('close'),
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        _SectionCard(
          title: 'Visit close checklist',
          child: Column(
            children: <Widget>[
              _CheckRow(
                label: 'Arrival recorded',
                done: _stopStatus == 'arrived',
              ),
              _CheckRow(
                label: _session.orderPending
                    ? 'Order queued for sync'
                    : 'Order submitted',
                done: _session.orderSubmitted || _session.orderPending,
              ),
              _CheckRow(
                label: 'Outcome recorded',
                done: _session.outcomeRecorded,
              ),
            ],
          ),
        ),
        const SizedBox(height: 12),
        if (_session.duplicateOrderCount > 1) ...<Widget>[
          Text(
            '${_session.duplicateOrderCount} existing orders were found for this stop. No additional order will be created; manager review is required.',
            style: const TextStyle(color: Color(0xFFB91C1C), height: 1.4),
          ),
          const SizedBox(height: 12),
        ],
        const Text(
          'Completing the stop updates only your route progress. It does not edit the published route.',
          style: TextStyle(color: AppColors.textGrey, height: 1.4),
        ),
      ],
    );
  }

  Widget _focusBody(VisitBrief? brief) {
    if (brief == null) return const Text('No visit brief for this stop.');
    final List<VisitFocusItem> items = brief.fieldFocusItems;
    if (items.isEmpty) {
      if (brief.hasNoPriorityIssues) {
        return Column(
          crossAxisAlignment: CrossAxisAlignment.start,
          children: <Widget>[
            Text(
              brief.noPriorityHeadline,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(brief.noPriorityBody),
          ],
        );
      }
      return const Text('No current visit brief issues.');
    }
    return Column(
      children: <Widget>[
        for (final VisitFocusItem item in items)
          ListTile(
            contentPadding: EdgeInsets.zero,
            dense: true,
            title: Text(item.title),
            subtitle: Text(
              <String>[
                if (item.signal.isNotEmpty) item.signal,
                if (item.action.isNotEmpty) 'Action: ${item.action}',
                if (item.previousOutcome case final previous?
                    when !previous.isEmpty)
                  'Last answer: ${previous.label}',
              ].join('\n'),
            ),
            isThreeLine: item.action.isNotEmpty,
            trailing: _StatusPill(label: item.priority),
          ),
      ],
    );
  }

  Future<void> _recordNoOrderOutcome() async {
    final VisitBrief? brief = widget.brief;
    if (brief == null || brief.topInsights.isEmpty) return;
    final String? reason = await showModalBottomSheet<String>(
      context: context,
      showDragHandle: true,
      builder: (BuildContext context) => SafeArea(
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            const ListTile(
              title: Text(
                'Why was no order placed?',
                style: TextStyle(fontWeight: FontWeight.bold),
              ),
            ),
            for (final String value in const <String>[
              'low_sell_through',
              'price_too_high',
              'retailer_busy',
              'decision_maker_unavailable',
            ])
              ListTile(
                title: Text(value.replaceAll('_', ' ')),
                onTap: () => Navigator.pop(context, value),
              ),
          ],
        ),
      ),
    );
    if (reason == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.copilotService.queueOutcome(
        user: widget.user,
        branchId: widget.plan.branchId,
        planId: widget.plan.id,
        stopId: widget.stop.stopId,
        brief: brief,
        insight: brief.topInsights.first,
        reasonCode: reason,
        note: '',
        replacementProductId: '',
        isOnline: context.read<ConnectivityProvider>().isOnline,
      );
      await GuidedVisitSessionStore.markOutcomeRecorded(
        salesmanUid: widget.user.uid,
        routePlanId: widget.plan.id,
        routeStopId: widget.stop.stopId,
      );
      await _reloadSession();
      if (mounted) setState(() => _stage = GuidedVisitStage.close);
    } catch (_) {
      _message('Outcome could not be saved. Check the required fields.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _recordNoOrderToday() async {
    final NoOrderDraft? draft = await showNoOrderReasonSheet(context);
    if (draft == null || !mounted) return;
    setState(() => _busy = true);
    try {
      await widget.copilotService.queueNoOrderOutcome(
        user: widget.user,
        branchId: widget.plan.branchId,
        planId: widget.plan.id,
        stopId: widget.stop.stopId,
        retailerId: widget.stop.retailerId,
        retailerName: widget.stop.retailerName,
        reasonCode: draft.reasonCode,
        note: draft.note,
        isDemo: widget.plan.isDemo,
        isOnline: context.read<ConnectivityProvider>().isOnline,
      );
      await GuidedVisitSessionStore.markOutcomeRecorded(
        salesmanUid: widget.user.uid,
        routePlanId: widget.plan.id,
        routeStopId: widget.stop.stopId,
      );
      await _reloadSession();
      if (mounted) setState(() => _stage = GuidedVisitStage.close);
    } catch (_) {
      _message('No order today could not be saved. Check the reason.');
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  void _message(String text) {
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(SnackBar(content: Text(text)));
  }
}

class _StageHeader extends StatelessWidget {
  const _StageHeader({required this.stage, required this.onSelected});
  final GuidedVisitStage stage;
  final ValueChanged<GuidedVisitStage> onSelected;

  @override
  Widget build(BuildContext context) {
    return Stack(
      children: <Widget>[
        ScootStepBar(
          current: stage.index,
          steps: const <String>['Prepare', 'Sell', 'Close'],
        ),
        Positioned.fill(
          child: Row(
            children: <Widget>[
              for (final GuidedVisitStage item in GuidedVisitStage.values)
                Expanded(
                  child: Semantics(
                    button: true,
                    enabled: item.index <= stage.index,
                    label: item.name[0].toUpperCase() + item.name.substring(1),
                    child: InkWell(
                      onTap: item.index <= stage.index
                          ? () => onSelected(item)
                          : null,
                    ),
                  ),
                ),
            ],
          ),
        ),
      ],
    );
  }
}

class _VisitHero extends StatelessWidget {
  const _VisitHero({required this.stop});
  final AssignedRouteStop stop;
  @override
  Widget build(BuildContext context) => _SectionCard(
    title: stop.retailerName,
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (stop.address.isNotEmpty) Text(stop.address),
        if (stop.estimatedArrival.isNotEmpty)
          Text('Planned arrival ${stop.estimatedArrival}'),
        if (stop.priorityReason.isNotEmpty)
          Text(
            'Why this visit: ${stop.priorityReason}',
            style: const TextStyle(color: AppColors.textGrey),
          ),
      ],
    ),
  );
}

class _SectionCard extends StatelessWidget {
  const _SectionCard({required this.title, required this.child});
  final String title;
  final Widget child;
  @override
  Widget build(BuildContext context) => Container(
    width: double.infinity,
    padding: const EdgeInsets.all(16),
    decoration: BoxDecoration(
      color: Colors.white,
      borderRadius: BorderRadius.circular(14),
      border: Border.all(color: AppColors.inputBorder),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        LongNameText(
          title,
          style: const TextStyle(fontSize: 16, fontWeight: FontWeight.bold),
        ),
        const SizedBox(height: 10),
        child,
      ],
    ),
  );
}

class _StatusPill extends StatelessWidget {
  const _StatusPill({required this.label});
  final String label;
  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 9, vertical: 5),
    decoration: BoxDecoration(
      color: ScootColors.of(context).brandTint,
      borderRadius: ScootRadius.pillAll,
    ),
    child: Text(
      label.replaceAll('_', ' '),
      style: TextStyle(
        fontSize: 11,
        color: ScootColors.of(context).brandText,
        fontWeight: FontWeight.w600,
      ),
    ),
  );
}

class _CheckRow extends StatelessWidget {
  const _CheckRow({required this.label, required this.done});
  final String label;
  final bool done;
  @override
  Widget build(BuildContext context) => ListTile(
    contentPadding: EdgeInsets.zero,
    dense: true,
    leading: Icon(
      done ? Icons.check_circle : Icons.radio_button_unchecked,
      color: done ? AppColors.primary : AppColors.textSecondary,
    ),
    title: Text(label),
  );
}
