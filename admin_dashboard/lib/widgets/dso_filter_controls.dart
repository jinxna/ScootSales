import 'package:flutter/material.dart';
import 'package:scoot_design/scoot_design.dart';

import '../theme/dso_theme.dart';

class DsoFilterMetrics {
  const DsoFilterMetrics._();

  static const double height = 36;
  static const double radius = DsoTokens.rMd;
  static const double fontSize = 13;
  static const double iconSize = 16;
  static const double gap = 8;
}

InputDecoration dsoFilterDropdownDecoration(
  BuildContext context, {
  Widget? prefixIcon,
}) {
  final DsoColors dso = context.dso;
  final OutlineInputBorder border = OutlineInputBorder(
    borderRadius: BorderRadius.circular(DsoFilterMetrics.radius),
    borderSide: BorderSide(color: Theme.of(context).colorScheme.outlineVariant),
  );
  return InputDecoration(
    isDense: true,
    filled: true,
    fillColor: dso.card,
    contentPadding: const EdgeInsets.symmetric(horizontal: 12, vertical: 8),
    border: border,
    enabledBorder: border,
    disabledBorder: border,
    prefixIcon: prefixIcon,
    prefixIconConstraints: const BoxConstraints(minWidth: 34, minHeight: 16),
  );
}

class DsoFilterButton extends StatelessWidget {
  const DsoFilterButton({
    super.key,
    required this.label,
    required this.onPressed,
    this.active = false,
    this.icon,
    this.showChevron = true,
  });

  final String label;
  final VoidCallback? onPressed;

  final bool active;
  final IconData? icon;
  final bool showChevron;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Semantics(
      selected: active,
      child: OutlinedButton(
        onPressed: onPressed,
        style: OutlinedButton.styleFrom(
          minimumSize: const Size(0, DsoFilterMetrics.height),
          maximumSize: const Size(double.infinity, DsoFilterMetrics.height),
          padding: const EdgeInsets.symmetric(horizontal: 12),
          tapTargetSize: MaterialTapTargetSize.shrinkWrap,
          visualDensity: VisualDensity.standard,
          shape: RoundedRectangleBorder(
            borderRadius: BorderRadius.circular(DsoFilterMetrics.radius),
          ),
          side: BorderSide(color: active ? dso.accent : scheme.outlineVariant),
          backgroundColor: active ? dso.brandSurface : dso.card,
          foregroundColor: active ? dso.accentText : dso.body,
          textStyle: const TextStyle(
            fontSize: DsoFilterMetrics.fontSize,
            fontWeight: FontWeight.w500,
          ),
        ),
        child: Row(
          mainAxisSize: MainAxisSize.min,
          children: <Widget>[
            if (icon != null) ...<Widget>[
              ExcludeSemantics(
                child: Icon(icon, size: DsoFilterMetrics.iconSize),
              ),
              const SizedBox(width: 6),
            ],
            Flexible(
              child: Text(label, maxLines: 1, overflow: TextOverflow.ellipsis),
            ),
            if (showChevron) ...<Widget>[
              const SizedBox(width: 4),
              ExcludeSemantics(
                child: Icon(
                  ScootIcons.expandMore,
                  size: DsoFilterMetrics.iconSize,
                  color: dso.muted,
                ),
              ),
            ],
          ],
        ),
      ),
    );
  }
}

class DsoFilterSearchField extends StatelessWidget {
  const DsoFilterSearchField({
    super.key,
    required this.controller,
    required this.hintText,
    this.focusNode,
    this.width = 300,
    this.onChanged,
    this.shortcutKey,
  });

  final TextEditingController controller;
  final String hintText;
  final FocusNode? focusNode;
  final double width;
  final ValueChanged<String>? onChanged;

  final String? shortcutKey;

  @override
  Widget build(BuildContext context) {
    final DsoColors dso = context.dso;
    return SizedBox(
      width: width,
      height: DsoFilterMetrics.height,
      child: ValueListenableBuilder<TextEditingValue>(
        valueListenable: controller,
        builder: (BuildContext context, TextEditingValue value, Widget? _) {
          Widget? suffix;
          if (value.text.isNotEmpty) {
            suffix = IconButton(
              tooltip: 'Clear search',
              icon: const Icon(ScootIcons.close, size: DsoFilterMetrics.iconSize),
              visualDensity: VisualDensity.compact,
              constraints: const BoxConstraints.tightFor(
                width: DsoFilterMetrics.height - 4,
                height: DsoFilterMetrics.height - 4,
              ),
              onPressed: () {
                controller.clear();
                onChanged?.call('');
              },
            );
          } else if (shortcutKey != null) {
            suffix = ExcludeSemantics(
              child: Padding(
                padding: const EdgeInsets.only(right: 8),
                child: Center(
                  widthFactor: 1,
                  child: Container(
                    padding: const EdgeInsets.symmetric(
                      horizontal: 6,
                      vertical: 1,
                    ),
                    decoration: BoxDecoration(
                      border: Border.all(color: dso.hairline),
                      borderRadius: BorderRadius.circular(4),
                    ),
                    child: Text(
                      shortcutKey!,
                      style: TextStyle(fontSize: 11, color: dso.muted),
                    ),
                  ),
                ),
              ),
            );
          }
          return TextField(
            controller: controller,
            focusNode: focusNode,
            onChanged: onChanged,
            style: const TextStyle(fontSize: DsoFilterMetrics.fontSize),
            decoration: InputDecoration(
              isDense: true,
              hintText: hintText,
              hintStyle: TextStyle(
                fontSize: DsoFilterMetrics.fontSize,
                color: dso.muted,
              ),
              prefixIcon: const Icon(
                ScootIcons.search,
                size: DsoFilterMetrics.iconSize,
              ),
              prefixIconConstraints: const BoxConstraints(
                minWidth: DsoFilterMetrics.height,
                minHeight: DsoFilterMetrics.height,
              ),
              contentPadding: const EdgeInsets.symmetric(
                horizontal: 10,
                vertical: 10,
              ),
              suffixIcon: suffix,
              suffixIconConstraints: const BoxConstraints(
                minWidth: DsoFilterMetrics.height,
                minHeight: DsoFilterMetrics.height,
              ),
            ),
          );
        },
      ),
    );
  }
}

class DsoFilterMenu extends StatelessWidget {
  const DsoFilterMenu({
    super.key,
    required this.value,
    required this.options,
    required this.onChanged,
    this.defaultValue = 'all',
    this.maxButtonWidth = 240,
    this.label,
  });

  final String value;
  final Map<String, String> options;
  final ValueChanged<String> onChanged;

  final String defaultValue;
  final double maxButtonWidth;

  final String? label;

  @override
  Widget build(BuildContext context) {
    final String current = options.containsKey(value) ? value : defaultValue;
    return MenuAnchor(
      style: const MenuStyle(
        maximumSize: WidgetStatePropertyAll<Size>(Size(320, 360)),
      ),
      menuChildren: options.entries
          .map(
            (MapEntry<String, String> o) => MenuItemButton(
              style: MenuItemButton.styleFrom(
                minimumSize: const Size(0, DsoFilterMetrics.height),
                visualDensity: VisualDensity.standard,
                tapTargetSize: MaterialTapTargetSize.shrinkWrap,
              ),
              leadingIcon: Icon(
                o.key == current ? ScootIcons.check : null,
                size: DsoFilterMetrics.iconSize,
              ),
              onPressed: () => onChanged(o.key),
              child: Text(
                o.value,
                style: const TextStyle(fontSize: DsoFilterMetrics.fontSize),
              ),
            ),
          )
          .toList(growable: false),
      builder: (BuildContext context, MenuController controller, Widget? _) {
        return ConstrainedBox(
          constraints: BoxConstraints(maxWidth: maxButtonWidth),
          child: DsoFilterButton(
            label: label != null && current != defaultValue
                ? '$label: ${options[current] ?? current}'
                : options[current] ?? current,
            active: current != defaultValue,
            onPressed: () =>
                controller.isOpen ? controller.close() : controller.open(),
          ),
        );
      },
    );
  }
}
