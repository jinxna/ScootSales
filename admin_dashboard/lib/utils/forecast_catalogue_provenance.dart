const String kForecastProvenanceVersion = 'catalogue-provenance/1.0.0';

const List<String> _catalogueIdFields = <String>[
  'docId',
  'productId',
  'product_id',
  'itemId',
  'item_id',
  'itemCode',
  'item_code',
  'productCode',
  'product_code',
  'sku',
  'barcode',
  'itemBarcode',
  'item_barcode',
];

const List<String> _catalogueNameFields = <String>[
  'productName',
  'product_name',
  'itemName',
  'item_name',
  'name',
];

const List<String> _forecastIdFields = <String>[
  'productId',
  'product_id',
  'itemCode',
  'barcode',
];

const List<String> _forecastNameFields = <String>[
  'productName',
  'product_name',
];

String normaliseCatalogueKey(Object? value) {
  final String raw = value == null ? '' : value.toString();
  final StringBuffer buffer = StringBuffer();
  for (final int unit in raw.toLowerCase().codeUnits) {
    final bool keep =
        (unit >= 0x61 && unit <= 0x7a) || (unit >= 0x30 && unit <= 0x39);
    if (keep) buffer.writeCharCode(unit);
  }
  return buffer.toString();
}

String _normaliseName(Object? value) {
  final String raw = value == null ? '' : value.toString();
  return raw.toLowerCase().replaceAll(RegExp(r'[^a-z0-9]+'), ' ').trim();
}

class ForecastCatalogueSelection {
  const ForecastCatalogueSelection({
    required this.rows,
    required this.excludedCount,
    required this.verificationAvailable,
    this.excludedSamples = const <String>[],
  });

  final List<Map<String, dynamic>> rows;

  final int excludedCount;

  final bool verificationAvailable;

  final List<String> excludedSamples;

  bool get hasExclusions => excludedCount > 0;
}

class ForecastOperationalSummary {
  const ForecastOperationalSummary({
    required this.productCount,
    required this.rowCount,
    required this.modelCount,
    required this.intervalCount,
    required this.insufficientHistoryCount,
    required this.forecastCount,
  });

  final int productCount;
  final int rowCount;
  final int modelCount;
  final int intervalCount;
  final int insufficientHistoryCount;
  final int forecastCount;

  factory ForecastOperationalSummary.fromRows(
    Iterable<Map<String, dynamic>> rows,
  ) {
    final List<Map<String, dynamic>> values = rows.toList(growable: false);
    final int forecastCount = values.where(forecastRowCountsAsForecast).length;
    return ForecastOperationalSummary(
      productCount: values
          .map((Map<String, dynamic> row) => _text(row['productId']))
          .where((String value) => value.isNotEmpty)
          .toSet()
          .length,
      rowCount: values.length,
      modelCount: values
          .where(forecastRowCountsAsForecast)
          .map(
            (Map<String, dynamic> row) =>
                _text(row['model'] ?? row['modelUsed'] ?? row['model_used']),
          )
          .where((String value) => value.isNotEmpty)
          .toSet()
          .length,
      intervalCount: values
          .where(
            (Map<String, dynamic> row) =>
                forecastRowCountsAsForecast(row) &&
                _firstPresent(row, const <String>[
                      'lower',
                      'lowerQuantity',
                      'lower_quantity',
                    ]) !=
                    null,
          )
          .length,
      insufficientHistoryCount: values.length - forecastCount,
      forecastCount: forecastCount,
    );
  }
}

bool forecastRowCountsAsForecast(Map<String, dynamic> row) {
  final String status = _text(row['status']).toLowerCase();
  if (status == 'ok') return true;
  if (status.isNotEmpty) return false;
  return (_number(
            _firstPresent(row, const <String>[
              'predictedQuantity',
              'predicted_quantity',
              'forecastQuantity',
              'forecast_quantity',
            ]),
          ) ??
          0) >
      0;
}

bool forecastRowHasUsablePoint(Map<String, dynamic> row) {
  if (!forecastRowCountsAsForecast(row)) return false;
  final double? point = _forecastPoint(row);
  return point != null && point >= 0;
}

bool forecastRowHasPositivePoint(Map<String, dynamic> row) {
  if (!forecastRowCountsAsForecast(row)) return false;
  return (_forecastPoint(row) ?? 0) > 0;
}

class ForecastRestockSignal {
  const ForecastRestockSignal({
    required this.forecastQuantity,
    required this.referenceQuantity,
    required this.changePercent,
    required this.action,
    required this.hasForecast,
  });

  final double forecastQuantity;
  final double referenceQuantity;
  final double changePercent;
  final String action;
  final bool hasForecast;

  bool get hasAction =>
      action.isNotEmpty && action.toLowerCase() != 'maintain stock';

  bool get shouldShow =>
      hasForecast &&
      (hasAction ||
          changePercent >= 10 ||
          forecastQuantity > referenceQuantity ||
          (referenceQuantity <= 0 && forecastQuantity > 0));
}

ForecastRestockSignal forecastRestockSignal(Map<String, dynamic> row) {
  final double forecast = _numberOrZero(
    row['predictedQuantity'] ??
        row['predicted_quantity'] ??
        row['forecastQuantity'] ??
        row['forecast_quantity'] ??
        row['point'] ??
        row['quantity'],
  );
  final double reference = _numberOrZero(
    row['historicalAverage'] ??
        row['historical_average'] ??
        row['monthlyAverage'] ??
        row['monthly_average'] ??
        row['averageQuantity'] ??
        row['average_quantity'] ??
        row['baselineQuantity'] ??
        row['baseline_quantity'] ??
        row['referenceUnits'] ??
        row['reference_units'],
  );
  double change = _numberOrZero(
    row['changePercentage'] ??
        row['change_percentage'] ??
        row['changePercent'] ??
        row['change_percent'] ??
        row['demandChangePercent'],
  );
  if (change == 0 && forecast > 0 && reference > 0) {
    change = ((forecast - reference) / reference) * 100;
  }
  final String action = _text(
    row['recommendedAction'] ?? row['recommended_action'],
  );
  return ForecastRestockSignal(
    forecastQuantity: forecast,
    referenceQuantity: reference,
    changePercent: change,
    action: action.toLowerCase() == 'null' ? '' : action,
    hasForecast: forecastRowHasPositivePoint(row),
  );
}

double _numberOrZero(Object? value) {
  if (value == null) return 0;
  if (value is num) return value.toDouble();
  return double.tryParse(value.toString().replaceAll(',', '').trim()) ?? 0;
}

double? _forecastPoint(Map<String, dynamic> row) => _number(
  _firstPresent(row, const <String>[
    'point',
    'predictedQuantity',
    'predicted_quantity',
    'forecastQuantity',
    'forecast_quantity',
  ]),
);

Object? _firstPresent(Map<String, dynamic> row, List<String> fields) {
  for (final String field in fields) {
    if (row[field] != null) return row[field];
  }
  return null;
}

double? _number(Object? value) {
  final double? number = value is num
      ? value.toDouble()
      : double.tryParse(value?.toString().replaceAll(',', '').trim() ?? '');
  return number != null && number.isFinite ? number : null;
}

ForecastCatalogueSelection selectCatalogueForecasts({
  required List<Map<String, dynamic>> forecasts,
  required List<Map<String, dynamic>>? catalogue,
}) {
  if (catalogue == null || catalogue.isEmpty) {
    return ForecastCatalogueSelection(
      rows: forecasts,
      excludedCount: 0,
      verificationAvailable: false,
    );
  }

  final Set<String> idKeys = <String>{};
  final Set<String> nameKeys = <String>{};
  for (final Map<String, dynamic> product in catalogue) {
    for (final String field in _catalogueIdFields) {
      final String key = normaliseCatalogueKey(product[field]);
      if (key.isNotEmpty) idKeys.add(key);
    }
    for (final String field in _catalogueNameFields) {
      final String key = _normaliseName(product[field]);
      if (key.isNotEmpty) nameKeys.add(key);
    }
  }

  final List<Map<String, dynamic>> kept = <Map<String, dynamic>>[];
  final List<String> samples = <String>[];
  int excluded = 0;
  for (final Map<String, dynamic> row in forecasts) {
    bool matched = false;
    for (final String field in _forecastIdFields) {
      final String key = normaliseCatalogueKey(row[field]);
      if (key.isNotEmpty && idKeys.contains(key)) {
        matched = true;
        break;
      }
    }
    if (!matched) {
      for (final String field in _forecastNameFields) {
        final String key = _normaliseName(row[field]);
        if (key.isNotEmpty && nameKeys.contains(key)) {
          matched = true;
          break;
        }
      }
    }
    if (matched) {
      kept.add(row);
    } else {
      excluded += 1;
      if (samples.length < 3) {
        final String label = _forecastNameFields
            .map((String field) => row[field]?.toString().trim() ?? '')
            .firstWhere((String value) => value.isNotEmpty, orElse: () => '');
        if (label.isNotEmpty) samples.add(label);
      }
    }
  }

  return ForecastCatalogueSelection(
    rows: kept,
    excludedCount: excluded,
    verificationAvailable: true,
    excludedSamples: samples,
  );
}

String _latestForecastPeriod(List<Map<String, dynamic>> rows) {
  String latest = '';
  for (final Map<String, dynamic> row in rows) {
    final String period = _text(row['periodStart']);
    if (period.compareTo(latest) > 0) latest = period;
  }
  return latest;
}

List<Map<String, dynamic>> selectLatestForecastPeriod(
  List<Map<String, dynamic>> rows,
) {
  final String latest = _latestForecastPeriod(rows);
  if (latest.isEmpty) return rows;
  return rows
      .where((Map<String, dynamic> row) => _text(row['periodStart']) == latest)
      .toList(growable: false);
}

bool forecastWindowCoversLatestPeriod(
  List<Map<String, dynamic>> window,
  List<Map<String, dynamic>> counted, {
  required int limit,
}) {
  if (window.length < limit) return true;
  final String latest = _latestForecastPeriod(counted);
  return window.any(
    (Map<String, dynamic> row) =>
        _text(row['periodStart']).compareTo(latest) < 0,
  );
}

int forecastRestockSignalCount(List<Map<String, dynamic>> rows) =>
    selectLatestForecastPeriod(rows)
        .where(
          (Map<String, dynamic> row) => forecastRestockSignal(row).shouldShow,
        )
        .length;

String forecastFreshnessLabel(List<Map<String, dynamic>> rows) {
  DateTime? newest;
  for (final Map<String, dynamic> row in rows) {
    final DateTime? parsed = DateTime.tryParse(
      row['generatedAt']?.toString().trim() ?? '',
    );
    if (parsed == null) continue;
    if (newest == null || parsed.isAfter(newest)) newest = parsed;
  }
  if (newest == null) return 'Forecast generation time not recorded.';
  return 'Forecast made ${readableForecastTime(newest)}.';
}

const List<String> _monthNames = <String>[
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

String readableForecastDate(DateTime day) =>
    '${day.day} ${_monthNames[day.month - 1]} ${day.year}';

String readableForecastTime(DateTime instant) {
  final DateTime kl = instant.toUtc().add(const Duration(hours: 8));
  String two(int value) => value.toString().padLeft(2, '0');
  return '${readableForecastDate(kl)}, ${two(kl.hour)}:${two(kl.minute)}';
}

String readableForecastTimeText(String raw) {
  final DateTime? parsed = DateTime.tryParse(raw.trim());
  return parsed == null ? raw : readableForecastTime(parsed);
}

String forecastUnitsLabel(Object? value) {
  final num? parsed = value is num ? value : num.tryParse('${value ?? ''}'.trim());
  if (parsed == null || !parsed.isFinite) return '${value ?? ''}';
  return parsed == parsed.roundToDouble()
      ? parsed.round().toString()
      : parsed.toStringAsFixed(1);
}

String _text(Object? value) => value?.toString().trim() ?? '';
