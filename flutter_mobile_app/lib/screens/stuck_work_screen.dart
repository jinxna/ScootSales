import 'dart:async';

import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../services/company_lifecycle_monitor.dart';
import '../services/sales_visit_copilot_service.dart';
import '../services/stuck_work.dart';
import '../widgets/phone_card.dart';
import '../widgets/phone_status_strip.dart';

typedef ResendStops = Future<bool> Function(String planId);

class StuckWorkScreen extends StatefulWidget {
  const StuckWorkScreen({
    super.key,
    required this.uid,
    required this.projectId,
    required this.resendStops,
    this.outcomes,
  });

  final String uid;
  final String projectId;
  final ResendStops resendStops;
  final SalesVisitCopilotService? outcomes;

  @override
  State<StuckWorkScreen> createState() => _StuckWorkScreenState();
}

class _StuckWorkScreenState extends State<StuckWorkScreen> {
  late final SalesVisitCopilotService _outcomes =
      widget.outcomes ?? SalesVisitCopilotService();
  late final StuckWork _work = StuckWork(
    projectId: widget.projectId,
    outcomes: _outcomes,
  );
  List<StuckWorkItem>? _items;
  String _note = '';
  bool _busy = false;

  @override
  void initState() {
    super.initState();
    unawaited(_load());
  }

  Future<void> _load() async {
    await _outcomes.initialiseForUser(widget.uid);
    final List<StuckWorkItem> items = await _work.list(widget.uid);
    if (mounted) setState(() => _items = items);
  }

  Future<void> _afterChange() async {
    await CompanyLifecycleMonitor.instance.refresh();
    await _load();
  }

  Future<void> _sendAgain(StuckWorkItem item) async {
    setState(() {
      _busy = true;
      _note = '';
    });
    try {
      if (item.kind == StuckWorkKind.stopEvent) {
        final bool tried = await widget.resendStops(item.planId);
        if (!tried) {
          _note =
              'That route is no longer yours, so this update cannot be sent again. You can remove it.';
        }
      } else {
        await _work.sendAgain(widget.uid, item);
        await CompanyLifecycleMonitor.instance.refresh();
      }
      await _load();
      final bool cleared = !(_items ?? const <StuckWorkItem>[]).any(
        (StuckWorkItem row) => row.id == item.id,
      );
      if (cleared && _note.isEmpty) {
        _note = await _work.stillHeld(widget.uid, item)
            ? 'It is waiting to be sent. It stays on this phone until the server accepts it, and comes back to this list if the server refuses it again.'
            : 'Sent. The server has accepted it.';
      } else if (_note.isEmpty) {
        _note = 'It was not accepted. The reason is shown on the card.';
      }
    } catch (_) {
      _note = 'It could not be sent now. It is still kept on this phone.';
    } finally {
      if (mounted) setState(() => _busy = false);
    }
  }

  Future<void> _remove(StuckWorkItem item) async {
    final bool? confirmed = await showDialog<bool>(
      context: context,
      builder: (BuildContext context) => AlertDialog(
        title: const Text('Remove this item?'),
        content: Text('${item.removeWarning}\n\nThis cannot be undone.'),
        actions: <Widget>[
          TextButton(
            onPressed: () => Navigator.of(context).pop(false),
            child: const Text('Keep it'),
          ),
          FilledButton(
            onPressed: () => Navigator.of(context).pop(true),
            child: const Text('Remove'),
          ),
        ],
      ),
    );
    if (confirmed != true) return;
    await _work.remove(widget.uid, item);
    await _afterChange();
  }

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final List<StuckWorkItem>? items = _items;
    return ScootPhoneScaffold(
      appBar: ScootPhoneAppBar(
        title: 'Needs attention',
        onBack: () => Navigator.of(context).maybePop(),
      ),
      statusStrip: const PhoneStatusStrip(),
      body: items == null
          ? const Center(child: CircularProgressIndicator())
          : ListView(
              padding: const EdgeInsets.all(ScootSpace.phoneGutter),
              children: <Widget>[
                if (items.isEmpty)
                  Text(
                    'Nothing needs attention. All your work has been sent.',
                    style: ScootType.body.copyWith(color: c.text2),
                  )
                else
                  Text(
                    'These items are kept on this phone. Send them again, or remove them if you do not need them.',
                    style: ScootType.body.copyWith(color: c.text2),
                  ),
                if (_note.isNotEmpty) ...<Widget>[
                  const SizedBox(height: 12),
                  ScootNotice(
                    tone: ScootTone.warning,
                    icon: ScootIcons.paused,
                    message: _note,
                    liveRegion: true,
                  ),
                ],
                for (final StuckWorkItem item in items) ...<Widget>[
                  const SizedBox(height: 12),
                  PhoneCard(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        Text(
                          item.title,
                          style: ScootType.bodyStrong.copyWith(color: c.ink),
                        ),
                        const SizedBox(height: 6),
                        Text(
                          item.reason.isEmpty
                              ? 'The server could not accept this item.'
                              : item.reason,
                          style: ScootType.body.copyWith(color: c.text2),
                        ),
                        const SizedBox(height: 12),
                        Row(
                          children: <Widget>[
                            Expanded(
                              child: FilledButton(
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(_sendAgain(item)),
                                child: const Text('Send again'),
                              ),
                            ),
                            const SizedBox(width: 12),
                            Expanded(
                              child: OutlinedButton(
                                onPressed: _busy
                                    ? null
                                    : () => unawaited(_remove(item)),
                                child: const Text('Remove'),
                              ),
                            ),
                          ],
                        ),
                      ],
                    ),
                  ),
                ],
              ],
            ),
    );
  }
}
