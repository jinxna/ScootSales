import 'package:flutter/material.dart';

import '../../services/csv_downloader.dart';
import '../../utils/csv_export.dart';
import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';

class CompaniesPage extends StatefulWidget {
  const CompaniesPage({
    super.key,
    required this.store,
    required this.nav,
    this.initialQuery = '',
  });

  final CcStore store;
  final CcNav nav;
  final String initialQuery;

  @override
  State<CompaniesPage> createState() => _CompaniesPageState();
}

class _CompaniesPageState extends State<CompaniesPage> {
  static const List<String> _tabs = <String>[
    'All',
    'Renews in 7 days',
    'Past due',
    'Awaiting first payment',
    'Suspended',
    'Setting up',
    'No billing email',
  ];

  late final TextEditingController _query = TextEditingController(
    text: widget.initialQuery,
  );
  int _tab = 0;
  int _page = 0;
  int _perPage = 25;

  CcStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    _reload();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _reload({bool force = false}) async {
    await Future.wait<void>(<Future<void>>[
      _store.refreshCompanies(force: force),
      _store.refreshInvoices(force: force),
    ]);
  }

  bool _matchesTab(StaffCompany company) {
    final String? state = _store.lifecycleState(company.tenantId);
    switch (_tab) {
      case 1:
        final DateTime? end = parseMoment(
          _store.paidToPeriodEnd(company.tenantId),
        );
        if (end == null) return false;
        final int days = end.difference(DateTime.now().toUtc()).inDays;
        return days >= 0 && days <= 7;
      case 2:
        return state == 'past_due';
      case 3:
        return state == 'lead';
      case 4:
        return state == 'suspended';
      case 5:
        return company.status == 'lead';
      case 6:
        return company.billingEmail == null;
      default:
        return true;
    }
  }

  bool _matchesQuery(StaffCompany company) {
    final String query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return true;
    final bool invoiceMatch = _store
        .invoicesFor(company.tenantId)
        .any(
          (StaffInvoice i) => (i.number ?? '').toLowerCase().contains(query),
        );
    return company.legalName.toLowerCase().contains(query) ||
        company.workspace.toLowerCase().contains(query) ||
        (company.billingEmail ?? '').toLowerCase().contains(query) ||
        invoiceMatch;
  }

  List<StaffCompany> _filtered(List<StaffCompany> all) => all
      .where((StaffCompany c) => _matchesTab(c) && _matchesQuery(c))
      .toList(growable: false);

  void _export(List<StaffCompany> rows) => downloadCsv(
    filename: 'companies.csv',
    csv: buildCsv(
      <String>[
        'Company',
        'Workspace',
        'Status',
        'Package',
        'Paid to',
        'Billing email',
      ],
      <List<Object?>>[
        for (final StaffCompany c in rows)
          <Object?>[
            c.legalName,
            codeText(c.workspace),
            stateLabel(_store.lifecycleState(c.tenantId)),
            c.planRef,
            lastDayText(_store.paidToPeriodEnd(c.tenantId) ?? ''),
            c.billingEmail ?? '',
          ],
      ],
    ),
  );

  Widget _statusCell(StaffCompany company) {
    final String? state = _store.lifecycleState(company.tenantId);
    return Wrap(
      spacing: 6,
      runSpacing: 4,
      children: <Widget>[
        CcBadge(stateLabel(state), tone: stateTone(state)),
        if (company.expired) const CcBadge('Expired record', tone: Tone.danger),
      ],
    );
  }

  Widget _recordsBanner(List<StaffCompany> all) {
    final DateTime horizon = DateTime.now().toUtc().add(
      const Duration(days: 14),
    );
    int expired = 0;
    int expiring = 0;
    for (final StaffCompany company in all) {
      if (company.expired) {
        expired++;
        continue;
      }
      final DateTime? ends = parseMoment(company.expiresAt);
      if (ends != null && !ends.isAfter(horizon)) expiring++;
    }
    if (!_store.profile!.canManageAccounts || (expired == 0 && expiring == 0)) {
      return const SizedBox.shrink();
    }
    return CcBanner(
      bold: 'Company records need renewing.',
      text:
          '$expired expired, $expiring expiring within 14 days. The engineer renews them.',
    );
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (BuildContext context, Widget? _) {
      final Loaded<List<StaffCompany>>? loaded = _store.companies;
      final List<StaffCompany> all = loaded?.value ?? const <StaffCompany>[];
      final List<StaffCompany> rows = _filtered(all);
      final int pages = (rows.length / _perPage).ceil().clamp(1, 1 << 20);
      final int page = _page.clamp(0, pages - 1);
      final List<StaffCompany> shown = rows
          .skip(page * _perPage)
          .take(_perPage)
          .toList(growable: false);
      return CcPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CcPageHeader(
              'Companies',
              actions: <Widget>[
                OutlinedButton(
                  onPressed: rows.isEmpty ? null : () => _export(rows),
                  child: const Text('Export CSV'),
                ),
                if (_store.profile!.canCreateCompany)
                  FilledButton.icon(
                    onPressed: () => widget.nav.go(CcSection.newCompany),
                    icon: const Icon(Icons.add, size: 18),
                    label: const Text('Add company'),
                  ),
              ],
            ),
            _recordsBanner(all),
            CcTabBar(
              labels: _tabs,
              selected: _tab,
              onSelected: (int tab) => setState(() {
                _tab = tab;
                _page = 0;
              }),
            ),
            Align(
              alignment: Alignment.centerLeft,
              child: ConstrainedBox(
                constraints: const BoxConstraints(maxWidth: 460),
                child: Padding(
                  padding: const EdgeInsets.only(bottom: 14),
                  child: TextField(
                    controller: _query,
                    decoration: const InputDecoration(
                      labelText: 'Search this list',
                      prefixIcon: Icon(Icons.search),
                    ),
                    onChanged: (_) => setState(() => _page = 0),
                  ),
                ),
              ),
            ),
            if (loaded == null)
              const CcSkeleton(rows: 8)
            else if (loaded.value == null)
              CcErrorState(
                what: 'companies',
                message: loaded.error!,
                onRetry: () => _reload(force: true),
              )
            else
              CcTable(
                columns: const <CcColumn>[
                  CcColumn('Company', flex: 4),
                  CcColumn('Status', width: 200),
                  CcColumn('Package', width: 120, hideBelow: 820),
                  CcColumn('Paid to', width: 120, hideBelow: 720),
                  CcColumn('Billing email', flex: 3, hideBelow: 1060),
                ],
                rows: <CcTableRow>[
                  for (final StaffCompany company in shown)
                    CcTableRow(
                      semanticLabel:
                          '${company.legalName}, workspace ${codeText(company.workspace)}, status ${stateLabel(_store.lifecycleState(company.tenantId))}${company.expired ? ', expired record' : ''}',
                      onTap: () => widget.nav.openCompany(company.tenantId),
                      cells: <Widget>[
                        Column(
                          crossAxisAlignment: CrossAxisAlignment.start,
                          children: <Widget>[
                            Tooltip(
                              message: company.legalName,
                              child: Text(
                                company.legalName,
                                overflow: TextOverflow.ellipsis,
                                style: const TextStyle(
                                  fontWeight: FontWeight.w700,
                                  color: Cc.ink,
                                ),
                              ),
                            ),
                            Text(codeText(company.workspace), style: Cc.small),
                          ],
                        ),
                        _statusCell(company),
                        Text(company.planRef, style: Cc.numbers),
                        Text(
                          _store.paidToPeriodEnd(company.tenantId) == null
                              ? '—'
                              : lastDayText(
                                  _store.paidToPeriodEnd(company.tenantId)!,
                                ),
                          style: Cc.numbers,
                        ),
                        Text(
                          company.billingEmail == null
                              ? 'Not set'
                              : maskEmail(company.billingEmail!),
                          overflow: TextOverflow.ellipsis,
                          style: TextStyle(
                            color: company.billingEmail == null
                                ? Cc.warnFg
                                : Cc.body,
                          ),
                        ),
                      ],
                    ),
                ],
                empty: CcEmptyState(
                  title: _query.text.trim().isEmpty
                      ? 'No companies here'
                      : 'No companies match "${_query.text.trim()}"',
                  message:
                      'Check the spelling, or search by workspace code or billing email.',
                  action: OutlinedButton(
                    onPressed: () => setState(() {
                      _query.clear();
                      _tab = 0;
                    }),
                    child: const Text('Clear search and filters'),
                  ),
                ),
                footer: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 8,
                  children: <Widget>[
                    Text(
                      rows.isEmpty
                          ? '0 companies'
                          : '${page * _perPage + 1}–${page * _perPage + shown.length} of ${rows.length} companies',
                      style: Cc.small,
                    ),
                    Row(
                      mainAxisSize: MainAxisSize.min,
                      children: <Widget>[
                        const Text('Per page  ', style: Cc.small),
                        DropdownButton<int>(
                          value: _perPage,
                          items: const <DropdownMenuItem<int>>[
                            DropdownMenuItem<int>(value: 25, child: Text('25')),
                            DropdownMenuItem<int>(value: 50, child: Text('50')),
                            DropdownMenuItem<int>(
                              value: 100,
                              child: Text('100'),
                            ),
                          ],
                          onChanged: (int? v) => setState(() {
                            _perPage = v ?? 25;
                            _page = 0;
                          }),
                        ),
                        IconButton(
                          tooltip: 'Previous page',
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          onPressed: page == 0
                              ? null
                              : () => setState(() => _page = page - 1),
                          icon: const Icon(Icons.chevron_left),
                        ),
                        Text('Page ${page + 1} of $pages', style: Cc.small),
                        IconButton(
                          tooltip: 'Next page',
                          constraints: const BoxConstraints(
                            minWidth: 44,
                            minHeight: 44,
                          ),
                          onPressed: page >= pages - 1
                              ? null
                              : () => setState(() => _page = page + 1),
                          icon: const Icon(Icons.chevron_right),
                        ),
                      ],
                    ),
                  ],
                ),
              ),
          ],
        ),
      );
    },
  );
}
