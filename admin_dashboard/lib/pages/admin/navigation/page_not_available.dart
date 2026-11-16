import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

const String pageNotAvailableTitle = 'Page not available';
const String pageNotAvailableMessage =
    'This page is not available for your role';

class PageNotAvailable extends StatelessWidget {
  const PageNotAvailable({
    super.key,
    required this.requestedKey,
    required this.landingLabel,
    required this.onOpenLanding,
  });

  final String requestedKey;
  final String landingLabel;
  final VoidCallback onOpenLanding;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 520),
        child: Column(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            Icon(ScootIcons.lock, size: 36, color: scheme.onSurfaceVariant),
            const SizedBox(height: 14),
            Text(
              pageNotAvailableMessage,
              textAlign: TextAlign.center,
              style: const TextStyle(fontSize: 18, fontWeight: FontWeight.w600),
            ),
            const SizedBox(height: 8),
            Text(
              'The address "$requestedKey" is not a page this account can open.',
              textAlign: TextAlign.center,
              style: TextStyle(color: scheme.onSurfaceVariant, height: 1.5),
            ),
            const SizedBox(height: 18),
            FilledButton(
              onPressed: onOpenLanding,
              child: Text('Go to $landingLabel'),
            ),
          ],
        ),
      ),
    );
  }
}
