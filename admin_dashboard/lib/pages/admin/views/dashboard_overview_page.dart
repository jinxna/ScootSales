import 'dart:async';

import 'package:cloud_firestore/cloud_firestore.dart';
import 'package:firebase_auth/firebase_auth.dart';
import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';
import '../../../app/build_flags.dart';
import '../../../models/action_centre_item.dart';
import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../services/action_centre_service.dart';
import '../../../services/notification_read_state_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/notification_read_state.dart';
import '../../../security/team_scope.dart';
import '../../../utils/order_id_resolver.dart';
import '../../../widgets/ai_freshness_chip.dart';
import '../../../utils/ai_data_freshness.dart';
import '../widgets/cms_panel.dart';
import '../widgets/order_details_dialog.dart';
import '../../../utils/derived_team_alerts.dart';
import 'overview/notification_feed_model.dart';
import 'overview/notifications_feed_view.dart';
import 'overview/role_home.dart';

class DashboardOverviewPage extends StatefulWidget {
  const DashboardOverviewPage({
    super.key,
    required this.currentUser,
    this.forceNotificationsMode = false,
    this.onNavigateRequested,
  });

  final UserProfile currentUser;
  final bool forceNotificationsMode;
  final ValueChanged<String>? onNavigateRequested;

  @override
  State<DashboardOverviewPage> createState() => _DashboardOverviewPageState();
}

class _DashboardOverviewPageState extends State<DashboardOverviewPage> {
  final CmsRepository repository = CmsRepository();

  Future<List<ActionCentreItem>>? _actionItemsFuture;

  UserProfile get currentUser => widget.currentUser;
  bool get forceNotificationsMode => widget.forceNotificationsMode;
  ValueChanged<String>? get onNavigateRequested => widget.onNavigateRequested;

  @override
  void didUpdateWidget(DashboardOverviewPage old) {
    super.didUpdateWidget(old);
    if (old.currentUser.uid != widget.currentUser.uid ||
        old.currentUser.role != widget.currentUser.role) {
      _actionItemsFuture = null;
    }
  }

  @override
  Widget build(BuildContext context) {
    if (forceNotificationsMode) {
      return _NotificationsFeedPanel(
        currentUser: currentUser,
        repository: repository,
      );
    }
    final Future<List<ActionCentreItem>> actionItemsFuture =
        _actionItemsFuture ??= ActionCentreService(
          repository: repository,
        ).loadItems(currentUser: currentUser);
    return SingleChildScrollView(
      child: Padding(
        padding: const EdgeInsets.only(bottom: 12),
        child: RoleHomeSection(
          repository: repository,
          currentUser: currentUser,
          actionItemsFuture: actionItemsFuture,
          onRetryActions: () => setState(() => _actionItemsFuture = null),
          onNavigateRequested: onNavigateRequested,
        ),
      ),
    );
  }

  static String _safeText(Object? value, {required String fallback}) {
    final String text = '$value'.trim();
    if (text.isEmpty || text == 'null') {
      return fallback;
    }
    return text;
  }

  static DateTime? _toDateTime(Object? value) {
    if (value == null) return null;
    if (value is Timestamp) return value.toDate();
    if (value is DateTime) return value;
    if (value is int) {
      final bool looksLikeMilliseconds = value > 9999999999;
      return DateTime.fromMillisecondsSinceEpoch(
        looksLikeMilliseconds ? value : value * 1000,
        isUtc: true,
      );
    }
    final String text = value.toString().trim();
    if (text.isEmpty || text.toLowerCase() == 'null') return null;
    final RegExp timestampPattern = RegExp(
      r'Timestamp\(seconds=(\d+),\s*nanoseconds=(\d+)\)',
    );
    final RegExpMatch? match = timestampPattern.firstMatch(text);
    if (match != null) {
      final int seconds = int.tryParse(match.group(1) ?? '') ?? 0;
      final int nanoseconds = int.tryParse(match.group(2) ?? '') ?? 0;
      return DateTime.fromMillisecondsSinceEpoch(
        (seconds * 1000) + (nanoseconds ~/ 1000000),
        isUtc: true,
      );
    }
    return DateTime.tryParse(text);
  }

  static String _dateKeyKualaLumpur(Object? value) {
    final DateTime? dateTime = _toDateTime(value);
    if (dateTime == null) return '';
    final DateTime klTime = dateTime.toUtc().add(const Duration(hours: 8));
    return '${klTime.year}-${klTime.month.toString().padLeft(2, '0')}-${klTime.day.toString().padLeft(2, '0')}';
  }
}

class ForecastHighlightsPanel extends StatelessWidget {
  const ForecastHighlightsPanel({
    super.key,
    required this.forecasts,
    required this.onNavigateRequested,
  });

  final Stream<List<Map<String, dynamic>>> forecasts;
  final ValueChanged<String>? onNavigateRequested;

  @override
  Widget build(BuildContext context) {
    return CmsPanel(
      title: 'Forecast Highlights',
      trailing: const _HeaderTag(label: 'Saved forecast'),
      child: StreamBuilder<List<Map<String, dynamic>>>(
        stream: forecasts,
        builder:
            (
              BuildContext context,
              AsyncSnapshot<List<Map<String, dynamic>>> snapshot,
            ) {
              if (snapshot.connectionState == ConnectionState.waiting &&
                  !snapshot.hasData) {
                return const Center(child: CircularProgressIndicator());
              }
              final List<Map<String, dynamic>>
              rows = (snapshot.data ?? <Map<String, dynamic>>[])
                  .where((Map<String, dynamic> row) {
                    final String action = _DashboardOverviewPageState._safeText(
                      row['recommendedAction'] ?? row['recommended_action'],
                      fallback: '',
                    );
                    final String reason = _DashboardOverviewPageState._safeText(
                      row['reason'],
                      fallback: '',
                    );
                    return action.isNotEmpty || reason.isNotEmpty;
                  })
                  .take(4)
                  .toList(growable: false);
              if (rows.isEmpty) {
                return Column(
                  children: <Widget>[
                    const Padding(
                      padding: EdgeInsets.all(12),
                      child: AiFreshnessChip(
                        hasData: false,
                        timestamps: <DateTime?>[],
                      ),
                    ),
                    Expanded(
                      child: SingleChildScrollView(
                        child: _EmptyPanelState(
                          icon: ScootIcons.forecast,
                          title: 'No forecast highlights yet',
                          subtitle:
                              'No forecast has been published for this company yet.',
                        ),
                      ),
                    ),
                  ],
                );
              }
              return ListView.separated(
                padding: const EdgeInsets.all(16),
                itemCount: rows.length + 1,
                separatorBuilder: (_, _) => const Divider(height: 18),
                itemBuilder: (BuildContext context, int index) {
                  if (index == 0) {
                    final List<DateTime?> timestamps = rows
                        .map(aiDataTimestamp)
                        .toList(growable: false);
                    return Align(
                      alignment: Alignment.centerLeft,
                      child: AiFreshnessChip(
                        hasData: true,
                        timestamps: timestamps,
                        hasMissingTimestamp: timestamps.contains(null),
                      ),
                    );
                  }
                  final Map<String, dynamic> row = rows[index - 1];
                  final String product = _DashboardOverviewPageState._safeText(
                    row['productName'] ??
                        row['product_name'] ??
                        row['productId'] ??
                        row['product_id'],
                    fallback: 'Product',
                  );
                  final String quantity = _DashboardOverviewPageState._safeText(
                    row['predictedQuantity'] ??
                        row['predicted_quantity'] ??
                        row['forecastQuantity'] ??
                        row['forecast_quantity'],
                    fallback: '-',
                  );
                  final String action = _DashboardOverviewPageState._safeText(
                    row['recommendedAction'] ?? row['recommended_action'],
                    fallback: 'Review forecast',
                  );
                  return Row(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      CircleAvatar(
                        radius: 17,
                        backgroundColor: context.dso.brandSurface,
                        child: Icon(
                          ScootIcons.forecast,
                          size: 17,
                          color: context.dso.accentText,
                        ),
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Text(
                              product,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: const TextStyle(
                                fontSize: 13,
                                fontWeight: FontWeight.w800,
                              ),
                            ),
                            const SizedBox(height: 3),
                            Text(
                              '$quantity forecast units | $action',
                              maxLines: 2,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 12,
                                color: context.dso.muted,
                                height: 1.4,
                              ),
                            ),
                          ],
                        ),
                      ),
                      if (onNavigateRequested != null)
                        IconButton(
                          tooltip: 'Open Prediction',
                          onPressed: () => onNavigateRequested!('prediction'),
                          icon: const Icon(Icons.open_in_new, size: 18),
                        ),
                    ],
                  );
                },
              );
            },
      ),
    );
  }
}

class _NotificationsFeedPanel extends StatefulWidget {
  const _NotificationsFeedPanel({
    required this.currentUser,
    required this.repository,
  });

  final UserProfile currentUser;
  final CmsRepository repository;

  @override
  State<_NotificationsFeedPanel> createState() =>
      _NotificationsFeedPanelState();
}

class _NotificationsFeedPanelState extends State<_NotificationsFeedPanel> {
  DateTime? _selectedDate;
  NotificationCategory? _category;
  NotificationReadStateService? _readStateService;
  StreamSubscription<NotificationReadState?>? _readStateSubscription;
  NotificationReadState _readState = const NotificationReadState();
  DateTime? _optimisticReadThroughAt;
  Object? _readStateError;
  bool _readStateLoading = true;
  bool _readAllPending = false;
  int _readStateGeneration = 0;

  final ValueNotifier<Set<String>> _failedAlertSources =
      ValueNotifier<Set<String>>(const <String>{});

  void _markAlertSource(String source, {required bool failed}) {
    if (!mounted) return;
    final Set<String> current = _failedAlertSources.value;
    if (current.contains(source) == failed) return;
    _failedAlertSources.value = failed
        ? <String>{...current, source}
        : (<String>{...current}..remove(source));
  }

  String get _selectedDateKey {
    if (_selectedDate == null) return 'all';
    return '${_selectedDate!.year}-${_selectedDate!.month.toString().padLeft(2, '0')}-${_selectedDate!.day.toString().padLeft(2, '0')}';
  }

  Future<void> _pickDate(Set<String> availableDateKeys) async {
    final DateTime now = DateTime.now();
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: _selectedDate ?? now,
      firstDate: DateTime(now.year - 1),
      lastDate: now,
      helpText: 'Select date to view activity',
      builder: (BuildContext context, Widget? child) {
        return Theme(
          data: Theme.of(context).copyWith(
            colorScheme: Theme.of(context).colorScheme.copyWith(
              primary: context.dso.accent,
              onPrimary: Colors.white,
            ),
          ),
          child: child!,
        );
      },
    );
    if (picked != null) {
      setState(() => _selectedDate = picked);
    }
  }

  final Stopwatch _notificationTimer = Stopwatch()..start();
  int _visibleLimit = 20;
  int _retryNonce = 0;
  bool _loggedFirstQuery = false;
  bool _loggedInitialList = false;
  late Stream<List<Map<String, dynamic>>> _systemStream;
  late Stream<List<Map<String, dynamic>>> _activityStream;

  void _openFeedStreams() {
    _systemStream = _watchSystemNotifications();
    _activityStream = _watchActivityFeed();
  }

  @override
  void initState() {
    super.initState();
    _openFeedStreams();
    _startReadStateWatch();
    WidgetsBinding.instance.addPostFrameCallback((Duration _) {
      _debugTiming('notification shell rendered');
    });
  }

  @override
  void didUpdateWidget(covariant _NotificationsFeedPanel oldWidget) {
    super.didUpdateWidget(oldWidget);
    if (oldWidget.currentUser.uid != widget.currentUser.uid) {
      _startReadStateWatch();
    }
    final UserProfile oldUser = oldWidget.currentUser;
    final UserProfile newUser = widget.currentUser;
    if (oldUser.uid != newUser.uid ||
        oldUser.role != newUser.role ||
        oldUser.branchId != newUser.branchId ||
        oldUser.assignedSalesmanCodes.join(',') !=
            newUser.assignedSalesmanCodes.join(',') ||
        !identical(oldWidget.repository, widget.repository)) {
      _openFeedStreams();
    }
  }

  @override
  void dispose() {
    _readStateSubscription?.cancel();
    _failedAlertSources.dispose();
    super.dispose();
  }

  String get _authUid {
    final String firebaseUid =
        FirebaseAuth.instance.currentUser?.uid.trim() ?? '';
    if (firebaseUid.isNotEmpty) return firebaseUid;
    return widget.currentUser.uid?.trim() ?? '';
  }

  void _startReadStateWatch() {
    _readStateSubscription?.cancel();
    final int generation = ++_readStateGeneration;
    final NotificationReadStateService service = NotificationReadStateService(
      authUid: _authUid,
    );
    _readStateService = service;
    if (mounted) {
      setState(() {
        _readState = const NotificationReadState();
        _optimisticReadThroughAt = null;
        _readAllPending = false;
        _readStateLoading = true;
        _readStateError = null;
      });
    }
    _readStateSubscription = service.watch().listen(
      (NotificationReadState? state) {
        if (!mounted || generation != _readStateGeneration) return;
        final DateTime? remoteCutoff = state?.readThroughAt;
        final DateTime? optimisticCutoff = _optimisticReadThroughAt;
        final DateTime? effectiveCutoff = _laterCutoff(
          _readState.readThroughAt,
          _laterCutoff(remoteCutoff, optimisticCutoff),
        );
        if (optimisticCutoff != null &&
            remoteCutoff != null &&
            !remoteCutoff.isBefore(optimisticCutoff)) {
          _optimisticReadThroughAt = null;
        }
        setState(() {
          _readState = NotificationReadState(readThroughAt: effectiveCutoff);
          _readStateLoading = false;
          _readStateError = null;
        });
      },
      onError: (Object error, StackTrace stackTrace) {
        if (!mounted || generation != _readStateGeneration) return;
        setState(() {
          _readStateLoading = false;
          _readStateError = error;
        });
      },
    );
  }

  static DateTime? _laterCutoff(DateTime? first, DateTime? second) {
    if (first == null) return second;
    if (second == null) return first;
    return first.isAfter(second) ? first : second;
  }

  @override
  Widget build(BuildContext context) {
    return StreamBuilder<List<Map<String, dynamic>>>(
      key: ValueKey<String>('system_$_visibleLimit-$_retryNonce'),
      stream: _systemStream,
      builder:
          (
            BuildContext context,
            AsyncSnapshot<List<Map<String, dynamic>>> systemSnap,
          ) {
            final List<Map<String, dynamic>> systemNotifications =
                _scopeSystemNotifications(
                  systemSnap.data ?? <Map<String, dynamic>>[],
                );
            return StreamBuilder<List<Map<String, dynamic>>>(
              key: ValueKey<String>('activity_$_visibleLimit-$_retryNonce'),
              stream: _activityStream,
              builder:
                  (
                    BuildContext context,
                    AsyncSnapshot<List<Map<String, dynamic>>> activitySnap,
                  ) {
                    if (systemSnap.hasError || activitySnap.hasError) {
                      return _feedView(phase: ScootLoadPhase.error);
                    }
                    if (!systemSnap.hasData && !activitySnap.hasData) {
                      return _feedView(phase: ScootLoadPhase.loading);
                    }
                    if (!_loggedFirstQuery) {
                      _loggedFirstQuery = true;
                      _debugTiming('first notification query returned');
                    }
                    final List<Map<String, dynamic>> notifications =
                        _mergeNotificationFeeds(
                          systemNotifications,
                          _scopeNotifications(
                            activitySnap.data ?? <Map<String, dynamic>>[],
                          ),
                        );
                    final int unreadCount = _readStateLoading
                        ? 0
                        : unreadNotificationCount(notifications, _readState);
                    final List<Map<String, dynamic>> filtered =
                        _selectedDateKey == 'all'
                        ? notifications
                        : notifications
                              .where(
                                (Map<String, dynamic> item) =>
                                    _DashboardOverviewPageState._dateKeyKualaLumpur(
                                      item['createdAt'] ??
                                          item['created_at'] ??
                                          item['updatedAt'] ??
                                          item['updated_at'] ??
                                          item['created'] ??
                                          item['timestamp'],
                                    ) ==
                                    _selectedDateKey,
                              )
                              .toList(growable: false);
                    if (!_loggedInitialList) {
                      _loggedInitialList = true;
                      _debugTiming('total initial notification list time');
                    }
                    final List<NotificationEntry> entries = filtered
                        .take(_visibleLimit)
                        .map(_entryFor)
                        .toList(growable: false);
                    final Map<NotificationCategory, int> categoryCounts =
                        <NotificationCategory, int>{
                          for (final NotificationCategory c
                              in NotificationCategory.values)
                            c: entries
                                .where((NotificationEntry e) => e.category == c)
                                .length,
                        };
                    final List<NotificationEntry> shown =
                        collapseRepeatedNotifications(
                          _category == null
                              ? entries
                              : entries
                                    .where(
                                      (NotificationEntry e) =>
                                          e.category == _category,
                                    )
                                    .toList(growable: false),
                        );
                    return _feedView(
                      phase: ScootLoadPhase.ready,
                      groups: groupNotificationsByDay(shown),
                      totalEntries: entries.length,
                      categoryCounts: categoryCounts,
                      unreadCount: unreadCount,
                      loadedCount: notifications.length,
                      hasMore: notifications.length >= _visibleLimit,
                    );
                  },
            );
          },
    );
  }

  void _retryFeed() {
    setState(() {
      _retryNonce += 1;
      _loggedFirstQuery = false;
      _loggedInitialList = false;
      _openFeedStreams();
    });
    _startReadStateWatch();
  }

  Widget _feedView({
    required ScootLoadPhase phase,
    List<NotificationDayGroup> groups = const <NotificationDayGroup>[],
    int totalEntries = 0,
    Map<NotificationCategory, int> categoryCounts =
        const <NotificationCategory, int>{},
    int unreadCount = 0,
    int loadedCount = 0,
    bool hasMore = false,
  }) {
    final String unreadLabel = _readStateLoading
        ? 'Checking unread'
        : _readStateError != null
        ? 'Unread count unavailable'
        : unreadCount == 0
        ? 'All read'
        : '$unreadCount unread in the newest $loadedCount';
    return ValueListenableBuilder<Set<String>>(
      valueListenable: _failedAlertSources,
      builder: (BuildContext context, Set<String> failed, Widget? _) =>
          NotificationsFeedView(
            phase: phase,
            onRetry: _retryFeed,
            groups: groups,
            totalEntries: totalEntries,
            categoryCounts: categoryCounts,
            category: _category,
            onCategory: (NotificationCategory? value) =>
                setState(() => _category = value),
            unreadLabel: unreadLabel,
            canMarkAllRead:
                unreadCount != 0 &&
                !_readAllPending &&
                !_readStateLoading &&
                _readStateError == null,
            markingAllRead: _readAllPending,
            onMarkAllRead: _markAllRead,
            dateLabel: _selectedDate == null
                ? 'All dates'
                : '${_selectedDate!.day.toString().padLeft(2, '0')}/${_selectedDate!.month.toString().padLeft(2, '0')}/${_selectedDate!.year}',
            dateActive: _selectedDate != null,
            onPickDate: () => _pickDate(const <String>{}),
            onClearDate: () => setState(() => _selectedDate = null),
            failedSources: failed,
            readStateFailed: _readStateError != null,
            onRetryReadState: _startReadStateWatch,
            hasMore: hasMore,
            onLoadMore: () => setState(() {
              _visibleLimit += 20;
              _loggedFirstQuery = false;
              _openFeedStreams();
            }),
            onOpen: (NotificationEntry entry) => OrderDetailsDialog.show(
              context,
              orderDocumentId: entry.orderDocumentId,
              repository: widget.repository,
              initialOrder: entry.source,
              currentUser: widget.currentUser,
              showActions: true,
            ),
          ),
    );
  }

  bool _isRead(Map<String, dynamic> notification) {
    if (_readStateLoading) return true;
    return _readState.isRead(notification);
  }

  Future<void> _markAllRead() async {
    final NotificationReadStateService? service = _readStateService;
    if (service == null || _readAllPending) return;

    final DateTime? previousCutoff = _readState.readThroughAt;
    final DateTime optimisticCutoff = DateTime.now().toUtc();
    final DateTime? effectiveCutoff = _laterCutoff(
      _readState.readThroughAt,
      optimisticCutoff,
    );
    setState(() {
      _readAllPending = true;
      _optimisticReadThroughAt = effectiveCutoff;
      _readState = NotificationReadState(readThroughAt: effectiveCutoff);
      _readStateError = null;
    });

    try {
      await service.markAllRead(localCutoff: optimisticCutoff);
      if (!mounted) return;
      setState(() => _readAllPending = false);
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(content: Text('Notifications marked as read.')),
      );
    } catch (error) {
      if (!mounted) return;
      setState(() {
        _readAllPending = false;
        _optimisticReadThroughAt = null;
        _readState = NotificationReadState(readThroughAt: previousCutoff);
        _readStateError = error;
      });
      ScaffoldMessenger.of(context).showSnackBar(
        const SnackBar(
          content: Text('Could not save read status. Try again when online.'),
        ),
      );
    }
  }

  Stream<List<Map<String, dynamic>>> _watchActivityFeed() {
    final Stream<List<Map<String, dynamic>>> logs = _watchLatestRaw(
      'notification_logs',
    );

    final StreamController<List<Map<String, dynamic>>> controller =
        StreamController<List<Map<String, dynamic>>>();
    List<Map<String, dynamic>> logRows = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> orderRows = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> visitRows = const <Map<String, dynamic>>[];
    List<Map<String, dynamic>> requestRows = const <Map<String, dynamic>>[];
    final List<StreamSubscription<List<Map<String, dynamic>>>> subscriptions =
        <StreamSubscription<List<Map<String, dynamic>>>>[];

    void emit() {
      if (controller.isClosed) return;
      controller.add(<Map<String, dynamic>>[
        ...logRows,
        ...deriveTeamAlerts(
          orders: orderRows,
          visits: visitRows,
          specialRequests: requestRows,
          audience: widget.currentUser.isSupervisor
              ? StaleRequestAudience.supervisor
              : widget.currentUser.isBranchManager
              ? StaleRequestAudience.branchManager
              : StaleRequestAudience.admin,
        ),
      ]);
    }

    Timer? staleTicker;
    void listenLive(
      String source,
      Stream<List<Map<String, dynamic>>> stream,
      void Function(List<Map<String, dynamic>> rows) keep,
    ) {
      subscriptions.add(
        stream.listen((List<Map<String, dynamic>> rows) {
          keep(rows);
          _markAlertSource(source, failed: false);
          emit();
        }, onError: (Object _) => _markAlertSource(source, failed: true)),
      );
    }

    controller.onListen = () {
      staleTicker = Timer.periodic(const Duration(minutes: 5), (_) => emit());
      subscriptions.add(
        logs.listen((List<Map<String, dynamic>> rows) {
          logRows = rows;
          emit();
        }, onError: controller.addError),
      );
      listenLive(
        'orders',
        widget.repository.watchCollection('orders', limit: 200),
        (List<Map<String, dynamic>> rows) => orderRows = rows,
      );
      listenLive(
        'visit_logs',
        widget.repository.watchCollection('visit_logs', limit: 200),
        (List<Map<String, dynamic>> rows) => visitRows = rows,
      );
      listenLive(
        'special_requests',
        widget.repository.watchSpecialRequests(currentUser: widget.currentUser),
        (List<Map<String, dynamic>> rows) => requestRows = rows,
      );
    };
    controller.onCancel = () async {
      staleTicker?.cancel();
      for (final StreamSubscription<List<Map<String, dynamic>>> sub
          in subscriptions) {
        await sub.cancel();
      }
    };
    return controller.stream;
  }

  Stream<List<Map<String, dynamic>>> _watchLatestRaw(String collectionName) {
    final StreamController<List<Map<String, dynamic>>> controller =
        StreamController<List<Map<String, dynamic>>>();
    final Map<String, Map<String, dynamic>> byId =
        <String, Map<String, dynamic>>{};
    final Map<String, Set<String>> idsByField = <String, Set<String>>{};
    final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
    subscriptions = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

    void emit() {
      final List<Map<String, dynamic>> rows = byId.values.toList()
        ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
          final DateTime? da = _DashboardOverviewPageState._toDateTime(
            a['createdAt'] ??
                a['created_at'] ??
                a['updatedAt'] ??
                a['updated_at'] ??
                a['timestamp'],
          );
          final DateTime? db = _DashboardOverviewPageState._toDateTime(
            b['createdAt'] ??
                b['created_at'] ??
                b['updatedAt'] ??
                b['updated_at'] ??
                b['timestamp'],
          );
          if (da == null && db == null) return 0;
          if (da == null) return 1;
          if (db == null) return -1;
          return db.compareTo(da);
        });
      if (!controller.isClosed) {
        controller.add(rows.take(_visibleLimit).toList(growable: false));
      }
    }

    for (final String field in const <String>[
      'createdAt',
      'updatedAt',
      'timestamp',
    ]) {
      int queryIndex = 0;
      for (final Query<Map<String, dynamic>> query in _latestRawQueries(
        collectionName,
        field,
      )) {
        final String queryKey = '$field:${queryIndex++}';
        subscriptions.add(
          query.snapshots().listen((
            QuerySnapshot<Map<String, dynamic>> snapshot,
          ) {
            idsByField[queryKey] = snapshot.docs
                .map(
                  (QueryDocumentSnapshot<Map<String, dynamic>> doc) => doc.id,
                )
                .toSet();
            for (final QueryDocumentSnapshot<Map<String, dynamic>> doc
                in snapshot.docs) {
              byId[doc.id] = <String, dynamic>{
                ...doc.data(),
                'docId': doc.id,
                'sourceCollection': collectionName,
              };
            }
            final Set<String> activeIds = idsByField.values
                .expand((Set<String> ids) => ids)
                .toSet();
            byId.removeWhere(
              (String id, Map<String, dynamic> _) => !activeIds.contains(id),
            );
            emit();
          }, onError: controller.addError),
        );
      }
    }

    if (subscriptions.isEmpty) {
      scheduleMicrotask(emit);
    }

    controller.onCancel = () async {
      for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>> sub
          in subscriptions) {
        await sub.cancel();
      }
    };
    return controller.stream;
  }

  List<Query<Map<String, dynamic>>> _latestRawQueries(
    String collectionName,
    String field,
  ) {
    final CollectionReference<Map<String, dynamic>> collection =
        FirebaseFirestore.instance.collection(collectionName);
    Query<Map<String, dynamic>> baseQuery = collection
        .orderBy(field, descending: true)
        .limit(_visibleLimit);

    if (collectionName != 'notification_logs' &&
        collectionName != 'notifications') {
      return <Query<Map<String, dynamic>>>[baseQuery];
    }
    if (widget.currentUser.isAdmin) {
      return <Query<Map<String, dynamic>>>[baseQuery];
    }
    if (field != 'createdAt') {
      return <Query<Map<String, dynamic>>>[];
    }
    if (widget.currentUser.isSupervisor) {
      final List<String> codes = widget.currentUser.assignedSalesmanCodes
          .map((String code) => code.trim())
          .where((String code) => code.isNotEmpty)
          .toSet()
          .toList(growable: false);
      final List<Query<Map<String, dynamic>>> queries =
          <Query<Map<String, dynamic>>>[];
      for (int start = 0; start < codes.length; start += 30) {
        final int end = start + 30 < codes.length ? start + 30 : codes.length;
        final List<String> chunk = codes.sublist(start, end);
        if (chunk.isEmpty) continue;
        queries.add(
          collection.where('salesmanCode', whereIn: chunk).limit(_visibleLimit),
        );
      }
      return queries;
    }
    if (widget.currentUser.isBranchManager) {
      final String branchId = widget.currentUser.branchId.trim();
      if (branchId.isEmpty) return <Query<Map<String, dynamic>>>[];
      return <Query<Map<String, dynamic>>>[
        collection.where('branchId', isEqualTo: branchId).limit(_visibleLimit),
      ];
    }
    return <Query<Map<String, dynamic>>>[];
  }

  Stream<List<Map<String, dynamic>>> _watchSystemNotifications() {
    if (widget.currentUser.isAdmin) {
      return _watchLatestRaw('dashboard_notifications');
    }

    final StreamController<List<Map<String, dynamic>>> controller =
        StreamController<List<Map<String, dynamic>>>();
    final Map<String, Map<String, dynamic>> byId =
        <String, Map<String, dynamic>>{};
    final List<StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>
    subscriptions = <StreamSubscription<QuerySnapshot<Map<String, dynamic>>>>[];

    void emit() {
      final List<Map<String, dynamic>> rows = byId.values.toList()
        ..sort((Map<String, dynamic> a, Map<String, dynamic> b) {
          final DateTime? left = _DashboardOverviewPageState._toDateTime(
            a['createdAt'] ?? a['updatedAt'] ?? a['timestamp'],
          );
          final DateTime? right = _DashboardOverviewPageState._toDateTime(
            b['createdAt'] ?? b['updatedAt'] ?? b['timestamp'],
          );
          return (right ?? DateTime(1970)).compareTo(left ?? DateTime(1970));
        });
      if (!controller.isClosed) {
        controller.add(rows.take(_visibleLimit).toList(growable: false));
      }
    }

    void listen(Query<Map<String, dynamic>> query) {
      subscriptions.add(
        query.limit(200).snapshots().listen((
          QuerySnapshot<Map<String, dynamic>> snapshot,
        ) {
          for (final DocumentChange<Map<String, dynamic>> change
              in snapshot.docChanges) {
            if (change.type == DocumentChangeType.removed) {
              byId.remove(change.doc.id);
            } else {
              byId[change.doc.id] = <String, dynamic>{
                ...change.doc.data()!,
                'docId': change.doc.id,
                'sourceCollection': 'dashboard_notifications',
              };
            }
          }
          emit();
        }, onError: controller.addError),
      );
    }

    final CollectionReference<Map<String, dynamic>> collection =
        FirebaseFirestore.instance.collection('dashboard_notifications');
    if (widget.currentUser.isSupervisor) {
      final List<String> codes = widget.currentUser.assignedSalesmanCodes;
      for (int start = 0; start < codes.length; start += 30) {
        final int end = start + 30 < codes.length ? start + 30 : codes.length;
        final List<String> chunk = codes.sublist(start, end);
        if (chunk.isNotEmpty) {
          listen(
            collection
                .where('roleTarget', isEqualTo: 'supervisor')
                .where('salesmanCode', whereIn: chunk),
          );
        }
      }
    } else if (widget.currentUser.isBranchManager &&
        widget.currentUser.branchId.isNotEmpty) {
      listen(
        collection
            .where(
              'roleTarget',
              whereIn: const <String>['supervisor', 'branch_manager'],
            )
            .where('branchId', isEqualTo: widget.currentUser.branchId),
      );
    }

    if (subscriptions.isEmpty) {
      scheduleMicrotask(emit);
    }
    controller.onCancel = () async {
      for (final StreamSubscription<QuerySnapshot<Map<String, dynamic>>>
          subscription
          in subscriptions) {
        await subscription.cancel();
      }
    };
    return controller.stream;
  }

  NotificationEntry _entryFor(Map<String, dynamic> item) {
    final String type = _DashboardOverviewPageState._safeText(
      item['notification_type'] ?? item['notificationType'] ?? item['type'],
      fallback: 'update',
    );
    final String salesman = _resolveNotificationSalesman(
      item,
      const <String, String>{},
    );
    final String retailer = _DashboardOverviewPageState._safeText(
      item['retailerName'] ??
          item['retailer_name'] ??
          item['retailerId'] ??
          item['retailer_id'],
      fallback: 'Retailer',
    );
    final String rawMessage = _DashboardOverviewPageState._safeText(
      item['message'],
      fallback: '',
    );
    final String message = rawMessage.isEmpty
        ? _fallbackNotificationMessage(
            type,
            salesman: salesman,
            retailer: retailer,
          )
        : rawMessage;
    final String orderDocumentId = OrderIdResolver.resolve(item);
    final String detail = _buildNotificationSubtitle(
      type: type,
      item: item,
      salesman: salesman,
      retailer: retailer,
      timeLabel: '',
    ).replaceAll(RegExp(r'(\s*\|\s*)+$'), '');
    final String tidyTitle = tidyNotificationTitle(
      message,
      referenceId: _DashboardOverviewPageState._safeText(
        item['reference_id'] ?? item['referenceId'],
        fallback: '',
      ),
    );
    final bool retailerKnown = retailer != 'Retailer';
    final String title = retailerKnown && !tidyTitle.contains(retailer)
        ? '$tidyTitle · $retailer'
        : tidyTitle;
    final String orderRef = _DashboardOverviewPageState._safeText(
      item['orderId'] ?? item['order_id'] ?? item['reference_id'],
      fallback: '',
    );
    return NotificationEntry(
      id: '${item['docId'] ?? ''}',
      type: type,
      title: title,
      detail: _detailWithoutRetailer(detail, retailer, orderRef),
      time: _DashboardOverviewPageState._toDateTime(
        item['createdAt'] ??
            item['created_at'] ??
            item['updatedAt'] ??
            item['updated_at'] ??
            item['created'] ??
            item['timestamp'],
      ),
      unread: !_isRead(item),
      source: item,
      orderDocumentId: type.toLowerCase().contains('order')
          ? orderDocumentId
          : '',
    );
  }

  void _debugTiming(String label) {
    if (!kDebugMode) return;
    debugPrint(
      '[notifications] $label: ${_notificationTimer.elapsedMilliseconds}ms',
    );
  }

  List<Map<String, dynamic>> _scopeSystemNotifications(
    List<Map<String, dynamic>> items,
  ) {
    return items
        .where((Map<String, dynamic> item) {
          if (isBasicEdition) {
            final String type = _DashboardOverviewPageState._safeText(
              item['notification_type'] ??
                  item['notificationType'] ??
                  item['type'],
              fallback: '',
            ).toLowerCase();
            if (type.startsWith('ai_') || type.contains('forecast')) {
              return false;
            }
          }
          final String target = _DashboardOverviewPageState._safeText(
            item['roleTarget'] ?? item['role_target'],
            fallback: '',
          ).toLowerCase();
          if (target.isEmpty || target == 'all') return true;
          if (target == 'admin') {
            return widget.currentUser.isAdmin ||
                widget.currentUser.isBranchManager;
          }
          if (target == 'supervisor') {
            final String salesmanCode = _DashboardOverviewPageState._safeText(
              item['salesmanCode'] ?? item['salesman_code'],
              fallback: '',
            );
            return widget.currentUser.isSupervisor &&
                salesmanCode.isNotEmpty &&
                widget.currentUser.assignedSalesmanCodes.contains(salesmanCode);
          }
          if (target == 'branch_manager') {
            final String branchId = _DashboardOverviewPageState._safeText(
              item['branchId'] ?? item['branch_id'],
              fallback: '',
            );
            return widget.currentUser.isBranchManager &&
                branchId.isNotEmpty &&
                branchId == widget.currentUser.branchId;
          }
          return widget.currentUser.role.toLowerCase() == target;
        })
        .toList(growable: false);
  }

  List<Map<String, dynamic>> _mergeNotificationFeeds(
    List<Map<String, dynamic>> system,
    List<Map<String, dynamic>> activity,
  ) {
    final List<Map<String, dynamic>> merged = <Map<String, dynamic>>[
      ...system,
      ...activity,
    ];
    merged.sort((Map<String, dynamic> a, Map<String, dynamic> b) {
      final DateTime? da = _DashboardOverviewPageState._toDateTime(
        a['createdAt'] ?? a['created_at'] ?? a['created'] ?? a['timestamp'],
      );
      final DateTime? db = _DashboardOverviewPageState._toDateTime(
        b['createdAt'] ?? b['created_at'] ?? b['created'] ?? b['timestamp'],
      );
      if (da == null && db == null) return 0;
      if (da == null) return 1;
      if (db == null) return -1;
      return db.compareTo(da);
    });
    return merged;
  }

  List<Map<String, dynamic>> _scopeNotifications(
    List<Map<String, dynamic>> items,
  ) {
    return TeamScope.filter(widget.currentUser, items);
  }

  String _fallbackNotificationMessage(
    String type, {
    String salesman = 'Salesman',
    String retailer = 'Retailer',
  }) {
    final String safeSalesman = _isGenericSalesmanLabel(salesman)
        ? 'Unknown Salesman'
        : salesman;
    final String safeRetailer = retailer.trim().isEmpty ? 'Retailer' : retailer;
    switch (type) {
      case 'arrival':
        return '$safeSalesman arrived at $safeRetailer.';
      case 'day_complete':
        return '$safeSalesman completed work for the day.';
      case 'order_submitted':
        return 'New order submitted by $safeSalesman for $safeRetailer.';
      default:
        return 'New system notification.';
    }
  }

  String _buildNotificationSubtitle({
    required String type,
    required Map<String, dynamic> item,
    required String salesman,
    required String retailer,
    required String timeLabel,
  }) {
    final String lower = type.toLowerCase();
    if (lower.contains('forecast') || lower.contains('import')) {
      return 'Forecasting service | $timeLabel';
    }
    final bool isSalesmanDriven =
        lower.contains('order') ||
        lower.contains('arrival') ||
        lower.contains('visit') ||
        lower.contains('day_complete') ||
        lower.contains('day-complete');
    if (isSalesmanDriven) {
      return '$salesman | $retailer | $timeLabel';
    }
    final String actor = _DashboardOverviewPageState._safeText(
      item['createdByName'] ??
          item['actorName'] ??
          item['updatedByName'] ??
          item['salesmanName'] ??
          item['salesman_name'],
      fallback: '',
    );
    final String actorLabel =
        actor.isNotEmpty && !_isGenericSalesmanLabel(actor)
        ? actor
        : 'System Admin';

    final String referenceLabel = _referenceLabelForType(type, item);

    return '$actorLabel | $referenceLabel | $timeLabel';
  }

  String _referenceLabelForType(String type, Map<String, dynamic> item) {
    final String collection = _DashboardOverviewPageState._safeText(
      item['reference_collection'] ?? item['referenceCollection'],
      fallback: '',
    );
    if (collection.isNotEmpty) {
      return _humaniseCollectionName(collection);
    }
    final String token = type.toLowerCase();
    if (token.contains('user')) return 'User';
    if (token.contains('product')) return 'Product';
    if (token.contains('retailer')) return 'Retailer';
    if (token.contains('department')) return 'Department';
    if (token.contains('branch')) return 'Branch';
    return 'System';
  }

  String _humaniseCollectionName(String collection) {
    final String tidy = collection
        .replaceAll('_', ' ')
        .replaceAll('-', ' ')
        .trim();
    if (tidy.isEmpty) return 'Record';
    final String lower = tidy.toLowerCase();
    final String singular = lower.endsWith('s')
        ? lower.substring(0, lower.length - 1)
        : lower;
    return singular[0].toUpperCase() + singular.substring(1);
  }
}

class _EmptyPanelState extends StatelessWidget {
  const _EmptyPanelState({
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
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 38, color: context.dso.subtle),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 16,
                fontWeight: FontWeight.w700,
                color: context.dso.ink,
              ),
            ),
            const SizedBox(height: 8),
            Text(
              subtitle,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 13,
                height: 1.6,
                color: context.dso.muted,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class _HeaderTag extends StatelessWidget {
  const _HeaderTag({required this.label});

  final String label;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: context.dso.surfaceSoft,
        borderRadius: BorderRadius.circular(999),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 12,
          fontWeight: FontWeight.w700,
          color: context.dso.body,
        ),
      ),
    );
  }
}

String _resolveNotificationSalesman(
  Map<String, dynamic> item,
  Map<String, String> userIndex,
) {
  for (final String field in <String>[
    'salesmanId',
    'salesman_id',
    'salesmanUid',
    'salesman_uid',
    'actorUid',
    'actor_uid',
    'actorId',
    'actor_id',
    'userId',
    'user_id',
    'uid',
    'employeeCode',
    'staffId',
    'submittedBy',
    'submitted_by',
    'submittedById',
    'submitted_by_id',
    'createdBy',
    'created_by',
    'email',
  ]) {
    final String id = '${item[field]}'.trim();
    if (id.isEmpty || id == 'null' || _isGenericSalesmanLabel(id)) continue;
    final String name =
        userIndex[id] ??
        userIndex[id.toLowerCase()] ??
        userIndex[_compactNameKey(id)] ??
        '';
    if (name.isNotEmpty && !_isGenericSalesmanLabel(name)) return name;
  }

  for (final String field in <String>[
    'salesmanName',
    'salesman_name',
    'submittedByName',
    'createdByName',
    'salesPersonName',
    'salespersonName',
    'name',
    'displayName',
  ]) {
    final String rawName = '${item[field]}'.trim();
    if (rawName.isEmpty || _isGenericSalesmanLabel(rawName)) continue;
    final String verifiedName =
        userIndex[rawName] ??
        userIndex[rawName.toLowerCase()] ??
        userIndex[_compactNameKey(rawName)] ??
        '';
    if (verifiedName.isNotEmpty && !_isGenericSalesmanLabel(verifiedName)) {
      return verifiedName;
    }
    if (!rawName.contains('(') &&
        !rawName.contains('ID:') &&
        rawName.length > 1) {
      return rawName;
    }
  }

  final String parsedFromMessage = _salesmanFromNotificationMessage(
    '${item['message'] ?? ''}',
  );
  if (parsedFromMessage.isNotEmpty &&
      !_isGenericSalesmanLabel(parsedFromMessage)) {
    final String verifiedName =
        userIndex[parsedFromMessage] ??
        userIndex[parsedFromMessage.toLowerCase()] ??
        userIndex[_compactNameKey(parsedFromMessage)] ??
        '';
    if (verifiedName.isNotEmpty && !_isGenericSalesmanLabel(verifiedName)) {
      return verifiedName;
    }
    return parsedFromMessage;
  }

  return 'Unknown Salesman';
}

String _salesmanFromNotificationMessage(String message) {
  if (message.trim().isEmpty) return '';
  final RegExp byForPattern = RegExp(
    r'\bby\s+(.+?)\s+for\s+(.+?)(?:\.|$)',
    caseSensitive: false,
  );
  final RegExpMatch? match = byForPattern.firstMatch(message);
  if (match == null) return '';
  return (match.group(1) ?? '').trim().replaceAll(RegExp(r'\s+'), ' ');
}

bool _isGenericSalesmanLabel(String value) {
  final String text = value.trim().toLowerCase();
  return text.isEmpty ||
      text == 'null' ||
      text == 'n/a' ||
      text == 'na' ||
      text == 'unknown' ||
      text == 'unknown salesman' ||
      text == 'salesman' ||
      text == 'salesman not linked' ||
      text == 'sales person' ||
      text == 'salesperson' ||
      text == 'sales representative';
}

String _compactNameKey(String value) =>
    value.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]'), '');

String _detailWithoutRetailer(String detail, String retailer, String orderRef) {
  final List<String> parts = detail
      .split('|')
      .map((String part) => part.trim())
      .where((String part) => part.isNotEmpty && part != retailer)
      .toList();
  if (orderRef.isNotEmpty && !parts.contains(orderRef)) parts.add(orderRef);
  return parts.join(' · ');
}
