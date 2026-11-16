import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../app/browser_page_history.dart';

import '../../../models/user_profile.dart';
import '../../../repositories/cms_repository.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/collection_rows.dart';
import '../../../utils/my_team_roster.dart';
import '../../../utils/user_facing_error.dart';
import '../../../widgets/team_hierarchy_tree.dart';
import '../../../widgets/catalogue/catalogue_states.dart';
import '../../../widgets/tip_text.dart';

enum MyTeamDestination { orders, visits, routePlanner, activity }

typedef MyTeamNavigate =
    void Function(MyTeamDestination destination, String salesmanUid);

class MyTeamRawData {
  const MyTeamRawData({
    required this.users,
    this.orders = const <Map<String, dynamic>>[],
    this.visits = const <Map<String, dynamic>>[],
    this.plans = const <Map<String, dynamic>>[],
    this.liveRows = const <Map<String, dynamic>>[],
    this.failedSources = const <String>{},
  });

  final List<Map<String, dynamic>> users;
  final List<Map<String, dynamic>> orders;
  final List<Map<String, dynamic>> visits;
  final List<Map<String, dynamic>> plans;
  final List<Map<String, dynamic>> liveRows;
  final Set<String> failedSources;
}

typedef MyTeamLoader = Future<MyTeamRawData> Function(UserProfile user);

class MyTeamPage extends StatefulWidget {
  const MyTeamPage({
    super.key,
    required this.currentUser,
    this.onNavigate,
    @visibleForTesting this.loader,
    @visibleForTesting this.clock,
  });

  final UserProfile currentUser;
  final MyTeamNavigate? onNavigate;

  final MyTeamLoader? loader;

  final DateTime Function()? clock;

  @override
  State<MyTeamPage> createState() => _MyTeamPageState();
}

class _MyTeamPageState extends State<MyTeamPage> {
  static const int _orderReadLimit = 500;
  static const int _visitReadLimit = 500;
  static const int _planReadLimit = 200;
  static const int _userReadLimit = 500;

  Future<MyTeamRawData>? _future;
  Timer? _refreshTimer;
  static const int _fullReloadEvery = 10;
  int _ticks = 0;
  int _failedPolls = 0;
  MyTeamRawData? _latest;

  bool get _isSupervisor => widget.currentUser.isSupervisor;

  List<String> get _assignedCodes => widget.currentUser.assignedSalesmanCodes
      .map((String c) => c.trim())
      .where((String c) => c.isNotEmpty)
      .toList(growable: false);

  DateTime _now() => (widget.clock ?? DateTime.now)();

  @override
  void initState() {
    super.initState();
    if (!(_isSupervisor && _assignedCodes.isEmpty)) {
      _future = _load();
      _refreshTimer = Timer.periodic(const Duration(seconds: 60), (_) {
        if (isBrowserTabHidden()) return;
        _ticks++;
        final MyTeamRawData? cached = _latest;
        final bool full = cached == null || _ticks % _fullReloadEvery == 0;
        final Future<MyTeamRawData> next = full
            ? _load()
            : _loadLiveOnly(cached);
        next.then(
          (MyTeamRawData data) {
            if (!mounted) return;
            setState(() {
              _failedPolls = 0;
              _future = Future<MyTeamRawData>.value(data);
            });
          },
          onError: (Object _) {
            if (!mounted) return;
            setState(() => _failedPolls++);
          },
        );
      });
    }
  }

  @override
  void dispose() {
    _refreshTimer?.cancel();
    super.dispose();
  }

  Future<MyTeamRawData> _load() {
    final MyTeamLoader loader = widget.loader ?? _loadFromFirestore;
    return loader(widget.currentUser).then((MyTeamRawData data) {
      _latest = data;
      return data;
    });
  }

  Future<MyTeamRawData> _loadLiveOnly(MyTeamRawData cached) async {
    final List<Map<String, dynamic>> live = widget.loader != null
        ? (await widget.loader!(widget.currentUser)).liveRows
        : await CmsRepository().getScopedLiveTrackingSnapshot();
    final MyTeamRawData merged = MyTeamRawData(
      users: cached.users,
      orders: cached.orders,
      visits: cached.visits,
      plans: cached.plans,
      liveRows: live,
      failedSources: <String>{...cached.failedSources}..remove('locations'),
    );
    _latest = merged;
    return merged;
  }

  void _reload() {
    _ticks = 0;
    _failedPolls = 0;
    setState(() => _future = _load());
  }

  static Future<MyTeamRawData> _loadFromFirestore(UserProfile user) async {
    final CmsRepository repo = CmsRepository();
    final Future<List<Map<String, dynamic>>> usersRead = repo.getCollectionOnce(
      'users',
      raw: true,
      limit: _userReadLimit,
    );
    usersRead.ignore();
    final Set<String> failed = <String>{};
    Future<List<Map<String, dynamic>>> source(
      String name,
      Future<List<Map<String, dynamic>>> read,
    ) async {
      try {
        return await read;
      } catch (error) {
        debugPrint('My Team could not read $name: $error');
        failed.add(name);
        return const <Map<String, dynamic>>[];
      }
    }

    final List<List<Map<String, dynamic>>> results =
        await Future.wait(<Future<List<Map<String, dynamic>>>>[
          source(
            'orders',
            repo.getCollectionOnce(
              'orders',
              raw: true,
              orderBy: 'submittedAt',
              descending: true,
              limit: _orderReadLimit,
            ),
          ),
          source(
            'visits',
            repo.getCollectionOnce(
              'visit_logs',
              raw: true,
              orderBy: 'arrivalTime',
              descending: true,
              limit: _visitReadLimit,
            ),
          ),
          source(
            'route plans',
            repo.getCollectionOnce(
              'route_plans',
              raw: true,
              orderBy: 'weekStart',
              descending: true,
              limit: _planReadLimit,
            ),
          ),
          source('locations', repo.getScopedLiveTrackingSnapshot()),
        ]);
    final List<Map<String, dynamic>> users = await usersRead;
    return MyTeamRawData(
      users: users,
      orders: results[0],
      visits: results[1],
      plans: results[2],
      liveRows: results[3],
      failedSources: failed,
    );
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final Widget body;
    if (_future == null) {
      body = _MessageState(
        icon: ScootIcons.team,
        title: 'No salespeople are assigned to you yet.',
        message: 'Ask an administrator to assign your team.',
      );
    } else {
      body = FutureBuilder<MyTeamRawData>(
        future: _future,
        builder: (BuildContext context, AsyncSnapshot<MyTeamRawData> snapshot) {
          if (snapshot.hasError) {
            return CatalogueError(
              message: userFacingError(
                snapshot.error!,
                action: 'load your team',
              ),
              onRetry: _reload,
            );
          }
          if (!snapshot.hasData) return const CatalogueLoading(rows: 5);
          return _buildRoster(context, snapshot.data!);
        },
      );
    }
    return DefaultTextStyle.merge(
      style: TextStyle(color: dso.body),
      child: _failedPolls >= 2
          ? Stack(
              children: <Widget>[
                body,
                Positioned(
                  top: 0,
                  right: 8,
                  child: Text(
                    'Last refresh failed',
                    key: const ValueKey<String>('my-team-refresh-failed'),
                    style: ScootType.caption.copyWith(color: dso.muted),
                  ),
                ),
              ],
            )
          : body,
    );
  }

  Widget _buildRoster(BuildContext context, MyTeamRawData data) {
    final DsoColors dso = context.dso;
    if (!collectionRowsComplete(data.users)) {
      return ListView(
        children: <Widget>[
          const _MessageState(
            icon: ScootIcons.info,
            title: 'Incomplete team roster',
            message:
                'Roster counts and team figures are unavailable until the '
                'bounded roster read can be verified.',
          ),
          TextButton.icon(
            onPressed: _reload,
            icon: const Icon(ScootIcons.refresh),
            label: const Text('Refresh'),
          ),
        ],
      );
    }
    final DateTime now = _now();
    final List<TeamMember> members = _isSupervisor
        ? buildSupervisorRoster(
            assignedCodes: _assignedCodes,
            userRows: data.users,
          )
        : buildBranchRoster(userRows: data.users);
    final List<TeamMemberCardData> cards = assembleTeamCards(
      members: members,
      orders: data.orders,
      visits: data.visits,
      liveRows: data.liveRows,
      plans: data.plans,
      now: now,
    );
    final Set<String> incomplete = <String>{
      if (!collectionRowsComplete(data.orders)) 'orders',
      if (!collectionRowsComplete(data.visits)) 'visits',
      if (!collectionRowsComplete(data.plans)) 'route plans',
    };
    final Set<String> failed = <String>{...data.failedSources, ...incomplete};
    final bool canPlan = _isSupervisor;
    return ListView(
      padding: EdgeInsets.zero,
      children: <Widget>[
        Row(
          children: <Widget>[
            Expanded(
              child: Semantics(
                header: true,
                child: Text(
                  myTeamHeaderText(
                    supervisor: _isSupervisor,
                    count: members.length,
                  ),
                  key: const ValueKey<String>('my-team-header'),
                  style: TextStyle(
                    fontSize: 17,
                    fontWeight: FontWeight.w700,
                    color: dso.ink,
                  ),
                ),
              ),
            ),
            IconButton(
              tooltip: 'Refresh',
              onPressed: _reload,
              icon: Icon(ScootIcons.refresh, color: dso.muted),
            ),
          ],
        ),
        if (failed.isNotEmpty) ...<Widget>[
          const SizedBox(height: 8),
          _Notice(
            text:
                'Some team figures are unavailable or incomplete '
                '(${(failed.toList()..sort()).join(', ')}). '
                'Only verified figures are shown.',
          ),
        ],
        if (!_isSupervisor) ...<Widget>[
          const SizedBox(height: 12),
          TeamHierarchyTree(
            managerName: widget.currentUser.name,
            hierarchy: buildTeamHierarchy(
              branchId: widget.currentUser.branchId,
              userRows: data.users,
            ),
          ),
        ],
        const SizedBox(height: 12),
        if (cards.isEmpty)
          const _MessageState(
            icon: ScootIcons.team,
            title: 'No salespeople found in your branch.',
            message: 'Ask an administrator to check branch assignments.',
          )
        else
          LayoutBuilder(
            builder: (BuildContext context, BoxConstraints constraints) {
              const double gap = 14;
              final double width = constraints.maxWidth;
              final int columns = width >= 1000
                  ? 3
                  : width >= 640
                  ? 2
                  : 1;
              final double cardWidth = (width - gap * (columns - 1)) / columns;
              return Wrap(
                spacing: gap,
                runSpacing: gap,
                children: <Widget>[
                  for (final TeamMemberCardData card in cards)
                    SizedBox(
                      width: cardWidth,
                      child: _TeamCard(
                        data: card,
                        now: now,
                        failedSources: failed,
                        canPlanRoutes: canPlan,
                        onNavigate: widget.onNavigate,
                      ),
                    ),
                ],
              );
            },
          ),
        const SizedBox(height: 16),
      ],
    );
  }
}

class _TeamCard extends StatelessWidget {
  const _TeamCard({
    required this.data,
    required this.now,
    required this.failedSources,
    required this.canPlanRoutes,
    required this.onNavigate,
  });

  final TeamMemberCardData data;
  final DateTime now;
  final Set<String> failedSources;
  final bool canPlanRoutes;
  final MyTeamNavigate? onNavigate;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final TeamMember m = data.member;
    final BoxDecoration decoration = BoxDecoration(
      color: dso.card,
      borderRadius: BorderRadius.circular(DsoTokens.rXl),
      border: Border.all(color: dso.hairline),
    );
    if (!m.profileFound) {
      return Container(
        key: ValueKey<String>('my-team-card-${m.code}'),
        padding: const EdgeInsets.all(16),
        decoration: decoration,
        child: Row(
          children: <Widget>[
            Icon(ScootIcons.person, color: dso.warningText),
            const SizedBox(width: 10),
            Expanded(
              child: Text(
                '${m.code} — profile not found',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w700,
                  color: dso.ink,
                ),
              ),
            ),
          ],
        ),
      );
    }
    final bool ordersOk = !failedSources.contains('orders');
    final bool visitsOk = !failedSources.contains('visits');
    final bool plansOk = !failedSources.contains('route plans');
    final bool liveOk = !failedSources.contains('locations');
    final TeamTodayStats s = data.stats;
    return Container(
      key: ValueKey<String>('my-team-card-${m.code}'),
      padding: const EdgeInsets.all(16),
      decoration: decoration,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              Expanded(
                child: Column(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    TipText(
                      m.displayName,
                      maxLines: 2,
                      style: TextStyle(
                        fontSize: 15.5,
                        fontWeight: FontWeight.w700,
                        color: dso.ink,
                      ),
                    ),
                    const SizedBox(height: 2),
                    Text(
                      m.employeeCode.isNotEmpty ? m.employeeCode : m.code,
                      style: TextStyle(fontSize: 12.5, color: dso.muted),
                    ),
                  ],
                ),
              ),
              const SizedBox(width: 8),
              _StatusChip(status: m.status),
            ],
          ),
          const SizedBox(height: 10),
          _InfoLine(icon: ScootIcons.badge, text: m.phone, selectable: true),
          _InfoLine(icon: ScootIcons.inbox, text: m.email, selectable: true),
          _InfoLine(icon: ScootIcons.store, text: m.branchId),
          const SizedBox(height: 12),
          Container(
            padding: const EdgeInsets.all(12),
            decoration: BoxDecoration(
              color: dso.surfaceSoft,
              borderRadius: BorderRadius.circular(DsoTokens.rMd),
            ),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                Text(
                  'Today',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w700,
                    color: dso.muted,
                  ),
                ),
                const SizedBox(height: 6),
                Wrap(
                  spacing: 18,
                  runSpacing: 8,
                  children: <Widget>[
                    _Metric(
                      label: 'Visits',
                      value: visitsOk ? '${s.visitsToday}' : 'Incomplete',
                    ),
                    _Metric(
                      label: 'Orders',
                      value: ordersOk ? '${s.ordersToday}' : 'Incomplete',
                    ),
                    _Metric(
                      label: 'Last order',
                      value: !ordersOk
                          ? 'Incomplete'
                          : s.lastOrderAt == null
                          ? 'None today'
                          : '${formatMalaysiaClock(s.lastOrderAt!)} MYT',
                    ),
                  ],
                ),
              ],
            ),
          ),
          const SizedBox(height: 10),
          Wrap(
            spacing: 18,
            runSpacing: 8,
            children: <Widget>[
              _Metric(
                label: 'Last seen',
                value: liveOk ? formatLastSeen(data.lastSeenAt, now) : '—',
              ),
              _Metric(
                label: 'Route this week',
                value: plansOk ? data.routeStatus.label : 'Incomplete',
              ),
            ],
          ),
          const SizedBox(height: 8),
          Wrap(
            spacing: 4,
            children: <Widget>[
              _action(
                context,
                'orders',
                'View orders',
                ScootIcons.document,
                MyTeamDestination.orders,
              ),
              _action(
                context,
                'visits',
                'View visits',
                ScootIcons.place,
                MyTeamDestination.visits,
              ),
              if (canPlanRoutes)
                _action(
                  context,
                  'route',
                  'Route planner',
                  ScootIcons.route,
                  MyTeamDestination.routePlanner,
                ),
              _action(
                context,
                'activity',
                'Activity',
                ScootIcons.map,
                MyTeamDestination.activity,
              ),
            ],
          ),
        ],
      ),
    );
  }

  Widget _action(
    BuildContext context,
    String id,
    String label,
    IconData icon,
    MyTeamDestination destination,
  ) {
    return TextButton.icon(
      key: ValueKey<String>('my-team-action-$id-${data.member.code}'),
      onPressed: onNavigate == null
          ? null
          : () => onNavigate!(destination, data.member.uid),
      icon: Icon(icon, size: 16),
      label: Text(label),
      style: TextButton.styleFrom(
        foregroundColor: context.dso.accentText,
        padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 4),
        minimumSize: const Size(0, 32),
        tapTargetSize: MaterialTapTargetSize.shrinkWrap,
      ),
    );
  }
}

class _StatusChip extends StatelessWidget {
  const _StatusChip({required this.status});

  final TeamMemberStatus status;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final (String label, Color bg, Color fg) = switch (status) {
      TeamMemberStatus.active => ('Active', dso.successSoft, dso.successText),
      TeamMemberStatus.suspended => (
        'Suspended',
        dso.dangerSoft,
        dso.dangerText,
      ),
      TeamMemberStatus.invited => ('Invited', dso.surfaceSoft, dso.muted),
      TeamMemberStatus.unknown => ('Unknown', dso.surfaceSoft, dso.muted),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DsoTokens.rPill),
      ),
      child: Text(
        label,
        style: TextStyle(
          fontSize: 11.5,
          fontWeight: FontWeight.w700,
          color: fg,
        ),
      ),
    );
  }
}

class _InfoLine extends StatelessWidget {
  const _InfoLine({
    required this.icon,
    required this.text,
    this.selectable = false,
  });

  final IconData icon;
  final String text;
  final bool selectable;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final String shown = text.isEmpty ? '—' : text;
    final TextStyle style = TextStyle(fontSize: 12.5, color: dso.body);
    return Padding(
      padding: const EdgeInsets.only(top: 3),
      child: Row(
        children: <Widget>[
          Icon(icon, size: 15, color: dso.muted),
          const SizedBox(width: 8),
          Expanded(
            child: selectable && text.isNotEmpty
                ? SelectableText(shown, style: style)
                : TipText(shown, style: style, maxLines: 1),
          ),
        ],
      ),
    );
  }
}

class _Metric extends StatelessWidget {
  const _Metric({required this.label, required this.value});

  final String label;
  final String value;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Semantics(
      label: '$label: $value',
      excludeSemantics: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: TextStyle(fontSize: 11.5, color: dso.muted)),
          const SizedBox(height: 2),
          Text(
            value,
            style: TextStyle(
              fontSize: 13.5,
              fontWeight: FontWeight.w600,
              color: dso.ink,
            ),
          ),
        ],
      ),
    );
  }
}

class _Notice extends StatelessWidget {
  const _Notice({required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dso.warningSoft,
        borderRadius: BorderRadius.circular(DsoTokens.rMd),
      ),
      child: Text(
        text,
        style: TextStyle(fontSize: 12.5, color: dso.warningText),
      ),
    );
  }
}

class _MessageState extends StatelessWidget {
  const _MessageState({
    required this.icon,
    required this.title,
    required this.message,
  });

  final IconData icon;
  final String title;
  final String message;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(28),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 36, color: dso.muted),
            const SizedBox(height: 12),
            Text(
              title,
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: dso.ink,
              ),
            ),
            const SizedBox(height: 4),
            Text(
              message,
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 13, color: dso.muted),
            ),
          ],
        ),
      ),
    );
  }
}
