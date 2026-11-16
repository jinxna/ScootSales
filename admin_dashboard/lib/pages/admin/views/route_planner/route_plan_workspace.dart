import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../../models/route_plan.dart';
import '../../../../theme/dso_colors.dart';
import '../../../../utils/retailer_readiness.dart';
import 'route_day_map.dart';

const List<Color> _dayColors = <Color>[
  Color(0xFF2F9E6E),
  Color(0xFF3B82F6),
  Color(0xFF8B5CF6),
  Color(0xFFE08A00),
  Color(0xFFE5484D),
  Color(0xFF0E9AA7),
];

Color routeDayColor(int index) => _dayColors[index % _dayColors.length];

List<String> routeReasonChips(String reason) {
  var text = reason.trim();
  if (text.isEmpty) return const <String>[];
  if (text.toLowerCase().startsWith('prioritised:')) {
    text = text.substring('prioritised:'.length);
  }
  if (text.endsWith('.')) text = text.substring(0, text.length - 1);
  return text
      .split(',')
      .map((String p) => p.trim())
      .where((String p) => p.isNotEmpty)
      .take(3)
      .toList(growable: false);
}

String routeFormatDuration(int minutes) {
  if (minutes <= 0) return '0 min';
  final int h = minutes ~/ 60;
  final int m = minutes % 60;
  if (h == 0) return '$m min';
  if (m == 0) return '${h}h';
  return '${h}h ${m}m';
}

String _shortDay(String label) =>
    label.length >= 3 ? label.substring(0, 3) : label;

const List<String> _months = <String>[
  'Jan',
  'Feb',
  'Mar',
  'Apr',
  'May',
  'Jun',
  'Jul',
  'Aug',
  'Sep',
  'Oct',
  'Nov',
  'Dec',
];

int _travelMinutes(RouteDay day) => day.stops.fold<int>(
  0,
  (int sum, RouteStop s) => sum + s.travelMinutesFromPrevious,
);

class RoutePlanWorkspace extends StatefulWidget {
  const RoutePlanWorkspace({
    super.key,
    required this.plan,
    required this.selectedDay,
    required this.onSelectDay,
    required this.editable,
    required this.maxPerDay,
    required this.coordinateStatusFor,
    required this.segmentBadgeFor,
    required this.onRemoveStop,
    required this.onReorderStop,
    this.roadNotes = const <String>[],
    this.onDismissRoadNotes,
    this.roadRoutingConfigured = false,
    this.onRefreshRoadRoute,
  });

  final RoutePlan plan;
  final int selectedDay;
  final ValueChanged<int> onSelectDay;

  final bool editable;
  final int maxPerDay;
  final CoordinateStatus? Function(RouteStop stop) coordinateStatusFor;
  final Widget? Function(String retailerId) segmentBadgeFor;
  final void Function(int dayIndex, RouteStop stop) onRemoveStop;
  final void Function(int dayIndex, int oldIndex, int newIndex) onReorderStop;

  final List<String> roadNotes;
  final VoidCallback? onDismissRoadNotes;

  final bool roadRoutingConfigured;

  final Future<String?> Function(int dayIndex)? onRefreshRoadRoute;

  @override
  State<RoutePlanWorkspace> createState() => _RoutePlanWorkspaceState();
}

class _RoutePlanWorkspaceState extends State<RoutePlanWorkspace> {
  final ValueNotifier<int?> _hovered = ValueNotifier<int?>(null);
  int? _focused;
  final Set<String> _refreshing = <String>{};
  final Map<String, String> _refreshErrors = <String, String>{};
  final Map<String, DateTime> _lastRefresh = <String, DateTime>{};

  Future<void> _refreshRoad(int dayIndex, RouteDay day) async {
    final Future<String?> Function(int)? refresh = widget.onRefreshRoadRoute;
    if (refresh == null || _refreshing.contains(day.dayId)) return;
    final DateTime now = DateTime.now();
    final DateTime? last = _lastRefresh[day.dayId];
    if (last != null && now.difference(last) < const Duration(seconds: 1)) {
      return;
    }
    _lastRefresh[day.dayId] = now;
    setState(() {
      _refreshing.add(day.dayId);
      _refreshErrors.remove(day.dayId);
    });
    final String? error = await refresh(dayIndex);
    if (!mounted) return;
    setState(() {
      _refreshing.remove(day.dayId);
      if (error != null) _refreshErrors[day.dayId] = error;
    });
  }

  @override
  void didUpdateWidget(RoutePlanWorkspace old) {
    super.didUpdateWidget(old);
    if (old.selectedDay != widget.selectedDay) {
      _hovered.value = null;
      _focused = null;
    }
  }

  @override
  void dispose() {
    _hovered.dispose();
    super.dispose();
  }

  void _setHover(int? seq) {
    if (_hovered.value != seq) _hovered.value = seq;
  }

  _RoadRefreshState? _roadRefreshState(RouteDay day, int dayIndex) {
    if (widget.onRefreshRoadRoute == null) return null;
    return _RoadRefreshState(
      locked: widget.plan.status == 'published',
      configured: widget.roadRoutingConfigured,
      busy: _refreshing.contains(day.dayId),
      error: _refreshErrors[day.dayId],
      onRefresh: () => _refreshRoad(dayIndex, day),
    );
  }

  @override
  Widget build(BuildContext context) {
    final RoutePlan plan = widget.plan;
    final int dayIndex = widget.selectedDay.clamp(0, plan.days.length - 1);
    final RouteDay day = plan.days[dayIndex];
    final double screenH = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double w = box.maxWidth;
        final bool wide = w >= 1120;
        final bool medium = w >= 720 && !wide;
        final double bodyH = math.max(520, screenH - 440);

        final Widget timeline = _Timeline(
          key: ValueKey<String>('timeline_${plan.id}_$dayIndex'),
          day: day,
          dayColor: routeDayColor(dayIndex),
          editable: widget.editable,
          roadRefresh: _roadRefreshState(day, dayIndex),
          hovered: _hovered,
          onHover: _setHover,
          onFocus: (int seq) => setState(() => _focused = seq),
          coordinateStatusFor: widget.coordinateStatusFor,
          segmentBadgeFor: widget.segmentBadgeFor,
          onRemove: (RouteStop s) => widget.onRemoveStop(dayIndex, s),
          onReorder: (int a, int b) => widget.onReorderStop(dayIndex, a, b),
        );
        final Widget map = RouteDayMapView(
          key: ValueKey<String>(
            'map_${plan.salesmanUid}_${day.dayId}_${day.stops.length}',
          ),
          day: day,
          color: routeDayColor(dayIndex),
          hoveredSequence: _hovered,
          onHover: _setHover,
          onStopTap: (int seq) => setState(() => _focused = seq),
          focusedSequence: _focused,
        );
        final Widget rail = _DayRail(
          plan: plan,
          selected: dayIndex,
          maxPerDay: widget.maxPerDay,
          vertical: wide,
          onSelect: widget.onSelectDay,
        );

        final Widget body;
        if (wide) {
          body = SizedBox(
            height: bodyH,
            child: Row(
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                SizedBox(width: 216, child: rail),
                const SizedBox(width: 12),
                SizedBox(width: 400, child: timeline),
                const SizedBox(width: 12),
                Expanded(child: map),
              ],
            ),
          );
        } else if (medium) {
          body = Column(
            children: <Widget>[
              rail,
              const SizedBox(height: 12),
              SizedBox(
                height: bodyH,
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.stretch,
                  children: <Widget>[
                    SizedBox(width: 340, child: timeline),
                    const SizedBox(width: 12),
                    Expanded(child: map),
                  ],
                ),
              ),
            ],
          );
        } else {
          body = Column(
            children: <Widget>[
              rail,
              const SizedBox(height: 12),
              SizedBox(height: 320, child: map),
              const SizedBox(height: 12),
              SizedBox(height: 520, child: timeline),
            ],
          );
        }
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.roadNotes.isNotEmpty)
              _RoadNotesNotice(
                notes: widget.roadNotes,
                onDismiss: widget.onDismissRoadNotes,
              ),
            _KpiStrip(plan: plan),
            const SizedBox(height: 12),
            body,
          ],
        );
      },
    );
  }
}

class _KpiStrip extends StatelessWidget {
  const _KpiStrip({required this.plan});
  final RoutePlan plan;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final int activeDays = plan.days
        .where((RouteDay d) => d.stops.isNotEmpty)
        .length;
    final int service = plan.days.fold<int>(
      0,
      (int sum, RouteDay d) => sum + d.estimatedServiceMinutes,
    );
    final int travel = plan.days.fold<int>(
      0,
      (int sum, RouteDay d) => sum + _travelMinutes(d),
    );
    final List<(String, String, IconData)> items = <(String, String, IconData)>[
      ('Stops', '${plan.totalStops}', ScootIcons.store),
      ('Active days', '$activeDays of 6', Icons.event_available_outlined),
      (
        'Distance',
        '${plan.totalDistanceKm.toStringAsFixed(1)} km',
        Icons.route_outlined,
      ),
      ('Travel', routeFormatDuration(travel), Icons.directions_car_outlined),
      ('Service', routeFormatDuration(service), Icons.timer_outlined),
    ];
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 10),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      child: Wrap(
        alignment: WrapAlignment.spaceEvenly,
        runSpacing: 10,
        children: <Widget>[
          for (final (String, String, IconData) k in items)
            Semantics(
              label: '${k.$1}: ${k.$2}',
              excludeSemantics: true,
              child: SizedBox(
                width: 168,
                child: Row(
                  mainAxisSize: MainAxisSize.min,
                  children: <Widget>[
                    const SizedBox(width: 12),
                    Container(
                      width: 34,
                      height: 34,
                      decoration: BoxDecoration(
                        color: dso.brandSurface,
                        borderRadius: BorderRadius.circular(10),
                      ),
                      child: Icon(k.$3, size: 18, color: dso.accentText),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            k.$2,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 17,
                              height: 1.15,
                              fontWeight: FontWeight.w800,
                              color: dso.ink,
                              fontFeatures: const <FontFeature>[
                                FontFeature.tabularFigures(),
                              ],
                            ),
                          ),
                          Text(
                            k.$1,
                            style: TextStyle(fontSize: 11.5, color: dso.muted),
                          ),
                        ],
                      ),
                    ),
                  ],
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _DayRail extends StatelessWidget {
  const _DayRail({
    required this.plan,
    required this.selected,
    required this.maxPerDay,
    required this.vertical,
    required this.onSelect,
  });

  final RoutePlan plan;
  final int selected;
  final int maxPerDay;
  final bool vertical;
  final ValueChanged<int> onSelect;

  @override
  Widget build(BuildContext context) {
    final int capacity = math.max(
      math.max(1, maxPerDay),
      plan.days.fold<int>(
        0,
        (int m, RouteDay d) => math.max(m, d.stops.length),
      ),
    );
    final List<Widget> cards = <Widget>[
      for (int i = 0; i < plan.days.length; i++)
        _DayCard(
          day: plan.days[i],
          index: i,
          selected: selected == i,
          capacity: capacity,
          compact: !vertical,
          onTap: () => onSelect(i),
        ),
    ];
    if (vertical) {
      return ListView.separated(
        padding: EdgeInsets.zero,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(height: 8),
        itemBuilder: (_, int i) => cards[i],
      );
    }
    return SizedBox(
      height: 92,
      child: ListView.separated(
        scrollDirection: Axis.horizontal,
        padding: EdgeInsets.zero,
        itemCount: cards.length,
        separatorBuilder: (_, _) => const SizedBox(width: 8),
        itemBuilder: (_, int i) => SizedBox(width: 132, child: cards[i]),
      ),
    );
  }
}

class _DayCard extends StatelessWidget {
  const _DayCard({
    required this.day,
    required this.index,
    required this.selected,
    required this.capacity,
    required this.compact,
    required this.onTap,
  });

  final RouteDay day;
  final int index;
  final bool selected;
  final int capacity;
  final bool compact;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final Color color = routeDayColor(index);
    final int stops = day.stops.length;
    final bool free = stops == 0;
    final String date = '${day.date.day} ${_months[day.date.month - 1]}';
    final String detail = free
        ? 'Free day'
        : '${day.totalDistanceKm.toStringAsFixed(1)} km · '
              '${routeFormatDuration(_travelMinutes(day))}';
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${day.dayLabel} $date, $stops stops, ${day.totalDistanceKm.toStringAsFixed(1)} kilometres',
      excludeSemantics: true,
      child: AnimatedContainer(
        duration: const Duration(milliseconds: 160),
        curve: Curves.easeOut,
        decoration: BoxDecoration(
          color: selected ? dso.brandSurface : dso.card,
          borderRadius: BorderRadius.circular(14),
          border: Border.all(
            color: selected ? (free ? dso.muted : color) : dso.hairline,
            width: selected ? 1.6 : 1,
          ),
        ),
        child: Material(
          type: MaterialType.transparency,
          child: InkWell(
            borderRadius: BorderRadius.circular(14),
            onTap: onTap,
            child: Padding(
              padding: EdgeInsets.fromLTRB(12, compact ? 8 : 10, 12, 10),
              child: Column(
                mainAxisAlignment: MainAxisAlignment.center,
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Row(
                    children: <Widget>[
                      Container(
                        width: 8,
                        height: 8,
                        decoration: BoxDecoration(
                          color: free ? dso.subtle : color,
                          shape: BoxShape.circle,
                        ),
                      ),
                      const SizedBox(width: 7),
                      Text(
                        _shortDay(day.dayLabel),
                        style: TextStyle(
                          fontSize: 14,
                          fontWeight: FontWeight.w800,
                          color: free ? dso.muted : dso.ink,
                        ),
                      ),
                      const SizedBox(width: 6),
                      Text(
                        date,
                        style: TextStyle(fontSize: 11.5, color: dso.muted),
                      ),
                      const Spacer(),
                      Text(
                        '$stops',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: free ? dso.subtle : dso.ink,
                        ),
                      ),
                    ],
                  ),
                  const SizedBox(height: 4),
                  Text(
                    detail,
                    maxLines: 1,
                    overflow: TextOverflow.ellipsis,
                    style: TextStyle(fontSize: 11.5, color: dso.muted),
                  ),
                  const SizedBox(height: 7),
                  ClipRRect(
                    borderRadius: BorderRadius.circular(999),
                    child: TweenAnimationBuilder<double>(
                      tween: Tween<double>(
                        end: (stops / capacity).clamp(0.0, 1.0),
                      ),
                      duration: const Duration(milliseconds: 420),
                      curve: Curves.easeOutCubic,
                      builder: (_, double v, _) => LinearProgressIndicator(
                        value: v,
                        minHeight: 5,
                        backgroundColor: dso.surfaceSoft,
                        valueColor: AlwaysStoppedAnimation<Color>(color),
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class _Timeline extends StatelessWidget {
  const _Timeline({
    super.key,
    required this.day,
    required this.dayColor,
    required this.editable,
    required this.roadRefresh,
    required this.hovered,
    required this.onHover,
    required this.onFocus,
    required this.coordinateStatusFor,
    required this.segmentBadgeFor,
    required this.onRemove,
    required this.onReorder,
  });

  final RouteDay day;
  final Color dayColor;
  final bool editable;
  final _RoadRefreshState? roadRefresh;
  final ValueListenable<int?> hovered;
  final ValueChanged<int?> onHover;
  final ValueChanged<int> onFocus;
  final CoordinateStatus? Function(RouteStop) coordinateStatusFor;
  final Widget? Function(String) segmentBadgeFor;
  final ValueChanged<RouteStop> onRemove;
  final void Function(int oldIndex, int newIndex) onReorder;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final List<RouteStop> stops = day.stops;
    int unusable = 0;
    int review = 0;
    for (final RouteStop s in stops) {
      switch (coordinateStatusFor(s)) {
        case CoordinateStatus.missing:
        case CoordinateStatus.invalid:
          unusable++;
        case CoordinateStatus.candidate:
        case CoordinateStatus.needsReview:
          review++;
        case CoordinateStatus.verified:
        case null:
          break;
      }
    }
    return Container(
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.fromLTRB(16, 14, 12, 8),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Column(
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Text(
                        '${day.dayLabel}, ${day.date.day} ${_months[day.date.month - 1]}',
                        style: TextStyle(
                          fontSize: 15,
                          fontWeight: FontWeight.w800,
                          color: dso.ink,
                        ),
                      ),
                      if (stops.isNotEmpty)
                        Text(
                          '${stops.first.arrival} start · ${stops.last.departure} finish · '
                          '${isProviderRoadGeometry(day.geometrySource) ? 'Road distances' : 'Estimated distances'}',
                          style: TextStyle(fontSize: 11.5, color: dso.muted),
                        ),
                    ],
                  ),
                ),
                if (stops.length > 1 && editable)
                  Tooltip(
                    message:
                        'Drag the handle on a stop to change the visiting order. Times are recalculated.',
                    child: Icon(
                      Icons.swap_vert,
                      size: 18,
                      color: dso.subtle,
                      semanticLabel: 'Drag stops to reorder',
                    ),
                  ),
              ],
            ),
          ),
          if (unusable > 0)
            _Banner(
              danger: true,
              text:
                  '$unusable stop${unusable == 1 ? '' : 's'} without usable coordinates. '
                  'The map position and travel time are unreliable until reviewed.',
            )
          else if (review > 0)
            _Banner(
              danger: false,
              text:
                  '$review stop${review == 1 ? ' has' : 's have'} unverified coordinates. '
                  'Verify them in Coordinate Review for confident routing.',
            ),
          if (roadRefresh != null && stops.isNotEmpty)
            _RoadRefreshBar(state: roadRefresh!),
          Divider(height: 1, color: dso.hairline),
          Expanded(
            child: stops.isEmpty
                ? const _DayEmpty()
                : ReorderableListView.builder(
                    padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                    buildDefaultDragHandles: false,
                    itemCount: stops.length,
                    onReorder: (int oldIndex, int newIndex) {
                      if (!editable) return;
                      onReorder(oldIndex, newIndex);
                    },
                    proxyDecorator:
                        (Widget child, int _, Animation<double> a) => Material(
                          color: Colors.transparent,
                          elevation: 6,
                          borderRadius: BorderRadius.circular(14),
                          child: child,
                        ),
                    itemBuilder: (BuildContext context, int i) {
                      final RouteStop s = stops[i];
                      return _StopTile(
                        key: ValueKey<String>('stop_${s.retailerId}'),
                        index: i,
                        stop: s,
                        showConnector: i > 0 || s.legDistanceKm > 0,
                        first: i == 0,
                        dayColor: dayColor,
                        editable: editable,
                        hovered: hovered,
                        onHover: onHover,
                        onFocus: onFocus,
                        status: coordinateStatusFor(s),
                        segmentBadge: segmentBadgeFor(s.retailerId),
                        onRemove: () => onRemove(s),
                      );
                    },
                  ),
          ),
        ],
      ),
    );
  }
}

class _RoadRefreshState {
  const _RoadRefreshState({
    required this.locked,
    required this.configured,
    required this.busy,
    required this.error,
    required this.onRefresh,
  });

  final bool locked;
  final bool configured;
  final bool busy;
  final String? error;
  final VoidCallback onRefresh;
}

class _RoadRefreshBar extends StatelessWidget {
  const _RoadRefreshBar({required this.state});
  final _RoadRefreshState state;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    if (state.locked) {
      return Padding(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
        child: Text(
          'Published plans are locked; regenerate as a new draft to get road routes',
          style: TextStyle(fontSize: 11.5, color: dso.muted),
        ),
      );
    }
    final bool enabled = state.configured && !state.busy;
    return Padding(
      padding: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Tooltip(
            message: state.configured
                ? 'Fetch road distances and the road line for this day'
                : 'No Geoapify key is configured for this build',
            child: OutlinedButton.icon(
              onPressed: enabled ? state.onRefresh : null,
              icon: state.busy
                  ? const SizedBox(
                      width: 14,
                      height: 14,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : const Icon(Icons.alt_route, size: 16),
              label: Text(
                state.busy ? 'Refreshing road route...' : 'Refresh road route',
              ),
            ),
          ),
          if (state.error != null)
            Padding(
              padding: const EdgeInsets.only(top: 6),
              child: Text(
                'Road route unavailable: ${state.error}',
                style: TextStyle(fontSize: 11.5, color: dso.dangerText),
              ),
            ),
        ],
      ),
    );
  }
}

class _RoadNotesNotice extends StatelessWidget {
  const _RoadNotesNotice({required this.notes, required this.onDismiss});
  final List<String> notes;
  final VoidCallback? onDismiss;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      margin: const EdgeInsets.only(bottom: 12),
      padding: const EdgeInsets.fromLTRB(12, 8, 4, 8),
      decoration: BoxDecoration(
        color: dso.warningSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Padding(
            padding: const EdgeInsets.only(top: 2),
            child: Icon(
              Icons.warning_amber_rounded,
              size: 17,
              color: dso.warningText,
            ),
          ),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              notes.join('\n'),
              style: TextStyle(
                fontSize: 12,
                height: 1.4,
                fontWeight: FontWeight.w600,
                color: dso.warningText,
              ),
            ),
          ),
          if (onDismiss != null)
            IconButton(
              tooltip: 'Dismiss',
              visualDensity: VisualDensity.compact,
              icon: Icon(ScootIcons.close, size: 16, color: dso.warningText),
              onPressed: onDismiss,
            ),
        ],
      ),
    );
  }
}

class _Banner extends StatelessWidget {
  const _Banner({required this.text, required this.danger});
  final String text;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final Color bg = danger ? dso.dangerSoft : dso.warningSoft;
    final Color fg = danger ? dso.dangerText : dso.warningText;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(Icons.warning_amber_rounded, size: 17, color: fg),
          const SizedBox(width: 8),
          Expanded(
            child: Text(
              text,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: fg,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _DayEmpty extends StatelessWidget {
  const _DayEmpty();

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Center(
      child: Padding(
        padding: const EdgeInsets.all(24),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Container(
              width: 56,
              height: 56,
              decoration: BoxDecoration(
                color: dso.surfaceSoft,
                shape: BoxShape.circle,
              ),
              child: Icon(Icons.event_available_outlined, color: dso.muted),
            ),
            const SizedBox(height: 12),
            Text(
              'No stops for this day',
              style: TextStyle(
                fontSize: 15,
                fontWeight: FontWeight.w700,
                color: dso.ink,
              ),
            ),
            const SizedBox(height: 6),
            Text(
              'Generate a plan or add retailers to give this day a route.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12.5, height: 1.45, color: dso.muted),
            ),
          ],
        ),
      ),
    );
  }
}

class _StopTile extends StatelessWidget {
  const _StopTile({
    super.key,
    required this.index,
    required this.stop,
    required this.showConnector,
    required this.first,
    required this.dayColor,
    required this.editable,
    required this.hovered,
    required this.onHover,
    required this.onFocus,
    required this.status,
    required this.segmentBadge,
    required this.onRemove,
  });

  final int index;
  final RouteStop stop;
  final bool showConnector;
  final bool first;
  final Color dayColor;
  final bool editable;
  final ValueListenable<int?> hovered;
  final ValueChanged<int?> onHover;
  final ValueChanged<int> onFocus;
  final CoordinateStatus? status;
  final Widget? segmentBadge;
  final VoidCallback onRemove;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final List<String> chips = routeReasonChips(stop.reason);
    final String leg =
        stop.legDistanceKm > 0 || stop.travelMinutesFromPrevious > 0
        ? '${stop.legDistanceKm.toStringAsFixed(1)} km · ~${stop.travelMinutesFromPrevious} min'
        : '';
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (showConnector && leg.isNotEmpty)
          Padding(
            padding: const EdgeInsets.only(left: 21, top: 2, bottom: 2),
            child: Row(
              children: <Widget>[
                SizedBox(
                  width: 2,
                  height: 22,
                  child: DecoratedBox(
                    decoration: BoxDecoration(
                      color: dayColor.withValues(alpha: 0.45),
                    ),
                  ),
                ),
                const SizedBox(width: 12),
                Icon(
                  first ? Icons.trip_origin : Icons.south,
                  size: 12,
                  color: dso.subtle,
                ),
                const SizedBox(width: 6),
                Text(
                  first ? 'From start point · $leg' : leg,
                  style: TextStyle(fontSize: 11.5, color: dso.muted),
                ),
              ],
            ),
          ),
        ValueListenableBuilder<int?>(
          valueListenable: hovered,
          builder: (BuildContext context, int? h, Widget? child) {
            final bool active = h == stop.sequence;
            return AnimatedContainer(
              duration: const Duration(milliseconds: 120),
              decoration: BoxDecoration(
                color: active ? dso.brandSurface : dso.surface,
                borderRadius: BorderRadius.circular(14),
                border: Border.all(
                  color: active ? dayColor : dso.hairline,
                  width: active ? 1.4 : 1,
                ),
              ),
              child: child,
            );
          },
          child: MouseRegion(
            onEnter: (_) => onHover(stop.sequence),
            onExit: (_) => onHover(null),
            child: InkWell(
              borderRadius: BorderRadius.circular(14),
              onTap: () => onFocus(stop.sequence),
              child: Padding(
                padding: const EdgeInsets.fromLTRB(8, 10, 4, 10),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    if (editable)
                      ReorderableDragStartListener(
                        index: index,
                        child: MouseRegion(
                          cursor: SystemMouseCursors.grab,
                          child: Tooltip(
                            message: 'Drag to reorder',
                            child: Padding(
                              padding: const EdgeInsets.only(top: 3, right: 2),
                              child: Icon(
                                Icons.drag_indicator,
                                size: 20,
                                color: dso.subtle,
                                semanticLabel: 'Reorder ${stop.retailerName}',
                              ),
                            ),
                          ),
                        ),
                      )
                    else
                      const SizedBox(width: 8),
                    Container(
                      width: 26,
                      height: 26,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: dayColor,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${stop.sequence}',
                        style: const TextStyle(
                          color: Colors.white,
                          fontSize: 12.5,
                          fontWeight: FontWeight.w800,
                        ),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            stop.retailerName,
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 13.5,
                              fontWeight: FontWeight.w700,
                              color: dso.ink,
                            ),
                          ),
                          const SizedBox(height: 3),
                          Row(
                            children: <Widget>[
                              Icon(ScootIcons.clock, size: 13, color: dso.muted),
                              const SizedBox(width: 4),
                              Text(
                                '${stop.arrival} – ${stop.departure}',
                                style: TextStyle(
                                  fontSize: 12,
                                  color: dso.body,
                                  fontFeatures: const <FontFeature>[
                                    FontFeature.tabularFigures(),
                                  ],
                                ),
                              ),
                            ],
                          ),
                          const SizedBox(height: 6),
                          Wrap(
                            spacing: 6,
                            runSpacing: 5,
                            children: <Widget>[
                              if (status != null)
                                _CoordinateBadge(status: status!),
                              ?segmentBadge,
                              for (final String c in chips) _ReasonChip(c),
                            ],
                          ),
                        ],
                      ),
                    ),
                    if (editable)
                      IconButton(
                        tooltip: 'Remove ${stop.retailerName}',
                        visualDensity: VisualDensity.compact,
                        onPressed: onRemove,
                        icon: Icon(ScootIcons.close, size: 16, color: dso.muted),
                      ),
                  ],
                ),
              ),
            ),
          ),
        ),
      ],
    );
  }
}

class _ReasonChip extends StatelessWidget {
  const _ReasonChip(this.text);
  final String text;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool urgent = text.toLowerCase().startsWith('overdue');
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: urgent ? dso.warningSoft : dso.card,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: urgent ? Colors.transparent : dso.hairline),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          fontWeight: FontWeight.w600,
          color: urgent ? dso.warningText : dso.body,
        ),
      ),
    );
  }
}

class _CoordinateBadge extends StatelessWidget {
  const _CoordinateBadge({required this.status});
  final CoordinateStatus status;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final (Color bg, Color fg, IconData icon, String label) = switch (status) {
      CoordinateStatus.verified => (
        dso.successSoft,
        dso.successText,
        Icons.verified_outlined,
        'Verified',
      ),
      CoordinateStatus.candidate => (
        dso.infoSoft,
        dso.infoText,
        ScootIcons.place,
        'Candidate',
      ),
      CoordinateStatus.needsReview => (
        dso.warningSoft,
        dso.warningText,
        Icons.rule_outlined,
        'Needs review',
      ),
      CoordinateStatus.invalid => (
        dso.dangerSoft,
        dso.dangerText,
        ScootIcons.error,
        'Invalid',
      ),
      CoordinateStatus.missing => (
        dso.dangerSoft,
        dso.dangerText,
        ScootIcons.locationOff,
        'Missing',
      ),
    };
    return Tooltip(
      message: 'Coordinates: $label',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 3),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(999),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(icon, size: 12, color: fg),
            const SizedBox(width: 4),
            Text(
              label,
              style: TextStyle(
                fontSize: 11,
                fontWeight: FontWeight.w700,
                color: fg,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class RoutePlanFooter extends StatelessWidget {
  const RoutePlanFooter({
    super.key,
    required this.status,
    required this.title,
    required this.message,
    required this.saved,
    required this.saving,
    required this.onSave,
    required this.onApprove,
    required this.onPublish,
    required this.onWithdraw,
    required this.onBackToDraft,
    this.readOnly = false,
  });

  final bool readOnly;

  final String status;
  final String title;
  final String message;
  final bool saved;
  final bool saving;
  final VoidCallback onSave;
  final VoidCallback onApprove;
  final VoidCallback onPublish;
  final VoidCallback onWithdraw;
  final VoidCallback onBackToDraft;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool draft = status == 'draft';
    final bool approved = status == 'approved';
    final int current = switch (status) {
      'draft' => 0,
      'approved' => 1,
      'published' => 2,
      _ => -1,
    };
    final Widget steps = Semantics(
      container: true,
      label: current < 0
          ? 'Route status unknown'
          : 'Route status: ${const <String>['Draft', 'Approved', 'Published'][current]}, step ${current + 1} of 3',
      child: ExcludeSemantics(
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            _Step(label: 'Draft', index: 0, current: current),
            _StepLink(done: current > 0),
            _Step(label: 'Approved', index: 1, current: current),
            _StepLink(done: current > 1),
            _Step(label: 'Published', index: 2, current: current),
          ],
        ),
      ),
    );
    final Widget actions = readOnly
        ? const SizedBox.shrink()
        : Wrap(
            spacing: 8,
            runSpacing: 8,
            crossAxisAlignment: WrapCrossAlignment.center,
            children: <Widget>[
              if (saving)
                const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
              if (status == 'published')
                OutlinedButton.icon(
                  onPressed: saving ? null : onWithdraw,
                  icon: const Icon(Icons.undo, size: 18),
                  label: const Text('Withdraw to edit'),
                )
              else ...<Widget>[
                if (approved)
                  OutlinedButton.icon(
                    onPressed: saving ? null : onBackToDraft,
                    icon: const Icon(Icons.undo, size: 18),
                    label: const Text('Back to draft'),
                  ),
                OutlinedButton.icon(
                  onPressed: saving || !draft ? null : onSave,
                  icon: const Icon(Icons.save_outlined, size: 18),
                  label: Text(saved ? 'Save changes' : 'Save draft'),
                ),
                FilledButton.tonalIcon(
                  onPressed: saving || !saved || !draft ? null : onApprove,
                  icon: const Icon(Icons.verified_outlined, size: 18),
                  label: const Text('Approve'),
                ),
                FilledButton.icon(
                  onPressed: saving || !saved || !approved ? null : onPublish,
                  icon: const Icon(Icons.publish_outlined, size: 18),
                  label: const Text('Publish'),
                ),
              ],
            ],
          );
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
        boxShadow: const <BoxShadow>[
          BoxShadow(
            color: Color(0x14000000),
            blurRadius: 16,
            offset: Offset(0, -4),
          ),
        ],
      ),
      child: LayoutBuilder(
        builder: (BuildContext context, BoxConstraints box) {
          final Widget note = Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text(
                readOnly ? 'View only' : title,
                style: TextStyle(
                  fontSize: 13,
                  fontWeight: FontWeight.w700,
                  color: dso.ink,
                ),
              ),
              Text(
                readOnly
                    ? 'Branch managers can view routes but not change them. '
                          'Ask a supervisor or administrator to plan or publish.'
                    : message,
                maxLines: 2,
                overflow: TextOverflow.ellipsis,
                style: TextStyle(fontSize: 12, color: dso.muted),
              ),
            ],
          );
          if (box.maxWidth < 900) {
            return Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SingleChildScrollView(
                  scrollDirection: Axis.horizontal,
                  child: steps,
                ),
                const SizedBox(height: 8),
                note,
                const SizedBox(height: 10),
                actions,
              ],
            );
          }
          return Row(
            children: <Widget>[
              steps,
              const SizedBox(width: 24),
              Expanded(child: note),
              const SizedBox(width: 16),
              actions,
            ],
          );
        },
      ),
    );
  }
}

class _Step extends StatelessWidget {
  const _Step({
    required this.label,
    required this.index,
    required this.current,
  });
  final String label;
  final int index;
  final int current;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool done = index < current;
    final bool active = index == current;
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        AnimatedContainer(
          duration: const Duration(milliseconds: 240),
          width: 22,
          height: 22,
          alignment: Alignment.center,
          decoration: BoxDecoration(
            color: done || active ? dso.accent : Colors.transparent,
            shape: BoxShape.circle,
            border: Border.all(
              color: done || active ? dso.accent : dso.hairline,
              width: 1.5,
            ),
          ),
          child: done
              ? const Icon(ScootIcons.check, size: 14, color: Colors.white)
              : Text(
                  '${index + 1}',
                  style: TextStyle(
                    fontSize: 11.5,
                    fontWeight: FontWeight.w800,
                    color: active ? Colors.white : dso.muted,
                  ),
                ),
        ),
        const SizedBox(width: 6),
        Text(
          label,
          style: TextStyle(
            fontSize: 12.5,
            fontWeight: active ? FontWeight.w800 : FontWeight.w600,
            color: active || done ? dso.ink : dso.muted,
          ),
        ),
      ],
    );
  }
}

class _StepLink extends StatelessWidget {
  const _StepLink({required this.done});
  final bool done;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      width: 28,
      height: 2,
      margin: const EdgeInsets.symmetric(horizontal: 8),
      color: done ? dso.accent : dso.hairline,
    );
  }
}
