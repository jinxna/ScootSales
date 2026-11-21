import 'package:flutter/material.dart';

import '../models/stop_brief_view.dart';
import '../theme/app_theme.dart';
import '../utils/replenishment_prefill.dart';

class ReplenishmentSuggestionsCard extends StatelessWidget {
  const ReplenishmentSuggestionsCard({
    super.key,
    required this.retailerId,
    required this.reorders,
  });

  static const String title = 'Reorder suggestions';

  final String retailerId;
  final List<BriefReorderView> reorders;

  @override
  Widget build(BuildContext context) {
    if (reorders.isEmpty) return const SizedBox.shrink();
    return Container(
      width: double.infinity,
      padding: const EdgeInsets.all(10),
      decoration: BoxDecoration(
        color: const Color(0xFFEDE9FE),
        borderRadius: BorderRadius.circular(10),
      ),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: [
          const Text(
            title,
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4C1D95),
            ),
          ),
          const SizedBox(height: 2),
          const Text(
            'Tap a product to use its number in the order.',
            style: TextStyle(fontSize: 11, color: AppColors.textGrey),
          ),
          const SizedBox(height: 6),
          for (final BriefReorderView reorder in reorders) ...[
            _ReplenishmentChip(retailerId: retailerId, reorder: reorder),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

class _ReplenishmentChip extends StatelessWidget {
  const _ReplenishmentChip({required this.retailerId, required this.reorder});

  final String retailerId;
  final BriefReorderView reorder;

  Future<void> _handleTap(BuildContext context) async {
    final ScaffoldMessengerState messenger = ScaffoldMessenger.of(context);
    final ReorderChoice choice = await ReplenishmentPrefill.choose(
      retailerId: retailerId,
      productId: reorder.suggestion.productId,
      suggestedQty: reorder.suggestion.suggestedQty,
    );
    final String message;
    switch (choice.result) {
      case ReorderChoiceResult.setInDraft:
        message = choice.quantity < reorder.suggestion.suggestedQty
            ? '${choice.quantity} set for ${reorder.name} in this order. '
                  'That is the limit for this product.'
            : '${choice.quantity} set for ${reorder.name} in this order.';
      case ReorderChoiceResult.waitsForAdd:
        message =
            '${reorder.name} will start at ${choice.quantity} when you add it.';
      case ReorderChoiceResult.notKept:
        message = 'The number could not be kept. Enter it in the order.';
    }
    messenger.showSnackBar(
      SnackBar(content: Text(message), duration: const Duration(seconds: 3)),
    );
  }

  @override
  Widget build(BuildContext context) {
    return Material(
      color: Colors.white,
      borderRadius: BorderRadius.circular(10),
      child: InkWell(
        borderRadius: BorderRadius.circular(10),
        onTap: () => _handleTap(context),
        child: ConstrainedBox(
          constraints: const BoxConstraints(minHeight: 44),
          child: Padding(
            padding: const EdgeInsets.symmetric(horizontal: 10, vertical: 8),
            child: Column(
              mainAxisAlignment: MainAxisAlignment.center,
              crossAxisAlignment: CrossAxisAlignment.start,
              children: [
                Text(
                  reorder.name,
                  style: const TextStyle(
                    fontSize: 12,
                    fontWeight: FontWeight.w600,
                  ),
                ),
                const SizedBox(height: 3),
                Text(
                  reorder.line,
                  style: const TextStyle(
                    fontSize: 12,
                    color: AppColors.textPrimary,
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}
