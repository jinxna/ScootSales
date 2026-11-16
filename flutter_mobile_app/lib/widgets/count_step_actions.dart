import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../theme/app_theme.dart';

class CountStepActions extends StatelessWidget {
  const CountStepActions({
    super.key,
    required this.isSaved,
    required this.onSave,
    required this.onAddItems,
    required this.onContinue,
  });

  final bool isSaved;
  final VoidCallback? onSave;
  final VoidCallback onAddItems;
  final VoidCallback? onContinue;

  @override
  Widget build(BuildContext context) {
    const Size minimumSize = Size.fromHeight(ScootSize.primaryButton);
    final ButtonStyle secondaryStyle = OutlinedButton.styleFrom(
      minimumSize: minimumSize,
      foregroundColor: AppColors.textGreen,
      side: BorderSide(color: AppColors.greenSolid.withValues(alpha: 0.45)),
    );
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: [
        FilledButton.icon(
          style: FilledButton.styleFrom(minimumSize: minimumSize),
          onPressed: onContinue,
          icon: const Icon(Icons.arrow_forward, size: 18),
          label: const Text(
            'Continue to Signature',
            textAlign: TextAlign.center,
          ),
        ),
        const SizedBox(height: 8),
        Row(
          children: [
            Expanded(
              child: OutlinedButton.icon(
                style: onSave == null
                    ? OutlinedButton.styleFrom(minimumSize: minimumSize)
                    : secondaryStyle,
                onPressed: onSave,
                icon: Icon(
                  isSaved ? Icons.check_circle : Icons.save_outlined,
                  size: 18,
                ),
                label: Text(isSaved ? 'Saved' : 'Save'),
              ),
            ),
            const SizedBox(width: 8),
            Expanded(
              child: OutlinedButton.icon(
                style: secondaryStyle,
                onPressed: onAddItems,
                icon: const Icon(Icons.add, size: 18),
                label: const Text('Items'),
              ),
            ),
          ],
        ),
      ],
    );
  }
}
