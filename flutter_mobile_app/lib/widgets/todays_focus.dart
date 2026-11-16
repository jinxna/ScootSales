import 'package:flutter/material.dart';

import '../models/visit_brief.dart';

class TodaysFocusCard extends StatelessWidget {
  const TodaysFocusCard({super.key, required this.brief});

  static const String title = "TODAY'S FOCUS";

  final VisitBrief brief;

  @override
  Widget build(BuildContext context) {
    final List<VisitFocusItem> items = brief.fieldFocusItems;
    if (items.isEmpty && !brief.hasNoPriorityIssues) {
      return const SizedBox.shrink();
    }
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: Colors.white,
        borderRadius: BorderRadius.circular(10),
        border: Border.all(color: const Color(0xFFDDD6FE)),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          const Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.bold,
              letterSpacing: 0.6,
              color: Color(0xFF4C1D95),
            ),
          ),
          const SizedBox(height: 6),
          if (items.isEmpty) ...<Widget>[
            Text(
              brief.noPriorityHeadline,
              style: const TextStyle(fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 2),
            Text(
              brief.noPriorityBody,
              style: TextStyle(
                fontSize: 12,
                color: Colors.deepPurple.shade700,
              ),
            ),
          ] else
            for (int index = 0; index < items.length; index++) ...<Widget>[
              if (index > 0) const Divider(height: 14),
              FocusItemTile(item: items[index], position: index + 1),
            ],
        ],
      ),
    );
  }
}

class FocusItemTile extends StatelessWidget {
  const FocusItemTile({
    super.key,
    required this.item,
    required this.position,
  });

  final VisitFocusItem item;
  final int position;

  static String previousOutcomeLine(VisitFocusItem item) {
    final FocusPreviousOutcome? previous = item.previousOutcome;
    if (previous == null || previous.isEmpty) return '';
    if (item.occurrenceCount > 1) {
      return 'Raised before (${item.occurrenceCount}x). Your last answer: '
          '${previous.label}.';
    }
    return 'Your last answer: ${previous.label}.';
  }

  @override
  Widget build(BuildContext context) {
    final String previousLine = previousOutcomeLine(item);
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      children: <Widget>[
        Text(
          '$position. ${item.title}',
          style: const TextStyle(fontWeight: FontWeight.w600),
        ),
        if (item.signal.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(item.signal, style: const TextStyle(fontSize: 12)),
        ],
        if (previousLine.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            previousLine,
            style: TextStyle(fontSize: 12, color: Colors.deepPurple.shade400),
          ),
        ],
        if (item.action.isNotEmpty) ...<Widget>[
          const SizedBox(height: 2),
          Text(
            'Action: ${item.action}',
            style: const TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4C1D95),
            ),
          ),
        ],
      ],
    );
  }
}
