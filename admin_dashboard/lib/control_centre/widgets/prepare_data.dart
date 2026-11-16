import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_command.dart';
import 'cc_common.dart';

Future<bool> showPrepareData(
  BuildContext context,
  StaffApiClient api,
  String tenantId,
  String companyName,
) {
  final List<StaffPrepareReport?> checked = <StaffPrepareReport?>[null];
  final GlobalKey<_PrepareBodyState> body = GlobalKey<_PrepareBodyState>();
  return showCcCommand(
    context,
    title: 'Prepare company data',
    confirmLabel: 'Prepare company data',
    reasonLabel: null,
    body: _PrepareBody(
      key: body,
      api: api,
      tenantId: tenantId,
      companyName: companyName,
      onChecked: (StaffPrepareReport report) => checked[0] = report,
    ),
    run: (String reason, String key) async {
      final StaffPrepareReport? report = checked[0];
      if (report == null) {
        return const CmdResult.fail('Wait until the check has finished.');
      }
      if (!report.ready) return CmdResult.fail(report.blockers.join(' '));
      if (report.prepared) {
        return const CmdResult.ok('Nothing to change. The data was ready.');
      }
      final CmdResult result = await CmdResult.run(
        () => api.prepareData(tenantId, apply: true),
        done: 'Company data is prepared.',
      );
      if (!result.ok) {
        checked[0] = null;
        await body.currentState?._check();
      }
      return result;
    },
  );
}

class _PrepareBody extends StatefulWidget {
  const _PrepareBody({
    super.key,
    required this.api,
    required this.tenantId,
    required this.companyName,
    required this.onChecked,
  });

  final StaffApiClient api;
  final String tenantId, companyName;
  final void Function(StaffPrepareReport report) onChecked;

  @override
  State<_PrepareBody> createState() => _PrepareBodyState();
}

class _PrepareBodyState extends State<_PrepareBody> {
  Loaded<StaffPrepareReport>? _report;

  @override
  void initState() {
    super.initState();
    _check();
  }

  Future<void> _check() async {
    setState(() => _report = null);
    final Loaded<StaffPrepareReport> loaded = await Loaded.of(
      widget.api.prepareData(widget.tenantId, apply: false),
    );
    if (loaded.value != null) widget.onChecked(loaded.value!);
    if (mounted) setState(() => _report = loaded);
  }

  String _changes(StaffPrepareReport report) {
    if (report.prepared) {
      return 'Nothing to change. The counters already match the people and products.';
    }
    return 'Prepare will mark ${report.accessRecords} access records and ${report.profiles} profiles with their seat, and set the counters. It does not remove or add any person.';
  }

  @override
  Widget build(BuildContext context) {
    final Loaded<StaffPrepareReport>? loaded = _report;
    if (loaded == null) {
      return Text('Checking ${widget.companyName}…');
    }
    final StaffPrepareReport? report = loaded.value;
    if (report == null) {
      return CcBanner(text: loaded.error!, tone: Tone.danger);
    }
    return Column(
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        Text(
          'Counts in ${widget.companyName} today',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        const SizedBox(height: 4),
        Text(limitsText(report.counts), style: Cc.numbers),
        const SizedBox(height: 12),
        const Text(
          'Compared with each package',
          style: TextStyle(fontWeight: FontWeight.w600),
        ),
        for (final StaffPackageFit fit in report.fit)
          Padding(
            padding: const EdgeInsets.only(top: 4),
            child: Text(
              fit.fits
                  ? '${fit.name}: fits'
                  : '${fit.name}: ${fit.exceeded.join(', ')}',
              style: TextStyle(
                color: fit.fits ? Cc.okFg : Cc.warnFg,
                fontSize: 13,
              ),
            ),
          ),
        const SizedBox(height: 14),
        for (final String blocker in report.blockers)
          CcBanner(text: blocker, tone: Tone.danger),
        for (final String note in report.notes)
          CcBanner(text: note, tone: Tone.info),
        if (report.ready) Text(_changes(report), style: Cc.small),
      ],
    );
  }
}
