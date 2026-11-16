import 'package:flutter/material.dart';

class TipText extends StatelessWidget {
  const TipText(this.text, {super.key, this.style, this.maxLines});

  final String text;
  final TextStyle? style;
  final int? maxLines;

  @override
  Widget build(BuildContext context) {
    final Widget label = Text(
      text,
      maxLines: maxLines,
      overflow: maxLines == null ? null : TextOverflow.ellipsis,
      style: style,
    );
    final int? lines = maxLines ?? DefaultTextStyle.of(context).maxLines;
    if (lines == null) return label;
    return Tooltip(
      message: text,
      waitDuration: const Duration(milliseconds: 400),
      child: label,
    );
  }
}
