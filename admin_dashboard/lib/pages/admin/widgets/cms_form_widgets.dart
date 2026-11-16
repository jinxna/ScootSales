import 'package:flutter/material.dart';

class CmsFormLabel extends StatelessWidget {
  const CmsFormLabel({super.key, required this.label, this.helpText});

  final String label;
  final String? helpText;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.only(bottom: 8),
      child: Column(
        crossAxisAlignment: CrossAxisAlignment.start,
        children: <Widget>[
          Text(
            label,
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
          if (helpText != null) ...<Widget>[
            const SizedBox(height: 4),
            Text(
              helpText!,
              style: TextStyle(fontSize: 12, color: scheme.onSurfaceVariant),
            ),
          ],
        ],
      ),
    );
  }
}

class CmsInput extends StatelessWidget {
  const CmsInput({
    super.key,
    required this.controller,
    this.maxLines = 1,
    this.hintText,
    this.label,
    this.validator,
  });

  final TextEditingController controller;
  final int maxLines;
  final String? hintText;
  final String? label;
  final FormFieldValidator<String>? validator;

  @override
  Widget build(BuildContext context) {
    return TextFormField(
      controller: controller,
      maxLines: maxLines,
      validator: validator,
      decoration: InputDecoration(
        hintText: hintText,
        labelText: label,
        isDense: true,
        contentPadding: const EdgeInsets.symmetric(
          horizontal: 12,
          vertical: 12,
        ),
        border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
      ),
    );
  }
}

class CmsDropdown extends StatelessWidget {
  const CmsDropdown({
    super.key,
    required this.value,
    required this.items,
    required this.onChanged,
    this.width = 180,
  });

  final String value;
  final List<String> items;
  final ValueChanged<String?> onChanged;
  final double width;

  @override
  Widget build(BuildContext context) {
    return SizedBox(
      width: width,
      child: DropdownButtonFormField<String>(
        initialValue: value,
        isDense: true,
        decoration: InputDecoration(
          border: OutlineInputBorder(borderRadius: BorderRadius.circular(12)),
          contentPadding: const EdgeInsets.symmetric(
            horizontal: 12,
            vertical: 12,
          ),
        ),
        items: items
            .map(
              (String item) => DropdownMenuItem<String>(
                value: item,
                child: Text(item, overflow: TextOverflow.ellipsis),
              ),
            )
            .toList(),
        onChanged: onChanged,
      ),
    );
  }
}

class PrimaryCmsButton extends StatelessWidget {
  const PrimaryCmsButton({
    super.key,
    required this.label,
    required this.onTap,
    this.icon,
    this.isPending = false,
  });

  final String label;
  final VoidCallback? onTap;
  final IconData? icon;
  final bool isPending;

  @override
  Widget build(BuildContext context) {
    return FilledButton(
      onPressed: isPending ? null : onTap,
      style: FilledButton.styleFrom(
        padding: const EdgeInsets.symmetric(horizontal: 16, vertical: 12),
        shape: RoundedRectangleBorder(borderRadius: BorderRadius.circular(12)),
      ),
      child: isPending
          ? const Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                SizedBox(
                  width: 18,
                  height: 18,
                  child: CircularProgressIndicator(strokeWidth: 2),
                ),
                SizedBox(width: 8),
                Text('Saving...'),
              ],
            )
          : Row(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                if (icon != null) ...<Widget>[
                  Icon(icon, size: 18),
                  const SizedBox(width: 8),
                ],
                Text(label),
              ],
            ),
    );
  }
}

class CmsMiniToolbar extends StatelessWidget {
  const CmsMiniToolbar({super.key, required this.itemCount});

  final int itemCount;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.fromLTRB(12, 12, 12, 12),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        border: Border(bottom: BorderSide(color: scheme.outlineVariant)),
      ),
      child: Row(
        children: <Widget>[
          Text(
            'Display ($itemCount)',
            style: TextStyle(
              fontSize: 13,
              color: scheme.onSurface,
              fontWeight: FontWeight.w600,
            ),
          ),
        ],
      ),
    );
  }
}
