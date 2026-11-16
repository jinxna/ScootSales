import 'package:flutter/material.dart';

import '../../services/csv_downloader.dart';
import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_fields.dart';
import '../widgets/cc_nav.dart';
import '../widgets/cc_shell.dart';

class AuditPage extends StatefulWidget {
  const AuditPage({super.key, required this.store, required this.nav});

  final CcStore store;
  final CcNav nav;

  @override
  State<AuditPage> createState() => _AuditPageState();
}

class _AuditPageState extends State<AuditPage> {
  final TextEditingController _query = TextEditingController();
  DateTime? _from, _to;
  Loaded<StaffAuditPage>? _page;
  final List<StaffAuditEvent> _events = <StaffAuditEvent>[];
  String? _next;
  bool _more = false;
  String? _check;
  bool _checking = false;

  CcStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    if (_store.companies == null) _store.refreshCompanies();
    _load();
  }

  @override
  void dispose() {
    _query.dispose();
    super.dispose();
  }

  Future<void> _load({bool append = false}) async {
    if (!append) {
      setState(() {
        _page = null;
        _events.clear();
        _next = null;
      });
    } else {
      setState(() => _more = true);
    }
    final Loaded<StaffAuditPage> loaded = await Loaded.of(
      _store.api.auditEvents(
        from: _from == null ? null : klIsoDay(_from!),
        to: _to == null ? null : klIsoDay(_to!),
        after: append ? _next : null,
        limit: 100,
      ),
    );
    if (!mounted) return;
    setState(() {
      _more = false;
      if (loaded.value != null) {
        _events.addAll(loaded.value!.events);
        _next = loaded.value!.nextAfter;
      }
      _page = loaded;
    });
  }

  Future<void> _verify() async {
    setState(() {
      _checking = true;
      _check = null;
    });
    final Loaded<StaffAuditCheck> result = await Loaded.of(
      _store.api.verifyAuditDay(klIsoDay(klToday())),
    );
    if (!mounted) return;
    setState(() {
      _checking = false;
      _check = result.value == null
          ? result.error
          : result.value!.ok
          ? 'Today\'s log is intact. ${result.value!.events} events checked.'
          : 'Today\'s log does not match its seal: ${result.value!.brokenReason ?? 'unknown reason'}.';
    });
  }

  List<StaffAuditEvent> get _shown {
    final String query = _query.text.trim().toLowerCase();
    if (query.isEmpty) return _events;
    return _events
        .where(
          (StaffAuditEvent e) =>
              e.actor.toLowerCase().contains(query) ||
              e.action.toLowerCase().contains(query) ||
              e.summary.toLowerCase().contains(query) ||
              operationLabel(e.action).toLowerCase().contains(query) ||
              auditSummaryText(e.summary).toLowerCase().contains(query) ||
              (e.tenantId != null &&
                  _store
                      .companyName(e.tenantId!)
                      .toLowerCase()
                      .contains(query)),
        )
        .toList(growable: false);
  }

  Future<void> _export() async {
    final Loaded<String> result = await Loaded.of(
      _store.api.exportAudit(
        format: 'csv',
        from: _from == null ? null : klIsoDay(_from!),
        to: _to == null ? null : klIsoDay(_to!),
      ),
    );
    if (!mounted) return;
    if (result.value == null) {
      announce(context, result.error!);
      return;
    }
    downloadCsv(filename: 'audit-log.csv', csv: result.value!);
    announce(context, 'The audit log was exported.');
  }

  @override
  Widget build(BuildContext context) {
    final Loaded<StaffAuditPage>? loaded = _page;
    final List<StaffAuditEvent> rows = _shown;
    return ListenableBuilder(
      listenable: _store,
      builder: (BuildContext context, Widget? _) => CcPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CcPageHeader(
              'Audit log',
              actions: <Widget>[
                OutlinedButton(
                  onPressed: _checking ? null : _verify,
                  child: const Text('Check today\'s log'),
                ),
                if (_store.profile!.isOwner)
                  OutlinedButton(
                    onPressed: _export,
                    child: const Text('Export CSV'),
                  ),
              ],
            ),
            if (_check != null)
              CcBanner(
                text: _check!,
                tone: _check!.contains('intact') ? Tone.ok : Tone.danger,
              ),
            Padding(
              padding: const EdgeInsets.only(bottom: 14),
              child: Wrap(
                spacing: 16,
                runSpacing: 12,
                crossAxisAlignment: WrapCrossAlignment.end,
                children: <Widget>[
                  SizedBox(
                    width: 320,
                    child: TextField(
                      controller: _query,
                      decoration: const InputDecoration(
                        labelText: 'Search who, company or action',
                        prefixIcon: Icon(Icons.search),
                      ),
                      onChanged: (_) => setState(() {}),
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: CcDateField(
                      label: 'From',
                      value: _from,
                      last: klToday(),
                      onChanged: (DateTime d) {
                        setState(() => _from = d);
                        _load();
                      },
                    ),
                  ),
                  SizedBox(
                    width: 200,
                    child: CcDateField(
                      label: 'To',
                      value: _to,
                      last: klToday(),
                      onChanged: (DateTime d) {
                        setState(() => _to = d);
                        _load();
                      },
                    ),
                  ),
                  if (_from != null || _to != null)
                    TextButton(
                      onPressed: () {
                        setState(() {
                          _from = null;
                          _to = null;
                        });
                        _load();
                      },
                      child: const Text('Clear dates'),
                    ),
                ],
              ),
            ),
            if (loaded == null)
              const CcSkeleton(rows: 8)
            else if (loaded.value == null && _events.isEmpty)
              CcErrorState(
                what: 'the audit log',
                message: loaded.error!,
                onRetry: _load,
              )
            else
              CcTable(
                columns: const <CcColumn>[
                  CcColumn('When', width: 170),
                  CcColumn('Who', flex: 2, hideBelow: 760),
                  CcColumn('Company', flex: 2, hideBelow: 960),
                  CcColumn('What happened', flex: 5),
                ],
                rows: <CcTableRow>[
                  for (final StaffAuditEvent e in rows)
                    CcTableRow(
                      cells: <Widget>[
                        Text(dateTimeText(e.at), style: Cc.numbers),
                        Text(e.actor, overflow: TextOverflow.ellipsis),
                        e.tenantId == null
                            ? const Text('—')
                            : CcLink(
                                _store.companyName(e.tenantId!),
                                onTap: () => widget.nav.openCompany(
                                  e.tenantId!,
                                  tab: CompanyTab.activity,
                                ),
                              ),
                        Text(
                          e.summary.isEmpty
                              ? operationLabel(e.action)
                              : auditSummaryText(e.summary),
                        ),
                      ],
                    ),
                ],
                empty: const CcEmptyState(
                  title: 'Nothing recorded for these dates',
                  message: 'Choose other dates or clear the search.',
                ),
                footer: Wrap(
                  alignment: WrapAlignment.spaceBetween,
                  crossAxisAlignment: WrapCrossAlignment.center,
                  spacing: 16,
                  runSpacing: 8,
                  children: <Widget>[
                    Text(
                      '${rows.length} events shown${loaded.value == null ? '' : ' · ${loaded.value!.from} to ${loaded.value!.to}'}',
                      style: Cc.small,
                    ),
                    if (_next != null)
                      OutlinedButton(
                        onPressed: _more ? null : () => _load(append: true),
                        child: const Text('Show older events'),
                      ),
                  ],
                ),
              ),
          ],
        ),
      ),
    );
  }
}
