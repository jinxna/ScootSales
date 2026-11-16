import 'dart:async';

import 'package:flutter/material.dart';

import '../tokens/colors.dart';
import '../tokens/icons.dart';
import '../tokens/metrics.dart';

class ScootSkeleton extends StatelessWidget {
  const ScootSkeleton({
    super.key,
    this.width,
    required this.height,
    this.radius = 6,
  });

  final double? width;
  final double height;
  final double radius;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: width,
      height: height,
      decoration: BoxDecoration(
        color: ScootColors.of(context).skeleton,
        borderRadius: BorderRadius.circular(radius),
      ),
    );
  }
}

class ScootSkeletonLines extends StatelessWidget {
  const ScootSkeletonLines({
    super.key,
    this.widthFactors = const <double>[0.9, 0.7, 0.5],
    this.lineHeight = 12,
    this.gap = 10,
  });

  final List<double> widthFactors;
  final double lineHeight;
  final double gap;

  @override
  Widget build(BuildContext context) {
    return Column(
      crossAxisAlignment: CrossAxisAlignment.start,
      mainAxisSize: MainAxisSize.min,
      children: <Widget>[
        for (int i = 0; i < widthFactors.length; i++) ...<Widget>[
          if (i > 0) SizedBox(height: gap),
          FractionallySizedBox(
            widthFactor: widthFactors[i],
            child: ScootSkeleton(height: lineHeight),
          ),
        ],
      ],
    );
  }
}

class ScootLoadingState extends StatefulWidget {
  const ScootLoadingState({
    super.key,
    required this.skeleton,
    required this.onRetry,
    this.stillLoadingAfter = ScootTiming.stillLoadingAfter,
    this.message = 'Still loading. The connection may be slow.',
    this.semanticLabel = 'Loading',
  });

  final Widget skeleton;
  final VoidCallback onRetry;
  final Duration stillLoadingAfter;
  final String message;
  final String semanticLabel;

  @override
  State<ScootLoadingState> createState() => _ScootLoadingStateState();
}

class _ScootLoadingStateState extends State<ScootLoadingState> {
  Timer? _timer;
  bool _slow = false;

  @override
  void initState() {
    super.initState();
    _start();
  }

  void _start() {
    _timer?.cancel();
    _timer = Timer(widget.stillLoadingAfter, () {
      if (mounted) {
        setState(() => _slow = true);
      }
    });
  }

  void _retry() {
    setState(() => _slow = false);
    _start();
    widget.onRetry();
  }

  @override
  void dispose() {
    _timer?.cancel();
    super.dispose();
  }

  @override
  Widget build(BuildContext context) {
    return Column(
      mainAxisSize: MainAxisSize.min,
      crossAxisAlignment: CrossAxisAlignment.stretch,
      children: <Widget>[
        if (_slow) ...<Widget>[
          ScootStillLoadingBar(message: widget.message, onRetry: _retry),
          const SizedBox(height: 8),
        ],
        Flexible(
          child: Semantics(
            label: widget.semanticLabel,
            excludeSemantics: true,
            child: widget.skeleton,
          ),
        ),
      ],
    );
  }
}

class ScootStillLoadingBar extends StatelessWidget {
  const ScootStillLoadingBar({
    super.key,
    required this.message,
    required this.onRetry,
  });

  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ScootToneColors tone = ScootColors.of(context).neutral;
    return Semantics(
      liveRegion: true,
      container: true,
      child: Column(
        mainAxisSize: MainAxisSize.min,
        crossAxisAlignment: CrossAxisAlignment.stretch,
        children: <Widget>[
          Container(
            padding: const EdgeInsets.fromLTRB(14, 12, 14, 12),
            decoration: BoxDecoration(
              color: tone.noteBackground,
              border: Border.all(color: tone.border),
              borderRadius: ScootRadius.noteAll,
            ),
            child: Row(
              children: <Widget>[
                Icon(ScootIcons.hourglass, size: 18, color: tone.noteText),
                const SizedBox(width: 10),
                Expanded(
                  child: Text(
                    message,
                    style: ScootType.body.copyWith(color: tone.noteText),
                  ),
                ),
              ],
            ),
          ),
          const SizedBox(height: 8),
          OutlinedButton(onPressed: onRetry, child: const Text('Retry')),
        ],
      ),
    );
  }
}

class ScootEmptyState extends StatelessWidget {
  const ScootEmptyState({
    super.key,
    required this.title,
    this.message,
    this.icon = ScootIcons.inbox,
    this.action,
  });

  final String title;
  final String? message;
  final IconData icon;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return _StateBody(
      iconTile: _IconTile(
        icon: icon,
        background: c.neutral.background,
        foreground: c.text2,
      ),
      title: title,
      message: message,
      action: action,
    );
  }
}

class ScootErrorState extends StatelessWidget {
  const ScootErrorState({
    super.key,
    this.title = 'This could not load',
    this.message = 'Check your connection, then try again.',
    required this.onRetry,
  });

  final String title;
  final String message;
  final VoidCallback onRetry;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Semantics(
      liveRegion: true,
      container: true,
      child: _StateBody(
        iconTile: _IconTile(
          icon: ScootIcons.error,
          background: c.danger.background,
          foreground: c.danger.foreground,
        ),
        title: title,
        message: message,
        action: FilledButton.icon(
          onPressed: onRetry,
          icon: const Icon(ScootIcons.refresh, size: 18),
          label: const Text('Retry'),
        ),
      ),
    );
  }
}

class _StateBody extends StatelessWidget {
  const _StateBody({
    required this.iconTile,
    required this.title,
    required this.message,
    required this.action,
  });

  final Widget iconTile;
  final String title;
  final String? message;
  final Widget? action;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 24, vertical: 40),
      child: Column(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          iconTile,
          const SizedBox(height: 12),
          Text(
            title,
            textAlign: TextAlign.center,
            style: ScootType.section.copyWith(color: c.ink),
          ),
          if (message != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              message!,
              textAlign: TextAlign.center,
              style: ScootType.body.copyWith(color: c.muted),
            ),
          ],
          if (action != null) ...<Widget>[const SizedBox(height: 14), action!],
        ],
      ),
    );
  }
}

class _IconTile extends StatelessWidget {
  const _IconTile({
    required this.icon,
    required this.background,
    required this.foreground,
  });

  final IconData icon;
  final Color background;
  final Color foreground;

  @override
  Widget build(BuildContext context) {
    return Container(
      width: 48,
      height: 48,
      decoration: BoxDecoration(
        color: background,
        borderRadius: ScootRadius.cardAll,
      ),
      child: Icon(icon, size: 24, color: foreground),
    );
  }
}

class ScootLongText extends StatelessWidget {
  const ScootLongText(
    this.text, {
    super.key,
    this.maxLines = 2,
    this.style,
    this.textAlign,
  });

  final String text;
  final int maxLines;
  final TextStyle? style;
  final TextAlign? textAlign;

  @override
  Widget build(BuildContext context) {
    return Semantics(
      label: text,
      excludeSemantics: true,
      child: Text(
        text,
        maxLines: maxLines,
        overflow: TextOverflow.ellipsis,
        softWrap: true,
        textAlign: textAlign,
        style: style,
      ),
    );
  }
}
