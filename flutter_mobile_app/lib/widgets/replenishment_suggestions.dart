import 'package:flutter/material.dart';

import '../models/visit_brief.dart';
import '../theme/app_theme.dart';
import '../utils/replenishment_prefill.dart';

class ReplenishmentSuggestionsCard extends StatelessWidget {
  const ReplenishmentSuggestionsCard({
    super.key,
    required this.retailerId,
    required this.suggestions,
    this.productNames = const <String, String>{},
  });

  final String retailerId;
  final List<ReplenishmentSuggestion> suggestions;

  final Map<String, String> productNames;

  @override
  Widget build(BuildContext context) {
    if (suggestions.isEmpty) return const SizedBox.shrink();
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
            'Replenishment suggestions',
            style: TextStyle(
              fontSize: 12,
              fontWeight: FontWeight.w600,
              color: Color(0xFF4C1D95),
            ),
          ),
          const SizedBox(height: 6),
          for (final suggestion in suggestions) ...[
            _ReplenishmentChip(
              retailerId: retailerId,
              suggestion: suggestion,
              productName:
                  productNames[suggestion.productId] ??
                  (suggestion.productName.isEmpty
                      ? null
                      : suggestion.productName),
            ),
            const SizedBox(height: 6),
          ],
        ],
      ),
    );
  }
}

class _ReplenishmentChip extends StatelessWidget {
  const _ReplenishmentChip({
    required this.retailerId,
    required this.suggestion,
    required this.productName,
  });

  final String retailerId;
  final ReplenishmentSuggestion suggestion;
  final String? productName;

  Color get _confidenceColor {
    switch (suggestion.confidenceLabel) {
      case 'high':
        return const Color(0xFF067647);
      case 'medium':
        return const Color(0xFFB54708);
      default:
        return const Color(0xFF667085);
    }
  }

  void _handleTap(BuildContext context) {
    ReplenishmentPrefill.stash(
      retailerId: retailerId,
      productId: suggestion.productId,
      suggestedQty: suggestion.suggestedQty,
    );
    ScaffoldMessenger.of(context).showSnackBar(
      SnackBar(
        content: Text(
          'Qty ${suggestion.suggestedQty} ready to prefill in the cart for ${productName ?? suggestion.productId}.',
        ),
        duration: const Duration(seconds: 3),
      ),
    );
  }

  @override
  Widget build(BuildContext context) {
    final String label = productName ?? suggestion.productId;
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
                Row(
                  children: [
                    Expanded(
                      child: Text(
                        label,
                        style: const TextStyle(
                          fontSize: 12,
                          fontWeight: FontWeight.w600,
                        ),
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                      ),
                    ),
                    const SizedBox(width: 6),
                    Container(
                      padding: const EdgeInsets.symmetric(
                        horizontal: 8,
                        vertical: 2,
                      ),
                      decoration: BoxDecoration(
                        color: _confidenceColor.withValues(alpha: 0.12),
                        borderRadius: BorderRadius.circular(999),
                      ),
                      child: Text(
                        'Suggest ${suggestion.suggestedQty} • ${suggestion.confidenceLabel}',
                        style: TextStyle(
                          fontSize: 11,
                          fontWeight: FontWeight.w700,
                          color: _confidenceColor,
                        ),
                      ),
                    ),
                  ],
                ),
                if (suggestion.rationale.isNotEmpty) ...[
                  const SizedBox(height: 3),
                  Tooltip(
                    message: suggestion.rationale,
                    child: Text(
                      suggestion.rationale,
                      style: const TextStyle(
                        fontSize: 11,
                        color: AppColors.textGrey,
                      ),
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                    ),
                  ),
                ],
              ],
            ),
          ),
        ),
      ),
    );
  }
}
