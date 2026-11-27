import 'dart:math' as math;

import 'package:flutter/foundation.dart';
import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../../models/route_plan.dart';
import '../../../../theme/dso_colors.dart';
import '../../../../utils/count_label.dart';
import '../../../../utils/retailer_readiness.dart';
import 'route_day_map.dart';
import 'route_plan_checks.dart';
import 'route_road_refresh.dart';

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

class RouteOrderHint {
  const RouteOrderHint({
    required this.extraMinutes,
    required this.straightLine,
    required this.exact,
  });

  final int extraMinutes;
  final bool straightLine;
  final bool exact;

  String get message =>
      'This order takes $extraMinutes minute${extraMinutes == 1 ? '' : 's'} '
      'more than ${exact ? 'the shortest order' : 'a shorter order found'}.'
      '${straightLine ? ' Estimated from straight-line distance.' : ''}';
}

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
    this.orderHint,
    this.onUseShortestOrder,
    this.header,
    this.onMoveStop,
    this.roadStateFor,
    this.lastRoadDayFor,
    this.onRetryRoad,
    this.onOpenBranches,
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
  final RouteOrderHint? orderHint;
  final void Function(int dayIndex)? onUseShortestOrder;
  final Widget? header;
  final void Function(int dayIndex, RouteStop stop, int toDayIndex)? onMoveStop;

  final RouteRoadState Function(String dayId)? roadStateFor;
  final RouteDay? Function(String dayId)? lastRoadDayFor;
  final void Function(int dayIndex)? onRetryRoad;
  final VoidCallback? onOpenBranches;

  @override
  State<RoutePlanWorkspace> createState() => _RoutePlanWorkspaceState();
}

class _RoutePlanWorkspaceState extends State<RoutePlanWorkspace> {
  final ValueNotifier<int?> _hovered = ValueNotifier<int?>(null);
  int? _focused;

  RouteRoadState _roadState(RouteDay day) =>
      widget.roadStateFor?.call(day.dayId) ?? RouteRoadState.settled;

  RouteDay _shown(RouteDay day) =>
      widget.lastRoadDayFor?.call(day.dayId) ?? day;

  bool _estimate(RouteDay day) => routeDayIsEstimate(
    day,
    start: widget.plan.startPoint,
    state: _roadState(day),
  );

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

  @override
  Widget build(BuildContext context) {
    final RoutePlan plan = widget.plan;
    final int dayIndex = widget.selectedDay.clamp(0, plan.days.length - 1);
    final RouteDay day = plan.days[dayIndex];
    final List<RouteDay> shownDays = <RouteDay>[
      for (final RouteDay d in plan.days) _shown(d),
    ];
    final bool updating = plan.days.any(
      (RouteDay d) => _roadState(d) == RouteRoadState.updating,
    );
    final bool mixed =
        !updating &&
        plan.days.any(_estimate) &&
        plan.days.any(routeDayHasRoadMetrics);
    final double screenH = MediaQuery.sizeOf(context).height;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final double w = box.maxWidth;
        final bool twoPane = w >= 900;
        final double mapH = math.min(720, math.max(440, screenH - 160));
        final int capacity = math.max(
          math.max(1, widget.maxPerDay),
          shownDays.fold<int>(
            0,
            (int m, RouteDay d) => math.max(m, d.stops.length),
          ),
        );

        final Widget timeline = _Timeline(
          key: ValueKey<String>('timeline_${plan.id}_$dayIndex'),
          day: day,
          start: plan.startPoint,
          legacy: plan.predatesStartPoints,
          orderHint: widget.editable ? widget.orderHint : null,
          onUseShortestOrder: widget.onUseShortestOrder == null
              ? null
              : () => widget.onUseShortestOrder!(dayIndex),
          dayColor: routeDayColor(dayIndex),
          editable: widget.editable,
          shownDay: _shown(day),
          roadState: _roadState(day),
          estimate: _estimate(day),
          onRetryRoad: widget.onRetryRoad == null
              ? null
              : () => widget.onRetryRoad!(dayIndex),
          onOpenBranches: widget.editable ? widget.onOpenBranches : null,
          hovered: _hovered,
          onHover: _setHover,
          onFocus: (int seq) => setState(() => _focused = seq),
          coordinateStatusFor: widget.coordinateStatusFor,
          segmentBadgeFor: widget.segmentBadgeFor,
          onRemove: (RouteStop s) => widget.onRemoveStop(dayIndex, s),
          onReorder: (int a, int b) => widget.onReorderStop(dayIndex, a, b),
          moveTargets: <(int, String)>[
            for (int i = 0; i < plan.days.length; i++)
              if (i != dayIndex) (i, plan.days[i].dayLabel),
          ],
          onMove: widget.onMoveStop == null
              ? null
              : (RouteStop s, int toDay) =>
                    widget.onMoveStop!(dayIndex, s, toDay),
        );
        final Widget map = RouteDayMapView(
          key: ValueKey<String>(
            'map_${plan.salesmanUid}_${day.dayId}_${day.stops.length}',
          ),
          day: day,
          start: plan.startPoint,
          color: routeDayColor(dayIndex),
          hoveredSequence: _hovered,
          onHover: _setHover,
          onStopTap: (int seq) => setState(() => _focused = seq),
          focusedSequence: _focused,
        );
        final Widget list = Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            for (int i = 0; i < shownDays.length; i++) ...<Widget>[
              if (i > 0) const SizedBox(height: 8),
              _DayCard(
                day: shownDays[i],
                index: i,
                selected: i == dayIndex,
                capacity: capacity,
                onTap: () => widget.onSelectDay(i),
              ),
              if (i == dayIndex) ...<Widget>[
                const SizedBox(height: 8),
                if (!twoPane) ...<Widget>[
                  SizedBox(height: 300, child: map),
                  const SizedBox(height: 8),
                ],
                timeline,
              ],
            ],
          ],
        );
        return Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (widget.header != null) ...<Widget>[
              widget.header!,
              const SizedBox(height: 12),
            ],
            _KpiStrip(
              plan: plan.copyWith(days: shownDays),
              updating: updating,
              mixed: mixed,
            ),
            if (plan.status.toLowerCase() == 'draft') ...<Widget>[
              const SizedBox(height: 12),
              _ChecksBox(
                checks: routePlanChecks(
                  plan,
                  maxPerDay: widget.maxPerDay,
                  coordinateStatusFor: widget.coordinateStatusFor,
                  roadStateFor: (String id) =>
                      widget.roadStateFor?.call(id) ?? RouteRoadState.settled,
                ),
                dayLabels: <String>[
                  for (final RouteDay d in plan.days) d.dayLabel,
                ],
                onSelectDay: widget.onSelectDay,
              ),
            ],
            const SizedBox(height: 12),
            if (twoPane)
              Row(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  SizedBox(width: (w * 0.4).clamp(380.0, 560.0), child: list),
                  const SizedBox(width: 12),
                  Expanded(
                    child: SizedBox(height: mapH, child: map),
                  ),
                ],
              )
            else
              list,
          ],
        );
      },
    );
  }
}

class _KpiStrip extends StatelessWidget {
  const _KpiStrip({
    required this.plan,
    required this.updating,
    required this.mixed,
  });
  final RoutePlan plan;
  final bool updating;
  final bool mixed;

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
      (int sum, RouteDay d) => sum + d.travelMinutes,
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
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Wrap(
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
                                style: TextStyle(
                                  fontSize: 11.5,
                                  color: dso.muted,
                                ),
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
          if (updating || mixed)
            Padding(
              padding: const EdgeInsets.fromLTRB(12, 8, 12, 0),
              child: Text(
                updating
                    ? 'Updating road distances…'
                    : 'Some days are straight-line estimates.',
                key: const ValueKey<String>('route_kpi_distance_note'),
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 11.5, color: dso.muted),
              ),
            ),
        ],
      ),
    );
  }
}

class _ChecksBox extends StatelessWidget {
  const _ChecksBox({
    required this.checks,
    required this.dayLabels,
    required this.onSelectDay,
  });

  final List<RouteCheck> checks;
  final List<String> dayLabels;
  final ValueChanged<int> onSelectDay;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool clear = checks.isEmpty;
    return Container(
      key: const ValueKey<String>('route_checks_box'),
      decoration: BoxDecoration(
        color: dso.card,
        borderRadius: BorderRadius.circular(16),
        border: Border.all(color: dso.hairline),
      ),
      clipBehavior: Clip.antiAlias,
      child: Container(
        padding: const EdgeInsets.fromLTRB(14, 12, 12, 10),
        decoration: BoxDecoration(
          border: Border(
            left: BorderSide(color: clear ? dso.accent : dso.warning, width: 4),
          ),
        ),
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Semantics(
              header: true,
              child: Text(
                clear
                    ? 'Things to check'
                    : 'Things to check (${checks.length})',
                style: TextStyle(
                  fontSize: 14,
                  fontWeight: FontWeight.w800,
                  color: dso.ink,
                ),
              ),
            ),
            const SizedBox(height: 6),
            if (clear)
              _CheckLine(
                icon: Icons.check_circle_outline,
                color: dso.accentText,
                text: 'Nothing to check.',
              )
            else
              for (final RouteCheck check in checks)
                _CheckLine(
                  icon: Icons.error_outline,
                  color: dso.warningText,
                  text: check.message,
                  action: check.dayIndex == null
                      ? null
                      : TextButton(
                          onPressed: () => onSelectDay(check.dayIndex!),
                          child: Text('Show ${dayLabels[check.dayIndex!]}'),
                        ),
                ),
          ],
        ),
      ),
    );
  }
}

class _CheckLine extends StatelessWidget {
  const _CheckLine({
    required this.icon,
    required this.color,
    required this.text,
    this.action,
  });

  final IconData icon;
  final Color color;
  final String text;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Padding(
      padding: const EdgeInsets.symmetric(vertical: 2),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.center,
        children: <Widget>[
          Icon(icon, size: 18, color: color),
          const SizedBox(width: 8),
          Expanded(
            child: Padding(
              padding: const EdgeInsets.symmetric(vertical: 6),
              child: Text(
                text,
                style: TextStyle(fontSize: 13, height: 1.35, color: dso.body),
              ),
            ),
          ),
          if (action != null) ...<Widget>[const SizedBox(width: 8), action!],
        ],
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
    required this.onTap,
  });

  final RouteDay day;
  final int index;
  final bool selected;
  final int capacity;
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
              '${routeFormatDuration(day.travelMinutes)}';
    return Semantics(
      button: true,
      selected: selected,
      label:
          '${day.dayLabel} $date, ${countLabel(stops, 'stop')}, ${day.totalDistanceKm.toStringAsFixed(1)} kilometres',
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
              padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
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
                      Expanded(
                        child: Text(
                          date,
                          maxLines: 1,
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(fontSize: 11.5, color: dso.muted),
                        ),
                      ),
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
    required this.start,
    required this.legacy,
    required this.orderHint,
    required this.onUseShortestOrder,
    required this.dayColor,
    required this.editable,
    required this.shownDay,
    required this.roadState,
    required this.estimate,
    required this.onRetryRoad,
    required this.onOpenBranches,
    required this.hovered,
    required this.onHover,
    required this.onFocus,
    required this.coordinateStatusFor,
    required this.segmentBadgeFor,
    required this.onRemove,
    required this.onReorder,
    required this.moveTargets,
    required this.onMove,
  });

  final List<(int, String)> moveTargets;
  final void Function(RouteStop stop, int toDayIndex)? onMove;
  final RouteDay day;
  final RouteStartPoint? start;
  final bool legacy;
  final RouteOrderHint? orderHint;
  final VoidCallback? onUseShortestOrder;
  final Color dayColor;
  final bool editable;
  final RouteDay shownDay;
  final RouteRoadState roadState;
  final bool estimate;
  final VoidCallback? onRetryRoad;
  final VoidCallback? onOpenBranches;
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
    final bool updating = roadState == RouteRoadState.updating;
    final String totals =
        '${shownDay.totalDistanceKm.toStringAsFixed(1)} km · '
        '${routeFormatDuration(shownDay.travelMinutes)} travel';
    final bool lateReturn = routeDayEndsLate(day, start: start);
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
                          updating
                              ? '$totals · Updating road distances\u2026'
                              : totals,
                          key: const ValueKey<String>('route_day_totals'),
                          style: TextStyle(
                            fontSize: 11.5,
                            color: updating ? dso.subtle : dso.muted,
                          ),
                        ),
                      if (lateReturn)
                        Text(
                          'Back after 18:00',
                          style: TextStyle(
                            fontSize: 11.5,
                            fontWeight: FontWeight.w700,
                            color: dso.warningText,
                          ),
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
          if (legacy)
            Padding(
              key: const ValueKey<String>('route_legacy_note'),
              padding: const EdgeInsets.fromLTRB(16, 0, 16, 8),
              child: Text(
                'This plan was made before route start points. '
                'Regenerate it to use the start point.',
                style: TextStyle(fontSize: 11.5, color: dso.muted),
              ),
            ),
          if (orderHint != null && onUseShortestOrder != null)
            _OrderHintBar(hint: orderHint!, onUseShortest: onUseShortestOrder!),
          if (estimate && stops.isNotEmpty) _EstimateLine(onRetry: onRetryRoad),
          if (start == null && stops.isNotEmpty)
            _NoStartLine(onOpenBranches: onOpenBranches),
          Divider(height: 1, color: dso.hairline),
          stops.isEmpty
              ? const _DayEmpty()
              : ReorderableListView.builder(
                  shrinkWrap: true,
                  physics: const NeverScrollableScrollPhysics(),
                  padding: const EdgeInsets.fromLTRB(12, 10, 12, 14),
                  buildDefaultDragHandles: false,
                  itemCount: stops.length,
                  header: start == null
                      ? null
                      : _StartRow(start: start!, day: day, dayColor: dayColor),
                  footer: start == null
                      ? null
                      : _ReturnLeg(start: start!, day: day, dayColor: dayColor),
                  onReorder: (int oldIndex, int newIndex) {
                    if (!editable) return;
                    onReorder(oldIndex, newIndex);
                  },
                  proxyDecorator: (Widget child, int _, Animation<double> a) =>
                      Material(
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
                      showConnector:
                          i > 0 || start != null || s.legDistanceKm > 0,
                      first: i == 0,
                      firstLegLabel: start == null
                          ? 'From the old route centre'
                          : 'From ${start!.name}',
                      dayColor: dayColor,
                      editable: editable,
                      hovered: hovered,
                      onHover: onHover,
                      onFocus: onFocus,
                      status: coordinateStatusFor(s),
                      segmentBadge: segmentBadgeFor(s.retailerId),
                      onRemove: () => onRemove(s),
                      moveTargets: moveTargets,
                      onMove: onMove == null
                          ? null
                          : (int toDay) => onMove!(s, toDay),
                    );
                  },
                ),
        ],
      ),
    );
  }
}

class _EstimateLine extends StatelessWidget {
  const _EstimateLine({required this.onRetry});

  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Padding(
      key: const ValueKey<String>('route_estimate_line'),
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: <Widget>[
          Text(
            'Distances are straight-line estimates.',
            style: TextStyle(fontSize: 11.5, color: dso.muted),
          ),
          if (onRetry != null)
            TextButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    );
  }
}

class _NoStartLine extends StatelessWidget {
  const _NoStartLine({required this.onOpenBranches});

  final VoidCallback? onOpenBranches;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Padding(
      key: const ValueKey<String>('route_no_start_line'),
      padding: const EdgeInsets.fromLTRB(16, 0, 8, 6),
      child: Wrap(
        crossAxisAlignment: WrapCrossAlignment.center,
        spacing: 4,
        children: <Widget>[
          Text(
            'No start point. Set a start point in Branches.',
            style: TextStyle(fontSize: 11.5, color: dso.warningText),
          ),
          if (onOpenBranches != null)
            TextButton(
              onPressed: onOpenBranches,
              child: const Text('Open Branches'),
            ),
        ],
      ),
    );
  }
}

class _StartRow extends StatelessWidget {
  const _StartRow({
    required this.start,
    required this.day,
    required this.dayColor,
  });

  final RouteStartPoint start;
  final RouteDay day;
  final Color dayColor;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final RouteStop first = day.stops.first;
    final int leaves =
        routeClockMinutes(first.arrival) - first.travelMinutesFromPrevious;
    String two(int v) => v.toString().padLeft(2, '0');
    final String leavesAt = '${two(leaves ~/ 60)}:${two(leaves % 60)}';
    return Container(
      key: const ValueKey<String>('route_start_row'),
      margin: const EdgeInsets.only(bottom: 2),
      padding: const EdgeInsets.fromLTRB(12, 10, 12, 10),
      decoration: BoxDecoration(
        color: dso.brandSurface,
        borderRadius: BorderRadius.circular(14),
        border: Border.all(color: dso.hairline),
      ),
      child: Row(
        children: <Widget>[
          Container(
            width: 26,
            height: 26,
            alignment: Alignment.center,
            decoration: BoxDecoration(
              color: Colors.white,
              shape: BoxShape.circle,
              border: Border.all(color: dayColor, width: 2.5),
            ),
            child: Text(
              'S',
              style: TextStyle(
                color: dayColor,
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
                  'Start: ${start.name}',
                  style: TextStyle(
                    fontSize: 13.5,
                    fontWeight: FontWeight.w700,
                    color: dso.ink,
                  ),
                ),
                Text(
                  'Leaves $leavesAt · first leg '
                  '${first.legDistanceKm.toStringAsFixed(1)} km, '
                  '${first.travelMinutesFromPrevious} min, '
                  'counted in the day total',
                  style: TextStyle(fontSize: 11.5, color: dso.muted),
                ),
              ],
            ),
          ),
        ],
      ),
    );
  }
}

class _OrderHintBar extends StatelessWidget {
  const _OrderHintBar({required this.hint, required this.onUseShortest});

  final RouteOrderHint hint;
  final VoidCallback onUseShortest;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      margin: const EdgeInsets.fromLTRB(12, 0, 12, 10),
      padding: const EdgeInsets.fromLTRB(10, 6, 6, 6),
      decoration: BoxDecoration(
        color: dso.warningSoft,
        borderRadius: BorderRadius.circular(10),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Text(
              hint.message,
              style: TextStyle(
                fontSize: 12,
                height: 1.35,
                fontWeight: FontWeight.w600,
                color: dso.warningText,
              ),
            ),
          ),
          const SizedBox(width: 8),
          TextButton(
            onPressed: onUseShortest,
            child: Text(hint.exact ? 'Use shortest' : 'Use shorter order'),
          ),
        ],
      ),
    );
  }
}

class _ReturnLeg extends StatelessWidget {
  const _ReturnLeg({
    required this.start,
    required this.day,
    required this.dayColor,
  });

  final RouteStartPoint start;
  final RouteDay day;
  final Color dayColor;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Padding(
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
          Icon(Icons.trip_origin, size: 12, color: dso.subtle),
          const SizedBox(width: 6),
          Expanded(
            child: Text(
              'End: back at ${start.name} ${routeDayBackAtLabel(day)} · '
              '${day.returnLegDistanceKm.toStringAsFixed(1)} km · '
              '~${day.returnTravelMinutes} min',
              key: const ValueKey<String>('route_end_row'),
              style: TextStyle(fontSize: 11.5, color: dso.muted),
            ),
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
    required this.firstLegLabel,
    required this.dayColor,
    required this.editable,
    required this.hovered,
    required this.onHover,
    required this.onFocus,
    required this.status,
    required this.segmentBadge,
    required this.onRemove,
    required this.moveTargets,
    required this.onMove,
  });

  final List<(int, String)> moveTargets;
  final ValueChanged<int>? onMove;
  final int index;
  final RouteStop stop;
  final bool showConnector;
  final bool first;
  final String firstLegLabel;
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
    final bool formulaReason = stop.reason.trim().toLowerCase().startsWith(
      'prioritised:',
    );
    final List<String> chips = formulaReason
        ? routeReasonChips(stop.reason)
        : const <String>[];
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
                Flexible(
                  child: Text(
                    first ? '$firstLegLabel · $leg' : leg,
                    style: TextStyle(fontSize: 11.5, color: dso.muted),
                  ),
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
                              Icon(
                                ScootIcons.clock,
                                size: 13,
                                color: dso.muted,
                              ),
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
                          if (!formulaReason && stop.reason.trim().isNotEmpty)
                            Padding(
                              padding: const EdgeInsets.only(top: 6),
                              child: _ExpandableReason(stop.reason.trim()),
                            ),
                        ],
                      ),
                    ),
                    if (editable && onMove != null && moveTargets.isNotEmpty)
                      PopupMenuButton<int>(
                        tooltip: 'Move ${stop.retailerName} to another day',
                        padding: EdgeInsets.zero,
                        onSelected: onMove,
                        itemBuilder: (BuildContext context) =>
                            <PopupMenuEntry<int>>[
                              for (final (int dayIndex, String label)
                                  in moveTargets)
                                PopupMenuItem<int>(
                                  value: dayIndex,
                                  child: Text('Move to $label'),
                                ),
                            ],
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        icon: Icon(
                          Icons.event_repeat_outlined,
                          size: 18,
                          color: dso.muted,
                        ),
                      ),
                    if (editable)
                      IconButton(
                        tooltip: 'Remove ${stop.retailerName}',
                        constraints: const BoxConstraints(
                          minWidth: 40,
                          minHeight: 40,
                        ),
                        onPressed: onRemove,
                        icon: Icon(
                          ScootIcons.close,
                          size: 18,
                          color: dso.muted,
                        ),
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

class _ExpandableReason extends StatefulWidget {
  const _ExpandableReason(this.text);
  final String text;

  @override
  State<_ExpandableReason> createState() => _ExpandableReasonState();
}

class _ExpandableReasonState extends State<_ExpandableReason> {
  bool _open = false;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final TextStyle style = TextStyle(
      fontSize: 11.5,
      height: 1.35,
      color: dso.body,
    );
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) {
        final TextPainter painter = TextPainter(
          text: TextSpan(text: widget.text, style: style),
          maxLines: 2,
          textDirection: Directionality.of(context),
        )..layout(maxWidth: box.maxWidth);
        final bool long = painter.didExceedMaxLines;
        painter.dispose();
        final Widget text = Text(
          widget.text,
          maxLines: _open || !long ? null : 2,
          overflow: _open || !long ? null : TextOverflow.ellipsis,
          style: style,
        );
        if (!long) return text;
        return Semantics(
          button: true,
          label: _open ? 'Show less' : 'Show the full reason',
          child: InkWell(
            onTap: () => setState(() => _open = !_open),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              children: <Widget>[
                text,
                Text(
                  _open ? 'Show less' : 'Show more',
                  style: style.copyWith(
                    fontWeight: FontWeight.w700,
                    color: dso.accentText,
                  ),
                ),
              ],
            ),
          ),
        );
      },
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
    this.onDeleteDraft,
    this.readOnly = false,
  });

  final bool readOnly;
  final VoidCallback? onDeleteDraft;

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
                if (draft && saved && onDeleteDraft != null)
                  TextButton.icon(
                    onPressed: saving ? null : onDeleteDraft,
                    icon: const Icon(Icons.delete_outline, size: 18),
                    label: const Text('Delete draft'),
                  ),
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
