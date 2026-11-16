import 'package:flutter/material.dart';

class SimpleContentEditor extends StatelessWidget {
  const SimpleContentEditor({super.key, required this.controller});

  final TextEditingController controller;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Column(
        children: <Widget>[
          Container(
            color: scheme.surfaceContainerHighest,
            padding: const EdgeInsets.all(6),
            child: Wrap(
              spacing: 6,
              runSpacing: 6,
              crossAxisAlignment: WrapCrossAlignment.center,
              children: <Widget>[
                _toolbarDropdown(context, label: 'Styles'),
                _toolbarDropdown(context, label: 'Format'),
                _toolbarDropdown(context, label: 'Arial'),
                _toolbarDropdown(context, label: '12'),
                _toolbarButton(context, icon: Icons.format_bold),
                _toolbarButton(context, icon: Icons.format_italic),
                _toolbarButton(context, icon: Icons.format_underlined),
                _toolbarButton(context, icon: Icons.format_align_left),
                _toolbarButton(context, icon: Icons.format_align_center),
                _toolbarButton(context, icon: Icons.format_align_right),
                _toolbarButton(context, icon: Icons.link),
                _toolbarButton(context, icon: Icons.image_outlined),
                _toolbarButton(context, icon: Icons.format_list_bulleted),
              ],
            ),
          ),
          SizedBox(
            height: 110,
            child: TextField(
              controller: controller,
              maxLines: null,
              expands: true,
              decoration: const InputDecoration(
                hintText: 'Enter product description here...',
                contentPadding: EdgeInsets.all(12),
                border: InputBorder.none,
              ),
            ),
          ),
        ],
      ),
    );
  }

  Widget _toolbarDropdown(BuildContext context, {required String label}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      height: 28,
      padding: const EdgeInsets.symmetric(horizontal: 8),
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Row(
        mainAxisSize: MainAxisSize.min,
        children: <Widget>[
          Text(label, style: TextStyle(fontSize: 12, color: scheme.onSurface)),
          Icon(Icons.arrow_drop_down, size: 18, color: scheme.onSurfaceVariant),
        ],
      ),
    );
  }

  Widget _toolbarButton(BuildContext context, {required IconData icon}) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      width: 28,
      height: 28,
      decoration: BoxDecoration(
        color: scheme.surface,
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Icon(icon, size: 16, color: scheme.onSurfaceVariant),
    );
  }
}
