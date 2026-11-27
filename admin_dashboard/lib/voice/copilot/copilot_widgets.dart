import 'dart:async';
import 'dart:math' as math;
import 'dart:ui' show ImageFilter, PointerDeviceKind;

import 'package:flutter/material.dart';

import '../../models/action_centre_item.dart';
import '../../theme/dso_colors.dart';
import '../../widgets/weekly_bar_chart.dart';
import 'copilot_controller.dart';
import 'copilot_rank_why.dart';
import 'copilot_scout.dart';
import 'copilot_status.dart';

Color? copilotStatusColor(DsoColors dso, CopilotServerState state) =>
    switch (state) {
      CopilotServerState.ready => dso.success,
      CopilotServerState.waking => dso.warning,
      CopilotServerState.offline => dso.subtle,
      CopilotServerState.off => null,
    };

String copilotStatusText(CopilotServerState state) => switch (state) {
  CopilotServerState.ready => 'Ready · assistant model on',
  CopilotServerState.waking => 'Assistant model waking up · up to 1 min',
  CopilotServerState.offline => 'Assistant model offline · basic commands work',
  CopilotServerState.off => 'Basic commands only',
};

String _capital(String text) =>
    text.isEmpty ? text : '${text[0].toUpperCase()}${text.substring(1)}';

Color copilotEdge(DsoColors dso) => Color.lerp(dso.hairline, dso.body, 0.3)!;

bool _reduceMotion(BuildContext context) =>
    MediaQuery.maybeOf(context)?.disableAnimations ?? false;

class StatusDot extends StatelessWidget {
  const StatusDot({super.key, required this.color, this.size = 8, this.ring});

  final Color color;
  final double size;

  final Color? ring;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: color,
      shape: BoxShape.circle,
      border: ring == null ? null : Border.all(color: ring!, width: 2),
    ),
  );
}

class CopilotMark extends StatelessWidget {
  const CopilotMark({super.key, this.size = 28});

  final double size;

  @override
  Widget build(BuildContext context) => Container(
    width: size,
    height: size,
    decoration: BoxDecoration(
      color: context.dso.accent,
      borderRadius: BorderRadius.circular(size * 0.3),
    ),
    child: Icon(Icons.auto_awesome, size: size * 0.6, color: Colors.white),
  );
}

class CopilotStatusLine extends StatelessWidget {
  const CopilotStatusLine({super.key, required this.state});

  final CopilotServerState state;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final Color? dot = copilotStatusColor(dso, state);
    return Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        if (dot != null) ...<Widget>[
          StatusDot(color: dot),
          const SizedBox(width: 6),
        ],
        Flexible(
          child: Text(
            copilotStatusText(state),
            maxLines: 1,
            overflow: TextOverflow.ellipsis,
            style: TextStyle(fontSize: 12, color: dso.body),
          ),
        ),
      ],
    );
  }
}

class CopilotHeader extends StatelessWidget {
  const CopilotHeader({
    super.key,
    required this.onClose,
    required this.onNewChat,
  });

  final VoidCallback onClose;

  final VoidCallback? onNewChat;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool dark = Theme.of(context).brightness == Brightness.dark;
    final bool solid = MediaQuery.maybeOf(context)?.highContrast ?? false;
    final Color accent = dso.accentText;
    final BorderRadius radius = BorderRadius.circular(18);
    final Widget label = Row(
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Icon(Icons.mic_none_rounded, size: 16, color: accent),
        const SizedBox(width: 6),
        Text(
          'Scout',
          style: TextStyle(
            fontSize: 14,
            fontWeight: FontWeight.w600,
            color: accent,
          ),
        ),
        const SizedBox(width: 6),
        Container(
          padding: const EdgeInsets.symmetric(horizontal: 4),
          decoration: BoxDecoration(
            border: Border.all(color: accent.withValues(alpha: 0.5)),
            borderRadius: BorderRadius.circular(5),
          ),
          child: Text(
            'beta',
            style: TextStyle(
              fontSize: 12,
              height: 1.25,
              fontWeight: FontWeight.w700,
              color: accent,
            ),
          ),
        ),
      ],
    );
    final Widget pill = Container(
      constraints: const BoxConstraints(minHeight: 36),
      padding: const EdgeInsets.symmetric(horizontal: 14),
      alignment: Alignment.center,
      decoration: BoxDecoration(
        borderRadius: radius,
        color: solid ? Color.lerp(dso.card, dso.accent, 0.14) : null,
        gradient: solid
            ? null
            : LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: dark
                    ? const <Color>[Color(0x29FFFFFF), Color(0x0AFFFFFF)]
                    : const <Color>[Color(0x99FFFFFF), Color(0x33FFFFFF)],
              ),
        border: Border.all(
          color: dark ? const Color(0x33FFFFFF) : const Color(0xF2FFFFFF),
        ),
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: dso.accent.withValues(alpha: 0.2),
            blurRadius: 10,
            offset: const Offset(0, 2),
          ),
        ],
      ),
      child: label,
    );
    return Container(
      padding: const EdgeInsets.fromLTRB(6, 10, 6, 10),
      decoration: BoxDecoration(
        gradient: LinearGradient(
          colors: <Color>[
            Color.lerp(dso.card, dso.accent, dark ? 0.22 : 0.2)!,
            Color.lerp(dso.card, dso.accent, dark ? 0.1 : 0.08)!,
            Color.lerp(dso.card, dso.accent, dark ? 0.2 : 0.17)!,
          ],
          stops: const <double>[0, 0.45, 1],
        ),
      ),
      child: Row(
        children: <Widget>[
          Expanded(
            child: Align(
              alignment: Alignment.centerLeft,
              child: _BarButton(
                label: 'Close Scout',
                icon: Icons.close,
                onPressed: onClose,
              ),
            ),
          ),
          Semantics(
            label: 'Scout beta',
            excludeSemantics: true,
            child: solid
                ? pill
                : ClipRRect(
                    borderRadius: radius,
                    child: BackdropFilter(
                      filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                      child: pill,
                    ),
                  ),
          ),
          Expanded(
            child: Align(
              alignment: Alignment.centerRight,
              child: _BarButton(
                label: 'New chat',
                icon: Icons.edit_outlined,
                onPressed: onNewChat,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class _BarButton extends StatelessWidget {
  const _BarButton({
    required this.label,
    required this.icon,
    required this.onPressed,
  });

  final String label;
  final IconData icon;
  final VoidCallback? onPressed;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    enabled: onPressed != null,
    label: label,
    excludeSemantics: true,
    onTap: onPressed,
    child: Tooltip(
      message: label,
      child: Opacity(
        opacity: onPressed == null ? 0.35 : 1,
        child: InkWell(
          borderRadius: BorderRadius.circular(8),
          onTap: onPressed,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Icon(icon, size: 20, color: context.dso.accentText),
          ),
        ),
      ),
    ),
  );
}

class CopilotContextStrip extends StatelessWidget {
  const CopilotContextStrip({
    super.key,
    required this.itemsShown,
    required this.focus,
    required this.onClearFocus,
  });

  final int itemsShown;
  final ActionCentreItem? focus;
  final VoidCallback onClearFocus;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.fromLTRB(14, 8, 14, 8),
      decoration: BoxDecoration(
        color: dso.surface,
        border: Border(bottom: BorderSide(color: dso.hairline)),
      ),
      child: Wrap(
        spacing: 6,
        runSpacing: 6,
        crossAxisAlignment: WrapCrossAlignment.center,
        children: <Widget>[
          Text('Context', style: TextStyle(fontSize: 12, color: dso.body)),
          _Pill(
            label: '$itemsShown items shown',
            bg: dso.surfaceSoft,
            fg: dso.body,
          ),
          if (focus != null)
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 240),
              child: Material(
                color: dso.brandSurface,
                shape: const StadiumBorder(),
                child: InkWell(
                  customBorder: const StadiumBorder(),
                  onTap: onClearFocus,
                  child: Padding(
                    padding: const EdgeInsets.fromLTRB(10, 3, 6, 3),
                    child: Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        Flexible(
                          child: Text(
                            'Focus: ${focus!.title}',
                            maxLines: 1,
                            overflow: TextOverflow.ellipsis,
                            style: TextStyle(
                              fontSize: 12,
                              color: dso.accentText,
                            ),
                          ),
                        ),
                        const SizedBox(width: 4),
                        Icon(
                          Icons.close,
                          size: 13,
                          semanticLabel: 'Clear focus',
                          color: dso.accentText,
                        ),
                      ],
                    ),
                  ),
                ),
              ),
            ),
        ],
      ),
    );
  }
}

class _Pill extends StatelessWidget {
  const _Pill({required this.label, required this.bg, required this.fg});

  final String label;
  final Color bg;
  final Color fg;

  @override
  Widget build(BuildContext context) => Container(
    padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 2),
    decoration: BoxDecoration(
      color: bg,
      borderRadius: BorderRadius.circular(999),
    ),
    child: Text(label, style: TextStyle(fontSize: 12, color: fg)),
  );
}

const List<String> _months = <String>[
  'January',
  'February',
  'March',
  'April',
  'May',
  'June',
  'July',
  'August',
  'September',
  'October',
  'November',
  'December',
];
const List<String> _days = <String>[
  'Monday',
  'Tuesday',
  'Wednesday',
  'Thursday',
  'Friday',
  'Saturday',
  'Sunday',
];

String copilotGreeting(DateTime now) => now.hour < 12
    ? 'Good morning'
    : now.hour < 18
    ? 'Good afternoon'
    : 'Good evening';

String copilotDateLine(DateTime now) =>
    '${_days[now.weekday - 1]}, ${now.day} ${_months[now.month - 1]}';

class CopilotHero extends StatelessWidget {
  const CopilotHero({
    super.key,
    required this.scope,
    required this.firstName,
    required this.state,
    required this.now,
  });

  final String scope;
  final String firstName;
  final CopilotServerState state;
  final DateTime now;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Center(
      child: SingleChildScrollView(
        padding: const EdgeInsets.fromLTRB(16, 0, 16, 20),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Text(
              '${copilotDateLine(now)} · $scope',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: dso.body),
            ),
            const SizedBox(height: 4),
            Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: '${copilotGreeting(now)},\n'),
                  TextSpan(
                    text: '$firstName.',
                    style: TextStyle(color: dso.accentText),
                  ),
                ],
              ),
              textAlign: TextAlign.center,
              style: TextStyle(
                fontSize: 28,
                height: 1.15,
                letterSpacing: -0.4,
                fontWeight: FontWeight.w700,
                color: dso.ink,
              ),
            ),
            const SizedBox(height: 12),
            CopilotStatusLine(state: state),
          ],
        ),
      ),
    );
  }
}

class CopilotSuggestions extends StatelessWidget {
  const CopilotSuggestions({
    super.key,
    required this.label,
    required this.suggestions,
    required this.onPick,
  });

  final String label;
  final List<String> suggestions;
  final ValueChanged<String> onPick;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final int perRow = (suggestions.length + 1) ~/ 2;
    final List<List<String>> rows = <List<String>>[
      suggestions.take(perRow).toList(),
      suggestions.skip(perRow).toList(),
    ].where((List<String> r) => r.isNotEmpty).toList();
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        Padding(
          padding: const EdgeInsets.fromLTRB(16, 0, 16, 6),
          child: Text(
            label.toUpperCase(),
            style: TextStyle(fontSize: 12, letterSpacing: 0.5, color: dso.body),
          ),
        ),
        ScrollConfiguration(
          behavior: ScrollConfiguration.of(context).copyWith(
            scrollbars: false,
            dragDevices: <PointerDeviceKind>{
              PointerDeviceKind.touch,
              PointerDeviceKind.mouse,
              PointerDeviceKind.trackpad,
              PointerDeviceKind.stylus,
            },
          ),
          child: SingleChildScrollView(
            key: const ValueKey<String>('copilot-suggestions'),
            scrollDirection: Axis.horizontal,
            padding: const EdgeInsets.fromLTRB(16, 0, 16, 10),
            child: Column(
              crossAxisAlignment: CrossAxisAlignment.start,
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int r = 0; r < rows.length; r++) ...<Widget>[
                  if (r > 0) const SizedBox(height: 8),
                  Row(
                    mainAxisSize: MainAxisSize.min,
                    children: <Widget>[
                      for (int i = 0; i < rows[r].length; i++) ...<Widget>[
                        if (i > 0) const SizedBox(width: 8),
                        _SuggestionPill(
                          text: rows[r][i],
                          onTap: () => onPick(rows[r][i]),
                        ),
                      ],
                    ],
                  ),
                ],
              ],
            ),
          ),
        ),
      ],
    );
  }
}

class _SuggestionPill extends StatelessWidget {
  const _SuggestionPill({required this.text, required this.onTap});

  final String text;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Semantics(
      button: true,
      label: text,
      excludeSemantics: true,
      onTap: onTap,
      child: Material(
        color: dso.card,
        shape: RoundedRectangleBorder(
          borderRadius: BorderRadius.circular(12),
          side: BorderSide(color: copilotEdge(dso)),
        ),
        child: InkWell(
          customBorder: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(12),
          ),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 38),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 13),
              child: Center(
                widthFactor: 1,
                child: Text(
                  text,
                  maxLines: 1,
                  style: TextStyle(
                    fontSize: 13,
                    fontWeight: FontWeight.w500,
                    color: dso.ink,
                  ),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CopilotUserBubble extends StatelessWidget {
  const CopilotUserBubble({super.key, required this.text});

  final String text;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => Align(
        alignment: Alignment.centerRight,
        child: Container(
          constraints: BoxConstraints(maxWidth: box.maxWidth * 0.84),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: dso.accent,
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomLeft: Radius.circular(14),
              bottomRight: Radius.circular(3),
            ),
          ),
          child: DefaultSelectionStyle(
            selectionColor: Colors.white.withValues(alpha: 0.45),
            child: Text(
              text,
              style: const TextStyle(fontSize: 13, color: Colors.white),
            ),
          ),
        ),
      ),
    );
  }
}

class CopilotAssistantRow extends StatelessWidget {
  const CopilotAssistantRow({
    super.key,
    required this.children,
    this.kind = CopilotEntryKind.answer,
  });

  final List<Widget> children;
  final CopilotEntryKind kind;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final (Color bg, Color border) = switch (kind) {
      CopilotEntryKind.answer => (dso.card, copilotEdge(dso)),
      CopilotEntryKind.refusal => (
        dso.warningSoft,
        dso.warning.withValues(alpha: 0.8),
      ),
      CopilotEntryKind.error => (
        dso.dangerSoft,
        dso.danger.withValues(alpha: 0.5),
      ),
    };
    final bool plain = kind == CopilotEntryKind.answer;
    return LayoutBuilder(
      builder: (BuildContext context, BoxConstraints box) => Align(
        alignment: Alignment.centerLeft,
        child: Container(
          constraints: BoxConstraints(maxWidth: box.maxWidth * 0.94),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
          decoration: BoxDecoration(
            color: bg,
            border: Border.all(color: border),
            borderRadius: plain
                ? const BorderRadius.only(
                    topLeft: Radius.circular(14),
                    topRight: Radius.circular(14),
                    bottomRight: Radius.circular(14),
                    bottomLeft: Radius.circular(3),
                  )
                : BorderRadius.circular(10),
          ),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            mainAxisSize: MainAxisSize.min,
            children: children,
          ),
        ),
      ),
    );
  }
}

class CopilotText extends StatelessWidget {
  const CopilotText(this.text, {super.key, this.title, this.titleColor});

  final String text;
  final String? title;
  final Color? titleColor;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        if (title != null)
          Text(
            title!,
            style: TextStyle(
              fontSize: 13,
              height: 1.4,
              fontWeight: FontWeight.w700,
              color: titleColor ?? dso.ink,
            ),
          ),
        Text(text, style: TextStyle(fontSize: 13, height: 1.4, color: dso.ink)),
      ],
    );
  }
}

class CopilotRetryButton extends StatelessWidget {
  const CopilotRetryButton({super.key, required this.onPressed});

  final VoidCallback onPressed;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Padding(
      padding: const EdgeInsets.only(top: 6),
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, 40),
          foregroundColor: dso.dangerText,
          backgroundColor: dso.card,
          side: BorderSide(color: dso.dangerText),
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(18),
          ),
        ),
        child: const Text(
          'Retry',
          style: TextStyle(fontSize: 13, fontWeight: FontWeight.w600),
        ),
      ),
    );
  }
}

class CopilotTypingDots extends StatefulWidget {
  const CopilotTypingDots({super.key});

  @override
  State<CopilotTypingDots> createState() => _CopilotTypingDotsState();
}

class _CopilotTypingDotsState extends State<CopilotTypingDots>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1000),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    if (_reduceMotion(context)) {
      _anim.stop();
    } else if (!_anim.isAnimating) {
      _anim.repeat();
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool still = _reduceMotion(context);
    return Semantics(
      container: true,
      liveRegion: true,
      label: 'Working…',
      excludeSemantics: true,
      child: Align(
        alignment: Alignment.centerLeft,
        child: Container(
          padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 12),
          decoration: BoxDecoration(
            color: dso.card,
            border: Border.all(color: copilotEdge(dso)),
            borderRadius: const BorderRadius.only(
              topLeft: Radius.circular(14),
              topRight: Radius.circular(14),
              bottomRight: Radius.circular(14),
              bottomLeft: Radius.circular(3),
            ),
          ),
          child: AnimatedBuilder(
            animation: _anim,
            builder: (BuildContext context, _) => Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                for (int i = 0; i < 3; i++) ...<Widget>[
                  if (i > 0) const SizedBox(width: 4),
                  Opacity(
                    opacity: still
                        ? 0.6
                        : 0.25 +
                              0.75 *
                                  (0.5 +
                                      0.5 *
                                          math.cos(
                                            2 *
                                                math.pi *
                                                (_anim.value - i * 0.15),
                                          )),
                    child: Container(
                      width: 7,
                      height: 7,
                      decoration: BoxDecoration(
                        color: dso.subtle,
                        shape: BoxShape.circle,
                      ),
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}

const Map<String, String> kBriefingSources = <String, String>{
  'rule_based_sales_change':
      "Rule on today's orders: the last 30 days are below 60% of the 30 days before",
  'rule_based_visit_order_gap':
      'Rule on visits and orders: the shop is due a visit, or its last order was 18 or more days ago',
  'rule_based_salesman_sync':
      'Rule on field activity: no visit or order synced for 2 or more days',
  'rule_based_route_heartbeat':
      'Rule on route tracking: no location from the phone for more than 15 minutes',
  'rule_based_route_idle':
      'Rule on route tracking: no route activity for 90 minutes',
  'rule_based_forecast': 'Saved demand forecast: it recommends extra stock',
  'rule_based_data_quality':
      'Rule on product data: a product has no usable price',
  'special_requests': 'Special requests: no decision after 24 hours',
  'conversation_outcomes': 'Visit outcomes: a callback is due today or overdue',
  'route_workflow_state':
      'Route plans: a draft or approved route is not published',
  'coordinate_data_quality':
      'Shop locations: a location is not verified, so routes cannot trust it',
  'unscheduled_priority':
      'Shop priority: a high-priority shop is on no active route',
  'route_plan_progress': 'Route progress: the route records could not be read',
  'demand_forecasts':
      'Saved demand forecasts: the latest week has more products than this list reads',
};

String briefingSourceText(String source) =>
    kBriefingSources[source] ??
    (source.trim().isEmpty ? 'saved record' : source);

class CopilotItemList extends StatelessWidget {
  const CopilotItemList({super.key, required this.items, this.onOpenItem});

  final List<ActionCentreItem> items;

  final ValueChanged<ActionCentreItem>? onOpenItem;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      margin: const EdgeInsets.only(top: 8),
      decoration: BoxDecoration(
        color: dso.card,
        border: Border.all(color: dso.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      clipBehavior: Clip.antiAlias,
      child: Column(
        children: <Widget>[
          for (int i = 0; i < items.length; i++)
            InkWell(
              onTap: onOpenItem == null ? null : () => onOpenItem!(items[i]),
              child: Container(
                padding: const EdgeInsets.all(10),
                decoration: BoxDecoration(
                  border: i == 0
                      ? null
                      : Border(top: BorderSide(color: dso.hairline)),
                ),
                child: Row(
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    Container(
                      width: 22,
                      height: 22,
                      alignment: Alignment.center,
                      decoration: BoxDecoration(
                        color: dso.surfaceSoft,
                        shape: BoxShape.circle,
                      ),
                      child: Text(
                        '${i + 1}',
                        style: TextStyle(fontSize: 12, color: dso.body),
                      ),
                    ),
                    const SizedBox(width: 10),
                    Expanded(
                      child: Column(
                        crossAxisAlignment: CrossAxisAlignment.start,
                        children: <Widget>[
                          Text(
                            items[i].title,
                            style: TextStyle(
                              fontSize: 13,
                              fontWeight: FontWeight.w600,
                              color: dso.ink,
                            ),
                          ),
                          const SizedBox(height: 4),
                          Wrap(
                            spacing: 6,
                            runSpacing: 4,
                            crossAxisAlignment: WrapCrossAlignment.center,
                            children: <Widget>[
                              _priorityPill(dso, items[i].priority),
                              _statusPill(dso, items[i].workflowStatus),
                              Text(
                                items[i].category,
                                style: TextStyle(fontSize: 12, color: dso.body),
                              ),
                            ],
                          ),
                          const SizedBox(height: 4),
                          Text(
                            'From: ${briefingSourceText(items[i].source)}',
                            style: TextStyle(
                              fontSize: 11.5,
                              height: 1.35,
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
    );
  }

  Widget _priorityPill(DsoColors dso, String priority) {
    final (Color bg, Color fg) = switch (priority.toLowerCase()) {
      'high' => (dso.dangerSoft, dso.dangerText),
      'medium' => (dso.warningSoft, dso.warningText),
      'low' => (dso.successSoft, dso.successText),
      _ => (dso.surfaceSoft, dso.body),
    };
    return _Pill(label: priority, bg: bg, fg: fg);
  }

  Widget _statusPill(DsoColors dso, String workflowStatus) {
    final bool review = workflowStatus == 'in_review';
    return _Pill(
      label: _capital(copilotStatusLabel(workflowStatus)),
      bg: review ? dso.brandSurface : dso.surfaceSoft,
      fg: review ? dso.accentText : dso.body,
    );
  }
}

class CopilotRankWhyView extends StatelessWidget {
  const CopilotRankWhyView({super.key, required this.card});

  final RankWhyCard card;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: dso.card,
        border: Border.all(color: dso.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Details',
            style: TextStyle(
              fontSize: 11,
              fontWeight: FontWeight.w600,
              letterSpacing: 0.4,
              color: dso.muted,
            ),
          ),
          const SizedBox(height: 2),
          Text(
            card.title,
            style: TextStyle(
              fontSize: 12.5,
              fontWeight: FontWeight.w700,
              color: dso.ink,
            ),
          ),
          const SizedBox(height: 4),
          for (final String step in card.steps)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 1.5),
              child: Text(
                step,
                style: TextStyle(fontSize: 12, height: 1.35, color: dso.body),
              ),
            ),
          Padding(
            padding: const EdgeInsets.only(top: 6),
            child: Text(
              card.note,
              style: TextStyle(
                fontSize: 11.5,
                fontStyle: FontStyle.italic,
                color: dso.body,
              ),
            ),
          ),
        ],
      ),
    );
  }
}

class CopilotConfirmCard extends StatelessWidget {
  const CopilotConfirmCard({
    super.key,
    required this.pending,
    required this.busy,
    required this.onConfirm,
    required this.onCancel,
  });

  final PendingAction pending;
  final bool busy;
  final VoidCallback onConfirm;
  final VoidCallback onCancel;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        ...switch (pending) {
          PendingStatusChange(
            :final ActionCentreItem item,
            :final String status,
            :final String shownStatus,
          ) =>
            <Widget>[
              Text(
                'Set "${item.title}" to ${copilotStatusLabel(status)}?',
                style: TextStyle(
                  fontSize: 13,
                  height: 1.4,
                  fontWeight: FontWeight.w700,
                  color: dso.ink,
                ),
              ),
              const SizedBox(height: 6),
              Row(
                children: <Widget>[
                  _Pill(
                    label: _capital(copilotStatusLabel(shownStatus)),
                    bg: dso.surfaceSoft,
                    fg: dso.body,
                  ),
                  Padding(
                    padding: const EdgeInsets.symmetric(horizontal: 6),
                    child: Icon(Icons.arrow_forward, size: 14, color: dso.body),
                  ),
                  _Pill(
                    label: _capital(copilotStatusLabel(status)),
                    bg: dso.brandSurface,
                    fg: dso.accentText,
                  ),
                ],
              ),
              const SizedBox(height: 8),
              Text(
                'Changes only your own review status. It does not solve the problem.',
                style: TextStyle(fontSize: 12, color: dso.body),
              ),
            ],
          PendingOrderApproval(:final List<String> lines) => <Widget>[
            Container(
              width: double.infinity,
              margin: const EdgeInsets.only(top: 8),
              decoration: BoxDecoration(
                color: dso.card,
                border: Border.all(color: dso.hairline),
                borderRadius: BorderRadius.circular(10),
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  for (int i = 0; i < lines.length; i++)
                    Container(
                      width: double.infinity,
                      padding: const EdgeInsets.symmetric(
                        horizontal: 10,
                        vertical: 8,
                      ),
                      decoration: BoxDecoration(
                        border: i == 0
                            ? null
                            : Border(top: BorderSide(color: dso.hairline)),
                      ),
                      child: Text(
                        lines[i],
                        style: TextStyle(fontSize: 12, color: dso.body),
                      ),
                    ),
                ],
              ),
            ),
            const SizedBox(height: 8),
            Text(
              'Each order gets the same checks as the Approve button. An order '
              'above a product limit is skipped, so you can open it and decide.',
              style: TextStyle(fontSize: 12, color: dso.body),
            ),
          ],
        },
        const SizedBox(height: 10),
        Row(
          children: <Widget>[
            FilledButton(
              onPressed: busy ? null : onConfirm,
              style: FilledButton.styleFrom(
                minimumSize: const Size(0, 40),
                backgroundColor: dso.accent,
                foregroundColor: Colors.white,
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text('Confirm'),
            ),
            const SizedBox(width: 8),
            OutlinedButton(
              onPressed: busy ? null : onCancel,
              style: OutlinedButton.styleFrom(
                minimumSize: const Size(0, 40),
                foregroundColor: dso.accentText,
                side: BorderSide(color: dso.accent),
                shape: RoundedRectangleBorder(
                  borderRadius: BorderRadius.circular(18),
                ),
              ),
              child: const Text('Cancel'),
            ),
            const Spacer(),
            CopilotCountdown(expiresAt: pending.expiresAt),
          ],
        ),
      ],
    );
  }
}

class CopilotCountdown extends StatefulWidget {
  const CopilotCountdown({super.key, required this.expiresAt});

  final DateTime expiresAt;

  @override
  State<CopilotCountdown> createState() => CopilotCountdownState();
}

class CopilotCountdownState extends State<CopilotCountdown> {
  late final Timer _timer = Timer.periodic(
    const Duration(seconds: 1),
    (_) => mounted ? setState(() {}) : null,
  );

  @override
  void dispose() {
    _timer.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final int left = widget.expiresAt.difference(DateTime.now()).inSeconds;
    return Text(
      left > 0 ? 'Expires in $left s' : 'Expired',
      style: TextStyle(fontSize: 12, color: context.dso.body),
    );
  }
}

const int kCopilotMaxLength = 200;

class CopilotComposer extends StatefulWidget {
  const CopilotComposer({
    super.key,
    required this.controller,
    required this.enabled,
    required this.listening,
    required this.onCancelListening,
    required this.onMic,
    required this.onSend,
    required this.onSubmitted,
    this.focusNode,
  });

  final TextEditingController controller;

  final FocusNode? focusNode;
  final bool enabled;
  final bool listening;
  final VoidCallback onCancelListening;
  final VoidCallback onMic;
  final VoidCallback onSend;
  final ValueChanged<String> onSubmitted;

  @override
  State<CopilotComposer> createState() => _CopilotComposerState();
}

class _CopilotComposerState extends State<CopilotComposer> {
  FocusNode? _ownFocus;
  FocusNode get _focus =>
      widget.focusNode ?? (_ownFocus ??= FocusNode(debugLabel: 'composer'));

  @override
  void dispose() {
    _ownFocus?.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        ListenableBuilder(
          listenable: Listenable.merge(<Listenable>[widget.controller, _focus]),
          builder: (BuildContext context, _) {
            final int length = widget.controller.text.length;
            final bool canSend =
                widget.enabled && widget.controller.text.trim().isNotEmpty;
            final bool focused = _focus.hasFocus;
            return Container(
              margin: const EdgeInsets.symmetric(horizontal: 14),
              padding: const EdgeInsets.fromLTRB(12, 8, 6, 4),
              decoration: BoxDecoration(
                color: dso.card,
                borderRadius: BorderRadius.circular(18),
                border: Border.all(
                  color: focused || widget.listening
                      ? dso.accent
                      : copilotEdge(dso),
                ),
                boxShadow: focused
                    ? <BoxShadow>[
                        BoxShadow(
                          color: dso.accent.withValues(alpha: 0.16),
                          spreadRadius: 3,
                        ),
                      ]
                    : null,
              ),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  if (widget.listening)
                    Padding(
                      padding: const EdgeInsets.only(bottom: 4, right: 6),
                      child: Row(
                        children: <Widget>[
                          Expanded(
                            child: Semantics(
                              liveRegion: true,
                              child: Text(
                                'Listening…',
                                style: TextStyle(
                                  fontSize: 13,
                                  fontWeight: FontWeight.w600,
                                  color: dso.accentText,
                                ),
                              ),
                            ),
                          ),
                          OutlinedButton(
                            onPressed: widget.onCancelListening,
                            style: OutlinedButton.styleFrom(
                              minimumSize: const Size(0, 34),
                              padding: const EdgeInsets.symmetric(
                                horizontal: 12,
                              ),
                              foregroundColor: dso.accentText,
                              side: BorderSide(color: dso.accent),
                              shape: RoundedRectangleBorder(
                                borderRadius: BorderRadius.circular(18),
                              ),
                            ),
                            child: const Text('Cancel'),
                          ),
                        ],
                      ),
                    ),
                  Padding(
                    padding: const EdgeInsets.only(right: 6),
                    child: TextField(
                      controller: widget.controller,
                      focusNode: _focus,
                      onSubmitted: widget.onSubmitted,
                      minLines: 1,
                      maxLines: 3,
                      maxLength: kCopilotMaxLength,
                      buildCounter:
                          (
                            BuildContext context, {
                            required int currentLength,
                            required int? maxLength,
                            required bool isFocused,
                          }) => null,
                      keyboardType: TextInputType.text,
                      textInputAction: TextInputAction.none,
                      style: TextStyle(fontSize: 14, color: dso.ink),
                      decoration: InputDecoration(
                        isDense: true,
                        border: InputBorder.none,
                        enabledBorder: InputBorder.none,
                        focusedBorder: InputBorder.none,
                        disabledBorder: InputBorder.none,
                        filled: false,
                        contentPadding: const EdgeInsets.symmetric(vertical: 8),
                        hintText: 'Ask or say a command',
                        hintStyle: TextStyle(color: dso.body),
                      ),
                    ),
                  ),
                  Row(
                    children: <Widget>[
                      if (length >= 180)
                        Semantics(
                          liveRegion: true,
                          child: Text(
                            '$length / $kCopilotMaxLength',
                            style: TextStyle(
                              fontSize: 12,
                              fontWeight: length >= 190
                                  ? FontWeight.w600
                                  : FontWeight.w400,
                              color: length >= 190 ? dso.dangerText : dso.body,
                            ),
                          ),
                        ),
                      const Spacer(),
                      _CircleAction(
                        label: widget.listening ? 'Stop listening' : 'Speak',
                        icon: Icons.mic_none_rounded,
                        filled: widget.listening,
                        pulse: widget.listening,
                        onPressed: widget.enabled || widget.listening
                            ? widget.onMic
                            : null,
                      ),
                      _CircleAction(
                        label: 'Send',
                        icon: Icons.arrow_upward,
                        filled: true,
                        solid: true,
                        onPressed: canSend ? widget.onSend : null,
                      ),
                    ],
                  ),
                ],
              ),
            );
          },
        ),
        if (widget.listening)
          Padding(
            padding: const EdgeInsets.fromLTRB(14, 6, 14, 0),
            child: Text(
              'Your browser may send this audio to its speech service.',
              textAlign: TextAlign.center,
              style: TextStyle(fontSize: 12, color: dso.body),
            ),
          ),
        Padding(
          padding: const EdgeInsets.fromLTRB(14, 6, 14, 14),
          child: Text(
            'Scout can make mistakes. Double-check its answers.',
            textAlign: TextAlign.center,
            style: TextStyle(fontSize: 12, color: dso.body),
          ),
        ),
      ],
    );
  }
}

class _CircleAction extends StatefulWidget {
  const _CircleAction({
    required this.label,
    required this.icon,
    required this.filled,
    required this.onPressed,
    this.solid = false,
    this.pulse = false,
  });

  final String label;
  final IconData icon;
  final bool filled;

  final bool solid;
  final bool pulse;
  final VoidCallback? onPressed;

  @override
  State<_CircleAction> createState() => _CircleActionState();
}

class _CircleActionState extends State<_CircleAction>
    with SingleTickerProviderStateMixin {
  late final AnimationController _anim = AnimationController(
    vsync: this,
    duration: const Duration(milliseconds: 1200),
  );

  @override
  void didChangeDependencies() {
    super.didChangeDependencies();
    _syncPulse();
  }

  @override
  void didUpdateWidget(_CircleAction old) {
    super.didUpdateWidget(old);
    _syncPulse();
  }

  void _syncPulse() {
    if (widget.pulse && !_reduceMotion(context)) {
      if (!_anim.isAnimating) _anim.repeat(reverse: true);
    } else {
      _anim
        ..stop()
        ..value = 0;
    }
  }

  @override
  void dispose() {
    _anim.dispose();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final bool enabled = widget.onPressed != null;
    final Color fill = widget.filled
        ? (enabled ? dso.accent : Color.lerp(dso.card, dso.accent, 0.3)!)
        : dso.card;
    final Color iconColor = widget.filled ? Colors.white : dso.accentText;
    return Semantics(
      button: true,
      enabled: enabled,
      label: widget.label,
      excludeSemantics: true,
      onTap: widget.onPressed,
      child: Tooltip(
        message: widget.label,
        child: InkResponse(
          onTap: widget.onPressed,
          radius: 22,
          child: SizedBox(
            width: 44,
            height: 44,
            child: Center(
              child: AnimatedBuilder(
                animation: _anim,
                builder: (BuildContext context, _) => Container(
                  width: 38,
                  height: 38,
                  decoration: BoxDecoration(
                    color: fill,
                    shape: BoxShape.circle,
                    border: widget.solid
                        ? null
                        : Border.all(color: dso.accent, width: 1.5),
                    boxShadow: widget.pulse
                        ? <BoxShadow>[
                            BoxShadow(
                              color: dso.accent.withValues(alpha: 0.18),
                              spreadRadius: 7 * _anim.value,
                            ),
                          ]
                        : null,
                  ),
                  child: Icon(widget.icon, size: 18, color: iconColor),
                ),
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class CopilotDataUsed extends StatelessWidget {
  const CopilotDataUsed(this.text, {super.key});

  final String text;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Padding(
      padding: const EdgeInsets.only(top: 8),
      child: Text(
        'Data used: $text',
        style: TextStyle(fontSize: 11, height: 1.35, color: dso.muted),
      ),
    );
  }
}

class CopilotScoutView extends StatelessWidget {
  const CopilotScoutView({
    super.key,
    required this.card,
    required this.enabled,
    required this.onButton,
  });

  final ScoutCard card;
  final bool enabled;
  final ValueChanged<ScoutButton> onButton;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 9),
      decoration: BoxDecoration(
        color: dso.card,
        border: Border.all(color: dso.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          for (final ScoutSection section in card.sections) ...<Widget>[
            if (section.title != null)
              Padding(
                padding: const EdgeInsets.only(top: 4, bottom: 2),
                child: Text(
                  section.title!,
                  style: TextStyle(
                    fontSize: 12.5,
                    fontWeight: FontWeight.w700,
                    color: dso.ink,
                  ),
                ),
              ),
            for (final String line in section.lines)
              Padding(
                padding: const EdgeInsets.symmetric(vertical: 1.5),
                child: Text(
                  line,
                  style: TextStyle(fontSize: 12, height: 1.35, color: dso.body),
                ),
              ),
          ],
          for (final ScoutButton button in card.buttons)
            Padding(
              padding: const EdgeInsets.only(top: 8),
              child: FilledButton(
                onPressed: enabled ? () => onButton(button) : null,
                style: FilledButton.styleFrom(
                  minimumSize: const Size(0, 40),
                  backgroundColor: dso.accent,
                  foregroundColor: Colors.white,
                  shape: RoundedRectangleBorder(
                    borderRadius: BorderRadius.circular(8),
                  ),
                ),
                child: Text(button.label),
              ),
            ),
        ],
      ),
    );
  }
}

class CopilotChartView extends StatelessWidget {
  const CopilotChartView({super.key, required this.chart});

  final ScoutChart chart;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Container(
      width: double.infinity,
      margin: const EdgeInsets.only(top: 8),
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: dso.card,
        border: Border.all(color: dso.hairline),
        borderRadius: BorderRadius.circular(10),
      ),
      child: WeeklyBarChart(
        key: ValueKey<String>('scout-chart-${chart.title}'),
        title: chart.title,
        weeks: chart.weeks,
        barAreaHeight: 110,
      ),
    );
  }
}
