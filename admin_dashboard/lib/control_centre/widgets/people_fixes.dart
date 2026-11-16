import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_command.dart';
import 'cc_common.dart';

const String _changedPrefix = 'This record changed';

Future<void> showPeopleFixes(
  BuildContext context,
  StaffApiClient api,
  String tenantId,
  String companyName,
) => showDialog<void>(
  context: context,
  builder: (BuildContext context) =>
      _PeopleDialog(api: api, tenantId: tenantId, companyName: companyName),
);

class _PeopleDialog extends StatefulWidget {
  const _PeopleDialog({
    required this.api,
    required this.tenantId,
    required this.companyName,
  });

  final StaffApiClient api;
  final String tenantId, companyName;

  @override
  State<_PeopleDialog> createState() => _PeopleDialogState();
}

class _PeopleDialogState extends State<_PeopleDialog> {
  Loaded<StaffPeopleReport>? _report;
  String? _error;
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    _load();
  }

  Future<void> _load() async {
    final Loaded<StaffPeopleReport> loaded = await Loaded.of(
      widget.api.peopleDefects(widget.tenantId),
    );
    if (mounted) setState(() => _report = loaded);
  }

  Future<void> _guard(Future<String?> Function() work) async {
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    String? message;
    try {
      message = await work();
    } on StaffApiException catch (error) {
      message = friendlyError(error);
      if (error.message.startsWith(_changedPrefix)) await _load();
    } catch (_) {
      message = uncertainMessage;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = message;
    });
  }

  Future<void> _fix(StaffPeopleDefect item, StaffPeopleFix fix) =>
      _guard(() async {
        final Map<String, Object?> preview = await widget.api.previewPeopleFix(
          widget.tenantId,
          item.id,
          fix.id,
        );
        if (!mounted) return null;
        final Object? summary = preview['summary'];
        final bool apply = await showCcConfirm(
          context,
          title: fix.label,
          message: summary is String && summary.isNotEmpty
              ? summary
              : 'This changes one record.',
          confirmLabel: 'Apply',
        );
        if (!apply) return null;
        await widget.api.applyPeopleFix(
          widget.tenantId,
          item.id,
          fix.id,
          preview,
        );
        await _load();
        return 'The fix was applied.';
      });

  Future<void> _restore(StaffArchivedRow row) => _guard(() async {
    await widget.api.restorePeopleRow(widget.tenantId, row.id);
    await _load();
    return 'The record was restored.';
  });

  Widget _item(StaffPeopleDefect item) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 10),
    child: Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          <String>[
            if (item.name != null) item.name!,
            if (item.employeeCode != null) item.employeeCode!,
          ].join(' · '),
          style: const TextStyle(fontWeight: FontWeight.w600, color: Cc.ink),
        ),
        Text(item.text, style: Cc.small),
        const SizedBox(height: 6),
        if (item.fixes.isEmpty)
          const Text('No fix is offered here.', style: Cc.small)
        else
          Wrap(
            spacing: 8,
            runSpacing: 6,
            children: <Widget>[
              for (final StaffPeopleFix fix in item.fixes)
                OutlinedButton(
                  onPressed: _busy ? null : () => _fix(item, fix),
                  child: Text(fix.label),
                ),
            ],
          ),
      ],
    ),
  );

  Widget _archived(StaffArchivedRow row) => Padding(
    padding: const EdgeInsets.symmetric(vertical: 6),
    child: Row(
      children: <Widget>[
        Expanded(
          child: Text(
            <String>[
              row.employeeCode ?? 'Record',
              ?row.reason,
              if (row.archivedBy != null) 'by ${row.archivedBy}',
            ].join(' · '),
          ),
        ),
        OutlinedButton(
          onPressed: _busy ? null : () => _restore(row),
          child: const Text('Restore'),
        ),
      ],
    ),
  );

  @override
  Widget build(BuildContext context) {
    final Loaded<StaffPeopleReport>? loaded = _report;
    final StaffPeopleReport? report = loaded?.value;
    Widget body;
    if (loaded == null) {
      body = Text('Reading the people in ${widget.companyName}…');
    } else if (report == null) {
      body = CcBanner(text: loaded.error!, tone: Tone.danger);
    } else {
      body = Column(
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          if (report.items.isEmpty)
            const Text('No person needs a fix.')
          else
            for (final StaffPeopleDefect item in report.items) ...<Widget>[
              _item(item),
              const Divider(height: 1, color: Cc.line),
            ],
          if (report.archived.isNotEmpty) ...<Widget>[
            const SizedBox(height: 16),
            const Text(
              'Archived records',
              style: TextStyle(fontWeight: FontWeight.w600, color: Cc.ink),
            ),
            for (final StaffArchivedRow row in report.archived) _archived(row),
          ],
        ],
      );
    }
    return AlertDialog(
      title: const Text('Fix people'),
      content: SizedBox(
        width: 560,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.stretch,
            children: <Widget>[
              if (_error != null) ...<Widget>[
                CcBanner(text: _error!, tone: Tone.info),
                const SizedBox(height: 8),
              ],
              body,
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: () => Navigator.of(context).pop(),
          child: const Text('Close'),
        ),
      ],
    );
  }
}
