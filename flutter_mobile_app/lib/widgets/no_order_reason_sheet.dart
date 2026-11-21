import 'package:flutter/material.dart';

import '../services/sales_visit_copilot_service.dart';
import '../utils/retailer_memory.dart';
import 'follow_up_chips.dart';

class NoOrderDraft {
  const NoOrderDraft({
    required this.reasonCode,
    required this.note,
    this.followUpOn,
  });

  final String reasonCode;
  final String note;
  final DateTime? followUpOn;
}

Future<NoOrderDraft?> showNoOrderReasonSheet(
  BuildContext context, {
  DateTime? nextVisit,
}) {
  return showModalBottomSheet<NoOrderDraft>(
    context: context,
    isScrollControlled: true,
    showDragHandle: true,
    builder: (BuildContext context) => NoOrderReasonSheet(nextVisit: nextVisit),
  );
}

class NoOrderReasonSheet extends StatefulWidget {
  const NoOrderReasonSheet({super.key, this.nextVisit});

  final DateTime? nextVisit;

  @override
  State<NoOrderReasonSheet> createState() => _NoOrderReasonSheetState();
}

class _NoOrderReasonSheetState extends State<NoOrderReasonSheet> {
  final TextEditingController _note = TextEditingController();
  String _reason = '';
  String _message = '';
  DateTime? _followUpOn;
  bool _saved = false;

  @override
  void dispose() {
    _note.dispose();
    super.dispose();
  }

  void _save() {
    if (_saved) return;
    final String note = _note.text.trim();
    if (_reason.isEmpty) {
      setState(() => _message = 'Choose a reason.');
      return;
    }
    if (_reason == 'other' && note.length < 8) {
      setState(() => _message = 'Other needs a note of at least 8 characters.');
      return;
    }
    _saved = true;
    Navigator.pop(
      context,
      NoOrderDraft(reasonCode: _reason, note: note, followUpOn: _followUpOn),
    );
  }

  @override
  Widget build(BuildContext context) {
    final List<String> reasons = SalesVisitCopilotService.noOrderReasonCodes
        .toList(growable: false);
    return SafeArea(
      child: Padding(
        padding: EdgeInsets.only(
          bottom: MediaQuery.of(context).viewInsets.bottom,
          left: 16,
          right: 16,
        ),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          crossAxisAlignment: CrossAxisAlignment.stretch,
          children: <Widget>[
            Flexible(
              child: SingleChildScrollView(
                child: Column(
                  mainAxisSize: MainAxisSize.min,
                  crossAxisAlignment: CrossAxisAlignment.start,
                  children: <Widget>[
                    const Text(
                      'Why was no order placed today?',
                      style: TextStyle(
                        fontWeight: FontWeight.bold,
                        fontSize: 16,
                      ),
                    ),
                    const SizedBox(height: 12),
                    Wrap(
                      spacing: 8,
                      runSpacing: 8,
                      children: <Widget>[
                        for (final String reason in reasons)
                          ChoiceChip(
                            key: ValueKey<String>('no-order-$reason'),
                            label: Text(reasonCodeLabel(reason)),
                            selected: _reason == reason,
                            onSelected: (_) => setState(() {
                              _reason = reason;
                              _message = '';
                            }),
                          ),
                      ],
                    ),
                    const SizedBox(height: 12),
                    TextField(
                      key: const ValueKey<String>('no-order-note'),
                      controller: _note,
                      maxLength: 500,
                      maxLines: 2,
                      textCapitalization: TextCapitalization.sentences,
                      decoration: InputDecoration(
                        labelText: _reason == 'other'
                            ? 'Note (required)'
                            : 'Note (optional)',
                      ),
                    ),
                    FollowUpChips(
                      nextVisit: widget.nextVisit,
                      value: _followUpOn,
                      onChanged: (DateTime? day) =>
                          setState(() => _followUpOn = day),
                    ),
                    const SizedBox(height: 8),
                    if (_message.isNotEmpty)
                      Text(_message, style: const TextStyle(color: Colors.red)),
                  ],
                ),
              ),
            ),
            const SizedBox(height: 8),
            FilledButton(
              key: const ValueKey<String>('no-order-save'),
              onPressed: _save,
              child: const Text('Save no order today'),
            ),
            const SizedBox(height: 16),
          ],
        ),
      ),
    );
  }
}
