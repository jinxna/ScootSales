import 'package:flutter/material.dart';

const int kLongNameMaxLines = 2;

class LongNameText extends StatelessWidget {
  const LongNameText(this.name, {super.key, this.style});

  final String name;
  final TextStyle? style;

  @override
  Widget build(BuildContext context) {
    return Tooltip(
      message: name,
      child: Text(
        name,
        maxLines: kLongNameMaxLines,
        overflow: TextOverflow.ellipsis,
        style: style,
      ),
    );
  }
}
