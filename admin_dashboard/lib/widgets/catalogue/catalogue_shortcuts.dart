import 'package:flutter/material.dart';
import 'package:flutter/services.dart';

class CatalogueShortcuts extends StatefulWidget {
  const CatalogueShortcuts({
    super.key,
    required this.child,
    this.onSearch,
    this.onNew,
    this.onEscape,
    this.onNext,
    this.onPrevious,
    this.onOpen,
    this.onToggleSelect,
  });

  final Widget child;
  final VoidCallback? onSearch;
  final VoidCallback? onNew;
  final VoidCallback? onEscape;
  final VoidCallback? onNext;
  final VoidCallback? onPrevious;
  final VoidCallback? onOpen;
  final VoidCallback? onToggleSelect;

  @override
  State<CatalogueShortcuts> createState() => _CatalogueShortcutsState();

  static bool _editingText() {
    final BuildContext? focus = FocusManager.instance.primaryFocus?.context;
    if (focus == null) return false;
    return focus.widget is EditableText ||
        focus.findAncestorWidgetOfExactType<EditableText>() != null;
  }
}

class _CatalogueShortcutsState extends State<CatalogueShortcuts> {
  final FocusNode _node = FocusNode(debugLabel: 'catalogue shortcuts');

  @override
  void initState() {
    super.initState();
    WidgetsBinding.instance.addPostFrameCallback((_) {
      if (mounted && !_node.hasFocus) _node.requestFocus();
    });
  }

  @override
  void dispose() {
    _node.dispose();
    super.dispose();
  }

  KeyEventResult _onKey(FocusNode node, KeyEvent event) {
    if (event is KeyUpEvent) return KeyEventResult.ignored;
    final LogicalKeyboardKey key = event.logicalKey;
    if (key == LogicalKeyboardKey.escape && widget.onEscape != null) {
      widget.onEscape!();
      WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_node.hasFocus) _node.requestFocus();
      });
      return KeyEventResult.handled;
    }
    final HardwareKeyboard keyboard = HardwareKeyboard.instance;
    if (keyboard.isControlPressed ||
        keyboard.isMetaPressed ||
        keyboard.isAltPressed ||
        CatalogueShortcuts._editingText()) {
      return KeyEventResult.ignored;
    }
    VoidCallback? action;
    if (key == LogicalKeyboardKey.slash) {
      action = widget.onSearch;
    } else if (key == LogicalKeyboardKey.keyN && event is KeyDownEvent) {
      action = widget.onNew;
    } else if (key == LogicalKeyboardKey.arrowDown) {
      action = widget.onNext;
    } else if (key == LogicalKeyboardKey.arrowUp) {
      action = widget.onPrevious;
    } else if (key == LogicalKeyboardKey.enter && event is KeyDownEvent) {
      action = widget.onOpen;
    } else if (key == LogicalKeyboardKey.space && event is KeyDownEvent) {
      action = widget.onToggleSelect;
    }
    if (action == null) return KeyEventResult.ignored;
    action();
    return KeyEventResult.handled;
  }

  @override
  Widget build(BuildContext context) {
    return Listener(
      onPointerDown: (_) => WidgetsBinding.instance.addPostFrameCallback((_) {
        if (mounted && !_node.hasFocus) _node.requestFocus();
      }),
      child: Focus(
        focusNode: _node,
        autofocus: true,
        skipTraversal: true,
        onKeyEvent: _onKey,
        child: widget.child,
      ),
    );
  }
}
