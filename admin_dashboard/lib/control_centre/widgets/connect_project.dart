import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../staff_api_client.dart';
import 'cc_command.dart';
import 'cc_common.dart';

Future<bool> showConnectProject(
  BuildContext context,
  StaffApiClient api,
  StaffOnboardingDraft draft, {
  String? knownProjectId,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => _ConnectDialog(
        api: api,
        draft: draft,
        knownProjectId: knownProjectId,
      ),
    ) ??
    false;

class _ConnectDialog extends StatefulWidget {
  const _ConnectDialog({
    required this.api,
    required this.draft,
    required this.knownProjectId,
  });

  final StaffApiClient api;
  final StaffOnboardingDraft draft;
  final String? knownProjectId;

  @override
  State<_ConnectDialog> createState() => _ConnectDialogState();
}

class _ConnectDialogState extends State<_ConnectDialog> {
  late final TextEditingController _project = TextEditingController(
    text: widget.knownProjectId,
  );
  Loaded<String?>? _serviceEmail;
  StaffConnectResult? _result;
  String? _error;
  bool _busy = false, _connected = false;

  @override
  void initState() {
    super.initState();
    _loadServiceEmail();
  }

  @override
  void dispose() {
    _project.dispose();
    super.dispose();
  }

  Future<void> _loadServiceEmail() async {
    final Loaded<String?> loaded = await Loaded.of<String?>(
      widget.api.projectServiceEmail(),
    );
    if (mounted) setState(() => _serviceEmail = loaded);
  }

  Future<void> _run(
    Future<StaffConnectResult> Function(String projectId) call,
  ) async {
    final String projectId = _project.text.trim();
    if (projectId.isEmpty) {
      setState(() => _error = 'Enter the Firebase project ID.');
      return;
    }
    if (_busy) return;
    setState(() {
      _busy = true;
      _error = null;
    });
    StaffConnectResult? result;
    String? failure;
    try {
      result = await call(projectId);
    } on StaffApiException catch (error) {
      failure = isUncertain(error) ? uncertainMessage : friendlyError(error);
    } catch (_) {
      failure = uncertainMessage;
    }
    if (!mounted) return;
    setState(() {
      _busy = false;
      _error = failure;
      if (result != null) {
        _result = result;
        _connected = result.ok;
      }
    });
  }

  bool get _hasProgress =>
      _result != null &&
      !_result!.ok &&
      _result!.parts.any((StaffConnectPart p) => p.state == 'saved');

  Widget _partRow(StaffConnectPart part) {
    final (IconData icon, Color color, String word) = switch (part.state) {
      'saved' => (Icons.check_circle, Cc.accent, 'Saved'),
      'pending' => (Icons.error, Cc.dangerFg, 'Not finished'),
      _ => (Icons.help_outline, Cc.muted, 'Could not check'),
    };
    return Padding(
      padding: const EdgeInsets.only(bottom: 6),
      child: Row(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Icon(icon, size: 18, color: color, semanticLabel: word),
          const SizedBox(width: 8),
          Expanded(child: Text('${part.label}: $word')),
        ],
      ),
    );
  }

  Widget _serviceCard() {
    final Loaded<String?>? loaded = _serviceEmail;
    if (loaded == null) {
      return const Text('Reading the Scoot service email…');
    }
    if (loaded.error != null) {
      return CcBanner(text: loaded.error!, tone: Tone.danger);
    }
    final String? email = loaded.value;
    if (email == null) {
      return const CcBanner(
        text:
            'Ask the engineer for the Scoot service email, then add it in IAM with the role Firebase Admin.',
        tone: Tone.info,
      );
    }
    return Container(
      padding: const EdgeInsets.all(14),
      decoration: BoxDecoration(
        color: Cc.accentSoft,
        borderRadius: BorderRadius.circular(8),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            'Step 1. Let Scoot read the project',
            style: TextStyle(fontWeight: FontWeight.w600, color: Cc.ink),
          ),
          const SizedBox(height: 6),
          const Text(
            'The person who owns the Google project opens IAM and adds this email with the role Firebase Admin.',
          ),
          const SizedBox(height: 8),
          Row(
            children: <Widget>[
              Expanded(child: SelectableText(email, style: Cc.numbers)),
              IconButton(
                tooltip: 'Copy the email',
                onPressed: () async {
                  await Clipboard.setData(ClipboardData(text: email));
                  if (!mounted) return;
                  announce(context, 'The email is copied.');
                },
                icon: const Icon(Icons.copy, size: 18),
              ),
            ],
          ),
        ],
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final StaffConnectResult? result = _result;
    return PopScope(
      canPop: !_busy,
      child: AlertDialog(
        title: Text(
          _hasProgress ? 'Finish connecting' : 'Connect the Firebase project',
        ),
        content: SizedBox(
          width: 500,
          child: SingleChildScrollView(
            child: Column(
              mainAxisSize: MainAxisSize.min,
              crossAxisAlignment: CrossAxisAlignment.stretch,
              children: <Widget>[
                _serviceCard(),
                const SizedBox(height: 16),
                const Text(
                  'Step 2. Enter the project ID',
                  style: TextStyle(fontWeight: FontWeight.w600, color: Cc.ink),
                ),
                const SizedBox(height: 6),
                TextField(
                  controller: _project,
                  readOnly: _busy || _connected,
                  decoration: const InputDecoration(
                    labelText: 'Firebase project ID',
                  ),
                ),
                const SizedBox(height: 8),
                const Text(
                  'Scoot reads the project and finds out if it is New (empty) or Existing (has people and data).',
                  style: Cc.small,
                ),
                if (_error != null) ...<Widget>[
                  const SizedBox(height: 12),
                  CcBanner(text: _error!, tone: Tone.danger),
                ],
                if (result != null) ...<Widget>[
                  const SizedBox(height: 14),
                  if (result.summary != null)
                    Text(
                      result.summary!,
                      style: const TextStyle(fontWeight: FontWeight.w600),
                    ),
                  const SizedBox(height: 8),
                  for (final StaffConnectPart part in result.parts)
                    _partRow(part),
                  if (result.refusal != null)
                    CcBanner(text: result.refusal!, tone: Tone.danger),
                  if (result.retryLater)
                    const CcBanner(
                      text:
                          'Scoot cannot read the project yet. Wait a minute, then check again.',
                      tone: Tone.warn,
                    ),
                  if (result.fallback != null)
                    CcBanner(
                      bold: 'If the owner cannot add the email.',
                      text: result.fallback!,
                      tone: Tone.info,
                    ),
                ],
              ],
            ),
          ),
        ),
        actions: <Widget>[
          TextButton(
            onPressed: _busy
                ? null
                : () => Navigator.of(context).pop(_connected),
            child: Text(_connected ? 'Close' : 'Cancel'),
          ),
          if (!_connected) ...<Widget>[
            OutlinedButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      (String id) =>
                          widget.api.checkProject(widget.draft.draftId, id),
                    ),
              child: const Text('Check again'),
            ),
            FilledButton(
              onPressed: _busy
                  ? null
                  : () => _run(
                      (String id) =>
                          widget.api.connectProject(widget.draft.draftId, id),
                    ),
              child: _busy
                  ? const SizedBox(
                      width: 18,
                      height: 18,
                      child: CircularProgressIndicator(strokeWidth: 2),
                    )
                  : Text(_hasProgress ? 'Finish connecting' : 'Connect'),
            ),
          ],
        ],
      ),
    );
  }
}
