import 'package:flutter/material.dart';

import '../staff_api_client.dart';
import 'cc_common.dart';

const String uncertainMessage =
    'We do not know if this was saved. Check again before you save it a second time. Retrying is safe: it cannot happen twice.';

bool isUncertain(StaffApiException error) =>
    error.statusCode == null ||
    error.statusCode == 408 ||
    error.statusCode == 429 ||
    error.statusCode! >= 500;

bool isMissingRoute(StaffApiException error) =>
    error.statusCode == 404 || error.statusCode == 405;

String friendlyError(StaffApiException error) {
  if (error.statusCode == 403 &&
      error.message.startsWith('The staff service returned an error')) {
    return 'Your role cannot do this. Ask an owner in Inbox.';
  }
  return error.message;
}

class CmdFix {
  const CmdFix(this.label, this.go);

  final String label;
  final VoidCallback go;
}

class CmdResult {
  const CmdResult.ok([this.message]) : ok = true, uncertain = false, fix = null;
  const CmdResult.fail(String this.message, {this.uncertain = false, this.fix})
    : ok = false;

  final bool ok, uncertain;
  final String? message;
  final CmdFix? fix;

  static Future<CmdResult> run(
    Future<Object?> Function() action, {
    String? done,
    CmdFix? Function(StaffApiException error)? fixFor,
  }) async {
    try {
      await action();
      return CmdResult.ok(done);
    } on StaffApiException catch (error) {
      return CmdResult.fail(
        isUncertain(error) ? uncertainMessage : friendlyError(error),
        uncertain: isUncertain(error),
        fix: fixFor?.call(error),
      );
    } catch (_) {
      return const CmdResult.fail(uncertainMessage, uncertain: true);
    }
  }
}

Future<CmdResult> sendForApproval(
  StaffApiClient api, {
  required String action,
  required Map<String, Object?> params,
  required String reason,
  required String key,
  String? tenantId,
}) async {
  try {
    await api.requestApproval(
      action: action,
      params: params,
      reason: reason,
      key: key,
      tenantId: tenantId,
    );
    return const CmdResult.ok('Sent for approval');
  } on StaffApiException catch (error) {
    if (isMissingRoute(error)) {
      return const CmdResult.fail(
        'Approvals are not switched on yet. Nothing was changed.',
      );
    }
    return CmdResult.fail(
      isUncertain(error) ? uncertainMessage : friendlyError(error),
      uncertain: isUncertain(error),
    );
  } catch (_) {
    return const CmdResult.fail(uncertainMessage, uncertain: true);
  }
}

typedef CommandRun = Future<CmdResult> Function(String reason, String key);

Future<bool> showCcCommand(
  BuildContext context, {
  required String title,
  required String confirmLabel,
  required CommandRun run,
  Widget? body,
  String? reasonLabel = 'Reason',
  String reasonHint = 'Saved in the audit log',
  bool danger = false,
}) async =>
    await showDialog<bool>(
      context: context,
      barrierDismissible: false,
      builder: (BuildContext context) => CcCommandDialog(
        title: title,
        confirmLabel: confirmLabel,
        run: run,
        body: body,
        reasonLabel: reasonLabel,
        reasonHint: reasonHint,
        danger: danger,
      ),
    ) ??
    false;

class CcCommandDialog extends StatefulWidget {
  const CcCommandDialog({
    super.key,
    required this.title,
    required this.confirmLabel,
    required this.run,
    this.body,
    this.reasonLabel = 'Reason',
    this.reasonHint = 'Saved in the audit log',
    this.danger = false,
  });

  final String title, confirmLabel, reasonHint;
  final String? reasonLabel;
  final Widget? body;
  final CommandRun run;
  final bool danger;

  @override
  State<CcCommandDialog> createState() => _CcCommandDialogState();
}

class _CcCommandDialogState extends State<CcCommandDialog> {
  final TextEditingController _reason = TextEditingController();
  String? _key, _frozenReason, _error, _fieldError;
  CmdFix? _fix;
  bool _busy = false, _uncertain = false;

  @override
  void dispose() {
    _reason.dispose();
    super.dispose();
  }

  Future<void> _send() async {
    if (_busy) return;
    if (!_uncertain) {
      final String reason = _reason.text.trim();
      if (widget.reasonLabel != null && reason.isEmpty) {
        setState(() => _fieldError = 'Enter a reason.');
        return;
      }
      _frozenReason = reason;
      _key = newKey();
    }
    setState(() {
      _busy = true;
      _error = null;
      _fix = null;
      _fieldError = null;
    });
    final CmdResult result = await widget.run(_frozenReason!, _key!);
    if (!mounted) return;
    if (result.ok) {
      if (result.message != null) announce(context, result.message!);
      Navigator.of(context).pop(true);
      return;
    }
    setState(() {
      _busy = false;
      _uncertain = result.uncertain;
      _error = result.message;
      _fix = result.fix;
      if (!result.uncertain) {
        _key = null;
        _frozenReason = null;
      }
    });
  }

  @override
  Widget build(BuildContext context) => PopScope(
    canPop: !_busy && !_uncertain,
    child: AlertDialog(
      title: Text(widget.title),
      content: SizedBox(
        width: 460,
        child: SingleChildScrollView(
          child: Column(
            mainAxisSize: MainAxisSize.min,
            crossAxisAlignment: CrossAxisAlignment.start,
            children: <Widget>[
              ?widget.body,
              if (widget.body != null && widget.reasonLabel != null)
                const SizedBox(height: 14),
              if (widget.reasonLabel != null)
                TextField(
                  controller: _reason,
                  readOnly: _uncertain,
                  maxLines: 3,
                  maxLength: 500,
                  decoration: InputDecoration(
                    labelText: widget.reasonLabel,
                    helperText: widget.reasonHint,
                    errorText: _fieldError,
                  ),
                ),
              if (_error != null) CcBanner(text: _error!, tone: Tone.danger),
              if (_fix != null)
                Align(
                  alignment: Alignment.centerLeft,
                  child: TextButton(
                    onPressed: () {
                      final VoidCallback go = _fix!.go;
                      Navigator.of(context).pop(false);
                      go();
                    },
                    child: Text(_fix!.label),
                  ),
                ),
            ],
          ),
        ),
      ),
      actions: <Widget>[
        TextButton(
          onPressed: _busy ? null : () => Navigator.of(context).pop(false),
          child: Text(_uncertain ? 'Close' : 'Cancel'),
        ),
        FilledButton(
          style: widget.danger
              ? FilledButton.styleFrom(backgroundColor: Cc.dangerFg)
              : null,
          onPressed: _busy ? null : _send,
          child: _busy
              ? const SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                )
              : Text(_uncertain ? 'Check again' : widget.confirmLabel),
        ),
      ],
    ),
  );
}

Future<bool> showCcConfirm(
  BuildContext context, {
  required String title,
  required String message,
  required String confirmLabel,
  bool danger = false,
}) async =>
    await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: Text(title),
        content: SizedBox(width: 440, child: Text(message)),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Cancel'),
          ),
          FilledButton(
            style: danger
                ? FilledButton.styleFrom(backgroundColor: Cc.dangerFg)
                : null,
            onPressed: () => Navigator.of(context).pop(true),
            child: Text(confirmLabel),
          ),
        ],
      ),
    ) ??
    false;
