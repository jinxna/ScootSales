import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

import '../navigation/cms_navigation.dart';

Future<void> showCmsCommandPalette({
  required BuildContext context,
  required List<CmsNavItem> items,
  required String currentKey,
  required ValueChanged<String> onSelected,
}) {
  return showDialog<void>(
    context: context,
    barrierColor: Colors.black.withValues(alpha: 0.28),
    builder: (BuildContext context) => _CommandPalette(
      items: items,
      currentKey: currentKey,
      onSelected: onSelected,
    ),
  );
}

class _CommandPalette extends StatefulWidget {
  const _CommandPalette({
    required this.items,
    required this.currentKey,
    required this.onSelected,
  });

  final List<CmsNavItem> items;
  final String currentKey;
  final ValueChanged<String> onSelected;

  @override
  State<_CommandPalette> createState() => _CommandPaletteState();
}

class _CommandPaletteState extends State<_CommandPalette> {
  final TextEditingController _controller = TextEditingController();
  final ScrollController _scrollController = ScrollController();
  String _query = '';
  int _highlighted = 0;

  static const double _rowHeight = 54;

  List<CmsNavItem> get _filtered {
    final String query = _query.trim().toLowerCase();
    if (query.isEmpty) return widget.items;
    final List<String> terms = query.split(RegExp(r'\s+'));
    return widget.items
        .where(
          (CmsNavItem item) =>
              terms.every((String t) => item.searchText.contains(t)),
        )
        .toList(growable: false);
  }

  @override
  void dispose() {
    _controller.dispose();
    _scrollController.dispose();
    super.dispose();
  }

  void _move(int delta) {
    final int count = _filtered.length;
    if (count == 0) return;
    setState(() => _highlighted = (_highlighted + delta) % count);
    if (_highlighted < 0) _highlighted += count;
    _ensureVisible();
  }

  void _ensureVisible() {
    if (!_scrollController.hasClients) return;
    final double target = _highlighted * _rowHeight;
    final double viewStart = _scrollController.offset;
    final double viewEnd =
        viewStart + _scrollController.position.viewportDimension;
    if (target < viewStart) {
      _scrollController.jumpTo(target);
    } else if (target + _rowHeight > viewEnd) {
      _scrollController.jumpTo(
        target + _rowHeight - _scrollController.position.viewportDimension,
      );
    }
  }

  void _select([int? index]) {
    final List<CmsNavItem> filtered = _filtered;
    if (filtered.isEmpty) return;
    final int i = index ?? _highlighted;
    if (i < 0 || i >= filtered.length) return;
    Navigator.of(context).pop();
    widget.onSelected(filtered[i].key);
  }

  @override
  Widget build(BuildContext context) {
    final List<CmsNavItem> filtered = _filtered;
    final ColorScheme scheme = Theme.of(context).colorScheme;
    if (_highlighted >= filtered.length) {
      _highlighted = filtered.isEmpty ? 0 : filtered.length - 1;
    }

    return CallbackShortcuts(
      bindings: <ShortcutActivator, VoidCallback>{
        const SingleActivator(LogicalKeyboardKey.arrowDown): () => _move(1),
        const SingleActivator(LogicalKeyboardKey.arrowUp): () => _move(-1),
        const SingleActivator(LogicalKeyboardKey.enter): _select,
        const SingleActivator(LogicalKeyboardKey.escape): () =>
            Navigator.of(context).pop(),
      },
      child: Align(
        alignment: const Alignment(0, -0.55),
        child: Material(
          color: Colors.transparent,
          child: Container(
            width: 560,
            constraints: const BoxConstraints(maxHeight: 460),
            decoration: BoxDecoration(
              color: scheme.surface,
              borderRadius: BorderRadius.circular(14),
              border: Border.all(color: scheme.outlineVariant),
              boxShadow: <BoxShadow>[
                BoxShadow(
                  color: Colors.black.withValues(alpha: 0.12),
                  blurRadius: 32,
                  offset: const Offset(0, 12),
                ),
              ],
            ),
            child: Column(
              mainAxisSize: MainAxisSize.min,
              children: <Widget>[
                Padding(
                  padding: const EdgeInsets.fromLTRB(16, 14, 16, 10),
                  child: Row(
                    children: <Widget>[
                      Icon(
                        Icons.search_rounded,
                        size: 20,
                        color: scheme.onSurfaceVariant,
                      ),
                      const SizedBox(width: 10),
                      Expanded(
                        child: TextField(
                          controller: _controller,
                          autofocus: true,
                          style: TextStyle(
                            fontSize: 15,
                            color: scheme.onSurface,
                          ),
                          decoration: InputDecoration(
                            border: InputBorder.none,
                            isCollapsed: true,
                            hintText: 'Jump to a page…',
                            hintStyle: TextStyle(
                              fontSize: 15,
                              color: scheme.onSurfaceVariant,
                            ),
                          ),
                          onChanged: (String value) => setState(() {
                            _query = value;
                            _highlighted = 0;
                          }),
                          onSubmitted: (_) => _select(),
                        ),
                      ),
                      _KbdHint(text: 'Esc'),
                    ],
                  ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Flexible(
                  child: filtered.isEmpty
                      ? Padding(
                          padding: EdgeInsets.symmetric(vertical: 36),
                          child: Text(
                            'No matching page',
                            style: TextStyle(color: scheme.onSurfaceVariant),
                          ),
                        )
                      : ListView.builder(
                          controller: _scrollController,
                          padding: const EdgeInsets.symmetric(vertical: 6),
                          itemCount: filtered.length,
                          itemExtent: _rowHeight,
                          itemBuilder: (BuildContext context, int index) {
                            final CmsNavItem item = filtered[index];
                            final bool active = index == _highlighted;
                            final bool current = item.key == widget.currentKey;
                            return _PaletteRow(
                              item: item,
                              active: active,
                              current: current,
                              onTap: () => _select(index),
                              onHover: () =>
                                  setState(() => _highlighted = index),
                            );
                          },
                        ),
                ),
                Divider(height: 1, color: scheme.outlineVariant),
                Padding(
                  padding: EdgeInsets.symmetric(horizontal: 16, vertical: 9),
                  child: Row(
                    children: <Widget>[
                      _KbdHint(text: '↑'),
                      SizedBox(width: 4),
                      _KbdHint(text: '↓'),
                      SizedBox(width: 6),
                      Text(
                        'to navigate',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                      SizedBox(width: 14),
                      _KbdHint(text: '↵'),
                      SizedBox(width: 6),
                      Text(
                        'to open',
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _PaletteRow extends StatelessWidget {
  const _PaletteRow({
    required this.item,
    required this.active,
    required this.current,
    required this.onTap,
    required this.onHover,
  });

  final CmsNavItem item;
  final bool active;
  final bool current;
  final VoidCallback onTap;
  final VoidCallback onHover;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Padding(
      padding: const EdgeInsets.symmetric(horizontal: 8),
      child: MouseRegion(
        onHover: (_) => onHover(),
        child: GestureDetector(
          onTap: onTap,
          behavior: HitTestBehavior.opaque,
          child: Container(
            padding: const EdgeInsets.symmetric(horizontal: 10),
            decoration: BoxDecoration(
              color: active ? scheme.primaryContainer : Colors.transparent,
              borderRadius: BorderRadius.circular(9),
            ),
            child: Row(
              children: <Widget>[
                Icon(
                  item.icon,
                  size: 19,
                  color: active
                      ? scheme.onPrimaryContainer
                      : scheme.onSurfaceVariant,
                ),
                const SizedBox(width: 12),
                Expanded(
                  child: Column(
                    mainAxisAlignment: MainAxisAlignment.center,
                    crossAxisAlignment: CrossAxisAlignment.start,
                    children: <Widget>[
                      Row(
                        children: <Widget>[
                          Flexible(
                            child: Text(
                              item.title,
                              maxLines: 1,
                              overflow: TextOverflow.ellipsis,
                              style: TextStyle(
                                fontSize: 13.5,
                                fontWeight: FontWeight.w600,
                                color: scheme.onSurface,
                              ),
                            ),
                          ),
                          if (item.section.isNotEmpty) ...<Widget>[
                            const SizedBox(width: 8),
                            Text(
                              item.section,
                              style: TextStyle(
                                fontSize: 11,
                                color: scheme.onSurfaceVariant,
                              ),
                            ),
                          ],
                        ],
                      ),
                      Text(
                        item.description,
                        maxLines: 1,
                        overflow: TextOverflow.ellipsis,
                        style: TextStyle(
                          fontSize: 11.5,
                          color: scheme.onSurfaceVariant,
                        ),
                      ),
                    ],
                  ),
                ),
                if (current)
                  Padding(
                    padding: EdgeInsets.only(left: 8),
                    child: Text(
                      'current',
                      style: TextStyle(
                        fontSize: 11,
                        color: scheme.primary,
                        fontWeight: FontWeight.w600,
                      ),
                    ),
                  ),
              ],
            ),
          ),
        ),
      ),
    );
  }
}

class _KbdHint extends StatelessWidget {
  const _KbdHint({required this.text});
  final String text;

  @override
  Widget build(BuildContext context) {
    final ColorScheme scheme = Theme.of(context).colorScheme;
    return Container(
      padding: const EdgeInsets.symmetric(horizontal: 6, vertical: 2),
      decoration: BoxDecoration(
        color: scheme.surfaceContainerHighest,
        borderRadius: BorderRadius.circular(5),
        border: Border.all(color: scheme.outlineVariant),
      ),
      child: Text(
        text,
        style: TextStyle(
          fontSize: 11,
          color: scheme.onSurfaceVariant,
          fontWeight: FontWeight.w600,
        ),
      ),
    );
  }
}
