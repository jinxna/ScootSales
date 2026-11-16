import 'package:flutter/material.dart';

class BetaBadge extends StatelessWidget {
  const BetaBadge({super.key});

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      label: 'Beta',
      child: Container(
        padding: const EdgeInsets.symmetric(horizontal: 7, vertical: 2),
        decoration: BoxDecoration(
          color: scheme.tertiaryContainer,
          borderRadius: BorderRadius.circular(999),
          border: Border.all(color: scheme.tertiary),
        ),
        child: Text(
          'Beta',
          style: TextStyle(
            color: scheme.onTertiaryContainer,
            fontSize: 10.5,
            height: 1.2,
            fontWeight: FontWeight.w700,
          ),
        ),
      ),
    );
  }
}
