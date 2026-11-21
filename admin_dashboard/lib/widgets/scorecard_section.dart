import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../utils/insight_lifecycle.dart';

const String scorecardEmptyLine =
    'No scorecard yet. It is switched on per company.';

class ScorecardSection extends StatelessWidget {
  const ScorecardSection({
    super.key,
    required this.summaries,
    required this.readFailed,
    this.salespersonNames = const <String, String>{},
  });

  final List<Map<String, dynamic>> summaries;
  final Map<String, String> salespersonNames;
  final bool readFailed;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final List<Map<String, dynamic>> withCard = summaries
        .where((Map<String, dynamic> row) => _map(row['scorecard']) != null)
        .toList(growable: false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text('Scorecard', style: ScootType.h2.copyWith(color: c.ink)),
        const SizedBox(height: 8),
        if (readFailed)
          const ScootNotice(
            tone: ScootTone.danger,
            title: 'Scorecard could not load',
            message: 'The weekly summaries could not be read. Try Refresh.',
          )
        else if (withCard.isEmpty)
          Text(
            scorecardEmptyLine,
            style: ScootType.body.copyWith(color: c.muted),
          )
        else
          for (final Map<String, dynamic> row in withCard) ...<Widget>[
            _ScorecardBlock(
              scorecard: _map(row['scorecard'])!,
              forecastAccuracy: _map(row['forecastAccuracy']),
              scopeTitle: withCard.length > 1
                  ? _scopeTitle(row, salespersonNames)
                  : null,
            ),
            const SizedBox(height: 16),
          ],
      ],
    );
  }
}

class _ScorecardBlock extends StatelessWidget {
  const _ScorecardBlock({
    required this.scorecard,
    required this.forecastAccuracy,
    required this.scopeTitle,
  });

  final Map<String, dynamic> scorecard;
  final Map<String, dynamic>? forecastAccuracy;
  final String? scopeTitle;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final Map<String, dynamic> label = _map(scorecard['dataLabel']) ?? const {};
    final Map<String, dynamic>? reasons = _map(scorecard['noSaleReasons']);
    final List<Map<String, dynamic>> reasonRows = _list(
      reasons?['byReasonCode'],
    );
    final String basis = _text(scorecard['basis']);
    final List<Widget> tiles = <Widget>[
      _TopRankedTile(block: _map(scorecard['topRankedOrdered']) ?? const {}),
      _ForecastTile(
        block: _map(scorecard['forecastAgainstActual']) ?? const {},
        older: forecastAccuracy,
      ),
      _KeptTile(block: _map(scorecard['suggestedReordersKept']) ?? const {}),
      if (reasonRows.isNotEmpty)
        _ReasonsTile(
          rows: reasonRows,
          outcomes: _map(reasons?['sample'])?['outcomes'],
        ),
    ];
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (scopeTitle != null) ...<Widget>[
          Text(scopeTitle!, style: ScootType.bodyStrong.copyWith(color: c.ink)),
          const SizedBox(height: 8),
        ],
        Text(
          _windowLine(_map(scorecard['window']) ?? const {}),
          style: ScootType.bodyStrong.copyWith(color: c.ink),
        ),
        if (basis.isNotEmpty) ...<Widget>[
          const SizedBox(height: 4),
          Text(
            'Basis: $basis',
            style: ScootType.small.copyWith(color: c.muted),
          ),
        ],
        const SizedBox(height: 8),
        _dataLabelNotice(label),
        const SizedBox(height: 12),
        LayoutBuilder(
          builder: (BuildContext context, BoxConstraints constraints) {
            final int columns = constraints.maxWidth >= 1100 ? 2 : 1;
            final double width = columns == 1
                ? constraints.maxWidth
                : (constraints.maxWidth - 16) / columns;
            return Wrap(
              spacing: 16,
              runSpacing: 16,
              children: <Widget>[
                for (final Widget tile in tiles)
                  SizedBox(width: width, child: tile),
              ],
            );
          },
        ),
      ],
    );
  }
}

Widget _dataLabelNotice(Map<String, dynamic> label) {
  final List<String> batches = (label['simulationBatchIds'] is List)
      ? (label['simulationBatchIds'] as List)
            .map((Object? value) => _text(value))
            .where((String value) => value.isNotEmpty)
            .toList(growable: false)
      : const <String>[];
  final String kind = _text(label['kind']);
  if (kind == 'real_orders') {
    return const ScootNotice(
      tone: ScootTone.success,
      title: 'Real orders',
      message: 'These numbers come from recorded orders.',
    );
  }
  if (kind == 'simulated') {
    final String title = batches.isEmpty
        ? 'Simulated data'
        : 'Simulated data (batch ${batches.join(', ')})';
    return ScootNotice(
      tone: ScootTone.warning,
      title: title,
      message:
          '${_count(label['simulatedRecordCount'])} of ${_count(label['recordCount'])} records are simulated. These numbers are not client results.',
    );
  }
  return const ScootNotice(
    tone: ScootTone.neutral,
    title: 'Data source not recorded',
    message: 'Do not read these numbers as client results.',
  );
}

class _Tile extends StatelessWidget {
  const _Tile({
    required this.title,
    required this.lines,
    this.counted,
    this.footnote,
  });

  final String title;
  final String? counted;
  final List<String> lines;
  final String? footnote;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return ScootCard(
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(title, style: ScootType.bodyStrong.copyWith(color: c.ink)),
          if (counted != null) ...<Widget>[
            const SizedBox(height: 2),
            Text(counted!, style: ScootType.small.copyWith(color: c.muted)),
          ],
          const SizedBox(height: 8),
          for (final String line in lines)
            Padding(
              padding: const EdgeInsets.only(bottom: 4),
              child: Text(line, style: ScootType.body.copyWith(color: c.ink)),
            ),
          if (footnote != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(footnote!, style: ScootType.small.copyWith(color: c.muted)),
          ],
        ],
      ),
    );
  }
}

class _TopRankedTile extends StatelessWidget {
  const _TopRankedTile({required this.block});
  final Map<String, dynamic> block;

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> sample = _map(block['sample']) ?? const {};
    return _Tile(
      title: 'Top ${_count(block['topCount'])} ranked shops that ordered',
      counted: 'Each shop counts once for each week.',
      lines: <String>[
        'Top shops: ${_count(block['topOrderedShopWeeks'])} of ${_count(sample['topShopWeeks'])} (${_percent(block['topOrderedPercent'])})',
        'Other shops: ${_count(block['otherOrderedShopWeeks'])} of ${_count(sample['otherShopWeeks'])} (${_percent(block['otherOrderedPercent'])})',
      ],
      footnote: 'This compares. It does not prove cause.',
    );
  }
}

class _ForecastTile extends StatelessWidget {
  const _ForecastTile({required this.block, required this.older});
  final Map<String, dynamic> block;
  final Map<String, dynamic>? older;

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> sample = _map(block['sample']) ?? const {};
    final Map<String, dynamic>? stored = older;
    return _Tile(
      title: 'Forecast against actual, by product',
      counted: 'Each product counts once for each week.',
      lines: <String>[
        'Rebuilt forecasts compared: ${_count(sample['productWeeks'])}',
        'Forecast: ${_count(block['forecastUnits'])} units',
        'Actual: ${_count(block['actualUnits'])} units',
        'Error: ${_count(block['absoluteErrorUnits'])} units (${_percent(block['weightedAbsolutePercentageError'])} of actual)',
        '${_count(block['actualUnitsWithoutForecast'])} units ordered with no forecast',
        if (stored != null)
          'Forecasts saved for the latest week: average error ${_percent(stored['meanAbsolutePercentageError'])} over ${_count(stored['evaluatedForecastCount'])} forecasts',
      ],
    );
  }
}

class _KeptTile extends StatelessWidget {
  const _KeptTile({required this.block});
  final Map<String, dynamic> block;

  @override
  Widget build(BuildContext context) {
    final Map<String, dynamic> sample = _map(block['sample']) ?? const {};
    return _Tile(
      title: 'Suggested reorders that were ordered',
      lines: <String>[
        '${_count(block['keptSuggestions'])} of ${_count(sample['suggestions'])} (${_percent(block['keptPercent'])})',
      ],
    );
  }
}

class _ReasonsTile extends StatelessWidget {
  const _ReasonsTile({required this.rows, required this.outcomes});
  final List<Map<String, dynamic>> rows;
  final Object? outcomes;

  @override
  Widget build(BuildContext context) {
    final Object? total = outcomes;
    final String ofTotal = total is num && total.isFinite
        ? ' of ${_count(total)}'
        : '';
    return _Tile(
      title: 'Why shops did not order',
      counted: 'Each recorded reason counts once.',
      lines: <String>[
        for (final Map<String, dynamic> row in rows)
          '${lifecycleReasonLabel(_text(row['reasonCode']))}: ${_count(row['count'])}$ofTotal',
      ],
    );
  }
}

Map<String, dynamic>? _map(Object? value) =>
    value is Map ? Map<String, dynamic>.from(value) : null;

List<Map<String, dynamic>> _list(Object? value) => value is List
    ? value.map(_map).whereType<Map<String, dynamic>>().toList(growable: false)
    : const <Map<String, dynamic>>[];

String _text(Object? value) => value == null ? '' : value.toString().trim();

String _count(Object? value) {
  if (value is! num || !value.isFinite) return 'no data';
  return value == value.roundToDouble()
      ? value.toInt().toString()
      : value.toString();
}

String _percent(Object? value) {
  if (value is! num || !value.isFinite) return 'no data';
  return '${value.toStringAsFixed(1)}%';
}

String _scopeTitle(
  Map<String, dynamic> row,
  Map<String, String> salespersonNames,
) {
  final String type = _text(row['scopeType']);
  final String key = _text(row['scopeKey']);
  switch (type) {
    case 'salesman':
      return 'Salesperson ${salespersonNames[key] ?? key}';
    case 'branch':
      return 'Branch $key';
    default:
      return 'Whole company';
  }
}

String _windowLine(Map<String, dynamic> window) {
  final Object? scored = window['weeksScored'];
  final Object? requested = window['weeksRequested'];
  final String weeks = scored is num && requested is num && scored < requested
      ? '${_count(scored)} of ${_count(requested)} weeks'
      : '${_count(scored)} weeks';
  return '$weeks, ${_day(window['firstWeekStart'])} to ${_day(window['lastWeekStart'])}';
}

String _day(Object? value) {
  final String raw = _text(value);
  final DateTime? date = DateTime.tryParse(raw);
  if (date == null) return raw.isEmpty ? 'no data' : raw;
  const List<String> months = <String>[
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
  return '${date.day} ${months[date.month - 1]}';
}
