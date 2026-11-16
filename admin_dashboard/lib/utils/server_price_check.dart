import 'package:flutter/material.dart';

import '../theme/dso_theme.dart';
import 'money_format.dart';

enum ServerPriceCheckStatus { ok, mismatch, unverifiable }

class ServerPriceCheckLine {
  const ServerPriceCheckLine({
    required this.productId,
    required this.quantity,
    required this.submittedUnitSen,
    required this.expectedUnitSen,
  });

  final String productId;
  final int? quantity;
  final int? submittedUnitSen;
  final int? expectedUnitSen;

  bool get differs => submittedUnitSen != expectedUnitSen;
}

class ServerPriceCheckName {
  const ServerPriceCheckName({
    required this.kind,
    required this.submitted,
    required this.expected,
  });

  final String kind;
  final String submitted;
  final String expected;

  String get label => switch (kind) {
    'retailer' => 'Retailer name',
    'salesman' => 'Salesperson name',
    _ => 'Product name',
  };
}

class ServerPriceCheck {
  const ServerPriceCheck({
    required this.status,
    required this.reason,
    required this.expectedTotalSen,
    required this.submittedTotalSen,
    required this.lines,
    this.names = const <ServerPriceCheckName>[],
  });

  final ServerPriceCheckStatus status;
  final String? reason;
  final int? expectedTotalSen;
  final int? submittedTotalSen;
  final List<ServerPriceCheckLine> lines;
  final List<ServerPriceCheckName> names;

  List<ServerPriceCheckLine> get mismatchedLines =>
      lines.where((ServerPriceCheckLine line) => line.differs).toList();

  String? get reasonText {
    final String? code = reason;
    if (status == ServerPriceCheckStatus.ok) return null;
    return switch (code) {
      'price_differs' =>
        'A submitted unit price differs from the master price.',
      'name_differs' =>
        'A name on the order differs from the current record. The record '
            'may have been renamed after the order was sent.',
      'price_and_name_differ' =>
        'A submitted price and a name on the order differ from the current '
            'records.',
      'retailer_missing' => 'The retailer on the order is not in the records.',
      'total_differs_from_lines' =>
        'The order total does not match the sum of its lines.',
      'no_commercial_lines' => 'The order has no priced lines to check.',
      'commercial_lines_invalid' => 'The order lines could not be read.',
      'total_unreadable' => 'The order total could not be read.',
      'product_missing' => 'A product on the order is not in the price list.',
      'price_unreadable' => 'A master price could not be read.',
      'prices_changed_after_submission' =>
        'Prices changed after the order was submitted.',
      _ => 'The server could not verify the prices.',
    };
  }

  static ServerPriceCheck? fromOrder(Map<String, dynamic>? order) =>
      parse(order?['serverPriceCheck']);

  static ServerPriceCheck? parse(Object? raw) {
    if (raw is! Map) return null;
    final ServerPriceCheckStatus? status = switch (raw['status']) {
      'ok' => ServerPriceCheckStatus.ok,
      'mismatch' => ServerPriceCheckStatus.mismatch,
      'unverifiable' => ServerPriceCheckStatus.unverifiable,
      _ => null,
    };
    if (status == null) return null;
    final Object? rawReason = raw['reason'];
    final Object? rawLines = raw['lines'];
    final Object? rawNames = raw['names'];
    return ServerPriceCheck(
      status: status,
      reason: rawReason is String && rawReason.trim().isNotEmpty
          ? rawReason.trim()
          : null,
      expectedTotalSen: _wholeNumber(raw['expectedTotalSen']),
      submittedTotalSen: _wholeNumber(raw['submittedTotalSen']),
      lines: rawLines is List
          ? rawLines
                .whereType<Map>()
                .map(
                  (Map<dynamic, dynamic> line) => ServerPriceCheckLine(
                    productId: '${line['productId'] ?? ''}'.trim(),
                    quantity: _wholeNumber(line['quantity']),
                    submittedUnitSen: _wholeNumber(line['submittedUnitSen']),
                    expectedUnitSen: _wholeNumber(line['expectedUnitSen']),
                  ),
                )
                .toList(growable: false)
          : const <ServerPriceCheckLine>[],
      names: rawNames is List
          ? rawNames
                .whereType<Map>()
                .map(
                  (Map<dynamic, dynamic> entry) => ServerPriceCheckName(
                    kind: '${entry['kind'] ?? ''}',
                    submitted: '${entry['submitted'] ?? ''}'.trim(),
                    expected: '${entry['expected'] ?? ''}'.trim(),
                  ),
                )
                .toList(growable: false)
          : const <ServerPriceCheckName>[],
    );
  }

  static int? _wholeNumber(Object? value) {
    if (value is int) return value;
    if (value is double && value.isFinite && value == value.roundToDouble()) {
      return value.toInt();
    }
    return null;
  }
}

bool orderPriceMismatch(Map<String, dynamic>? order) =>
    ServerPriceCheck.fromOrder(order)?.status ==
    ServerPriceCheckStatus.mismatch;

String formatSenAsRm(int? sen) => sen == null ? '—' : formatRm(sen / 100);

class ServerPriceCheckBadge extends StatelessWidget {
  const ServerPriceCheckBadge({
    super.key,
    required this.check,
    this.showWhenAbsent = false,
    this.showReason = true,
  });

  final ServerPriceCheck? check;
  final bool showWhenAbsent;
  final bool showReason;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final ServerPriceCheck? current = check;
    if (current == null && !showWhenAbsent) return const SizedBox.shrink();
    final (String label, Color bg, Color fg) = switch (current?.status) {
      ServerPriceCheckStatus.ok => (
        'Price checked',
        dso.successSoft,
        dso.successText,
      ),
      ServerPriceCheckStatus.mismatch => (
        'Price mismatch',
        dso.dangerSoft,
        dso.dangerText,
      ),
      ServerPriceCheckStatus.unverifiable => (
        'Price not verifiable',
        dso.surfaceSoft,
        dso.muted,
      ),
      null => ('Not checked yet', Colors.transparent, dso.muted),
    };
    final Widget pill = Container(
      padding: const EdgeInsets.symmetric(horizontal: 8, vertical: 3),
      decoration: BoxDecoration(
        color: bg,
        borderRadius: BorderRadius.circular(999),
        border: Border.all(color: fg.withValues(alpha: 0.28)),
      ),
      child: Text(
        label,
        maxLines: 1,
        overflow: TextOverflow.ellipsis,
        style: TextStyle(color: fg, fontSize: 11, fontWeight: FontWeight.w700),
      ),
    );
    final String? hint = showReason ? current?.reasonText : null;
    return Align(
      alignment: Alignment.centerLeft,
      child: hint == null
          ? pill
          : Tooltip(
              message: hint,
              child: Semantics(container: true, hint: hint, child: pill),
            ),
    );
  }
}

class ServerPriceCheckMark extends StatelessWidget {
  const ServerPriceCheckMark({super.key, required this.check});

  final ServerPriceCheck check;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final (String label, IconData icon, Color color) = switch (check.status) {
      ServerPriceCheckStatus.ok => (
        'Price checked',
        Icons.verified_outlined,
        dso.successText,
      ),
      ServerPriceCheckStatus.mismatch => (
        'Price mismatch',
        Icons.error_outline,
        dso.dangerText,
      ),
      ServerPriceCheckStatus.unverifiable => (
        'Price not verifiable',
        Icons.help_outline,
        dso.muted,
      ),
    };
    return Tooltip(
      message: label,
      child: Semantics(
        label: label,
        excludeSemantics: true,
        child: Icon(icon, size: 18, color: color),
      ),
    );
  }
}
