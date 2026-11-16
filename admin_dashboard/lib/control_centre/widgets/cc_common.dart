import 'dart:math';

import 'package:flutter/material.dart';

import '../../theme/dso_theme.dart';
import '../staff_api_client.dart';

class Cc {
  const Cc._();

  static const Color accent = Color(0xFF3A7D5C);
  static const Color accentDark = Color(0xFF2D6A4F);
  static const Color accentSoft = Color(0xFFE6F0EA);
  static const Color sidebar = Color(0xFF10231A);
  static const Color sidebarHover = Color(0xFF1B3A2B);
  static const Color sidebarActive = Color(0xFF2B5240);
  static const Color sidebarMuted = Color(0xFF9DB5A8);
  static const Color canvas = Color(0xFFF4F6F4);
  static const Color line = Color(0xFFE2E7E3);
  static const Color ink = Color(0xFF16201A);
  static const Color body = Color(0xFF3F4A43);
  static const Color muted = Color(0xFF5F6B64);
  static const Color warnBg = Color(0xFFFFF4DC);
  static const Color warnFg = Color(0xFF7A4A00);
  static const Color dangerBg = Color(0xFFFDE8E6);
  static const Color dangerFg = Color(0xFFB42318);
  static const Color infoBg = Color(0xFFE8F0FE);
  static const Color infoFg = Color(0xFF1D4ED8);
  static const Color okFg = Color(0xFF1F6B45);
  static const Color neutralBg = Color(0xFFEDF0EE);

  static const List<FontFeature> figures = <FontFeature>[
    FontFeature.tabularFigures(),
  ];

  static const TextStyle small = TextStyle(fontSize: 13, color: muted);
  static const TextStyle label = TextStyle(
    fontSize: 12,
    fontWeight: FontWeight.w600,
    color: muted,
  );
  static const TextStyle numbers = TextStyle(
    fontSize: 14,
    color: ink,
    fontFeatures: figures,
  );

  static ThemeData theme() {
    final ThemeData base = DsoTheme.light;
    final ButtonStyle tall = ButtonStyle(
      minimumSize: const WidgetStatePropertyAll<Size>(Size(64, 44)),
      tapTargetSize: MaterialTapTargetSize.padded,
    );
    ButtonStyle withFocusRing(ButtonStyle style) {
      final WidgetStateProperty<BorderSide?>? side = style.side;
      return style
          .merge(tall)
          .copyWith(
            side: WidgetStateProperty.resolveWith(
              (Set<WidgetState> states) => states.contains(WidgetState.focused)
                  ? const BorderSide(
                      color: accentDark,
                      width: 2,
                      strokeAlign: BorderSide.strokeAlignOutside,
                    )
                  : side?.resolve(states),
            ),
          );
    }

    return base.copyWith(
      scaffoldBackgroundColor: canvas,
      filledButtonTheme: FilledButtonThemeData(
        style: withFocusRing(base.filledButtonTheme.style!),
      ),
      outlinedButtonTheme: OutlinedButtonThemeData(
        style: withFocusRing(base.outlinedButtonTheme.style!),
      ),
      textButtonTheme: TextButtonThemeData(
        style: withFocusRing(base.textButtonTheme.style!),
      ),
    );
  }
}

const int _klOffsetHours = 8;
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

DateTime? parseMoment(String? iso) =>
    iso == null ? null : DateTime.tryParse(iso)?.toUtc();

DateTime _kl(DateTime utc) => utc.add(const Duration(hours: _klOffsetHours));

String _two(int n) => n.toString().padLeft(2, '0');

String codeText(String code) => code.toUpperCase();

String dayText(String? iso) {
  final DateTime? moment = parseMoment(iso);
  if (moment == null) return '';
  final DateTime local = _kl(moment);
  return '${local.day} ${_months[local.month - 1]} ${local.year}';
}

String shortDayText(String? iso) {
  final DateTime? moment = parseMoment(iso);
  if (moment == null) return '';
  final DateTime local = _kl(moment);
  return '${local.day} ${_months[local.month - 1]}';
}

String lastDayText(String periodEnd) {
  final DateTime? moment = parseMoment(periodEnd);
  if (moment == null) return '';
  return dayText(moment.subtract(const Duration(days: 1)).toIso8601String());
}

String periodText(String start, String end) =>
    '${dayText(start)} – ${lastDayText(end)}';

String dateTimeText(String? iso) {
  final DateTime? moment = parseMoment(iso);
  if (moment == null) return '';
  final DateTime local = _kl(moment);
  return '${local.day} ${_months[local.month - 1]} ${local.year}, ${_two(local.hour)}:${_two(local.minute)} MYT';
}

String ageText(String? iso, {DateTime? now}) {
  final DateTime? moment = parseMoment(iso);
  if (moment == null) return '';
  final Duration age = (now ?? DateTime.now().toUtc()).difference(moment);
  if (age.inMinutes < 1) return 'Just now';
  if (age.inMinutes < 60) {
    return '${age.inMinutes} ${age.inMinutes == 1 ? 'minute' : 'minutes'}';
  }
  if (age.inHours < 24) {
    return '${age.inHours} ${age.inHours == 1 ? 'hour' : 'hours'}';
  }
  return '${age.inDays} ${age.inDays == 1 ? 'day' : 'days'}';
}

String klIsoDay(DateTime day) =>
    '${day.year}-${_two(day.month)}-${_two(day.day)}';

DateTime klToday() {
  final DateTime local = _kl(DateTime.now().toUtc());
  return DateTime(local.year, local.month, local.day);
}

String klMidnightUtc(DateTime day) =>
    '${DateTime.utc(day.year, day.month, day.day).subtract(const Duration(hours: _klOffsetHours)).toIso8601String().substring(0, 19)}Z';

String money(int amountMinor) {
  final String grouped = (amountMinor ~/ 100).toString().replaceAllMapped(
    RegExp(r'\B(?=(\d{3})+(?!\d))'),
    (_) => ',',
  );
  return 'RM $grouped.${_two(amountMinor % 100)}';
}

String maskEmail(String email) {
  final int at = email.indexOf('@');
  if (at < 1) return email;
  return '${email.substring(0, 1)}•••${email.substring(at)}';
}

String newKey() => List<int>.generate(
  32,
  (_) => Random.secure().nextInt(256),
).map((int byte) => byte.toRadixString(16).padLeft(2, '0')).join();

String stateLabel(String? state) => switch (state) {
  null || 'not_started' => 'Setting up',
  'lead' => 'Awaiting first payment',
  'past_due' => 'Past due',
  _ => '${state[0].toUpperCase()}${state.substring(1)}',
};

Tone stateTone(String? state) => switch (state) {
  'active' => Tone.ok,
  'past_due' || 'lead' || null || 'not_started' => Tone.warn,
  'suspended' || 'expired' || 'cancelled' => Tone.danger,
  _ => Tone.neutral,
};

String intervalLabel(String? interval) =>
    interval == 'yearly' ? 'yearly' : 'monthly';

const Map<String, String> _oneLimitLabels = <String, String>{
  'salesmen': 'salesperson',
  'supervisors': 'supervisor',
  'admins': 'admin',
  'managers': 'manager',
  'branchManagers': 'branch manager',
  'products': 'product',
};

String limitsText(Map<String, int?> limits) => <String>[
  for (final MapEntry<String, String> label in staffLimitLabels.entries)
    if (limits.containsKey(label.key))
      '${limits[label.key] ?? 'Unlimited'} ${limits[label.key] == 1 ? _oneLimitLabels[label.key] ?? label.value.toLowerCase() : label.value.toLowerCase()}',
].join(' · ');

class Loaded<T> {
  const Loaded.ok(T this.value) : error = null;
  const Loaded.failed(String this.error) : value = null;

  static Future<Loaded<T>> of<T>(Future<T> future) async {
    try {
      return Loaded<T>.ok(await future);
    } on StaffApiException catch (error) {
      return Loaded<T>.failed(error.message);
    } catch (_) {
      return Loaded<T>.failed(
        'The staff service returned an invalid response.',
      );
    }
  }

  final T? value;
  final String? error;
}

enum Tone { neutral, ok, warn, danger, info }

class CcBadge extends StatelessWidget {
  const CcBadge(this.label, {super.key, this.tone = Tone.neutral});

  final String label;
  final Tone tone;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      Tone.ok => (Cc.accentSoft, Cc.okFg),
      Tone.warn => (Cc.warnBg, Cc.warnFg),
      Tone.danger => (Cc.dangerBg, Cc.dangerFg),
      Tone.info => (Cc.infoBg, Cc.infoFg),
      Tone.neutral => (Cc.neutralBg, Cc.body),
    };
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 4),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(DsoTokens.rPill),
      ),
      child: Text(
        label,
        style: TextStyle(fontSize: 12, fontWeight: FontWeight.w600, color: fg),
      ),
    );
  }
}

class CcCard extends StatelessWidget {
  const CcCard({
    super.key,
    required this.child,
    this.title,
    this.trailing,
    this.padding = const EdgeInsets.all(20),
  });

  final Widget child;
  final String? title;
  final Widget? trailing;
  final EdgeInsetsGeometry padding;

  @override
  Widget build(BuildContext context) => Container(
    decoration: BoxDecoration(
      color: Colors.white,
      border: Border.all(color: Cc.line),
      borderRadius: BorderRadius.circular(12),
    ),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (title != null)
          Padding(
            padding: const EdgeInsets.fromLTRB(20, 16, 20, 0),
            child: Row(
              children: <Widget>[
                Expanded(
                  child: Semantics(
                    header: true,
                    child: Text(
                      title!,
                      style: const TextStyle(
                        fontSize: 16,
                        fontWeight: FontWeight.w700,
                        color: Cc.ink,
                      ),
                    ),
                  ),
                ),
                if (trailing != null) trailing!,
              ],
            ),
          ),
        Padding(padding: padding, child: child),
      ],
    ),
  );
}

class CcPageHeader extends StatelessWidget {
  const CcPageHeader(this.title, {super.key, this.actions = const <Widget>[]});

  final String title;
  final List<Widget> actions;

  @override
  Widget build(BuildContext context) => Padding(
    padding: const EdgeInsets.only(bottom: 18),
    child: Wrap(
      alignment: WrapAlignment.spaceBetween,
      crossAxisAlignment: WrapCrossAlignment.center,
      spacing: 12,
      runSpacing: 10,
      children: <Widget>[
        Semantics(
          header: true,
          child: Text(
            title,
            style: const TextStyle(
              fontSize: 26,
              fontWeight: FontWeight.w700,
              color: Cc.ink,
              height: 1.2,
            ),
          ),
        ),
        if (actions.isNotEmpty)
          Wrap(spacing: 8, runSpacing: 8, children: actions),
      ],
    ),
  );
}

class CcTabBar extends StatelessWidget {
  const CcTabBar({
    super.key,
    required this.labels,
    required this.selected,
    required this.onSelected,
    this.counts = const <int?>[],
  });

  final List<String> labels;
  final List<int?> counts;
  final int selected;
  final ValueChanged<int> onSelected;

  @override
  Widget build(BuildContext context) => Container(
    decoration: const BoxDecoration(
      border: Border(bottom: BorderSide(color: Cc.line)),
    ),
    margin: const EdgeInsets.only(bottom: 16),
    child: Wrap(
      spacing: 4,
      children: <Widget>[
        for (int i = 0; i < labels.length; i++)
          Semantics(
            button: true,
            selected: i == selected,
            label: counts.length > i && counts[i] != null
                ? '${labels[i]} ${counts[i]}'
                : labels[i],
            excludeSemantics: true,
            onTap: () => onSelected(i),
            child: InkWell(
              onTap: () => onSelected(i),
              child: Container(
                constraints: const BoxConstraints(minHeight: 44),
                padding: const EdgeInsets.symmetric(horizontal: 12),
                decoration: BoxDecoration(
                  border: Border(
                    bottom: BorderSide(
                      color: i == selected ? Cc.accent : Colors.transparent,
                      width: 3,
                    ),
                  ),
                ),
                child: Center(
                  widthFactor: 1,
                  child: Text.rich(
                    TextSpan(
                      children: <InlineSpan>[
                        TextSpan(
                          text: labels[i],
                          style: TextStyle(
                            fontWeight: i == selected
                                ? FontWeight.w700
                                : FontWeight.w500,
                            color: i == selected ? Cc.ink : Cc.muted,
                          ),
                        ),
                        if (counts.length > i && counts[i] != null)
                          TextSpan(
                            text: '  ${counts[i]}',
                            style: const TextStyle(
                              color: Cc.muted,
                              fontFeatures: Cc.figures,
                            ),
                          ),
                      ],
                    ),
                    style: const TextStyle(fontSize: 14),
                  ),
                ),
              ),
            ),
          ),
      ],
    ),
  );
}

class CcColumn {
  const CcColumn(
    this.label, {
    this.width,
    this.flex = 1,
    this.right = false,
    this.hideBelow = 0,
  });

  final String label;
  final double? width;
  final int flex;
  final bool right;
  final double hideBelow;
}

class CcTableRow {
  const CcTableRow({
    required this.cells,
    this.onTap,
    this.semanticLabel,
    this.selected = false,
  });

  final List<Widget> cells;
  final VoidCallback? onTap;
  final String? semanticLabel;
  final bool selected;
}

class CcTable extends StatelessWidget {
  const CcTable({
    super.key,
    required this.columns,
    required this.rows,
    this.footer,
    this.empty,
  });

  final List<CcColumn> columns;
  final List<CcTableRow> rows;
  final Widget? footer;
  final Widget? empty;

  static const double _stackBelow = 640;
  static const Set<String> _actionLabels = <String>{'Action', 'Actions'};

  Widget _stackedRow(List<Widget> cells) => Column(
    crossAxisAlignment: CrossAxisAlignment.stretch,
    children: <Widget>[
      for (int i = 0; i < columns.length; i++)
        Padding(
          padding: EdgeInsets.only(top: i == 0 ? 0 : 8),
          child: Column(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              if (i > 0 &&
                  columns[i].label.isNotEmpty &&
                  !_actionLabels.contains(columns[i].label))
                Text(columns[i].label, style: Cc.label),
              Align(alignment: Alignment.centerLeft, child: cells[i]),
            ],
          ),
        ),
    ],
  );

  Widget _cell(CcColumn column, Widget child) {
    final Widget aligned = Align(
      alignment: column.right ? Alignment.centerRight : Alignment.centerLeft,
      child: child,
    );
    return column.width != null
        ? SizedBox(width: column.width, child: aligned)
        : Expanded(flex: column.flex, child: aligned);
  }

  @override
  Widget build(BuildContext context) => LayoutBuilder(
    builder: (BuildContext context, BoxConstraints constraints) {
      final bool stacked = constraints.maxWidth < _stackBelow;
      final List<int> shown = <int>[
        for (int i = 0; i < columns.length; i++)
          if (constraints.maxWidth >= columns[i].hideBelow) i,
      ];
      final List<int> hidden = <int>[
        for (int i = 0; i < columns.length; i++)
          if (!shown.contains(i)) i,
      ];
      Widget line(List<Widget> cells, {bool withHidden = false}) => stacked
          ? _stackedRow(cells)
          : Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                Row(
                  crossAxisAlignment: CrossAxisAlignment.center,
                  children: <Widget>[
                    for (int k = 0; k < shown.length; k++) ...<Widget>[
                      if (k > 0) const SizedBox(width: 12),
                      _cell(columns[shown[k]], cells[shown[k]]),
                    ],
                  ],
                ),
                if (withHidden && hidden.isNotEmpty)
                  Padding(
                    padding: const EdgeInsets.only(top: 8),
                    child: Wrap(
                      spacing: 24,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final int i in hidden)
                          ConstrainedBox(
                            constraints: BoxConstraints(
                              maxWidth: constraints.maxWidth - 32,
                            ),
                            child: Column(
                              crossAxisAlignment: CrossAxisAlignment.start,
                              children: <Widget>[
                                Text(columns[i].label, style: Cc.label),
                                cells[i],
                              ],
                            ),
                          ),
                      ],
                    ),
                  ),
              ],
            );
      return Container(
        decoration: BoxDecoration(
          color: Colors.white,
          border: Border.all(color: Cc.line),
          borderRadius: BorderRadius.circular(12),
        ),
        clipBehavior: Clip.antiAlias,
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            if (!stacked) ...<Widget>[
              Container(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                color: const Color(0xFFF8FAF8),
                child: line(<Widget>[
                  for (final CcColumn column in columns)
                    Text(column.label, style: Cc.label),
                ]),
              ),
              const Divider(height: 1, color: Cc.line),
            ],
            if (rows.isEmpty && empty != null)
              Padding(padding: const EdgeInsets.all(24), child: empty!),
            for (int i = 0; i < rows.length; i++) ...<Widget>[
              if (i > 0) const Divider(height: 1, color: Cc.line),
              if (rows[i].onTap == null)
                ColoredBox(
                  color: rows[i].selected ? Cc.accentSoft : Colors.white,
                  child: Container(
                    constraints: const BoxConstraints(minHeight: 56),
                    padding: const EdgeInsets.symmetric(
                      horizontal: 16,
                      vertical: 10,
                    ),
                    child: line(rows[i].cells, withHidden: true),
                  ),
                )
              else
                Semantics(
                  button: true,
                  label: rows[i].semanticLabel,
                  container: true,
                  excludeSemantics: true,
                  onTap: rows[i].onTap,
                  child: Material(
                    color: rows[i].selected ? Cc.accentSoft : Colors.white,
                    child: InkWell(
                      onTap: rows[i].onTap,
                      child: Container(
                        constraints: const BoxConstraints(minHeight: 56),
                        padding: const EdgeInsets.symmetric(
                          horizontal: 16,
                          vertical: 10,
                        ),
                        child: line(rows[i].cells, withHidden: true),
                      ),
                    ),
                  ),
                ),
            ],
            if (footer != null) ...<Widget>[
              const Divider(height: 1, color: Cc.line),
              Padding(
                padding: const EdgeInsets.symmetric(
                  horizontal: 16,
                  vertical: 12,
                ),
                child: footer,
              ),
            ],
          ],
        ),
      );
    },
  );
}

class CcSkeleton extends StatelessWidget {
  const CcSkeleton({super.key, this.rows = 5});

  final int rows;

  @override
  Widget build(BuildContext context) => Semantics(
    label: 'Loading',
    liveRegion: true,
    child: Container(
      padding: const EdgeInsets.all(16),
      decoration: BoxDecoration(
        color: Colors.white,
        border: Border.all(color: Cc.line),
        borderRadius: BorderRadius.circular(12),
      ),
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows; i++)
            Padding(
              padding: const EdgeInsets.symmetric(vertical: 10),
              child: Container(
                height: 16,
                decoration: BoxDecoration(
                  color: Cc.neutralBg,
                  borderRadius: BorderRadius.circular(6),
                ),
              ),
            ),
        ],
      ),
    ),
  );
}

class CcErrorState extends StatelessWidget {
  const CcErrorState({
    super.key,
    required this.message,
    required this.onRetry,
    this.what = 'this page',
  });

  final String message;
  final String what;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) => CcCard(
    child: Semantics(
      liveRegion: true,
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            'Could not load $what.',
            style: const TextStyle(
              fontWeight: FontWeight.w700,
              color: Cc.dangerFg,
            ),
          ),
          const SizedBox(height: 6),
          SelectableText(message, style: const TextStyle(color: Cc.body)),
          const SizedBox(height: 12),
          FilledButton(onPressed: onRetry, child: const Text('Try again')),
        ],
      ),
    ),
  );
}

class CcEmptyState extends StatelessWidget {
  const CcEmptyState({
    super.key,
    required this.title,
    required this.message,
    this.action,
  });

  final String title, message;
  final Widget? action;

  @override
  Widget build(BuildContext context) => Center(
    child: Padding(
      padding: const EdgeInsets.symmetric(vertical: 20),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(
            title,
            textAlign: TextAlign.center,
            style: const TextStyle(
              fontSize: 17,
              fontWeight: FontWeight.w700,
              color: Cc.ink,
            ),
          ),
          const SizedBox(height: 6),
          Text(
            message,
            textAlign: TextAlign.center,
            style: const TextStyle(color: Cc.muted),
          ),
          if (action != null) ...<Widget>[const SizedBox(height: 12), action!],
        ],
      ),
    ),
  );
}

class CcBanner extends StatelessWidget {
  const CcBanner({
    super.key,
    required this.text,
    this.tone = Tone.warn,
    this.action,
    this.bold,
  });

  final String text;
  final String? bold;
  final Tone tone;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final (Color bg, Color fg) = switch (tone) {
      Tone.danger => (Cc.dangerBg, Cc.dangerFg),
      Tone.info => (Cc.infoBg, Cc.infoFg),
      Tone.ok => (Cc.accentSoft, Cc.okFg),
      _ => (Cc.warnBg, Cc.warnFg),
    };
    return Semantics(
      container: true,
      liveRegion: true,
      child: Container(
        margin: const EdgeInsets.only(bottom: 14),
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        decoration: BoxDecoration(
          color: bg,
          borderRadius: BorderRadius.circular(10),
        ),
        child: Wrap(
          crossAxisAlignment: WrapCrossAlignment.center,
          alignment: WrapAlignment.spaceBetween,
          spacing: 12,
          runSpacing: 8,
          children: <Widget>[
            ConstrainedBox(
              constraints: const BoxConstraints(maxWidth: 760),
              child: Text.rich(
                TextSpan(
                  children: <InlineSpan>[
                    if (bold != null)
                      TextSpan(
                        text: '$bold ',
                        style: const TextStyle(fontWeight: FontWeight.w700),
                      ),
                    TextSpan(text: text),
                  ],
                ),
                style: TextStyle(color: fg, fontSize: 14),
              ),
            ),
            ?action,
          ],
        ),
      ),
    );
  }
}

class CcKeyValue extends StatelessWidget {
  const CcKeyValue(this.rows, {super.key, this.labelWidth = 150});

  final List<(String, Widget)> rows;
  final double labelWidth;

  @override
  Widget build(BuildContext context) => Column(
    children: <Widget>[
      for (final (String label, Widget value) in rows)
        Padding(
          padding: const EdgeInsets.symmetric(vertical: 7),
          child: Row(
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              SizedBox(
                width: labelWidth,
                child: Text(label, style: Cc.small),
              ),
              Expanded(
                child: DefaultTextStyle.merge(
                  style: const TextStyle(color: Cc.ink, fontSize: 14),
                  child: value,
                ),
              ),
            ],
          ),
        ),
    ],
  );
}

class CcFilterChip extends StatelessWidget {
  const CcFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
  });

  final String label;
  final int? count;
  final bool selected;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    selected: selected,
    label: count == null ? label : '$label $count',
    excludeSemantics: true,
    onTap: onTap,
    child: Material(
      color: selected ? Cc.ink : Colors.white,
      shape: StadiumBorder(
        side: BorderSide(color: selected ? Cc.ink : Cc.line),
      ),
      child: InkWell(
        customBorder: const StadiumBorder(),
        onTap: onTap,
        child: Container(
          constraints: const BoxConstraints(minHeight: 44),
          padding: const EdgeInsets.symmetric(horizontal: 16),
          child: Center(
            widthFactor: 1,
            child: Text.rich(
              TextSpan(
                children: <InlineSpan>[
                  TextSpan(text: label),
                  if (count != null)
                    TextSpan(
                      text: '  $count',
                      style: const TextStyle(fontFeatures: Cc.figures),
                    ),
                ],
              ),
              style: TextStyle(
                fontSize: 14,
                fontWeight: FontWeight.w600,
                color: selected ? Colors.white : Cc.body,
              ),
            ),
          ),
        ),
      ),
    ),
  );
}

class CcLink extends StatelessWidget {
  const CcLink(this.label, {super.key, required this.onTap, this.semantic});

  final String label;
  final String? semantic;
  final VoidCallback onTap;

  @override
  Widget build(BuildContext context) => Semantics(
    button: true,
    label: semantic ?? label,
    excludeSemantics: true,
    onTap: onTap,
    child: InkWell(
      onTap: onTap,
      child: ConstrainedBox(
        constraints: const BoxConstraints(minHeight: 44),
        child: Align(
          alignment: Alignment.centerLeft,
          widthFactor: 1,
          child: Text(
            label,
            overflow: TextOverflow.ellipsis,
            style: const TextStyle(
              fontWeight: FontWeight.w600,
              color: Cc.ink,
              decoration: TextDecoration.underline,
            ),
          ),
        ),
      ),
    ),
  );
}

void announce(BuildContext context, String message) =>
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Semantics(liveRegion: true, child: Text(message))),
    );

String roleLabel(String role) => switch (role) {
  'owner' => 'Owner',
  'operator' => 'Operator',
  'engineer' => 'Engineer',
  'support' => 'Support',
  _ => role,
};
