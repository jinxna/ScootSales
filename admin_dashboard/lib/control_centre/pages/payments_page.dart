import 'package:flutter/material.dart';

import '../../services/csv_downloader.dart';
import '../../utils/csv_export.dart';
import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';
import '../widgets/payment_actions.dart';

class _PaymentRow {
  const _PaymentRow(this.entry, this.voided);

  final StaffPaymentEntry entry;
  final StaffPaymentEntry? voided;
}

class PaymentsPage extends StatefulWidget {
  const PaymentsPage({super.key, required this.store, required this.nav});

  final CcStore store;
  final CcNav nav;

  @override
  State<PaymentsPage> createState() => _PaymentsPageState();
}

class _PaymentsPageState extends State<PaymentsPage> {
  int _tab = 0;
  int _range = 0;
  int _by = 0;
  Loaded<List<_PaymentRow>>? _all;
  int _failedCompanies = 0;
  bool _loadingAll = false;

  static const int _maxInFlight = 8;

  CcStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _store.refreshToCheck(force: false);
    if (_store.companies == null) _store.refreshCompanies();
  }

  Future<void> _loadAll() async {
    if (_loadingAll) return;
    _loadingAll = true;
    setState(() => _all = null);
    try {
      await _readAll();
    } finally {
      _loadingAll = false;
    }
  }

  Future<void> _readAll() async {
    final List<StaffCompany> companies =
        _store.companies?.value ?? const <StaffCompany>[];
    final List<_PaymentRow> rows = <_PaymentRow>[];
    String? error;
    int failed = 0;
    bool sessionLost = false;

    Future<void> read(StaffCompany company) async {
      try {
        final StaffPayments ledger = await _store.api.payments(
          company.tenantId,
        );
        final Map<String, StaffPaymentEntry> voids =
            <String, StaffPaymentEntry>{
              for (final StaffPaymentEntry e in ledger.entries)
                if (e.type == 'void' && e.receiptId != null) e.receiptId!: e,
            };
        for (final StaffPaymentEntry entry in ledger.entries) {
          if (entry.isPayment) {
            rows.add(_PaymentRow(entry, voids[entry.entryId]));
          }
        }
      } on StaffApiException catch (e) {
        failed++;
        error = e.message;
        if (e.statusCode == 401) sessionLost = true;
      } catch (_) {
        failed++;
        error = 'The staff service returned an invalid response.';
      }
    }

    int next = 0;
    Future<void> worker() async {
      while (mounted && !sessionLost && next < companies.length) {
        await read(companies[next++]);
      }
    }

    if (companies.isNotEmpty) {
      next = 1;
      await read(companies.first);
      await Future.wait<void>(<Future<void>>[
        for (int i = 0; i < _maxInFlight; i++) worker(),
      ]);
    }
    if (!mounted) return;
    rows.sort(
      (_PaymentRow a, _PaymentRow b) =>
          b.entry.createdAt.compareTo(a.entry.createdAt),
    );
    setState(() {
      _failedCompanies = failed;
      _all = sessionLost
          ? const Loaded<List<_PaymentRow>>.failed(
              'Your session ended. Sign in again.',
            )
          : failed > 0 && failed == companies.length
          ? Loaded<List<_PaymentRow>>.failed(error!)
          : Loaded<List<_PaymentRow>>.ok(rows);
    });
  }

  bool _inRange(StaffPaymentEntry entry) {
    if (_range == 2) return true;
    final DateTime? received = parseMoment(entry.receivedAt);
    if (received == null) return true;
    final DateTime now = DateTime.now().toUtc();
    return _range == 0
        ? now.difference(received).inDays <= 30
        : received.year == now.year && received.month == now.month;
  }

  bool _byMatches(StaffPaymentEntry entry) => switch (_by) {
    1 => entry.createdBy == _store.me,
    2 => entry.createdBy != _store.me,
    _ => true,
  };

  Future<void> _refresh() async {
    await _store.refreshMoney();
    if (_tab != 0) await _loadAll();
  }

  void _export(List<StaffPaymentEntry> rows) => downloadCsv(
    filename: 'payments.csv',
    csv: buildCsv(
      <String>[
        'Company',
        'Invoice',
        'Bank reference',
        'Amount (RM)',
        'Bank date',
        'Recorded by',
        'Checked by',
      ],
      <List<Object?>>[
        for (final StaffPaymentEntry e in rows)
          <Object?>[
            e.companyName ?? _store.companyName(e.tenantId),
            e.invoiceReference ?? '',
            e.externalReference ?? '',
            ((e.amountMinor ?? 0) / 100).toStringAsFixed(2),
            dayText(e.receivedAt),
            e.createdBy,
            e.check?.checkedBy ?? '',
          ],
      ],
    ),
  );

  Widget _filters() => Wrap(
    spacing: 16,
    runSpacing: 10,
    crossAxisAlignment: WrapCrossAlignment.center,
    children: <Widget>[
      const Text('Received', style: Cc.small),
      SizedBox(
        width: 190,
        child: DropdownButtonFormField<int>(
          initialValue: _range,
          decoration: const InputDecoration(isDense: true),
          items: const <DropdownMenuItem<int>>[
            DropdownMenuItem<int>(value: 0, child: Text('Last 30 days')),
            DropdownMenuItem<int>(value: 1, child: Text('This month')),
            DropdownMenuItem<int>(value: 2, child: Text('All time')),
          ],
          onChanged: (int? v) => setState(() => _range = v ?? 0),
        ),
      ),
      const Text('Recorded by', style: Cc.small),
      SizedBox(
        width: 150,
        child: DropdownButtonFormField<int>(
          initialValue: _by,
          decoration: const InputDecoration(isDense: true),
          items: const <DropdownMenuItem<int>>[
            DropdownMenuItem<int>(value: 0, child: Text('Anyone')),
            DropdownMenuItem<int>(value: 1, child: Text('Me')),
            DropdownMenuItem<int>(value: 2, child: Text('Others')),
          ],
          onChanged: (int? v) => setState(() => _by = v ?? 0),
        ),
      ),
    ],
  );

  List<CcColumn> _columns(bool withActions) => <CcColumn>[
    const CcColumn('Company and invoice', flex: 4),
    const CcColumn('Amount and period', flex: 3, width: 190),
    const CcColumn('Recorded', flex: 3, width: 230, hideBelow: 980),
    if (withActions) const CcColumn('Actions', width: 250, right: true),
  ];

  Widget _company(StaffPaymentEntry entry) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      CcLink(
        entry.companyName ?? _store.companyName(entry.tenantId),
        onTap: () =>
            widget.nav.openCompany(entry.tenantId, tab: CompanyTab.payments),
      ),
      Text(
        '${entry.invoiceReference ?? ''} · bank ref ${entry.externalReference ?? ''}',
        style: Cc.small,
        overflow: TextOverflow.ellipsis,
      ),
    ],
  );

  Widget _amount(StaffPaymentEntry entry) => Column(
    crossAxisAlignment: CrossAxisAlignment.start,
    children: <Widget>[
      Text(
        money(entry.amountMinor ?? 0),
        style: const TextStyle(
          fontWeight: FontWeight.w700,
          color: Cc.ink,
          fontFeatures: Cc.figures,
        ),
      ),
      if (entry.periodStart != null && entry.periodEnd != null)
        Text(periodText(entry.periodStart!, entry.periodEnd!), style: Cc.small),
    ],
  );

  Widget _recorded(StaffPaymentEntry entry, {String? tail}) {
    final String who = entry.createdBy == _store.me
        ? '${entry.createdBy} (you)'
        : entry.createdBy;
    final String age = ageText(entry.createdAt);
    final bool overdue =
        entry.check == null &&
        (parseMoment(entry.createdAt)?.isBefore(
              DateTime.now().toUtc().subtract(const Duration(hours: 72)),
            ) ??
            false);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          'Bank date ${shortDayText(entry.receivedAt)} · by $who, ${shortDayText(entry.createdAt)}',
          style: const TextStyle(fontSize: 13, color: Cc.body),
        ),
        if (tail != null)
          Text(tail, style: Cc.small)
        else if (entry.check != null)
          Text(
            'Checked by ${entry.check!.checkedBy} · ${entry.check!.receiptNumber}',
            style: Cc.small,
          )
        else
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: CcBadge(
              'Waiting $age${overdue ? ' · overdue' : ''}',
              tone: overdue ? Tone.warn : Tone.neutral,
            ),
          ),
      ],
    );
  }

  Widget _toCheckTable(List<StaffPaymentEntry> all) {
    final List<StaffPaymentEntry> rows = all
        .where((StaffPaymentEntry e) => _inRange(e) && _byMatches(e))
        .toList(growable: false);
    return CcTable(
      columns: _columns(true),
      rows: <CcTableRow>[
        for (final StaffPaymentEntry entry in rows)
          CcTableRow(
            cells: <Widget>[
              _company(entry),
              _amount(entry),
              _recorded(entry),
              PaymentActionButtons(
                store: _store,
                entry: entry,
                showVoid: true,
                onDone: () {},
              ),
            ],
          ),
      ],
      empty: const CcEmptyState(
        title: 'No payments to check',
        message:
            'A payment recorded by someone else appears here until it matches the bank statement.',
      ),
      footer: Wrap(
        alignment: WrapAlignment.spaceBetween,
        spacing: 16,
        children: <Widget>[
          Text('Showing ${rows.length} of ${all.length}', style: Cc.small),
          Text(
            all.any(
                  (StaffPaymentEntry e) =>
                      e.createdBy == _store.me && e.canCheck == true,
                )
                ? 'You are the solo owner, so you can check a payment you recorded.'
                : 'The person who records a payment never checks it.',
            style: Cc.small,
          ),
        ],
      ),
    );
  }

  Widget _allTable(List<_PaymentRow> all, {required bool voidedTab}) {
    final List<_PaymentRow> rows = all
        .where(
          (_PaymentRow r) =>
              (voidedTab ? r.voided != null : true) &&
              _inRange(r.entry) &&
              _byMatches(r.entry),
        )
        .toList(growable: false);
    return CcTable(
      columns: _columns(false),
      rows: <CcTableRow>[
        for (final _PaymentRow row in rows)
          CcTableRow(
            cells: <Widget>[
              _company(row.entry),
              _amount(row.entry),
              _recorded(
                row.entry,
                tail: row.voided != null
                    ? 'Voided by ${row.voided!.createdBy}: ${row.voided!.reason}'
                    : null,
              ),
            ],
          ),
      ],
      empty: CcEmptyState(
        title: voidedTab ? 'No voided payments' : 'No payments found',
        message: 'Try a wider date range.',
      ),
      footer: Text('Showing ${rows.length} of ${all.length}', style: Cc.small),
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (BuildContext context, Widget? _) {
      final Loaded<List<StaffPaymentEntry>>? toCheck = _store.toCheck;
      return CcPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CcPageHeader(
              'Payments',
              actions: <Widget>[
                OutlinedButton(
                  onPressed: toCheck?.value == null
                      ? null
                      : () => _export(toCheck!.value!),
                  child: const Text('Export CSV'),
                ),
                IconButton(
                  tooltip: 'Reload payments',
                  constraints: const BoxConstraints(
                    minWidth: 44,
                    minHeight: 44,
                  ),
                  onPressed: _refresh,
                  icon: const Icon(Icons.refresh),
                ),
              ],
            ),
            CcTabBar(
              labels: const <String>['To check', 'All payments', 'Voided'],
              counts: <int?>[toCheck?.value?.length, null, null],
              selected: _tab,
              onSelected: (int tab) {
                setState(() => _tab = tab);
                if (tab != 0 && _all == null) _loadAll();
              },
            ),
            _filters(),
            const SizedBox(height: 16),
            if (_tab == 0)
              toCheck == null
                  ? const CcSkeleton()
                  : toCheck.value == null
                  ? CcErrorState(
                      what: 'payments',
                      message: toCheck.error!,
                      onRetry: _store.refreshToCheck,
                    )
                  : _toCheckTable(toCheck.value!)
            else if (_all == null)
              const CcSkeleton()
            else if (_all!.value == null)
              CcErrorState(
                what: 'payments',
                message: _all!.error!,
                onRetry: _loadAll,
              )
            else ...<Widget>[
              if (_failedCompanies > 0)
                CcBanner(
                  text:
                      '$_failedCompanies ${_failedCompanies == 1 ? 'company' : 'companies'} could not be read. The list below is incomplete.',
                  action: TextButton(
                    onPressed: _loadAll,
                    child: const Text('Retry'),
                  ),
                ),
              _allTable(_all!.value!, voidedTab: _tab == 2),
            ],
          ],
        ),
      );
    },
  );
}
