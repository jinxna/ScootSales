import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import '../store/cc_store.dart';
import '../widgets/cc_common.dart';
import '../widgets/cc_shell.dart';

class SupportHomePage extends StatefulWidget {
  const SupportHomePage({super.key, required this.store});

  final CcStore store;

  @override
  State<SupportHomePage> createState() => _SupportHomePageState();
}

class _SupportHomePageState extends State<SupportHomePage> {
  CcStore get _store => widget.store;

  @override
  void initState() {
    super.initState();
    if (_store.supportGrants == null) _store.refreshSupportGrants();
  }

  @override
  Widget build(BuildContext context) => ListenableBuilder(
    listenable: _store,
    builder: (BuildContext context, Widget? _) {
      final Loaded<List<StaffSupportGrant>>? loaded = _store.supportGrants;
      return CcPage(
        child: Column(
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            CcPageHeader(
              'Support',
              actions: <Widget>[
                OutlinedButton(
                  onPressed: _store.refreshSupportGrants,
                  child: const Text('Refresh'),
                ),
              ],
            ),
            const CcBanner(
              tone: Tone.info,
              text:
                  'A company gives support access for a short time. Each row below is one open request and ends by itself.',
            ),
            const SizedBox(height: 16),
            if (loaded == null)
              const CcSkeleton()
            else if (loaded.value == null)
              CcErrorState(
                message: loaded.error!,
                what: 'support requests',
                onRetry: _store.refreshSupportGrants,
              )
            else
              CcTable(
                columns: const <CcColumn>[
                  CcColumn('Company', flex: 3),
                  CcColumn('Task', flex: 4),
                  CcColumn('Access', width: 120, hideBelow: 760),
                  CcColumn('Ends', width: 170),
                ],
                rows: <CcTableRow>[
                  for (final StaffSupportGrant grant in loaded.value!)
                    CcTableRow(
                      cells: <Widget>[
                        Text(
                          grant.workspace == null
                              ? grant.companyLabel
                              : '${grant.companyLabel} (${codeText(grant.workspace!)})',
                          overflow: TextOverflow.ellipsis,
                        ),
                        Text(grant.task ?? '—'),
                        CcBadge(
                          grant.scope == 'diagnostics'
                              ? 'Diagnostics'
                              : grant.scope,
                          tone: Tone.info,
                        ),
                        Text(dateTimeText(grant.expiresAt), style: Cc.numbers),
                      ],
                    ),
                ],
                empty: const CcEmptyState(
                  title: 'No open support requests',
                  message:
                      'When a company gives your account support access, it shows here until the access ends.',
                ),
                footer: Text('${loaded.value!.length} open', style: Cc.small),
              ),
          ],
        ),
      );
    },
  );
}
