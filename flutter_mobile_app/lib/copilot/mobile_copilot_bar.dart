import 'dart:ui' show ImageFilter;

import 'package:flutter/material.dart';

const Color kCopilotInk = Color(0xFF14231B);
const Color kCopilotMute = Color(0xFF4F5D56);
const Color kCopilotGreen = Color(0xFF2F6F4F);
const Color kCopilotDeepGreen = Color(0xFF1F5A3F);

const BoxDecoration kCopilotBarDecoration = BoxDecoration(
  gradient: LinearGradient(
    begin: Alignment.centerLeft,
    end: Alignment.centerRight,
    colors: <Color>[Color(0xFFD9EEE2), Color(0xFFEAF3ED), Color(0xFFCFE6DA)],
    stops: <double>[0, 0.45, 1],
  ),
);

const double kCopilotBarHeight = 56;

class CopilotBarRow extends StatelessWidget {
  const CopilotBarRow({
    super.key,
    required this.left,
    required this.center,
    required this.right,
  });

  final Widget left;
  final Widget center;
  final Widget right;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      height: kCopilotBarHeight,
      child: Padding(
        padding: const EdgeInsets.symmetric(horizontal: 10),
        child: Row(
          children: <Widget>[
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerLeft,
                child: left,
              ),
            ),
            center,
            Expanded(
              child: FittedBox(
                fit: BoxFit.scaleDown,
                alignment: Alignment.centerRight,
                child: right,
              ),
            ),
          ],
        ),
      ),
    );
  }
}

class CopilotGlassPill extends StatelessWidget {
  const CopilotGlassPill({
    super.key,
    required this.label,
    this.beta = false,
    this.onTap,
    this.semanticsLabel,
  });

  final String label;
  final bool beta;
  final VoidCallback? onTap;
  final String? semanticsLabel;

  @override
  Widget build(BuildContext context) {
    final MediaQueryData media = MediaQuery.of(context);
    final bool solid = media.disableAnimations || media.highContrast;
    const BorderRadius radius = BorderRadius.all(Radius.circular(19));
    final Widget content = Container(
      constraints: const BoxConstraints(minHeight: 38),
      padding: const EdgeInsets.symmetric(horizontal: 12),
      decoration: BoxDecoration(
        borderRadius: radius,
        color: solid ? const Color(0xFFEAF3ED) : null,
        gradient: solid
            ? null
            : const LinearGradient(
                begin: Alignment.topCenter,
                end: Alignment.bottomCenter,
                colors: <Color>[Color(0x99FFFFFF), Color(0x33FFFFFF)],
              ),
        border: Border.all(
          color: solid ? const Color(0xFFB7D3C3) : const Color(0xF2FFFFFF),
        ),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          const Icon(Icons.mic_none, size: 16, color: Color(0xFF1B4F37)),
          const SizedBox(width: 6),
          Text(
            label,
            style: const TextStyle(
              fontSize: 13,
              fontWeight: FontWeight.w600,
              color: Color(0xFF1B4F37),
            ),
          ),
          if (beta) ...<Widget>[
            const SizedBox(width: 6),
            Container(
              padding: const EdgeInsets.symmetric(horizontal: 4),
              decoration: BoxDecoration(
                borderRadius: BorderRadius.circular(5),
                border: Border.all(color: const Color(0x801B4F37)),
              ),
              child: const Text(
                'beta',
                style: TextStyle(
                  fontSize: 12,
                  fontWeight: FontWeight.w700,
                  color: Color(0xFF1B4F37),
                ),
              ),
            ),
          ],
        ],
      ),
    );
    final Widget pill = DecoratedBox(
      decoration: const BoxDecoration(
        borderRadius: radius,
        boxShadow: <BoxShadow>[
          BoxShadow(
            color: Color(0x382F6F4F),
            blurRadius: 10,
            offset: Offset(0, 2),
          ),
        ],
      ),
      child: solid
          ? content
          : ClipRRect(
              borderRadius: radius,
              child: BackdropFilter(
                filter: ImageFilter.blur(sigmaX: 10, sigmaY: 10),
                child: content,
              ),
            ),
    );
    return Semantics(
      container: true,
      button: onTap != null,
      header: onTap == null,
      label: semanticsLabel ?? label,
      excludeSemantics: true,
      onTap: onTap,
      child: GestureDetector(
        behavior: HitTestBehavior.opaque,
        onTap: onTap,
        child: SizedBox(height: 44, child: Center(child: pill)),
      ),
    );
  }
}
