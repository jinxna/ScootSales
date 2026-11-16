import 'package:flutter/material.dart';

import 'package:scoot_design/scoot_design.dart';

import '../../theme/dso_theme.dart';

class CatalogueLoading extends StatelessWidget {
  const CatalogueLoading({super.key, this.rows = 8, this.onRetry});

  final int rows;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) {
    final Widget skeleton = ExcludeSemantics(
      child: Column(
        children: <Widget>[
          for (int i = 0; i < rows; i++)
            const Padding(
              padding: EdgeInsets.symmetric(vertical: 8),
              child: ScootSkeleton(height: 20),
            ),
        ],
      ),
    );
    if (onRetry == null) {
      return Semantics(label: 'Loading', child: skeleton);
    }
    return ScootLoadingState(
      onRetry: onRetry!,
      semanticLabel: 'Loading',
      skeleton: skeleton,
    );
  }
}

class _Message extends StatelessWidget {
  const _Message({
    required this.title,
    required this.message,
    this.action,
    this.icon,
  });

  final String title;
  final String message;
  final Widget? action;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return Center(
      child: ConstrainedBox(
        constraints: const BoxConstraints(maxWidth: 420),
        child: Padding(
          padding: const EdgeInsets.all(24),
          child: Column(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              if (icon != null) ...<Widget>[
                Icon(icon, size: 28, color: dso.subtle),
                const SizedBox(height: 12),
              ],
              Text(
                title,
                textAlign: TextAlign.center,
                style: TextStyle(
                  fontSize: 16,
                  fontWeight: FontWeight.w600,
                  color: dso.ink,
                ),
              ),
              const SizedBox(height: 6),
              Text(
                message,
                textAlign: TextAlign.center,
                style: TextStyle(fontSize: 14, color: dso.muted, height: 1.4),
              ),
              if (action != null) ...<Widget>[
                const SizedBox(height: 16),
                action!,
              ],
            ],
          ),
        ),
      ),
    );
  }
}

class CatalogueEmpty extends StatelessWidget {
  const CatalogueEmpty({
    super.key,
    required this.title,
    required this.message,
    this.action,
  });

  final String title;
  final String message;
  final Widget? action;

  @override
  Widget build(BuildContext context) =>
      _Message(title: title, message: message, action: action);
}

class CatalogueNoResults extends StatelessWidget {
  const CatalogueNoResults({super.key, required this.onClear});

  final VoidCallback onClear;

  @override
  Widget build(BuildContext context) => _Message(
    title: 'No results',
    message: 'Nothing matches the current search and filters.',
    action: OutlinedButton(
      onPressed: onClear,
      child: const Text('Clear search and filters'),
    ),
  );
}

class CatalogueError extends StatelessWidget {
  const CatalogueError({super.key, required this.message, this.onRetry});

  final String message;
  final VoidCallback? onRetry;

  @override
  Widget build(BuildContext context) => _Message(
    icon: ScootIcons.error,
    title: 'Could not load this list',
    message: message,
    action: onRetry == null
        ? null
        : OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
  );
}

class CataloguePermissionDenied extends StatelessWidget {
  const CataloguePermissionDenied({super.key});

  @override
  Widget build(BuildContext context) => const _Message(
    icon: ScootIcons.lock,
    title: 'You do not have access to this list',
    message:
        'Your role cannot view this data. Ask an administrator to update '
        'your permissions.',
  );
}
