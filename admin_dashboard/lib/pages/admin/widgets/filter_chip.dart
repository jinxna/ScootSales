import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

class PageFilterChip extends StatelessWidget {
  const PageFilterChip({
    super.key,
    required this.label,
    required this.selected,
    required this.onTap,
    this.count,
    this.icon,
  });

  final String label;
  final bool selected;
  final VoidCallback? onTap;
  final int? count;
  final IconData? icon;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final String text = count == null ? label : '$label $count';
    return Semantics(
      button: true,
      selected: selected,
      label: text,
      excludeSemantics: true,
      child: Material(
        color: selected ? c.brandTint : c.card,
        shape: StadiumBorder(
          side: BorderSide(color: selected ? c.brand : c.line2),
        ),
        child: InkWell(
          customBorder: const StadiumBorder(),
          onTap: onTap,
          child: ConstrainedBox(
            constraints: const BoxConstraints(minHeight: 36),
            child: Padding(
              padding: const EdgeInsets.symmetric(horizontal: 14, vertical: 6),
              child: Row(
                mainAxisSize: MainAxisSize.min,
                children: <Widget>[
                  if (icon != null) ...<Widget>[
                    Icon(
                      icon,
                      size: 16,
                      color: selected ? c.brandText : c.text2,
                    ),
                    const SizedBox(width: 6),
                  ],
                  Flexible(
                    child: Text(
                      text,
                      maxLines: 1,
                      overflow: TextOverflow.ellipsis,
                      style: ScootType.smallStrong.copyWith(
                        color: selected ? c.brandText : c.text2,
                      ),
                    ),
                  ),
                ],
              ),
            ),
          ),
        ),
      ),
    );
  }
}

class PageFilterMenu extends StatelessWidget {
  const PageFilterMenu({
    super.key,
    required this.label,
    required this.value,
    required this.options,
    required this.onChanged,
  });

  final String label;
  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  @override
  Widget build(BuildContext context) {
    final ScootColors c = ScootColors.of(context);
    final String current = options[value] ?? options.values.first;
    return PopupMenuButton<String>(
      tooltip: label,
      onSelected: onChanged,
      itemBuilder: (BuildContext context) => <PopupMenuEntry<String>>[
        for (final MapEntry<String, String> option in options.entries)
          PopupMenuItem<String>(
            value: option.key,
            child: Text(option.value, overflow: TextOverflow.ellipsis),
          ),
      ],
      child: Semantics(
        button: true,
        label: '$label: $current',
        excludeSemantics: true,
        child: Container(
          constraints: const BoxConstraints(minHeight: 36, maxWidth: 260),
          padding: const EdgeInsets.symmetric(horizontal: 12, vertical: 6),
          decoration: BoxDecoration(
            color: c.card,
            border: Border.all(color: c.line2),
            borderRadius: ScootRadius.controlAll,
          ),
          child: Row(
            mainAxisSize: MainAxisSize.min,
            children: <Widget>[
              Text('$label: ', style: ScootType.small.copyWith(color: c.muted)),
              Flexible(
                child: Text(
                  current,
                  maxLines: 1,
                  overflow: TextOverflow.ellipsis,
                  style: ScootType.smallStrong.copyWith(color: c.ink),
                ),
              ),
              const SizedBox(width: 4),
              Icon(ScootIcons.expandMore, size: 18, color: c.muted),
            ],
          ),
        ),
      ),
    );
  }
}
