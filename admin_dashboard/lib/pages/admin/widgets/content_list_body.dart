import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../../../widgets/page_states.dart';

class ContentListBody extends StatelessWidget {
  const ContentListBody({
    super.key,
    required this.label,
    required this.phase,
    required this.pages,
    required this.onRetry,
    required this.onEdit,
    required this.saving,
    this.error,
  });

  final String label;
  final ScootLoadPhase phase;
  final List<Map<String, dynamic>> pages;
  final VoidCallback onRetry;
  final ValueChanged<Map<String, dynamic>> onEdit;
  final bool saving;
  final Object? error;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    switch (phase) {
      case ScootLoadPhase.loading:
        return Padding(
          padding: const EdgeInsets.all(20),
          child: ScootLoadingState(
            onRetry: onRetry,
            skeleton: const ScootSkeletonLines(
              widthFactors: <double>[0.7, 0.5, 0.8, 0.6],
            ),
          ),
        );
      case ScootLoadPhase.error:
        return Center(
          child: PageErrorState(
            error: error,
            title: 'Could not load $label',
            onRetry: onRetry,
          ),
        );
      case ScootLoadPhase.ready:
        if (pages.isEmpty) {
          return Center(
            child: ScootEmptyState(
              title: 'No $label yet',
              message: 'Add one with the form to see it here.',
            ),
          );
        }
        return ListView.separated(
          itemCount: pages.length,
          separatorBuilder: (_, _) => Divider(height: 1, color: c.hair),
          itemBuilder: (BuildContext context, int index) {
            final Map<String, dynamic> page = pages[index];
            final bool hidden =
                '${page['status'] ?? ''}'.toLowerCase() == 'hidden';
            return Container(
              constraints: const BoxConstraints(minHeight: 56),
              padding: const EdgeInsets.symmetric(horizontal: 20, vertical: 8),
              child: Row(
                children: <Widget>[
                  Expanded(
                    child: Column(
                      crossAxisAlignment: CrossAxisAlignment.start,
                      children: <Widget>[
                        ScootLongText(
                          page['title'] as String? ?? '-',
                          maxLines: 1,
                          style: ScootType.bodyStrong.copyWith(color: c.ink),
                        ),
                        Text(
                          'Position ${page['position'] ?? 0}',
                          style: ScootType.small.copyWith(color: c.muted),
                        ),
                      ],
                    ),
                  ),
                  if (hidden) ...<Widget>[
                    const ScootBadge(label: 'Hidden'),
                    const SizedBox(width: 12),
                  ],
                  OutlinedButton(
                    onPressed: saving ? null : () => onEdit(page),
                    child: const Text('Edit'),
                  ),
                ],
              ),
            );
          },
        );
    }
  }
}
