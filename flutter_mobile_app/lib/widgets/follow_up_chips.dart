import 'package:flutter/material.dart';
import 'package:intl/intl.dart';

import '../models/follow_up_promise.dart';
import '../models/stop_brief_view.dart';
import '../theme/app_theme.dart';

typedef MarkFollowUpDone = Future<void> Function(FollowUpPromise promise);

class FollowUpChips extends StatelessWidget {
  const FollowUpChips({
    super.key,
    required this.nextVisit,
    required this.value,
    required this.onChanged,
  });

  final DateTime? nextVisit;
  final DateTime? value;
  final ValueChanged<DateTime?> onChanged;

  static String _day(DateTime day) => DateFormat('EEE d MMM').format(day);

  Future<void> _pick(BuildContext context) async {
    final DateTime now = DateTime.now();
    final DateTime today = DateTime(now.year, now.month, now.day);
    final DateTime? picked = await showDatePicker(
      context: context,
      initialDate: value ?? today.add(const Duration(days: 1)),
      firstDate: today,
      lastDate: today.add(const Duration(days: followUpMaxDaysAhead)),
      helpText: 'Follow up on',
    );
    if (picked != null) onChanged(picked);
  }

  @override
  Widget build(BuildContext context) {
    final DateTime? next = nextVisit;
    final DateTime? chosen = value;
    final bool nextChosen = next != null && chosen == next;
    final bool pickedChosen = chosen != null && !nextChosen;
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        const Text(
          'Follow up on (optional)',
          style: TextStyle(fontSize: 12, color: AppColors.textGrey),
        ),
        const SizedBox(height: 6),
        Wrap(
          spacing: 8,
          runSpacing: 8,
          children: <Widget>[
            if (next != null)
              ChoiceChip(
                key: const ValueKey<String>('follow-up-next-visit'),
                label: Text('Next visit day: ${_day(next)}'),
                selected: nextChosen,
                onSelected: (bool on) => onChanged(on ? next : null),
              ),
            ChoiceChip(
              key: const ValueKey<String>('follow-up-pick-date'),
              label: Text(
                pickedChosen ? 'Pick a date: ${_day(chosen)}' : 'Pick a date',
              ),
              selected: pickedChosen,
              onSelected: (bool on) {
                if (on) {
                  _pick(context);
                } else {
                  onChanged(null);
                }
              },
            ),
          ],
        ),
      ],
    );
  }
}

class BriefFollowUpLine extends StatefulWidget {
  const BriefFollowUpLine({super.key, required this.view, this.onMarkDone});

  final StopBriefView view;
  final MarkFollowUpDone? onMarkDone;

  @override
  State<BriefFollowUpLine> createState() => _BriefFollowUpLineState();
}

class _BriefFollowUpLineState extends State<BriefFollowUpLine> {
  bool _saving = false;

  Future<void> _markDone(FollowUpPromise promise) async {
    final MarkFollowUpDone? markDone = widget.onMarkDone;
    if (_saving || markDone == null) return;
    setState(() => _saving = true);
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    try {
      await markDone(promise);
    } catch (error, stack) {
      FlutterError.reportError(
        FlutterErrorDetails(
          exception: error,
          stack: stack,
          library: 'follow-up',
        ),
      );
      messenger.showSnackBar(
        const SnackBar(
          content: Text('The follow-up could not be marked as done.'),
        ),
      );
    } finally {
      if (mounted) setState(() => _saving = false);
    }
  }

  @override
  Widget build(BuildContext context) {
    final FollowUpPromise? promise = widget.view.followUp;
    if (promise == null) return const SizedBox.shrink();
    return Padding(
      padding: const EdgeInsets.only(bottom: 4),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            widget.view.followUpLine,
            style: const TextStyle(fontSize: 12, fontWeight: FontWeight.w600),
          ),
          if (widget.onMarkDone != null && widget.view.canMarkFollowUpDone)
            TextButton.icon(
              key: const ValueKey<String>('follow-up-mark-done'),
              onPressed: _saving ? null : () => _markDone(promise),
              icon: const Icon(Icons.check_circle_outline, size: 17),
              label: const Text('Mark as done'),
            ),
        ],
      ),
    );
  }
}
