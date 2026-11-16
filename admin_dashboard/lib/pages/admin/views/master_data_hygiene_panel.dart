import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../../../models/master_data_hygiene.dart';
import '../../../models/user_profile.dart';
import '../../../services/master_data_hygiene_service.dart';
import '../../../theme/dso_theme.dart';
import '../../../utils/csv_export.dart';
import '../../../widgets/slow_loading.dart';

class MasterDataHygienePanel extends StatefulWidget {
  const MasterDataHygienePanel({
    super.key,
    required this.currentUser,
    this.onNavigateRequested,
  });

  final UserProfile currentUser;
  final ValueChanged<String>? onNavigateRequested;

  @override
  State<MasterDataHygienePanel> createState() => _MasterDataHygienePanelState();
}

class _MasterDataHygienePanelState extends State<MasterDataHygienePanel> {
  final MasterDataHygieneService _service = MasterDataHygieneService();
  late Future<List<HygieneIssue>> _future;
  String _filter = 'all';

  @override
  void initState() {
    super.initState();
    _future = widget.currentUser.isAdmin
        ? _service.loadIssues()
        : Future<List<HygieneIssue>>.value(const <HygieneIssue>[]);
  }

  void _refresh() {
    if (!widget.currentUser.isAdmin) return;
    setState(() => _future = _service.loadIssues());
  }

  @override
  Widget build(BuildContext context) {
    if (!widget.currentUser.isAdmin) {
      return const Center(
        child: Text('Master-data hygiene tools require an admin account.'),
      );
    }
    return FutureBuilder<List<HygieneIssue>>(
      future: _future,
      builder: (BuildContext context, AsyncSnapshot<List<HygieneIssue>> snapshot) {
        if (snapshot.connectionState == ConnectionState.waiting) {
          return const SlowLoading();
        }
        if (snapshot.hasError) {
          return Center(
            child: Text('Could not scan master data. Please try again.'),
          );
        }
        final List<HygieneIssue> all = snapshot.data ?? const <HygieneIssue>[];
        final List<String> types =
            all.map((HygieneIssue issue) => issue.type).toSet().toList()
              ..sort();
        final String filter = _filter == 'all' || types.contains(_filter)
            ? _filter
            : 'all';
        final List<HygieneIssue> visible = all
            .where(
              (HygieneIssue issue) => filter == 'all' || issue.type == filter,
            )
            .toList(growable: false);
        return Column(
          children: <Widget>[
            Padding(
              padding: const EdgeInsets.all(14),
              child: Column(
                crossAxisAlignment: CrossAxisAlignment.start,
                children: <Widget>[
                  Text(
                    'Bounded scan: 2,000 products, 2,000 retailers, '
                    '1,000 users, and 1,500 orders. Duplicate records and '
                    'ambiguous order defects are review-only; nothing is '
                    'merged or rewritten automatically.',
                    style: TextStyle(
                      fontSize: 12,
                      height: 1.45,
                      color: context.dso.muted,
                    ),
                  ),
                  const SizedBox(height: 10),
                  Wrap(
                    spacing: 9,
                    runSpacing: 9,
                    crossAxisAlignment: WrapCrossAlignment.center,
                    children: <Widget>[
                      _Count(
                        label: 'High',
                        value: all
                            .where(
                              (HygieneIssue issue) =>
                                  issue.severity == HygieneSeverity.high,
                            )
                            .length,
                        danger: true,
                      ),
                      _Count(
                        label: 'Medium',
                        value: all
                            .where(
                              (HygieneIssue issue) =>
                                  issue.severity == HygieneSeverity.medium,
                            )
                            .length,
                      ),
                      DropdownButton<String>(
                        value: filter,
                        items: <DropdownMenuItem<String>>[
                          const DropdownMenuItem<String>(
                            value: 'all',
                            child: Text('All issue types'),
                          ),
                          ...types.map(
                            (String type) => DropdownMenuItem<String>(
                              value: type,
                              child: Text(type.replaceAll('_', ' ')),
                            ),
                          ),
                        ],
                        onChanged: (String? value) {
                          if (value != null) {
                            setState(() => _filter = value);
                          }
                        },
                      ),
                      OutlinedButton.icon(
                        onPressed: () => _copyCsv(visible),
                        icon: const Icon(Icons.copy_all_outlined, size: 17),
                        label: const Text('Copy review CSV'),
                      ),
                      IconButton(
                        tooltip: 'Refresh scan',
                        onPressed: _refresh,
                        icon: const Icon(Icons.refresh),
                      ),
                    ],
                  ),
                ],
              ),
            ),
            const Divider(height: 1),
            Expanded(
              child: visible.isEmpty
                  ? const Center(child: Text('No issues match this filter.'))
                  : ListView.separated(
                      itemCount: visible.length,
                      separatorBuilder: (_, _) => const Divider(height: 1),
                      itemBuilder: (BuildContext context, int index) {
                        final HygieneIssue issue = visible[index];
                        return ListTile(
                          leading: Icon(
                            issue.severity == HygieneSeverity.high
                                ? Icons.error_outline
                                : Icons.warning_amber_outlined,
                            color: issue.severity == HygieneSeverity.high
                                ? context.dso.dangerText
                                : context.dso.warningText,
                          ),
                          title: Text(issue.title),
                          subtitle: Text(
                            '${issue.detail}\n'
                            '${_guidance(issue)}',
                          ),
                          isThreeLine: true,
                          trailing:
                              issue.fixPageKey.isEmpty ||
                                  widget.onNavigateRequested == null
                              ? const Text(
                                  'Review only',
                                  style: TextStyle(
                                    fontSize: 11,
                                    fontWeight: FontWeight.w700,
                                  ),
                                )
                              : TextButton.icon(
                                  onPressed: () => widget.onNavigateRequested!(
                                    issue.fixPageKey,
                                  ),
                                  icon: const Icon(Icons.open_in_new, size: 15),
                                  label: Text(
                                    'Open ${issue.fixPageKey.replaceAll('_', ' ')}',
                                  ),
                                ),
                        );
                      },
                    ),
            ),
          ],
        );
      },
    );
  }

  Future<void> _copyCsv(List<HygieneIssue> issues) async {
    final StringBuffer csv = StringBuffer(
      'severity,type,entityType,entityId,title,detail,fixPage\n',
    );
    for (final HygieneIssue issue in issues) {
      csv.writeln(
        <String>[
          issue.severity.name,
          issue.type,
          issue.entityType,
          issue.entityId,
          issue.title,
          issue.detail,
          issue.fixPageKey,
        ].map(csvCell).join(','),
      );
    }
    await Clipboard.setData(ClipboardData(text: csv.toString()));
    if (!mounted) return;
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(content: Text('${issues.length} hygiene issue(s) copied.')),
    );
  }
}

class _Count extends StatelessWidget {
  const _Count({required this.label, required this.value, this.danger = false});

  final String label;
  final int value;
  final bool danger;

  @override
  Widget build(BuildContext context) {
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 7),
      decoration: BoxDecoration(
        color: danger ? context.dso.dangerSoft : context.dso.warningSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Text(
        '$label: $value',
        style: TextStyle(
          fontWeight: FontWeight.w800,
          color: danger ? context.dso.dangerText : context.dso.warningText,
        ),
      ),
    );
  }
}

String _guidance(HygieneIssue issue) {
  if (issue.type.startsWith('duplicate_')) {
    return 'Compare references and choose a canonical record manually. '
        'No automatic merge or delete is available.';
  }
  if (issue.type == 'unverified_coordinates') {
    return 'Confirm the location, then verify it in Coordinate Review. '
        'Unverified retailers are excluded by the planner\'s "Verified only" '
        'gate.';
  }
  if (issue.type == 'unaddressable_profile') {
    return 'This account\'s profile is not stored under its sign-in ID, so its '
        'role may not be recognised. The profile has to be moved by a '
        'developer; there is no fix available in the dashboard.';
  }
  if (issue.entityType == 'order') {
    return 'Order lines, dates and identities cannot be edited from the '
        'dashboard. Review the original order and ask a developer to correct it.';
  }
  return issue.fixPageKey.isEmpty
      ? 'Review the source record and correct it explicitly.'
      : 'Use the ${issue.fixPageKey.replaceAll('_', ' ')} editor and confirm '
            'the corrected value.';
}
